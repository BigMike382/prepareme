// This file is part of PrepareMe, a local build of Kiwix for one household's phones (combined step 9).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import PrepareMeShared
import SwiftUI

/// The travel street maps on this phone (combined step 9; docs/plans/2026-10-20-step-9-travel-maps.md): one state's
/// map at a time, taken from iCloud Drive › PrepareMe Travel Maps (Home Mac › Add a travel map), checked three ways
/// against that folder's list and as a whole map file (TravelMaps, PrepareMeShared), kept in the app's own storage
/// (TravelStore: Application Support › PrepareMe › travel, out of the phone's backups, never synced again) and drawn
/// on the street map with the home file. An adult adds and removes them, as with Add from Files (owner, 2026-10-18).
@MainActor
enum PrepareMeTravel {
    static let store: TravelStore = {
        let made = TravelStore(root: PrepareMeLibrary.root.appendingPathComponent("travel", isDirectory: true))
        made.prepareFolders()
        return made
    }()
}

/// The picked folder, what it offers, and each Add: copied into the store's `incoming` (never read in place), checked
/// off the main thread, then kept. Phase M's room rule first: the state's size and 1 GB, twice its size while iCloud
/// still holds it off the phone.
@MainActor
final class TravelMapsModel: ObservableObject {
    @Published var items: [TravelMaps.Item]?
    @Published var problem: String?
    @Published var reading = false
    @Published var adding: (name: String, share: Double)?
    @Published var results: [String: String] = [:]
    /// Phase 4: the question before a map that leaves under 10 GB
    @Published var roomAsk: RoomAsk?
    private var folder: URL?
    private var list: TravelMaps.List?
    private var stopped = false

    /// The one model while its screen is open, for the copy's progress
    static weak var shared: TravelMapsModel?

    /// The folder picked: its list read (downloaded first if iCloud holds it off the phone), off the main thread
    func open(_ url: URL) async {
        close()
        if adding == nil { CopyControl.clearLeftovers() }
        guard url.startAccessingSecurityScopedResource() else {
            problem = FolderRead.notLetIn
            return
        }
        folder = url
        reading = true
        defer { reading = false }
        let found = await Task.detached(priority: .userInitiated) {
            FolderRead.list(in: url, named: TravelMaps.manifestName, parse: TravelMaps.read)
        }.value
        switch found {
        case let .success((list, present)):
            self.list = list
            items = TravelMaps.offer(list, present: present, held: PrepareMeTravel.store.held)
        case let .failure(refusal):
            problem = refusal.words(noList: TravelMaps.noList, damaged: TravelMaps.damagedList, unreadable:
                "This folder's list couldn't be read. The \(ThisDevice.word) needs internet to get it from "
                    + "iCloud Drive; try again with Wi-Fi or mobile data on.", device: ThisDevice.word)
        }
    }

    func close() {
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
        list = nil
        items = nil
        problem = nil
        results = [:]
    }

    /// Stop: the copy under way stops at its next piece, and a download iCloud is still making for it is cancelled
    func stop() {
        stopped = true
        CopyControl.shared.stop()
    }

    static func progress(_ share: Double) {
        guard let model = shared, let adding = model.adding else { return }
        model.adding = (adding.name, share)
    }

    /// One state copied in, checked and kept; said first when there isn't room for it, or when this phone's record
    /// can't be read (phase K, finding 10: before, the whole file was copied and then refused)
    func add(_ item: TravelMaps.Item, roomAsked: Bool = false) async {
        guard let folder, let list, adding == nil, item.canAdd else { return }
        let store = PrepareMeTravel.store
        guard !store.locked else {
            problem = TravelMaps.damagedRecord(device: ThisDevice.word)
            return
        }
        let entry = item.entry
        let source = folder.appendingPathComponent(entry.name)
        let notLocal = await Task.detached(priority: .userInitiated) { AddFromFilesModel.isInICloudOnly(source) }.value
        if let noRoom = TravelMaps.noRoom(entry, inICloudOnly: notLocal, free: PrepareMeLibrary.availableBytes(),
                                          device: ThisDevice.word) {
            problem = noRoom
            return
        }
        // family downloads plan, phase 4: the floor the library needs to update, and the question under 10 GB
        let floor = LibraryPlan.floor(PrepareMeLibrary.shared.store.record.manifest?.files)
        switch LibraryPlan.adding(entry.size, free: PrepareMeLibrary.availableBytes(), floor: floor) {
        case let .refused(floor):
            problem = StorageWords.floorRefusal(floor: floor)
            return
        case let .ask(left) where !roomAsked:
            roomAsk = RoomAsk(title: "Add \(TravelMaps.title(entry))'s map?",
                              words: StorageWords.leaves(left, device: ThisDevice.word)) {
                [weak self] in Task { await self?.add(item, roomAsked: true) }
            }
            return
        default: break
        }
        problem = nil
        stopped = false
        CopyControl.shared.clear()
        store.prepareFolders()
        let target = store.incoming(entry)
        adding = (TravelMaps.title(entry), 0)
        let verdict = await Task.detached(priority: .userInitiated) { () -> TravelMaps.Verdict? in
            guard AddFromFilesModel.coordinatedCopy(source, to: target, size: entry.size,
                                                    partial: CopyControl.partial(sha256: entry.sha256),
                                                    progress: { share in
                                                        Task { @MainActor in TravelMapsModel.progress(share) }
                                                    }) == nil else { return nil }
            let verdict = (try? TravelMaps.check(target, as: entry.name, against: list)) ?? .wrongSize(-1)
            if verdict != .ok { try? FileManager.default.removeItem(at: target) }
            return verdict
        }.value
        adding = nil
        switch verdict {
        case nil:
            results[entry.state] = stopped ? FolderRead.stopped
                : "Couldn't be copied from the folder. " + TravelMaps.waitForICloud
        case .ok?:
            do {
                try store.keep(target, entry: entry)
                results[entry.state] = TravelMaps.added
            } catch {
                results[entry.state] = "It passed its checks, but this \(ThisDevice.word) couldn't keep it; nothing "
                    + "changed."
            }
        case let refused?:
            results[entry.state] = TravelMaps.refusal(refused)
        }
        if let url = self.folder {  // the list again, now against what the phone holds; the results stay
            let kept = results
            await open(url)
            results = kept
        }
    }
}

/// Add a travel map: what it is and its three limits, then the folder to pick, then each state it holds with its
/// size and Add
struct TravelMapsView: View {
    let done: () -> Void
    @StateObject private var model = TravelMapsModel()
    @ObservedObject private var travel = PrepareMeTravel.store
    @State private var picking = false

    var body: some View {
        NavigationStack {
            PMList {
                Section {
                    Text(TravelMaps.intro(device: ThisDevice.word))
                }
                if travel.locked {
                    Section { TravelDamagedRows() }
                }
                Section(pmTitle: "Before you travel") {
                    ForEach(TravelMaps.limits, id: \.self) { limit in Text(limit) }
                }
                if let items = model.items {
                    Section(pmTitle: "In the folder") {
                        if items.isEmpty { Text("The folder's list names no state yet.") }
                        ForEach(items, id: \.entry.state) { item in row(item) }
                    }
                } else if model.reading {
                    Section { Text(FolderRead.reading).foregroundStyle(PrepareMeColors.text2) }
                }
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(PrepareMeColors.red) }
                }
            }
            .navigationTitle("Add a travel map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { model.close(); done() }.disabled(model.adding != nil || model.reading) }
            .pmBar(.bottom) { bottomBar.padding() }
            .sheet(isPresented: $picking) {
                FolderPicker { url in
                    picking = false
                    if let url { Task { await model.open(url) } }
                }
            }
        }
        .roomAsk($model.roomAsk)
        .onAppear {
            TravelMapsModel.shared = model
            // a stopped add's copy and unlisted map files go when it opens with nothing being added (phase K, 11)
            if model.adding == nil { PrepareMeTravel.store.clearLeftovers() }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if let adding = model.adding {
            VStack(alignment: .leading, spacing: 8) {
                Text(adding.share == 0 ? "Adding \(adding.name), getting it from iCloud…"
                     : "Adding \(adding.name), \(Int(adding.share * 100))%")
                ProgressView(value: adding.share)
                Button("Stop", role: .destructive) { model.stop() }.pmAction()
            }
        } else {
            Button(model.items == nil ? "Choose the \(TravelMaps.folderName) folder" : "Choose another folder") {
                picking = true
            }
            .pmAction()
            .frame(maxWidth: .infinity)
            .disabled(model.reading)
        }
    }

    private func row(_ item: TravelMaps.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TravelMaps.title(item.entry))
            Text(TravelMaps.standingLine(item, device: ThisDevice.word)).font(.pmNote)
                .foregroundStyle(item.standing == .notWhole ? PrepareMeColors.caution : PrepareMeColors.text2)
            if let result = model.results[item.entry.state] {
                Text(result).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            if item.canAdd {
                Text(TravelMaps.takes(item.entry, device: ThisDevice.word)).font(.pmNote)
                    .foregroundStyle(PrepareMeColors.text2)
                Button("Add (\(StorageWords.size(item.entry.size)))") { Task { await model.add(item) } }
                    .pmAction()
                    .disabled(model.adding != nil || travel.locked)  // the damaged list's line says why
            }
        }
    }
}

/// A travel map this phone holds, under Downloads: its state, its map age line and size, and Remove (a child's phone
/// too since the family downloads plan, phase 2); a Remove that fails says why under it, and the state stays (phase K, 9)
struct TravelMapRow: View {
    let held: TravelHeld
    @State private var removing = false
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TravelMaps.title(held.entry))
            Text(TravelMaps.heldLine(held)).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            if let failed { Text(failed).font(.pmNote).foregroundStyle(PrepareMeColors.red) }
            Button("Remove from this \(ThisDevice.word)", role: .destructive) { removing = true }.pmAction()
        }
        .contextMenu {  // a held finger: the row's button (docs/design/menus.md)
            PMMenuDelete(FileRow.removeMenu, systemImage: "trash") { removing = true }
        }
        .confirmationDialog("Remove \(TravelMaps.title(held.entry))'s map from this \(ThisDevice.word)?",
                            isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                do {
                    try PrepareMeTravel.store.remove(held.entry.state)
                    failed = nil
                } catch {
                    failed = TravelMaps.removeFailed(held.entry, reason: FileCopy.reason(error),
                                                     device: ThisDevice.word)
                }
            }
        } message: {
            Text("It frees \(StorageWords.size(held.entry.size)). Add it again from the \(TravelMaps.folderName) "
                 + "folder, with internet.")
        }
    }
}

/// This phone's record of travel maps can't be read (phase K, finding 10): said on Home Mac › Street map and on Add a
/// travel map, with Start over behind its question (the owner's choice 2, 2026-10-20; a child's phone too since the
/// family downloads plan, phase 2). A Start over that can't delete the record leaves it locked, so the line and the
/// button stay.
struct TravelDamagedRows: View {
    @ObservedObject private var travel = PrepareMeTravel.store
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TravelMaps.damagedRecord(device: ThisDevice.word)).foregroundStyle(PrepareMeColors.red)
            Button(TravelMaps.startOver, role: .destructive) { asking = true }.pmAction()
        }
        .confirmationDialog(TravelMaps.startOverQuestion(device: ThisDevice.word), isPresented: $asking,
                            titleVisibility: .visible) {
            Button(TravelMaps.startOver, role: .destructive) { try? travel.startOver() }
        }
    }
}
#endif
