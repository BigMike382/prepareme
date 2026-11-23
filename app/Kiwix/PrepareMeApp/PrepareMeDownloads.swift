// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 8).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import Foundation
import PrepareMeShared
import SwiftUI

/// Downloads from Kiwix's online library, on the Mac only (build plan phase 8; owner, 2026-10-14). Kiwix's catalog
/// shows in the sidebar again, but its Download button comes here instead of Kiwix's own downloader: each file goes to
/// Application Support › PrepareMe › downloads, is kept only when its size and SHA-256 are what Kiwix publishes
/// (`CatalogDownload`), over Wi-Fi or a wired network only, and reaches the reader the way every file does (the
/// packer's folder, `FolderSync`, `LibraryStore`), so Kiwix never opens a file this code is still writing (F-064).
/// "For the family" offers a kept file to the phones; each phone then picks it like an optional map.
@MainActor
final class MacDownloads: ObservableObject {
    static let shared = MacDownloads()

    struct Running: Identifiable {
        let id: String  // the Metalink's address
        let title: String
        var done: Int64 = 0
        var total: Int64 = 0
        var started = Date()  // for the row's minutes left (library redesign plan 1.2): set at the first report,
        var from: Int64?  // with what was already on disk then, so a resumed file's rate counts only new bytes
        var task: Task<Void, Never>?
    }

    struct Waiting: Codable, Equatable, Identifiable {
        let source: String
        let title: String
        var outside: OutsideList.Entry?  // an Other Sites item (library redesign 5.2); its source is outside:<key>
        var id: String { source }
    }

    /// An Other Sites entry's key in running, queued and the rows: outside:<key>#<sha256>, so a file kept before the
    /// list re-checked it under the same key isn't taken for the current one and its card offers Download (phase 5
    /// review).
    static func source(of entry: OutsideList.Entry) -> URL { source(key: entry.key, sha256: entry.sha256) }
    static func source(key: String, sha256: String) -> URL { URL(string: "outside:\(key)#\(sha256)")! }

    @Published private(set) var running: [String: Running] = [:]
    @Published private(set) var kept: [DownloadsRecord.File] = []
    @Published private(set) var waiting: [Waiting] = []  // started, not finished: they resume from where they stopped
    @Published var message: String?
    @Published private(set) var queued: [Waiting] = []  // one download at a time (review 8): the next starts when one finishes
    /// The last refusal by source, for the row that started it (an Other Sites card shows its own; plan 5.4).
    @Published private(set) var failed: [String: String] = [:]

    nonisolated static var folder: URL? {
        PrepareMeMac.folders?.appendingPathComponent("downloads")
    }

    static let waitingName = ".waiting.json"

    private init() {
        refresh()
    }

    func refresh() {
        guard let folder = Self.folder else { return }
        // the Other Sites files show as kept downloads under their packed name, so the rows, Kept on this Mac, For the
        // family and Remove need nothing of their own (library redesign 5.2)
        let outside = OutsideRecord.read(folder).files.map { file in
            DownloadsRecord.File(name: OutsideRecord.packedName(file.key), title: file.title, size: file.size,
                                 sha256: file.sha256,
                                 source: Self.source(key: file.key, sha256: file.sha256).absoluteString,
                                 family: file.family, keptAt: file.keptAt)
        }
        kept = (DownloadsRecord.read(folder).files + outside)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        waiting = (try? Data(contentsOf: folder.appendingPathComponent(Self.waitingName)))
            .flatMap { try? JSONDecoder().decode([Waiting].self, from: $0) } ?? []
    }

    /// Start (or resume) the download of an Other Sites entry (library redesign 5.2), queued with the others.
    func startOutside(_ entry: OutsideList.Entry) {
        start(source: Self.source(of: entry), title: entry.title, outside: entry)
    }

    /// Start (or resume) the download of a catalog entry's file: its Metalink's address and title.
    func start(source: URL, title: String, outside: OutsideList.Entry? = nil) {
        guard let folder = Self.folder else {
            message = "PrepareMe couldn't find this Mac's home folder."
            return
        }
        let key = source.absoluteString
        guard running[key] == nil, !queued.contains(where: { $0.source == key }) else { return }
        failed[key] = nil
        remember(Waiting(source: key, title: title, outside: outside), in: folder)
        guard running.isEmpty else {  // one at a time, so two never pass the room check each alone
            queued.append(Waiting(source: key, title: title, outside: outside))
            message = "\(title) waits for the download in progress to finish."
            return
        }
        var entry = Running(id: key, title: title)
        entry.task = Task { [weak self] in
            do {
                let gate = ProgressThrottle()
                let report: @Sendable (Int64, Int64) -> Void = { done, total in
                    guard gate.pass(done: done, total: total) else { return }
                    Task { @MainActor in
                        guard var entry = self?.running[key] else { return }
                        if entry.from == nil { entry.from = done; entry.started = Date() }
                        entry.done = done
                        entry.total = total
                        self?.running[key] = entry
                    }
                }
                let name: String
                if let outside {
                    let kept = try await CatalogDownload.runOutside(outside, family: false, folder: folder,
                                                                    progress: report, loopback: PrepareMeHome.isCheck)
                    name = OutsideRecord.packedName(kept.key)
                } else {
                    name = try await CatalogDownload.run(metalink: source, title: title, family: false, folder: folder,
                                                         progress: report).name
                }
                self?.forget(key, in: folder)
                PrepareMeMac.shared.store.undecline(name)  // kept again after a Remove: it opens again
                PrepareMeLibraryShelf.shared.ask(name: name, title: title,  // Which category? (Library plan 3.1)
                                                 suggest: outside.map(\.category))
                self?.message = "\(title) is downloaded and checked. It opens here, and can be offered to the phones, "
                    + "after the Mac's next quarter-hour check."
            } catch let failure as CatalogDownload.Failure {
                if failure == .damaged || failure == .alreadyKept { self?.forget(key, in: folder) }
                if case .changedAtSource = failure { self?.forget(key, in: folder) }
                self?.message = "\(title): \(failure.description)"
                if failure != .cancelled { self?.failed[key] = failure.description }
            } catch {
                self?.message = "\(title): the download stopped (\(type(of: error))). It picks up where it left off."
            }
            self?.running[key] = nil
            self?.refresh()
            if let next = self?.queued.first, let url = URL(string: next.source) {
                self?.queued.removeFirst()
                self?.start(source: url, title: next.title, outside: next.outside)
            }
        }
        running[key] = entry
    }

    /// Stopped part-way › Resume. An Other Sites item resumes only as the list vets it now (phase 5 review): the
    /// list is read again, and one dropped or re-checked since says so and waits to be discarded.
    func resume(_ waiting: Waiting) {
        guard let saved = waiting.outside else {
            if let url = URL(string: waiting.source) { start(source: url, title: waiting.title) }
            return
        }
        Task {
            await OtherSitesList.shared.refresh()
            // Discard pressed while the list was read: it stays discarded (phase 6 review)
            guard self.waiting.contains(where: { $0.source == waiting.source }) else { return }
            let why: String
            switch OutsideList.resume(key: saved.key, sha256: saved.sha256, list: OtherSitesList.shared.list) {
            case .entry(let current): return startOutside(current)
            case .notListed: why = Self.notListed
            case .listUnread: why = Self.listUnread
            }
            message = "\(waiting.title): \(why)"
            failed[waiting.source] = why  // shown under its Stopped part-way row
        }
    }

    static let notListed = "It's no longer on the Other Sites list as it was checked, so it can't resume. Discard it; "
        + "if it's listed again, download it from Other Sites."
    static let listUnread = "The Other Sites list couldn't be read just now, so it waits. Try Resume again later."
    static let droppedNote = "No longer on the Other Sites list, so the phones don't get it."

    /// A kept Other Sites file the list no longer vets (phase 5 review): its row says so and offers no For the family.
    static func dropped(_ file: DownloadsRecord.File, list: OutsideList?) -> Bool {
        guard let key = OutsideRecord.key(packedName: file.name) else { return false }
        return OutsideList.dropped(key: key, sha256: file.sha256, from: list)
    }

    func stop(_ key: String) {
        queued.removeAll { $0.source == key }
        running[key]?.task?.cancel()
    }

    /// Give up a waiting download: its part-file and its line go.
    func discard(_ waiting: Waiting) {
        guard let folder = Self.folder else { return }
        stop(waiting.source)
        forget(waiting.source, in: folder)
        if let outside = waiting.outside {
            try? FileManager.default.removeItem(at: CatalogDownload.partURL(
                "\(outside.key).pdf", in: folder.appendingPathComponent(OutsideRecord.folderName)))
        }
        // Kiwix names a Metalink for its file (<file>.zim.meta4), and the part-file is named for the file
        else if let name = URL(string: waiting.source)?.deletingPathExtension().lastPathComponent, FileName.isPlain(name) {
            try? FileManager.default.removeItem(at: CatalogDownload.partURL(name, in: folder))
        }
        refresh()
    }

    func setFamily(_ name: String, _ family: Bool) {
        guard let folder = Self.folder else { return }
        withdraw(name, !family)
        if let key = OutsideRecord.key(packedName: name), var outside = try? OutsideRecord.load(folder),
           let index = outside.files.firstIndex(where: { $0.key == key }) {  // an Other Sites item (5.2)
            outside.files[index].family = family
            do {
                try outside.write(folder)
            } catch {
                message = "That wasn't saved (\(type(of: error)))."
            }
            return refresh()
        }
        guard var record = try? DownloadsRecord.load(folder) else {
            message = CatalogDownload.Failure.recordUnreadable.description
            return
        }
        guard let index = record.files.firstIndex(where: { $0.name == name }) else { return }
        record.files[index].family = family
        do {
            try record.write(folder)
        } catch {
            message = "That wasn't saved (\(type(of: error)))."
        }
        refresh()
    }

    /// Remove…'s confirm, here and on the Library page (owner, 2026-11-13, by click).
    static func removeAsk(_ title: String) -> String { "Remove \(title)?" }
    static func removeNote(size: Int64) -> String {
        "It comes off this Mac and out of the phones' list; a phone that has it keeps its copy. Getting it back means "
            + "downloading \(StorageWords.size(size)) again."
    }

    func remove(_ name: String) {
        guard let folder = Self.folder else { return }
        do {
            try CatalogDownload.removeKept(name, from: folder)  // an Other Sites item's record, or Kiwix's
        } catch {
            message = (error as? CatalogDownload.Failure)?.description ?? "That wasn't removed (\(type(of: error)))."
            return
        }
        withdraw(name, false)  // gone from the Mac: the phones keep their copies (removeNote)
        refresh()
        Task { await PrepareMeMac.shared.store.remove(name) }  // the Mac's own reading copy goes too
    }

    /// Un-ticking For the family keeps the name for the service, which tells every device to let go of its copy until
    /// it is ticked again or removed (family downloads plan, phase 3, decision 3; the Downloads view asks first when
    /// devices hold it, phase 6).
    private func withdraw(_ name: String, _ withdrawn: Bool) {
        guard let pairing = PrepareMeMac.folders?.appendingPathComponent(PairingDesk.folderName) else { return }
        do {
            try PhoneChoices.withdraw(name, withdrawn, in: pairing)
        } catch {
            message = "The devices' list wasn't saved (\(type(of: error)))."
        }
    }

    private func remember(_ entry: Waiting, in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var list = waiting.filter { $0.source != entry.source }
        list.append(entry)
        save(list, in: folder)
    }

    private func forget(_ key: String, in folder: URL) {
        save(waiting.filter { $0.source != key }, in: folder)
    }

    private func save(_ list: [Waiting], in folder: URL) {
        if let data = try? JSONEncoder().encode(list) {
            try? DurableFile.write(data, to: folder.appendingPathComponent(Self.waitingName))
        }
        waiting = list
    }
}

/// What a catalog row shows where its Download button was (library redesign plan 1.2; owner, 2026-11-13): the button
/// while nothing is under way, then the download's progress, its place in line, or where the kept file sits.
struct PrepareMeDownloadButton: View {
    let source: URL
    let title: String
    var start: () -> Void
    @ObservedObject private var downloads = MacDownloads.shared
    @ObservedObject private var shelf = PrepareMeLibraryShelf.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { time in  // the minutes left move even between progress calls
            PrepareMeDownloadRowView(row: state(now: time.date), start: start,
                                     pause: { downloads.stop(source.absoluteString) },
                                     cancel: { downloads.stop(source.absoluteString) })  // as Downloads' Cancel: a part-file stays
        }
    }

    private func state(now: Date) -> DownloadRow {
        let key = source.absoluteString
        let kept = downloads.kept.first { $0.source == key }
        let place = kept.flatMap { file -> String? in
            let current = shelf.current
            guard let id = current.category(for: LibraryShelf.key(fileName: file.name)) else { return nil }
            return current.path(of: id)  // "📖 Books › Homesteading" for a subcategory (phase 4 review)
        }
        return DownloadRow.state(source: key,
                                 running: downloads.running.mapValues { ($0.done, $0.total, $0.started, $0.from ?? $0.done) },
                                 queued: downloads.queued.map(\.source),
                                 runningTitle: downloads.running.values.first?.title,
                                 keptSources: Set(downloads.kept.map(\.source)), place: place, now: now,
                                 pausedSources: Set(downloads.waiting.map(\.source)))
    }
}

/// One row state drawn: the Download button, a teal bar with its words and Pause, the line's words and Cancel, or
/// where the kept file sits.
struct PrepareMeDownloadRowView: View {
    let row: DownloadRow
    var start: () -> Void
    var pause: () -> Void
    var cancel: () -> Void

    var body: some View {
        switch row {
        case .ready:
            Button("Download", action: start).pmAction(fullWidth: false)
        case .paused:  // a part is kept: the same start picks up where it stopped
            Button(row.words, action: start).pmAction(fullWidth: false)
        case let .running(done, total, _):
            VStack(alignment: .leading, spacing: 4) {
                bar(total > 0 ? Double(done) / Double(total) : 0)
                HStack {
                    words
                    Spacer()
                    Button("Pause", action: pause)
                }
            }
        case .waiting:
            HStack {
                words
                Spacer()
                Button("Cancel", action: cancel)
            }
        case .kept:
            words
        }
    }

    private var words: some View { Text(row.words).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }

    /// The Mac's own bar ignores the tint, so it drew the system blue: this one fills with the house tint (`pmTint`,
    /// teal, or ink under red night) on a track that shows in light mode too.
    private func bar(_ share: Double) -> some View {
        GeometryReader { space in
            ZStack(alignment: .leading) {
                Capsule().fill(PrepareMeColors.line)
                Capsule().fill(.tint).frame(width: space.size.width * min(max(share, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue(row.words)
    }

    /// PREPAREME_CHECK_DOWNLOAD_ROWS=1 (library redesign plan 1.2): the four states with made-up figures, in a window
    /// of their own, since the check build can't reach Kiwix's catalog.
    static var sampleWindow: NSWindow?
    static func showSamples() {
        let rows: [DownloadRow] = [.ready, .running(done: 18_000_000, total: 43_000_000, secondsLeft: 84),
                                   .waiting(behind: "FEMA handbook"), .kept(place: "🥫 Food and Garden")]
        let list = VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                PrepareMeDownloadRowView(row: row, start: {}, pause: {}, cancel: {})
            }
        }
        .padding(20).frame(width: 420).background(PrepareMeColors.panel).pmTint()
        let window = NSWindow(contentViewController: NSHostingController(rootView: list))
        window.title = "Download rows"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        sampleWindow = window
    }
}

/// Downloads, in File › Get More Libraries…'s window (PrepareMeCatalogWindow): what's downloading, what's waiting to
/// resume, and what's kept, with For the family and Remove for each.
struct PrepareMeDownloadsView: View {
    @ObservedObject private var downloads = MacDownloads.shared
    @ObservedObject private var sites = OtherSitesList.shared
    @EnvironmentObject private var library: LibraryViewModel
    @State private var removing: DownloadsRecord.File?
    @ObservedObject private var pairing = PhonePairing.shared
    @State private var unticking: DownloadsRecord.File?  // For the family off on a file devices hold: asked first
    @State private var filesFor: PairingDesk.Phone?  // a child's device's Files…, from beside the tick

    var body: some View {
        PMList {
            Section {
                Text("Find files under Categories, New or Other Sites, then Download. Each is checked against what "
                     + "its source publishes, or what was vetted, before it's kept, and downloads only over Wi-Fi or "
                     + "a wired network.")
                    .foregroundStyle(PrepareMeColors.text2)
                Button("Refresh Kiwix's catalog") { Task { await library.start(isUserInitiated: true) } }
                if let message = downloads.message {
                    Text(message).foregroundStyle(PrepareMeColors.text2)
                }
            }
            if !downloads.running.isEmpty {
                Section(pmTitle: "Downloading") {
                    ForEach(Array(downloads.running.values).sorted { $0.title < $1.title }) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.title)
                                if entry.total > 0 {
                                    ProgressView(value: Double(entry.done), total: Double(entry.total))
                                    Text("\(StorageWords.size(entry.done)) of \(StorageWords.size(entry.total))").font(.pmNote)
                                        .foregroundStyle(PrepareMeColors.text2)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            Spacer()
                            Button("Stop") { downloads.stop(entry.id) }
                        }
                        .contextMenu { Button("Stop") { downloads.stop(entry.id) } }  // the row's buttons (docs/design/menus.md)
                    }
                }
            }
            if !downloads.queued.isEmpty {
                Section(pmTitle: "Next, one at a time") {
                    ForEach(downloads.queued) { entry in
                        HStack {
                            Text(entry.title)
                            Spacer()
                            Button("Cancel") { downloads.stop(entry.source) }
                        }
                        .contextMenu { Button("Cancel") { downloads.stop(entry.source) } }
                    }
                }
            }
            let paused = downloads.waiting.filter { entry in
                downloads.running[entry.source] == nil && !downloads.queued.contains { $0.source == entry.source }
            }
            if !paused.isEmpty {
                Section(pmTitle: "Stopped part-way") {
                    ForEach(paused) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.title)
                                if let why = downloads.failed[entry.source] {  // why Resume didn't (phase 6 review)
                                    Text(why).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                                }
                            }
                            Spacer()
                            Button("Resume") { downloads.resume(entry) }
                            Button("Discard") { downloads.discard(entry) }
                        }
                        .contextMenu {
                            Button("Resume") { downloads.resume(entry) }
                            Divider()
                            PMMenuDelete("Discard") { downloads.discard(entry) }
                        }
                    }
                }
            }
            Section(pmTitle: "Kept on this Mac") {
                if downloads.kept.isEmpty {
                    Text("Nothing yet.").foregroundStyle(PrepareMeColors.text2)
                }
                ForEach(downloads.kept, id: \.name) { file in
                    let dropped = MacDownloads.dropped(file, list: sites.list)
                    HStack {
                        VStack(alignment: .leading) {
                            Text(file.title)
                            Text("\(file.name), \(StorageWords.size(file.size))").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                            if dropped {
                                Text(MacDownloads.droppedNote).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                            } else if file.family {
                                children(file)
                            }
                        }
                        Spacer()
                        if !dropped {
                            Toggle("For the family", isOn: Binding(get: { file.family },
                                                                   set: { setFamily(file, $0) }))
                                .pmSwitch()
                                .help("Offer it to the phones: it shows under Downloads on each phone")
                        }
                        Button("Remove…") { removing = file }
                    }
                    .contextMenu {
                        if !dropped {
                            Toggle("For the Family", isOn: Binding(get: { file.family },
                                                                   set: { setFamily(file, $0) }))
                                .pmSwitch()
                            Divider()
                        }
                        PMMenuDelete("Remove…") { removing = file }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .onAppear {
            downloads.refresh()
            pairing.refresh()  // the devices beside each tick, and what each holds
            #if PREPAREME_CHECK
            // the check build only: PREPAREME_CHECK_UNTICK=<file name> un-ticks that kept file as a click would
            if let name = ProcessInfo.processInfo.environment["PREPAREME_CHECK_UNTICK"],
               let file = downloads.kept.first(where: { $0.name == name }) { setFamily(file, false) }
            #endif
        }
        .confirmationDialog(unticking.map { PhoneCuration.untickAsk(devices: holders($0), size: $0.size) } ?? "",
                            isPresented: Binding(get: { unticking != nil }, set: { if !$0 { unticking = nil } }),
                            presenting: unticking) { file in
            Button("Remove", role: .destructive) { downloads.setFamily(file.name, false) }
        } message: { _ in
            Text("Each device lets go of its copy at its next check at home. Tick For the family again to offer it again.")
        }
        .sheet(item: $filesFor) { phone in
            PhoneFilesSheet(phone: phone, title: pairing.title(for: phone)) { filesFor = nil }
        }
        .task { await sites.refresh() }  // so a kept item the list dropped says so
        .confirmationDialog(MacDownloads.removeAsk(removing?.title ?? ""),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { file in
            Button("Remove", role: .destructive) { downloads.remove(file.name) }
        } message: { file in
            Text(MacDownloads.removeNote(size: file.size))
        }
    }


    /// Ticking offers the file at once; un-ticking a file devices hold asks first (family downloads plan, decision 3)
    private func setFamily(_ file: DownloadsRecord.File, _ family: Bool) {
        if !family && holders(file) > 0 { unticking = file } else { downloads.setFamily(file.name, family) }
    }

    /// The paired devices whose last report says they hold the file
    private func holders(_ file: DownloadsRecord.File) -> Int {
        (pairing.phones ?? []).filter { pairing.rooms[$0.label]?.held.contains(file.name) == true }.count
    }

    /// Beside the tick: which children's devices will see the file (all but those set to Never), and Files… for each
    @ViewBuilder private func children(_ file: DownloadsRecord.File) -> some View {
        let kids = (pairing.phones ?? []).filter(\.readOnly)
        let seeing = kids.filter { pairing.files(for: $0)[file.name] != PhoneChoices.hide }
        if let line = PhoneCuration.childrenLine(seeing: seeing.map(pairing.title(for:)),
                                                 neverOn: kids.count - seeing.count) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Menu("Files…") {
                    ForEach(kids) { phone in Button(pairing.title(for: phone)) { filesFor = phone } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.pmNote)
                .help("Set what each child's device gets, file by file")
            }
        }
    }
}
#endif
