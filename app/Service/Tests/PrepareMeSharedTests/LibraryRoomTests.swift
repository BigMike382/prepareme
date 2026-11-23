import Foundation
import PrepareMeShared
import XCTest

/// Phase M (owner, 2026-10-18; docs/plans/2026-10-18-phase-m-storage-aware-downloads.md): a phone takes its base
/// always, then the maps by room in the owner's order while it keeps its reserve (10 GB whatever its size since
/// 2026-11-15), updates first; Always and Never per phone come from the Mac. Made-up lists and sizes only.
final class LibraryRoomTests: XCTestCase {
    static let gb: Int64 = 1_000_000_000

    func entry(_ name: String, fetch: String? = nil, order: Int? = nil, size: Int64 = 1 * gb, sha: Character = "a",
               kind: String = "map-optional", family: Bool? = nil) -> Manifest.Entry {
        Manifest.Entry(name: name, id: UUID().uuidString, kind: kind, size: size,
                       sha256: String(repeating: sha, count: 64), deliveredAt: "2026-10-18T12:00:00-04:00",
                       family: family, fetch: fetch, order: order)
    }

    var list: [Manifest.Entry] {
        [entry("prepareme-daily.zim", fetch: "base", size: 1_000_000, kind: "library"),
         entry("prepareme-street-map.pmtiles", fetch: "base", size: 2 * Self.gb, kind: "map"),
         entry("prepareme-maps-home-topo.zim", fetch: "base", size: 3 * Self.gb, kind: "map-core"),
         entry("prepareme-maps-roads.zim", fetch: "room", order: 1, size: 1 * Self.gb, kind: "map-core"),
         entry("prepareme-maps-routes.zim", fetch: "room", order: 3, size: 2 * Self.gb, kind: "map-core"),
         entry("prepareme-maps-topo-today-4.zim", fetch: "room", order: 101, size: 5 * Self.gb),
         entry("prepareme-maps-topo-today-3.zim", fetch: "room", order: 102, size: 1 * Self.gb),
         entry("family.zim", size: 1 * Self.gb, kind: "download", family: true)]
    }

    func names(_ free: Int64, capacity: Int64 = 64 * gb, record: LibraryRecord = LibraryRecord(),
               choices: [String: String]? = nil) -> [String] {
        var manifest = Manifest(writtenAt: "x", files: list)
        manifest.choices = choices
        var record = record
        record.manifest = manifest  // as LibraryStore.read keeps it before any download is planned
        return LibraryPlan.toFetch(manifest, record, room: LibraryPlan.Room(free: free, capacity: capacity)).map(\.name)
    }

    func testTheReserveIsTenGigabytesWhateverTheDevice() {
        XCTAssertEqual(LibraryPlan.reserve(capacity: 32 * Self.gb), 10 * Self.gb)
        XCTAssertEqual(LibraryPlan.reserve(capacity: 256 * Self.gb), 10 * Self.gb)
        XCTAssertEqual(LibraryPlan.reserve(capacity: 1_000 * Self.gb), 10 * Self.gb)
    }

    func testTheBaseAlwaysThenRoomFilesInOrderWhileTheReserveHolds() {
        // 64 GB phone: reserve 10 GB. 21 GB free: the base's 5 GB leaves 6 GB above the reserve: roads (1) and
        // routes (2) fit, today-4 (5) doesn't, and the order is strict: today-3 (1) waits behind it
        XCTAssertEqual(names(21 * Self.gb), ["prepareme-daily.zim", "prepareme-street-map.pmtiles",
                                             "prepareme-maps-home-topo.zim", "prepareme-maps-roads.zim",
                                             "prepareme-maps-routes.zim"])
        // plenty of room: everything by room, in order; never the download nobody asked for
        XCTAssertEqual(names(60 * Self.gb).suffix(4), ["prepareme-maps-roads.zim", "prepareme-maps-routes.zim",
                                                        "prepareme-maps-topo-today-4.zim",
                                                        "prepareme-maps-topo-today-3.zim"])
        XCTAssertFalse(names(60 * Self.gb).contains("family.zim"))
        // under the reserve: the base still comes, nothing by room
        XCTAssertEqual(names(8 * Self.gb), ["prepareme-daily.zim", "prepareme-street-map.pmtiles",
                                            "prepareme-maps-home-topo.zim"])
    }

    func testAHeldFileIsKeptCurrentEvenBelowTheReserveAndBeforeNewFiles() {
        var record = LibraryRecord()
        for name in ["prepareme-daily.zim", "prepareme-street-map.pmtiles", "prepareme-maps-home-topo.zim"] {
            let current = list.first { $0.name == name }!
            record.held[name] = HeldFile(entry: current, file: name)
        }
        var old = entry("prepareme-maps-topo-today-3.zim", fetch: "room", order: 102, size: 1 * Self.gb, sha: "b")
        old.deliveredAt = "2026-10-01T12:00:00-04:00"
        record.held[old.name] = HeldFile(entry: old, file: "today-3-old")
        XCTAssertEqual(names(3 * Self.gb, record: record), ["prepareme-maps-topo-today-3.zim"])
        XCTAssertEqual(names(40 * Self.gb, record: record).first, "prepareme-maps-topo-today-3.zim")
    }

    func testAlwaysAndNeverFromTheMac() {
        let choices = ["prepareme-maps-topo-today-3.zim": "always", "prepareme-maps-roads.zim": "never",
                       "family.zim": "always"]
        // under the reserve, above the floor (family downloads plan, phase 4): 14 GB less the 5 GB base leaves 9 GB
        let taken = names(14 * Self.gb, choices: choices)
        XCTAssertTrue(taken.contains("prepareme-maps-topo-today-3.zim"))
        XCTAssertTrue(taken.contains("family.zim"))
        XCTAssertFalse(names(60 * Self.gb, choices: choices).contains("prepareme-maps-roads.zim"))
        // Never on a base file is ignored: the phone keeps its library
        XCTAssertTrue(names(8 * Self.gb, choices: ["prepareme-daily.zim": "never"]).contains("prepareme-daily.zim"))
    }

    func testARemovedFileStaysRemovedAndAnAskedForOneComes() {
        var record = LibraryRecord()
        record.declined = ["prepareme-maps-roads.zim"]
        record.requested = ["family.zim"]
        let taken = names(60 * Self.gb, record: record)
        XCTAssertFalse(taken.contains("prepareme-maps-roads.zim"))
        XCTAssertTrue(taken.contains("family.zim"))
    }

    func testAListFromBeforePhaseMBehavesAsToday() {
        let old = [entry("prepareme-daily.zim", size: 1_000_000, kind: "library"),
                   entry("prepareme-maps-roads.zim", kind: "map-core"),
                   entry("prepareme-maps-topo-today-1.zim", kind: "map-optional")]
        let taken = LibraryPlan.toFetch(Manifest(writtenAt: "x", files: old), LibraryRecord(),
                                        room: LibraryPlan.Room(free: 1 * Self.gb, capacity: 64 * Self.gb)).map(\.name)
        XCTAssertEqual(taken, ["prepareme-daily.zim", "prepareme-maps-roads.zim"])
    }

    func testWhatWaitsForRoomAndWhichBaseFileCantUpdate() {
        let manifest = Manifest(writtenAt: "x", files: list)
        let room = LibraryPlan.Room(free: 17 * Self.gb, capacity: 64 * Self.gb)
        XCTAssertEqual(LibraryPlan.waitingForRoom(manifest, LibraryRecord(), room: room).map(\.name),
                       ["prepareme-maps-routes.zim", "prepareme-maps-topo-today-4.zim",
                        "prepareme-maps-topo-today-3.zim"])  // 2 GB above the reserve: roads only
        var record = LibraryRecord()
        var old = list[2]
        old.sha256 = String(repeating: "c", count: 64)
        record.held[old.name] = HeldFile(entry: old, file: "home-old")
        XCTAssertEqual(LibraryPlan.cantUpdate(manifest, record, free: 2 * Self.gb).map(\.name),
                       ["prepareme-street-map.pmtiles", "prepareme-maps-home-topo.zim"])  // 2 or 3 GB plus 1 won't fit in 2
        XCTAssertEqual(LibraryPlan.cantUpdate(manifest, record, free: 10 * Self.gb), [])
    }

    func testABaseFileIsntRemovableAndARoomFileIs() {
        var record = LibraryRecord()
        record.manifest = Manifest(writtenAt: "x", files: list)
        for name in ["prepareme-maps-home-topo.zim", "prepareme-maps-roads.zim"] {
            record.held[name] = HeldFile(entry: list.first { $0.name == name }!, file: name)
        }
        XCTAssertFalse(LibraryPlan.removable("prepareme-maps-home-topo.zim", record))
        XCTAssertTrue(LibraryPlan.removable("prepareme-maps-roads.zim", record))
    }

    // MARK: Review of tasks 1 and 2

    func manifestAndRecord(_ record: LibraryRecord = LibraryRecord(), choices: [String: String]? = nil)
        -> (Manifest, LibraryRecord) {
        var manifest = Manifest(writtenAt: "x", files: list)
        manifest.choices = choices
        var record = record
        record.manifest = manifest
        return (manifest, record)
    }

    func testARoomFileWaitingForItsCheckIsntFetchedAgain() {
        var record = LibraryRecord()
        record.checking = [list[3]]  // roads, downloaded, waiting for its check
        let (manifest, kept) = manifestAndRecord(record)
        let taken = LibraryPlan.toFetch(manifest, kept, room: LibraryPlan.Room(free: 60 * Self.gb, capacity: 64 * Self.gb))
        XCTAssertFalse(taken.map(\.name).contains("prepareme-maps-roads.zim"))
    }

    func testWhatWaitsAgreesWithWhatIsTakenWhenAFileIsAskedFor() {
        var record = LibraryRecord()
        record.requested = ["prepareme-maps-topo-today-4.zim"]  // 5 GB asked for, ahead of the rest
        let (manifest, kept) = manifestAndRecord(record)
        let room = LibraryPlan.Room(free: 22 * Self.gb, capacity: 64 * Self.gb)  // 7 GB over the reserve
        let taken = Set(LibraryPlan.toFetch(manifest, kept, room: room).map(\.name))
        let waiting = LibraryPlan.waitingForRoom(manifest, kept, room: room).map(\.name)
        XCTAssertTrue(taken.contains("prepareme-maps-topo-today-4.zim"))
        XCTAssertEqual(waiting, ["prepareme-maps-routes.zim", "prepareme-maps-topo-today-3.zim"])  // 2 GB left: roads
        XCTAssertTrue(taken.isDisjoint(with: waiting))
    }

    func testNeverOnAFileThePhoneHoldsKeepsItCurrentAndNeverRemovesIt() {
        var record = LibraryRecord()
        var old = list[3]
        old.sha256 = String(repeating: "d", count: 64)
        record.held[old.name] = HeldFile(entry: old, file: "roads-old")
        let (manifest, kept) = manifestAndRecord(record, choices: ["prepareme-maps-roads.zim": "never"])
        let taken = LibraryPlan.toFetch(manifest, kept, room: LibraryPlan.Room(free: 60 * Self.gb, capacity: 64 * Self.gb))
        XCTAssertTrue(taken.map(\.name).contains("prepareme-maps-roads.zim"))  // a stale copy is a defect (owner)
    }

    func testTheMacAppTakesEveryFileOfAPhaseMList() {
        let manifest = Manifest(writtenAt: "x", files: list)
        let taken = LibraryPlan.toFetch(manifest, LibraryRecord(), everyKind: true,
                                        room: LibraryPlan.Room(free: 1, capacity: 64 * Self.gb))
        XCTAssertEqual(taken.count, list.count)
    }

    /// Review: a base file the phone never got, with no room to get it, is said as well; one with room isn't
    func testABaseFileNeverGotWithNoRoomIsSaid() {
        let manifest = Manifest(writtenAt: "x", files: list)
        XCTAssertEqual(LibraryPlan.cantUpdate(manifest, LibraryRecord(), free: 3_500_000_000).map(\.name),
                       ["prepareme-maps-home-topo.zim"])
        XCTAssertEqual(LibraryPlan.cantUpdate(manifest, LibraryRecord(), free: 5 * Self.gb), [])
    }

    /// Review: the street map was removable before phase M; a phone that removed it then still gets it now it is base
    func testABaseFileRemovedBeforePhaseMStillComes() {
        var record = LibraryRecord()
        record.declined = ["prepareme-street-map.pmtiles", "prepareme-maps-roads.zim"]
        let taken = names(60 * Self.gb, record: record)
        XCTAssertTrue(taken.contains("prepareme-street-map.pmtiles"))
        XCTAssertFalse(taken.contains("prepareme-maps-roads.zim"))
    }

    func testEachBaseFileThatCantUpdateIsSaid() {
        var record = LibraryRecord()
        for index in [1, 2] {
            var old = list[index]
            old.sha256 = String(repeating: "e", count: 64)
            record.held[old.name] = HeldFile(entry: old, file: "old-\(index)")
        }
        let manifest = Manifest(writtenAt: "x", files: list)
        XCTAssertEqual(LibraryPlan.cantUpdate(manifest, record, free: 3_500_000_000).map(\.name),
                       ["prepareme-maps-home-topo.zim"])  // the 2 GB street map fits in 3.5 GB with its spare; 3 GB doesn't
    }

    /// Offline fixes, phase 5: maps by room (and a list from before phase M's optional maps) wait for the charger;
    /// the base, library files, a pre-phase-M core map, a family download and a file asked for come at once
    func testOptionalMapsUseTheDiscretionarySession() {
        let waiting = list.filter { LibraryPlan.waitsForPower($0, LibraryRecord()) }.map(\.name)
        XCTAssertEqual(waiting, ["prepareme-maps-roads.zim", "prepareme-maps-routes.zim",
                                 "prepareme-maps-topo-today-4.zim", "prepareme-maps-topo-today-3.zim"])
        XCTAssertTrue(LibraryPlan.waitsForPower(entry("old-optional.zim"), LibraryRecord()))
        XCTAssertFalse(LibraryPlan.waitsForPower(entry("old-core.zim", kind: "map-core"), LibraryRecord()))
        var asked = LibraryRecord()
        asked.requested = ["prepareme-maps-roads.zim"]
        XCTAssertFalse(LibraryPlan.waitsForPower(list[3], asked))
    }
}
