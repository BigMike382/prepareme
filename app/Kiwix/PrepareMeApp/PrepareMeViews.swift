// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import PrepareMeShared
import SwiftUI
import UserNotifications
import VisionKit

/// The Home Mac screen: pairing, Check now, each file of the Mac's library and where it stands on this phone, and when
/// this install stops opening.
struct HomeMacView: View {
    @ObservedObject private var library = PrepareMeLibrary.shared
    @ObservedObject private var store = PrepareMeLibrary.shared.store
    @ObservedObject private var inventory = PhoneInventoryModel.shared
    @ObservedObject private var travel = PrepareMeTravel.store
    @State private var pairing = false
    @State private var addingFromFiles = false
    @State private var addingTravel = false
    @AppStorage(OpeningSelfCheck.reportKey) private var openingReport: Data?  // redrawn when a check finishes

    var body: some View {
        PMList {
            Section {  // no "Home Mac" heading: the screen's title says it (beta run 2, B2-21)
                if let code = MacLink.pairing {
                    Text(HomeMacWords.pairedLine(host: code.host, removed: library.lastProblem == .answered(401),
                                                 device: ThisDevice.word))
                    Button(library.busy ? "Checking…" : "Check now") { Task { await library.check(.checkNow) } }
                        .pmAction()
                        .disabled(library.busy)
                    if library.lastProblem != .answered(401) {  // the line above says it for a removed phone
                        Text(answer).font(.pmNote)  // an update asked for is caution, amber (audit P2h)
                            .foregroundStyle(library.lastProblem == .newer ? PrepareMeColors.caution : PrepareMeColors.text2)
                    }
                    if let refused = MacStatus.standingRefusal(store.lastRefusal, store.record) {  // F43's rule
                        Text("Last copy refused by its checks: \(refused).").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                    Button("Pair again") { pairing = true }.pmAction()
                    if inventory.isChild {  // the Mac's steps are in Pair again's sheet (F44; beta run 2, B2-21)
                        Text(HomeMacWords.pairStartsOnMac)
                            .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                } else {
                    Text("Not paired yet. " + HomeMacWords.pairSteps(device: ThisDevice.word))
                    Button("Pair with the Mac") { pairing = true }.pmAction()
                }
            }
            Section { RedNightSwitch(title: PrepareMeRedNight.title) }  // look 3 change 17: Inventory and Documents have no ••• menu to reach it from
            if let manifest = store.record.manifest {
                Section {
                    ForEach(HomeMacWords.ordered(manifest.files.filter { ($0.name.hasSuffix(".zim") || $0.isStreetMap) && $0.forPhones }), id: \.name) { entry in
                        FileRow(entry: entry)
                    }
                } header: {
                    Text("Library on this \(ThisDevice.word)").foregroundStyle(PrepareMeColors.text2)
                } footer: {
                    let room = PrepareMeLibrary.room()
                    Text(StorageWords.roomLine(free: room.free, capacity: room.capacity))  // B2-10
                        .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
            }
            if store.record.manifest?.files.contains(where: \.isStreetMap) == true {  // hand-off plan, 3.2
                Section(pmTitle: "Street map: directions") {
                    let installed = OrganicMapsCheck.installed  // read again each time the Mac's check redraws this
                    Text(OrganicMaps.installedWords(installed, device: ThisDevice.word))
                        .foregroundStyle(installed ? PrepareMeColors.ink : PrepareMeColors.caution)
                }
            }
            // combined step 9: other states' street maps, on a child's phone too (family downloads plan, phase 2)
            Section {
                if travel.locked { TravelDamagedRows() }  // phase K, finding 10
                ForEach(travel.held, id: \.entry.state) { held in TravelMapRow(held: held) }
                Button("Add a travel map") { addingTravel = true }.pmAction()
            } header: {
                Text("Street map: travel maps").foregroundStyle(PrepareMeColors.text2)
            } footer: {
                Text("Other states' street maps, from the \(TravelMaps.folderName) folder in iCloud Drive. The "
                     + "street map shows them with the home map.").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            let dropped = LibraryPlan.dropped(store.record)
            if !dropped.isEmpty {  // plan phase 8: kept here, no longer sent by the Mac
                Section(pmTitle: "No longer sent by the Mac") {
                    ForEach(dropped, id: \.entry.name) { held in
                        RemoveRow(entry: held.entry,
                                  note: "Kept on this \(ThisDevice.word); the Mac no longer sends it.")
                    }
                }
            }
            Section {  // concept-doc plan, phase B; a child's device too (family downloads plan, phase 2)
                Button("Add from Files") { addingFromFiles = true }.pmAction()
            } header: {
                Text("Away from the Mac").foregroundStyle(PrepareMeColors.text2)
            } footer: {
                Text("From the PrepareMe Backup folder, in iCloud Drive or on a USB-C drive.").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            Section(pmTitle: "This install") {
                // the build on its own row: Home Mac had no way to tell 1731 from 2049 (owner, 2026-11-14)
                if let build = InstallInfo.build { Text("Build \(build)") }
                if !InstallInfo.quiet { Text(InstallInfo.line) }  // a quiet copy: the build row alone (pre-submission fixes)
                if let update = UpdateSelfCheck.result {  // the update self-check (owner, 2026-11-14)
                    Text(UpdateCheck.words(update))
                        .foregroundStyle(update.dropped.isEmpty ? PrepareMeColors.ink : PrepareMeColors.caution)
                }
                // the opening self-check (phase 1, quiet): only on a paired device that had something to check
                if MacLink.pairing != nil, let last = OpeningSelfCheck.decode(openingReport)?.last, last.ran {
                    Text(OpeningCheck.words(last))
                        .foregroundStyle(last.foundProblem ? PrepareMeColors.caution : PrepareMeColors.ink)
                }
                if let words = InstallInfo.notUpdated {  // over-the-air plan, layer 3: two missed weekly rebuilds
                    Text(words).foregroundStyle(PrepareMeColors.caution)
                    Button("Update", action: InstallInfo.openTestFlight).pmAction()
                }
            }
        }
        .navigationTitle("Downloads")
        .pmTitleSmall()
        .onAppear { PrepareMeTabs.shared.markOffersSeen() }  // the offers' count (family downloads plan, phase 5)
        .sheet(isPresented: $pairing) {  // Pair again's sheet says the Mac's steps; Not paired yet's line already does
            PairView(steps: MacLink.pairing == nil || inventory.isChild ? nil
                     : HomeMacWords.pairSteps(device: ThisDevice.word, button: nil)) { pairing = false }
        }
        .fullScreenCover(isPresented: $addingFromFiles) { AddFromFilesView { addingFromFiles = false } }
        .fullScreenCover(isPresented: $addingTravel) { TravelMapsView { addingTravel = false } }
    }

    private var answer: String {
        if let problem = library.lastProblem { return problem.words }
        guard let at = store.record.checkedAt, let date = ISO8601DateFormatter().date(from: at) else {
            return "The Mac hasn't answered yet."
        }
        return "The Mac last answered \(date.formatted(date: .abbreviated, time: .shortened))."
    }
}

/// One file of the Mac's library and where it stands on this phone, with its button when it has one.
struct FileRow: View {
    let entry: Manifest.Entry
    @ObservedObject private var library = PrepareMeLibrary.shared
    @ObservedObject private var store = PrepareMeLibrary.shared.store
    @State private var answer: FileRow.GetAnswer?
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(FileRow.title(entry))
            Text(status).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            if LibraryPlan.isRefused(entry, store.record) {
                Button("Try again") { library.tryAgain(entry) }.pmAction()
            } else if !LibraryPlan.wanted(entry, store.record)
                        || library.waitingForRoom.contains(where: { $0.name == entry.name }) {
                // phase M: a map waiting its turn can still be asked for now, ahead of the order (review)
                Button("Download (\(StorageWords.size(entry.size)))") { answer = FileRow.get(entry) }
                    .pmAction()
            } else if LibraryPlan.removable(entry.name, store.record) {
                Button("Remove from this \(ThisDevice.word)", role: .destructive) { removing = true }.pmAction()
            } else if store.record.held[entry.name] != nil && LibraryPlan.keptByMac(entry, store.record) {
                Text(HomeMacWords.keptByMac(device: ThisDevice.word))  // phase 4, decision 8: no Remove on Always
                    .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
        }
        .contextMenu {  // a held finger: the row's button (docs/design/menus.md)
            FileRowMenu(entry: entry, offer: FileRowMenu.offer(entry), answer: $answer, removing: $removing)
                .equatable()
        }
        .modifier(DownloadAnswer(entry: entry, answer: $answer))
        .confirmationDialog("Remove \(FileRow.title(entry)) from this \(ThisDevice.word)?", isPresented: $removing,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await library.remove(entry.name) } }
        } message: {
            Text("It frees \(StorageWords.size(entry.size)). Get it again from here at home, over Wi-Fi.")
        }
    }

    /// The held-finger menu's Remove, the button's words in a menu's capitals and with its "…" (docs/design/menus.md)
    static var removeMenu: String { "Remove from This \(ThisDevice.word)…" }

    /// A file's name as shown: a download's catalog title, or a library's name without its prefix.
    static func title(_ entry: Manifest.Entry) -> String {
        HomeMacWords.title(entry)  // plain names, never a file name (beta run F40)
    }

    /// What Download says before it asks for the file (family downloads plan, phase 4)
    enum GetAnswer: Equatable {
        case refused(String)
        case ask(title: String, words: String)
    }

    /// Download: refused when it would leave less than the floor the library needs to update, asked first when it
    /// would leave under 10 GB (unless `asked`, the question's own Download), else nil and the file is asked for.
    static func get(_ entry: Manifest.Entry, asked: Bool = false) -> GetAnswer? {
        let floor = LibraryPlan.floor(PrepareMeLibrary.shared.store.record.manifest?.files)
        switch LibraryPlan.adding(entry.size, free: PrepareMeLibrary.availableBytes(), floor: floor) {
        case let .refused(floor): return .refused(StorageWords.floorReason(floor: floor))  // under "Not enough room"
        case let .ask(left) where !asked:
            return .ask(title: "Download \(title(entry))?", words: StorageWords.leaves(left, device: ThisDevice.word))
        default: break
        }
        PrepareMeLibrary.shared.get(entry)
        return nil
    }
}

/// FileRow's held-finger menu. Its own view, not an observer of the library, compared by what it offers: built in the
/// row, it was rebuilt on every 1% of a download, and an open menu on an iPhone redraws its rows each time (F-119).
struct FileRowMenu: View, Equatable {
    enum Offer: Equatable { case tryAgain, download, remove, none }
    let entry: Manifest.Entry
    let offer: Offer
    @Binding var answer: FileRow.GetAnswer?
    @Binding var removing: Bool

    /// The row's button, as FileRow's body picks it (the kept-by-Mac line has no command)
    static func offer(_ entry: Manifest.Entry) -> Offer {
        let library = PrepareMeLibrary.shared, record = library.store.record
        if LibraryPlan.isRefused(entry, record) { return .tryAgain }
        if !LibraryPlan.wanted(entry, record) || library.waitingForRoom.contains(where: { $0.name == entry.name }) {
            return .download
        }
        return LibraryPlan.removable(entry.name, record) ? .remove : .none
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.entry == b.entry && a.offer == b.offer }
    }

    var body: some View {
        switch offer {
        case .tryAgain:
            Button("Try Again", systemImage: "arrow.clockwise") { PrepareMeLibrary.shared.tryAgain(entry) }
        case .download:
            Button("Download (\(StorageWords.size(entry.size)))", systemImage: "arrow.down.circle") {
                answer = FileRow.get(entry)
            }
        case .remove: PMMenuDelete(FileRow.removeMenu, systemImage: "trash") { removing = true }
        case .none: EmptyView()
        }
    }
}

/// Download's refusal or question (phase 4): "Not enough room" with OK, or "Download [title]?" with Download and
/// Cancel; `then` runs once the file is asked for.
struct DownloadAnswer: ViewModifier {
    let entry: Manifest.Entry?
    @Binding var answer: FileRow.GetAnswer?
    var then: () -> Void = {}

    private var title: String {
        if case let .ask(title, _) = answer { return title }
        return "Not enough room"
    }

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(get: { answer != nil }, set: { if !$0 { answer = nil } })) {
            if case .ask = answer {
                Button("Download") {
                    answer = entry.flatMap { FileRow.get($0, asked: true) }
                    if answer == nil { then() }
                }
                Button("Cancel", role: .cancel) { answer = nil }
            } else {
                Button("OK") { answer = nil }
            }
        } message: {
            switch answer {
            case let .refused(words)?: Text(words)
            case let .ask(_, words)?: Text(words)
            case nil: Text("")
            }
        }
    }
}

/// A file kept on the phone that the Mac no longer sends, with Remove (on a child's phone too: family downloads, phase 2).
struct RemoveRow: View {
    let entry: Manifest.Entry
    let note: String
    @ObservedObject private var store = PrepareMeLibrary.shared.store
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(FileRow.title(entry))
            Text(note).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            Button("Remove from this \(ThisDevice.word)", role: .destructive) { removing = true }.pmAction()
        }
        .contextMenu { RemoveMenu(removing: $removing).equatable() }
        .confirmationDialog("Remove \(FileRow.title(entry)) from this \(ThisDevice.word)?", isPresented: $removing,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await PrepareMeLibrary.shared.remove(entry.name) } }
        }
    }
}

/// RemoveRow's held-finger menu, its one Remove, compared as always the same: the row was rebuilt on some of a
/// download's 1% steps (F-119), and the menu never changes.
struct RemoveMenu: View, Equatable {
    @Binding var removing: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool { true }

    var body: some View {
        PMMenuDelete(FileRow.removeMenu, systemImage: "trash") { removing = true }
    }
}

extension FileRow {
    private var status: String { Self.status(entry) }

    /// Where a file stands on this device, as its Downloads row says it (the Library's cards too: phase 5)
    static func status(_ entry: Manifest.Entry) -> String {
        let library = PrepareMeLibrary.shared, store = library.store
        if let share = library.progress[entry.name] { return "Downloading: \(Int(share * 100))%" }
        if let note = store.notes[entry.name] { return note }
        if LibraryPlan.isCurrent(entry, store.record) {  // what the phone knows, never "Up to date" (beta run F03)
            return HomeMacWords.status(entry: entry, current: true, check: library.checkResult,
                                       device: ThisDevice.word, lastReached: library.lastReached)
        }
        let charging = LibraryPlan.waitsForPower(entry, store.record)  // offline fixes, phase 5
            ? " It may wait until this \(ThisDevice.word) is charging on Wi-Fi." : ""
        if store.record.held[entry.name] != nil { return "A newer copy is waiting to download." + charging }
        if store.record.manifest?.choices?[entry.name] == "never" {  // phase M: set on the Mac for this phone
            return "Not taken on this \(ThisDevice.word) (set on the Mac)."
        }
        if library.waitingForRoom.contains(where: { $0.name == entry.name }) {
            return "Waiting for room (\(StorageWords.size(entry.size))): it comes in its turn when "
                + "this \(ThisDevice.word) has the space."
        }
        if LibraryPlan.wanted(entry, store.record) {
            return "Waiting to download (\(StorageWords.size(entry.size)))." + charging
        }
        return "Not on this \(ThisDevice.word)."
    }
}

/// Phase 4's question before an add from Files or a travel map that leaves under 10 GB: its title and words, and the
/// add itself, run on Add
struct RoomAsk {
    let title: String
    let words: String
    let go: () -> Void
}

extension View {
    func roomAsk(_ ask: Binding<RoomAsk?>) -> some View {
        alert(ask.wrappedValue?.title ?? "", isPresented: Binding(get: { ask.wrappedValue != nil },
                                                                  set: { if !$0 { ask.wrappedValue = nil } })) {
            Button("Add") {
                let go = ask.wrappedValue?.go
                ask.wrappedValue = nil
                go?()
            }
            Button("Cancel", role: .cancel) { ask.wrappedValue = nil }
        } message: {
            Text(ask.wrappedValue?.words ?? "")
        }
    }
}

/// "Get this file": a link into a library this phone doesn't hold, when the Mac's list has it.
struct GetFileSheet: View {
    let entry: Manifest.Entry
    let done: () -> Void
    @State private var answer: FileRow.GetAnswer?

    var body: some View {
        NavigationStack {
            ScrollView {  // scrolls at the large text sizes, the button included (spec section 8, fix 1)
                VStack(alignment: .leading, spacing: 16) {
                    Text("This page is in a file that isn't on this \(ThisDevice.word).")
                    let free = StorageWords.size(PrepareMeLibrary.availableBytes())
                    Text("It is \(StorageWords.size(entry.size)); this \(ThisDevice.word) has \(free) free. It downloads "
                         + "from the Mac at home, over Wi-Fi.")
                        .foregroundStyle(PrepareMeColors.text2)
                    // said before anything starts (plan phase 8): the refusal, or phase 4's question
                    Button("Download (\(StorageWords.size(entry.size)))") {
                        answer = FileRow.get(entry)
                        if answer == nil { done() }
                    }
                    .pmAction()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Not on this \(ThisDevice.word)")
            .pmTitleSmall()
            .toolbar { Button("Not now", action: done) }
            .modifier(DownloadAnswer(entry: entry, answer: $answer, then: done))
        }
        .presentationDetents([.medium, .large])
    }
}

/// A Library card on the phones (family downloads plan, phase 5): the shared card's face, which opens a held file or
/// an offer's sheet, and below it an offer's Download (`OfferAction`) or a held family download's Remove from this
/// phone (never on an Always: "Kept on this phone (set on the Mac).") Its held-finger menu holds the same commands
/// (docs/design/menus.md). Our own collections have neither.
struct PhoneLibraryCard: View {
    let item: LibraryShelf.Item
    let shelf: LibraryShelf
    let emoji: String?
    let open: () -> Void
    @ObservedObject private var store = PrepareMeLibrary.shared.store
    @ObservedObject private var library = PrepareMeLibrary.shared  // the offer's progress and the Mac's last answer
    @State private var answer: FileRow.GetAnswer?
    @State private var removing = false
    @State private var details = false

    /// A family download this device holds: the one Remove reaches
    private var held: HeldFile? {
        guard item.offer == nil, item.notChecked else { return nil }
        return store.record.held.values.first { UUID(uuidString: $0.entry.id) == item.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { if item.offer == nil { open() } else { details = true } } label: {
                PrepareMeLibraryCard(item: item, shelf: shelf, emoji: emoji)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(item.offer == nil ? "" : "Shows what it is and its Download")
            if let offer = item.offer {
                OfferAction(entry: offer, answer: $answer)
            } else if let held {
                if LibraryPlan.removable(held.entry.name, store.record) {
                    Button("Remove from this \(ThisDevice.word)", role: .destructive) { removing = true }.pmAction()
                } else if LibraryPlan.keptByMac(held.entry, store.record) {
                    Text(HomeMacWords.keptByMac(device: ThisDevice.word))
                        .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
            }
        }
        .padding(14).pmPanel().contentShape(.rect(cornerRadius: PrepareMeCorners.panel))
        .contextMenu {
            PhoneCardMenu(offer: item.offer, stand: item.offer.map(OfferAction.stand),
                          removable: held.map { LibraryPlan.removable($0.entry.name, store.record) } ?? false,
                          open: open, answer: $answer, removing: $removing)
                .equatable()
        }
        .modifier(DownloadAnswer(entry: item.offer, answer: $answer))
        .confirmationDialog("Remove \(item.title) from this \(ThisDevice.word)?", isPresented: $removing,
                            titleVisibility: .visible, presenting: held) { held in
            Button("Remove", role: .destructive) { Task { await library.remove(held.entry.name) } }
        } message: { held in  // as Downloads' Remove asks
            Text("It frees \(StorageWords.size(held.entry.size)). Download it again here at home, over Wi-Fi.")
        }
        .sheet(isPresented: $details) { OfferSheet(item: item) { details = false } }
    }
}

/// PhoneLibraryCard's held-finger menu, compared by what it offers, as FileRowMenu (F-119): the card observes the
/// library, so every 1% of any download rebuilt it.
struct PhoneCardMenu: View, Equatable {
    let offer: Manifest.Entry?
    let stand: OfferAction.Stand?
    let removable: Bool
    let open: () -> Void
    @Binding var answer: FileRow.GetAnswer?
    @Binding var removing: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.offer == b.offer && a.stand == b.stand && a.removable == b.removable }
    }

    var body: some View {
        if let offer, let stand {
            OfferAction.menu(offer, stand: stand) { answer = FileRow.get(offer) }
        } else if removable {
            Button("Open", systemImage: "book", action: open)
            Divider()
            PMMenuDelete(FileRow.removeMenu, systemImage: "trash") { removing = true }
        }
    }
}

/// An offer's Download, on its Library card and its sheet (family downloads plan, phase 5): Try again for a refused
/// copy; once asked for, where it stands, as its Downloads row says it, with the progress bar while it downloads; else
/// "Not enough room (needs X free)" with the way to Downloads, or Download, which reads "Download at home" while the
/// Mac didn't answer the last check (a tap then asks for it, so it starts by itself at the next answered check).
struct OfferAction: View {
    let entry: Manifest.Entry
    @Binding var answer: FileRow.GetAnswer?
    var then: () -> Void = {}
    @ObservedObject private var library = PrepareMeLibrary.shared
    @ObservedObject private var store = PrepareMeLibrary.shared.store

    enum Stand: Equatable { case refused, asked, noRoom(need: Int64), download, atHome }

    @MainActor static func stand(_ entry: Manifest.Entry) -> Stand {
        let library = PrepareMeLibrary.shared, record = library.store.record
        if LibraryPlan.isRefused(entry, record) { return .refused }
        // as FileRow: a file waiting its turn for room can still be asked for now
        if LibraryPlan.wanted(entry, record) && !library.waitingForRoom.contains(where: { $0.name == entry.name }) {
            return .asked
        }
        let floor = LibraryPlan.floor(record.manifest?.files)
        if case .refused = LibraryPlan.adding(entry.size, free: PrepareMeLibrary.availableBytes(), floor: floor) {
            return .noRoom(need: LibraryPlan.need(entry, record, floor: floor))
        }
        return library.lastProblem == nil ? .download : .atHome
    }

    static func downloadWords(_ entry: Manifest.Entry) -> String { "Download (\(StorageWords.size(entry.size)))" }

    /// The held-finger menu's item: the button's command in a menu's capitals (docs/design/menus.md)
    @MainActor @ViewBuilder static func menu(_ entry: Manifest.Entry, stand: Stand,
                                             download: @escaping () -> Void) -> some View {
        switch stand {
        case .refused:
            Button("Try Again", systemImage: "arrow.clockwise") { PrepareMeLibrary.shared.tryAgain(entry) }
        case .asked: EmptyView()
        case .noRoom:
            Button("Open Downloads", systemImage: "arrow.down.circle") { PrepareMeTabs.shared.openHomeMac() }
        case .download: Button(downloadWords(entry), systemImage: "arrow.down.circle", action: download)
        case .atHome: Button("Download at Home", systemImage: "arrow.down.circle", action: download)
        }
    }

    var body: some View {
        let stand = Self.stand(entry)
        VStack(alignment: .leading, spacing: 8) {
            switch stand {
            case .refused:
                note(FileRow.status(entry))
                Button("Try again") { library.tryAgain(entry) }.pmAction()
            case .asked:
                if let share = library.progress[entry.name] { ProgressView(value: share).tint(PrepareMeColors.teal) }
                note(library.lastProblem == nil ? FileRow.status(entry) : HomeMacWords.waitingForMac)
            case let .noRoom(need):
                note(HomeMacWords.noRoom(need: need))
                Button(HomeMacWords.openDownloads) { PrepareMeTabs.shared.openHomeMac() }.pmAction()
            case .download, .atHome:
                if stand == .atHome { note(HomeMacWords.waitingForMac) }
                Button(stand == .atHome ? HomeMacWords.downloadAtHome : Self.downloadWords(entry)) {
                    answer = FileRow.get(entry)
                    if answer == nil { then() }
                }
                .pmAction()
            }
        }
    }

    private func note(_ words: String) -> some View {
        Text(words).font(.pmNote).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
    }
}

/// A tap on a Not downloaded card (family downloads plan, phase 5): its name, description, Inside, size and this
/// device's free space, the at-home line, and Download.
struct OfferSheet: View {
    let item: LibraryShelf.Item
    let done: () -> Void
    @ObservedObject private var library = PrepareMeLibrary.shared
    @State private var answer: FileRow.GetAnswer?

    var body: some View {
        NavigationStack {
            ScrollView {  // scrolls at the large text sizes, the button included
                VStack(alignment: .leading, spacing: 16) {
                    if let about = PrepareMeTabs.shared.shelf.description(for: item) { Text(about) }
                    if let inside = item.inside, !inside.isEmpty { Text("\(Text("Inside:").bold()) \(inside)") }
                    if let offer = item.offer {
                        Text(HomeMacWords.sizeAndFree(size: offer.size, free: PrepareMeLibrary.availableBytes(),
                                                      device: ThisDevice.word)
                             + (library.lastProblem == nil ? " " + HomeMacWords.atHome : ""))
                            .foregroundStyle(PrepareMeColors.text2)
                        OfferAction(entry: offer, answer: $answer, then: done)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(InventoryLook.title(item.title))
            .pmTitleSmall()
            .toolbar { Button("Done") { done() } }
            .modifier(DownloadAnswer(entry: item.offer, answer: $answer, then: done))
        }
        .presentationDetents([.medium, .large])
    }
}

/// The first screen before any library has arrived: what to do, never Kiwix's online catalog.
struct PrepareMeWelcome: View {
    @State private var pairing = false
    @State private var addingFromFiles = false

    var body: some View {
        PMStateScreen {  // look 3: the one look for "not set up" (spec section 10)
            if MacLink.pairing == nil {
                PMState(symbol: "desktopcomputer", heading: "PrepareMe",
                        line: "Pair this \(ThisDevice.word) with the Mac at home to get the library.",
                        action: ("Pair with the Mac", { pairing = true }))
                // concept-doc plan, phase B (2026-10-18): a phone never paired may fill itself from the backup, an
                // adult's OK on each list it can't vouch for (FolderOffer); the same screen as Home Mac's
                Text("Away from the Mac? Add the library from Files: the PrepareMe Backup folder, in "
                     + "iCloud Drive or on a USB-C drive.")
                    .foregroundStyle(PrepareMeColors.text2)
                    .padding(.horizontal, 24)
                Button("Add from Files") { addingFromFiles = true }.pmAction(fullWidth: false)
                if PrepareMeSample.shared.offered {  // Unlisted plan, phase 4: a look before setting up
                    Text(SampleLibrary.tryWhy)
                        .foregroundStyle(PrepareMeColors.text2)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    Button(SampleLibrary.tryIt) { Task { await PrepareMeSample.shared.start() } }
                        .pmAction(fullWidth: false)
                }
            } else {
                // its next step (spec section 10, rule 2): Home Mac, a tab or, on an adult's iPhone, the bar's sheet
                PMState(symbol: "desktopcomputer", heading: "PrepareMe", line: StateWords.welcomePaired,
                        action: (StateWords.openHomeMac, { PrepareMeTabs.shared.openHomeMac() }))
            }
        }
        .sheet(isPresented: $pairing) { PairView { pairing = false } }
        .fullScreenCover(isPresented: $addingFromFiles) { AddFromFilesView { addingFromFiles = false } }
    }
}

/// The iPhone's Library button: the libraries on this phone and the Home Mac screen; no online catalog.
struct PrepareMeLibraryTab: View {
    let dismiss: (() -> Void)?

    var body: some View {
        TabView {
            SheetContent { ZimFilesOpenedNavStack(dismiss: dismiss) }
                .tabItem { Label("Libraries", systemImage: "books.vertical") }
            SheetContent { HomeMacView() }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            PhoneInventoryTab()  // plan phase 7, slice 5
                .tabItem { Label("Inventory", systemImage: "shippingbox") }
        }
        .modifier(BinLabelSheet())  // a sheet shows only over the top screen: this one, while it is up
    }
}

/// A bin label scanned with the Camera (plan phase 7, slice 6): that bin's list. On the app's main screen and on the
/// Library sheet too, since iPhone shows a new sheet only over the screen on top (owner, 2026-10-14: a label scanned
/// with the Inventory tab open showed only once the sheet was closed).
struct BinLabelSheet: ViewModifier {
    @ObservedObject private var inventory = PhoneInventoryModel.shared

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { inventory.openedPlace.map(Opened.init) },
                                    set: { inventory.openedPlace = $0?.id })) { opened in
            NavigationStack {
                Group {
                    if let copy = inventory.shown, let place = copy.places.first(where: { $0.id == opened.id }) {
                        PlaceContents(copy: copy, place: place)
                    } else if inventory.busy {
                        ProgressView("Getting the inventory from the Mac…").padding()
                    } else {
                        PMStateScreen {  // look 3's one look; the sentence says where to go (spec section 10)
                            PMState(symbol: "shippingbox", heading: StateWords.binNotInCopy(device: ThisDevice.word), line: "")
                        }
                    }
                }
                .toolbar { Button("Done") { inventory.openedPlace = nil } }
            }
        }
    }

    struct Opened: Identifiable {
        let id: Int64
    }
}

/// The get-file sheet and the install's expiry warning, over every screen.
struct PrepareMeSheets: ViewModifier {
    @ObservedObject private var library = PrepareMeLibrary.shared
    @State private var warnedToday = false

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { library.offered.map(Offered.init) }, set: { library.offered = $0?.entry })) {
                GetFileSheet(entry: $0.entry) { library.offered = nil }
            }
            .modifier(BinLabelSheet())
            .alert("This install stops opening soon", isPresented: warning) {
                if InstallInfo.testflight {
                    Button("Update", action: InstallInfo.openTestFlight)  // over-the-air plan, layer 3
                } else {
                    Button("OK") {}
                }
            } message: {
                Text(InstallInfo.warning)
            }
    }

    private var warning: Binding<Bool> {
        Binding(get: { InstallInfo.warnNow && !warnedToday }, set: { _ in
            InstallInfo.warned()
            warnedToday = true
        })
    }

    struct Offered: Identifiable {
        let entry: Manifest.Entry
        var id: String { entry.name }
    }
}

/// This device in the screens' words: "iPad" on an iPad, else "phone" ("Library on this iPad"; beta run F07, and
/// 2026-10-18 for every screen). The one place that asks; the shared words take it as their `device`.
@MainActor
enum ThisDevice {
    static let word = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "phone"
}

/// Whether Organic Maps is on this device, as the directions alert decides (canOpenURL; Info.plist's
/// LSApplicationQueriesSchemes lists om): Home Mac's line and the room report to the Mac (hand-off plan, 3.2).
enum OrganicMapsCheck {
    static var installed: Bool { URL(string: "\(OrganicMaps.scheme)://map").map(UIApplication.shared.canOpenURL) ?? false }
}

/// The update self-check (UpdateCheck; owner, by click, 2026-11-14): this device's counts, numbers only, kept each
/// time PrepareMe opens and goes to the background; a different build's first opening compares them with the build
/// before's, from what is on the device before anything is fetched, and keeps the result for this build.
@MainActor
enum UpdateSelfCheck {
    static let countsKey = "PrepareMe.updateCounts"
    static let resultKey = "PrepareMe.updateResult"

    /// This build's result, nil before its first update
    static var result: UpdateCheck.Result? {
        UserDefaults.standard.data(forKey: resultKey).flatMap { try? JSONDecoder().decode(UpdateCheck.Result.self, from: $0) }
    }

    static func counts() -> UpdateCheck.Counts {
        let copy = PhoneInventoryModel.shared.sample ? nil : PhoneInventoryModel.shared.copy  // never the sample's
        let files = PhoneDocumentsModel.root.map { $0.appendingPathComponent("files", isDirectory: true) }
        let sealed = files.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?
            .filter { $0.hasSuffix(".pmdoc") }.count ?? 0
        let found = [PrepareMeLibrary.shared.record.held.count, copy?.items.count ?? 0, copy?.places.count ?? 0,
                     copy?.marks?.count ?? 0, copy?.pins?.count ?? 0, sealed, MacLink.pairing == nil ? 0 : 1]
        return UpdateCheck.Counts(build: InstallInfo.build ?? "", counts: Dictionary(uniqueKeysWithValues: zip(UpdateCheck.kinds, found)))
    }

    /// At each opening, before the library and inventory are fetched: a different build compares, then the counts kept
    static func opened() {
        let now = counts()
        let before = UserDefaults.standard.data(forKey: countsKey)
            .flatMap { try? JSONDecoder().decode(UpdateCheck.Counts.self, from: $0) }
        if let found = UpdateCheck.compare(before, now), let data = try? JSONEncoder().encode(found) {
            UserDefaults.standard.set(data, forKey: resultKey)
        }
        keep(now)
    }

    /// Going to the background: the counts as they are now, the ones the next build compares with
    static func wentToBackground() { keep(counts()) }

    private static func keep(_ counts: UpdateCheck.Counts) {
        if let data = try? JSONEncoder().encode(counts) { UserDefaults.standard.set(data, forKey: countsKey) }
    }
}

/// When this install stops opening: never for a copy from the App Store (Unlisted plan, phase 5), a TestFlight build's
/// stamped time plus 90 days, else its provisioning profile's end (over-the-air plan, phase 2); warned about once a day
/// in its last 30 days (its last 2 for an install that lasts a week), with Update in place of OK on a TestFlight build,
/// and by the phone's own notifications (InstallNotices).
enum InstallInfo {
    static let profile: Data? = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? Data(contentsOf: $0) }
    /// The stamp and the receipt's name this copy was installed with
    private static let installed: (stamp: String?, receipt: String?) = {
        var stamp = Bundle.main.object(forInfoDictionaryKey: "PrepareMeChannel") as? String
        var receipt = Bundle.main.appStoreReceiptURL?.lastPathComponent
        #if targetEnvironment(simulator)
        // A simulator has no store or TestFlight receipt: this stands in for one (a device build has no such code;
        // kiwix-mac/tests/test_check_install.py holds that)
        switch ProcessInfo.processInfo.environment["PREPAREME_CHECK_INSTALL"] {
        case "appstore": (stamp, receipt) = (InstallExpiry.appstore, "receipt")
        case "testflight": (stamp, receipt) = (InstallExpiry.appstore, "sandboxReceipt")  // the store build via TestFlight
        default: break
        }
        #endif
        return (stamp, receipt)
    }()
    /// "appstore", "testflight" or nil (cable), from the stamp build.sh writes (--app-store, --app-testflight) and how
    /// this copy was installed (InstallExpiry.channel): a store-stamped build that came through TestFlight is "testflight"
    static let channel: String? = InstallExpiry.channel(stamp: installed.stamp, hasProfile: profile != nil,
                                                        receipt: installed.receipt)
    static let built: Date? = {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_INSTALL"] == "testflight" { return Date() }  // a fresh one
        #endif
        return InstallExpiry.built(Bundle.main.object(forInfoDictionaryKey: "PrepareMeBuilt") as? String)
    }()
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    static var testflight: Bool { channel == InstallExpiry.testflight && built != nil }
    static var store: Bool { channel == InstallExpiry.appstore }
    /// What the phone tells the Mac: a stamped build with no stamped time reports as cable, as before
    static var reported: String? { store ? InstallExpiry.appstore : testflight ? InstallExpiry.testflight : nil }
    static let expiry: Date? = InstallExpiry.end(channel: channel, built: built,
                                                 profile: profile.flatMap(InstallExpiry.date(fromProfile:)))
    /// The store build not installed by the store (InstallExpiry.quiet): no date line, TestFlight word, Update or
    /// notification question until its last 30 days (the pre-submission fixes); it still reports TestFlight to the Mac
    static var quiet: Bool {
        InstallExpiry.quiet(stamp: installed.stamp, channel: channel,
                            daysLeft: expiry.map { InstallExpiry.daysLeft($0, now: Date()) })
    }

    static var line: String {
        if store { return HomeMacWords.storeLine }
        guard let expiry else { return "This install has no expiry date (a simulator build)." }
        let days = InstallExpiry.daysLeft(expiry, now: Date())
        let until = expiry.formatted(date: .long, time: .omitted)
        return testflight ? HomeMacWords.testflightLine(until: until, days: days)
            : "This install opens until \(until) (\(days) days)."
    }

    /// Home Mac's and Today's sentence beside Update once a TestFlight build is 21 days old; nil otherwise
    static var notUpdated: String? {
        guard testflight, !quiet, let built else { return nil }
        let days = InstallExpiry.daysOld(built, now: Date())
        return days >= InstallExpiry.staleDays ? HomeMacWords.notUpdated(days: days) : nil
    }

    @MainActor static var warning: String {
        testflight ? HomeMacWords.testflightWarning(until: line, device: ThisDevice.word)
            : HomeMacWords.yearlyWarning(until: line, device: ThisDevice.word)  // F47
    }

    static var warnNow: Bool {
        let created = testflight ? nil : profile.flatMap(InstallExpiry.created(fromProfile:))
        let warnDays = InstallExpiry.warnDays(created: created, expiry: expiry ?? .distantFuture)
        guard let expiry, InstallExpiry.daysLeft(expiry, now: Date()) <= warnDays else { return false }
        let last = UserDefaults.standard.double(forKey: "expiryWarnedAt")
        return Date().timeIntervalSince1970 - last >= 86400
    }

    static func warned() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "expiryWarnedAt")
    }

    /// Update: TestFlight itself (Apple documents no address for an app's own page there, and none for TestFlight
    /// either: itms-beta is the one apps use), else TestFlight's App Store page, where Open does the same
    static func openTestFlight() {
        UIApplication.shared.open(URL(string: "itms-beta://")!) { opened in
            if !opened { UIApplication.shared.open(URL(string: "https://apps.apple.com/app/testflight/id899247664")!) }
        }
    }
}

/// The install's end told by the phone itself (over-the-air plan, phase 2, layer 3): a notification at 30, 14, 7, 3
/// and 1 days left on a TestFlight build, 60, 30, 14, 7 and 1 on a cable install, set again at each open, so a newer
/// build's date replaces an older one's and no internet is needed. A TestFlight build asks iOS's question once (its
/// one-time setup, plan section 3, step 10); a cable install never asks, as the expiry reminders don't (F38).
@MainActor
enum InstallNotices {
    static let prefix = "install-end-"

    static func isNotice(_ identifier: String) -> Bool { identifier.hasPrefix(prefix) }

    static func schedule() {
        let expiry = InstallInfo.expiry
        let testflight = InstallInfo.testflight, quiet = InstallInfo.quiet
        Task {
            let center = UNUserNotificationCenter.current()
            let old = await center.pendingNotificationRequests().map(\.identifier).filter(isNotice)
            center.removePendingNotificationRequests(withIdentifiers: old)
            // no end (a store copy, Unlisted plan phase 5): an earlier build's "tap Update" notices go, shown ones too
            guard let expiry else {
                let shown = await center.deliveredNotifications().map(\.request.identifier).filter(isNotice)
                center.removeDeliveredNotifications(withIdentifiers: shown)
                return
            }
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined && testflight && !quiet {  // a quiet copy asks in its last 30 days
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                status = await center.notificationSettings().authorizationStatus
            }
            guard status == .authorized || status == .provisional else { return }
            for days in InstallExpiry.noticeDays(channel: InstallInfo.channel) {
                let at = expiry.addingTimeInterval(-Double(days) * 86400)
                guard at > Date() else { continue }
                var when = Calendar.current.dateComponents([.year, .month, .day], from: at)
                when.hour = 10  // mid-morning, not the hour the build happened to be made
                let content = UNMutableNotificationContent()
                content.title = HomeMacWords.endNoticeTitle
                content.body = HomeMacWords.endNotice(days: days, testflight: testflight)
                try? await center.add(UNNotificationRequest(
                    identifier: prefix + String(days), content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
            }
        }
    }
}

/// Pairing: the camera reads the code on the Mac's screen; pasting the code is the fallback, behind "Can't scan?"
/// unless the camera can't be used (remaining-findings plan, Task 9.3; F46; owner, 2026-10-18, by click). Once the
/// code is kept the sheet says "Paired with …", as the Mac's "Press Done once the phone says paired" expects.
struct PairView: View {
    var steps: String?  // the Mac's steps, from Pair again (beta run 2, B2-21)
    let done: () -> Void
    @State private var pasted = ""
    @State private var problem = ""
    @State private var problemKind = PMMessageKind.damaged  // refused red, an empty box's ask amber (section 10)
    @State private var pasting = false
    @State private var paired: String?
    @State private var scanner = 0  // a new scanner after a code that isn't PrepareMe's, so it looks again

    private var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            // scrolls, so the steps at the largest text size never push Pair and its message out of reach (R2.3 fix 1)
            ScrollView { VStack(alignment: .leading, spacing: 16) {
                if let paired {
                    Text(paired).font(.pmTitle)
                    Text("Now press Done on the Mac.").foregroundStyle(PrepareMeColors.text2)
                    Button("Done", action: done).pmAction()
                } else {
                    if let steps { Text(steps).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
                    if canScan {
                        Scanner { text in use(text, scanned: true) }
                            .id(scanner)
                            .frame(height: 300)  // a fixed height: a scroll view offers the camera no height of its own
                    } else {
                        CameraCantScan(words: StateWords.cantReadPairing)
                    }
                    if pasting || !canScan {
                        // one line that ends at Return, so Pair stays in reach on the SE (beta run 3, B3-07); a code
                        // is one line of JSON
                        TextField("Paste the pairing code", text: $pasted)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.go)
                            .onSubmit { use(pasted, scanned: false) }
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: pasted) { problem = "" }  // a code still arriving is never called wrong
                        Button("Pair") { use(pasted, scanned: false) }.pmAction()
                    } else {
                        Button("Can't scan?") { pasting = true }.pmAction()
                    }
                    if !problem.isEmpty { Text(problem).foregroundStyle(problemKind.color) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding() }
            .pmScreen()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Pair with the Mac")
            .pmTitleSmall()
            .toolbar {  // Cancel at the leading edge, Done at the trailing one (Apple's sheets page)
                if paired == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { done() } }  // the bar's, not the page's
                }
            }
        }
    }

    private func use(_ text: String, scanned: Bool) {
        if !scanned, let empty = HomeMacWords.pasteProblem(text) {  // an empty box asks for the code (beta run 2, B2-19)
            problem = empty
            problemKind = .attention
            return
        }
        do {
            try MacLink.pair(text)
            LocalNetworkPermission.ask()
            Task { await PrepareMeLibrary.shared.check() }
            Task { await PhoneInventoryModel.shared.paired() }  // adult's or child's, known at once (beta run F58)
            paired = HomeMacWords.pairedLine(host: MacLink.pairing?.host ?? "the Mac", removed: false)
        } catch let refused as MacLink.Problem {
            problem = "The code couldn't be kept: \(refused.words)"
            problemKind = .damaged
            if scanned { lookAgain() }
        } catch {
            problem = HomeMacWords.notAPairingCode
            problemKind = .damaged
            if scanned { lookAgain() }
        }
    }

    /// The camera stopped on a code it couldn't use: look again in a moment (a new scanner), the paste box shown too.
    private func lookAgain() {
        pasting = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            scanner += 1
        }
    }
}

/// VisionKit's scanner, for QR codes only.
struct Scanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var used = false

        init(found: @escaping (String) -> Void) {
            self.found = found
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case let .barcode(code) in items {
                guard !used, let text = code.payloadStringValue else { continue }
                used = true
                scanner.stopScanning()
                found(text)
            }
        }
    }
}
#else
/// The Mac build compiles MacLink too, whose words only a phone shows (no Mac screen uses MacLink): unchanged there.
enum ThisDevice {
    static let word = "phone"
}
#endif
