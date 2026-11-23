// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 7).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import AppKit
import Foundation
import PrepareMeShared
import SwiftUI
import UniformTypeIdentifiers

/// The Mac's inventory editor (build plan phase 7): the inventory file in Application Support › PrepareMe › inventory,
/// kept in the layout the lists job reads (readiness/grist.py), with PrepareMe its only writer.
///
/// - Every change goes through InventoryEditor: the lists job's own ID check (the venv's Python on the copy of the
///   check's code inside the app, Contents/Resources/check, put there by kiwix-mac/build.sh), then the rules (a location
///   or category in use isn't deleted, naming its items; a bin isn't kept inside itself), then one write. A check that
///   can't run keeps nothing and says so.
/// - Before move day there is no file: the window says the inventory arrives then (docs/inventory.md).
/// - Undo and redo are the window's own (Edit › Undo), one change at a time; a Delete of several rows is one change
///   (B2-07).
@MainActor
final class InventoryModel: ObservableObject {
    static let shared = InventoryModel()

    /// A Choice column's widget options: its choices, in Grist's own shape.
    nonisolated static func choices(_ list: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(["choices": list])) ?? Data(), as: UTF8.self)
    }
    nonisolated static let fileName = "PrepareMe Inventory.grist"  // the layout readiness reads, by its own name

    enum State {
        case notOpened
        case missing  // no file yet: it comes on move day
        case problem(String)
        case ready(Inventory)
    }

    @Published private(set) var state: State = .notOpened {
        didSet {
            if case .ready(let now) = state, case .ready(let before) = oldValue, now.sameRows(as: before) { return }
            revision += 1
        }
    }
    /// Bumped when the inventory's rows change (a save, or the file changed under it; checkpoint 2 and its re-review),
    /// not on the 10-second read that changed nothing: what the search's near-miss words and the add form's names are
    /// kept by, so a rename that leaves the count alone still builds them again.
    private(set) var revision = 0
    @Published var message: String?
    /// A pick asked for from outside the inventory: a guide's In the house (phase 14, F57), taken by the view.
    @Published var requestedPick: InventoryPick?
    /// Bumped by a click on Inventory's own sidebar row while it shows (the inventory fresh look, phase 3): the view
    /// goes back to its home page.
    @Published private(set) var homeAsked = 0

    func goHome() { homeAsked += 1 }
    /// New Item… (false) or Add by Barcode… (true) pressed on the home page (phase 3): All Items opens, and its table
    /// opens the form, so Add, Go to that item and the new row's selection work as they do there.
    @Published var addAsked: Bool?
    @Published private(set) var saving = 0  // changes waiting on the check and the write
    @Published private(set) var toBuy: ToBuyList?  // the lists' To buy, after cutover (slice 4)
    @Published private(set) var ticks: [ToBuyTick] = []  // the app's ticks the lists haven't counted yet
    @Published private(set) var turnLists: TurnLists?  // the printed turn lists (hand-off improvements, phase 3)
    private var editor: InventoryEditor?
    private var opened: (inode: UInt64, url: URL)?
    private var seenVersion: Int64?  // the file's data_version at the last read: the same means nothing else wrote it

    nonisolated static var folder: URL? {
        PrepareMeMac.folders?.appendingPathComponent("inventory")
    }

    nonisolated static var fileURL: URL? { folder?.appendingPathComponent(fileName) }

    /// Open the file, or open it again when it was put back (a restore) or changed outside the editor.
    func open() {
        guard let url = Self.fileURL else {
            state = .problem("PrepareMe couldn't find this Mac's home folder.")
            return
        }
        guard let inode = Self.inode(url) else {
            editor = nil
            opened = nil
            state = .missing
            return
        }
        do {
            if let editor, opened?.inode == inode, opened?.url == url {
                // every 10 seconds and each window switch: a reload redrew and re-measured the whole table, so only
                // when something outside the editor wrote the file
                let version = try editor.file.dataVersion()
                if version == seenVersion {
                    refreshToBuy()
                    refreshLists()
                    return
                }
                try editor.reload()
                seenVersion = version
            } else {
                let file = try InventoryFile(url: url)
                // The app's own column (plan phase 7): bins sit inside places.
                try file.ensureColumn("Locations", colId: "Kept_in", label: Inventory.Label.keptIn,
                                      type: "Ref:Locations")
                // and vehicles hold gear kept loaded (plan phase 7, part 2): a truck, an RV
                try file.ensureColumn("Locations", colId: "Vehicle", label: Inventory.Label.vehicle, type: "Bool")
                // and two ticks on items (the 2026-10-23 plan): a container kept empty, food kept past its date
                try file.ensureColumn("Inventory", colId: "Empty_until_needed", label: Inventory.Label.emptyUntilNeeded,
                                      type: "Bool")
                try file.ensureColumn("Inventory", colId: "Keep_past_date", label: Inventory.Label.keepPastDate,
                                      type: "Bool")
                // and the entry fixes plan's phase 3 fields (2026-10-23): what one holds, whose food, a generator's watts
                try file.ensureColumn("Inventory", colId: "Each_holds", label: Inventory.Label.eachHolds, type: "Numeric")
                try file.ensureColumn("Inventory", colId: "Holds_unit", label: Inventory.Label.holdsUnit, type: "Choice",
                                      widgetOptions: Self.choices(Inventory.Label.holdsUnits))
                try file.ensureChoices("Inventory", label: Inventory.Label.holdsUnit, Inventory.Label.holdsUnits)  // fl oz
                try file.ensureChoices("Inventory", label: "Unit", Inventory.Label.unitAdds)  // bottles… (spec 5.4)
                try file.ensureColumn("Inventory", colId: "Pet_food_for", label: Inventory.Label.petFoodFor,
                                      type: "Choice", widgetOptions: Self.choices(Inventory.Label.petFoodChoices))
                try file.ensureColumn("Inventory", colId: "Running_watts", label: Inventory.Label.runningWatts,
                                      type: "Numeric")
                try file.ensureColumn("Inventory", colId: "Starting_watts", label: Inventory.Label.startingWatts,
                                      type: "Numeric")
                editor = try InventoryEditor(file: file, checker: Self.checker())
                opened = (inode, url)
                seenVersion = try file.dataVersion()
            }
            state = .ready(editor!.inventory)
            refreshToBuy()
            refreshLists()
        } catch let error as InventoryFileError {
            editor = nil  // never write through a connection to a file that was replaced (review 10)
            opened = nil
            state = .problem(error.description)
        } catch {
            editor = nil
            opened = nil
            state = .problem("The inventory file couldn't be read (\(type(of: error))).")
        }
    }

    // MARK: The phones (plan phase 7, slice 5)

    private var phonesLoop: Task<Void, Never>?
    private var lastPhoneCopy: PhoneInventory?  // as last written, its time set aside

    /// From launch, window or not: every 10 seconds, apply the phones' edits waiting in the inbox (PhoneInbox, through
    /// the same editor and checks as the Mac's own) and keep the phones' copy (phone-inventory.json) up to date. A
    /// check that can't run leaves the edits waiting for the next try.
    func startPhones() {
        guard phonesLoop == nil else { return }
        if let folder = Self.folder {  // made here: the service's sandbox may write in it but not make it
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent(PhoneInbox.inboxName),
                                                     withIntermediateDirectories: true)
        }
        phonesLoop = Task { @MainActor in
            while !Task.isCancelled {
                await servePhones()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Why phones' changes are waiting, for Settings' Phones tab and, last, the sidebar's attention
    /// line (nil when nothing is): the check couldn't run, or the phones' copy couldn't be written, on this many tries
    /// in a row.
    @Published private(set) var phoneProblem: String?
    private var stuckTries = 0
    private var lastPhoneWrite: Date?
    static let phoneCopyEvery: TimeInterval = 600  // written at least this often, so a phone can tell how old it is

    func servePhones() async {
        open()
        guard let editor, let folder = Self.folder else { return }
        // when event mode came on, as the hourly job wrote it: a Used 1 is logged in it (step 8c, section 4)
        editor.useLogStart = EventModeFile.start(EventModeFile.read(in: folder))
        editor.useLogShares = SupplyShares.read(in: folder)  // a Used 1 is valued from them as it's applied
        do {
            let mode = editor.inventory.lists?.setting(ListsLayout.eventMode)
            if try await PhoneInbox.process(folder: folder, editor: editor) {
                state = .ready(editor.inventory)
                refreshToBuy()
                if editor.inventory.lists?.setting(ListsLayout.eventMode) != mode { pressCheckOnce() }  // a phone's switch
            }
            refreshLists()
            stuckTries = 0
            phoneProblem = nil
        } catch {
            stuckTries += 1
            if stuckTries >= 3 {
                phoneProblem = "Devices' changes are waiting: the ID check couldn't run (\(stuckTries) tries)."
            }
        }
        writePhoneCopy()
        writeInsurancePDF()
    }

    private var insuranceDigest: Int?

    /// The insurance record's PDF (plan phase 7, part 2), written whole into the inventory folder when what it shows
    /// changes (and when it's missing), for the nightly copy to Household Private; none before the record is started.
    func writeInsurancePDF() {
        guard let editor, let folder = Self.folder, editor.inventory.hasInsuranceRecord else { return }
        let url = folder.appendingPathComponent(InsurancePDF.fileName)
        // what it shows, without reading a photo: the items' words and the photos' counts and size
        let counts = (try? editor.file.photoCounts()) ?? (byItem: [:], bytes: 0)
        let digest = InsurancePDF.digest(InsurancePDF.items(editor.inventory) { _ in [] },
                                         total: editor.inventory.insuredTotal,
                                         photos: counts.byItem.sorted { $0.key < $1.key }.map { [$0.key, Int64($0.value)] },
                                         bytes: counts.bytes)
        guard digest != insuranceDigest || !FileManager.default.fileExists(atPath: url.path) else { return }
        let items = InsurancePDF.items(editor.inventory) { (try? editor.file.photos(of: $0)) ?? [] }
        do {
            try DurableFile.write(InsurancePDF.pdf(items, total: editor.inventory.insuredTotal), to: url)
            insuranceDigest = digest
        } catch {
            phoneProblem = "The insurance record's PDF couldn't be written (\(type(of: error)))."
        }
    }

    /// The phones' copy, written whole when what it holds has changed, and at least every 10 minutes (never a Private
    /// row: PhoneInventory.make). Its answers to phones' edits come from the inventory file's own record.
    func writePhoneCopy() {
        guard let editor, let folder = Self.folder else { return }
        let results = (try? editor.file.phoneEditResults(since: Date().addingTimeInterval(-60 * 86_400))) ?? [:]
        let supply = SupplyShares.read(in: folder)
        // the use log since event mode came on, by the amounts each tap was valued at (step 8c, section 4); none out of
        // event mode, or unreadable
        var useLog: PhoneUseLog?
        if case .on(let since) = EventModeFile.start(EventModeFile.read(in: folder)),
           let entries = try? editor.file.useLog() {
            useLog = PhoneUseLog.make(entries, since: since)
        }
        let copy = PhoneInventory.make(editor.inventory, toBuy: toBuy, waiting: ticks, results: results,
                                       barcodes: (try? editor.file.barcodes()) ?? [:],
                                       supply: supply, manuals: keepManuals(editor.inventory), useLog: useLog,
                                       alsoChanged: (try? editor.file.alsoChanged()) ?? [],
                                       makers: PhonePairing.shared.makers())
        let same = lastPhoneCopy.map { $0.unstamped == copy.unstamped } ?? false
        let fresh = lastPhoneWrite.map { Date().timeIntervalSince($0) < Self.phoneCopyEvery } ?? false
        guard !same || !fresh || PhoneInventory.read(in: folder) == nil else { return }
        do {
            // kept in the file first, so a phone never holds a copy this file doesn't know it wrote (task 1.4); the
            // app's first copy since it opened starts a new run
            if let at = ISO8601DateFormatter().date(from: copy.writtenAt) {
                try editor.file.recordCopyWritten(at, newRun: lastPhoneWrite == nil)
            }
            try copy.write(in: folder)
            PrepareMeOurHome.refill()  // an Our Home page shown fills from the new copy (Task 2.4)
            lastPhoneCopy = copy
            lastPhoneWrite = Date()
        } catch {
            phoneProblem = "The phones' copy of the inventory couldn't be written (\(type(of: error)))."
        }
    }

    // MARK: Equipment manuals (top-ten plan, phase 7)

    /// Bumped when a manual is added or removed, so the item form looks again.
    @Published private(set) var manualsStamp = 0

    /// The manuals folder (Application Support › PrepareMe › item-manuals, ItemManuals), for reading.
    nonisolated static var manuals: ItemManuals? {
        PrepareMeMac.folders.map { ItemManuals(support: $0) }
    }

    /// The items whose manual the phones' copy names, after dropping any whose item has turned Private or been deleted
    /// (the library reaches every phone) and renaming any whose item was renamed (the library's index titles it by the
    /// item). A manual the packer left out, or stopped its build on, isn't named (ItemManuals.forPhones).
    func keepManuals(_ inventory: Inventory) -> Set<Int64> {
        guard let manuals = Self.manuals else { return [] }
        let shared = Dictionary(inventory.itemRows.filter { !inventory.isPrivate($0) }
            .map { ($0.id, inventory.name(ofItem: $0)) }) { first, _ in first }
        do {
            try manuals.keep(shared: shared)
        } catch let unreadable as ItemManuals.Unreadable {
            phoneProblem = unreadable.description
        } catch {
            phoneProblem = "The equipment manuals' list couldn't be written (\(type(of: error)))."
        }
        let kept = Set(((try? manuals.entries()) ?? [:]).keys)
        if kept != lastManuals {
            lastManuals = kept
            manualsStamp += 1
        }
        return manuals.forPhones()
    }

    private var lastManuals: Set<Int64> = []

    func manualState(_ item: Int64) -> ItemManuals.State {
        Self.manuals?.state(itemID: item) ?? .none
    }

    /// "Add Manual…" and "Replace…": the PDF read page by page through the ID check (ItemManuals.add), then copied in;
    /// a refusal says why in `message`, naming a page and the kind only.
    func addManual(_ pdf: URL, item: Int64) async {
        guard let support = PrepareMeMac.folders, case .ready(let inventory) = state,
              let row = inventory.itemRows.first(where: { $0.id == item }) else {
            message = "PrepareMe couldn't find this item or this Mac's home folder."
            return
        }
        let manuals = ItemManuals(support: support, checker: Self.checker())
        saving += 1
        defer { saving -= 1 }
        let access = pdf.startAccessingSecurityScopedResource()
        defer { if access { pdf.stopAccessingSecurityScopedResource() } }
        do {
            _ = try await manuals.add(pdf: pdf, itemID: item, itemName: inventory.name(ofItem: row),
                                      isPrivate: inventory.isPrivate(row))
            message = nil
            manualsStamp += 1
            writePhoneCopy()
        } catch let refused as ItemManuals.Refused {
            message = refused.words
        } catch let error as CheckUnavailable {
            message = error.description
        } catch let unreadable as ItemManuals.Unreadable {
            message = unreadable.description
        } catch {
            message = "The manual couldn't be saved (\(type(of: error)))."
        }
    }

    func removeManual(_ item: Int64) {
        do {
            try Self.manuals?.remove(itemID: item)
            message = nil
        } catch let unreadable as ItemManuals.Unreadable {
            message = unreadable.description
        } catch {
            message = "The manual couldn't be removed (\(type(of: error)))."
        }
        manualsStamp += 1
        writePhoneCopy()
    }

    /// The lists' To buy, and the ticks still waiting: a tick the lists have counted (`folded`) is dropped here. Any
    /// failure leaves the last list shown; the next look tries again.
    func refreshToBuy() {
        guard let folder = Self.folder, let editor else { return }
        let list = ToBuyList.read(in: folder)
        if let list, !list.folded.isEmpty {
            try? editor.file.dropTicks(list.folded)
        }
        if let list, list != toBuy { toBuy = list }  // set only when changed, so no redraw (fix round 1, finding 10)
        if let now = try? editor.file.ticks(), now != ticks { ticks = now }
        let turns = TurnLists.read(in: folder)  // read with To buy, every look; set only when changed, so no redraw
        if turns != turnLists { turnLists = turns }
    }

    /// The lists (plan phase 7, part 2): the lists job's rewrite taken in when it's new and the lists are still as its
    /// read saw them (ListsTables.swift), at its turn in the editor. A failure leaves the lists as they are; the next
    /// look tries again.
    func refreshLists() {
        guard let folder = Self.folder, let editor, let payload = ListsPayload.read(in: folder),
              payload.stamp != editor.inventory.lists?.stamp else { return }
        Task { @MainActor in
            if (try? await editor.takeIn(payload)) == true, self.editor === editor {
                state = .ready(editor.inventory)
                writePhoneCopy()
            }
        }
    }

    /// The lists as the file holds them, or nil before they're handed over.
    var lists: Lists? {
        if case .ready(let inventory) = state { return inventory.lists }
        return nil
    }

    /// The Event mode switch (plan phase 7, part 2), then a press of Check conditions once, so the hourly job reads the
    /// lists and repacks the phones within minutes rather than at its next start.
    func setEventMode(_ value: String, undo: UndoManager?) async {
        guard let row = lists?.rows(ListsLayout.settings).first(where: { $0["Setting"].text == ListsLayout.eventMode })
        else { return }
        guard await apply(.listSet(sheet: ListsLayout.settings, row: ListRowRef(row), column: "Value",
                                   value: .text(value), expected: row["Value"]), undo: undo, name: "Event mode") != nil
        else { return }
        pressCheckOnce()
    }

    /// Check conditions once, so the hourly job reads the lists and repacks the phones within minutes (after an Event
    /// mode switch, the Mac's or a phone's).
    func pressCheckOnce() {
        #if PREPAREME_CHECK
        guard PrepareMeRequests.homeOverride != nil else { return }  // a session's check build presses only its own
        #endif
        try? PrepareMeRequests.press(.checkOnce)
    }

    static func checker() -> TextChecking {
        let code = Bundle.main.resourceURL?.appendingPathComponent("check") ?? URL(fileURLWithPath: "/nonexistent")
        let python = PythonTextCheck.venvPython() ?? URL(fileURLWithPath: "/nonexistent")
        return PythonTextCheck(python: python, code: code)
    }

    static func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// An item's photos (slice 7), oldest first.
    func photos(of item: Int64) -> [InventoryPhoto] {
        (try? editor?.file.photos(of: item)) ?? []
    }

    /// The product barcodes linked to an item (slice 6), in order.
    func codes(of item: Int64) -> [String] {
        ((try? editor?.file.barcodes()) ?? [:]).filter { $0.value == item }.map(\.key).sorted()
    }

    /// Apply a change; on success what undoes it goes on `undo`.
    @discardableResult
    func apply(_ change: InventoryChange, undo: UndoManager?, name: String) async -> Int64? {
        guard let (back, row) = await run(change) else { return nil }
        let known = ChangeBox()
        known.task = Task { back }
        register(known, undo: undo, name: name)
        return row
    }

    /// Undo and redo (review 1): the manager's undo closure runs synchronously while it is undoing, so what undoes
    /// that undo is registered right there, landing on the redo stack (and a redo's, back on the undo stack). The
    /// change it will make is known only once the undo's own change has run, so it waits on that, in order.
    private func register(_ box: ChangeBox, undo: UndoManager?, name: String) {
        undo?.registerUndo(withTarget: self) { model in
            let next = ChangeBox()
            model.register(next, undo: undo, name: name)
            next.task = Task { @MainActor in
                guard let change = await box.task?.value else { return nil }
                return await model.run(change)?.0
            }
        }
        undo?.setActionName(name)
    }

    /// One change through the editor: (what undoes it, the row) when done; nil, with the reason in `message`, when it
    /// was refused or couldn't be saved.
    private func run(_ change: InventoryChange) async -> (InventoryChange, Int64)? {
        open()
        guard let editor else { return nil }
        saving += 1
        defer { saving -= 1 }
        do {
            switch try await editor.apply(change) {
            case .done(let back, let row):
                #if PREPAREME_CHECK
                if let notes = ProcessInfo.processInfo.environment["PREPAREME_CHECK_NOTES"] {
                    InventoryTableCheck.note("apply done: \(change)", to: notes)  // one per save, one undo step each
                }
                #endif
                message = nil
                state = .ready(editor.inventory)
                refreshToBuy()
                // the phones' copy waits for the 10-second loop (servePhones): built and written on every save, it
                // froze the window about 25 ms an Add at 600 items (2026-10-31)
                return (back, row)
            case .refused(let why):
                message = PhoneEditRules.shownRefusal(why)  // "Year: must be…", said once (2026-11-19)
            }
        } catch let error as CheckUnavailable {
            message = error.description
        } catch let error as InventoryFileError {
            message = error.description
        } catch {
            message = "Nothing was saved: the inventory file couldn't be written (\(type(of: error)))."
        }
        if let editor = self.editor { state = .ready(editor.inventory) }
        return nil
    }
}

/// The change a pending undo or redo will make, once the one before it has run.
@MainActor
final class ChangeBox {
    var task: Task<InventoryChange?, Never>?
}

// MARK: The editor

/// The main window's Inventory (Mac sidebar plan, part 2; the inventory fresh look, phase 3, spec 5.1): on Inventory's
/// own sidebar row its home page (`PrepareMeInventoryHome`) or the table a tile opened, with a back button to the home
/// page; on one of the five rows under it, that row's list. A pick asked for from elsewhere (`requestedPick`: Today's
/// counts, a guide's In the house, Show Them, Go to that item) first makes its row the sidebar's
/// (`MacInventoryList.row(for:)`), then shows there. A tile's table isn't remembered: Inventory reopens on its home page.
/// What shows, and each move between them, is `MacInventoryPage` (PrepareMeShared, fix round 1), tested there.
struct PrepareMeInventoryView: View {
    let row: MacRow
    @ObservedObject private var model = InventoryModel.shared
    @State private var page = MacInventoryPage()  // Inventory's own pick and the one search box

    var shown: InventoryPick? { page.shown(on: row) }

    var body: some View {
        Group {
            switch model.state {
            case .notOpened: ProgressView()
            case .missing: InventoryMissing()
            case .problem(let why): InventoryNote(text: "The inventory couldn't be read", line: why, kind: .damaged,
                                                  symbol: "exclamationmark.triangle")
            case .ready(let inventory):
                if shown == .toBuy {
                    ToBuyView(inventory: inventory)
                } else if case .list(let sheet) = shown {
                    ListSheetView(inventory: inventory, sheet: sheet)
                } else {
                    Group {
                        if let shown {
                            InventoryDetail(inventory: inventory, pick: shown, search: $page.search) { clearSearch() }
                        } else {
                            PrepareMeInventoryHome(inventory: inventory) { open($0) }
                        }
                    }
                    .modifier(FindFocus())  // Edit › Find puts the cursor in the search box (inside .searchable)
                    .searchable(text: $page.search, placement: .toolbar, prompt: "Search")
                    .autocorrectionDisabled(!PhoneSearch.boxAutocorrects)  // B2-09
                }
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if page.showsBack(on: row) {  // over a tile's table, and a home page search's All Items (fix round 1)
                ToolbarItem(placement: .navigation) {
                    Button { goHome() } label: { Label("Inventory", systemImage: "chevron.backward") }
                        .help(page.search.isEmpty ? "Back to Inventory's home page"
                              : "Back to Inventory's home page, the search cleared")
                }
            }
        }
        .onAppear {
            model.open()
            takeRequest()
            #if PREPAREME_CHECK
            checkPick()
            #endif
        }
        .onChange(of: model.requestedPick) { takeRequest() }
        .onChange(of: model.homeAsked) { goHome() }
        .onChange(of: row) { _, now in page.moved(to: now) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.open() }
        #if PREPAREME_CHECK
        // PREPAREME_CHECK_FIND_ITEMS=<made-up words> types them in the search box (2026-10-31; the home page's too)
        // (2 s in, once PREPAREME_CHECK_ROW has set the row: coming to Inventory's row clears a list row's words)
        .task {
            if let words = ProcessInfo.processInfo.environment["PREPAREME_CHECK_FIND_ITEMS"] {
                try? await Task.sleep(for: .seconds(2))
                page.search = words
            }
        }
        #endif
    }

    /// A tile's, an edit button's or a list button's table, on Inventory's own row.
    func open(_ picked: InventoryPick) {
        model.requestedPick = picked
    }

    func goHome() { page.goHome() }

    /// The asked-for pick on the row it belongs under: a list row's own, or Inventory's with the pick kept.
    func takeRequest() {
        guard let asked = model.requestedPick else { return }
        model.requestedPick = nil
        let target = page.take(asked)
        if target != row { PrepareMeMacTabs.shared.pick(target) }
    }

    /// The table's search cleared to show an item it hid: a home page search's All Items moves to its own row in the
    /// same moment, so the table, its selection and its open form stay (fix round 1, finding 1).
    func clearSearch() {
        if let move = page.clearSearch(on: row) { PrepareMeMacTabs.shared.pick(move) }
    }

    #if PREPAREME_CHECK
    /// The check build's picks for a check that can't click, each once a launch, once the inventory is read:
    /// PREPAREME_CHECK_INVENTORY_PICK=Locations, Categories or location:<name> shows that table or place 2 s in
    /// (`InventoryDetail` took it until phase 3, but the home page has no table); PREPAREME_CHECK_ROW=inventoryCategory
    /// opens the first category's table (phase 3).
    func checkPick() {
        let env = ProcessInfo.processInfo.environment
        guard !InventoryTableCheck.picked,
              env["PREPAREME_CHECK_INVENTORY_PICK"] != nil || env["PREPAREME_CHECK_ROW"] == "inventoryCategory" else {
            return
        }
        InventoryTableCheck.picked = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard case .ready(let inventory) = model.state else { return }
            if env["PREPAREME_CHECK_ROW"] == "inventoryCategory", let first = inventory.sidebarCategories.first {
                model.requestedPick = .view(.category(first.id))
            } else if let picked = env["PREPAREME_CHECK_INVENTORY_PICK"], picked.hasPrefix("location:") {
                let name = String(picked.dropFirst("location:".count))
                if let place = inventory.locationRows.first(where: {
                    InventoryFile.same(inventory.name(ofLocation: $0.id), name) }) {
                    model.requestedPick = .view(.location(place.id))
                }
            } else if let picked = env["PREPAREME_CHECK_INVENTORY_PICK"] {
                model.requestedPick = .table(picked)
            }
        }
    }
    #endif
}

/// The Not counted notice under the counts (owner, 2026-11-14, by click: the reasons left Today): the lists' reasons
/// supplies aren't counted in full, as one amber row, and Show them opening the rows a supply left out. Nothing when
/// the last count left nothing out.
struct InventoryNotCounted: View {
    let inventory: Inventory
    var padded = true  // over a table; the home page sets its own frame
    @State private var shares: SupplyShares?

    var body: some View {
        VStack(spacing: 0) {  // a VStack even when empty, so the task still reads the count
            if let line = shares?.notCountedLine {
                let rows = shares?.leftOut ?? []
                let shown = inventory.items(in: .leftOut(rows)).count
                PMWarningRow(line, action: shown > 0 ? (SupplyShares.showThem(shown), {
                    InventoryModel.shared.requestedPick = .view(.leftOut(rows))
                }) : nil)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, padded ? 16 : 0)
                .padding(.vertical, padded ? 10 : 0)
            }
        }
        .task(id: inventory.itemRows.count) { shares = InventoryModel.folder.flatMap { SupplyShares.read(in: $0) } }
    }
}

struct InventoryMissing: View {
    var body: some View {
        InventoryNote(text: StateWords.noInventoryYet)
    }
}

/// A pane with nothing to show yet, or that couldn't be read: look 3's one look (spec section 10, rule 1), its one
/// sentence as the heading (phase 4's rule for a message with no heading of its own).
struct InventoryNote: View {
    let text: String
    var line = ""  // in the kind's color: a red or amber note's reason (PMState colors the line, not the heading)
    var kind: PMMessageKind = .info
    var symbol = "tray"

    var body: some View {
        PMStateScreen { PMState(symbol: symbol, heading: text, line: line, kind: kind) }
    }
}

/// The picked table or view: a search, the table, and its buttons.
struct InventoryDetail: View {
    let inventory: Inventory
    let pick: InventoryPick
    @Binding var search: String  // the Inventory view's, which holds the box (the home page searches too: phase 3)
    /// Clears the search through the Inventory view's rule (`MacInventoryPage.clearSearch`), never by emptying the box
    /// here: a home page search's All Items would turn back into the home page, its open form with it.
    let clearSearch: () -> Void
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.undoManager) private var undo
    @State private var nearIndex = PhoneSearch.KeyedCache<PhoneSearch.Index>()  // B2-09
    /// The columns' widths, measured once a table and kept across the tiles' tables (each opening builds a new view:
    /// fix round 1, finding 8), measured again once a save has come since (`openedAt`).
    private let fits = InventoryDetail.fitsKept
    static let fitsKept = PhoneSearch.KeyedCache<[String: CGFloat]>()
    @State private var openedAt = InventoryModel.shared.revision  // the rows' revision this table opened at
    @State private var hidden: [String: [String]] = [:]  // the hidden labels ticked this run, by `columnsKey`
    /// The table's width, once it first held still 0.3 s (phase 0), then live. Kept outside SwiftUI's state: written
    /// on every frame of a resize, it redrew the whole view each frame (round 2, finding E); only the fitting reads it.
    @State private var liveWidth = LiveWidth()
    /// Whether the table is 1200 points wide or more, for `compactBar`: watched, and changed only as a resize crosses
    /// that line, so it doesn't redraw every frame the way the live width did (round 2, finding E).
    @State private var tableWide = (InventoryDetail.settledWidth ?? 0) >= 1200
    @State private var fittedAt: (key: String, width: CGFloat)?  // the width the table shown was built at (`fitKey`)
    @State private var resets = 0  // Reset Columns pressed: a fresh table, fitted again even with the same columns
    @State private var settling: Task<Void, Never>?
    @State private var editing = false  // Edit Table pressed: a click changes a cell (spec 5.2); set afresh per table
    @State private var selection: Set<Int64> = []
    @State private var sortOrder: [RowOrder] = []
    @State private var form: Int64?
    @State private var newItem: NewItemPick?  // B2-07: Add on the items opens the new-item form
    @State private var askDelete: DeleteAsk?  // B2-07: more than one row asks first
    @State private var removingEmpty = false  // Inventory › Remove Empty Places… (owner, 2026-10-23)
    @State private var scrollTo: Int64?  // an item just added, shown
    @State private var nameNew: Int64?  // a place or category just added: its Name cell opens for typing (Task 2.6)
    @State private var reveal: Int64?  // an item to select once All items is shown (checkpoint 2)
    @ObservedObject private var store = PrepareMeMac.shared.store
    @State private var calculators: CalculatorLinks?  // the daily library's (step 8b)
    @State private var figures: CalculatorFigures?  // the lists job's last count's, in supply.json

    var tableName: String {
        if case .table(let name) = pick { return name }
        return "Inventory"
    }

    /// The toolbar's buttons as icons alone (`pmBarLabel`) while the search box holds words and the table is under
    /// 1200 points wide (a 1200 by 800 window's is about 950), so the box has room to show them. Both are watched
    /// state, so it's right at first draw and on a resize (fix round 2, finding 2).
    var compactBar: Bool { !search.isEmpty && !tableWide }

    /// The check build's PREPAREME_CHECK_EDIT_TABLE=1 opens every table unlocked, for a check that can't click.
    var checkUnlocked: Bool {
        #if PREPAREME_CHECK
        ProcessInfo.processInfo.environment["PREPAREME_CHECK_EDIT_TABLE"] == "1"
        #else
        false
        #endif
    }

    /// One memory of hidden columns and sort for every items' table, one for Locations, one for Categories (spec 5.2).
    var columnsKey: String { searchesItems ? "items" : tableName }

    /// The column that always shows and is the last trimmed: Item, or Name on Locations and Categories.
    var firstLabel: String { searchesItems ? Inventory.Label.item : Inventory.Label.name }

    var hiddenLabels: [String] { hidden[columnsKey] ?? InventoryTableMemory().hidden(columnsKey) }

    /// Every column the Columns menu lists: the items' in `ItemsTableColumns.ordered` order less what the view leaves
    /// out whatever is ticked (a category's Category, a place's Location); another table's in the file's order.
    var tickable: [InventoryColumn] {
        guard searchesItems else { return inventory.table(tableName).columns }
        var leftOut: [String] = []
        if case .view(let view) = pick {
            let bins = if case .location(let id) = view { inventory.bins(in: id).count } else { 0 }
            leftOut = ItemsTableColumns.leftOut(view, binsInside: bins)
        }
        return ItemsTableColumns.tickable(inventory.items.columns, items: true, leftOut: leftOut)
    }

    /// The columns shown: `tickable` less the hidden labels (saved, else `ItemsTableColumns.hiddenAtFirst` for the
    /// items, which holds the views' Calories each, step 8a); a label the file no longer has is ignored. Worked out
    /// once a pass (`body`) and handed down: it had been worked out about 40 times a pass (phase 1 fixes, finding 6).
    var columns: [InventoryColumn] {
        ItemsTableColumns.shownColumns(tickable, hidden: hiddenLabels, first: firstLabel)
    }

    /// Edit Table and Done, the toolbar's button and the Inventory menu's item: the one place the lock is changed but
    /// a new table or view and New Row.
    func editTable() {
        endTyping()
        editing.toggle()
    }

    /// A cell still being typed in is ended, and so saved (its `controlTextDidEndEditing`), before the toolbar or the
    /// menu bar locks or rebuilds the table: neither takes the cursor, so the box would go with its text unsaved (final
    /// review, finding 1). The table's own window, never the key one (Settings may be in front: phase 1 fixes,
    /// finding 1), and the keyboard back on the table once it is up again (finding 11).
    func endTyping() {
        guard let window = PrepareMeMacTabs.shared.window else { return }
        window.makeFirstResponder(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(300))  // a rebuilt table (a tick, Reset Columns) is up by then
            guard window.firstResponder === window, let table = InventoryDetail.itemsTableView(in: window) else { return }
            window.makeFirstResponder(table)
        }
    }

    /// The items' (or a table's) NSTableView in `window`: the one whose first column is "#".
    static func itemsTableView(in window: NSWindow) -> NSTableView? {
        func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
        return window.contentView.map(tables)?.first { $0.tableColumns.first?.title == "#" }
    }

    /// The toolbar's Columns menu: a tick per column (Item, or Name, always shown), then Reset Columns. No Fit Columns
    /// to Window: every opening and every tick is fitted (phase 0).
    @ViewBuilder func columnTicks(_ ticks: [InventoryColumn], shown: Set<String>) -> some View {
        ForEach(ticks, id: \.colId) { column in
            Toggle(header(column), isOn: Binding(get: { shown.contains(column.colId) },
                                                 set: { setShown(column.label, $0) }))
                .disabled(InventoryFile.same(column.label, firstLabel)).pmSwitch()
        }
        Divider()
        Button("Reset Columns") { resetColumns() }
    }

    /// The Columns menu's tick: the table is built afresh (see `.id`), its widths fitted again. Hiding the column the
    /// rows are sorted by drops the sort and its saved copy (phase 1 fixes, finding 5: sorted with no arrow).
    func setShown(_ label: String, _ shown: Bool) {
        endTyping()
        let sortedBy = sortOrder.first.flatMap { first in  // read while its column still shows
            first.key == "#" ? "#" : columns.first { $0.colId == first.key }?.label
        }
        let now = ItemsTableColumns.hiding(label, !shown, in: hiddenLabels)
        hidden[columnsKey] = now
        InventoryTableMemory().setHidden(now, columnsKey)
        if !shown, ItemsTableColumns.dropsSort(hiding: label, sortedBy: sortedBy) {
            sortOrder = []
            InventoryTableMemory().setSort(nil, columnsKey)
        }
    }

    /// Reset Columns: the hidden-at-first list back (none hidden on Locations and Categories), the table built afresh
    /// and fitted to the window as it is now (phase 1 fixes, finding 3).
    func resetColumns() {
        endTyping()
        InventoryTableMemory().forget(columnsKey)
        hidden[columnsKey] = InventoryTableMemory().hidden(columnsKey)
        resets += 1
    }

    /// The saved sort put back as the table opens, when it still names a column shown (review focus 1).
    func savedSortOrder() -> [RowOrder] {
        let columns = columns
        guard let saved = ItemsTableColumns.sort(InventoryTableMemory().sort(columnsKey),
                                                 among: ["#"] + columns.map(\.label)) else { return [] }
        var found: RowOrder
        if saved.label == "#" {
            found = positionOrder()
        } else if let column = columns.first(where: { InventoryFile.same($0.label, saved.label) }) {
            found = CellOrder(column: column, names: inventory.names(for: column)).asRowOrder
        } else {
            return []
        }
        found.order = saved.ascending ? .forward : .reverse
        return [found]
    }

    /// Each sort the table is given is saved; none is never saved, so a view whose columns lack the saved sort's
    /// leaves it for the tables that have it.
    func saveSort(_ now: [RowOrder]) {
        guard let first = now.first,
              let label = first.key == "#" ? "#" : columns.first(where: { $0.colId == first.key })?.label else { return }
        InventoryTableMemory().setSort(SavedSort(label: label, ascending: first.order == .forward), columnsKey)
    }

    /// One table per table shown (see `.id` below); All items and the views stay two, so a switch between them starts
    /// the sort over as before.
    var tableKey: String {
        if case .view = pick { return tableName + " list" }
        return tableName
    }

    /// The table's identity, `.id` below: a fresh table for each table shown, each set of shown columns and each
    /// Reset Columns, fitted to the width it opens at (`fittedAt`).
    func fitKey(_ shown: [InventoryColumn]) -> String {
        tableKey + "|" + shown.map(\.label).joined(separator: "|") + "|\(resets)"
    }

    /// The width a fresh table is fitted to is kept for it: a resize leaves its widths to the table (phase 0).
    func keepFit(_ key: String) {
        guard fittedAt?.key != key, let width = liveWidth.value else { return }
        fittedAt = (key, width)
    }

    var rows: [InventoryRow] {
        let found: [InventoryRow] = switch pick {
        case .table("Inventory"): inventory.items(in: .all, search: search)
        case .table(let name): inventory.rows(name).filter { matches($0, inventory.table(name)) }
        case .view(let view): inventory.items(in: view, search: search)
        case .toBuy, .list: []  // ToBuyView's and ListSheetView's own
        }
        return sortOrder.isEmpty ? found : found.sorted(using: sortOrder)
    }

    func matches(_ row: InventoryRow, _ table: InventoryTable) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = table.columns.map { InventoryValues.shown(row[$0], in: $0, names: inventory.names(for: $0)) }
            .joined(separator: " ")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// A category's or a group's Counts as, for its Calculators line (step 8b); nil for any other pick.
    var group: String? {
        switch pick {
        case .view(.category(let id)): inventory.group(ofCategory: id)
        case .view(.group(let group)): group
        default: nil
        }
    }

    /// The Calculators line above a category's or a group's items (step 8b): its calculators by the names of all its
    /// items (a search doesn't hide one), filled in from the lists job's last count; nil when it has none.
    var calculatorLine: CalculatorLinks.Line? {
        guard let group, let calculators, case .view(let view) = pick else { return nil }
        let names = inventory.items(in: view).map { inventory.name(ofItem: $0) }
        let line = calculators.line(group: group, itemNames: names, figures: figures)
        return line.links.isEmpty ? nil : line
    }

    /// Whether this pick is the items (All items, or a view of them): the other tables never offer an item word.
    var searchesItems: Bool {
        switch pick {
        case .table(let name): name == "Inventory"
        case .view: true
        case .toBuy, .list: false
        }
    }

    /// The items view shown (All items for the items table), for Did you mean and for showing an item.
    var itemsView: Inventory.View {
        if case .view(let view) = pick { return view }
        return .all
    }

    /// Did you mean's words: the items in the view shown, the rows Nothing found is about (checkpoint 2), built again
    /// after each save (InventoryModel.revision) or another view.
    func nearIndexFor(_ inventory: Inventory) -> PhoneSearch.Index {
        nearIndex.value(key: "\(model.revision)|\(itemsView)") { inventory.nearIndex(in: itemsView) }
    }

    /// Each column as wide as its longest text, title included, plus a small gap (owner, 2026-10-31: Category cut
    /// "Power and batteri…"), measured over the whole table so a search or a view doesn't change it. Where the columns
    /// don't fit the table, `startWidths` caps the widest (the inventory fresh look: a column drags narrower, and its
    /// cut text shows whole under the pointer). Worked out once a table, each different value measured once (600 items' every cell, on each save, took about
    /// 80 ms), so a longer value typed since widens its column the next time the table opens.
    func fittedWidths(_ shown: [InventoryColumn]) -> [String: CGFloat] {
        // keyed by the shown columns too, so a column ticked on gets its own width at once (phase 0: 120 until the
        // table changed)
        fits.value(key: "\(openedAt)|" + tableKey + "|" + shown.map(\.label).joined(separator: "|")) {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)  // the table's text, the Mac's 13 points
            func wide(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
            let all = searchesItems ? inventory.itemRows : inventory.rows(tableName)
            return Dictionary(shown.map { column in
                let names = inventory.names(for: column), titles = CellEditor.titles(column, in: tableName)
                let texts = Set(all.map {
                    let text = InventoryValues.shown($0[column], in: column, names: names)
                    return titles ? InventoryLook.title(text) : text  // as the cell shows it
                })
                let widest = texts.reduce(wide(header(column)) + 12) { max($0, wide($1)) }  // + the title's sort arrow
                // shortcut: a value past 360 points is cut, raise it if long names matter
                return (column.colId, min(ceil(widest) + 16, 360))
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Each shown column's starting width: fitted, the widest capped so they fit `width`, Item (or Name) the last
    /// trimmed (`ItemsTableColumns.starts`, owner, 2026-11-17, by click).
    func startWidths(_ fitted: [String: CGFloat], _ shown: [InventoryColumn], width: CGFloat?) -> [String: CGFloat] {
        guard let width else { return fitted }
        return ItemsTableColumns.starts(shown, fitted: fitted.mapValues(Double.init), first: firstLabel,
                                        tableWidth: Double(width)).mapValues { CGFloat($0) }
    }

    /// The width the last table settled at, or was resized to, kept across the tiles' tables.
    static var settledWidth: CGFloat?

    /// Select and show `id`, after Add or Go to that item. One the table leaves out (another place's or category's view,
    /// or a search that doesn't find it) is shown in All items with no search (checkpoint 2): the view is changed
    /// first, and the item selected once All items' table is up (`reveal`, taken when the table changes).
    func show(_ id: Int64) {
        guard case .ready(let current) = model.state else { return }
        let here = current.shows(item: id, in: itemsView, search: search)
        if !here { clearSearch() }
        // only the search hid it: shown here once it is cleared, never moved to All items for that (Task 2.6)
        if here || pick == .table("Inventory") || current.shows(item: id, in: itemsView, search: "") {
            selection = [id]
            scrollTo = id
        } else {
            reveal = id
            model.requestedPick = .table("Inventory")
        }
    }

    var body: some View {
        #if PREPAREME_CHECK
        let _ = InventoryTableCheck.bodies += 1  // a resize's frames must not count here (round 2, finding E)
        #endif
        let shownRows = rows  // worked out once for this pass
        let ticks = tickable, shown = ItemsTableColumns.shownColumns(ticks, hidden: hiddenLabels, first: firstLabel)
        let shownIds = Set(shown.map(\.colId))
        let key = fitKey(shown)
        let width = ItemsTableColumns.fitWidth(key: key, fittedKey: fittedAt?.key, fittedWidth: fittedAt.map { Double($0.width) },
                                               live: liveWidth.value.map(Double.init)).map { CGFloat($0) }
        let fitted = fittedWidths(shown)
        let starts = startWidths(fitted, shown, width: width)
        VStack(spacing: 0) {
            // the counts and chips went to the home page (phase 3, spec 5.1); the Not counted row stays over the rows
            // its Show Them opens, and a tile's table has its slim band (Add Item Here… at its end: no strip of its own
            // with nothing beside it, fix round 1, finding 7), a place's its bins, then a category's Calculators
            if case .view(.leftOut) = pick { InventoryNotCounted(inventory: inventory) }
            if let tile = bandTile {
                slimBand(tile)
                if case .view(.location(let id)) = pick, let bins = InventoryHomeTiles.binsRow(inventory, location: id) {
                    binsRow(bins.owner, bins.bins, shown: id)
                }
                if let line = calculatorLine {
                    CalculatorsLine(line: line, held: store.record.held) { PrepareMeMacTabs.shared.open($0) }
                }
                Divider()
            } else if let line = calculatorLine {
                CalculatorsLine(line: line, held: store.record.held) { PrepareMeMacTabs.shared.open($0) }
                Divider()
            }
            if searchesItems, !PhoneSearch.showsNotes(search: search), shownRows.isEmpty {  // B2-09, as on the phone
                HStack {
                    Text(PhoneSearch.nothingFound).foregroundStyle(PrepareMeColors.text2)
                    if let near = PhoneSearch.nearMiss(search: search, index: { nearIndexFor(inventory) }) {
                        Button(PhoneSearch.didYouMean(near)) { search = near }.pmAction(fullWidth: false)
                    }
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 6)
                Divider()
            }
            if editing, searchesItems {  // a plain bar, the tile's color: teal is never a status (spec 5.2)
                Text(InventoryWords.editingTable)
                    .foregroundStyle(PrepareMeColors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 6)
                    .background(PrepareMeColors.tile)
                Divider()
            }
            Group {
                if width != nil {
                    itemsTable(shownRows, shown: shown, starts: starts, key: key)
                } else {
                    PrepareMeColors.ground  // the table appears once its width has held still, so it opens fitted
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                guard liveWidth.value == nil else {  // a fresh table later fits to it
                    liveWidth.value = width
                    Self.settledWidth = width
                    return
                }
                // a tile's table opening at the width the last table had: the window isn't settling, so no wait (fix
                // round 1, finding 8: each tile builds a new view, and each waited 0.3 s blank)
                if width == Self.settledWidth {
                    liveWidth.value = width
                    keepFit(liveWidth.key ?? key)
                    return
                }
                settling?.cancel()  // the first opening, or a new width: the window may still be settling (phase 0)
                settling = Task {
                    try? await Task.sleep(for: .seconds(0.3))
                    if !Task.isCancelled {
                        liveWidth.value = width
                        Self.settledWidth = width
                        keepFit(liveWidth.key ?? key)  // the key now
                    }
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= 1200 } action: { tableWide = $0 }
        }
        .onChange(of: key, initial: true) { _, now in liveWidth.key = now; keepFit(now) }
        // locked again on every other table or view: Locations and Categories open unlocked
        .onChange(of: pick, initial: true) { editing = InventoryCommands.startsEditing(table: tableName) || checkUnlocked }
        // the selection starts over on every other table or view (phase 1 fixes, finding 2: views share one table);
        // Go to that item's, or a new item's, kept. A row a search or a save takes off screen leaves the selection
        // (round 2, finding F), so Delete, from the menu or the key, takes only rows still shown.
        .onChange(of: shownRows.map(\.id)) { _, ids in
            let kept = InventoryCommands.onScreen(selection, shown: ids)
            if kept != selection { selection = kept }
        }
        .onChange(of: pick) {
            selection = reveal.map { [$0] } ?? []
            if let id = reveal {
                reveal = nil
                Task { scrollTo = id }  // once the new table is up
            }
        }
        // the sort is remembered between launches, one for every items' table (spec 5.2)
        .onChange(of: tableKey, initial: true) { sortOrder = savedSortOrder() }
        .onChange(of: sortOrder) { _, now in saveSort(now) }
        .background(PrepareMeColors.ground)  // the calculators' line and the search's note too
        // the saving spinner in the list's corner, not the toolbar: there, coming and going (or kept hidden), it
        // squeezed the search box to an icon (owner, 2026-10-29)
        .overlay(alignment: .bottomTrailing) {
            if model.saving > 0 { ProgressView().controlSize(.small).padding(12).help("Checking and saving") }
        }
        // A refusal or a failed save, as an alert (a strip above the table made the window lay out taller than itself)
        .alert("Not Saved", isPresented: Binding(get: { model.message != nil && form == nil && newItem == nil },
                                                 set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .alert(InventoryWords.deleteAsk(askDelete?.ids.count ?? 0, table: askDelete?.table ?? tableName),
               isPresented: Binding(get: { askDelete != nil }, set: { if !$0 { askDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let asked = askDelete { deleteNow(asked.ids, in: asked.table) }
                askDelete = nil
            }
            Button("Cancel", role: .cancel) { askDelete = nil }
        }
        .onAppear { takeAdd() }
        .onChange(of: model.addAsked) { takeAdd() }
        .focusedSceneValue(\.inventoryMenu, InventoryMenuActions(
            state: commands, add: { add() }, addByBarcode: { add(byBarcode: true) },
            openForm: { form = selection.first }, editTable: { editTable() },
            columns: ticks.map { column in
                InventoryMenuActions.Tick(label: column.label, title: header(column), shown: shownIds.contains(column.colId),
                                          fixed: InventoryFile.same(column.label, firstLabel))
            },
            setShown: { setShown($0, $1) }, resetColumns: { resetColumns() }, delete: { delete(selection) },
            removeEmptyPlaces: { removingEmpty = true }, printBlankSheet: { BlankSheet.print() },
            printLabels: { printLabels($0) },
            printGrabSheets: { printGrabSheets() }, exportCSV: { exportCSV() }))
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                // each button's word beside its icon (Task 13.1; F39); "…" on each that opens a window first (Apple's
                // Buttons page). Open as Form…, Export CSV… and Delete are the menu bar's and the right-click's (the
                // inventory fresh look, spec 5.2): at most New Item…, Add by Barcode…, Edit Table, Columns and Print
                if commands.canAdd {
                    Button { add() } label: { Label(commands.addTitle, systemImage: "plus") }
                        .help(commands.canAddByBarcode ? "Add an item" : "Add a row")  // the items' form, or a row
                        .pmBarLabel(compact: compactBar)
                }
                if commands.canAddByBarcode {
                    Button { add(byBarcode: true) } label: { Label("Add by Barcode…", systemImage: "barcode.viewfinder") }
                        .help("Scan products one after another with a USB scanner, or type their codes")
                        .pmBarLabel(compact: compactBar)
                }
            }
            // plain information on the teal title bar, never a button: its own item with no capsule (round 2, C)
            if commands.table == "Locations" {  // also in the Inventory menu (spec 5.5)
                ToolbarItem {
                    Button { removingEmpty = true } label: {
                        Label(InventoryWords.removeEmptyTitle + "…", systemImage: "trash")
                    }
                    .help("Remove the places that hold nothing, after a look at the list")
                    .pmBarLabel(compact: compactBar)
                }
            }
            if let sign = commands.lockedSign {
                if #available(macOS 26, *) {
                    ToolbarItem { LockedSign(words: sign, spoken: commands.lockedSignSpoken, compact: compactBar) }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem { LockedSign(words: sign, spoken: commands.lockedSignSpoken, compact: compactBar) }
                }
            }
            ToolbarItemGroup {
                Button { editTable() } label: {
                    Label(commands.editTitle, systemImage: editing ? "checkmark" : "pencil")
                }
                .help(editing ? "Lock the table again" : "Unlock the table to change its cells")
                .pmBarLabel(compact: compactBar)
                Menu {
                    columnTicks(ticks, shown: shownIds)
                } label: {
                    Label("Columns", systemImage: "tablecells")
                }
                .help("Show or hide the table's columns")
                .pmBarLabel(compact: compactBar)
                if commands.canPrintBlankSheet || commands.canPrintLabels || commands.canPrintGrabSheets {
                    Menu {
                        // what each prints is in Print's own tip: a tip on an item in a toolbar menu never shows
                        // (phase 1 fixes, finding 10; round 2, finding D)
                        if commands.canPrintBlankSheet {
                            Button("Print Blank Sheet…") { BlankSheet.print() }
                        }
                        if commands.canPrintLabels {
                            // says what will print: every bin's, or the selected places' (spec 5.5); the sizes are
                            // the Brother label printer's two rolls and the Letter sheet (step 6, part 2)
                            Menu(InventoryWords.labelsItem(selected: commands.labelCount)) {
                                ForEach(BinLabelSize.allCases) { size in
                                    Button(size.title + "…") { printLabels(size) }
                                }
                            }
                        }
                        if commands.canPrintGrabSheets {  // plan phase 7, part 2
                            Button("Print Grab Sheets…") { printGrabSheets() }
                        }
                    } label: {
                        Label("Print", systemImage: "printer")
                    }
                    .help(InventoryWords.printTip(blank: commands.canPrintBlankSheet, labels: commands.canPrintLabels,
                                                  grab: commands.canPrintGrabSheets, selected: commands.labelCount,
                                                  place: commands.placeView))
                    .pmBarLabel(compact: compactBar)
                }
            }
        }
        .sheet(item: Binding(get: { form.map(FormPick.init) }, set: { form = $0?.id })) { picked in
            ItemForm(inventory: inventory, id: picked.id)
        }
        .sheet(isPresented: $removingEmpty) {
            EmptyPlacesSheet(inventory: inventory) { ids in
                Task { await model.apply(.deleteRows(table: "Locations", rows: ids), undo: undo,
                                         name: InventoryWords.removeEmptyTitle) }
            }
        }
        .background {  // its own view: two sheets on one view can fight over which one shows
            Color.clear.sheet(item: $newItem) { picked in
                NewItemForm(inventory: inventory, preset: picked.preset, byBarcode: picked.byBarcode) { id in show(id) }
            }
        }
        .task(id: store.record.held) { calculators = await PrepareMeKeptTabs.calculatorLinks(held: store.record.held) }
        .task(id: pick) { figures = InventoryModel.folder.flatMap { SupplyShares.read(in: $0)?.calculators } }
        #if PREPAREME_CHECK
        // The check build only (screenshots only, 2026-10-21): PREPAREME_CHECK_FORM=newItem or byBarcode opens that form;
        // =first opens the first item's own form in a window wide enough for the whole search box (2026-10-29)
        // PREPAREME_CHECK_FIND_ITEMS: the Inventory view's, which holds the search box since phase 3
        // PREPAREME_CHECK_COLUMNS_LOG=<file in the check home>: once each table is up, what the memory holds and each
        // drawn column's width (the inventory fresh look; a session can't read the check build's settings: phase 0)
        .task(id: width == nil ? "" : key) {
            guard let width, let path = ProcessInfo.processInfo.environment["PREPAREME_CHECK_COLUMNS_LOG"] else {
                return
            }
            try? await Task.sleep(for: .seconds(3))
            InventoryTableCheck.log(to: path, key: columnsKey, settled: width, fitted: fitted, starts: starts,
                                    columns: shown)
        }
        // PREPAREME_CHECK_HIDE_COLUMN=<label>: the Columns menu's untick of that column, 6 s in, for a check that can't
        // click
        .task {
            guard let label = ProcessInfo.processInfo.environment["PREPAREME_CHECK_HIDE_COLUMN"] else { return }
            try? await Task.sleep(for: .seconds(6))
            setShown(label, false)
        }
        // PREPAREME_CHECK_DONE=1: Done pressed 9 s in, as the toolbar's button, after EDIT_ITEM and TYPE have typed into
        // a cell and left the cursor in it (the final review's finding 1)
        .task {
            guard ProcessInfo.processInfo.environment["PREPAREME_CHECK_DONE"] == "1" else { return }
            try? await Task.sleep(for: .seconds(9))
            if editing { editTable() }
        }
        .task(id: pick) { await checkSteps() }
        .task {
            guard tableName == "Inventory", let form = ProcessInfo.processInfo.environment["PREPAREME_CHECK_FORM"] else {
                return
            }
            try? await Task.sleep(for: .seconds(1))
            if form == "first" {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    window.setFrame(NSRect(origin: window.frame.origin, size: CGSize(width: 1500, height: 900)), display: true)
                }
                try? await Task.sleep(for: .seconds(2))
                self.form = rows.first?.id
            } else if form == "emptyPlaces" { removingEmpty = true } else { add(byBarcode: form == "byBarcode") }
        }
        #endif
    }

    #if PREPAREME_CHECK
    /// The check build's steps for a check that can't click (phase 1 fixes, findings 1, 12 and 13), each once a launch,
    /// on the first table shown (PREPAREME_CHECK_INVENTORY_PICK's, taken by the Inventory view since phase 3):
    /// PREPAREME_CHECK_RETURN=1 selects the first row and presses Return on the table 4 s in;
    /// PREPAREME_CHECK_NEW_ROW=1 presses New Row 5 s in; PREPAREME_CHECK_TOOLBAR_MENUS=<file in the check home> writes
    /// the toolbar's items and their menus' items, with each tip, 6 s in; PREPAREME_CHECK_THEN, 9 s in, after EDIT_ITEM
    /// and TYPE have left the cursor in a cell: steps a second apart, split by commas, each pick (a category's view),
    /// hide:<label> (its Columns untick), show:<label> (its tick), sort:<label>, select (the first row), bin (a bin
    /// added to the place shown) or quit; NOTES then gets the selection and the sort. Run per pick (`.task(id: pick)`), since a task keeps the view
    /// it started with: the starting pick first, then the rest on the table it shows.
    func checkSteps() async {
        let env = ProcessInfo.processInfo.environment
        guard !InventoryTableCheck.ran else { return }
        InventoryTableCheck.ran = true
        try? await Task.sleep(for: .seconds(2))
        if env["PREPAREME_CHECK_RETURN"] == "1", let window = PrepareMeMacTabs.shared.window,
           let table = Self.itemsTableView(in: window), let first = rows.first {
            selection = [first.id]
            window.makeFirstResponder(table)
            try? await Task.sleep(for: .milliseconds(500))
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let key = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: "\r",
                                              charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                    NSApp.postEvent(key, atStart: false)
                }
            }
        }
        try? await Task.sleep(for: .seconds(1))
        if env["PREPAREME_CHECK_NEW_ROW"] == "1" { add() }
        try? await Task.sleep(for: .seconds(1))
        if let path = env["PREPAREME_CHECK_TOOLBAR_MENUS"], let toolbar = PrepareMeMacTabs.shared.window?.toolbar {
            let lines = toolbar.items.flatMap { item -> [String] in
                let tip = item.toolTip.map { " — tip: \($0)" } ?? ""
                return ["\(item.label.isEmpty ? item.itemIdentifier.rawValue : item.label)\(tip)"]
                    + PrepareMeMacTabs.menuLines((item as? NSMenuToolbarItem)?.menu ?? item.menuFormRepresentation?.submenu,
                                                 depth: 1)
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        try? await Task.sleep(for: .seconds(3))
        guard let then = env["PREPAREME_CHECK_THEN"] else { return }
        let notes = env["PREPAREME_CHECK_NOTES"]
        let detail = self  // its @State reads stay live after a pick; its `pick` doesn't
        Task {  // not this task: a pick step ends it, and the steps after must still wait their second
            for step in then.split(separator: ",").map(String.init) {
                if let notes { InventoryTableCheck.note("THEN \(step)", to: notes) }
                detail.checkStep(step)
                try? await Task.sleep(for: .seconds(1))
            }
            try? await Task.sleep(for: .seconds(1))
            if let notes {
                InventoryTableCheck.note("after THEN: selection \(detail.selection.count), sort "
                                         + (detail.sortOrder.first?.key ?? "none"), to: notes)
            }
        }
    }

    func checkStep(_ step: String) {
        if step == "pick", let column = inventory.items.column(Inventory.Label.category),
           let category = inventory.names(for: column).keys.min() {
            model.requestedPick = .view(.category(category))
        } else if step.hasPrefix("hide:") {
            setShown(String(step.dropFirst("hide:".count)), false)
        } else if step.hasPrefix("show:") {  // its Columns tick (phase 4: Year, hidden at first)
            setShown(String(step.dropFirst("show:".count)), true)
        } else if step.hasPrefix("sort:"), let column = columns.first(where: { InventoryFile.same($0.label, String(step.dropFirst(5))) }) {
            sortOrder = [order(column)]
        } else if step == "select", let first = rows.first {
            selection = [first.id]
        } else if step == "bin", case .view(.location(let place)) = pick {
            let table = inventory.locations
            var values: [String: SQLValue] = [:]
            if let column = table.column(Inventory.Label.name) { values[column.colId] = .text("Check bin") }
            if let column = table.column(Inventory.Label.keptIn) { values[column.colId] = .int(place) }
            Task { _ = await model.apply(.add(table: "Locations", values: values), undo: nil, name: "New Place") }
        } else if step.hasPrefix("width:"), let width = Double(step.dropFirst(6)),
                  let window = PrepareMeMacTabs.shared.window {
            window.setFrame(NSRect(origin: window.frame.origin, size: CGSize(width: width, height: window.frame.height)),
                            display: true)
        } else if step.hasPrefix("drag:"), let width = Double(step.dropFirst(5)), let window = PrepareMeMacTabs.shared.window {
            // a live resize, 20 frames: the body's count before and after (round 2, finding E)
            let notes = ProcessInfo.processInfo.environment["PREPAREME_CHECK_NOTES"], from = window.frame.width
            let before = InventoryTableCheck.bodies
            Task {
                for frame in 1...20 {
                    let now = from + (width - from) * Double(frame) / 20
                    window.setFrame(NSRect(origin: window.frame.origin, size: CGSize(width: now, height: window.frame.height)),
                                    display: true)
                    try? await Task.sleep(for: .milliseconds(30))
                }
                try? await Task.sleep(for: .milliseconds(300))
                if let notes {
                    InventoryTableCheck.note("drag \(Int(from)) to \(Int(width)) in 20 frames: body worked out "
                                             + "\(InventoryTableCheck.bodies - before) times", to: notes)
                }
            }
        } else if step == "edit" {
            editTable()
        } else if step == "reset" {
            resetColumns()
        } else if step == "ok" {
            model.message = nil  // the Not saved alert's OK
        } else if step == "focus", let window = PrepareMeMacTabs.shared.window,
                  let notes = ProcessInfo.processInfo.environment["PREPAREME_CHECK_NOTES"] {
            // where the keyboard is (round 2, finding G: back on the table after Edit Table, Done, a tick, Reset)
            let responder = window.firstResponder
            InventoryTableCheck.note("focus: \(responder.map { String(describing: type(of: $0)) } ?? "none"), on the table "
                                     + "\(responder != nil && responder === Self.itemsTableView(in: window))", to: notes)
        } else if step == "quit" {
            // as Cmd-Q arrives, from the run loop, never from inside this task
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }
    #endif

    /// The table itself, apart from `body` so the compiler can check it in reasonable time.
    func itemsTable(_ shownRows: [InventoryRow], shown: [InventoryColumn], starts: [String: CGFloat],
                    key: String) -> some View {
        ScrollViewReader { proxy in
            Table(shownRows, selection: $selection, sortOrder: $sortOrder) {
                // The row's number in the file's own order, as the lists job and the ID check's messages name it
                TableColumn("#", sortUsing: positionOrder()) { row in
                    // verbatim: a number in Text's interpolation took a thousands comma, "1,0…" in the column (F39)
                    Text(verbatim: String(row.position)).foregroundStyle(PrepareMeColors.text2).monospacedDigit()
                }
                .width(min: 40, ideal: 48, max: 72)  // four digits whole (Task 13.1; F39)
                TableColumnForEach(shown) { column in
                    TableColumn(header(column), sortUsing: order(column)) { row in cell(column, row) }
                    .width(min: 40, ideal: starts[column.colId] ?? 120)  // drags narrower; cut text ends in "…"
                }
            }
            .pmScreen()  // the pages' ground behind the rows (owner, 2026-10-22: the Mac's inventory too)
            .alternatingRowBackgrounds(.disabled)
            // A fresh table for each table shown: SwiftUI's Table crashes when its set of columns changes under it
            // (TableColumnForEach, macOS 27), so one table never becomes another; a tick in Columns or Reset Columns
            // builds a fresh table too, its widths fitted again to the width it opens at (`fitKey`; phase 1 fixes,
            // finding 3). The selection starts over on every pick, in `body`
            .id(key)
            .contextMenu(forSelectionType: Int64.self) { picked in
                if picked.count == 1, let id = picked.first, tableName == "Inventory" {
                    Button("Open as Form…") { form = id }  // the menu's name (look 3, change 20)
                }
                if !picked.isEmpty {
                    if picked.count == 1, tableName == "Inventory" { Divider() }
                    // several rows ask first, so "…"; title capitals, "Delete 3 Items…" (docs/design/menus.md)
                    PMMenuDelete(picked.count == 1 ? "Delete" : InventoryWords.deleteMenu(picked.count, table: tableName).capitalized + "…") {
                        delete(picked)
                    }
                }
            } primaryAction: { picked in
                if picked.count == 1, tableName == "Inventory" { form = picked.first }
            }
            // the Delete key on the selected rows, as Inventory › Delete, only once Edit Table is pressed (the Apple
            // guidelines plan, phase 2; spec 5.2); a box being typed in keeps its own Delete
            .onDeleteCommand { if commands.deleteKeyWorks { delete(selection) } }
            .onChange(of: selection) { _, now in if let nameNew, now != [nameNew] { self.nameNew = nil } }
            .onChange(of: scrollTo) { _, id in  // B2-07: a new item had landed out of sight at the bottom
                guard let id else { return }
                proxy.scrollTo(id)
                scrollTo = nil
            }
        }
    }

    /// One cell, and its column's order, apart from the table so the compiler checks each in reasonable time
    func cell(_ column: InventoryColumn, _ row: InventoryRow) -> CellEditor {
        CellEditor(inventory: inventory, tableName: tableName, column: column, row: row,
                   inTable: true,
                   startsEditing: nameNew == row.id && InventoryFile.same(column.label, "Name"), locked: !editing)
    }

    func order(_ column: InventoryColumn) -> RowOrder {
        CellOrder(column: column, names: inventory.names(for: column)).asRowOrder
    }

    var title: String {
        switch pick {
        case .table("Inventory"): "All Items"
        case .table(let name): name
        case .view(.expiringSoon): "Expiring Soon"
        case .view(.grab(let tier)): tier == 1 ? "Grab in 10 Minutes" : "Grab in an Hour"
        case .view(.privateOnly): "Private"
        case .view(.insured):
            // title capitals, as every window title (design 5.5; phase 1 fixes, finding 8)
            "Insurance Record: \(inventory.insuredTotal.formatted(.currency(code: "USD"))) in "
                + "\(rows.count) Item\(rows.count == 1 ? "" : "s")"
        case .view(.location(let id)): InventoryLook.title(inventory.name(ofLocation: id))  // as the sidebar's row
        case .view(.category(let id)):
            inventory.items.column(Inventory.Label.category).flatMap { inventory.names(for: $0)[id] }
                .map(InventoryLook.title) ?? "Category"
        case .view(.group(let group)): InventoryLook.title(group)  // as a category's title (fix round 1)
        case .view(.guide(let guide, _)): "\(GuideLinks.houseTitle): \(guide)"
        case .view(.leftOut): SupplyShares.leftOutTitle
        case .view(.all): "All Items"
        case .toBuy: "To Buy"
        case .list(let sheet): ListsLayout.shownTitle(sheet)
        }
    }

    func header(_ column: InventoryColumn) -> String {
        InventoryFile.same(column.label, Inventory.Label.privateRow) ? "Private" : column.label
    }

    /// A new row. On the items (B2-07, beta run 2), the new-item form, kept only once it has a name; in a view of one
    /// location or category, it starts there. On the other tables, a blank row at once, as before.
    func add(byBarcode: Bool = false) {
        var values: [String: SQLValue] = [:]
        if tableName == "Inventory" {
            if case .view(.location(let id)) = pick, let column = inventory.items.column(Inventory.Label.location) {
                values[column.colId] = .int(id)
            }
            if case .view(.category(let id)) = pick, let column = inventory.items.column(Inventory.Label.category) {
                values[column.colId] = .int(id)
            }
            newItem = NewItemPick(preset: values, byBarcode: byBarcode)
            return
        }
        editing = true  // a new place's or category's Name opens for typing at once
        Task {
            if let id = await model.apply(.add(table: tableName, values: values), undo: undo, name: "Add") {
                selection = [id]
                scrollTo = id  // the new row in sight, its Name being typed (Task 2.6)
                nameNew = id
                // shortcut: a second for the row to come into sight, then a scroll back to it never reopens its Name
                try? await Task.sleep(for: .seconds(1))
                if nameNew == id { nameNew = nil }
            }
        }
    }

    /// One row goes at once, as before (Edit › Undo brings it back); more than one asks first (B2-07).
    func delete(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        if ids.count > 1 { askDelete = DeleteAsk(table: tableName, ids: ids) } else { deleteNow(ids, in: tableName) }
    }

    /// The rows the question is about, with their table as it was when asked (R4.1's review): the answer deletes those
    /// rows from that table, whatever is shown by then.
    struct DeleteAsk {
        let table: String
        let ids: Set<Int64>
    }

    /// Several rows are one change, all or none, so one Edit › Undo puts them all back (B2-07: each had been its own).
    func deleteNow(_ ids: Set<Int64>, in name: String) {
        let change: InventoryChange = ids.count == 1 ? .delete(table: name, row: ids.first!)
            : .deleteRows(table: name, rows: ids.sorted())
        Task {
            if await model.apply(change, undo: undo, name: "Delete") != nil { selection = [] }
        }
    }

    func exportCSV() { Self.exportCSV(inventory) }

    /// Export CSV…: every table, whatever shows (the home page's too: the owner's choice A, 2026-11-18).
    static func exportCSV(_ inventory: Inventory) {
        let model = InventoryModel.shared
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save CSV files here"
        panel.message = "Each table is saved as its own CSV file. Private rows, prices and serial numbers are included: "
            + "keep these files on this Mac or in Household Private, never in a shared folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            for (name, text) in InventoryCSV.export(inventory) {
                try Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
            }
            model.message = nil
        } catch {
            model.message = "The CSV files weren't saved: that folder may already hold files of the same names."
        }
    }
}

extension InventoryDetail {
    /// Bin labels (slice 6): the selected places, or with none selected every bin (a place kept in another; every
    /// place when none is), in the order they show.
    var isGrabView: Bool {
        if case .view(.grab) = pick { return true }
        return false
    }

    /// What the toolbar and the Inventory menu allow here (the Apple guidelines plan, phase 2).
    var commands: InventoryCommands {
        InventoryCommands(table: tableName, grabView: isGrabView, selected: selection.count, editing: editing,
                          placeView: placeShown != nil)
    }

    /// The place, bin or vehicle whose table this is (phase 3: it prints its own label and grab sheet), else nil.
    var placeShown: Int64? {
        if case .view(.location(let id)) = pick { return id }
        return nil
    }

    /// A category's, place's, bin's or vehicle's tile, for its table's slim band; nil on any other table.
    var bandTile: InventoryTile? {
        if case .view(let view) = pick { return InventoryHomeTiles.band(inventory, view: view) }
        return nil
    }

    /// The slim band over a tile's table (phase 3, board 2): its emoji, its name, what it holds, and Add Item Here… at
    /// its end, in the band's own colors.
    func slimBand(_ tile: InventoryTile) -> some View {
        // Add Item Here…'s tooltip says what it does on this band: a category's sets the category, a place's the place
        let isCategoryBand = if case .view(.category) = pick { true } else { false }
        return PMBand {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(tile.emoji) \(tile.name)").font(.pmTitle).accessibilityLabel(tile.name)
                Text(tile.detail)
                Spacer(minLength: 12)
                Button("Add Item Here…") { add() }.pmAction(fullWidth: false)
                    .environment(\.colorScheme, .dark)  // on the band's teal, as the phones' `pmOnBand`
                    .help(isCategoryBand ? "A new item in this category" : "A new item, kept here")
            }
        }
        .card()
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    /// A place's bins as a row of buttons over its table (spec 5.1, my call there): the whole place first, then each
    /// bin narrowing the table to it; the one shown marked, as the category chips were: in the tint (red night turns
    /// it to ink, where teal reads 1.6:1 on black), with an outline and read as selected, so not by color alone.
    func binsRow(_ owner: Int64, _ bins: [InventoryTile], shown: Int64) -> some View {
        let all = InventoryTile(id: owner, emoji: "", name: InventoryHomeTiles.allOf(InventoryHomeTiles.band(
            inventory, view: .location(owner))?.name ?? ""), detail: "")
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach([all] + bins) { bin in
                    let on = bin.id == shown
                    Button { model.requestedPick = .view(.location(bin.id)) } label: {
                        Text(bin.name)
                            .fontWeight(on ? .semibold : .regular)
                            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(PrepareMeColors.ink))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(on ? PrepareMeColors.tealTint : PrepareMeColors.tile, in: Capsule())
                            .overlay {  // a shape as well as a color, so the red night screen marks it too
                                if on { Capsule().strokeBorder(.tint, lineWidth: 1.5) }
                            }
                            .contentShape(Capsule())  // a click on its rim counts
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .help(bin.detail)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }

    /// The home page's New Item… or Add by Barcode…, once this table (All Items) is up.
    func takeAdd() {
        guard let byBarcode = model.addAsked, tableName == "Inventory" else { return }
        model.addAsked = nil
        add(byBarcode: byBarcode)
    }

    func printGrabSheets() { Self.printGrabSheets(inventory, picked: placesPicked) }

    /// The grab sheets (plan phase 7, part 2): the bins as the labels take them, or the picked places (the home page
    /// picks none).
    static func printGrabSheets(_ inventory: Inventory, picked placesPicked: Set<Int64>) {
        if !placesPicked.isEmpty {  // the selected places, or the place shown: vehicles get a vehicle's page
            let picked = inventory.locationRows.map(\.id).filter(placesPicked.contains)
            GrabSheets.print(GrabSheets.sheets(inventory, bins: picked.filter { !inventory.isVehicle($0) },
                                               vehicles: picked.filter(inventory.isVehicle)))
        } else {
            GrabSheets.print(GrabSheets.sheets(inventory,
                                               bins: inventory.locationRows.filter { inventory.keptIn($0.id) != nil }
                                                   .map(\.id)))
        }
    }

    /// The places Print acts on: the place, bin or vehicle whose table this is (phase 3), else the rows selected on
    /// Locations; empty for every bin. Never the items selected on an items' table.
    var placesPicked: Set<Int64> {
        if let placeShown { return [placeShown] }
        return tableName == "Locations" ? selection : []
    }

    func printLabels(_ size: BinLabelSize) { Self.printLabels(inventory, picked: placesPicked, size: size) }

    /// The picked places' labels, or with none every bin's (every place's while there are no bins).
    static func printLabels(_ inventory: Inventory, picked placesPicked: Set<Int64>, size: BinLabelSize) {
        let ids = placesPicked.isEmpty
            ? { let bins = inventory.locationRows.filter { inventory.keptIn($0.id) != nil }
                return (bins.isEmpty ? inventory.locationRows : bins).map(\.id) }()
            : inventory.locationRows.map(\.id).filter(placesPicked.contains)
        BinLabels.print(BinLabels.labels(inventory, ids: ids), size: size)
    }
}

/// The new-item form's start (B2-07): the place or category of the view it was opened from.
extension Inventory {
    /// The entry redesign's Food rule for an item (or a new item's draft): its category is Food or it has calories.
    func showsFood(_ row: InventoryRow, scannedFood: Bool = false) -> Bool {
        let group = items.column(Label.category).flatMap { row[$0].whole }.flatMap { group(ofCategory: $0) }
        let calories = items.column(Label.caloriesEach).map { row[$0].number == 0 ? "" : InventoryValues.plain(row[$0]) }
        return ItemFieldGroup.showsFood(group: group, calories: calories ?? "", scannedFood: scannedFood)
    }

    /// Whether a field shows on an item's form (entry fixes plan, phase 3; ItemFieldGroup.shows): by its category's
    /// group, its Unit and its name (`item`, a new item's typed name, else the row's own).
    func shows(_ column: InventoryColumn, in row: InventoryRow, item: String? = nil) -> Bool {
        let group = items.column(Label.category).flatMap { row[$0].whole }.flatMap { group(ofCategory: $0) }
        let unit = items.column("Unit").map { InventoryValues.plain(row[$0]) } ?? ""
        let filled = !InventoryValues.plain(row[column]).isEmpty && row[column].number != 0  // Grist's blank number is 0
        return ItemFieldGroup.shows(column.label, group: group, unit: unit, item: item ?? name(ofItem: row),
                                    filled: filled)
    }

    /// Whether More details opens for an item: one of its cells holds something.
    func moreFilled(_ row: InventoryRow) -> Bool {
        ItemFieldGroup.opensMore(items.columns.filter { ItemFieldGroup.of($0.label) == .more }
            .map { row[$0].number == 0 && row[$0] != .null ? "" : InventoryValues.plain(row[$0]) })
    }
}

struct NewItemPick: Identifiable {
    let id = UUID()
    let preset: [String: SQLValue]
    var byBarcode = false
}

struct FormPick: Identifiable {
    let id: Int64
}

/// The check build's look at the inventory's tables (the memory itself is `InventoryTableMemory`, in PrepareMeShared).
#if PREPAREME_CHECK
@MainActor
enum InventoryTableCheck {
    static var ran = false, picked = false  // `InventoryDetail.checkSteps`, once a launch
    static var bodies = 0  // the detail view's body, worked out this many times

    /// Every pop-up button under `view` (a SwiftUI Menu's arrow is one), for PREPAREME_CHECK_CHOICES.
    static func popUps(in view: NSView?) -> [NSPopUpButton] {
        guard let view else { return [] }
        if let button = view as? NSPopUpButton { return [button] }
        return view.subviews.flatMap { popUps(in: $0) }
    }

    /// One line added to `path` (a file in the check home), for a check that can't read the screen's state.
    static func note(_ line: String, to path: String) {
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + "\(Date()) \(line)\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// PREPAREME_CHECK_COLUMNS_LOG: the keys' values, the table's widths and each drawn column's, added to `path`.
    static func log(to path: String, key: String, settled: CGFloat, fitted: [String: CGFloat],
                    starts: [String: CGFloat], columns: [InventoryColumn]) {
        let columnsPrefix = InventoryTableMemory.columnsPrefix, sortPrefix = InventoryTableMemory.sortPrefix
        let table = PrepareMeMacTabs.shared.window.flatMap(InventoryDetail.itemsTableView(in:))
        var lines = ["--- \(Date()) key \(key)",
                     "columns: \(UserDefaults.standard.string(forKey: columnsPrefix + key) ?? "(none)")",
                     "sort: \(UserDefaults.standard.string(forKey: sortPrefix + key) ?? "(none)")",
                     "fitted to width: \(settled)",
                     "visible width: \(table?.enclosingScrollView?.contentView.bounds.width ?? -1)",
                     "window width: \(table?.window?.frame.width ?? -1)"]
        for drawn in table?.tableColumns ?? [] {
            let column = columns.first { $0.label == drawn.title || (drawn.title == "Private" && InventoryFile.same($0.label, Inventory.Label.privateRow)) }
            let id = column?.colId ?? ""
            lines.append("\(drawn.title)\tdrawn \(drawn.width)\tstart \(starts[id] ?? -1)\tfitted \(fitted[id] ?? -1)")
        }
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif

/// The table's sort: by the row's number, or by one column (CellOrder).
struct RowOrder: SortComparator {
    let compareRows: @Sendable (InventoryRow, InventoryRow) -> ComparisonResult
    let key: String
    var order: SortOrder = .forward

    func compare(_ a: InventoryRow, _ b: InventoryRow) -> ComparisonResult {
        let found = compareRows(a, b)
        if order == .forward { return found }
        return found == .orderedAscending ? .orderedDescending : found == .orderedDescending ? .orderedAscending : .orderedSame
    }

    static func == (a: RowOrder, b: RowOrder) -> Bool { a.key == b.key && a.order == b.order }
    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(order == .forward)
    }
}

func positionOrder() -> RowOrder {
    RowOrder(compareRows: { a, b in a.position == b.position ? .orderedSame : a.position < b.position ? .orderedAscending
                            : .orderedDescending }, key: "#")
}

/// Sorting by one column as the editor shows it, numbers by value and text in the Finder's order.
struct CellOrder: SortComparator {
    let column: InventoryColumn
    let names: [Int64: String]
    var order: SortOrder = .forward

    func compare(_ a: InventoryRow, _ b: InventoryRow) -> ComparisonResult {
        let found: ComparisonResult
        switch column.kind {
        case .numeric, .int, .date, .bool:
            let x = a[column].number ?? -.infinity, y = b[column].number ?? -.infinity
            found = x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending
        default:
            let x = InventoryValues.shown(a[column], in: column, names: names)
            let y = InventoryValues.shown(b[column], in: column, names: names)
            let xn = InventoryValues.parseNumber(x), yn = InventoryValues.parseNumber(y)
            if let xn, let yn {
                found = xn == yn ? .orderedSame : xn < yn ? .orderedAscending : .orderedDescending
            } else {
                found = x.localizedStandardCompare(y)
            }
        }
        if order == .forward { return found }
        return found == .orderedAscending ? .orderedDescending : found == .orderedDescending ? .orderedAscending : .orderedSame
    }

    var asRowOrder: RowOrder {
        let order = self
        return RowOrder(compareRows: { order.compare($0, $1) }, key: column.colId)
    }

    static func == (a: CellOrder, b: CellOrder) -> Bool { a.column == b.column && a.order == b.order }
    func hash(into hasher: inout Hasher) {
        hasher.combine(column)
        hasher.combine(order == .forward)
    }
}

/// One cell, edited in place: text and numbers typed (kept on Return or on leaving the cell), a reference picked from
/// its table's names, a tick ticked. A column the editor doesn't change is shown greyed.
/// A table cell's text box, AppKit's own with its text scrolling (owner, 2026-10-31): SwiftUI's TextField in a table cell
/// never scrolls (its field is set unscrollable, and setting it back, before or after the cursor arrives, didn't hold), so
/// a name past the column's edge was cut there, the cursor going out of sight and the name's end out of reach.
/// The sign beside Edit Table while the items are locked (spec 5.2): the band's own text color on the teal title bar
/// (PMDarkTitlebar, both looks), dimmed with the rest of the toolbar when the window isn't the one in front.
private struct LockedSign: View {
    let words: String
    let spoken: String
    var compact = false  // the lock alone, as the buttons' icons while a search's words need the room
    @Environment(\.controlActiveState) private var active

    var body: some View {
        Label(words, systemImage: "lock")
            .pmBarLabel(compact: compact)
            .help(words)  // the lock alone says nothing while a search's words need the room (fix round 2, finding 3)
            .foregroundStyle(PrepareMeColors.bandText)
            .opacity(active == .inactive ? 0.5 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
    }
}

extension View {
    /// A toolbar button's word beside its icon (Task 13.1; F39), or its icon alone (its tip still says what it does)
    /// while the search box holds words in a narrow window: at 1200 points the buttons left the box a clipped stub and
    /// the words couldn't be seen (fix round 1, finding 2). One style either way, so no view is swapped for another as
    /// the first letter is typed (a rebuilt toolbar could take the cursor from the search box: fix round 2, finding 1).
    func pmBarLabel(compact: Bool) -> some View {
        labelStyle(PMBarLabelStyle(titleShown: !compact))
    }
}

/// A toolbar label's icon and its word, the word kept in place but narrowed to nothing while hidden, so showing and
/// hiding it changes sizes, never which views are there.
struct PMBarLabelStyle: LabelStyle {
    let titleShown: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: titleShown ? 4 : 0) {
            configuration.icon
            configuration.title
                .fixedSize()
                .frame(width: titleShown ? nil : 0, alignment: .leading)
                .clipped()
                .opacity(titleShown ? 1 : 0)
        }
    }
}

/// The table's live width, read only by the fitting: changing it redraws nothing (round 2, finding E).
final class LiveWidth {
    var value: CGFloat?
    /// The fit key of the table shown now: the first settling, 0.3 s late, fits that table, not the one it began on.
    var key: String?
}

private struct TableTextField: NSViewRepresentable {
    @Binding var text: String
    let label: String
    let left: () -> Void  // Return, or the cursor gone elsewhere
    /// The box torn down with its typing never ended (a pick changed, the shown columns changed, a bin added under
    /// the view): saves the text it holds. Built from values, never the cell's state, which is gone by then (phase 1
    /// fixes, finding 1: there was no save on this path).
    let torn: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)  // VoiceOver says which field (entry fixes, phase 4)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }  // clicked to edit: type at once
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.delegate = nil  // an end of typing after this would save again, from a cell already gone (round 2, B)
        guard !coordinator.ended else { return }  // Return or leaving the box already saved it
        coordinator.ended = true
        coordinator.parent.torn(field.stringValue)
        #if PREPAREME_CHECK
        if let notes = ProcessInfo.processInfo.environment["PREPAREME_CHECK_NOTES"] {
            InventoryTableCheck.note("cell torn down while open, its text passed on: \(field.stringValue)", to: notes)
        }
        #endif
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TableTextField
        var ended = false
        init(_ parent: TableTextField) { self.parent = parent }
        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { parent.text = field.stringValue }
        }
        func controlTextDidEndEditing(_ note: Notification) {
            guard !ended else { return }  // torn down first: its text was passed on then
            ended = true
            parent.left()
        }
    }
}

struct CellEditor: View {
    let inventory: Inventory
    let tableName: String
    let column: InventoryColumn
    let row: InventoryRow
    /// The new-item form's (B2-07): a value kept in its draft instead of written, nil for a row in the file.
    var keep: ((SQLValue) -> Void)?
    /// In a form, not the table (the entry redesign): a pick is a pick button, a typed cell an outlined box.
    var boxed = false
    /// The item form's: told of each value this cell saved, so its Cancel puts back only those (the audit, finding 1).
    var saved: ((String, SQLValue) -> Void)?
    /// In the table: plain text until clicked (owner, 2026-10-22). A live edit box or pick list in every cell made each
    /// table switch freeze about half a second while the Mac built and sized them all.
    var inTable = false
    /// A place or category just added in the table: its Name opens for typing at once (Task 2.6).
    var startsEditing = false
    /// The table's lock (the inventory fresh look, spec 5.2): plain text that a click only selects, until Edit Table.
    var locked = false
    /// A form's: told of each keystroke in this box (column id, text), for its what's-missing line (Task 2.6).
    var typing: ((String, String) -> Void)?
    @State private var editing = false
    // not observed: a cell only calls the model, and observing it redrew and re-measured every cell on each change
    private var model: InventoryModel { .shared }
    @Environment(\.undoManager) private var undo
    @State private var draft = ""
    @State private var pending: String?  // a value sent to be saved and not answered yet (review 8)
    @State private var refused: String?  // what a refusal left typed, kept to fix, never resent as is (Task 1.7)
    @State private var reopened = false  // the table cell opened again with it, after the alert (Task 1.7)
    @FocusState private var focused: Bool

    var shown: String {
        let text = InventoryValues.shown(row[column], in: column, names: names)
        return Self.titles(column, in: tableName) ? InventoryLook.title(text) : text
    }
    /// A category's or a place's name in title case on the items' table and forms, as the sidebar shows it (owner,
    /// 2026-10-31, by click: everywhere it is read); the Categories and Locations tables, where they are named, and the
    /// CSV files keep it as typed (`InventoryLook`).
    static func titles(_ column: InventoryColumn, in tableName: String) -> Bool {
        guard tableName == "Inventory", case .reference(let target) = column.kind else { return false }
        return target == "Locations" || target == "Categories"
    }
    /// A form's Unit, Brand or Model, being typed: its pick list and the earlier entries that start with what's typed
    /// (owner, 2026-10-30). Brand's pick list never gains a typed brand, so the rows are read too.
    var suggestions: [String] {
        guard boxed, focused, tableName == "Inventory", PhoneEditRules.typedAsIs(column.label) else { return [] }
        return PhoneEditRules.suggestions(typed: draft, from: column.choices
                                          + inventory.itemRows.map { InventoryValues.plain($0[column]) })
    }
    var names: [Int64: String] { inventory.names(for: column) }

    var body: some View {
        Group {
            if inTable, locked, column.editable {  // a click selects the row, a double-click or Return opens the form
                Text(column.kind == .bool ? (row[column].whole == 1 ? "✓" : " ") : (shown.isEmpty ? " " : shown))
                    .lineLimit(1)
                    .help(column.kind == .bool ? "" : shown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(column.label)
                    .accessibilityValue(column.kind == .bool ? (row[column].whole == 1 ? "Yes" : "No") : shown)
            } else if inTable, column.editable, !editing {
                Button {
                    if column.kind == .bool { save(.int(row[column].whole == 1 ? 0 : 1)) } else { editing = true }
                } label: {
                    Text(column.kind == .bool ? (row[column].whole == 1 ? "✓" : " ") : (shown.isEmpty ? " " : shown))
                        .lineLimit(1)
                        .help(column.kind == .bool ? "" : shown)  // a cut value shows whole under the pointer
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(column.label)
                .accessibilityValue(column.kind == .bool ? (row[column].whole == 1 ? "Yes" : "No") : shown)
            } else {
                editor
            }
        }
        .onAppear { if startsEditing, column.editable, !locked { editing = true } }
        #if PREPAREME_CHECK
        // the check build only: PREPAREME_CHECK_EDIT_ITEM=<row #> opens that row's Item for typing, 4 s in (2026-10-31),
        // or PREPAREME_CHECK_EDIT_COLUMN's (Kept in on Locations: its pick list)
        .task {
            let env = ProcessInfo.processInfo.environment
            guard inTable, InventoryFile.same(column.label, env["PREPAREME_CHECK_EDIT_COLUMN"] ?? Inventory.Label.item),
                  env["PREPAREME_CHECK_EDIT_ITEM"] == String(row.position) else { return }
            try? await Task.sleep(for: .seconds(4))
            if !locked { editing = true }
            // PREPAREME_CHECK_NOTES=<file in the check home>: whether the cell opened, for the locked table's check
            if let notes = ProcessInfo.processInfo.environment["PREPAREME_CHECK_NOTES"] {
                InventoryTableCheck.note("EDIT_ITEM row \(row.position): \(locked ? "locked, not opened" : "opened")",
                                         to: notes)
            }
        }
        #endif
        .onChange(of: startsEditing) { _, now in if now, column.editable, !locked { editing = true } }
        // Done, or another table, locks it. A box being typed in was ended first (`endTyping`), or saves as it goes
        // (`TableTextField.dismantleNSView`); a refusal kept to fix is let go, never shown at the next opening (phase 1
        // fixes, finding 4)
        .onChange(of: locked) { _, now in
            #if PREPAREME_CHECK
            if now, refused != nil, let notes = ProcessInfo.processInfo.environment["PREPAREME_CHECK_NOTES"] {
                InventoryTableCheck.note("locked: the refused \(column.label) let go", to: notes)  // round 2, finding G
            }
            #endif
            if now { editing = false; refused = nil; reopened = false }
        }
        // a table cell whose entry was refused opens again with it once the alert saying why is closed (Task 1.7)
        .onChange(of: model.message) { _, now in
            if now == nil, refused != nil, inTable, !editing, !locked {
                reopened = true
                editing = true
                #if PREPAREME_CHECK
                if let notes = ProcessInfo.processInfo.environment["PREPAREME_CHECK_NOTES"] {
                    InventoryTableCheck.note("reopened with its refusal: \(column.label)", to: notes)
                }
                #endif
            }
        }
    }

    var editor: some View {
        Group {
            if !column.editable {
                Text(shown).foregroundStyle(PrepareMeColors.text2).help("This column can't be changed here.")
            } else {
                switch column.kind {
                case .bool:
                    Toggle("", isOn: Binding(get: { row[column].whole == 1 },
                                             set: { save(.int($0 ? 1 : 0)) })).labelsHidden().pmSwitch()
                // a searchable list, New Place… at its foot (Task 1.6); in the table too, opened at once (spec 5.2)
                case .reference(let target) where boxed || target == "Locations" || target == "Categories":
                    PickListButton(title: column.label, value: pickedName,
                                   choices: choicesForReference.map { PickChoice(id: $0.0, title: $0.1) },
                                   picked: Binding(get: { row[column].whole ?? 0 }, set: { save(.int($0)) }),
                                   newTitle: target == "Locations" ? PickLists.newPlaceTitle
                                       : target == "Categories" ? PickLists.newCategoryTitle : nil,
                                   startsOpen: inTable, onClose: inTable ? { editing = false } : nil) { done in
                        if target == "Locations" {
                            NewPlaceForm(places: inventory.locationRows.map {
                                             PickChoice(id: $0.id, title: InventoryLook.title(inventory.path(ofLocation: $0.id)))
                                         },
                                         others: inventory.locationRows.map {
                                             (id: $0.id, name: inventory.name(ofLocation: $0.id), keptIn: inventory.keptIn($0.id))
                                         },
                                         keptIn: row[column].whole ?? 0, add: addPlace, done: done)
                        } else {
                            NewCategoryForm(others: Array(inventory.names(for: column).values), add: addCategory, done: done)
                        }
                    }
                case .reference:
                    Picker("", selection: Binding(get: { row[column].whole ?? 0 }, set: { save(.int($0)); editing = false })) {
                        Text("").tag(Int64(0))
                        ForEach(choicesForReference, id: \.0) { id, name in Text(name).tag(id) }
                    }
                    .labelsHidden()
                case .choice where boxed && InventoryFile.same(column.label, Inventory.Label.grab):
                    // Grab side by side, as the phone's: None, 10 min, 1 hour (and the item's own, if another)
                    Picker(column.label, selection: Binding(get: { InventoryValues.plain(row[column]) },
                                                            set: { picked in
                                                                if case .success(let value) = InventoryValues.stored(
                                                                    picked, in: column, names: names) { save(value) }
                                                            })) {
                        Text("None").tag("")
                        ForEach(PhoneEditRules.grabOptions(column.choices.isEmpty ? Inventory.grabChoices : column.choices,
                                                           current: InventoryValues.plain(row[column])),
                                id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                // Manual, Holds unit: a pick, never typed (spec 5.4), in the table too, closing once picked (review, 7)
                case _ where (boxed || inTable) && PhoneEditRules.isPickOnly(column.label):
                    let stored = InventoryValues.plain(row[column])
                    let now = PhoneEditRules.pickShown(column.label, stored: stored, choices: column.choices)
                    Picker(column.label, selection: Binding(get: { now }, set: { picked in
                        defer { if inTable { editing = false } }
                        // only a choice picked is saved: opening, or a value not on the list left alone, writes nothing
                        guard picked != now else { return }
                        if case .success(let value) = InventoryValues.stored(picked, in: column, names: names) {
                            save(value)
                        }
                    })) {
                        ForEach(PhoneEditRules.pickChoices(column.label, choices: column.choices, stored: stored),
                                id: \.self) {  // Holds unit's blank as Grab's
                            Text($0.isEmpty ? "None" : $0).tag(PhoneEditRules.pickStored(column.label, shown: $0))
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                default:
                    HStack(spacing: 2) {
                        if boxed, InventoryFile.same(column.label, Inventory.Label.quantity) {  // − n +, as the phone's; one size for both (− alone is a flat glyph)
                            Button { step(-1) } label: { Image(systemName: "minus").frame(width: 12, height: 12) }.pmAction(fullWidth: false)
                                .accessibilityLabel("One less")
                        }
                        Group {
                            if inTable {
                                TableTextField(text: $draft, label: column.label, left: left, torn: tornSave)
                            } else {
                                TextField("", text: $draft)
                                    .textFieldStyle(.plain)
                                    .focused($focused)
                                    .onSubmit(commit)
                                    .accessibilityLabel(column.label)  // VoiceOver says which field (entry fixes, phase 4)
                                    .textInputSuggestions(suggestions, id: \.self) { Text($0).textInputCompletion($0) }
                            }
                        }
                        .capitalFirst($draft, (focused || inTable) && tableName == "Inventory"
                                      && InventoryFile.same(column.label, Inventory.Label.item))
                        // Year's offered years and no list for an amount (spec 5.4), on the form and in the table
                        let offered = PhoneEditRules.boxChoices(table: tableName, columnLabel: column.label,
                                                                choices: column.kind == .choice ? column.choices : [],
                                                                current: shown, now: .now)
                        if !offered.isEmpty {
                            Menu {
                                ForEach(offered, id: \.self) { choice in
                                    Button(choice) { draft = choice; commit() }
                                }
                            } label: { EmptyView() }
                            .menuStyle(.borderlessButton)
                            .frame(width: 14)
                            .accessibilityLabel("\(column.label) choices")
                        }
                        if boxed, InventoryFile.same(column.label, Inventory.Label.quantity) {
                            Button { step(1) } label: { Image(systemName: "plus").frame(width: 12, height: 12) }.pmAction(fullWidth: false)
                                .accessibilityLabel("One more")
                        }
                    }
                    .padding(.horizontal, boxed ? 8 : 0).padding(.vertical, boxed ? 6 : 0)
                    .overlay {  // the typed box's one outline (pmBox), in a form only
                        if boxed {
                            RoundedRectangle(cornerRadius: PrepareMeCorners.control)
                                .stroke(PrepareMeColors.edge.opacity(0.6))
                        }
                    }
                    .onAppear { draft = refused ?? shown }
                    .onChange(of: draft) { _, now in typing?(column.colId, now) }
                    .onChange(of: shown) { _, new in if !focused, !inTable { draft = new } }
                    .onChange(of: focused) { _, now in if !now { left() } }
                    .onDisappear { if focused { commit() } }  // the form closed with it still being typed in
                    #if PREPAREME_CHECK
                    .task {  // the check build only: with EDIT_ITEM, PREPAREME_CHECK_TYPE fills the box, then the cursor
                        // goes to its end, as End would, and PREPAREME_CHECK_LEAVE=1 leaves the box 2 s later (2026-10-31)
                        let check = ProcessInfo.processInfo.environment
                        guard inTable, check["PREPAREME_CHECK_EDIT_ITEM"] != nil, let typed = check["PREPAREME_CHECK_TYPE"]
                        else { return }
                        try? await Task.sleep(for: .seconds(1))
                        draft = typed
                        try? await Task.sleep(for: .milliseconds(500))
                        let window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
                        window?.firstResponder?.tryToPerform(#selector(NSResponder.moveToEndOfLine(_:)), with: nil)
                        if check["PREPAREME_CHECK_LEAVE"] != nil { try? await Task.sleep(for: .seconds(2)); window?.makeFirstResponder(nil) }
                    }
                    .task {  // the check build only: PREPAREME_CHECK_FOCUS=Brand puts the cursor in that form box and
                        // PREPAREME_CHECK_TYPE types into it, for its suggestions (2026-10-30)
                        let check = ProcessInfo.processInfo.environment
                        guard boxed, let label = check["PREPAREME_CHECK_FOCUS"], InventoryFile.same(column.label, label)
                        else { return }
                        try? await Task.sleep(for: .seconds(2))
                        focused = true
                        try? await Task.sleep(for: .milliseconds(300))
                        if let typed = check["PREPAREME_CHECK_TYPE"] { draft = typed }
                    }
                    .task {  // the check build only: PREPAREME_CHECK_CHOICES=<label> writes what that form box, or
                        // table cell being typed in, offers beside it to PREPAREME_CHECK_NOTES, then presses its
                        // choices arrow 5 s in, as a click would (phase 4: Year's years; an amount has none)
                        let check = ProcessInfo.processInfo.environment
                        guard boxed || inTable, let label = check["PREPAREME_CHECK_CHOICES"],
                              InventoryFile.same(column.label, label)
                        else { return }
                        try? await Task.sleep(for: .seconds(5))
                        let offered = PhoneEditRules.boxChoices(table: tableName, columnLabel: column.label,
                                                                choices: column.kind == .choice ? column.choices : [],
                                                                current: shown, now: .now)
                        // a SwiftUI Menu fills its items only when clicked, so the arrow is told by place: SCROLL put
                        // this row at the middle of its window (the form), or it is the table cell being typed in
                        // the form, or the table; its own window when another app is in front
                        let window = NSApp.keyWindow ?? PrepareMeMacTabs.shared.window.map { $0.attachedSheet ?? $0 }
                        let popUps = InventoryTableCheck.popUps(in: window?.contentView)
                        func middle(_ view: NSView) -> CGFloat {
                            abs(view.convert(view.bounds, to: nil).midY - (view.window?.contentView?.bounds.midY ?? 0))
                        }
                        let arrow = popUps.min { middle($0) < middle($1) }
                        if let notes = check["PREPAREME_CHECK_NOTES"] {
                            InventoryTableCheck.note("\(column.label) holds \"\(shown)\", offers \(offered.count): "
                                                     + "\(offered.prefix(3).joined(separator: ", ")) … "
                                                     + "\(offered.suffix(3).joined(separator: ", ")); "
                                                     + "\(popUps.count) choices arrows on screen, at "
                                                     + popUps.map { "\(Int($0.convert($0.bounds, to: nil).midY))" }
                                                        .joined(separator: ", ") + "; "
                                                     + (offered.isEmpty ? "none pressed (no list offered)"
                                                        : arrow.map { "pressed the one at \(Int($0.convert($0.bounds, to: nil).midY))" }
                                                        ?? "none pressed"), to: notes)
                        }
                        if !offered.isEmpty { arrow?.performClick(nil) }  // an amount offers none: nothing pressed
                    }
                    .task {  // the check build only: PREPAREME_CHECK_STEP=n presses a form's Quantity + n times, 2 s apart
                        guard boxed, InventoryFile.same(column.label, Inventory.Label.quantity),
                              let times = ProcessInfo.processInfo.environment["PREPAREME_CHECK_STEP"].flatMap(Int.init)
                        else { return }
                        for _ in 0..<times { try? await Task.sleep(for: .seconds(2)); step(1) }
                    }
                    #endif
                }
            }
        }
    }

    /// The box left, its cursor gone elsewhere (or Return, in the table): saved, and a table cell back to plain text.
    func left() {
        // a refused entry left again unchanged goes back to what the file holds (Task 1.7)
        // (the alert taking the cursor is no leaving: only the cell opened again after it)
        if refused != nil, draft == refused {
            if reopened { refused = nil; reopened = false; draft = shown }
        } else {
            commit()
        }
        editing = false
    }

    /// The save for a table cell torn down while typed in (`TableTextField.torn`): worked out now, while the cell is
    /// on screen, from values only, since its @State reads as new once it is gone. Unchanged, or the refusal it was
    /// left with, saves nothing; text that can't be stored says so in the window's Not saved alert.
    var tornSave: (String) -> Void {
        let shown = shown, refused = refused, names = names, undo = undo
        let column = column, table = tableName, row = row.id
        return { text in
            guard text != shown, text != refused else { return }
            let model = InventoryModel.shared
            switch InventoryValues.stored(text, in: column, names: names) {
            case .success(let value):
                Task { await model.apply(.set(table: table, row: row, colId: column.colId, value: value), undo: undo,
                                         name: "Change \(column.label)") }
            case .failure(let problem): model.message = "\(column.label): \(problem.description)"
            }
        }
    }

    /// A pick's value as the form shows it: a place by its path ("Garage › Shelf 2"), anything else by its name.
    var pickedName: String {
        guard let id = row[column].whole, id != 0 else { return "" }
        let name = if case .reference("Locations") = column.kind { inventory.path(ofLocation: id) } else { names[id] ?? "" }
        return Self.titles(column, in: tableName) ? InventoryLook.title(name) : name
    }

    /// New Place… or New Category… from a form (Task 1.6): made at once, with its own Edit › Undo; the editor's refusal
    /// is shown in the form, not as the window's alert.
    func addPlace(_ name: String, _ keptIn: Int64, _ vehicle: Bool) async -> (row: Int64?, why: String?) {
        let table = inventory.locations
        var values: [String: SQLValue] = [:]
        if let column = table.column(Inventory.Label.name) { values[column.colId] = .text(name) }
        if keptIn != 0, let column = table.column(Inventory.Label.keptIn) { values[column.colId] = .int(keptIn) }
        if vehicle, let column = table.column(Inventory.Label.vehicle) { values[column.colId] = .int(1) }
        return await made(.add(table: "Locations", values: values), name: "New Place")
    }

    func addCategory(_ name: String, _ countsAs: String) async -> (row: Int64?, why: String?) {
        let table = inventory.categories
        var values: [String: SQLValue] = [:]
        if let column = table.column(Inventory.Label.name) { values[column.colId] = .text(name) }
        if let column = table.column(Inventory.Label.countsAs) { values[column.colId] = .text(countsAs) }
        return await made(.add(table: "Categories", values: values), name: "New Category")
    }

    func made(_ change: InventoryChange, name: String) async -> (row: Int64?, why: String?) {
        let row = await model.apply(change, undo: undo, name: name)
        let why = model.message
        if row == nil { model.message = nil }
        return (row, why)
    }

    /// The reference's choices: its table's names in the Finder's order, a place by its path ("Truck › Drawer 1",
    /// Task 1.6); for a location's Kept in, never itself or one of its own bins.
    var choicesForReference: [(Int64, String)] {
        var found = names.map { ($0.key, $0.value) }
        if case .reference("Locations") = column.kind { found = found.map { ($0.0, inventory.path(ofLocation: $0.0)) } }
        if tableName == "Locations", InventoryFile.same(column.label, Inventory.Label.keptIn) {
            let own = inventory.within(row.id)
            found.removeAll { own.contains($0.0) }
        }
        if Self.titles(column, in: tableName) { found = found.map { ($0.0, InventoryLook.title($0.1)) } }
        return found.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    /// Quantity up or down by one, from 0 to 10,000 as the phone's, kept as a typed change would be.
    func step(_ by: Double) {
        draft = PhoneEditRules.stepped(draft, by: by)
        commit()
    }

    func commit() {
        guard draft != shown, draft != pending, draft != refused else { return }
        switch InventoryValues.stored(draft, in: column, names: names) {
        case .success(let value): save(value)
        case .failure(let problem):
            model.message = "\(column.label): \(problem.description)"
            keepTyped(draft)
        }
    }

    func save(_ value: SQLValue) {
        if let keep { return keep(value) }
        let change = InventoryChange.set(table: tableName, row: row.id, colId: column.colId, value: value)
        let typed = draft
        pending = typed
        Task {
            if await model.apply(change, undo: undo, name: "Change \(column.label)") == nil {
                if typesText { keepTyped(typed) } else { draft = shown }  // a pick or a switch has nothing typed
            } else {
                refused = nil
                saved?(column.colId, value)
            }
            pending = nil
        }
    }

    /// A refused entry stays typed (entry fixes plan, Task 1.7, 2026-10-23: it had been thrown away): in a form, in its
    /// box under the reason; in the table, the cell opens again with it once the alert is closed. It is never sent
    /// again as it is.
    /// Whether this cell is typed into (a pick, a switch or Grab's choices aren't), the only kind a refusal keeps.
    var typesText: Bool {
        switch column.kind {
        case .bool, .reference: false
        default: !(boxed && (InventoryFile.same(column.label, Inventory.Label.grab)
                             || PhoneEditRules.isPickOnly(column.label)))
        }
    }

    func keepTyped(_ typed: String) {
        refused = typed
        draft = typed
    }
}

/// The item form's Manual row (top-ten plan, phase 7). With no manual: the column's pick ("Not recorded", the blank;
/// "Not needed"; "None exists") and "Add Manual…". With one: where it stands against the packer's last build of the
/// manuals library (waiting for it, left out and why, or the manual its build stopped on), "Read the Manual" once the
/// library holds it, "Replace…" and "Remove".
struct ManualRow: View {
    static let label = "Manual"
    let inventory: Inventory
    let column: InventoryColumn
    let row: InventoryRow
    /// The item form's: told of the pick saved, so its Cancel puts it back as every other field's.
    var saved: ((String, SQLValue) -> Void)?
    @ObservedObject private var model = InventoryModel.shared
    @ObservedObject private var store = PrepareMeMac.shared.store
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var adding = false

    var body: some View {
        let state = model.manualState(row.id)
        VStack(alignment: .trailing, spacing: 6) {
            switch state {
            case .none:
                HStack(spacing: 8) {
                    CellEditor(inventory: inventory, tableName: "Inventory", column: column, row: row, boxed: true,
                               saved: saved)
                    addButton("Add Manual…")
                }
            case .waiting, .ready, .leftOut, .stopped:
                if case .leftOut(let reason) = state {
                    Text("Left out of the library: \(reason)")
                        .foregroundStyle(PrepareMeColors.caution).fixedSize(horizontal: false, vertical: true)
                } else if case .stopped(let found) = state {
                    Text(ItemManuals.stoppedWords(found))
                        .foregroundStyle(PrepareMeColors.red).fixedSize(horizontal: false, vertical: true)
                } else if state == .waiting {
                    Text("Waiting for the next library build").foregroundStyle(PrepareMeColors.text2)
                }
                HStack(spacing: 8) {
                    if state == .ready {
                        Button("Read the Manual") { read() }
                    }
                    addButton("Replace…")
                    Button("Remove") { model.removeManual(row.id) }.disabled(adding)
                }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf]) { picked in
            guard case .success(let url) = picked else { return }
            adding = true
            Task {
                await model.addManual(url, item: row.id)
                adding = false
            }
        }
    }

    /// The manual in Guides, from this Mac's own copy of the manuals library; until it has opened the copy that holds
    /// it, a line saying so.
    func read() {
        Task {
            guard let url = await PrepareMeKeptTabs.manualURL(ItemManuals.contentPath(itemID: row.id),
                                                             held: store.record.held) else {
                model.message = "This Mac hasn't opened the library with this manual yet; try again in a few minutes."
                return
            }
            model.message = nil
            dismiss()
            PrepareMeMacTabs.shared.open(url)
        }
    }

    func addButton(_ words: String) -> some View {
        Button(adding ? "Checking each page…" : words) { choosing = true }
            .disabled(adding)
            .help("Each page is read and checked for ID numbers before the manual is kept; a Mac-only item gets none.")
    }
}

/// One item as a form: every column, labeled, with the same controls as the table.
/// The sheet's own window keeps nothing focused once it is key (Task 13.1; F39; the phase 13 review: clearing whichever
/// window was key on appear could miss the sheet, and AppKit focuses a sheet's first field as it becomes key).
private struct NoFirstField: NSViewRepresentable {
    final class Watcher: NSView {
        private var seen: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let seen { NotificationCenter.default.removeObserver(seen) }
            seen = nil
            guard let window else { return }
            if window.isKeyWindow { DispatchQueue.main.async { window.makeFirstResponder(nil) } }
            seen = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                          queue: .main) { [weak self] _ in
                // once: a field picked later by click or Tab keeps its focus
                if let seen = self?.seen { NotificationCenter.default.removeObserver(seen) }
                self?.seen = nil
                DispatchQueue.main.async { window.makeFirstResponder(nil) }
            }
        }
    }

    func makeNSView(context: Context) -> Watcher { Watcher() }
    func updateNSView(_ view: Watcher, context: Context) {}
}

struct ItemForm: View {
    let inventory: Inventory
    let id: Int64
    @ObservedObject private var model = InventoryModel.shared
    @ObservedObject private var store = PrepareMeMac.shared.store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undo
    @State private var code = ""
    @State private var links: GuideLinks?  // the daily library's, for How to use it (phase 14, F57)
    @State private var lookup: Lookup?  // a code just added, looked up (step 8a)
    @State private var moreOpen = false  // More details, open when one of its cells holds something (`onAppear`)
    @State private var perServing = ""  // the servings boxes, for a food (2026-10-22)
    @State private var servings = ""
    @State private var prefilled: (perServing: String, servings: String, from: String)?  // what the lookup put in
    @State private var original: [String: SQLValue] = [:]  // the row's cells as the form opened, for Cancel
    @State private var mine: [String: SQLValue] = [:]  // what this form saved in each cell, the last time, for Cancel
    @State private var supply: SupplyShares?  // the last count's, for what the item counts toward (Task 3.4)
    @State private var typed: [String: String] = [:]  // each box as typed, by column id, for the what's-missing line

    /// What the lookup of a code just added came to: still asking, or its answer.
    enum Lookup: Equatable {
        case looking
        case done(ProductLookupClient.Outcome)
    }

    var body: some View {
        let current: Inventory = if case .ready(let found) = model.state { found } else { inventory }
        let line = current.itemRows.first { $0.id == id }
            .flatMap { current.needsLine($0, typed: typed, units: supply?.units) }
        VStack(alignment: .leading, spacing: 12) {
            if let row = current.itemRows.first(where: { $0.id == id }) {
                Text(current.name(ofItem: row).isEmpty ? "Unnamed Item" : current.name(ofItem: row)).font(.pmTitle)
                // what it counts toward, as the last count found it (entry fixes plan, Task 3.4)
                Text(SupplyShares.countedLine(supply, row: row.position, item: current.name(ofItem: row)))
                    .foregroundStyle(PrepareMeColors.text2)
                if let message = model.message {
                    Text(message).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
                }
                ScrollViewReader { proxy in
                    PMForm {
                        // the entry redesign (docs/plans/2026-10-22-item-entry-redesign.md): the phone's groups
                        ForEach(ItemFieldGroup.grouped(current.items.columns.filter { current.shows($0, in: row) },
                                                       label: \.label), id: \.group) { entry in
                            let cells = ForEach(entry.columns) { column in
                                LabeledContent(InventoryFile.same(column.label, Inventory.Label.privateRow) ? "Private"
                                               : column.label) {
                                    if InventoryFile.same(column.label, ManualRow.label) {  // top-ten plan, phase 7
                                        ManualRow(inventory: current, column: column, row: row,
                                                  saved: { mine[$0] = $1 })
                                    } else {
                                        CellEditor(inventory: current, tableName: "Inventory", column: column, row: row,
                                                   boxed: true, saved: { mine[$0] = $1 }, typing: { typed[$0] = $1 })
                                    }
                                }
                                .id(column.colId)
                            }
                            switch entry.group {
                            case .more: EntryFold(open: $moreOpen) { cells }
                            case .food: if current.showsFood(row) { EntrySection(group: .food) { cells } }
                            default: EntrySection(group: entry.group) { cells }
                            }
                        }
                        if let guides = links?.guides(forItem: current.name(ofItem: row)), !guides.isEmpty {
                            // phase 14 (F57): the guides its name has words of (each button says How to use it)
                            Section {
                                HowToUseButtons(guides: guides, held: store.record.held) { url in
                                    model.message = nil
                                    dismiss()
                                    PrepareMeMacTabs.shared.open(url)
                                }
                            }
                        }
                        InsuranceSection(inventory: current, id: id)  // slice 7, Mac only
                        Section(pmTitle: "Barcodes") {  // slice 6: a phone that scans one opens this item
                            ForEach(model.codes(of: id), id: \.self) { code in
                                LabeledContent(code) {
                                    Button("Remove") {
                                        Task { await model.apply(.unlinkBarcode(code: code, row: id), undo: undo,
                                                                 name: "Remove barcode") }
                                    }
                                }
                            }
                            TextField("Add a barcode", text: $code,
                                      prompt: Text("Type it, or scan it with a USB scanner"))
                                .onSubmit {
                                    let typed = code
                                    Task {
                                        if await model.apply(.linkBarcode(code: typed, row: id), undo: undo,
                                                             name: "Add barcode") != nil {
                                            code = ""
                                            await look(typed)
                                        }
                                    }
                                }
                            if let lookup { lookupRows(lookup, current) }
                        }
                    }
                    // scrolls: an item has more cells, photos and codes than a sheet shows at once
                    .formStyle(.grouped)
                    .task(id: store.record.held) { links = await PrepareMeKeptTabs.guideLinks(held: store.record.held) }
                    #if PREPAREME_CHECK
                    // the check build only: PREPAREME_CHECK_SCROLL=<label> scrolls that row into view 2 s in
                    // (Holds unit's pick sat below a 900-high window; fix wave)
                    .task {
                        guard let label = ProcessInfo.processInfo.environment["PREPAREME_CHECK_SCROLL"],
                              let column = current.items.column(label) else { return }
                        try? await Task.sleep(for: .seconds(2))
                        proxy.scrollTo(column.colId, anchor: .center)
                    }
                    #endif
                }
            } else {
                Text("That item is no longer there.")
            }
            // what a supply still needs of it, never stopping Done (spec 5.3)
            if let line { PMNeedsLine(line: line) }
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Done") { finish() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 470)  // inside the Inventory window as it first opens
        .announcesNeeds(line)
        .background(NoFirstField())  // nothing focused: typing at once had renamed "AA batteries" to "30" (F39)
        .onAppear {
            let current: Inventory = if case .ready(let found) = model.state { found } else { inventory }
            if let row = current.itemRows.first(where: { $0.id == id }) {
                moreOpen = current.moreFilled(row)
                original = row.values
            }
            supply = InventoryModel.folder.flatMap { SupplyShares.read(in: $0) }
        }
    }

    /// Step 8a (owner, 2026-10-19, by click): a code just added is looked up as the phone's Quick add looks one up
    /// (ProductLookupClient: Open Food Facts, then UPCitemdb, only the code sent), and what was found is offered: its
    /// name and brand, and a food's calories for the whole package. Nothing is kept until Fill in the blanks, which
    /// puts each into a blank cell only, through the editor as any typed cell. What the food services have shows under
    /// it, and for a food the two servings boxes as on the phone's item form, filled with what was found (owner,
    /// 2026-10-22, by click): their figure goes into Calories each and their words into Notes, by the same button.
    func look(_ typed: String) async {
        guard let code = Barcode.valid(typed) else { return }
        lookup = .looking
        let outcome = await ProductLookupClient.shared.lookup(code)
        if case .found(let info) = outcome {
            perServing = info.perServing.map(String.init) ?? ""
            servings = info.servings.map(ProductLookup.number) ?? ""
            prefilled = (perServing, servings, info.figuresFrom)
        }
        lookup = .done(outcome)
    }

    /// The servings boxes' figure and words, once both hold numbers.
    var worked: (calories: Int, note: String)? {
        let from = prefilled.flatMap { $0.perServing == perServing && $0.servings == servings ? $0.from : nil }
        guard let calories = ProductLookup.caloriesFromServings(perServing: perServing, servings: servings),
              let note = ProductLookup.servingsNote(perServing: perServing, servings: servings, from: from) else {
            return nil
        }
        return (calories, note)
    }

    @ViewBuilder func lookupRows(_ lookup: Lookup, _ current: Inventory) -> some View {
        switch lookup {
        case .looking:
            Label(ProductLookup.lookingUp, systemImage: "magnifyingglass").foregroundStyle(PrepareMeColors.text2)
        case .done(.found(let info)):  // row for row as the phone's item form (owner, 2026-10-22, by click)
            Text(ProductLookup.found(info))
            if let figures = ProductLookup.figures(info) {
                Text(figures).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            }
            if ProductLookup.showsServings(info) {
                LabeledContent(ProductLookup.perServingLabel) {
                    TextField(ProductLookup.perServingLabel, text: $perServing).labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(ProductLookup.servingsLabel) {
                    TextField(ProductLookup.servingsLabel, text: $servings).labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                Text(ProductLookup.servingsHint).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let whole = worked?.calories ?? info.calories {
                LabeledContent(ProductLookup.wholeLabel, value: ProductLookup.number(Double(whole)))
            }
            if let withheld = current.caloriesWithheld(info, row: id, servings: worked) {  // not in packages (review)
                Text(withheld).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            } else if let worked {
                Text(worked.note).foregroundStyle(PrepareMeColors.text2)
            } else if let calories = info.calories {
                Text(ProductLookup.caloriesOffer(calories, source: info.figuresFrom))
                    .foregroundStyle(PrepareMeColors.text2)
            }
            Button(ProductLookup.fillBlanks) { fill(info) }
                .help(ProductLookup.fillBlanksHelp)
                .disabled(current.lookupFills(info, row: id, servings: worked).isEmpty)
        case .done(.notFound):
            Text(ProductLookup.notFoundOnline).foregroundStyle(PrepareMeColors.text2)
        case .done(.later):
            Text(ProductLookup.notNow).foregroundStyle(PrepareMeColors.text2)
        }
    }

    /// Each blank cell the answer fills, read from the inventory as it is at the click, and kept by the editor only
    /// while the cell still holds what was read (`.revert`: a phone's change since is never overwritten; review).
    func fill(_ info: ProductInfo) {
        let now: Inventory = if case .ready(let found) = model.state { found } else { inventory }
        let fills = now.lookupFills(info, row: id, servings: worked)
        Task {
            for fill in fills {
                guard await model.apply(.revert(table: "Inventory", row: id, colId: fill.column.colId, value: fill.value,
                                                expected: fill.expected), undo: undo,
                                        name: ProductLookup.fillBlanks) != nil else { return }
                mine[fill.column.colId] = fill.value
            }
            lookup = nil
        }
    }

    /// Done keeps what is being typed (the owner's report, 2026-10-19: a serial number typed, then Done, was lost, since
    /// a cell saves on Return or on leaving it): the field is let go first, so it saves as on Return, then Done waits
    /// for the save, and the form stays open with the reason when it was refused.
    /// Cancel (owner, 2026-10-22): each cell this form saved goes back, through the editor as any edit, and only while
    /// it still holds what the form saved (`InventoryChange.cancelForm`), so a phone's change since stays (the audit,
    /// finding 1), Manual's pick among them; photos, barcodes and the manual's PDF stay as their own buttons left them.
    func cancel() {
        model.message = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(50))  // the field's save starts as it is let go
            while model.saving > 0 { try? await Task.sleep(for: .milliseconds(20)) }
            for change in InventoryChange.cancelForm(row: id, opened: original, saved: mine) {
                await model.apply(change, undo: undo, name: "Cancel changes")
            }
            model.message = nil
            dismiss()
        }
    }

    func finish() {
        model.message = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(50))  // the field's save starts as it is let go
            while model.saving > 0 { try? await Task.sleep(for: .milliseconds(20)) }
            if model.message == nil { dismiss() }
        }
    }
}
/// A new item as a form (B2-07, beta run 2: Add had saved an empty row at once, out of sight at the bottom and already in
/// the phones' copy): the item form's own fields, kept in a draft and written as one Add only once it has a name, which
/// Add waits for. Cancel leaves nothing behind. After Add, the new item is selected and shown in the table.
/// By barcode (owner, 2026-10-22, by click: the phone's Quick add on the Mac): a Barcode box first, for a USB scanner or
/// typing; a new product is looked up as the item form does and fills the blank boxes, with the phone form's serving
/// rows; Add keeps it with its code and clears the form for the next, keeping place, category and unit; a code already
/// in the inventory offers Add 1 to it instead.
struct NewItemForm: View {
    let inventory: Inventory
    var byBarcode = false
    let added: (Int64) -> Void
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undo
    @State private var name = ""
    @State private var values: [String: SQLValue]  // started from the preset: the view's place or category
    @State private var adding = false
    @State private var names = PhoneSearch.KeyedCache<ItemMatch.Names>()  // folded once per save (checkpoint 2)
    @FocusState private var nameFocused: Bool
    @State private var code = ""
    @FocusState private var codeFocused: Bool
    @State private var heard = ""
    @State private var found: ProductInfo?  // the lookup's answer for `code`
    @State private var known: (id: Int64, line: String)?  // `code` already linked to an item
    @State private var perServing = ""
    @State private var servings = ""
    @State private var prefilled: (perServing: String, servings: String, from: String)?
    @State private var worked: (calories: Int, note: String)?  // the boxes' figure and words, last put in
    @State private var moreOpen = false  // More details: open once the lookup puts Notes in
    @State private var manual: URL?  // the PDF Add manual… picked, kept once Add has made the item
    @State private var choosingManual = false
    @State private var typed: [String: String] = [:]  // each box as typed, by column id, for the what's-missing line
    @State private var units: SupplyShares.Units?  // the lists job's, read once as the form opens (Task 2.6)

    init(inventory: Inventory, preset: [String: SQLValue], byBarcode: Bool = false,
         added: @escaping (Int64) -> Void) {
        self.inventory = inventory
        self.byBarcode = byBarcode
        self.added = added
        _values = State(initialValue: Self.countingOne(preset, in: inventory))
    }

    /// A new item counts 1 until changed (owner, 2026-10-23, at the phase 2 gate).
    static func countingOne(_ values: [String: SQLValue], in inventory: Inventory) -> [String: SQLValue] {
        guard let quantity = inventory.items.column(Inventory.Label.quantity), values[quantity.colId] == nil,
              case .success(let one) = InventoryValues.stored("1", in: quantity) else { return values }
        return values.merging([quantity.colId: one]) { own, _ in own }
    }

    var nameColumn: InventoryColumn? { inventory.items.column(Inventory.Label.item) }

    /// The draft's fields: every column a person types into but the item's name, which has its own box. The Manual row
    /// offers Add manual… too (owner, 2026-10-30): the PDF is held and added once Add has made the item.
    var columns: [InventoryColumn] {
        inventory.items.columns.filter { $0.editable && $0.colId != nameColumn?.colId }
    }

    var hasName: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// As the item form; the check build's PREPAREME_CHECK_TALL shows it whole for one screenshot
    static var height: CGFloat {
        #if PREPAREME_CHECK
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_TALL"] != nil { return 1000 }
        #endif
        return 470
    }

    var body: some View {
        let draft = InventoryRow(id: 0, position: inventory.itemRows.count + 1, values: values)
        let line = inventory.needsLine(draft, typed: typed, units: units)
        VStack(alignment: .leading, spacing: 12) {
            Text(byBarcode ? "Add by Barcode" : "New Item").font(.pmTitle)  // as the toolbar names them (phase 4 words)
            if let message = model.message {
                Text(message).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            }
            PMForm {
                if byBarcode { Section { barcodeRows } }  // the title says Barcode, and its row: no third (fix round 1)
                // the entry redesign (docs/plans/2026-10-22-item-entry-redesign.md): the phone's groups
                ForEach(ItemFieldGroup.grouped(columns.filter { inventory.shows($0, in: draft, item: name) },
                                               label: \.label), id: \.group) { entry in
                    switch entry.group {
                    case .what: EntrySection(group: .what) { whatRows(draft); cells(entry.columns, draft) }
                    case .more: EntryFold(open: $moreOpen) { cells(entry.columns, draft) }
                    case .food:
                        if inventory.showsFood(draft, scannedFood: found.map(ProductLookup.showsServings) ?? false) {
                            EntrySection(group: .food) { foodRows; cells(entry.columns, draft) }
                        }
                    default: EntrySection(group: entry.group) { cells(entry.columns, draft) }
                    }
                }
            }
            .formStyle(.grouped)
            if let line { PMNeedsLine(line: line) }  // never stops Add (spec 5.3)
            HStack {
                Spacer()
                Button("Cancel") { model.message = nil; dismiss() }.keyboardShortcut(.cancelAction)
                if !byBarcode {  // the next item at once, its place, category and unit kept (Task 2.1, 2026-10-23)
                    Button(InventoryWords.addAndNext) { add(andNext: true) }
                        .keyboardShortcut(.return, modifiers: .command).disabled(!hasName || adding)
                        .help("Keep this item and start the next, in the same place and category")
                }
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(!hasName || adding)
                    .help(hasName ? "Keep this item" : "Give the item a name first")
            }
        }
        .padding(20)
        .frame(width: 560, height: Self.height)  // as the item form
        .announcesNeeds(line)
        .fileImporter(isPresented: $choosingManual, allowedContentTypes: [.pdf]) { picked in
            if case .success(let url) = picked { manual = url }
        }
        .onAppear {  // a new item: its name is what to type first; by barcode, its code
            model.message = nil
            units = InventoryModel.folder.flatMap { SupplyShares.read(in: $0) }?.units
            if byBarcode { codeFocused = true } else { nameFocused = true }
            #if PREPAREME_CHECK
            if ProcessInfo.processInfo.environment["PREPAREME_CHECK_TALL"] != nil { moreOpen = true }  // all of it
            // PREPAREME_CHECK_CATEGORY=<name> picks that category, so the what's-missing line shows (fix wave)
            if let wanted = ProcessInfo.processInfo.environment["PREPAREME_CHECK_CATEGORY"],
               let column = inventory.items.column(Inventory.Label.category),
               let category = inventory.sidebarCategories.first(where: { InventoryFile.same($0.name, wanted) }) {
                values[column.colId] = .int(category.id)
            }
            // the check build only: PREPAREME_CHECK_CODE is typed into the Barcode box, as a USB scanner would
            if byBarcode, let typed = ProcessInfo.processInfo.environment["PREPAREME_CHECK_CODE"] {
                code = typed
                Task { await lookUp() }
            }
            // PREPAREME_CHECK_ADD_NEXT=<name> names the item and presses Add and Next once, 4 s in: after FOCUS and
            // TYPE have filled a box (2026-10-31, the early Add and Next's refusal path)
            if let typed = ProcessInfo.processInfo.environment["PREPAREME_CHECK_ADD_NEXT"] {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    name = typed
                    add(andNext: true)
                }
            }
            #endif
        }
    }

    /// What it is: the name in its own large box, then "already in the inventory" when it matches one.
    @ViewBuilder func whatRows(_ draft: InventoryRow) -> some View {
        if nameColumn != nil {
            TextField("Name", text: $name, prompt: Text("Name (needed before it's kept)"))
                .labelsHidden().textFieldStyle(.plain).font(.pmEntry).pmBox()
                .focused($nameFocused)
                .capitalFirst($name)
        }
        if !byBarcode, !heard.isEmpty {  // "Added Rice. Type the next." after Add and Next
            Text(heard).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
        }
        // fresh eyes: six cans of soup, soup exists already; the names folded once per save, not per keystroke
        if let same = inventory.alreadyThere(named: name, in: names.value(key: "\(model.revision)") {
            inventory.itemNames
        }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(same.line).font(.pmNote).fixedSize(horizontal: false, vertical: true)
                Button(ItemMatch.goTo) {
                    model.message = nil
                    dismiss()
                    added(same.id)  // the existing row, selected and scrolled to
                }
                .pmAction(fullWidth: false)
            }
        }
    }

    /// A group's cells (`columns`: the name has its own box above), each kept in the draft.
    @ViewBuilder func cells(_ group: [InventoryColumn], _ draft: InventoryRow) -> some View {
        ForEach(group) { column in
            LabeledContent(InventoryFile.same(column.label, Inventory.Label.privateRow) ? "Private"
                           : InventoryFile.same(column.label, Inventory.Label.caloriesEach) ? ProductLookup.wholeLabel
                           : column.label) {
                if InventoryFile.same(column.label, ManualRow.label), let manual {  // as ManualRow, before the build
                    HStack(spacing: 8) {
                        Text(manual.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(PrepareMeColors.text2)
                        Button("Remove") { self.manual = nil }
                    }
                } else {
                    HStack(spacing: 8) {
                        CellEditor(inventory: inventory, tableName: "Inventory", column: column, row: draft,
                                   keep: { value in values[column.colId] = value }, boxed: true,
                                   typing: { typed[$0] = $1 })
                        if InventoryFile.same(column.label, ManualRow.label) {
                            Button("Add Manual…") { choosingManual = true }
                        }
                    }
                }
            }
        }
    }

    /// The Barcode box and what its lookup found, row for row as the phone's item form.
    @ViewBuilder var barcodeRows: some View {
        LabeledContent("Barcode") {
            TextField("Barcode", text: $code, prompt: Text("Scan it with a USB scanner, or type it"))
                .labelsHidden()
                .focused($codeFocused)
                .onSubmit { Task { await lookUp() } }
        }
        if !heard.isEmpty {
            Text(heard).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
        }
        if let known {
            Button("Add 1 to It") { Task { await plusOne(known.id) } }.pmAction(fullWidth: false)
        }
    }

    /// Food: what the services have, the two serving boxes, and how the whole package's calories were reached; the
    /// draft's own Calories each cell follows them.
    @ViewBuilder var foodRows: some View {
        if let found {
            if let figures = ProductLookup.figures(found) {
                Text(figures).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            }
            if ProductLookup.showsServings(found) {
                LabeledContent(ProductLookup.perServingLabel) {
                    TextField(ProductLookup.perServingLabel, text: $perServing).labelsHidden().textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing).pmBox().frame(maxWidth: 120)
                }
                .onChange(of: perServing) { servingsChanged() }
                LabeledContent(ProductLookup.servingsLabel) {
                    TextField(ProductLookup.servingsLabel, text: $servings).labelsHidden().textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing).pmBox().frame(maxWidth: 120)
                }
                .onChange(of: servings) { servingsChanged() }
                Text(ProductLookup.servingsHint).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let worked {
                Text(worked.note).foregroundStyle(PrepareMeColors.info)  // the one key fact's color
            }
        }
    }

    func column(_ label: String) -> InventoryColumn? { inventory.items.column(label) }

    /// Puts `text` in the draft's `label` box while it is blank or still holds `last` (what the lookup put there).
    func fill(_ label: String, _ text: String, over last: String? = nil) {
        guard let column = column(label), column.editable else { return }
        let now = InventoryValues.plain(values[column.colId] ?? .null)
        guard now.isEmpty || now == last else { return }
        if text.isEmpty { values[column.colId] = nil; return }
        if case .success(let value) = InventoryValues.stored(text, in: column) { values[column.colId] = value }
    }

    /// The code typed or scanned: one already in the inventory offers Add 1 to it; a new one is looked up and fills
    /// the blank boxes (ProductLookupClient, as the item form's).
    func lookUp() async {
        found = nil
        known = nil
        worked = nil
        prefilled = nil
        (perServing, servings) = ("", "")
        guard let valid = Barcode.valid(code) else {
            heard = InventoryWords.notABarcode
            return
        }
        let now: Inventory = if case .ready(let current) = model.state { current } else { inventory }
        if let id = now.barcodes[valid], let row = now.itemRows.first(where: { $0.id == id }) {
            let place = now.items.column(Inventory.Label.location).flatMap { row[$0].whole }
                .map { InventoryLook.title(now.path(ofLocation: $0)) } ?? ""
            known = (id, now.name(ofItem: row))
            heard = "Already in the inventory: " + ([now.name(ofItem: row), place].filter { !$0.isEmpty }
                .joined(separator: ", ")) + "."
            return
        }
        heard = ProductLookup.lookingUp
        switch await ProductLookupClient.shared.lookup(valid) {
        case .found(let info):
            heard = ProductLookup.found(info)
            found = info
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = info.name }
            fill("Brand", info.brand)
            fill(Inventory.Label.model, info.model)  // UPCitemdb's (owner, 2026-10-23)
            // a food goes under Food when no category is chosen, as the phone's Quick add does
            if ProductLookup.isFood(info.source), let category = column(Inventory.Label.category),
               values[category.colId] == nil || values[category.colId] == .null,
               let food = inventory.names(for: category).first(where: { InventoryFile.same($0.value, "Food") }) {
                values[category.colId] = .int(food.key)
            }
            if ProductLookup.showsServings(info) {
                perServing = info.perServing.map(String.init) ?? ""
                servings = info.servings.map(ProductLookup.number) ?? ""
                prefilled = (perServing, servings, info.figuresFrom)
                servingsChanged()
            }
            if worked == nil {
                fill("Notes", info.size)
                fill(ProductLookup.caloriesLabel, ProductLookup.caloriesToFill(info.calories, unit: unit)
                    .map(String.init) ?? "")
            }
        case .notFound:
            heard = ProductLookup.notFoundOnline
        case .later:
            heard = ProductLookup.notNow
        }
    }

    var unit: String { column("Unit").map { InventoryValues.plain(values[$0.colId] ?? .null) } ?? "" }

    /// A serving box changed: Calories each and Notes follow while they hold what the boxes last put there.
    func servingsChanged() {
        let last = worked
        let from = prefilled.flatMap { $0.perServing == perServing && $0.servings == servings ? $0.from : nil }
        let note = ProductLookup.servingsNote(perServing: perServing, servings: servings, from: from)
        worked = ProductLookup.caloriesFromServings(perServing: perServing, servings: servings)
            .flatMap { figure in note.map { (calories: figure, note: $0) } }
        fill(ProductLookup.caloriesLabel,
             worked.flatMap { ProductLookup.caloriesToFill($0.calories, unit: unit) }.map(String.init) ?? "",
             over: last.map { String($0.calories) })
        fill("Notes", worked?.note ?? "", over: last?.note)
        if worked != nil { moreOpen = true }  // Notes now holds how the calories were reached
    }

    /// Add 1 to the item the code is already linked to, through the editor (Edit › Undo takes it back).
    func plusOne(_ id: Int64) async {
        guard await model.apply(.adjust(row: id, by: 1), undo: undo, name: "Add 1") != nil else { return }
        heard = "Added 1 to \(known?.line ?? "it"). Scan the next."
        known = nil
        code = ""
        codeFocused = true
        added(id)
    }

    /// After Add by barcode, or Add and Next: the next starts blank but for its place, category and unit.
    func next(_ addedName: String) {
        let kept = [Inventory.Label.location, Inventory.Label.category, "Unit"].compactMap { column($0)?.colId }
        values = Self.countingOne(values.filter { kept.contains($0.key) }, in: inventory)
        typed = [:]  // a box gone from the form can't tell its line it was emptied
        name = ""
        code = ""
        found = nil
        worked = nil
        prefilled = nil
        manual = nil
        (perServing, servings) = ("", "")
        heard = byBarcode ? "Added \(addedName). Scan the next." : InventoryWords.addedTypeNext(addedName)
        if byBarcode { codeFocused = true } else { nameFocused = true }
    }

    /// The field being typed in is let go first, so its value lands in the draft as on Return, then one Add writes it
    /// all; a refusal keeps the form open with the reason.
    func add(andNext: Bool = false) {
        guard let nameColumn, hasName else { return }
        adding = true
        model.message = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task {
            defer { adding = false }
            try? await Task.sleep(for: .milliseconds(50))  // the field's value is kept as it is let go
            var kept = values.filter { $0.value != .null && $0.value != .text("") }
            let stored = InventoryValues.stored(name, in: nameColumn)
            guard case .success(let typed) = stored else {  // said, never silent (R4.1's review)
                if case .failure(let why) = stored { model.message = "\(nameColumn.label): \(why.description)" }
                return
            }
            kept[nameColumn.colId] = typed
            let linked = byBarcode && known == nil ? Barcode.valid(code) : nil
            let change: InventoryChange = linked.map { .addItem(values: kept, barcode: $0) }
                ?? .add(table: "Inventory", values: kept)
            // Add and Next: the next item can be typed at once while the check and the write run behind it (owner,
            // 2026-10-31: no box had the cursor during the wait); a refusal puts this item back with the reason
            let early = andNext && !byBarcode
            let draft = (name: name, values: values, manual: manual, perServing: perServing, servings: servings,
                         worked: worked, prefilled: prefilled)
            if early {
                next(name)
                adding = false
            }
            guard let id = await model.apply(change, undo: undo, name: "Add") else {
                if early {
                    (name, values, manual, perServing, servings) = (draft.name, draft.values, draft.manual,
                                                                    draft.perServing, draft.servings)
                    (worked, prefilled, heard) = (draft.worked, draft.prefilled, "")
                }
                return
            }
            added(id)
            if let manual = draft.manual {  // the draft's: an early next() has emptied the form's
                await model.addManual(manual, item: id)
                // the item is kept either way: the Not saved alert must not read as if it were lost
                if let why = model.message { model.message = "The item was added, but its manual wasn't: " + why }
            }
            if byBarcode { next(name) } else if !early { dismiss() }
        }
    }
}

/// Edit › Find on Inventory (the Apple guidelines plan, phase 2): the cursor goes to the toolbar's search box, which
/// macOS 15 and later can be told to take (`searchFocused`); before that the box is clicked as before.
private struct FindFocus: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .searchFocused($focused)
                .onReceive(NotificationCenter.default.publisher(for: .prepareMeFind)) { _ in focused = true }
        } else {
            content
        }
    }
}

/// Inventory › Remove Empty Places… (owner, 2026-10-23, by click): every place holding no item, in it or in a bin
/// inside it, each ticked, to untick any to keep; one change, so one Edit › Undo puts them all back. The editor checks
/// again at its turn, so a phone's item put in one meanwhile refuses the lot rather than losing it.
struct EmptyPlacesSheet: View {
    let inventory: Inventory
    let remove: ([Int64]) -> Void
    private let empty: [InventoryRow]
    @State private var ticked: Set<Int64>
    @Environment(\.dismiss) private var dismiss

    init(inventory: Inventory, remove: @escaping ([Int64]) -> Void) {
        self.inventory = inventory
        self.remove = remove
        empty = inventory.emptyPlaces.sorted {  // A to Z by where they are, as a long list is read
            inventory.path(ofLocation: $0.id).localizedStandardCompare(inventory.path(ofLocation: $1.id))
                == .orderedAscending
        }
        _ticked = State(initialValue: Set(empty.map(\.id)))
    }

    var body: some View {
        let going = inventory.removable(ticked.intersection(empty.map(\.id)))  // only places still listed as empty
        VStack(alignment: .leading, spacing: 12) {
            Text(InventoryWords.removeEmptyTitle).font(.pmTitle)
            Text(empty.isEmpty ? InventoryWords.noEmptyPlaces : InventoryWords.removeEmptyWhy)
                .foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            if !empty.isEmpty {
                PMForm {
                    ForEach(empty, id: \.id) { row in
                        Toggle(isOn: Binding(get: { ticked.contains(row.id) }, set: { on in
                            if on { ticked.insert(row.id) } else { ticked.remove(row.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(InventoryLook.title(inventory.path(ofLocation: row.id)))
                                if ticked.contains(row.id) && !going.contains(row.id) {
                                    Text(InventoryWords.staysForBin).foregroundStyle(PrepareMeColors.text2)
                                }
                            }
                        }
                        .toggleStyle(.checkbox).pmSwitch()
                    }
                }
                .formStyle(.grouped)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if !empty.isEmpty {
                    Button(InventoryWords.removeEmptyButton(going.count), role: .destructive) {
                        remove(going)
                        dismiss()
                    }
                    .disabled(going.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: empty.isEmpty ? 180 : 470)
    }
}

/// What the Inventory menu calls on the table shown, published with `focusedSceneValue` while Inventory is on screen
/// (the Apple guidelines plan, phase 2).
struct InventoryMenuActions {
    /// One column in the Columns menu: `fixed` is Item, or Name, which always shows.
    struct Tick { let label, title: String; let shown, fixed: Bool }
    let state: InventoryCommands
    let add, addByBarcode, openForm, editTable: () -> Void
    let columns: [Tick]
    let setShown: (String, Bool) -> Void
    let resetColumns, delete, removeEmptyPlaces, printBlankSheet: () -> Void
    let printLabels: (BinLabelSize) -> Void
    let printGrabSheets, exportCSV: () -> Void
}

private struct InventoryMenuKey: FocusedValueKey { typealias Value = InventoryMenuActions }

extension FocusedValues {
    var inventoryMenu: InventoryMenuActions? {
        get { self[InventoryMenuKey.self] }
        set { self[InventoryMenuKey.self] = newValue }
    }
}

/// The menu bar's Inventory (Apple's menu bar page: every toolbar item is a menu command too): its items always there,
/// dimmed when Inventory isn't on screen or they don't apply. The Delete key deletes the selected rows too once Edit
/// Table is pressed (`onDeleteCommand` on the table), so Delete here shows no key of its own.
struct InventoryMenu: Commands {
    @FocusedValue(\.inventoryMenu) private var inventory

    var body: some Commands {
        CommandMenu("Inventory") {
            let state = inventory?.state
            Button(state?.addTitle ?? "New Item…") { inventory?.add() }
                .keyboardShortcut("n").disabled(state?.canAdd != true)
            Button("Add by Barcode…") { inventory?.addByBarcode() }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(state?.canAddByBarcode != true)
            Button("Open as Form…") { inventory?.openForm() }.disabled(state?.canOpenForm != true)
            Divider()
            Button(state?.editMenuTitle ?? "Edit Table") { inventory?.editTable() }.disabled(state?.canEditTable != true)
            Menu("Columns") {
                // by position: two columns may share a label (phase 1 fixes, finding 7)
                ForEach(Array((inventory?.columns ?? []).enumerated()), id: \.offset) { _, tick in
                    Toggle(tick.title, isOn: Binding(get: { tick.shown }, set: { inventory?.setShown(tick.label, $0) }))
                        .disabled(tick.fixed).pmSwitch()
                }
                Divider()
                Button("Reset Columns") { inventory?.resetColumns() }
            }
            .disabled(state?.canChooseColumns != true)
            Divider()
            Button("Print Blank Sheet…") { inventory?.printBlankSheet() }.disabled(state?.canPrintBlankSheet != true)
            // one title in both places, saying what prints (phase 1 fixes, finding 9); the sizes inside
            Menu(InventoryWords.labelsItem(selected: state?.labelCount ?? 0)) {
                ForEach(BinLabelSize.allCases) { size in Button(size.title + "…") { inventory?.printLabels(size) } }
            }
            .disabled(state?.canPrintLabels != true)
            Button("Print Grab Sheets…") { inventory?.printGrabSheets() }.disabled(state?.canPrintGrabSheets != true)
            Divider()
            Button("Export CSV…") { inventory?.exportCSV() }.disabled(state?.canExportCSV != true)
            Divider()  // the two that remove, last, as Documents ends with Delete… (menu bar plan, owner 2026-11-14)
            Button(state?.deleteTitle ?? "Delete") { inventory?.delete() }.disabled(state?.canDelete != true)
            Button(InventoryWords.removeEmptyTitle + "…") { inventory?.removeEmptyPlaces() }
                .disabled(state?.canRemoveEmptyPlaces != true)
        }
    }
}
#endif
