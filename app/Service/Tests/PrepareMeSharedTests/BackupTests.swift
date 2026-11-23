import CryptoKit
import Foundation
import PrepareMeShared
import XCTest

/// The iCloud backup (concept-doc plan, phase A; docs/plans/2026-10-17-phase-a-icloud-backup.md): every file the phones
/// can get copied from the Mac app's own checked copies into PrepareMe Backup, only what changed (from the manifests,
/// never by reading the backup's copies), each read back before the backup's one manifest names it. Made-up files in a
/// fresh temporary folder standing in for iCloud Drive; never the real one.
final class BackupTests: XCTestCase {
    var base: URL!
    var source: URL!  // the app's library folder, made up
    var folder: URL!  // stands in for iCloud Drive › PrepareMe Backup
    var mirror: URL!  // the local copy of the backup's manifest (Application Support › PrepareMe › backup)

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-backup-\(UUID())")
        source = base.appendingPathComponent("library")
        folder = base.appendingPathComponent("PrepareMe Backup")
        mirror = base.appendingPathComponent("backup/manifest.json")
        for dir in [source!, folder!, mirror.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    static let ids = ["0f1e2d3c-4b5a-4968-8776-6554433221a1", "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                      "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e", "3c4d5e6f-7a8b-4c9d-8e0f-2a3b4c5d6e7f"]

    /// A held copy in the made-up library folder, under a name of its own, and its entry.
    @discardableResult
    func hold(_ text: String, name: String = "prepareme-daily.zim", id: String = ids[0], kind: String = "library",
              family: Bool? = nil, into held: inout [String: HeldFile]) throws -> Manifest.Entry {
        let data = Data(text.utf8)
        let file = "copy-\(UUID().uuidString)-\(name)"
        try data.write(to: source.appendingPathComponent(file))
        let entry = Manifest.Entry(name: name, id: id, kind: kind, size: Int64(data.count),
                                   sha256: try FileCheck.sha256(of: source.appendingPathComponent(file)),
                                   deliveredAt: "2026-10-17T12:00:00-04:00", family: family)
        held[name] = HeldFile(entry: entry, file: file)
        return entry
    }

    func manifest(_ entries: [Manifest.Entry]) -> Manifest {
        Manifest(writtenAt: "2026-10-17T12:00:00-04:00", files: entries)
    }

    func text(_ name: String, in dir: URL? = nil) throws -> String {
        try String(contentsOf: (dir ?? folder).appendingPathComponent(name), encoding: .utf8)
    }

    func backedUp() throws -> Manifest {
        try Manifest.read(Data(contentsOf: folder.appendingPathComponent(Backup.manifestName)))
    }

    /// The whole round: plan from what's on disk, then carry it out
    @discardableResult
    func back(up delivery: Manifest, _ held: [String: HeldFile], hooks: Backup.Hooks = .init()) throws -> Backup.Outcome {
        let plan = Backup.plan(delivery: delivery, held: held, backup: Backup.readMirror(mirror, folder: folder),
                               present: Backup.present(in: folder))
        return try Backup.run(plan, source: source, folder: folder, mirror: mirror,
                              writtenAt: "2026-10-17T13:00:00-04:00", hooks: hooks)
    }

    // MARK: What gets copied

    func testEveryFileThePhonesCanGetIsCopiedAndNamedInTheOneManifest() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily one", into: &held)
        let map = try hold("a map", name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", into: &held)
        let outcome = try back(up: manifest([daily, map]), held)
        XCTAssertEqual(outcome.copied.sorted(), ["prepareme-daily.zim", "prepareme-maps-roads.zim"])
        XCTAssertEqual(try text("prepareme-daily.zim"), "daily one")
        XCTAssertEqual(try text("prepareme-maps-roads.zim"), "a map")
        XCTAssertEqual(try backedUp().files, [daily, map])  // the delivery's order, its entries as they were
        XCTAssertEqual(try Manifest.read(Data(contentsOf: mirror)), try backedUp())
    }

    func testAFamilyFalseDownloadIsNeverCopiedOrNamed() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let mine = try hold("the Mac's own", name: "wikipedia-100.zim", id: Self.ids[1], kind: "download",
                            family: false, into: &held)
        let unset = try hold("unset", name: "other-download.zim", id: Self.ids[2], kind: "download", into: &held)
        let plan = Backup.plan(delivery: manifest([daily, mine, unset]), held: held, backup: nil, present: [:])
        XCTAssertEqual(plan.copies.map(\.entry.name), ["prepareme-daily.zim"])
        try back(up: manifest([daily, mine, unset]), held)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("wikipedia-100.zim").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("other-download.zim").path))
        XCTAssertEqual(try backedUp().files.map(\.name), ["prepareme-daily.zim"])
    }

    func testADownloadSwitchedOffForTheFamilyLeavesTheBackupAndItsManifest() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        var shared = try hold("shared", name: "wikipedia-100.zim", id: Self.ids[1], kind: "download", family: true,
                              into: &held)
        try back(up: manifest([daily, shared]), held)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("wikipedia-100.zim").path))
        shared.family = false
        held["wikipedia-100.zim"]?.entry = shared
        let outcome = try back(up: manifest([daily, shared]), held)
        XCTAssertEqual(outcome.removed, ["wikipedia-100.zim"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("wikipedia-100.zim").path))
        XCTAssertEqual(try backedUp().files.map(\.name), ["prepareme-daily.zim"])
        XCTAssertEqual(try Manifest.read(Data(contentsOf: mirror)).files.map(\.name), ["prepareme-daily.zim"])
    }

    func testAFileTheDeliveryNoLongerListsLeavesTheBackup() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let map = try hold("a map", name: "prepareme-maps-topo-today-1.zim", id: Self.ids[1], kind: "map-optional",
                           into: &held)
        try back(up: manifest([daily, map]), held)
        held[map.name] = nil
        XCTAssertEqual(try back(up: manifest([daily]), held).removed, ["prepareme-maps-topo-today-1.zim"])
        XCTAssertEqual(Backup.present(in: folder).keys.sorted(), [Backup.manifestName, "prepareme-daily.zim"])
    }

    func testAFileAlreadyBackedUpIsNotCopiedAgain() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let map = try hold("a map", name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", into: &held)
        try back(up: manifest([daily, map]), held)
        let plan = Backup.plan(delivery: manifest([daily, map]), held: held,
                               backup: Backup.readMirror(mirror, folder: folder), present: Backup.present(in: folder))
        XCTAssertEqual(plan.copies, [])
        XCTAssertFalse(plan.isDue)
        XCTAssertEqual(plan.bytes, 0)
    }

    func testOnlyTheChangedFileIsCopied() throws {
        var held: [String: HeldFile] = [:]
        _ = try hold("daily", into: &held)
        let map = try hold("a map", name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", into: &held)
        try back(up: manifest([held["prepareme-daily.zim"]!.entry, map]), held)
        let daily = try hold("daily two", into: &held)
        let outcome = try back(up: manifest([daily, map]), held)
        XCTAssertEqual(outcome.copied, ["prepareme-daily.zim"])
        XCTAssertEqual(try text("prepareme-daily.zim"), "daily two")
        XCTAssertEqual(try backedUp().files, [daily, map])
    }

    func testAMissingOrResizedBackupCopyIsCopiedAgainFromAStatNeverARead() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let map = try hold("a map", name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", into: &held)
        try back(up: manifest([daily, map]), held)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("prepareme-daily.zim"))
        try Data("a map, but longer".utf8).write(to: folder.appendingPathComponent("prepareme-maps-roads.zim"))
        let plan = Backup.plan(delivery: manifest([daily, map]), held: held,
                               backup: Backup.readMirror(mirror, folder: folder), present: Backup.present(in: folder))
        XCTAssertEqual(plan.copies.map(\.entry.name), ["prepareme-daily.zim", "prepareme-maps-roads.zim"])
    }

    func testAFileTheMacHasntGotCurrentKeepsTheBackupsOlderCopy() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let map = try hold("a map", name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", into: &held)
        try back(up: manifest([daily, map]), held)
        var newer = map
        newer.sha256 = String(repeating: "a", count: 64)  // the delivery's newer copy, refused or not yet checked here
        let plan = Backup.plan(delivery: manifest([daily, newer]), held: held,
                               backup: Backup.readMirror(mirror, folder: folder), present: Backup.present(in: folder))
        XCTAssertEqual(plan.copies, [])
        XCTAssertEqual(plan.kept, [daily, map])
        XCTAssertEqual(plan.current, 1)
        XCTAssertEqual(plan.wanted, 2)
        XCTAssertFalse(plan.isDue)
    }

    func testAFileTheMacHasntGotCurrentAndTheBackupLacksIsLeftOut() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let missing = Manifest.Entry(name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", size: 5,
                                     sha256: String(repeating: "b", count: 64), deliveredAt: "2026-10-17T12:00:00-04:00")
        let plan = Backup.plan(delivery: manifest([daily, missing]), held: held, backup: nil, present: [:])
        XCTAssertEqual(plan.copies.map(\.entry.name), ["prepareme-daily.zim"])
        XCTAssertEqual(plan.wanted, 2)
    }

    func testAnUnreadableMirrorAndNoManifestInTheFolderCountAsAnEmptyBackup() throws {
        try Data("not json".utf8).write(to: mirror)
        XCTAssertNil(Backup.readMirror(mirror, folder: folder))
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        try back(up: manifest([daily]), held)
        try Data("not json".utf8).write(to: mirror)
        XCTAssertEqual(Backup.readMirror(mirror, folder: folder), try backedUp())  // the folder's, only then
        try FileManager.default.removeItem(at: mirror)
        XCTAssertEqual(Backup.readMirror(mirror, folder: folder), try backedUp())
    }

    func testAChangedTitleRewritesTheManifestWithoutACopy() throws {
        var held: [String: HeldFile] = [:]
        var shared = try hold("shared", name: "wikipedia-100.zim", id: Self.ids[1], kind: "download", family: true,
                              into: &held)
        try back(up: manifest([shared]), held)
        shared.title = "Wikipedia 100"
        held[shared.name]?.entry = shared
        let plan = Backup.plan(delivery: manifest([shared]), held: held,
                               backup: Backup.readMirror(mirror, folder: folder), present: Backup.present(in: folder))
        XCTAssertEqual(plan.copies, [])
        XCTAssertTrue(plan.isDue)
        try Backup.run(plan, source: source, folder: folder, mirror: mirror, writtenAt: "2026-10-17T14:00:00-04:00")
        XCTAssertEqual(try backedUp().files.first?.title, "Wikipedia 100")
    }

    // MARK: Review, task 2

    func testNoDeliveryListOrOneNamingNothingForThePhonesTouchesNothing() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let mine = try hold("mine", name: "wikipedia-100.zim", id: Self.ids[1], kind: "download", family: false,
                            into: &held)
        try back(up: manifest([daily]), held)
        for delivery in [nil, manifest([]), manifest([mine])] {
            let plan = Backup.plan(delivery: delivery, held: held, backup: Backup.readMirror(mirror, folder: folder),
                                   present: Backup.present(in: folder))
            XCTAssertFalse(plan.isDue)
            XCTAssertEqual(plan.removals, [])
            XCTAssertEqual(plan.copies, [])
        }
        XCTAssertEqual(try text("prepareme-daily.zim"), "daily")
    }

    func testANameListedTwiceIsNeverCopied() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let shared = try hold("shared", name: "shared-copy.zim", id: Self.ids[1], kind: "download", family: true, into: &held)
        var mine = shared
        mine.family = false
        let plan = Backup.plan(delivery: manifest([daily, shared, mine]), held: held, backup: nil, present: [:])
        XCTAssertEqual(plan.copies.map(\.entry.name), ["prepareme-daily.zim"])
        XCTAssertEqual(plan.final.map(\.name), ["prepareme-daily.zim"])
    }

    func testAMirrorNamingLessThanTheFolderStillDropsTheChangingEntryFirst() throws {
        var held: [String: HeldFile] = [:]
        let first = try hold("daily one", into: &held)
        try back(up: manifest([first]), held)
        // the interim save stopped between its two writes: the mirror names nothing, the folder still names the daily
        try Manifest(writtenAt: "x", files: []).encoded().write(to: mirror)
        let daily = try hold("daily two", into: &held)
        struct Stopped: Error {}
        var hooks = Backup.Hooks()
        hooks.afterCopy = { _ in throw Stopped() }
        XCTAssertThrowsError(try back(up: manifest([daily]), held, hooks: hooks))
        for entry in try backedUp().files {
            XCTAssertEqual(try FileCheck.verify(folder.appendingPathComponent(entry.name), size: entry.size,
                                                sha256: entry.sha256), .ok, entry.name)
        }
    }

    func testTheOlderDailyThatCantBeKeptStopsItsCopy() throws {
        var held: [String: HeldFile] = [:]
        let first = try hold("daily one", into: &held)
        try back(up: manifest([first]), held)
        try Data("in the way".utf8).write(to: folder.appendingPathComponent(Backup.olderFolder))  // not a folder
        let daily = try hold("daily two", into: &held)
        let outcome = try back(up: manifest([daily]), held)
        XCTAssertEqual(outcome.failed, ["prepareme-daily.zim"])
        XCTAssertEqual(try text("prepareme-daily.zim"), "daily one")  // never lost
        XCTAssertEqual(try backedUp().files, [first])
    }

    func testAFileThatWontLeaveIsSaidApartFromACopy() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let shared = try hold("shared", name: "wikipedia-100.zim", id: Self.ids[1], kind: "download", family: true,
                              into: &held)
        try back(up: manifest([daily, shared]), held)
        let stuck = folder.appendingPathComponent("wikipedia-100.zim")
        XCTAssertEqual(chflags(stuck.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(stuck.path, 0) }
        var mine = shared
        mine.family = false
        held[mine.name]?.entry = mine
        let outcome = try back(up: manifest([daily, mine]), held)
        XCTAssertEqual(outcome.unremoved, ["wikipedia-100.zim"])
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(try backedUp().files.map(\.name), ["prepareme-daily.zim"])  // never named, all the same
        var status = BackupStatus()
        status.checkedAt = "2026-10-17T12:00:00-04:00"
        status.problem = BackupStatus.notRemoved
        status.failed = 1
        let line = "Not backed up: 1 file the phones no longer get couldn't be taken out of the backup folder; tried "
            + "again at the next check."
        XCTAssertEqual(BackupWords.line(status, upload: nil, now: Date()), line)
        XCTAssertEqual(BackupWords.attention(status, upload: nil), line)  // at once: it may be the Mac's own
    }

    func testAStoppedRunsSavesAreClearedNextTime() throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent(".manifest.json.tmp-1234"))
        try Data("x".utf8).write(to: folder.appendingPathComponent(".Read me first.txt.tmp-1234"))
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        try back(up: manifest([daily]), held)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".") }, "\(names)")
    }

    /// The phones' copy is written by DurableFile under its own temporary name (".backup-phone-inventory.json-…"), and
    /// DurableFile's temporary for that is "..backup-…": a stop part-way leaves that, which `name.hasPrefix(".backup-")`
    /// doesn't match (checkpoint 1: the "..backup-" entry is what clears it)
    func testAStoppedInventoryWritesTemporaryIsClearedNextTime() throws {
        let left = "..backup-\(PhoneInventory.fileName)-1234.tmp-5678"
        try Data("x".utf8).write(to: folder.appendingPathComponent(left))
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        try back(up: manifest([daily]), held)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains(left), "\(names)")
    }

    // MARK: Review, task 3 and the app

    func testAFileHeldOffAfterFailingKeepsTheOlderCopyAndIsntCopied() throws {
        var held: [String: HeldFile] = [:]
        let first = try hold("daily one", into: &held)
        try back(up: manifest([first]), held)
        let daily = try hold("daily two", into: &held)
        let plan = Backup.plan(delivery: manifest([daily]), held: held,
                               backup: Backup.readMirror(mirror, folder: folder), present: Backup.present(in: folder),
                               holdOff: ["prepareme-daily.zim"])
        XCTAssertEqual(plan.copies, [])
        XCTAssertEqual(plan.final, [first])
        XCTAssertEqual(plan.current, 0)
    }

    func testASourceTheLibraryLetGoOfMidRunWaitsAndIsntAFailure() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let plan = Backup.plan(delivery: manifest([daily]), held: held, backup: nil, present: [:])
        try FileManager.default.removeItem(at: source.appendingPathComponent(held["prepareme-daily.zim"]!.file))
        let outcome = try Backup.run(plan, source: source, folder: folder, mirror: mirror, writtenAt: "x")
        XCTAssertEqual(outcome.waiting, ["prepareme-daily.zim"])
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(try backedUp().files, [])
    }

    func testAReadMeThatCantBeWrittenNeverStopsTheBackup() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(Backup.readMeName),
                                                withIntermediateDirectories: true)  // in the way
        let plan = Backup.plan(delivery: manifest([daily]), held: held, backup: nil, present: [:])
        let outcome = try Backup.run(plan, source: source, folder: folder, mirror: mirror, writtenAt: "x", readMe: true)
        XCTAssertFalse(outcome.readMeWritten)
        XCTAssertEqual(outcome.copied, ["prepareme-daily.zim"])
        XCTAssertEqual(try backedUp().files, [daily])
    }

    func testUnknownFreeSpaceIsRefusedAndSaysSo() {
        XCTAssertEqual(Backup.room(bytes: 1, free: nil), Backup.Room(need: 10_000_000_001, free: nil))
        var status = BackupStatus()
        status.checkedAt = "2026-10-17T12:00:00-04:00"
        status.problem = BackupStatus.noRoom
        status.need = 76_000_000_000
        XCTAssertEqual(BackupWords.line(status, upload: nil, now: Date()),
                       "Not backed up: this Mac needs 76.0 GB free for it, and its free space couldn't be read.")
    }

    func testWaitingForMacOSsQuestionIsSaidAndNeedsTheOwner() {
        var status = BackupStatus()
        status.checkedAt = "2026-10-17T12:00:00-04:00"
        status.problem = BackupStatus.asking
        let line = "Not backed up yet: macOS is asking whether PrepareMe may use iCloud Drive. Choose Allow; the "
            + "question may be behind other windows."
        XCTAssertEqual(BackupWords.line(status, upload: nil, now: Date()), line)
        XCTAssertEqual(BackupWords.attention(status, upload: nil), line)
    }

    // MARK: Room

    func testTheSpaceCheckRefusesBelowTheFilesSizePlusTheMargin() {
        XCTAssertNil(Backup.room(bytes: 5_000_000_000, free: 15_000_000_000))
        XCTAssertEqual(Backup.room(bytes: 66_000_000_000, free: 40_000_000_000),
                       Backup.Room(need: 76_000_000_000, free: 40_000_000_000))
        XCTAssertNil(Backup.room(bytes: 0, free: 1))  // nothing to copy: nothing to refuse
    }

    // MARK: Carrying it out

    func testACopyThatFailsItsReadBackIsDeletedAndNeverNamedAndTheOlderCopyStays() throws {
        var held: [String: HeldFile] = [:]
        _ = try hold("daily", into: &held)
        let map = try hold("a map", name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", into: &held)
        let first = held["prepareme-daily.zim"]!.entry
        try back(up: manifest([first, map]), held)
        let daily = try hold("daily two", into: &held)
        var hooks = Backup.Hooks()
        hooks.beforeSwap = { _, copy in try? Data("damaged!!".utf8).write(to: copy) }  // a bad copy, same size
        let outcome = try back(up: manifest([daily, map]), held, hooks: hooks)
        XCTAssertEqual(outcome.failed, ["prepareme-daily.zim"])
        XCTAssertEqual(outcome.copied, [])
        XCTAssertEqual(try text("prepareme-daily.zim"), "daily")  // the older copy is still there and named
        XCTAssertEqual(try backedUp().files, [first, map])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".") }, "the bad copy was left: \(names)")
    }

    func testAFirstCopyThatFailsItsReadBackLeavesItOut() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        var hooks = Backup.Hooks()
        hooks.beforeSwap = { _, copy in try? Data("x".utf8).write(to: copy) }
        XCTAssertEqual(try back(up: manifest([daily]), held, hooks: hooks).failed, ["prepareme-daily.zim"])
        XCTAssertEqual(try backedUp().files, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("prepareme-daily.zim").path))
    }

    func testTheOlderDailyFileIsKeptAndNoOtherKind() throws {
        var held: [String: HeldFile] = [:]
        _ = try hold("daily one", into: &held)
        _ = try hold("map one", name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", into: &held)
        try back(up: manifest(held.values.map(\.entry).sorted { $0.name < $1.name }), held)
        let daily = try hold("daily two", into: &held)
        let map = try hold("map two", name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", into: &held)
        let plan = Backup.plan(delivery: manifest([daily, map]), held: held,
                               backup: Backup.readMirror(mirror, folder: folder), present: Backup.present(in: folder))
        XCTAssertEqual(plan.keepOlder, ["prepareme-daily.zim"])
        try Backup.run(plan, source: source, folder: folder, mirror: mirror, writtenAt: "2026-10-17T14:00:00-04:00")
        let older = folder.appendingPathComponent(Backup.olderFolder)
        XCTAssertEqual(try text("prepareme-daily.zim", in: older), "daily one")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: older.path), ["prepareme-daily.zim"])
        XCTAssertEqual(try text("prepareme-daily.zim"), "daily two")
        XCTAssertEqual(try text("prepareme-maps-roads.zim"), "map two")
        let daily3 = try hold("daily three", into: &held)
        try back(up: manifest([daily3, map]), held)
        XCTAssertEqual(try text("prepareme-daily.zim", in: older), "daily two")  // only the last one
    }

    func testAStopPartWayLeavesAManifestThatMatchesEveryFileItNames() throws {
        var held: [String: HeldFile] = [:]
        _ = try hold("daily one", into: &held)
        _ = try hold("map one", name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", into: &held)
        _ = try hold("topo one", name: "prepareme-maps-home-topo.zim", id: Self.ids[2], kind: "map-core", into: &held)
        try back(up: manifest(held.values.map(\.entry).sorted { $0.name < $1.name }), held)
        _ = try hold("daily two", into: &held)
        _ = try hold("map two", name: "prepareme-maps-roads.zim", id: Self.ids[1], kind: "map-core", into: &held)
        struct Stopped: Error {}
        var hooks = Backup.Hooks()
        hooks.afterCopy = { _ in throw Stopped() }  // the power goes after the first copy lands
        XCTAssertThrowsError(try back(up: manifest(held.values.map(\.entry).sorted { $0.name < $1.name }), held,
                                      hooks: hooks))
        let named = try backedUp()
        XCTAssertFalse(named.files.isEmpty)
        for entry in named.files {
            XCTAssertEqual(try FileCheck.verify(folder.appendingPathComponent(entry.name), size: entry.size,
                                                sha256: entry.sha256), .ok, entry.name)
        }
        XCTAssertEqual(named.files.map(\.name), ["prepareme-maps-home-topo.zim"])  // the two changing were dropped
        // and the next round puts it right
        let outcome = try back(up: manifest(held.values.map(\.entry).sorted { $0.name < $1.name }), held)
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(try backedUp().files.count, 3)
    }

    func testNoFolderWritesNothing() throws {
        try FileManager.default.removeItem(at: folder)
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        XCTAssertThrowsError(try back(up: manifest([daily]), held)) { error in
            XCTAssertEqual(error as? Backup.Problem, .noFolder)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.path))
    }

    func testAFileThatIsntOursIsLeftAloneButOurOwnLeftoversGo() throws {
        try Data("the owner's".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try Data("left".utf8).write(to: folder.appendingPathComponent(".backup-prepareme-daily.zim-1234"))
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        try back(up: manifest([daily]), held)
        XCTAssertEqual(try text("notes.txt"), "the owner's")
        let leftover = folder.appendingPathComponent(".backup-prepareme-daily.zim-1234")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    func testTheReadMeIsWrittenWholeWhenAsked() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let plan = Backup.plan(delivery: manifest([daily]), held: held, backup: nil, present: [:])
        try Backup.run(plan, source: source, folder: folder, mirror: mirror, writtenAt: "2026-10-17T13:00:00-04:00",
                       readMe: true)
        XCTAssertEqual(try text(Backup.readMeName), Backup.readMe)
        XCTAssertTrue(Backup.readMe.contains("exFAT"))
        XCTAssertTrue(Backup.readMe.contains("FAT32"))
    }

    func testTheReadMeLeadsWithAddFromFilesForALostMac() {
        let text = Backup.readMe
        let heading = text.range(of: "if the mac is lost or broken", options: .caseInsensitive)!.lowerBound
        let drive = text.range(of: "COPY IT TO A USB-C DRIVE")!.lowerBound
        XCTAssertLessThan(heading, drive)
        let section = String(text[heading..<drive])
        XCTAssertTrue(section.contains("Downloads \u{203A} Away from the Mac \u{203A} Add from Files"))
        XCTAssertTrue(section.contains("asks first"))
        XCTAssertTrue(section.contains("only from a folder its Mac signed"), "a child's phone (family downloads, phase 2)")
        XCTAssertFalse(text.contains("leave these files alone"))
        XCTAssertTrue(text.contains("The household's USB backup drive gets this copy by itself"))  // offline fixes, 5.1
        XCTAssertLessThan(heading, text.range(of: "App Store")!.lowerBound)
    }

    func testTheCopyIsAClonedFileOfItsOwn() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        try back(up: manifest([daily]), held)
        var a = stat(), b = stat()
        stat(source.appendingPathComponent(held["prepareme-daily.zim"]!.file).path, &a)
        stat(folder.appendingPathComponent("prepareme-daily.zim").path, &b)
        XCTAssertNotEqual(a.st_ino, b.st_ino)  // a file of its own, so a swap in the library never touches it
    }

    // MARK: The phones' inventory copy (beta run 2, B2-04, choice a)

    /// A made-up phones' copy with one rally point, as the Mac app writes it (sorted keys)
    func phoneCopy(writtenAt: String = "2026-10-20T16:00:00Z", rally: String = "Corner of the park") throws -> Data {
        let copy = PhoneInventory(writtenAt: writtenAt, columns: [], items: [], places: [], categories: [],
                                  headsUpDays: 30, toBuy: [], results: [:],
                                  marks: [MapMark(id: 1, kind: .rally, name: rally, points: [[-77.03, 38.89]])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(copy)
    }

    /// The map pins plan, Task 1.2: the Mac's copy for the phones, so the backup's, holds no Start point.
    @MainActor
    func testTheBackupsPhoneCopyHoldsNoStartPoint() async throws {
        let url = folder.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        let editor = try InventoryEditor(file: try InventoryFile(url: url), checker: FakeCheck())
        _ = try await editor.apply(.addMark(MapMark(kind: .start, name: "End of the lane", points: [[-40.5, 10.5]])))
        _ = try await editor.apply(.addMark(MapMark(kind: .rally, name: "Big oak", points: [[-40.1, 10.9]])))
        XCTAssertEqual(editor.inventory.marks.count, 2)
        let data = try JSONEncoder().encode(PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:]))
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        XCTAssertTrue(try back(up: manifest([daily]), held, inventory: data).inventoryCopied)
        let backedUp = try Data(contentsOf: folder.appendingPathComponent(PhoneInventory.fileName))
        let copy = try JSONDecoder().decode(PhoneInventory.self, from: backedUp)
        XCTAssertNil(copy.start)
        XCTAssertEqual(copy.mapMarks.map(\.kind), [.rally])
        XCTAssertFalse(String(decoding: backedUp, as: UTF8.self).contains("End of the lane"))
    }

    /// A backup round with the phones' copy `data` (nil: the Mac has none)
    @discardableResult
    func back(up delivery: Manifest, _ held: [String: HeldFile], inventory data: Data?,
              signer: (@Sendable (Manifest) throws -> Data)? = nil) throws -> Backup.Outcome {
        let plan = Backup.plan(delivery: delivery, held: held, backup: Backup.readMirror(mirror, folder: folder),
                               present: Backup.present(in: folder), inventory: Backup.inventorySource(data))
        return try Backup.run(plan, source: source, folder: folder, mirror: mirror,
                              writtenAt: "2026-10-20T13:00:00-04:00", signer: signer)
    }

    func testThePhonesCopyIsBackedUpAndNamedInTheSignedList() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let data = try phoneCopy()
        let key = P256.Signing.PrivateKey()
        let outcome = try back(up: manifest([daily]), held, inventory: data,
                               signer: { try BackupSignature.sign($0, with: key) })
        XCTAssertTrue(outcome.inventoryCopied)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(PhoneInventory.fileName)), data)
        let list = try BackupSignature.read(Data(contentsOf: folder.appendingPathComponent(Backup.manifestName)))
        XCTAssertEqual(list.verdict, .signed(key: BackupSignature.publicKey(of: key)))  // covered by the signature
        let named = try XCTUnwrap(list.manifest.inventory)
        XCTAssertEqual(named.name, PhoneInventory.fileName)
        XCTAssertEqual(named.size, Int64(data.count))
        XCTAssertEqual(named.sha256, Hex.string(SHA256.hash(data: data)))
        XCTAssertEqual(named.writtenAt, "2026-10-20T16:00:00Z")
        XCTAssertEqual(list.manifest.files, [daily])  // never among the library files, which older phones check
        XCTAssertEqual(list.manifest.format, FileFormat.current, "the backup's list says its format (audit P2h)")
        XCTAssertEqual(try Manifest.read(Data(contentsOf: mirror)).inventory, named)
        // the counts stay the library's
        XCTAssertEqual(outcome.wanted, 1)
        XCTAssertEqual(outcome.current, 1)
    }

    func testThePhonesCopyIsCopiedAgainOnlyWhenWhatItHoldsChangesOrADayOn() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        try back(up: manifest([daily]), held, inventory: try phoneCopy())
        func plan(_ data: Data) throws -> Backup.Plan {
            Backup.plan(delivery: manifest([daily]), held: held, backup: Backup.readMirror(mirror, folder: folder),
                        present: Backup.present(in: folder), inventory: Backup.inventorySource(data))
        }
        // the Mac writes its copy again every 10 minutes with only its time changed: no copy, no new list
        let later = try plan(try phoneCopy(writtenAt: "2026-10-20T16:10:00Z"))
        XCTAssertNil(later.inventoryCopy)
        XCTAssertFalse(later.isDue)
        // a rally point moved: copied
        let moved = try plan(try phoneCopy(writtenAt: "2026-10-20T16:20:00Z", rally: "Library steps"))
        XCTAssertNotNil(moved.inventoryCopy)
        XCTAssertTrue(moved.isDue)
        XCTAssertNil(moved.inventoryKept, "the list first stops naming the copy being replaced")
        XCTAssertTrue(moved.interimNeeded)
        // the same, a day on: copied, so the backup's copy says how recent it is
        let dayOn = try plan(try phoneCopy(writtenAt: "2026-10-21T16:00:00Z"))
        XCTAssertNotNil(dayOn.inventoryCopy)
    }

    func testWithoutTheMacsCopyTheBackupKeepsItsOwn() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let data = try phoneCopy()
        try back(up: manifest([daily]), held, inventory: data)
        let named = try XCTUnwrap(try backedUp().inventory)
        let outcome = try back(up: manifest([daily]), held, inventory: nil)  // the Mac's copy unreadable this look
        XCTAssertFalse(outcome.inventoryCopied)
        XCTAssertEqual(try backedUp().inventory, named)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(PhoneInventory.fileName)), data)
        XCTAssertEqual(outcome.removed, [])
        // and a backup that never had one names none
        try FileManager.default.removeItem(at: folder.appendingPathComponent(PhoneInventory.fileName))
        try back(up: manifest([daily]), held, inventory: nil)
        XCTAssertNil(try backedUp().inventory, "a copy no longer whole in the folder is never named")
    }

    /// The whole-plan review: a look every 30 seconds reads, decodes and hashes the phones' copy again only when its
    /// file's size or modification date changed since the last look.
    func testThePhonesCopyIsReadAgainOnlyWhenItsFileChanged() throws {
        let place = base.appendingPathComponent("inventory", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let file = place.appendingPathComponent(PhoneInventory.fileName)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func write(_ data: Data, _ when: Date) throws {
            try data.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: file.path)
        }
        let park = try phoneCopy(rally: "Corner of the park"), yard = try phoneCopy(rally: "Corner of the yard")
        XCTAssertEqual(park.count, yard.count)
        var cache = Backup.InventoryCache()
        XCTAssertNil(cache.source(in: place), "no copy yet")
        try write(park, at)
        XCTAssertEqual(cache.source(in: place), Backup.inventorySource(park))
        try write(yard, at)  // other bytes behind the same size and date: not read again
        XCTAssertEqual(cache.source(in: place), Backup.inventorySource(park))
        try FileManager.default.setAttributes([.modificationDate: at.addingTimeInterval(10)], ofItemAtPath: file.path)
        XCTAssertEqual(cache.source(in: place), Backup.inventorySource(yard), "a new date: read again")
        try write(park + Data(" ".utf8), at.addingTimeInterval(10))
        XCTAssertEqual(cache.source(in: place)?.data, park + Data(" ".utf8), "a new size: read again")
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(cache.source(in: place), "gone: none")
        try write(Data("not a copy".utf8), at)
        XCTAssertNil(cache.source(in: place), "a file that isn't a phones' copy: none, as before")
    }

    func testOnlyAPhonesCopyIsBackedUpNeverAMacOnlyColumn() throws {
        XCTAssertNil(Backup.inventorySource(nil))
        XCTAssertNil(Backup.inventorySource(Data("not json".utf8)))
        XCTAssertNil(Backup.inventorySource(Data("{}".utf8)))
        XCTAssertNotNil(Backup.inventorySource(try phoneCopy()))
        // a copy carrying a Mac-only column (planted, or a Mac app gone wrong) is never backed up
        // the shared list's every label, so a Mac-only column added to it later is refused here too
        for label in ["Mac only", "Serial number", "Purchased", "Price", "serial number"] + Inventory.macOnlyLabels {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try phoneCopy()) as? [String: Any])
            object["columns"] = [["colId": "C9", "label": label, "kind": "text", "choices": [String](),
                                  "editable": true] as [String: Any]]
            let planted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            XCTAssertNil(Backup.inventorySource(planted), label)
        }
    }

    func testAPhonesCopyThatFailsItsReadBackIsNeverNamedAndTheOlderOneStays() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let first = try phoneCopy()
        try back(up: manifest([daily]), held, inventory: first)
        let named = try backedUp().inventory
        var hooks = Backup.Hooks()
        hooks.beforeInventorySwap = { temporary in try? Data("spoiled".utf8).write(to: temporary) }
        let plan = Backup.plan(delivery: manifest([daily]), held: held,
                               backup: Backup.readMirror(mirror, folder: folder), present: Backup.present(in: folder),
                               inventory: Backup.inventorySource(try phoneCopy(rally: "Library steps")))
        let outcome = try Backup.run(plan, source: source, folder: folder, mirror: mirror,
                                     writtenAt: "2026-10-20T14:00:00-04:00", hooks: hooks)
        XCTAssertEqual(outcome.failed, [PhoneInventory.fileName])
        XCTAssertFalse(outcome.inventoryCopied)
        XCTAssertEqual(try backedUp().inventory, named)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(PhoneInventory.fileName)), first)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".") })
    }

    /// A failed write of the phones' copy is held off like a library file (checkpoint 1): not tried again for an hour
    /// while what it holds is unchanged (the Mac rewrites it every 10 minutes with only its time changed), still said
    /// as a failure until it lands; Back up now (`force`) tries it at once, and a real change is tried at once
    func testAFailedPhonesCopyIsHeldOffLikeAFileAndStillCountsAsStuck() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        try back(up: manifest([daily]), held, inventory: try phoneCopy())
        let moved = try XCTUnwrap(Backup.inventorySource(try phoneCopy(writtenAt: "2026-10-20T16:20:00Z",
                                                                       rally: "Library steps")))
        // the write failed: its key is recorded as the app's failures map records it
        let failed = [PhoneInventory.fileName: Backup.failureKey(moved.entry)]
        // the Mac's next rewrite, only its time changed: still held off
        let rewritten = try XCTUnwrap(Backup.inventorySource(try phoneCopy(writtenAt: "2026-10-20T16:30:00Z",
                                                                           rally: "Library steps")))
        let delivery = manifest([daily])
        let holdOff = Backup.holdOff(delivery: delivery, inventory: rewritten.entry, failed: failed, force: false)
        XCTAssertEqual(holdOff, [PhoneInventory.fileName])
        let plan = Backup.plan(delivery: delivery, held: held, backup: Backup.readMirror(mirror, folder: folder),
                               present: Backup.present(in: folder), holdOff: holdOff, inventory: rewritten)
        XCTAssertNil(plan.inventoryCopy, "held off: not written again")
        XCTAssertFalse(plan.isDue)
        XCTAssertNotNil(plan.inventoryKept, "the backup's older copy stays named")
        XCTAssertEqual(Backup.stuck(holdOff, plan: plan, inventory: rewritten.entry), [PhoneInventory.fileName])
        // Back up now tries it at once
        XCTAssertEqual(Backup.holdOff(delivery: delivery, inventory: rewritten.entry, failed: failed, force: true), [])
        // what it holds changed again: tried at once
        let again = try XCTUnwrap(Backup.inventorySource(try phoneCopy(writtenAt: "2026-10-20T16:40:00Z",
                                                                       rally: "Big oak")))
        XCTAssertEqual(Backup.holdOff(delivery: delivery, inventory: again.entry, failed: failed, force: false), [])
        // a library file's hold-off is by its SHA-256, as before
        let fileFailed = ["prepareme-daily.zim": daily.sha256]
        XCTAssertEqual(Backup.holdOff(delivery: delivery, inventory: nil, failed: fileFailed, force: false),
                       ["prepareme-daily.zim"])
        XCTAssertEqual(Backup.failureKey(daily), daily.sha256)
    }

    /// The space check counts the phones' copy's bytes with the files' (checkpoint 1)
    func testTheSpaceCheckCountsThePhonesCopy() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        try back(up: manifest([daily]), held)
        let source = try XCTUnwrap(Backup.inventorySource(try phoneCopy()))
        let plan = Backup.plan(delivery: manifest([daily]), held: held,
                               backup: Backup.readMirror(mirror, folder: folder), present: Backup.present(in: folder),
                               inventory: source)
        XCTAssertEqual(plan.copies, [])
        XCTAssertNotNil(plan.inventoryCopy)
        XCTAssertEqual(plan.bytes, source.entry.size)
        XCTAssertEqual(Backup.room(bytes: plan.bytes, free: Backup.margin + source.entry.size - 1)?.need,
                       Backup.margin + source.entry.size)
    }

    /// Review focus 4: a list from before this change (no inventory) still reads, and a list with one still reads, its
    /// signature holding, on a phone from before this change
    func testListsBeforeAndAfterTheInventoryReadOnEitherPhone() throws {
        let before = """
            {"files": [{"delivered_at": "2026-10-18T12:00:00-04:00", "id": "\(Self.ids[0])", "kind": "library",
            "name": "prepareme-daily.zim", "sha256": "\(String(repeating: "a", count: 64))", "size": 5}],
            "written_at": "2026-10-18T13:00:00-04:00"}
            """
        XCTAssertNil(try Manifest.read(Data(before.utf8)).inventory)
        // the new list, read the way a phone from before this change reads it: a Manifest without `inventory`
        struct Older: Decodable, Equatable {
            var written_at: String
            var files: [Manifest.Entry]
            var backup_key: String?
        }
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        let key = P256.Signing.PrivateKey()
        try back(up: manifest([daily]), held, inventory: try phoneCopy(),
                 signer: { try BackupSignature.sign($0, with: key) })
        let data = try Data(contentsOf: folder.appendingPathComponent(Backup.manifestName))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["signed"] as? String)))
        let top = try JSONDecoder().decode(Older.self, from: data)
        XCTAssertEqual(top, try JSONDecoder().decode(Older.self, from: body))
        XCTAssertEqual(top.files.map(\.kind), ["library"])  // every entry a kind an older phone knows
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["signature"] as? String))))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: body))
    }

    func testAListWithABadInventoryEntryIsRefused() throws {
        let sha = String(repeating: "a", count: 64)
        for inventory in [
            Manifest.Inventory(name: "../phone-inventory.json", size: 5, sha256: sha, writtenAt: "x"),
            Manifest.Inventory(name: "prepareme-daily.zim", size: 5, sha256: sha, writtenAt: "x"),
            Manifest.Inventory(name: PhoneInventory.fileName, size: -1, sha256: sha, writtenAt: "x"),
            Manifest.Inventory(name: PhoneInventory.fileName, size: 5, sha256: "nope", writtenAt: "x"),
        ] {
            let list = Manifest(writtenAt: "x", files: [], inventory: inventory)
            XCTAssertThrowsError(try Manifest.read(try list.encoded()), inventory.name)
        }
    }

    func testTheReadMeSaysAPhoneSetUpFromItGetsTheMeetingPlacesAndTheInventory() {
        let text = Backup.readMe
        let heading = text.range(of: "IF THE MAC IS LOST OR BROKEN")!.upperBound
        let section = String(text[heading..<text.range(of: "COPY IT TO A USB-C DRIVE")!.lowerBound])
        XCTAssertTrue(section.contains("meeting places"))
        XCTAssertFalse(text.lowercased().contains("rally"), "the map pins plan: a person reads meeting place")
        XCTAssertTrue(section.contains("inventory"))
        XCTAssertTrue(section.contains("read only"))
        // a hurried drive refresh takes the inventory copy too, so the list never names one the drive lacks
        let hurry = String(text[text.range(of: "In a hurry")!.lowerBound..<text.range(of: "(choose Replace)")!.lowerBound])
        for name in ["prepareme-daily.zim", PhoneInventory.fileName, Backup.manifestName] {
            XCTAssertTrue(hurry.contains(name), name)
        }
    }

    // MARK: The status record

    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/backup-status.json")

    func testTheRecordsShapeIsTheSharedFixtures() throws {
        let status = try JSONDecoder().decode(BackupStatus.self, from: Data(contentsOf: Self.fixture))
        XCTAssertEqual(status.checkedAt, "2026-10-17T21:00:00-04:00")
        XCTAssertEqual(status.currentAt, "2026-10-14T09:30:00-04:00")
        XCTAssertEqual(status.behindDays, ["2026-10-15", "2026-10-16", "2026-10-17"])
        XCTAssertEqual(status.problem, "copy-failed")
        let again = try JSONSerialization.jsonObject(with: status.encoded()) as? NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? NSDictionary
        XCTAssertEqual(again, fixture)
    }

    static let uploadFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/backup-status-upload-failed.json")

    /// Phase K's drills, finding 1: the record of a backup iCloud won't upload, the case the notice's tests read too
    func testTheUploadFailedRecordIsTheSharedFixtures() throws {
        let status = try JSONDecoder().decode(BackupStatus.self, from: Data(contentsOf: Self.uploadFixture))
        XCTAssertEqual(status.problem, BackupStatus.uploadFailed)
        XCTAssertEqual(status.failed, 4)
        XCTAssertEqual(status.uploads, 4)
        XCTAssertEqual(status.behindDays.count, BackupWords.behindDays)
        let again = try JSONSerialization.jsonObject(with: status.encoded()) as? NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.uploadFixture)) as? NSDictionary
        XCTAssertEqual(again, fixture)
        let line = "Not backed up to iCloud: 4 of 4 files can't upload (iCloud may be full). This Mac's copy is up to "
            + "date."
        XCTAssertEqual(BackupWords.line(status, upload: nil, now: date("2026-10-17T22:00:00-04:00")), line)
        XCTAssertEqual(BackupWords.attention(status, upload: nil), line)  // behind 3 awake days: the sidebar too
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testDaysBehindCountEachAwakeDayOnceAndClearWhenCurrent() {
        var status = BackupStatus()
        status = status.updated(at: date("2026-10-15T08:00:00-04:00"), behind: true, calendar: Self.calendar)
        status = status.updated(at: date("2026-10-15T20:00:00-04:00"), behind: true, calendar: Self.calendar)
        status = status.updated(at: date("2026-10-17T07:00:00-04:00"), behind: true, calendar: Self.calendar)
        XCTAssertEqual(status.behindDays, ["2026-10-15", "2026-10-17"])  // the 16th the Mac slept
        XCTAssertNil(status.currentAt)
        status = status.updated(at: date("2026-10-17T07:05:00-04:00"), behind: false, ran: true,
                                calendar: Self.calendar)
        XCTAssertEqual(status.behindDays, [])
        XCTAssertEqual(status.currentAt, "2026-10-17T07:05:00-04:00")
        XCTAssertEqual(status.checkedAt, "2026-10-17T07:05:00-04:00")
        status = status.updated(at: date("2026-10-17T09:00:00-04:00"), behind: false, calendar: Self.calendar)
        XCTAssertEqual(status.currentAt, "2026-10-17T07:05:00-04:00")  // still when the last backup finished
        XCTAssertEqual(status.checkedAt, "2026-10-17T09:00:00-04:00")
    }

    func testTheRecordIsWrittenOnAChangeOrHourly() {
        let old = BackupStatus().updated(at: date("2026-10-17T07:00:00-04:00"), behind: false, calendar: Self.calendar)
        let same = old.updated(at: date("2026-10-17T07:30:00-04:00"), behind: false, calendar: Self.calendar)
        XCTAssertFalse(same.worthWriting(over: old))
        let hour = old.updated(at: date("2026-10-17T08:00:01-04:00"), behind: false, calendar: Self.calendar)
        XCTAssertTrue(hour.worthWriting(over: old))
        var problem = same
        problem.problem = BackupStatus.noFolder
        XCTAssertTrue(problem.worthWriting(over: old))
        XCTAssertTrue(same.worthWriting(over: nil))
    }

    // MARK: The words

    func testTheStatusLines() {
        let now = date("2026-10-17T15:00:00-04:00")
        var status = BackupStatus().updated(at: date("2026-10-17T12:00:00-04:00"), behind: false,
                                            calendar: Self.calendar)
        status.current = 28
        status.wanted = 28
        XCTAssertEqual(BackupWords.line(status, upload: .init(pending: 0, failed: 0, inICloud: true), now: now),
                       "Backed up to iCloud 3 hours ago: 28 of 28 files, all uploaded")
        XCTAssertEqual(BackupWords.line(status, upload: .init(pending: 2, failed: 0, inICloud: true), now: now),
                       "Backed up to iCloud 3 hours ago: 28 of 28 files, 2 still uploading to iCloud")
        XCTAssertEqual(BackupWords.line(status, upload: .init(pending: 0, failed: 0, inICloud: false), now: now),
                       "Backed up 3 hours ago: 28 of 28 files (a test folder, not iCloud)")
        XCTAssertEqual(BackupWords.uploadProblem(.init(pending: 0, failed: 1, inICloud: true)),
                       "1 file can't upload to iCloud: System Settings › your name › iCloud says why.")
        XCTAssertNil(BackupWords.uploadProblem(.init(pending: 3, failed: 0, inICloud: true)))
        XCTAssertEqual(BackupWords.copying(done: 1, total: 5), "Backing up to iCloud: 2 of 5 changed files")
        status.problem = BackupStatus.noFolder
        XCTAssertEqual(BackupWords.line(status, upload: nil, now: now),
                       "Not backed up: there's no PrepareMe Backup folder in iCloud Drive. Make one in Finder "
                       + "(iCloud Drive, then File › New Folder), then press Back up to iCloud now.")
        status.problem = BackupStatus.noRoom
        status.need = 76_000_000_000
        status.free = 40_000_000_000
        XCTAssertEqual(BackupWords.line(status, upload: nil, now: now),
                       "Not backed up: this Mac needs 76.0 GB free for it and has 40.0 GB.")
        status.problem = BackupStatus.copyFailed
        status.failed = 1
        XCTAssertEqual(BackupWords.line(status, upload: nil, now: now),
                       "Not backed up: 1 file couldn't be copied; it is tried again at the next check.")
        status.failed = 2
        XCTAssertEqual(BackupWords.line(status, upload: nil, now: now),
                       "Not backed up: 2 files couldn't be copied; they are tried again at the next check.")
        XCTAssertNil(BackupWords.line(nil, upload: nil, now: now))
    }

    func testAgoWords() {
        let now = date("2026-10-17T15:00:00-04:00")
        XCTAssertEqual(BackupWords.ago(date("2026-10-17T14:59:30-04:00"), now: now), "just now")
        XCTAssertEqual(BackupWords.ago(date("2026-10-17T14:59:00-04:00"), now: now), "1 minute ago")
        XCTAssertEqual(BackupWords.ago(date("2026-10-17T14:15:00-04:00"), now: now), "45 minutes ago")
        XCTAssertEqual(BackupWords.ago(date("2026-10-17T14:00:00-04:00"), now: now), "1 hour ago")
        XCTAssertEqual(BackupWords.ago(date("2026-10-16T14:00:00-04:00"), now: now), "1 day ago")
        XCTAssertEqual(BackupWords.ago(date("2026-10-14T14:00:00-04:00"), now: now), "3 days ago")
    }

    func testTheAttentionLineOnlyWhenTheOwnerMustAct() {
        var status = BackupStatus().updated(at: date("2026-10-17T12:00:00-04:00"), behind: false,
                                            calendar: Self.calendar)
        XCTAssertNil(BackupWords.attention(status, upload: nil))
        status.problem = BackupStatus.copyFailed
        status.failed = 1
        XCTAssertNil(BackupWords.attention(status, upload: nil))  // tried again in 30 seconds: not yet
        status.behindDays = ["2026-10-15", "2026-10-16", "2026-10-17"]
        XCTAssertEqual(BackupWords.attention(status, upload: nil),
                       "Not backed up: 1 file couldn't be copied; it is tried again at the next check.")
        status.behindDays = []
        status.problem = BackupStatus.noFolder
        XCTAssertNotNil(BackupWords.attention(status, upload: nil))
        status.problem = BackupStatus.noRoom
        XCTAssertNotNil(BackupWords.attention(status, upload: nil))
        status.problem = nil
        XCTAssertEqual(BackupWords.attention(status, upload: .init(pending: 0, failed: 2, inICloud: true)),
                       "2 files can't upload to iCloud: System Settings › your name › iCloud says why.")
    }

    /// Cloud review, 1: a folder that stats but won't open (as macOS's privacy check leaves iCloud Drive after Don't
    /// Allow) is refused, never taken for an empty folder
    func testAFolderThatStatsButWontOpenIsRefusedNotEmpty() throws {
        var held: [String: HeldFile] = [:]
        let daily = try hold("daily", into: &held)
        try back(up: manifest([daily]), held)
        XCTAssertEqual(chmod(folder.path, 0o000), 0)
        defer { chmod(folder.path, 0o755) }
        XCTAssertEqual(Backup.access(folder), .refused)
        XCTAssertThrowsError(try Backup.listing(in: folder))
        var status = BackupStatus()
        status.checkedAt = "2026-10-17T12:00:00-04:00"
        status.problem = BackupStatus.unreadable
        XCTAssertEqual(BackupWords.line(status, upload: nil, now: Date()),
                       "Not backed up: the PrepareMe Backup folder couldn't be read; it is tried again at the next check.")
    }

    func testAccessFromAStat() throws {
        XCTAssertEqual(Backup.access(folder), .ok)
        XCTAssertEqual(Backup.access(base.appendingPathComponent("not there")), .noFolder)
        let file = base.appendingPathComponent("a file")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(Backup.access(file), .noFolder)
        var status = BackupStatus()
        status.checkedAt = "2026-10-17T12:00:00-04:00"
        status.problem = BackupStatus.noAccess
        XCTAssertEqual(BackupWords.attention(status, upload: nil),
                       "Not backed up: macOS hasn't let PrepareMe into iCloud Drive. Allow it in System Settings › "
                       + "Privacy & Security › Files & Folders, under PrepareMe, then press Back up to iCloud now.")
    }

    // MARK: Upload state

    /// Phase K's drills, finding 1: four files iCloud won't upload make a copied backup not current, said first, and
    /// behind like any other failure, so the notice speaks after 3 awake days
    func testUploadsICloudWontTakeAreNotBackedUp() {
        let now = date("2026-10-17T15:00:00-04:00")
        var status = BackupStatus().updated(at: date("2026-10-14T12:00:00-04:00"), behind: false,
                                            calendar: Self.calendar)
        status.current = 3
        status.wanted = 3
        let refused = Backup.Upload(pending: 0, failed: 4, inICloud: true, total: 4)
        for day in ["2026-10-15T09:00:00-04:00", "2026-10-16T09:00:00-04:00", "2026-10-17T09:00:00-04:00"] {
            var next = status
            XCTAssertTrue(next.take(refused))
            status = next.updated(at: date(day), behind: true, calendar: Self.calendar)
        }
        XCTAssertEqual(status.problem, BackupStatus.uploadFailed)
        XCTAssertEqual(status.failed, 4)
        XCTAssertEqual(status.uploads, 4)
        XCTAssertEqual(status.currentAt, "2026-10-14T12:00:00-04:00")  // not current since
        XCTAssertEqual(status.behindDays, ["2026-10-15", "2026-10-16", "2026-10-17"])
        let line = "Not backed up to iCloud: 4 of 4 files can't upload (iCloud may be full). This Mac's copy is up to "
            + "date."
        XCTAssertEqual(BackupWords.line(status, upload: refused, now: now), line)
        XCTAssertEqual(BackupWords.attention(status, upload: refused), line)
        // one of four, and the uploads going again: current at once
        var one = BackupStatus().updated(at: now, behind: false, calendar: Self.calendar)
        XCTAssertTrue(one.take(.init(pending: 1, failed: 1, inICloud: true, total: 4)))
        XCTAssertEqual(BackupWords.line(one, upload: nil, now: now),
                       "Not backed up to iCloud: 1 of 4 files can't upload (iCloud may be full). This Mac's copy is up "
                       + "to date.")
        XCTAssertFalse(one.take(.init(pending: 0, failed: 0, inICloud: true, total: 4)))
        XCTAssertNil(one.problem)
        XCTAssertNil(one.failed)
        XCTAssertNil(one.uploads)
        // review: files still waiting on the Mac, so its copy is never said to be up to date
        var short = BackupStatus().updated(at: now, behind: false, calendar: Self.calendar)
        (short.current, short.wanted) = (26, 28)
        XCTAssertTrue(short.take(.init(pending: 0, failed: 3, inICloud: true, total: 27)))
        XCTAssertEqual(BackupWords.line(short, upload: nil, now: now),
                       "Not backed up to iCloud: 3 of 27 files can't upload (iCloud may be full).")
    }

    /// Phase K's drills' first likeliest failure: a slow upload is never called a failure
    func testPendingUploadsAloneStayStillUploading() {
        let now = date("2026-10-17T15:00:00-04:00")
        var status = BackupStatus().updated(at: date("2026-10-17T12:00:00-04:00"), behind: false,
                                            calendar: Self.calendar)
        status.current = 28
        status.wanted = 28
        let pending = Backup.Upload(pending: 28, failed: 0, inICloud: true, total: 29)
        XCTAssertFalse(status.take(pending))
        XCTAssertNil(status.problem)
        XCTAssertEqual(BackupWords.line(status, upload: pending, now: now),
                       "Backed up to iCloud 3 hours ago: 28 of 28 files, 28 still uploading to iCloud")
        // a test folder iCloud doesn't hold never fails an upload
        XCTAssertFalse(status.take(.init(pending: 0, failed: 2, inICloud: false, total: 2)))
        XCTAssertNil(status.problem)
    }

    /// Offline fixes, phase 2: files iCloud hasn't uploaded at any look for two days count as behind
    func testUploadsPendingForTwoDaysCountAsBehind() {
        let start = date("2026-10-15T09:00:00-04:00")
        var status = BackupStatus().updated(at: start, behind: false, ran: true, calendar: Self.calendar)
        let pending = Backup.Upload(pending: 3, failed: 0, inICloud: true, total: 29)
        XCTAssertFalse(status.take(pending, now: start))
        XCTAssertNotNil(status.uploadingSince)
        XCTAssertFalse(status.take(pending, now: start.addingTimeInterval(86400)))
        let later = start.addingTimeInterval(2 * 86400)
        XCTAssertTrue(status.take(pending, now: later))
        XCTAssertTrue(status.take(nil, now: later))  // no state read this time: it stands
        XCTAssertNil(status.problem)
        status.current = 28
        status.wanted = 28
        status = status.updated(at: later, behind: true, calendar: Self.calendar)
        let line = BackupWords.line(status, upload: pending, now: later) ?? ""
        XCTAssertTrue(line.contains(", 3 still uploading to iCloud since "), line)
        XCTAssertTrue(line.hasSuffix(": iCloud may be stuck; look at the PrepareMe Backup folder in Finder"), line)
    }

    func testUploadsPendingForADayDont() {
        let start = date("2026-10-15T09:00:00-04:00")
        var status = BackupStatus()
        let pending = Backup.Upload(pending: 3, failed: 0, inICloud: true, total: 29)
        XCTAssertFalse(status.take(pending, now: start))
        XCTAssertFalse(status.take(pending, now: start.addingTimeInterval(47 * 3600)))
        XCTAssertFalse(status.take(.init(pending: 3, failed: 0, inICloud: false, total: 0), now: start))
        XCTAssertNil(status.uploadingSince)  // a folder iCloud doesn't hold never waits on iCloud
    }

    func testUploadingSinceClearsAtZero() {
        let start = date("2026-10-15T09:00:00-04:00")
        var status = BackupStatus()
        XCTAssertFalse(status.take(.init(pending: 3, failed: 0, inICloud: true, total: 29), now: start))
        XCTAssertFalse(status.take(.init(pending: 0, failed: 0, inICloud: true, total: 29),
                                   now: start.addingTimeInterval(86400)))
        XCTAssertNil(status.uploadingSince)
        XCTAssertFalse(status.take(.init(pending: 1, failed: 0, inICloud: true, total: 29),
                                   now: start.addingTimeInterval(2 * 86400)))  // counting starts again
        let saved = BackupStatus.read(try? status.encoded())
        XCTAssertEqual(saved?.uploadingSince, status.uploadingSince)
        XCTAssertTrue(String(decoding: (try? status.encoded()) ?? Data(), as: UTF8.self).contains("uploading_since"))
    }

    /// Another problem leads; a standing upload problem stands while no upload state was read this time
    func testUploadStateNeverHidesAnotherProblem() {
        var status = BackupStatus()
        status.problem = BackupStatus.copyFailed
        status.failed = 1
        XCTAssertFalse(status.take(.init(pending: 0, failed: 4, inICloud: true, total: 4)))
        XCTAssertEqual(status.problem, BackupStatus.copyFailed)
        XCTAssertEqual(status.failed, 1)
        status.problem = nil
        status.failed = nil
        XCTAssertTrue(status.take(.init(pending: 0, failed: 2, inICloud: true, total: 5)))
        XCTAssertTrue(status.take(nil))
        XCTAssertEqual(status.problem, BackupStatus.uploadFailed)
        XCTAssertEqual(status.failed, 2)
    }


    func testAFolderOutsideICloudSaysSo() throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.zim"))
        XCTAssertEqual(Backup.upload(of: ["a.zim"], in: folder), .init(pending: 0, failed: 0, inICloud: false))
    }
}
