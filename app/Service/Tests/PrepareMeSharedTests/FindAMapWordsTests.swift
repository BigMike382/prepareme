@testable import PrepareMeShared
import XCTest

/// Find a map while the topo overview waits for room (beta run 3, B3-02): the overview is the file Find a map reads,
/// the room rule is the one Home Mac's "Waiting for room" uses, and the words are the owner's (2026-10-21, choice a).
final class FindAMapWordsTests: XCTestCase {
    static let overview = "prepareme-maps-topo-overview.zim"
    static let gb: Int64 = 1_000_000_000

    func entry(_ name: String, fetch: String?, order: Int?, size: Int64) -> Manifest.Entry {
        Manifest.Entry(name: name, id: UUID().uuidString, kind: "map-optional", size: size,
                       sha256: String(repeating: "a", count: 64), deliveredAt: "2026-10-21T12:00:00-04:00",
                       family: nil, fetch: fetch, order: order)
    }

    var manifest: Manifest {
        Manifest(writtenAt: "x", files: [
            entry("prepareme-daily.zim", fetch: "base", order: nil, size: 1_000_000),
            entry("prepareme-maps-roads.zim", fetch: "room", order: 1, size: 5 * Self.gb),
            entry(Self.overview, fetch: "room", order: 2, size: 60_000)])
    }

    func testTheOverviewWaitingForRoomIsWhatFindAMapReports() {
        // 64 GB phone, 14 GB free: the reserve is 10 GB, the base takes 1 MB, so roads (5 GB) doesn't fit and the
        // order is strict: the 60 KB overview waits behind it
        let room = LibraryPlan.Room(free: 14 * Self.gb, capacity: 64 * Self.gb)
        let waiting = LibraryPlan.waitingForRoom(manifest, LibraryRecord(), room: room)
        XCTAssertEqual(waiting.map(\.name), ["prepareme-maps-roads.zim", Self.overview])
        XCTAssertEqual(FindAMapWords.waitingOverview(waiting, overviewFile: Self.overview)?.name, Self.overview)
    }

    func testAnyOtherCaseKeepsTheOldWords() {
        let room = LibraryPlan.Room(free: 60 * Self.gb, capacity: 64 * Self.gb)  // plenty: nothing waits
        let waiting = LibraryPlan.waitingForRoom(manifest, LibraryRecord(), room: room)
        XCTAssertNil(FindAMapWords.waitingOverview(waiting, overviewFile: Self.overview))
        XCTAssertNil(FindAMapWords.waitingOverview([], overviewFile: Self.overview))
        // another map waiting is not the overview
        XCTAssertNil(FindAMapWords.waitingOverview([manifest.files[1]], overviewFile: Self.overview))
        XCTAssertEqual(FindAMapWords.fromTheMac,
                       "The maps come from the Mac with the library. Downloads shows how far it has got.")
    }

    func testTheOwnersWordsWithTheDeviceAndTheSize() {
        XCTAssertEqual(FindAMapWords.waitingForRoom(size: StorageWords.size(60_000), device: "phone"),
                       "The map overview is waiting for room on this phone (60 KB). Download it, or free up space.")
        XCTAssertEqual(FindAMapWords.waitingForRoom(size: "60 KB", device: "iPad"),
                       "The map overview is waiting for room on this iPad (60 KB). Download it, or free up space.")
        XCTAssertEqual(FindAMapWords.getThisFile, "Download")
    }

    /// After Get this file the screen said the old words until the file landed (the owner's click, 2026-10-21): asked for
    /// or downloading, it says the overview is on its way, in the owner's words; another file's download is not it.
    func testTheOverviewOnItsWaySaysSo() {
        XCTAssertEqual(FindAMapWords.getting(device: "phone"),
                       "Getting the map overview now. Find a map opens here once it's on this phone.")
        XCTAssertEqual(FindAMapWords.getting(device: "iPad"),
                       "Getting the map overview now. Find a map opens here once it's on this iPad.")
        XCTAssertTrue(FindAMapWords.isGetting(requested: [Self.overview], downloading: [:], overviewFile: Self.overview))
        XCTAssertTrue(FindAMapWords.isGetting(requested: [], downloading: [Self.overview: 0.4],
                                              overviewFile: Self.overview))
        XCTAssertFalse(FindAMapWords.isGetting(requested: ["prepareme-maps-roads.zim"],
                                               downloading: ["prepareme-maps-roads.zim": 0.1],
                                               overviewFile: Self.overview))
        XCTAssertFalse(FindAMapWords.isGetting(requested: [], downloading: [:], overviewFile: Self.overview))
    }
}
