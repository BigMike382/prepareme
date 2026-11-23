// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 10).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import Foundation
import PrepareMeShared
import SwiftUI

/// Pairing a phone from the Mac (build plan phase 10), in place of `prepareme-service pair`: the app asks the phones'
/// service through Application Support › PrepareMe › pairing (PairingDesk), since only the service holds the Mac's
/// identity and phone list, and shows the code it gets back, sealed to a key this app keeps in memory only. The code
/// is drawn on screen and nowhere else: never saved, logged or copied, and cleared when Settings closes (or another of
/// its tabs is picked) or after 10 minutes. The same pane lists the paired phones (the service's `phones.json`) with
/// Remove, and a name for each that the owner types, kept in this app's own settings only (owner, 2026-10-14): never
/// in the service's files, its log or a phone.
@MainActor
final class PhonePairing: ObservableObject {
    static let shared = PhonePairing()
    static let namesKey = "phoneNames"
    /// Add a device's "paired before" picks waiting to finish (family downloads plan, phase 6): new pairing's key → the
    /// key of the one it takes the place of, in this app's settings as the names are
    static let carriesKey = "phoneCarries"
    static let showFor: Duration = .seconds(600)
    static let waitFor: TimeInterval = 15
    /// No Terminal step (owner): PrepareMe starts its own service afresh when it has been silent for two checks, and
    /// a launch resets its once-an-hour limit on that (PrepareMeMac.registerAgain), so quitting and opening it is the
    /// step.
    static let noAnswer = "The devices' service didn't answer, so nothing changed. If Devices' status, at the top of "
        + "this tab, says it isn't answering, quit PrepareMe (PrepareMe › Quit PrepareMe) and open it again: "
        + "within a minute it starts the service afresh. Then try again."

    @Published private(set) var paired: PairingDesk.Paired?
    @Published private(set) var picture: CGImage?
    @Published private(set) var waiting = false
    @Published private(set) var removing: PairingDesk.Phone?  // while its removal waits for the service
    @Published private(set) var problem: String?
    @Published private(set) var phones: [PairingDesk.Phone]?
    @Published private(set) var names: [String: String]
    @Published private(set) var carries: [String: String]
    /// Phase M: each phone's last room report (the service's phones-storage.json) and the owner's Always or Never per
    /// file per phone (phone-files.json, written whole by this app), both in the pairing folder, by phone label
    @Published private(set) var rooms: [String: PhoneStorage] = [:]
    @Published private(set) var choices: [String: PhoneChoices.Entry] = [:]
    /// Essential Documents (phase 3): each adult's phone's ask for the key (the service's), whether the owner gave it
    /// (this app's gifts file) and its last count of matching documents (the service's), all by this pairing only
    @Published private(set) var documentAsks: [String: DocumentHandoff.Request] = [:]
    @Published private(set) var documentsGiven: Set<String> = []
    @Published private(set) var documentReports: [String: DocumentsPhoneReport] = [:]
    @Published private(set) var giving: PairingDesk.Phone?
    /// The Apple Developer Program renewal the owner typed in Dates that can stop PrepareMe (over-the-air phase 3)
    @Published private(set) var renewal: Date?
    private var hide: Task<Void, Never>?

    private init() {
        names = UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        carries = UserDefaults.standard.dictionary(forKey: Self.carriesKey) as? [String: String] ?? [:]
    }

    private var desk: PairingDesk? {
        PrepareMeMac.folders.map { PairingDesk(folder: $0.appendingPathComponent(PairingDesk.folderName)) }
    }

    /// `replacing`: the device this one is, paired before (phase 6, decision 7): the new pairing takes its name and
    /// choices, and it is removed once the new one visits (`PhoneCuration.carry`, at each refresh)
    func pair(readOnly: Bool, replacing: PairingDesk.Phone? = nil) async {
        guard let desk, !waiting else { return }
        clear()
        waiting = true
        defer { waiting = false }
        let ask: PairingDesk.Ask
        do {
            ask = try desk.askToPair(readOnly: readOnly)
        } catch {
            problem = "PrepareMe couldn't write to its pairing folder, so nothing changed."
            return
        }
        switch await answer(to: ask, at: desk) {
        case let .paired(code)?:
            paired = code
            if let replacing {
                var changed = carries
                changed["\(code.label)|\(code.added)"] = Self.key(replacing)
                saveCarries(changed)
            }
            picture = PairingPicture.image(code.code)
            if picture == nil { problem = "The code couldn't be drawn. \(code.label) was paired: remove it below." }
            refresh()
            hide = Task { [weak self] in
                try? await Task.sleep(for: Self.showFor)
                if !Task.isCancelled { self?.clear() }
            }
        case let .problem(line)?:
            problem = "Not paired: \(line)."
        case .removed?:
            problem = "Not paired: the devices' service answered something else."
        case nil:
            problem = Self.noAnswer
        }
    }

    func remove(_ phone: PairingDesk.Phone) async {
        guard let desk, !waiting else { return }
        problem = nil
        waiting = true
        removing = phone
        defer {
            waiting = false
            removing = nil
        }
        guard let ask = try? desk.askToUnpair(phone) else {
            problem = "PrepareMe couldn't write to its pairing folder, so nothing changed."
            return
        }
        switch await answer(to: ask, at: desk) {
        case .removed(true)?: setName("", for: phone)
        case .removed(false)?: problem = "\(phone.label) was already gone."
        case let .problem(line)?: problem = "Not removed: \(line)."
        case .paired?: problem = "Not removed: the devices' service answered something else."
        case nil: problem = Self.noAnswer
        }
        refresh()
    }

    /// The service's answer, looked for four times a second for 15 seconds; with none, the request is taken back.
    private func answer(to ask: PairingDesk.Ask, at desk: PairingDesk) async -> PairingDesk.Answer? {
        let until = Date().addingTimeInterval(Self.waitFor)
        while Date() < until {
            if let answer = desk.answer(to: ask) { return answer }
            try? await Task.sleep(for: .milliseconds(250))
        }
        desk.withdraw(ask)
        return desk.answer(to: ask)  // one that came as it was taken back
    }

    /// The code off the screen and out of memory.
    func clear() {
        hide?.cancel()
        hide = nil
        paired = nil
        picture = nil
        problem = nil
    }

    func refresh() {
        guard let listed = desk?.phones() else { return }
        if listed != phones { phones = listed }
        let folder = pairingFolder
        let onDisk = PhoneChoices.readAll(folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent(PhoneChoices.fileName)) })
        var set = onDisk, named = names
        if !carries.isEmpty {  // Add a device's "paired before" picks (phase 6): only the owner's pick carries anything
            let step = PhoneCuration.carry(carries, listed: listed, choices: set, names: named)
            set = step.choices
            named = step.names
            if step.pending != carries { saveCarries(step.pending) }
            if let old = step.remove.first, !waiting { Task { await remove(old) } }
        }
        let kept = named.filter { key, _ in listed.contains { Self.key($0) == key } }
        if kept != names { save(kept) }  // a removed phone's name goes with it, so a reused label starts blank
        guard let folder else { return }
        // Each phone's report and choices only from its own pairing: a reused label never shows a removed phone's
        let all = PhoneStorage.readAll(try? Data(contentsOf: folder.appendingPathComponent(PhoneStorage.fileName)))
        var reported: [String: PhoneStorage] = [:]
        for phone in listed { reported[phone.label] = PhoneStorage.current(all, label: phone.label, paired: phone.added) }
        if reported != rooms { rooms = reported }
        let stillPaired = set.filter { label, entry in listed.contains { $0.label == label && $0.added == entry.paired } }
        if stillPaired != onDisk { saveChoices(stillPaired) }  // a removed phone's choices go with it, as its name does
        else if onDisk != choices { choices = onDisk }
        refreshDocuments(listed, folder: folder)
        let typed = StopDates.renewal(try? Data(contentsOf: folder.appendingPathComponent(StopDates.fileName)))
        if typed != renewal { renewal = typed }
    }

    /// Settings › Updates shows it beside the dates table, where the date is typed
    static let renewalProblem = "The renewal date couldn't be saved; try again."

    /// Keeps the renewal date in the pairing folder, where the hourly check reads it to warn
    func setRenewal(_ date: Date) {
        guard let folder = pairingFolder else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try DurableFile.write(StopDates.renewalData(date), to: folder.appendingPathComponent(StopDates.fileName))
            renewal = StopDates.renewal(StopDates.renewalData(date))
        } catch {
            problem = Self.renewalProblem
        }
    }

    private func refreshDocuments(_ listed: [PairingDesk.Phone], folder: URL) {
        func read(_ name: String) -> Data? { try? Data(contentsOf: folder.appendingPathComponent(name)) }
        let requests = DocumentHandoff.readRequests(read(DocumentHandoff.requestsName))
        let giftsURL = folder.appendingPathComponent(DocumentHandoff.giftsName)
        let gifts = DocumentHandoff.readGifts(try? Data(contentsOf: giftsURL))
        let reports = DocumentsPhoneReport.readAll(read(DocumentHandoff.statusName))
        var asks: [String: DocumentHandoff.Request] = [:]
        var given: Set<String> = []
        var reported: [String: DocumentsPhoneReport] = [:]
        for phone in listed where !phone.readOnly {
            asks[phone.label] = DocumentHandoff.request(requests, label: phone.label, paired: phone.added)
            if DocumentHandoff.given(DocumentHandoff.gift(gifts, label: phone.label, paired: phone.added),
                                     ask: asks[phone.label]) { given.insert(phone.label) }
            reported[phone.label] = reports[phone.label].flatMap { $0.paired == phone.added ? $0 : nil }
        }
        // a removed phone's key goes with it: a reused label never gets the removed phone's gift
        let kept = gifts.filter { label, gift in
            listed.contains { !$0.readOnly && $0.label == label && $0.added == gift.paired }
        }
        if kept != gifts, let data = try? DocumentHandoff.encoded(kept) { try? DurableFile.write(data, to: giftsURL) }
        if asks != documentAsks { documentAsks = asks }
        if given != documentsGiven { documentsGiven = given }
        if reported != documentReports { documentReports = reported }
    }

    /// Give It Essential Documents…: Touch ID or the password on this Mac, then the key sealed to that phone's ask.
    func give(_ phone: PairingDesk.Phone) async {
        guard giving == nil, let ask = documentAsks[phone.label], let folder = pairingFolder else { return }
        problem = nil
        giving = phone
        defer { giving = nil }
        problem = await DocumentsModel.shared.give(phone, ask: ask, pairing: folder)
        refresh()
    }

    private var pairingFolder: URL? { PrepareMeMac.folders?.appendingPathComponent(PairingDesk.folderName) }

    /// One device's choices from its Files… sheet, saved once on Done (family downloads plan, phase 6, decision 5): the
    /// sheet holds its picks until then, and Cancel saves nothing
    func setFiles(_ files: [String: String], phone: PairingDesk.Phone) {
        let entry = files.isEmpty ? nil : PhoneChoices.Entry(paired: phone.added, files: files)
        guard choices[phone.label] != entry else { return }
        var changed = choices
        changed[phone.label] = entry
        saveChoices(changed)
    }

    /// One device's stored choices, only from its own pairing
    func files(for phone: PairingDesk.Phone) -> [String: String] {
        choices[phone.label].flatMap { $0.paired == phone.added ? $0.files : nil } ?? [:]
    }

    private func saveChoices(_ changed: [String: PhoneChoices.Entry]) {
        guard let folder = pairingFolder, let data = try? PhoneChoices.encoded(changed) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try DurableFile.write(data, to: folder.appendingPathComponent(PhoneChoices.fileName))
            choices = changed
        } catch {
            problem = "The choice couldn't be saved, so the device keeps what it had."
        }
    }

    func name(for phone: PairingDesk.Phone) -> String {
        names[Self.key(phone)] ?? ""
    }

    /// Every paired phone with the owner's name for it, for the pins it added (MapMark.makerName; owner, 2026-11-12:
    /// "When I label the phones by persons name the pins should carry that label"). The one place a name leaves
    /// this app's settings: onto that phone's pins, in the phones' copy.
    func makers() -> [MapMark.PhoneName] {
        #if PREPAREME_CHECK
        // The check build only, for a check that can't type in Settings: PREPAREME_CHECK_PHONE_NAME is every paired
        // phone's name (made up)
        if let made = ProcessInfo.processInfo.environment["PREPAREME_CHECK_PHONE_NAME"] {
            return (desk?.phones() ?? []).map { MapMark.PhoneName(label: $0.label, added: $0.added, name: made) }
        }
        #endif
        return (desk?.phones() ?? []).map { MapMark.PhoneName(label: $0.label, added: $0.added, name: name(for: $0)) }
    }

    func setName(_ name: String, for phone: PairingDesk.Phone) {
        var changed = names
        changed[Self.key(phone)] = name.isEmpty ? nil : String(name.prefix(40))
        save(changed)
    }

    private func save(_ changed: [String: String]) {
        names = changed
        UserDefaults.standard.set(changed, forKey: Self.namesKey)
    }

    private func saveCarries(_ changed: [String: String]) {
        carries = changed
        UserDefaults.standard.set(changed, forKey: Self.carriesKey)
    }

    /// The device a new pairing takes the place of, while its pick waits to finish
    func replaced(by paired: PairingDesk.Paired) -> PairingDesk.Phone? {
        carries["\(paired.label)|\(paired.added)"].flatMap { key in phones?.first { Self.key($0) == key } }
    }

    /// The owner's name for a device and its label, or the label alone
    func title(for phone: PairingDesk.Phone) -> String {
        let name = name(for: phone)
        return name.isEmpty ? phone.label : "\(name) (\(phone.label))"
    }

    /// A phone by its label and when it was paired: a label is reused once its phone is removed.
    static func key(_ phone: PairingDesk.Phone) -> String {
        "\(phone.label)|\(phone.added)"
    }
}

/// Settings' Devices tab: Add a device, then a card for each paired device (owner, 2026-11-14,
/// by click: one card per device, its key facts and space bar shown, the rest folded under More details). Sections of
/// the tab's form, so the tab's own page scrolls. Add a device is a fold, open by itself only when no device is paired
/// (owner, 2026-11-14); the tab's refresh, sheets and dialog hang on the fold itself, there whether open or closed.
struct PrepareMePairingView: View {
    /// The devices' service's line beside the Paired devices heading, nil while Devices' status shows a problem
    var status: String?
    @ObservedObject private var pairing = PhonePairing.shared
    @ObservedObject private var store = PrepareMeMac.shared.store
    @State private var confirming: PairingDesk.Phone?
    @State private var files: PairingDesk.Phone?  // phase M: the phone whose Always or Never is being set
    @State private var opened: Set<String> = []  // the cards whose More details is open
    @State private var addOpen: Bool?  // Add a device as the person left it; nil until they open or close it
    @State private var replacing: String?  // Add a device's "paired before" pick, by PhonePairing.key; nil: a new one
    #if PREPAREME_CHECK
    // the check build only, for screenshots without clicks: PREPAREME_CHECK_DETAILS=open opens every More details
    private static let detailsOpen = ProcessInfo.processInfo.environment["PREPAREME_CHECK_DETAILS"] == "open"
    #else
    private static let detailsOpen = false
    #endif
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(get: { addOpen ?? (Self.detailsOpen || (pairing.phones?.isEmpty ?? true)) },
                                                set: { addOpen = $0 })) {
                addPane
            } label: {
                Text("Add a device").font(.pmHeadline)
            }
            .onAppear {
                pairing.refresh()
                #if PREPAREME_CHECK
                // the check build only, for a screenshot of the code's window without clicks: PREPAREME_CHECK_PAIR_CODE=
                // adult or child pairs a made-up device as Add a device's buttons do (family downloads plan, phase 1)
                if let kind = ProcessInfo.processInfo.environment["PREPAREME_CHECK_PAIR_CODE"] {
                    Task { await pairing.pair(readOnly: kind == "child") }
                }
                // family downloads plan, phase 6: PREPAREME_CHECK_FILES=<label> opens that device's Files… sheet
                if let label = ProcessInfo.processInfo.environment["PREPAREME_CHECK_FILES"] {
                    files = pairing.phones?.first { $0.label == label }
                }
                #endif
            }
            .onDisappear { pairing.clear() }
            .onReceive(tick) { _ in pairing.refresh() }
            .confirmationDialog(confirming.map { "Remove \(title(for: $0))?" } ?? "",
                                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                presenting: confirming) { phone in
                Button("Remove", role: .destructive) { Task { await pairing.remove(phone) } }
            } message: { phone in
                Text("It gets nothing new from this Mac until it is paired again. What it already has stays on it."
                     + (pairing.documentsGiven.contains(phone.label) ? " " + DocumentsWords.removeNote : ""))
            }
            .sheet(item: $files) { phone in PhoneFilesSheet(phone: phone, title: title(for: phone)) { files = nil } }
            // the code in a window of its own, big enough for all of it (Task 13.2; F42: its steps and Done had sat
            // below the fold of Settings' small scrolling pane)
            .sheet(isPresented: Binding(get: { pairing.paired != nil && pairing.picture != nil },
                                        set: { if !$0 { pairing.clear() } })) { codeSheet }
            // under the fold, not in it: a Remove, Files… or pairing that failed says so with the fold closed too
            if let problem = pairing.problem {
                Text(problem)
                    .font(.pmNote)
                    .foregroundStyle(PrepareMeColors.red)  // mostly refused: Not paired, nothing changed (spec section 10, rule 3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let phones = pairing.phones, !phones.isEmpty {
            ForEach(phones) { phone in
                Section {
                    card(phone)
                } header: {
                    if phone == phones.first { pairedHeader.foregroundStyle(PrepareMeColors.text2) }
                } footer: {
                    if phone == phones.last { phonesFooter.font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
                }
            }
        } else {
            Section {
                Text(pairing.phones == nil
                     ? "The devices' service hasn't listed its devices yet. It does within a few seconds of starting."
                     : "No devices are paired.")
                    .foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                pairedHeader.foregroundStyle(PrepareMeColors.text2)
            }
        }
    }

    /// The Paired devices heading, with the devices' service's line at its end when it is well (grey where it is used)
    private var pairedHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Paired devices").font(.pmHeadline)
            Spacer()
            if let status { Text(status).font(.pmNote) }
        }
    }

    @ViewBuilder private var addPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("At home, with the iPhone or iPad on the same Wi-Fi as this Mac. Whose is it?")
                .fixedSize(horizontal: false, vertical: true)
            if let phones = pairing.phones, !phones.isEmpty {  // a device paired again (family downloads, phase 6)
                Picker("Paired before?", selection: $replacing) {
                    Text("No, a new device").tag(String?.none)
                    ForEach(phones) { phone in Text("Yes, it is \(title(for: phone))").tag(Optional(PhonePairing.key(phone))) }
                }
                .fixedSize()
                Text(PairingWords.pairedBefore)
                    .font(.pmNote).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                choice("An adult's device", "Reads everything, and can change the inventory and lists.", readOnly: false)
                choice("A child's device", PairingWords.childDevice, readOnly: true)  // family downloads, phase 2
            }
            if pairing.waiting && pairing.removing == nil {
                ProgressView("Asking the devices' service…").controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var phonesFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let phone = pairing.removing {
                ProgressView("Removing \(phone.label)…").controlSize(.small)
            }
            Text(HomeMacWords.phoneNamesNote)
                .foregroundStyle(PrepareMeColors.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var codeSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let paired = pairing.paired, let picture = pairing.picture {
                Text("Scan this code with the iPhone or iPad").font(.pmTitle)
                Image(decorative: picture, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 280, height: 280)
                    .accessibilityLabel("The pairing code")
                Text("On the iPhone or iPad: PrepareMe › Downloads › Pair with the Mac, then point the camera at this code.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("This is \(paired.label), \(paired.readOnly ? "a child's device" : "an adult's device"). "
                     + "Press Done once it says paired; until it has visited, Paired devices lists it as "
                     + "\(PairingWords.waiting). The code is never saved, and clears itself after 10 minutes."
                     + (pairing.replaced(by: paired).map { " " + PairingWords.takesThePlace(of: title(for: $0)) } ?? ""))
                    .font(.pmNote)
                    .foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Done") { pairing.clear() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 400)
        .pmMacWindow()
    }

    private func choice(_ title: String, _ detail: String, readOnly: Bool) -> some View {
        Button {
            let before = pairing.phones?.first { PhonePairing.key($0) == replacing }
            replacing = nil
            Task { await pairing.pair(readOnly: readOnly, replacing: before) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.pmHeadline)
                Text(detail).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: PrepareMeCorners.panel).fill(PrepareMeColors.ground))
            .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.panel).stroke(PrepareMeColors.line))
            .contentShape(RoundedRectangle(cornerRadius: PrepareMeCorners.panel))
        }
        .buttonStyle(.plain)
        .disabled(pairing.waiting)
        .opacity(pairing.waiting ? 0.5 : 1)
    }

    /// One phone's card: its name box and buttons, whose it is, its space, its warnings, Essential Documents, and
    /// More details (when paired, its install, its last report), every line wrapping, none cut off.
    private func card(_ phone: PairingDesk.Phone) -> some View {
        let room = pairing.rooms[phone.label]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                // a box that says what it's for (Task 13.2; F42: an empty dark box held only a dim "phone 3")
                TextField("Name", text: Binding(get: { pairing.name(for: phone) },
                                                set: { pairing.setName($0, for: phone) }),
                          prompt: Text(PairingWords.namePrompt))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .font(.pmHeadline)
                    .frame(maxWidth: 260)
                Spacer(minLength: 8)
                Button("Files…") { files = phone }
                Button { confirming = phone } label: {  // red as its menu item (docs/design/menus.md, rule 3)
                    if pairing.waiting { Text("Remove…") } else { Text("Remove…").foregroundStyle(PrepareMeColors.red) }
                }
                    .disabled(pairing.waiting)
            }
            Text(PairingWords.kind(label: phone.label, readOnly: phone.readOnly, waiting: phone.waiting))
                .foregroundStyle(PrepareMeColors.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let room, !room.sharesRoom {
                Text(PhoneStorage.notSharedLine).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let room {
                PhoneRoomBar(bar: StorageWords.RoomBar(free: room.free, capacity: room.capacity,
                                                       prepareMe: prepareMeBytes(room)),
                             waiting: room.waiting.count)
            } else {
                Text("No space report yet: the device sends one at its next check at home.")
                    .foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(warnings(room, name: title(for: phone)), id: \.self) { line in
                Text(line).foregroundStyle(PrepareMeColors.caution).fixedSize(horizontal: false, vertical: true)
            }
            if !phone.readOnly { documents(phone) }  // Essential Documents: adults' phones only (owner, 2026-10-24)
            DisclosureGroup("More details", isExpanded: Binding(
                get: { Self.detailsOpen || opened.contains(phone.id) },
                set: { if $0 { opened.insert(phone.id) } else { opened.remove(phone.id) } })) { details(phone, room) }
        }
        .padding(.vertical, 6)
        // the whole card takes the right-click: without it only its words and boxes did, and the space between them
        // opened nothing (owner check 65, 2026-11-14)
        .contentShape(Rectangle())
        .contextMenu {  // the card's buttons, by right-click too (the Apple guidelines plan, phase 8)
            if canGive(phone), pairing.giving == nil {
                Button(DocumentsWords.giveButton) { Task { await pairing.give(phone) } }
            }
            Button("Files…") { files = phone }
            if !pairing.waiting {
                Divider()
                PMMenuDelete("Remove…") { confirming = phone }
            }
        }
    }

    /// The amber lines that stay in sight: base files with no room, not heard from, no Organic Maps, an install
    /// near its end or not updating itself, an opening check that found a problem
    private func warnings(_ room: PhoneStorage?, name: String) -> [String] {
        guard let room else { return [] }
        var lines: [String] = []
        if !room.cantUpdate.isEmpty { lines.append(PhoneRoomWords.cantUpdate(room.cantUpdate.count)) }
        if let unseen = room.unseenLine() { lines.append(unseen) }  // offline fixes, phase 2
        if let maps = room.organicMapsLine { lines.append(maps) }  // hand-off plan, 3.2
        if let install = room.installLine(), install.caution { lines.append(install.text) }
        if let opening = OpeningCheck.macLine(name: name, room.opening) { lines.append(opening) }  // opening check, 1.3
        return lines
    }

    private func documents(_ phone: PairingDesk.Phone) -> some View {
        let status = documentStatus(phone)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Essential Documents:").foregroundStyle(PrepareMeColors.text2)
                Text(status.text).foregroundStyle(status.caution ? PrepareMeColors.caution : PrepareMeColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = status.note {
                Text(note).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            }
            if canGive(phone) {
                Button(DocumentsWords.giveButton) { Task { await pairing.give(phone) } }
                    .disabled(pairing.giving != nil)
            }
        }
    }

    private func documentStatus(_ phone: PairingDesk.Phone) -> DocumentsWords.PhoneStatus {
        DocumentsWords.phoneStatus(
            asked: pairing.documentAsks[phone.label]?.at.flatMap { ISO8601DateFormatter().date(from: $0) },
            given: pairing.documentsGiven.contains(phone.label),
            report: pairing.documentReports[phone.label])
    }

    /// More details: each fact on its own labeled line
    private func details(_ phone: PairingDesk.Phone, _ room: PhoneStorage?) -> some View {
        var facts: [(String, String)] = []
        let added = ISO8601DateFormatter().date(from: phone.added)?.formatted(date: .abbreviated, time: .omitted)
        facts.append(("Paired", phone.waiting ? PairingWords.waiting.prefix(1).uppercased() + PairingWords.waiting.dropFirst()
                                              : added ?? "Not known"))
        if let room, room.build != nil || room.opensUntil != nil {
            let build = room.build.map { ", build \($0)" } ?? ""
            let how = [InstallExpiry.testflight: "TestFlight", InstallExpiry.appstore: "App Store"][room.channel ?? ""]
            facts.append(("Install", (how ?? "By cable") + build))
        }
        if room?.channel == InstallExpiry.appstore {  // Unlisted plan, phase 5: a store copy never stops opening
            facts.append(("Opens until", PhoneStorage.noEndDate))
        } else if let until = room?.opensUntil.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            facts.append(("Opens until", until.formatted(date: .long, time: .omitted)))
        }
        if let last = room?.opening?.last, last.ran {  // the opening self-check (phase 1)
            let found = OpeningCheck.summary(last)
            facts.append(("Opening check", found.prefix(1).uppercased() + found.dropFirst() + ", build \(last.build)"))
        }
        facts.append(("Last report", room?.at.flatMap { ISO8601DateFormatter().date(from: $0) }
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "None yet"))
        if !phone.readOnly, let checked = documentStatus(phone).reported {
            facts.append(("Documents checked", checked.formatted(date: .abbreviated, time: .shortened)))
        }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(facts, id: \.0) { fact in
                GridRow {
                    Text(fact.0).foregroundStyle(PrepareMeColors.text2)
                    Text(fact.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)  // a DisclosureGroup centers what it holds
    }

    /// PrepareMe's part of the bar: the Mac's sizes for the files the phone says it holds
    private func prepareMeBytes(_ room: PhoneStorage) -> Int64 {
        let sizes = Dictionary((store.record.manifest?.files ?? []).map { ($0.name, $0.size) }) { first, _ in first }
        return room.held.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    /// An adult's phone that asked and hasn't been given the key (owner, 2026-10-24: the owner approves each phone)
    private func canGive(_ phone: PairingDesk.Phone) -> Bool {
        !phone.readOnly && pairing.documentAsks[phone.label] != nil && !pairing.documentsGiven.contains(phone.label)
    }

    private func title(for phone: PairingDesk.Phone) -> String { pairing.title(for: phone) }
}
extension PairingDesk.Phone: @retroactive Identifiable {
    public var id: String { "\(label)|\(added)" }
}

/// A phone's space as a bar (owner, 2026-11-14, by click: "three parts and a line"): its own photos and apps, PrepareMe's
/// files, what's free, and a line where PrepareMe's kept-free space starts; free turns amber under the line. Each part
/// has its word and size beside its swatch, so the bar reads in red night and without color.
struct PhoneRoomBar: View {
    let bar: StorageWords.RoomBar
    let waiting: Int

    private var otherColor: Color { PrepareMeColors.text2.opacity(0.55) }
    private var freeColor: Color { bar.short ? PrepareMeColors.accent : PrepareMeColors.tile }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let scale = bar.capacity > 0 ? geo.size.width / CGFloat(bar.capacity) : 0
                HStack(spacing: 0) {
                    Rectangle().fill(otherColor).frame(width: CGFloat(bar.other) * scale)
                    Rectangle().fill(PrepareMeColors.infoMark).frame(width: CGFloat(bar.prepareMe) * scale)
                    Rectangle().fill(freeColor)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(PrepareMeColors.line))
                .overlay(alignment: .leading) {
                    Rectangle().fill(PrepareMeColors.ink).frame(width: 2, height: 22)
                        .offset(x: CGFloat(bar.capacity - bar.reserve) * scale - 1)
                }
            }
            .frame(height: 14)
            .padding(.vertical, 4)
            .accessibilityElement()
            .accessibilityLabel(bar.spoken)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { legend }
                VStack(alignment: .leading, spacing: 3) { legend }
            }
            HStack(spacing: 6) {
                Rectangle().fill(PrepareMeColors.ink).frame(width: 2, height: 12)
                Text(bar.reserveWords).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Text(bar.mapsWords + " " + PhoneRoomWords.waiting(waiting))
                .foregroundStyle(bar.short ? PrepareMeColors.caution : PrepareMeColors.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var legend: some View {
        key(otherColor, "Photos and apps", bar.otherWords)
        key(PrepareMeColors.infoMark, "PrepareMe", bar.prepareMeWords)
        key(freeColor, "Free", bar.freeWords)
    }

    private func key(_ color: Color, _ name: String, _ size: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(PrepareMeColors.line))
            Text(name)
            Text(size).foregroundStyle(PrepareMeColors.text2).monospacedDigit()
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Phase M: the words for a phone's room on the Mac's Phones list
enum PhoneRoomWords {
    static func waiting(_ count: Int) -> String {
        count == 0 ? "Nothing waits for room." : "\(count) \(count == 1 ? "file waits" : "files wait") for room."
    }

    static func cantUpdate(_ count: Int) -> String {
        "\(count) of its base \(count == 1 ? "files doesn't" : "files don't") fit: not enough room to get or update "
            + (count == 1 ? "it." : "them.")
    }
}

/// One device's files (phase M; family downloads plan, phase 6): By room, Offered, Always or Never for each file the
/// Mac offers the devices, each row only the words that apply, with the device's room now and after the choices. The
/// picks are held here and saved once, on Done; Cancel throws them away. The base files (the library, the street map,
/// the home-area topo) are on every device and aren't listed.
struct PhoneFilesSheet: View {
    let phone: PairingDesk.Phone
    let title: String
    let done: () -> Void
    @ObservedObject private var pairing = PhonePairing.shared
    @ObservedObject private var store = PrepareMeMac.shared.store
    @State private var picks: [String: String] = [:]  // stored values by file name, as phone-files.json holds them
    @State private var refused: [String: Int64] = [:]  // an Always refused at the floor, by file name: the floor
    @State private var loaded = false

    private var manifest: Manifest { store.record.manifest ?? Manifest(writtenAt: "", files: []) }
    private var room: PhoneStorage? { pairing.rooms[phone.label] }

    private var entries: [Manifest.Entry] {
        manifest.files.filter { $0.forPhones && $0.fetch != LibraryPlan.base }
            .sorted { ($0.order ?? Int.max, $0.name) < ($1.order ?? Int.max, $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files on \(title)").font(.pmTitle)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(PhoneCuration.intro, id: \.self) { Text($0) }
            }
            .font(.pmNote).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            Text(roomLine).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries, id: \.name) { entry in row(entry) }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("The library, the street map and the home-area topo are on every device.")
                    .font(.pmNote).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Done") { pairing.setFiles(picks, phone: phone); done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700, height: 600)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            picks = pairing.files(for: phone)
            #if PREPAREME_CHECK
            // the check build only, for pictures without clicks: PREPAREME_CHECK_FILES_PICKS="<file>=<word>,…" picks
            // each word as a click would (a refused Always included)
            for pair in (ProcessInfo.processInfo.environment["PREPAREME_CHECK_FILES_PICKS"] ?? "").split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, let word = PhoneCuration.Word(rawValue: parts[1]),
                   let entry = entries.first(where: { $0.name == parts[0] }) { pick(word, entry) }
            }
            #endif
        }
        .font(.pmBody)
    }

    /// The head's room: free space from the device's last report, with when, and after these choices
    private var roomLine: String {
        guard let room else { return "No space report yet: the device sends one at its next check at home." }
        guard room.sharesRoom else { return PhoneStorage.notSharedLine }
        let when = room.at.flatMap { ISO8601DateFormatter().date(from: $0) }
            .map { ", reported \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        let after = PhoneCuration.after(picks, room: room, child: phone.readOnly, in: manifest)
        return "Free on this device: \(StorageWords.size(room.free))\(when). After these choices: about "
            + "\(StorageWords.size(after))."
    }

    private func row(_ entry: Manifest.Entry) -> some View {
        let word = PhoneCuration.word(picks[entry.name], entry, child: phone.readOnly, in: manifest)
        let words = PhoneCuration.words(entry)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(HomeMacWords.title(entry))
                    Text(state(entry)).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    if word == .never, let freed = PhoneCuration.removes(entry, room: room) {
                        Text("Removes \(StorageWords.size(freed)) from this device.")
                            .font(.pmNote).foregroundStyle(PrepareMeColors.caution)
                    }
                    if let floor = refused[entry.name] {
                        Text(StorageWords.floorRefusal(floor: floor))
                            .font(.pmNote).foregroundStyle(PrepareMeColors.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Picker("", selection: Binding(get: { word }, set: { pick($0, entry) })) {
                    ForEach(words, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: CGFloat(words.count) * 82)
                .labelsHidden()
                .accessibilityLabel(HomeMacWords.title(entry))
            }
            .padding(.vertical, 6)
            Divider()
        }
    }

    /// A pick, held until Done; an Always that would take the room the library needs to update is refused here
    private func pick(_ word: PhoneCuration.Word, _ entry: Manifest.Entry) {
        if word == .always, let room,
           let floor = PhoneCuration.refusesAlways(entry.name, picks, room: room, child: phone.readOnly, in: manifest) {
            refused[entry.name] = floor
            return
        }
        refused[entry.name] = nil
        picks[entry.name] = PhoneCuration.stored(word, entry, child: phone.readOnly, in: manifest)
    }

    private func state(_ entry: Manifest.Entry) -> String {
        let size = StorageWords.size(entry.size)
        guard let room else { return size }
        if room.held.contains(entry.name) { return "\(size), on this device" }
        if room.waiting.contains(entry.name) { return "\(size), waiting for room" }
        return "\(size), not on this device"
    }
}
#endif

