import Foundation
import PrepareMeShared
import XCTest

/// The phone's copies on disk and its record (plan phase 4), with a fake reader and made-up files in a fresh temporary
/// folder: the swap, and each failure the phase 4 review found (C1, C2, I1, I2, I5, M1, M5).
@MainActor
final class LibraryStoreTests: XCTestCase {
    var root: URL!
    var reader: FakeReader!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = FakeReader()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func store(zimProblem: String? = nil, write: ((Data, URL) throws -> Void)? = nil) -> LibraryStore {
        let made = LibraryStore(root: root, reader: reader, zimProblem: { _, _ in zimProblem },
                                write: write ?? { try DurableFile.write($0, to: $1) })
        made.prepareFolders()
        return made
    }

    /// A made-up copy: its bytes and the manifest entry that describes them.
    func copy(_ text: String, name: String = "daily.zim") throws -> (Data, Manifest.Entry) {
        let data = Data(text.utf8)
        let file = root.appendingPathComponent("scratch")
        try data.write(to: file)
        let entry = Manifest.Entry(name: name, id: "0f1e2d3c-4b5a-4968-8776-6554433221a1", kind: "library",
                                   size: Int64(data.count), sha256: try FileCheck.sha256(of: file),
                                   deliveredAt: "2026-10-13T12:00:00-04:00")
        return (data, entry)
    }

    func download(_ store: LibraryStore, _ data: Data, _ entry: Manifest.Entry) throws {
        try data.write(to: store.incoming(entry))
        store.handOver(entry)
    }

    func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func files(_ folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    func testACheckedCopyIsSwappedInAndTheOldOneGoesAfter() async throws {
        let store = store()
        let (one, first) = try copy("first")
        try download(store, one, first)
        await store.checkWaiting()
        XCTAssertEqual(store.record.held["daily.zim"]?.entry, first)
        let (two, second) = try copy("second")
        try download(store, two, second)
        await store.checkWaiting()
        XCTAssertEqual(store.record.held["daily.zim"]?.entry, second)
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(second)])
        XCTAssertEqual(reader.registered.map(\.lastPathComponent), [LibraryPlan.fileName(first),
                                                                    LibraryPlan.fileName(second)])
        XCTAssertEqual(reader.swaps, 2)
        XCTAssertEqual(files(store.incomingFolder), [])
        XCTAssertEqual(LibraryStore(root: root, reader: reader, zimProblem: { _, _ in nil }).record.held["daily.zim"]?
            .entry, second, "saved")
    }

    /// Plan phase 8: an optional map is removed from the phone (the reader lets go first) and not fetched again; a
    /// library file the Mac's list names can't be removed, as it would only come back; one the list dropped can.
    func testRemoveTakesOffAnOptionalMapButNeverALibraryFile() async throws {
        let store = store()
        let (data, daily) = try copy("daily")
        try download(store, data, daily)
        await store.checkWaiting()
        var (topo, map) = try copy("topo", name: "topo.zim")
        map.kind = "map-optional"
        store.request(map)
        try download(store, topo, map)
        await store.checkWaiting()
        store.read(Manifest(writtenAt: "2026-10-14T12:00:00Z", files: [daily, map]), at: Date())
        XCTAssertEqual(files(store.libraryFolder).count, 2)

        let refused = await store.remove("daily.zim")
        XCTAssertFalse(refused)
        XCTAssertNotNil(store.record.held["daily.zim"])
        let removed = await store.remove("topo.zim")
        XCTAssertTrue(removed)
        XCTAssertEqual(reader.removed, [map.id])
        XCTAssertNil(store.record.held["topo.zim"])
        XCTAssertFalse(store.record.requested.contains("topo.zim"))
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(daily)])
        XCTAssertEqual(LibraryPlan.toFetch(store.record.manifest!, store.record).map(\.name), [], "not fetched again")

        store.read(Manifest(writtenAt: "2026-10-14T13:00:00Z", files: []), at: Date())  // the Mac dropped the daily
        XCTAssertEqual(LibraryPlan.dropped(store.record).map(\.entry.name), ["daily.zim"])
        let gone = await store.remove("daily.zim")
        XCTAssertTrue(gone)
        XCTAssertEqual(files(store.libraryFolder), [])
    }

    /// Family downloads plan, phase 3: at its check a device lets go of each held name in the Mac's `drop`, never a
    /// library file the list still sends, and doesn't mark it removed, so the Mac can offer it again; a held file the
    /// list merely no longer names stays under "No longer sent by the Mac"
    func testLetGoDroppedLetsGoOnlyOfNamesInDropAndKeepsAFileMerelyAbsent() async throws {
        let store = store()
        let (data, daily) = try copy("daily")
        try download(store, data, daily)
        await store.checkWaiting()
        var maps: [Manifest.Entry] = []
        for (index, name) in ["topo.zim", "roads.zim"].enumerated() {
            let (bytes, made) = try copy(name, name: name)
            var map = made
            map.kind = "map-optional"
            map.fetch = "room"
            map.id = ["1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e"][index]
            store.request(map)
            try download(store, bytes, map)
            await store.checkWaiting()
            maps.append(map)
        }
        store.request(Manifest.Entry(name: "asked.zim", id: "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f", kind: "download",
                                     size: 1, sha256: String(repeating: "c", count: 64), deliveredAt: "x"))
        var listed = Manifest(writtenAt: "2026-11-15T12:00:00Z", files: [daily])  // roads.zim merely absent
        listed.drop = ["topo.zim", "asked.zim", "daily.zim", "never-held.zim"]
        store.read(listed, at: Date())

        let gone = await store.letGoDropped()
        XCTAssertEqual(gone, ["topo.zim"], "the daily is still sent: never let go of")
        XCTAssertEqual(reader.removed, [maps[0].id])
        XCTAssertNotNil(store.record.held["roads.zim"])
        XCTAssertEqual(LibraryPlan.dropped(store.record).map(\.entry.name), ["roads.zim"])
        XCTAssertFalse(store.record.declined.contains("topo.zim"))
        XCTAssertFalse(store.record.requested.contains("asked.zim"), "a tap on a file the Mac now drops is forgotten")
        listed.drop = nil
        listed.files.append(maps[0])
        store.read(listed, at: Date())
        XCTAssertEqual(LibraryPlan.toFetch(store.record.manifest!, store.record).map(\.name), ["topo.zim"],
                       "offered again: it comes back")
    }

    /// Family downloads plan, phase 3: a stored "never" is Offered now, so a device holding it keeps it, a child's too
    /// (the old `dropNever` let go of it on a child's phone)
    func testAStoredNeverNoLongerLetsGoOfAnything() async throws {
        let store = store()
        var (topo, map) = try copy("topo", name: "topo.zim")
        map.kind = "map-optional"
        map.fetch = "room"
        store.request(map)
        try download(store, topo, map)
        await store.checkWaiting()
        var listed = Manifest(writtenAt: "2026-11-15T12:00:00Z", files: [map])
        listed.choices = ["topo.zim": "never"]
        store.read(listed, at: Date())

        let gone = await store.letGoDropped()
        XCTAssertEqual(gone, [])
        XCTAssertNotNil(store.record.held["topo.zim"])
    }

    /// Family downloads plan, phase 3: a download that finishes for a name the Mac's list now drops, or no longer names,
    /// is dropped, never installed, and is no longer asked for
    func testACopyThatFinishesForADroppedOrUnlistedNameIsNeverInstalled() async throws {
        for drop in [true, false] {
            let store = store()
            let (topo, made) = try copy("topo \(drop)", name: "topo.zim")
            var map = made
            map.kind = "map-optional"
            store.read(Manifest(writtenAt: "2026-11-15T12:00:00Z", files: [map]), at: Date())
            store.request(map)
            try download(store, topo, map)
            var listed = Manifest(writtenAt: "2026-11-15T13:00:00Z", files: drop ? [map] : [])  // dropped, or unlisted
            if drop { listed.drop = ["topo.zim"] }
            store.read(listed, at: Date())
            await store.checkWaiting()
            XCTAssertNil(store.record.held["topo.zim"])
            XCTAssertFalse(store.record.requested.contains("topo.zim"))
            XCTAssertEqual(files(store.incomingFolder), [])
            XCTAssertEqual(store.record.checking, [])
            try? FileManager.default.removeItem(at: store.root.appendingPathComponent("library-state.json"))
        }
    }

    /// Phase 8 review, 2: Remove isn't undone by a newer copy already downloaded and waiting for its check, nor by one
    /// that finishes downloading afterwards.
    func testRemoveIsNotUndoneByACopyWaitingForItsCheck() async throws {
        let store = store()
        var (topo, map) = try copy("topo", name: "topo.zim")
        map.kind = "map-optional"
        store.request(map)
        try download(store, topo, map)
        await store.checkWaiting()
        var (newer, update) = try copy("topo two", name: "topo.zim")
        update.kind = "map-optional"
        store.read(Manifest(writtenAt: "2026-10-14T12:00:00Z", files: [update]), at: Date())
        try download(store, newer, update)  // waiting for its check
        let removed = await store.remove("topo.zim")
        XCTAssertTrue(removed)
        await store.checkWaiting()
        XCTAssertNil(store.record.held["topo.zim"])
        XCTAssertEqual(files(store.incomingFolder), [])
        try download(store, newer, update)  // a download that was in flight finishes after
        await store.checkWaiting()
        XCTAssertNil(store.record.held["topo.zim"], "never installed")
        XCTAssertEqual(files(store.incomingFolder), [])
        store.request(update)  // Get this file again: fetched as before
        XCTAssertEqual(LibraryPlan.toFetch(store.record.manifest!, store.record).map(\.name), ["topo.zim"])
    }

    func testAWrongCopyIsRefusedAndTheHeldOneKept() async throws {
        let store = store()
        let (one, first) = try copy("first")
        try download(store, one, first)
        await store.checkWaiting()
        let (_, second) = try copy("second")
        try download(store, Data("third".utf8), second)  // not the bytes the entry describes
        await store.checkWaiting()
        XCTAssertEqual(store.record.held["daily.zim"]?.entry, first)
        XCTAssertEqual(store.record.refusals[second.sha256], 1)
        XCTAssertNotNil(store.lastRefusal)
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(first)])
        XCTAssertEqual(files(store.incomingFolder), [])
    }

    /// Phase K's drills, finding 6: a copy from Add from Files' folder that its checks refuse is worded as the folder's,
    /// with nothing retried (nothing retries a folder), and never counted against the Mac's copy, which Wi-Fi still
    /// fetches at home; the same copy from the Mac afterwards is the Mac's again
    func testAFoldersRefusedCopyIsWordedAsTheFoldersAndNeverCounted() async throws {
        let store = store(zimProblem: "it carries another library's ID")
        store.wording = .device("iPad")
        let (one, first) = try copy("first")
        try one.write(to: store.incoming(first))
        store.handOver(first, from: .folder)
        await store.checkWaiting()
        XCTAssertEqual(store.notes["daily.zim"],
                       "The folder's copy was refused (it carries another library's ID); keeping the copy this iPad has.")
        XCTAssertNil(store.record.refusals[first.sha256])
        XCTAssertFalse(LibraryPlan.isRefused(first, store.record))
        XCTAssertNotNil(store.lastRefusal)
        XCTAssertEqual(files(store.incomingFolder), [])
        try download(store, one, first)
        await store.checkWaiting()
        XCTAssertEqual(store.notes["daily.zim"], "The Mac's copy was refused (it carries another library's ID); keeping "
                       + "the copy this iPad has and trying once more.")
        XCTAssertEqual(store.record.refusals[first.sha256], 1)
    }

    func testAFoldersCopyThatCantBeOpenedIsTheFoldersToo() async throws {
        let store = store()
        reader.refuse = true
        let (one, first) = try copy("first")
        try one.write(to: store.incoming(first))
        store.handOver(first, from: .folder)
        await store.checkWaiting()
        XCTAssertEqual(store.notes["daily.zim"], "The folder's copy was refused (it passed its checks but couldn't be put "
                       + "in place); keeping the copy this phone has.")
        XCTAssertNil(store.record.refusals[first.sha256])
    }

    func testTheReadersOwnCheckRefusesACopy() async throws {
        let store = store(zimProblem: "it carries another library's ID")
        let (one, first) = try copy("first")
        try download(store, one, first)
        await store.checkWaiting()
        XCTAssertNil(store.record.held["daily.zim"])
        XCTAssertEqual(store.record.refusals[first.sha256], 1)
        XCTAssertEqual(reader.registered, [])
    }

    func testARecordThatCantBeSavedKeepsTheOldCopy() async throws {  // review C1
        var failing = false
        let store = store(write: { data, url in
            if failing { throw POSIXError(.ENOSPC) }
            try DurableFile.write(data, to: url)
        })
        let (one, first) = try copy("first")
        try download(store, one, first)
        await store.checkWaiting()
        let (two, second) = try copy("second")
        try download(store, two, second)
        failing = true
        await store.checkWaiting()
        XCTAssertEqual(store.record.held["daily.zim"]?.entry, first)
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(first)], "the old copy kept, the new one gone")
        XCTAssertEqual(reader.registered.last?.lastPathComponent, LibraryPlan.fileName(first), "the reader sent back")
        failing = false
        await store.reconcile()
        XCTAssertEqual(store.record.held["daily.zim"]?.entry, first)
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(first)], "the tidy-up deletes nothing held")
    }

    func testTheTidyUpWaitsForASwapInProgress() async throws {  // review C2
        let store = store()
        let (one, first) = try copy("first")
        try download(store, one, first)
        reader.holdNextRegister = true
        let swap = Task { await store.checkWaiting() }
        while !reader.isHolding { await Task.yield() }
        let tidy = Task { await store.reconcile() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(first)], "not deleted mid-swap")
        reader.release()
        await swap.value
        await tidy.value
        XCTAssertEqual(store.record.held["daily.zim"]?.entry, first)
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(first)])
    }

    func testARecordThatCantBeReadDeletesNothingUntilAManifestAdoptsTheFiles() async throws {  // review I1
        let first = try await installed("first")
        try Data("{".utf8).write(to: root.appendingPathComponent("library-state.json"))
        let store = store()
        XCTAssertTrue(store.recordWasUnreadable)
        XCTAssertEqual(store.record.held, [:])
        await store.reconcile()
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(first)], "nothing deleted without a manifest")
        store.read(Manifest(writtenAt: "2026-10-13T12:00:00-04:00", files: [first]), at: Date())
        await store.reconcile()
        XCTAssertEqual(store.record.held["daily.zim"]?.entry, first, "adopted back by its SHA-256")
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(first)])
        XCTAssertFalse(store.recordWasUnreadable)
        XCTAssertTrue(files(root).contains { $0.hasPrefix("library-state.unreadable-") }, "the old record kept aside")
    }

    /// Plan phase 10, after D7: the library in Files follows each swap and launch, but a record that can't be read
    /// never empties it, as the App Store Kiwix may be the reader left while the Mac is out of reach (review, 2026-10-15).
    func testFilesFollowsTheRecordButARecordThatCantBeReadNeverEmptiesIt() async throws {
        let shelf = root.appendingPathComponent("Documents")
        let shown = shelf.appendingPathComponent("daily.zim")
        var store = store()
        store.shelf = shelf
        _ = try await installed("first", into: store)
        XCTAssertEqual(try text(shown), "first", "shown once swapped in")
        let second = try await installed("second", into: store)
        XCTAssertEqual(try text(shown), "second", "and each update")

        try Data("{".utf8).write(to: root.appendingPathComponent("library-state.json"))
        store = self.store()
        store.shelf = shelf
        XCTAssertTrue(store.recordWasUnreadable)
        await store.reconcile()
        XCTAssertEqual(try text(shown), "second", "kept while the record is unknown")
        store.read(Manifest(writtenAt: "2026-10-13T12:00:00-04:00", files: [second]), at: Date())
        await store.reconcile()
        XCTAssertEqual(try text(shown), "second", "adopted back, still shown")
    }

    /// The Files folder is backed up (Kiwix's session, a file someone saves there), so each link must carry its held
    /// copy's own mark: a link is the same file, so marking the copy marks the link (review, 2026-10-15).
    func testTheLibraryInFilesStaysOutOfBackups() async throws {
        let shelf = FileManager.default.temporaryDirectory  // outside the store's folder, as on the phone
            .appendingPathComponent("prepareme-documents-\(UUID())")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: shelf) }
        let shown = shelf.appendingPathComponent("daily.zim")
        func excluded(_ url: URL) throws -> Bool? {
            try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        }
        let store = store()
        store.shelf = shelf
        _ = try await installed("first", into: store)
        XCTAssertEqual(try excluded(shown), true, "the link, through its held copy")
        XCTAssertEqual(try excluded(shelf), false, "never the folder")

        var held = store.libraryFolder.appendingPathComponent(try XCTUnwrap(store.record.held["daily.zim"]).file)
        var unmarked = URLResourceValues()
        unmarked.isExcludedFromBackup = false
        try held.setResourceValues(unmarked)
        await store.reconcile()
        XCTAssertEqual(try excluded(shown), true, "a copy that lost its mark is marked again")
    }

    /// Audit D1: the top folder holds files that live only on this device (waiting inventory changes, pins, game saves),
    /// so it is never marked out of backups, and a mark an earlier build left on it is taken off; the library, its
    /// downloads and the record that names them stay out.
    func testOnlyTheLibraryIsKeptOutOfBackups() async throws {
        func excluded(_ url: URL) throws -> Bool? {
            try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try EarlierBuild.leaveBackupMark(on: root)  // as every device in use has it, from earlier builds
        let store = store()
        XCTAssertEqual(try excluded(root), false, "the top folder is never marked")
        XCTAssertEqual(try excluded(store.libraryFolder), true)
        XCTAssertEqual(try excluded(root.appendingPathComponent("incoming")), true)
        _ = try await installed("first", into: store)
        XCTAssertEqual(try excluded(store.recordFile), true, "the record names files a backup leaves out")
        XCTAssertEqual(try excluded(root), false, "still unmarked after an install")
        let waiting = root.appendingPathComponent("inventory-outbox.json")
        try Data("{}".utf8).write(to: waiting)
        XCTAssertEqual(try excluded(waiting), false, "a phone-only file beside the library is backed up")
    }

    func testARecordThatCantBeReadForAnotherReasonIsNeverWrittenOver() async throws {  // whole-branch review 3
        let first = try await installed("first")
        let recordFile = root.appendingPathComponent("library-state.json")
        let kept = try Data(contentsOf: recordFile)
        try FileManager.default.removeItem(at: recordFile)
        try FileManager.default.createDirectory(at: recordFile, withIntermediateDirectories: false)  // read fails
        var wrote = false
        let store = store(write: { data, url in
            wrote = true
            try DurableFile.write(data, to: url)
        })
        XCTAssertTrue(store.recordWasUnreadable)
        let (two, second) = try copy("second")
        try download(store, two, second)
        await store.checkWaiting()
        XCTAssertFalse(wrote, "nothing written over a record that couldn't be read")
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(first)], "nothing deleted or swapped")
        try FileManager.default.removeItem(at: recordFile)
        try kept.write(to: recordFile)
        XCTAssertEqual(self.store().record.held["daily.zim"]?.entry, first, "the next launch reads it")
    }

    /// A launch before the first unlock after a restart can't read the record; the app runs on once the phone is
    /// unlocked, so the reconcile when it opens reads it then (owner's phone, 2026-10-25: Today blank, and Kiwix's
    /// "Unable to load the page requested", on the first start after a restart only).
    func testARecordLockedAtLaunchIsReadOnceItCanBe() async throws {
        let first = try await installed("first")
        let recordFile = root.appendingPathComponent("library-state.json")
        let kept = try Data(contentsOf: recordFile)
        try FileManager.default.removeItem(at: recordFile)
        try FileManager.default.createDirectory(at: recordFile, withIntermediateDirectories: false)  // read fails
        let store = store()
        XCTAssertTrue(store.recordLocked)
        XCTAssertEqual(store.record.held, [:])
        try FileManager.default.removeItem(at: recordFile)
        try kept.write(to: recordFile)  // unlocked
        await store.reconcile()
        XCTAssertFalse(store.recordLocked)
        XCTAssertFalse(store.recordWasUnreadable)
        XCTAssertEqual(store.record.held["daily.zim"]?.entry, first)
        XCTAssertEqual(files(store.libraryFolder), [LibraryPlan.fileName(first)])
    }

    func testTheSameCopyTwiceNeverReplacesTheOneInPlace() async throws {  // review I2
        let store = store()
        let (one, first) = try copy("first")
        try download(store, one, first)
        await store.checkWaiting()
        let inPlace = store.libraryFolder.appendingPathComponent(LibraryPlan.fileName(first))
        let before = try FileManager.default.attributesOfItem(atPath: inPlace.path)[.systemFileNumber] as? Int
        try download(store, one, first)
        await store.checkWaiting()
        let after = try FileManager.default.attributesOfItem(atPath: inPlace.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "the open copy's file untouched")
        XCTAssertEqual(files(store.incomingFolder), [])
    }

    func testACopyThatCantBeOpenedCountsAsARefusal() async throws {  // review I5
        let store = store()
        reader.refuse = true
        let (one, first) = try copy("first")
        try download(store, one, first)
        await store.checkWaiting()
        XCTAssertEqual(store.record.refusals[first.sha256], 1)
        try download(store, one, first)
        await store.checkWaiting()
        XCTAssertTrue(LibraryPlan.isRefused(first, store.record), "not downloaded again forever")
        XCTAssertEqual(files(store.libraryFolder), [])
    }

    func testAMissingDownloadIsFetchedAgainNotRefused() async throws {  // review M1
        let store = store()
        let (_, first) = try copy("first")
        store.handOver(first)
        await store.checkWaiting()
        XCTAssertEqual(store.record.checking, [])
        XCTAssertNil(store.record.refusals[first.sha256])
    }

    func testAFinishedDownloadTheRecordMissedIsAdoptedForChecking() async throws {  // review M1
        let store = store()
        let (one, first) = try copy("first")
        store.read(Manifest(writtenAt: "2026-10-13T12:00:00-04:00", files: [first]), at: Date())
        try one.write(to: store.incoming(first))  // moved by the downloader, killed before its hand-over was saved
        let stale = store.incomingFolder.appendingPathComponent("\(String(repeating: "f", count: 64)).resume")
        try Data("partial".utf8).write(to: stale)
        await store.reconcile()
        XCTAssertEqual(store.record.held["daily.zim"]?.entry, first)
        XCTAssertEqual(files(store.incomingFolder), [], "the copy no longer wanted: its resume data gone too")
    }

    func testAHeldCopyTheReaderCantOpenIsDroppedAndFetchedAgain() async throws {  // review M5
        let first = try await installed("first")
        let store = store()
        reader.paths = [:]
        reader.refuse = true
        await store.reconcile()
        XCTAssertNil(store.record.held["daily.zim"])
        XCTAssertEqual(LibraryPlan.toFetch(Manifest(writtenAt: "x", files: [first]), store.record).map(\.name),
                       ["daily.zim"])
        XCTAssertEqual(files(store.libraryFolder), [])
    }

    /// A copy installed by `store`, or by a store of its own, as a previous launch left it.
    func installed(_ text: String, into store: LibraryStore? = nil) async throws -> Manifest.Entry {
        let store = store ?? self.store()
        let (data, entry) = try copy(text)
        try download(store, data, entry)
        await store.checkWaiting()
        XCTAssertEqual(store.record.held["daily.zim"]?.entry, entry)
        return entry
    }
}

@MainActor
final class FakeReader: LibraryReader {
    var registered: [URL] = []
    var paths: [String: String] = [:]
    var swaps = 0
    var refuse = false
    var holdNextRegister = false
    private(set) var isHolding = false
    private var held: CheckedContinuation<Void, Never>?

    func register(_ file: URL) async -> Bool {
        if holdNextRegister {
            holdNextRegister = false
            isHolding = true
            await withCheckedContinuation { held = $0 }
            isHolding = false
        }
        guard !refuse else { return false }
        registered.append(file)
        paths["0f1e2d3c-4b5a-4968-8776-6554433221a1"] = file.path
        return true
    }

    func release() {
        held?.resume()
        held = nil
    }

    func registeredPath(of id: String) async -> String? { paths[id] }
    func knows(_ id: String) -> Bool { paths[id] != nil }
    func swapped(_ entry: Manifest.Entry, wasNew: Bool) async { swaps += 1 }
    var removed: [String] = []
    func remove(_ id: String) async {
        removed.append(id)
        paths[id] = nil
    }
}
