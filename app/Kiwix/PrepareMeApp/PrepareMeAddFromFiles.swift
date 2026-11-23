// This file is part of PrepareMe, a local build of Kiwix for one household's phones (concept-doc plan, phase B).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import PrepareMeShared
import SwiftUI
import UniformTypeIdentifiers

/// Add from Files (concept-doc plan, phase B; docs/plans/2026-10-18-phase-b-add-from-files.md): a phone away from the
/// Mac, or after the Mac is lost, takes library files from the PrepareMe Backup folder, in iCloud Drive or on a USB-C
/// drive. A person picks the folder; FolderOffer (PrepareMeShared) says what may be taken; each chosen file is copied
/// into the store's `incoming` (never read in place) and handed to LibraryStore, whose three checks and swap are the
/// same as a Wi-Fi download's. The phone's copy stays until the new one passes.
///
/// - On a child's device, only from its own Mac's signed list, only missing or newer files (family downloads plan,
///   phase 2, decision 6; FolderOffer.make holds the rule).
/// - A list this phone can't vouch for (not signed by its Mac's key), or an older copy, is taken only after an adult's
///   OK; a signature that doesn't hold refuses the folder.
/// - Files iCloud holds off the phone are downloaded by a coordinated read, which needs internet.
/// - The phones' inventory copy, with the rally points (beta run 2, B2-04, choice a), comes with Add all, or on its
///   own row, on a device that isn't paired (or a paired one holding none): read whole, checked three ways
///   (FolderOffer.readInventory) and handed to PhoneInventoryModel, which keeps it read only. A paired device keeps its
///   own copy.
@MainActor
final class AddFromFilesModel: ObservableObject {
    @Published var offer: FolderOffer.Offer?
    @Published var problem: String?
    @Published var adding: (name: String, done: Int, total: Int, share: Double)?
    @Published var results: [String: String] = [:]
    @Published var reading = false
    /// Phase 4: the question before an add that leaves under 10 GB
    @Published var roomAsk: RoomAsk?
    static let addedWords = "Added and checked."
    /// What the last Add did, kept when the list is read again after it
    @Published var lastAdded: String?
    private var folder: URL?
    private var listDate: String?
    private var stopped = false

    var listLine: String? {
        guard let listDate, let date = FolderOffer.date(listDate) else { return nil }
        return "The folder's list is from \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    /// The folder picked: its list read (downloaded first if iCloud holds it off the phone), off the main thread
    func open(_ url: URL) async {
        await PrepareMeSample.shared.putAway()  // a real library on its way: the sample goes first, whole
        close()
        if adding == nil { CopyControl.clearLeftovers() }
        guard url.startAccessingSecurityScopedResource() else {
            problem = FolderRead.notLetIn
            return
        }
        folder = url
        reading = true
        defer { reading = false }
        let record = PrepareMeLibrary.shared.store.record
        let child = PhoneInventoryModel.shared.isChild
        let held = FolderOffer.HeldInventory(paired: MacLink.pairing != nil,
                                             writtenAt: PhoneInventoryModel.shared.copy?.writtenAt,
                                             fromBackup: PhoneInventoryModel.shared.fromBackup)
        let found = await Task.detached(priority: .userInitiated) {
            () -> Result<(FolderOffer.Offer, String), FolderRead.Refusal> in
            FolderRead.list(in: url, named: Backup.manifestName, parse: BackupSignature.read).map { found in
                (FolderOffer.make(found.0, present: found.1, record: record, child: child, inventory: held),
                 found.0.manifest.writtenAt)
            }
        }.value
        switch found {
        case let .success((offer, writtenAt)):
            self.offer = offer
            listDate = writtenAt
        case let .failure(refusal):  // "the iPad" on an iPad (ThisDevice)
            problem = refusal.words(noList: FolderOffer.noList, damaged: FolderOffer.damagedList, unreadable:
                "This folder's list couldn't be read. If it is in iCloud Drive, the \(ThisDevice.word) needs "
                    + "internet to get it; try again with Wi-Fi or mobile data on.", device: ThisDevice.word)
        }
    }

    func close() {
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
        offer = nil
        problem = nil
        results = [:]
        lastAdded = nil
        listDate = nil
    }

    /// Stop: the copy under way stops at its next piece, and a download iCloud is still making for it is cancelled
    func stop() {
        stopped = true
        CopyControl.shared.stop()
    }

    static var damagedCopy: String {
        "The folder's copy isn't whole or isn't the listed one; this \(ThisDevice.word)'s copy stays."
    }

    /// Each file in the batch copied in and checked, one at a time, then its inventory copy when it has one; said
    /// first when there isn't room for all of them
    func add(_ batch: FolderOffer.Batch, roomAsked: Bool = false) async {
        let items = batch.items, inventory = batch.inventory
        guard let folder, adding == nil, batch.count > 0 else { return }
        let names = items.map(\.entry.name)
        // a file iCloud must first bring to the phone needs room twice while it is copied (cloud review)
        let notLocal = await Task.detached(priority: .userInitiated) {
            Set(names.filter { AddFromFilesModel.isInICloudOnly(folder.appendingPathComponent($0)) })
        }.value
        let free = PrepareMeLibrary.availableBytes()
        let need = FolderOffer.need(items, notLocal: notLocal) + (inventory?.entry.size ?? 0)
        guard free >= need else {
            let sizes = StorageWords.room(need: need, free: free)  // never the same size twice (phase L)
            problem = "These need \(sizes.need) free to copy and check; this \(ThisDevice.word) has "
                + "\(sizes.free). Add fewer, or remove something under Downloads first."
            return
        }
        // family downloads plan, phase 4: a new file that isn't the base keeps the floor and asks under 10 GB; the base
        // and newer copies of held files keep only the rule above, so an empty phone still fills from the folder
        let record = PrepareMeLibrary.shared.store.record
        if items.contains(where: { !LibraryPlan.isBase($0.entry) && record.held[$0.entry.name] == nil }) {
            let floor = LibraryPlan.floor(record.manifest?.files ?? offer?.items.map(\.entry))
            switch LibraryPlan.adding(batch.size, free: free, floor: floor) {
            case let .refused(floor):
                problem = StorageWords.floorRefusal(floor: floor)
                return
            case let .ask(left) where !roomAsked:
                let what = items.count == 1 && inventory == nil ? FileRow.title(items[0].entry) : "these \(batch.count) files"
                roomAsk = RoomAsk(title: "Add \(what)?", words: StorageWords.leaves(left, device: ThisDevice.word)) {
                    [weak self] in Task { await self?.add(batch, roomAsked: true) }
                }
                return
            default: break
            }
        }
        problem = nil
        stopped = false
        CopyControl.shared.clear()
        let store = PrepareMeLibrary.shared.store
        store.prepareFolders()
        let total = batch.count  // one count from first to last (review, minor b)
        for (done, item) in items.enumerated() {
            guard !stopped else { break }
            let entry = item.entry
            adding = (FileRow.title(entry), done, total, 0)
            let target = store.incoming(entry)
            let source = folder.appendingPathComponent(entry.name)
            let copied = await Task.detached(priority: .userInitiated) { () -> Copied in
                let progress: @Sendable (Double) -> Void = { share in
                    Task { @MainActor in AddFromFilesModel.progress(share) }
                }
                if let failed = AddFromFilesModel.coordinatedCopy(source, to: target, entry: entry,
                                                                  progress: progress) { return .failed(failed) }
                // its size and SHA-256 checked here first, so a bad copy from a drive never counts as a refusal of
                // the Mac's own copy, which would stop the Wi-Fi download of it at home (cloud review)
                guard (try? FileCheck.verify(target, size: entry.size, sha256: entry.sha256)) == .ok else {
                    try? FileManager.default.removeItem(at: target)
                    return .damaged
                }
                return .whole
            }.value
            switch copied {
            case let .failed(failure):  // which step failed, in the plan's words (phase K, finding 12)
                results[entry.name] = FileCopy.words(stopped ? .stopped : failure, device: ThisDevice.word)
                continue
            case .damaged:
                results[entry.name] = Self.damagedCopy
                continue
            case .whole:
                break
            }
            if store.record.held[entry.name] == nil { store.request(entry) }
            store.handOver(entry, from: .folder)  // a refusal is the folder's, never counted against the Mac's copy
            await store.checkWaiting()  // (Wi-Fi still fetches it at home; phase K's drills, finding 6)
            if LibraryPlan.isCurrent(entry, store.record) {
                results[entry.name] = Self.addedWords
            } else {
                results[entry.name] = store.notes[entry.name]
                    ?? "Refused by its checks; the \(ThisDevice.word)'s copy stays."
            }
        }
        if let inventory, !stopped {
            adding = (FolderOffer.inventoryTitle, items.count, total, 0)
            results[inventory.entry.name] = await takeInventory(inventory.entry, from: folder)
        }
        adding = nil
        UserDefaults.standard.set(store.lastRefusal, forKey: "lastRefusal")
        var added = items.filter { results[$0.entry.name] == Self.addedWords }.count
        var others = items.compactMap { item -> String? in
            guard let result = results[item.entry.name], result != Self.addedWords else { return nil }
            return " \(FileRow.title(item.entry)): \(result)"
        }
        if let inventory, let result = results[inventory.entry.name] {
            if result == Self.addedWords { added += 1 } else { others.append(" \(FolderOffer.inventoryTitle): \(result)") }
        }
        if let url = self.folder { await open(url) }  // the list again, now against what the phone holds
        lastAdded = "\(added) \(added == 1 ? "file" : "files") added and checked." + others.joined()
    }

    enum Copied: Sendable { case whole, damaged, failed(FileCopy.Failure) }

    /// The folder's inventory copy read whole (downloaded first if iCloud holds it off the phone), checked three ways,
    /// then handed to the inventory, which keeps a paired device's own copy; what to say under its row
    private func takeInventory(_ entry: Manifest.Inventory, from folder: URL) async -> String {
        let source = folder.appendingPathComponent(entry.name)
        let read = await Task.detached(priority: .userInitiated) { () -> (Data?, PhoneInventory?) in
            guard let data = FolderRead.coordinatedRead(source) else { return (nil, nil) }
            return (data, FolderOffer.readInventory(data, entry: entry))
        }.value
        guard read.0 != nil else { return FileCopy.words(.readFailed, device: ThisDevice.word) }
        guard let copy = read.1 else { return Self.damagedCopy }
        return PhoneInventoryModel.shared.takeFromBackup(copy) ? Self.addedWords
            : FolderOffer.inventoryHeldLine(device: ThisDevice.word, fromBackup: PhoneInventoryModel.shared.fromBackup)
    }

    // MARK: Off the main thread

    /// The one model while its screen is open, for the copy's progress and Stop
    static weak var shared: AddFromFilesModel?

    static func progress(_ share: Double) {
        guard let model = shared, let adding = model.adding else { return }
        model.adding = (adding.name, adding.done, adding.total, share)
    }

    /// Whether iCloud holds the file off the phone (or only its placeholder is in the folder)
    nonisolated static func isInICloudOnly(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) { return true }
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// `source` copied to `target` in 4 MB pieces, through a partial file in the app's temporary folder (cleared at the
    /// next Add from Files if the app was stopped mid-copy), then renamed in (FileCopy, PrepareMeShared). Nil only when
    /// every byte of the entry's size was read and written: a read that fails part-way (a drive pulled out, iCloud
    /// giving up) is never taken for the end of the file (cloud review); else which step failed (phase K, finding 12).
    /// Stop cancels the coordinator, so it works while iCloud is still downloading. Blocking: run off the main thread.
    nonisolated static func coordinatedCopy(_ source: URL, to target: URL, entry: Manifest.Entry,
                                            progress: @escaping @Sendable (Double) -> Void) -> FileCopy.Failure? {
        coordinatedCopy(source, to: target, size: entry.size, partial: CopyControl.partial(entry), progress: progress)
    }

    /// The same for any file of a known size (a travel map, combined step 9), through `partial`
    nonisolated static func coordinatedCopy(_ source: URL, to target: URL, size: Int64, partial: URL,
                                            progress: @escaping @Sendable (Double) -> Void) -> FileCopy.Failure? {
        try? FileManager.default.removeItem(at: partial)
        var failure: FileCopy.Failure? = .readFailed  // stays so when the coordinator never reaches the file
        var error: NSError?
        let coordinator = NSFileCoordinator()
        guard CopyControl.shared.begin(coordinator) else { return .stopped }
        defer { CopyControl.shared.end() }
        coordinator.coordinate(readingItemAt: source, options: [], error: &error) { url in
            failure = FileCopy.copy(url, to: target, size: size, partial: partial,
                                    isStopped: { CopyControl.shared.isStopped }, progress: progress)
        }
        if failure == .readFailed, CopyControl.shared.isStopped { return .stopped }  // Stop cancelled the coordinator
        return failure
    }
}

/// Stop, and the copy's coordinator, shared between the screen and the copy running off the main thread
final class CopyControl: @unchecked Sendable {
    static let shared = CopyControl()
    private let lock = NSLock()
    private var stopped = false
    private var coordinator: NSFileCoordinator?

    var isStopped: Bool { lock.withLock { stopped } }
    func clear() { lock.withLock { stopped = false } }

    /// The copy's coordinator kept for Stop; false when Stop came first
    func begin(_ coordinator: NSFileCoordinator) -> Bool {
        lock.withLock {
            self.coordinator = coordinator
            return !stopped
        }
    }

    func end() { lock.withLock { coordinator = nil } }

    func stop() {
        let running: NSFileCoordinator? = lock.withLock {
            stopped = true
            return coordinator
        }
        running?.cancel()  // a coordinated read still waiting for iCloud ends now, not when the download finishes
    }

    static var folder: URL { FileManager.default.temporaryDirectory }

    static func partial(_ entry: Manifest.Entry) -> URL {
        partial(sha256: entry.sha256)
    }

    static func partial(sha256: String) -> URL {
        folder.appendingPathComponent("add-from-files-\(sha256).part")
    }

    /// Partial copies a stopped app left behind
    static func clearLeftovers() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix("add-from-files-") && name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

extension PhoneInventoryModel {
    /// A child's phone: paired and not known to be an adult's. The role is the Mac's last answer, kept in the Keychain
    /// with the pairing (MacLink.canEdit, so a reinstall keeps it), else this install's own inventory answer; with
    /// neither, a paired phone is taken as a child's, so the rule fails closed (cloud review). A phone never paired (one
    /// set up after the Mac is lost) is not a child's, so it can still take its library from the backup.
    var isChild: Bool {
        guard MacLink.pairing != nil else { return false }
        if let kept = MacLink.canEdit { return !kept }
        return !(lastLook != nil && canEdit)
    }
}

/// The screen: pick the folder, then what it holds against this phone, with one Add per file and Add all at the bottom
struct AddFromFilesView: View {
    let done: () -> Void
    @StateObject private var model = AddFromFilesModel()
    @State private var picking = false
    @State private var confirming: FolderOffer.Batch?
    @State private var confirmWhy = ""

    var body: some View {
        NavigationStack {
            PMList {
                if let offer = model.offer {
                    offerSections(offer)
                } else {
                    Section {
                        Text(FolderOffer.addIntro)
                        if model.reading { Text(FolderRead.reading).foregroundStyle(PrepareMeColors.text2) }
                    }
                }
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(PrepareMeColors.red) }
                }
            }
            .navigationTitle("Add from Files")
            .navigationBarTitleDisplayMode(.inline)
            // not while the folder's list is read either: Done would end the folder's access mid-read (phase K, 13)
            .toolbar { Button("Done") { model.close(); done() }.disabled(model.adding != nil || model.reading) }
            .pmBar(.bottom) { bottomBar.padding() }
            .sheet(isPresented: $picking) {
                FolderPicker { url in
                    picking = false
                    if let url { Task { await model.open(url) } }
                }
            }
            .confirmationDialog(confirmWhy, isPresented: Binding(get: { confirming != nil },
                                                                 set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible) {
                Button("Add anyway") {
                    let batch = confirming ?? FolderOffer.Batch(items: [])
                    confirming = nil
                    Task { await model.add(batch) }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            }
        }
        .roomAsk($model.roomAsk)
        .onAppear { AddFromFilesModel.shared = model }
    }

    /// The one main button, at the bottom where a thumb reaches it: the folder to pick, all that's newer, or progress
    @ViewBuilder private var bottomBar: some View {
        if let adding = model.adding {
            VStack(alignment: .leading, spacing: 8) {
                Text(adding.share == 0
                     ? "Adding \(adding.done + 1) of \(adding.total): \(adding.name), getting it from iCloud or the drive…"
                     : "Adding \(adding.done + 1) of \(adding.total): \(adding.name), \(Int(adding.share * 100))%")
                ProgressView(value: adding.share)
                Button("Stop", role: .destructive) { model.stop() }.pmAction()
            }
        } else if let offer = model.offer, !takeAll(offer).isEmpty || offer.inventory != nil {
            let batch = FolderOffer.Batch(items: takeAll(offer), inventory: offer.inventory)  // its copy, when offered
            Button("Add all newer and missing (\(batch.count), \(StorageWords.size(batch.size)))") {
                add(batch.items, offer, inventory: batch.inventory)
            }
                .pmAction()
                .frame(maxWidth: .infinity)
        } else {
            Button(model.offer == nil ? "Choose the PrepareMe Backup folder" : "Choose another folder") {
                picking = true
            }
            .pmAction()
            .frame(maxWidth: .infinity)
            .disabled(model.reading)
        }
    }

    private func takeAll(_ offer: FolderOffer.Offer) -> [FolderOffer.Item] {
        FolderOffer.takeAll(offer)
    }

    /// Adding, after an adult's OK where one is needed
    private func add(_ items: [FolderOffer.Item], _ offer: FolderOffer.Offer,
                     inventory: FolderOffer.InventoryItem? = nil) {
        let first = items.first(where: \.needsAdult)
        let batch = FolderOffer.Batch(items: items, inventory: inventory)
        guard first != nil || inventory?.needsAdult == true else {
            Task { await model.add(batch) }
            return
        }
        if let line = FolderOffer.trustLine(offer.trust, device: ThisDevice.word), offer.needsAdult {
            confirmWhy = line
        } else if let first, first.state == .older {
            confirmWhy = olderLine(first)
        } else if let first, first.state == .different {
            confirmWhy = "This copy of \(FileRow.title(first.entry)) differs from the one on this \(ThisDevice.word), "
                + "with the same date. Add it only if the \(ThisDevice.word)'s copy is wrong."
        } else if let first {
            confirmWhy = "Your Mac no longer sends \(FileRow.title(first.entry)) to this \(ThisDevice.word). "
                + "Add it only if you know you want it."
        }
        confirming = batch
    }

    private func olderLine(_ item: FolderOffer.Item) -> String {
        FolderOffer.olderLine(item, title: FileRow.title(item.entry), device: ThisDevice.word)
    }

    private func day(_ text: String?) -> String {
        text.flatMap(FolderOffer.date).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "an unknown date"
    }

    @ViewBuilder private func offerSections(_ offer: FolderOffer.Offer) -> some View {
        Section {
            if let added = model.lastAdded { Text(added) }
            if let line = model.listLine { Text(line) }
            if let refusal = offer.childRefusal {  // a child's device: one plain line, no button (decision 6)
                Text(FolderOffer.childLine(refusal, device: ThisDevice.word))
            } else if let trust = FolderOffer.trustLine(offer.trust, device: ThisDevice.word) {
                Label(trust, systemImage: offer.trust == .badSignature ? "xmark.octagon" : "exclamationmark.triangle")
                    .foregroundStyle(offer.trust == .badSignature ? PrepareMeColors.red : PrepareMeColors.caution)
            }
            if !offer.absent.isEmpty {
                Text("Listed but missing or not whole in this folder: \(offer.absent.count) "
                     + "\(offer.absent.count == 1 ? "file" : "files"). A drive may have been copied part-way.")
                    .foregroundStyle(PrepareMeColors.caution)
            }
        }
        group("Newer than this \(ThisDevice.word)'s", offer.items.filter { $0.state == .newer }, offer)
        group("Not on this \(ThisDevice.word)", offer.items.filter { $0.state == .missing }, offer)
        group("Older than this \(ThisDevice.word)'s", offer.items.filter { $0.state == .older }, offer)
        group("Another copy, same date", offer.items.filter { $0.state == .different }, offer)
        if let inventory = offer.inventory { inventoryRow(inventory, offer) }  // B2-04
        let same = offer.items.filter { $0.state == .same }.count
        if same > 0 {
            Section {
                Label {
                    Text("\(same) \(same == 1 ? "file is" : "files are") the same as this \(ThisDevice.word)'s.")
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(PrepareMeColors.okMark)
                }
            }
        }
        if offer.inventoryKept {  // a paired device keeps its own copy (B2-04)
            Section { Text(FolderOffer.inventoryKeptLine(device: ThisDevice.word)).foregroundStyle(PrepareMeColors.text2) }
        }
    }

    /// The phones' inventory copy and its rally points (B2-04): its own row, read only once taken
    @ViewBuilder private func inventoryRow(_ inventory: FolderOffer.InventoryItem, _ offer: FolderOffer.Offer) -> some View {
        Section(pmTitle: FolderOffer.inventoryTitle) {
            VStack(alignment: .leading, spacing: 6) {  // the section's title names it
                let note = FolderOffer.inventoryNote(device: ThisDevice.word, paired: MacLink.pairing != nil)
                Text("From \(day(inventory.entry.writtenAt)). \(note)")
                if let result = model.results[inventory.entry.name] {
                    Text(result).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
                Button("Add (\(StorageWords.size(inventory.entry.size)))\(inventory.needsAdult ? "…" : "")") {
                    add([], offer, inventory: inventory)
                }
                    .pmAction()
                    .disabled(model.adding != nil)
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ items: [FolderOffer.Item], _ offer: FolderOffer.Offer) -> some View {
        if !items.isEmpty {
            Section(pmTitle: title) {
                ForEach(items, id: \.entry.name) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(FileRow.title(item.entry))
                        Text(note(item)).font(.pmNote)
                            .foregroundStyle(item.state == .older || item.state == .different ? PrepareMeColors.caution
                                             : PrepareMeColors.text2)
                        if let result = model.results[item.entry.name] {
                            Text(result).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                        }
                        if item.addable {
                            Button("Add (\(StorageWords.size(item.entry.size)))\(item.needsAdult ? "…" : "")") {
                                add([item], offer)
                            }
                                .pmAction()
                                .disabled(model.adding != nil)
                        } else {  // an older copy on a child's device (decision 6)
                            Text(FolderOffer.childNewerHere(device: ThisDevice.word)).font(.pmNote)
                                .foregroundStyle(PrepareMeColors.text2)
                        }
                    }
                }
            }
        }
    }

    private func note(_ item: FolderOffer.Item) -> String {
        FolderOffer.fromLine(item, device: ThisDevice.word)
            + (item.state == .missing && item.declined ? " You removed it from this \(ThisDevice.word); Add brings it back." : "")
    }
}

/// The system's folder picker
struct FolderPicker: UIViewControllerRepresentable {
    let picked: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picked: (URL?) -> Void
        init(picked: @escaping (URL?) -> Void) { self.picked = picked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            picked(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picked(nil) }
    }
}
#endif
