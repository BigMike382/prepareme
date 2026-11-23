import Foundation
import PrepareMeShared
import XCTest

/// The Mac app's copies of the packer's local folder (plan phase 6): each file the folder's list names is cloned into the
/// app's own storage under a name of its own and checked before the reader opens it, so a file the packer replaces at
/// its path is never read mid-swap (FINDINGS F-064). Made-up files in a fresh temporary folder; never the real one.
@MainActor
final class FolderSyncTests: XCTestCase {
    var base: URL!
    var folder: URL!  // the packer's local folder, made up
    var reader: FolderReader!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-folder-\(UUID())")
        folder = base.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reader = FolderReader()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    static let dailyID = "0f1e2d3c-4b5a-4968-8776-6554433221a1"
    static let mapID = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"

    func sync(zimProblem: String? = nil, now: @escaping @Sendable () -> Date = { Date() }) -> FolderSync {
        let store = LibraryStore(root: base.appendingPathComponent("app"), reader: reader,
                                 zimProblem: { _, _ in zimProblem })
        return FolderSync(store: store, folder: folder, now: now)
    }

    /// A file put in the folder the packer's way (a temporary name, then a swap), and its manifest entry.
    @discardableResult
    func deliver(_ text: String, name: String = "prepareme-daily.zim", id: String = dailyID,
                 kind: String = "library") throws -> Manifest.Entry {
        let data = Data(text.utf8)
        let temporary = folder.appendingPathComponent(".\(name).tmp")
        try data.write(to: temporary)
        let entry = Manifest.Entry(name: name, id: id, kind: kind, size: Int64(data.count),
                                   sha256: try FileCheck.sha256(of: temporary), deliveredAt: "2026-10-13T12:00:00-04:00")
        guard rename(temporary.path, folder.appendingPathComponent(name).path) == 0 else { throw POSIXError(.EIO) }
        return entry
    }

    func list(_ entries: [Manifest.Entry]) throws {
        let manifest = Manifest(writtenAt: "2026-10-13T12:00:00-04:00", files: entries)
        try manifest.encoded().write(to: folder.appendingPathComponent("manifest.json"))
    }

    func held(_ sync: FolderSync) -> [String: String] {
        sync.store.record.held.mapValues(\.entry.sha256)
    }

    func text(_ sync: FolderSync, _ name: String) throws -> String {
        let file = try XCTUnwrap(sync.store.record.held[name]).file
        return try String(contentsOf: sync.store.libraryFolder.appendingPathComponent(file), encoding: .utf8)
    }

    func inode(_ url: URL) -> UInt64 {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_ino : 0
    }

    func testEveryFileTheListNamesIsClonedCheckedAndHeldUnderItsOwnName() async throws {
        let daily = try deliver("daily one")
        let map = try deliver("an optional map", name: "maps-optional-1.zim", id: Self.mapID, kind: "map-optional")
        try list([daily, map])
        let sync = sync()
        await sync.check()
        XCTAssertEqual(held(sync), ["prepareme-daily.zim": daily.sha256, "maps-optional-1.zim": map.sha256])
        XCTAssertEqual(try text(sync, "prepareme-daily.zim"), "daily one")
        let copy = sync.store.libraryFolder.appendingPathComponent(LibraryPlan.fileName(daily))
        XCTAssertNotEqual(inode(copy), inode(folder.appendingPathComponent("prepareme-daily.zim")))  // its own file
        XCTAssertNil(sync.problem)
        XCTAssertNil(sync.copying)
    }

    /// Phase 8 review, 1: a download removed on the Mac isn't cloned back while the folder's list still names it, and
    /// is let go once the list drops it; kept again, it comes back.
    func testADownloadRemovedOnTheMacStaysRemoved() async throws {
        let daily = try deliver("daily one")
        let wiki = try deliver("a made-up download", name: "sample_en_2026-08.zim", id: Self.mapID, kind: "download")
        try list([daily, wiki])
        let sync = sync()
        await sync.check()
        XCTAssertNotNil(sync.store.record.held["sample_en_2026-08.zim"])
        let removed = await sync.store.remove("sample_en_2026-08.zim")  // the Downloads screen's Remove
        XCTAssertTrue(removed)
        await sync.check()  // the packer hasn't run yet: the list still names it
        XCTAssertNil(sync.store.record.held["sample_en_2026-08.zim"], "never cloned back")
        try list([daily])  // the packer dropped it
        await sync.check()
        XCTAssertFalse(sync.store.record.declined.contains("sample_en_2026-08.zim"))
        try list([daily, wiki])  // kept again later
        await sync.check()
        XCTAssertNotNil(sync.store.record.held["sample_en_2026-08.zim"])
    }

    /// Phase 8 review, 1: a download the Mac held before the list dropped it (removed outside the app) is let go.
    func testADownloadTheListDropsIsLetGo() async throws {
        let daily = try deliver("daily one")
        let wiki = try deliver("a made-up download", name: "sample_en_2026-08.zim", id: Self.mapID, kind: "download")
        try list([daily, wiki])
        let sync = sync()
        await sync.check()
        try list([daily])
        await sync.check()
        XCTAssertEqual(held(sync).keys.sorted(), ["prepareme-daily.zim"])
    }

    func testAFileReplacedInTheFolderNeverChangesTheCopyTheReaderHas() async throws {
        let first = try deliver("daily one")
        try list([first])
        let sync = sync()
        await sync.check()
        let firstCopy = sync.store.libraryFolder.appendingPathComponent(LibraryPlan.fileName(first))
        let second = try deliver("daily two")
        try list([second])
        XCTAssertEqual(try String(contentsOf: firstCopy, encoding: .utf8), "daily one")  // untouched by the packer
        await sync.check()
        XCTAssertEqual(try text(sync, "prepareme-daily.zim"), "daily two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCopy.path))  // the old copy goes once swapped
        XCTAssertEqual(reader.swaps, 2)
    }

    func testAFileSwappedBeforeTheListIsWrittenIsNotRefused() async throws {
        let first = try deliver("daily one")
        try list([first])
        let sync = sync()
        await sync.check()
        let second = try deliver("daily two")
        try list([second])
        try await Task.sleep(for: .milliseconds(20))
        let third = try deliver("daily three")  // the next build swapped the file; its list isn't written yet
        await sync.check()  // the list asks for the second copy; the folder holds the third
        XCTAssertEqual(sync.store.record.refusals, [:])
        XCTAssertEqual(sync.store.notes["prepareme-daily.zim"], FolderSync.beingUpdated)
        XCTAssertEqual(held(sync), ["prepareme-daily.zim": first.sha256])  // the copy it had stays
        try list([third])
        await sync.check()
        XCTAssertEqual(held(sync), ["prepareme-daily.zim": third.sha256])
        XCTAssertEqual(sync.store.record.refusals, [:])
    }

    func testAListRewrittenDuringALookNeverRefusesTheNewCopy() async throws {
        // whole-branch review, 1: the look read list 1, and before it copied the file the packer swapped it and wrote
        // list 2, so the copy is list 2's file checked against list 1's entry
        let first = try deliver("daily one")
        try list([first])
        let sync = sync()
        var second: Manifest.Entry?
        sync.beforeClone = { [unowned self] _ in
            sync.beforeClone = nil
            second = try? self.deliver("daily two")
            try? self.list([second!])
        }
        await sync.check()
        XCTAssertEqual(sync.store.record.refusals, [:])
        XCTAssertEqual(sync.store.notes["prepareme-daily.zim"], FolderSync.beingUpdated)
        await sync.check()
        XCTAssertEqual(held(sync), ["prepareme-daily.zim": try XCTUnwrap(second).sha256])
        XCTAssertEqual(sync.store.record.refusals, [:])
    }

    func testAFileThatDisagreesWithAnOlderListIsNotRefusedWhileTheFolderIsBeingUpdated() async throws {
        let listed = try deliver("what the list says")
        try list([listed])
        try await Task.sleep(for: .milliseconds(20))
        try deliver("what the file is")  // changed after the list
        let sync = sync()
        await sync.check()
        XCTAssertEqual(sync.store.record.refusals, [:])
        XCTAssertEqual(held(sync), [:])
    }

    func testAFileThatDisagreesWithItsListLongAfterIsRefused() async throws {
        let listed = try deliver("what the list says")
        try await Task.sleep(for: .milliseconds(20))
        try deliver("what the file is")
        try await Task.sleep(for: .milliseconds(20))
        try list([listed])  // written after the file: the folder isn't being updated, the copy is wrong
        let sync = sync()
        await sync.check()
        XCTAssertEqual(sync.store.record.refusals[listed.sha256], 1)
        XCTAssertEqual(held(sync), [:])
    }

    func testAFileChangedAfterItsListButLongAgoIsRefused() async throws {
        let listed = try deliver("what the list says")
        try list([listed])
        try await Task.sleep(for: .milliseconds(20))
        try deliver("what the file is")
        let later = Date().addingTimeInterval(FolderSync.updateWindow + 60)
        let sync = sync(now: { later })  // the list was never rewritten: something other than the packer changed it
        await sync.check()
        XCTAssertEqual(sync.store.record.refusals[listed.sha256], 1)
    }

    func testAMissingListKeepsEveryCopyAndSaysSo() async throws {
        let daily = try deliver("daily one")
        try list([daily])
        let sync = sync()
        await sync.check()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("manifest.json"))
        await sync.check()
        XCTAssertEqual(held(sync), ["prepareme-daily.zim": daily.sha256])
        XCTAssertEqual(sync.problem, FolderSync.listUnreadable)
    }

    func testAFileTheListNamesButTheFolderLacksIsNotedAndTheRestGoOn() async throws {
        let daily = try deliver("daily one")
        let gone = try deliver("a map", name: "maps-core-1.zim", id: Self.mapID, kind: "map-core")
        try FileManager.default.removeItem(at: folder.appendingPathComponent(gone.name))
        try list([gone, daily])
        let sync = sync()
        await sync.check()
        XCTAssertEqual(held(sync), ["prepareme-daily.zim": daily.sha256])
        XCTAssertEqual(sync.store.notes["maps-core-1.zim"], FolderSync.notInFolder)
        XCTAssertEqual(sync.store.record.refusals, [:])
    }

    func testOneIDIsOneLibraryTheFirstInTheListWins() async throws {
        let first = try deliver("first", name: "a.zim")
        let second = try deliver("second", name: "b.zim")  // the same ID: the packer refuses this, but never twice here
        try list([first, second])
        let sync = sync()
        await sync.check()
        XCTAssertEqual(held(sync), ["a.zim": first.sha256])
    }

    func testAnUnchangedFolderIsNotCopiedOrCheckedAgain() async throws {
        let daily = try deliver("daily one")
        try list([daily])
        let sync = sync()
        await sync.check()
        await sync.check()
        XCTAssertEqual(reader.registered.count, 1)
        XCTAssertEqual(reader.swaps, 1)
    }
}

/// A reader that records each copy registered, by the library ID its test file stands for (name prefix → ID).
@MainActor
final class FolderReader: LibraryReader {
    var registered: [URL] = []
    var paths: [String: String] = [:]
    var swaps = 0

    func id(of file: URL) -> String {
        file.lastPathComponent.hasPrefix("maps-") ? FolderSyncTests.mapID : FolderSyncTests.dailyID
    }

    func register(_ file: URL) async -> Bool {
        registered.append(file)
        paths[id(of: file)] = file.path
        return true
    }

    func registeredPath(of id: String) async -> String? { paths[id] }
    func knows(_ id: String) -> Bool { paths[id] != nil }
    func swapped(_ entry: Manifest.Entry, wasNew: Bool) async { swaps += 1 }
    func remove(_ id: String) async { paths[id] = nil }
}
