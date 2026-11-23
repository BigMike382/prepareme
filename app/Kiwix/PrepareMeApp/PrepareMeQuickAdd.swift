// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 7, part 2).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import PrepareMeShared
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// Follows a redirect only on the same host, over https: a feed's answer never comes from somewhere else. (Moved here
/// from LiveConditions.swift, which is the phone's only, when the lookup reached the Mac in step 8a.)
final class SameHostOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url, to.scheme == "https",
              to.host == from.host else { return nil }
        return request
    }
}

/// Barcode lookup on the phone (owner, 2026-10-14; ProductLookup.swift), and on the Mac's item form since step 8a
/// (owner, 2026-10-19, by click: a code from a USB scanner looked up the same way): USDA and Open Food Facts for a food
/// (owner, 2026-10-22, by click: each figure from whichever has it, `ProductLookup.merge`), then UPCitemdb when neither
/// knows it, each asked only while the pacer allows, with only the barcode number sent (USDA's key in its header);
/// answers are kept by code so none is asked twice (each device keeps its own). On the phone, codes saved with no name
/// (no signal, a limit reached, nothing found yet) wait in `unnamed` and are looked up again after each look at the
/// Mac, then named on the Mac like any change, if the item still has no name.
@MainActor
final class ProductLookupClient: ObservableObject {
    static let shared = ProductLookupClient()

    private var pacer: LookupPacer
    private var answers: [String: ProductInfo]
    private var versions: [String: Int]  // each kept answer's `ProductLookup.answersVersion`
    @Published private(set) var unnamed: [String]
    private let session: URLSession
    /// The owner's key: the Mac's, kept from the Mac on an adult's device (Unlisted plan, phase 4), else one built in
    /// at install (kiwix-mac/build.sh), else USDA's public one.
    private var usdaKey: String {
        ProductLookup.usdaKey(MacLookupKeys.held?.usda
                              ?? Bundle.main.object(forInfoDictionaryKey: ProductLookup.keyEntry) as? String)
    }
    /// The owner's UPC Database key, the Mac's or built in the same way; without either that source is never asked.
    private var upcdbKey: String? {
        ProductLookup.upcdbKey(MacLookupKeys.held?.upcdb
                               ?? Bundle.main.object(forInfoDictionaryKey: ProductLookup.upcdbKeyEntry) as? String)
    }

    private static let pacerKey = "PrepareMe.lookupPacer", answersKey = "PrepareMe.lookupAnswers"
    private static let unnamedKey = "PrepareMe.lookupUnnamed"
    static let answersKept = 1000
    static let largest = 256 * 1024

    private init() {
        let defaults = UserDefaults.standard
        pacer = defaults.data(forKey: Self.pacerKey).flatMap { try? JSONDecoder().decode(LookupPacer.self, from: $0) }
            ?? LookupPacer()
        pacer.newSources()  // a source added since: codes nobody knew are asked again
        let kept = defaults.data(forKey: Self.answersKey)
            .flatMap { try? JSONDecoder().decode([String: Kept].self, from: $0) } ?? [:]
        answers = kept.mapValues(\.info)
        versions = kept.mapValues { $0.version ?? 0 }
        unnamed = defaults.stringArray(forKey: Self.unnamedKey) ?? []
        let configuration = URLSessionConfiguration.ephemeral  // no cookies, no cache kept
        configuration.timeoutIntervalForRequest = 10
        configuration.httpAdditionalHeaders = ["User-Agent": ProductLookup.userAgent, "Accept": "application/json"]
        session = URLSession(configuration: configuration, delegate: SameHostOnly(), delegateQueue: nil)
    }

    /// A kept answer. One kept before 2026-10-22 has no figures or version (its calories and serving fields are
    /// left unread), so a food one is asked again once.
    struct Kept: Codable {
        let name, brand, model, size, source: String
        var figures: FoodFigures? = nil
        var figuresFrom: String? = nil
        var version: Int? = nil
        var info: ProductInfo {
            ProductInfo(name: name, brand: brand, model: model, size: size, source: source,
                        figures: figures ?? FoodFigures(), figuresFrom: figuresFrom ?? "")
        }
    }

    enum Outcome: Equatable {
        case found(ProductInfo)
        case notFound  // no service knows it
        case later  // no signal, a limit reached, or an answer of another shape: tried again later by itself
    }

    /// A code's product, from the answers kept, else the services: the food services, then UPCitemdb.
    func lookup(_ code: String) async -> Outcome {
        #if targetEnvironment(simulator)
        if let check = ProcessInfo.processInfo.environment["PREPAREME_CHECK_LOOKUP"] { return await Self.checkAnswer(check) }
        #endif
        if let kept = answers[code] {
            // a food answer kept before the serving figures and USDA has no servings: asked once more (2026-10-22)
            guard ProductLookup.asksAgain(source: kept.source, version: versions[code] ?? 0) else { return .found(kept) }
            let food = await askFood(code)
            if let info = food.found {
                keep(code, info)
                return .found(info)
            }
            if food.answered { keep(code, kept) }  // both answered: kept as it was, never asked again
            return .found(kept)  // else asked again another time
        }
        if pacer.notFound.contains(code) { return .notFound }
        let food = await askFood(code)
        if let info = food.found {
            keep(code, info)
            return .found(info)
        }
        if food.unreadable { return .later }
        // then the household's goods: Open Food Facts' sister sites, the FDA's drug list (a medicine's barcode only),
        // UPCitemdb (100 a day), and UPC Database (100 a day, with the owner's key) last
        var allAnswered = food.answered
        for service in [ProductLookup.Service.beauty, .products, .fda, .goods, .upcdb] {
            // a source this code isn't for (the FDA's, for a barcode with no drug code) or with no key isn't asked
            guard let url = ProductLookup.url(service, code: code), service != .upcdb || upcdbKey != nil else { continue }
            guard pacer.may(service) else {
                allAnswered = false
                continue
            }
            pacer.asked(service)
            savePacer()
            let headers = service == .upcdb ? upcdbKey.map { ["Authorization": "Bearer \($0)"] } ?? [:] : [:]
            guard let reply = await fetch(url, headers: headers),
                  let answer = ProductLookup.answer(service, status: reply.status, data: reply.data, code: code) else {
                allAnswered = false
                continue
            }
            switch answer {
            case .found(let info):
                keep(code, info)
                return .found(info)
            case .notFound:
                continue
            case .unreadable:
                return .later
            }
        }
        if allAnswered {  // every one answered, none knows it: never asked again
            pacer.notFound.insert(code)
            savePacer()
            return .notFound
        }
        return .later
    }

    /// USDA, then Open Food Facts, each as the pacer allows, and their answers merged; `answered` when both answered.
    private func askFood(_ code: String) async -> (found: ProductInfo?, answered: Bool, unreadable: Bool) {
        var found: [ProductLookup.Service: ProductInfo] = [:]
        var answered = 0, unreadable = false
        for service in [ProductLookup.Service.usda, .food] {
            guard pacer.may(service), let url = ProductLookup.url(service, code: code) else { continue }
            pacer.asked(service)
            savePacer()
            guard let reply = await fetch(url, headers: service == .usda ? ["X-Api-Key": usdaKey] : [:]),
                  let answer = ProductLookup.answer(service, status: reply.status, data: reply.data, code: code)
            else { continue }
            switch answer {
            case .found(let info):
                found[service] = info
                answered += 1
            case .notFound:
                answered += 1
            case .unreadable:
                unreadable = true
            }
        }
        return (ProductLookup.merge(usda: found[.usda], food: found[.food]), answered == 2, unreadable)
    }

    /// A service's reply and its status (ProductLookup.answer reads it); nil with no reply (no signal, a timeout, an
    /// answer from another host or too large).
    private func fetch(_ url: URL, headers: [String: String] = [:]) async -> (status: Int, data: Data)? {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }  // keys never in the address
        guard let host = url.host, ProductLookup.hosts.contains(host),
              let answer = try? await session.data(for: request),
              let http = answer.1 as? HTTPURLResponse, http.url?.host == host,
              answer.0.count <= Self.largest else { return nil }
        return (http.statusCode, answer.0)
    }

    /// Remember a code saved with no name, to name it later.
    func waitForName(_ code: String) {
        guard !unnamed.contains(code) else { return }
        unnamed.append(code)
        UserDefaults.standard.set(unnamed, forKey: Self.unnamedKey)
    }

    #if os(iOS)
    /// After a look at the Mac: each waiting code whose item the Mac has and that still has no name is looked up, and
    /// named (its brand too, when blank) by a change like any other; a code both services don't know stops waiting.
    func nameWaiting(_ model: PhoneInventoryModel) async {
        guard model.canEdit, let copy = model.shown, let item = copy.column("Item") else { return }
        for code in unnamed {
            let id: Int64
            switch QuickForm.nameWait(code, in: copy, item: item.colId) {
            case .waiting: continue
            case .gone, .named: drop(code); continue  // no item holds it any more (phase 2 review, M2), or named
            case .unnamed(let found): id = found
            }
            guard let row = copy.items.first(where: { $0.id == id }) else { continue }
            switch await lookup(code) {
            case .found(let info):
                model.edit(.set(table: "Inventory", row: id, colId: item.colId, value: .text(info.name)),
                           what: "\(info.name): named from its barcode")
                if let brand = copy.column("Brand"), !info.brand.isEmpty,
                   InventoryValues.plain(row.values[brand.colId] ?? .null).isEmpty {
                    model.edit(.set(table: "Inventory", row: id, colId: brand.colId, value: .text(info.brand)),
                               what: "\(info.name): brand")
                }
                if let column = copy.column(Inventory.Label.model), !info.model.isEmpty,
                   InventoryValues.plain(row.values[column.colId] ?? .null).isEmpty {
                    model.edit(.set(table: "Inventory", row: id, colId: column.colId, value: .text(info.model)),
                               what: "\(info.name): model")
                }
                drop(code)
            case .notFound:
                drop(code)
            case .later:
                return  // no signal or a limit: the rest wait too
            }
        }
    }

    #endif

    /// Stop waiting to name a code: named, unknown to both services, or its add taken back (phase 2 review, 5).
    func drop(_ code: String) {
        unnamed.removeAll { $0 == code }
        UserDefaults.standard.set(unnamed, forKey: Self.unnamedKey)
    }

    private func keep(_ code: String, _ info: ProductInfo) {
        answers[code] = info
        versions[code] = ProductLookup.answersVersion
        if answers.count > Self.answersKept { answers.removeValue(forKey: answers.keys.sorted().first ?? code) }
        let kept = Dictionary(uniqueKeysWithValues: answers.map { code, info in
            (code, Kept(name: info.name, brand: info.brand, model: info.model, size: info.size, source: info.source,
                        figures: info.figures, figuresFrom: info.figuresFrom, version: versions[code]))
        })
        UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: Self.answersKey)
    }

    private func savePacer() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pacer), forKey: Self.pacerKey)
    }

    #if targetEnvironment(simulator)
    /// A session's simulator check only (no camera, no network asked): PREPAREME_CHECK_LOOKUP=food (a can of soup with
    /// its serving figures), water (a 24-pack of bottles with its package size), notfound or later, answered after two
    /// seconds so the form can be seen and typed in while it looks. Made-up products.
    static func checkAnswer(_ kind: String) async -> Outcome {
        try? await Task.sleep(for: .seconds(2))
        switch kind {
        case "food":
            return .found(ProductInfo(name: "Tomato soup", brand: "Made Up Kitchen", size: "10.75 oz",
                                      source: ProductLookup.usdaName,
                                      figures: FoodFigures(package: Amount(305, "g"), packageWords: "10.75 oz",
                                                           serving: Amount(120, "g"), servingWords: "1/2 cup (120 g)",
                                                           perServing: 90),
                                      figuresFrom: ProductLookup.usdaName))
        case "water":
            return .found(ProductInfo(name: "Purified water, 24 bottles", brand: "Made Up Springs",
                                      size: "24 x 16.9 fl oz", source: ProductLookup.goodsName))
        case "notfound": return .notFound
        default: return .later
        }
    }
    #endif
}

#if os(iOS)
/// Moves the sheet it sits in to full height once `full` is set (addition C). Under the tab bar, SwiftUI leaves a sheet at
/// the height it opened with: a later change of `presentationDetents`' selection, or of its heights, never reached the
/// sheet (iOS 27 simulator, 2026-11-18: Quick add's form stayed at half when Water was picked), so UIKit's own sheet is
/// told, once as `full` turns on: a height the user drags afterwards is never pulled back.
private struct SheetToFull: UIViewControllerRepresentable {
    let full: Bool

    final class Coordinator { var full = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        defer { context.coordinator.full = full }
        guard full, !context.coordinator.full else { return }
        DispatchQueue.main.async {  // once it is among the sheet's own view controllers
            guard let sheet = controller.sheetPresentationController, sheet.selectedDetentIdentifier != .large else { return }
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
    }
}

/// Quick add (owner, 2026-10-14: hundreds of items, as fast as can be): scan a bin's label once to choose the place
/// (or pick it), then products one after another. A code already linked to an item in that place adds 1; one linked
/// elsewhere asks; a new one opens the full item form (inventory fresh look, spec 5.3, Task 2.4: in place of its own
/// short card), looked up with its name filled in, added with one tap of Add at its foot (place, category and unit
/// kept from the last item; quantity 1). With no place chosen, a known code asks rather than adding 1. The camera
/// keeps running: a code is read once while it stays in view (and not at all while the form or a question is up), so
/// counting two of a product means taking it out of view and back. A running count, Undo last, and Type a code for
/// a label the camera can't read.
struct QuickAddView: View {
    @ObservedObject private var model = PhoneInventoryModel.shared
    @ObservedObject private var lookups = ProductLookupClient.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(QuickForm.Memory.placeKey) private var place = 0  // one memory with Add's (Task 2.5)
    @AppStorage(QuickForm.Memory.categoryKey) private var category = 0
    @AppStorage(QuickForm.Memory.unitKey) private var unit = QuickForm.Memory.quickUnit
    @State private var card: NewItem?
    @State private var elsewhere: (code: String, item: Int64)?
    @State private var log: [Done] = []
    @State private var adds = 0  // counts up with each add, for its buzz
    @State private var note: String?
    @State private var pickingPlace = false
    @State private var typing = false
    @State private var typed = ""
    @State private var readingDate = false  // the form's Read the date sheet: this camera pauses under it
    @State private var height = PresentationDetent.medium  // the form's: half, full once its line is amber (C)

    struct NewItem: Identifiable {
        let code: String
        var id: String { code }
    }

    struct Done {
        let edit: String  // "" for a 1 more held until the Mac has its item
        let what: String
        let plusOne: Int64?  // the item 1 was added to, so Undo can take it back
        var code: String? = nil  // a new item's barcode, or a held 1 more's
        var held = false
        var raised: Int64? = nil  // a new item still on this phone whose Quantity the scan raised (Task 2.5)
        // when it was made, for its place in the list (UndoList); the clock, not the time since the phone started, so
        // the app needs no reason for reading that (Unlisted plan, phase 4)
        var at = Date().timeIntervalSinceReferenceDate
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                placeBar
                ZStack(alignment: .bottom) {
                    Color.clear  // the camera's space, the whole height, so the place stays at the top
                    if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                        CodeScanner(continuous: true, paused: readingDate) { text in
                            guard card == nil, elsewhere == nil, !typing, !pickingPlace else { return }  // one at a time
                            read(text)
                        }
                        .ignoresSafeArea(edges: .horizontal)
                    } else {
                        CameraCantScan(words: StateWords.cantReadCodes)
                    }
                    if let note {
                        // big enough to see at a glance; 7 were added before the small one was noticed (owner, 2026-11-18)
                        Text(note).font(.pmHeadline).multilineTextAlignment(.center).padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PrepareMeCorners.panel))
                            .padding(.horizontal, 16)
                            .frame(maxHeight: .infinity)  // mid-camera, where the eye is after Add 1 or a scan
                    }
                }
                footer
            }
            .background(PrepareMeColors.ground)
            .sensoryFeedback(.success, trigger: adds)  // a buzz for each add (owner, 2026-11-18); an undo put back never
            .navigationTitle("Quick Add with the Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .sheet(item: $card, onDismiss: { height = .medium }) { found in
                if let copy = model.shown {
                    NavigationStack {
                        ItemForm(copy: copy, row: nil, barcode: found.code,
                                 quick: ItemForm.QuickRun(place: $place, category: $category, unit: $unit,
                                                          readingDate: $readingDate, grow: { height = .large },
                                                          addOne: { row in
                                                              card = nil  // the form closes; the scan's own 1 more
                                                              plusOne(row.id, copy, row)
                                                          }) { done in
                                     log.append(done); adds += 1
                                     show("Added \(done.what)")
                                 })
                    }
                    .presentationDetents([.medium, .large], selection: $height)
                    .background(SheetToFull(full: height == .large))  // the selection alone never moves it (C)
                } else {
                    NoCopyYet { card = nil }  // never a blank sheet holding the camera still
                }
            }
            .sheet(isPresented: $pickingPlace) {
                PlacePicker(place: $place)
            }
            .onAppear { forgetGone() }
            .onChange(of: model.shown) {
                forgetGone()
                if model.shown == nil, card != nil {  // the copy went (paired again): the camera reads again, and why
                    card = nil
                    show(NoCopyYet.line(model.problem))
                }
            }
            #if targetEnvironment(simulator)
            .task {  // a session's simulator check only: PREPAREME_CHECK_QUICK_ADD=type opens Type a code's box 2 s in
                guard ProcessInfo.processInfo.environment["PREPAREME_CHECK_QUICK_ADD"] == "type" else { return }
                try? await Task.sleep(for: .seconds(2))
                typed = ""; typing = true
            }
            #endif
            .alert("Type the Barcode's Numbers", isPresented: $typing) {
                TextField("Numbers under the bars", text: $typed).keyboardType(.numberPad)
                Button("Look up") {
                    let code = typed
                    Task {  // once the box has closed: a form asked for while it closes is dropped
                        try? await Task.sleep(for: .seconds(0.6))
                        read(code)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(place == 0 ? "This product is already in the inventory."
                                : "This product is already in the inventory, kept somewhere else.",
                                isPresented: Binding(get: { elsewhere != nil }, set: { if !$0 { elsewhere = nil } }),
                                titleVisibility: .visible) {
                if let found = elsewhere, let copy = model.shown,
                   let row = copy.items.first(where: { $0.id == found.item }) {
                    Button("Add 1 to it (\(PhoneText.whereKept(copy, row)))") { plusOne(found.item, copy, row) }
                    Button(place == 0 ? "Add it as a new item" : "Add it here as a new item") {
                        card = NewItem(code: found.code)
                    }
                }
            }
        }
    }

    var placeBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Adding to").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                Text(placeName).font(.pmHeadline).lineLimit(2)
            }
            Spacer()
            Button("Change") { pickingPlace = true }.pmAction(fullWidth: false)  // beside the place's name (review)
        }
        .padding()
    }

    /// A remembered place or category the Mac has since removed is forgotten (2026-10-23), never sent with an item.
    func forgetGone() {
        guard let copy = model.shown else { return }
        let kept = QuickForm.Memory(place: place, category: category, unit: unit)
            .forgettingGone(places: copy.places.map(\.id), categories: copy.categories.map(\.id))
        if kept.place != place { place = kept.place }
        if kept.category != category { category = kept.category }
    }

    var placeName: String {
        guard place != 0, let copy = model.shown, copy.places.contains(where: { $0.id == Int64(place) }) else {
            return "No place yet: scan a bin's label, or Change"
        }
        return InventoryLook.title(copy.path(Int64(place)))
    }

    var footer: some View {
        // on one line where it fits, else the counts on a line of their own over the buttons (a small iPhone; phase 4)
        ViewThatFits(in: .horizontal) {
            HStack { counts; Spacer(); buttons }
            VStack(alignment: .leading, spacing: 8) {
                HStack { counts }
                HStack { Spacer(); buttons }
            }
        }
        .font(.pmNote)
        .padding()
    }

    @ViewBuilder var counts: some View {
        Text("\(log.count) this time").monospacedDigit()
        if !lookups.unnamed.isEmpty {
            Text("and \(lookups.unnamed.count) to name later").foregroundStyle(PrepareMeColors.text2)
        }
        if !model.outbox.refused.isEmpty {  // the Inventory home lists them, under this screen (Task 2.4)
            Button(InventoryHome.notSaved(model.outbox.refused.count)) { dismiss() }
                .foregroundStyle(PrepareMeColors.red).accessibilityHint(InventoryHome.notSavedHint)
        }
    }

    @ViewBuilder var buttons: some View {
        // a torn label, or a camera that won't read it
        Button("Type a code") { typed = ""; typing = true }.pmAction(fullWidth: false)
        Button("Undo last") { undo() }.pmAction(fullWidth: false).disabled(log.isEmpty)
    }

    func read(_ text: String) {
        if let found = Barcode.place(in: text) {
            if model.shown?.places.contains(where: { $0.id == found }) == true {
                place = Int(found)
                show("Adding to \(InventoryLook.title(model.shown?.path(found) ?? ""))")
            } else {
                place = 0  // never keep adding to the last bin while this one is unknown (2026-10-23)
                show("That bin isn't in this \(ThisDevice.word)'s copy yet")
                Task { await model.look() }
            }
            return
        }
        guard let code = Barcode.valid(text) else {
            show("That isn't a product's barcode")
            return
        }
        guard let copy = model.shown else {  // said, never a code dropped without a word
            show(NoCopyYet.line(model.problem))
            return
        }
        if let item = model.item(forCode: code), let row = copy.items.first(where: { $0.id == item }) {
            let location = copy.column("Location")
            let kept = copy.items.map { item in (item.id, copy.itemName(item), location.flatMap { item.values[$0.colId]?.whole }) }
            if place != 0, location.flatMap({ row.values[$0.colId]?.whole }) == Int64(place) {
                plusOne(item, copy, row)  // with no place chosen, it asks (review 2026-10-14)
            } else if let same = ItemMatch.inPlace(named: copy.itemName(row), place: Int64(place), kept),
                      let sameRow = copy.items.first(where: { $0.id == same }) {
                plusOne(same, copy, sameRow)  // an item of its name is here already: 1 more of that one (Task 2.7)
            } else {
                elsewhere = (code, item)
            }
            return
        }
        card = NewItem(code: code)
    }

    func plusOne(_ item: Int64, _ copy: PhoneInventory, _ row: PhoneInventory.Row) {
        let name = copy.shownName(row)
        guard item > 0 else {
            Task {
                if await model.raiseWaitingAdd(item, by: 1) {  // still on this phone: one item of 6, not 1 and five more
                    log.append(Done(edit: "", what: name, plusOne: nil, raised: item)); adds += 1
                    show("\(name): 1 more")
                } else if let code = copy.barcodes?.first(where: { $0.value == item })?.key {
                    // its new item is on its way: the 1 more goes as soon as the Mac has it
                    model.holdOneMore(code)
                    log.append(Done(edit: "", what: name, plusOne: nil, code: code, held: true)); adds += 1
                    show("\(name): 1 more (sent once the Mac has it)")
                } else {  // an item typed in with no barcode, on its way: nothing to hold the 1 more by (review)
                    show("\(name) is on its way to the Mac; scan it again in a moment")
                }
            }
            return
        }
        if let id = model.edit(.adjust(row: item, by: 1), what: "\(name): 1 more") {
            log.append(Done(edit: id, what: name, plusOne: item)); adds += 1
            show("\(name): 1 more")
        }
    }

    func undo() {
        guard let last = log.popLast() else { return }
        if let item = last.raised {
            Task {  // a send under way is waited for first
                show(await model.raiseWaitingAdd(item, by: -1) ? "Took back 1: \(last.what)"
                     : "\(last.what) is on its way to the Mac; take 1 off there")
            }
            return
        }
        if last.held, let code = last.code {
            model.unholdOne(code)
            show("Took back 1: \(last.what)")
            return
        }
        if model.isSending(last.edit) { note = "One moment: \(last.what) is still being sent." }  // up to a minute
        Task {
            let taken = await model.withdraw(last.edit)  // a send of it under way is waited for first (checkpoint 2)
            if taken == .done {
                if let code = last.code {
                    model.dropHeld(code)  // its held 1 mores go with it
                    // and its wait for a name, unless another item still holds the code (phase 2 review, 5)
                    if model.item(forCode: code) == nil { lookups.drop(code) }
                }
                show("Took back: \(last.what)")
            } else if taken == .stillSending {  // a minute on and not ended: it may yet come back unsent (re-review)
                UndoList.putBack(last, into: &log, madeAt: \.at)  // where it was: the next Undo still takes the latest
                show("\(last.what) is still being sent; try Undo again in a moment")
            } else if let item = last.plusOne {
                // the scan went to the Mac already: a 1 less marked as a correction, never logged as a use (B2-08)
                model.edit(.adjust(row: item, by: -1), what: "\(last.what): 1 less", correction: true)
                show("Took back 1: \(last.what)")
            } else if let code = last.code {  // a new item the Mac has: deleted there (owner, 2026-11-18)
                if model.isSending(last.edit) || model.item(forCode: code).map({ $0 < 0 }) == true {
                    note = "One moment: taking back \(last.what)."
                }
                switch await model.takeBackSentAdd(edit: last.edit, what: last.what) {
                case .deleted, .gone:
                    model.dropHeld(code)
                    if model.item(forCode: code) == nil { lookups.drop(code) }
                    show("Took back: \(last.what)")
                case .notYet:
                    UndoList.putBack(last, into: &log, madeAt: \.at)
                    show("\(last.what) is still being sent; try Undo again in a moment")
                }
            } else {
                show("\(last.what) is on the Mac now; delete it there")  // a send of it reached the Mac, or may have
            }
        }
    }

    func show(_ text: String) {
        note = text
        AccessibilityNotification.Announcement(text).post()  // VoiceOver hears what the toast says (entry fixes, phase 4)
        let shown = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if note == shown { note = nil }
        }
    }
}

/// Choose the place quick add puts things in: every place by its whole path.
struct PlacePicker: View {
    @Binding var place: Int
    @ObservedObject private var model = PhoneInventoryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            PMList {  // searchable, New Place… at its foot (entry fixes plan, Task 1.6)
                if let copy = model.shown {
                    ForEach(PickLists.places(copy.places.map { (id: $0.id, path: copy.path($0.id)) }, search: search)) { found in
                        Button {
                            place = Int(found.id)
                            dismiss()
                        } label: {
                            HStack {
                                // shown in title case, as the item form shows it; search and order use the stored path
                                Text(InventoryLook.title(found.title)).foregroundStyle(PrepareMeColors.ink)
                                Spacer()
                                if place == Int(found.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if model.mayEdit {
                        NavigationLink {
                            NewPlaceForm(places: copy.places.map { PickChoice(id: $0.id, title: InventoryLook.title(copy.path($0.id))) },
                                         others: copy.places.map { (id: $0.id, name: $0.name, keptIn: $0.keptIn) },
                                         keptIn: Int64(place), add: model.addPlace) { made in
                                place = Int(made)
                                dismiss()
                            }
                        } label: {
                            Label(PickLists.newPlaceTitle, systemImage: "plus").foregroundStyle(PrepareMeColors.ink)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search")
            .navigationTitle("Pick a Place")
            .pmTitleSmall()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }  // a tap picks
        }
    }
}
#endif
