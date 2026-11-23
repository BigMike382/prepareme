import Foundation
import PrepareMeShared
import XCTest

/// The PrepareMe app's fetch rules (plan phase 4) on made-up manifests: which files, in what order, refusals, room,
/// the names copies are kept under, the get-file sheet's lookup and the install's expiry.
final class LibraryPlanTests: XCTestCase {
    /// A made-up entry; its ID is made from its name unless given, so two names are two libraries.
    func entry(_ name: String, kind: String = "library", size: Int64 = 100, sha: Character = "a",
               id: String? = nil) -> Manifest.Entry {
        let number = name.utf8.reduce(UInt64(7)) { ($0 &* 31 &+ UInt64($1)) % 0xFFFF_FFFF_FFFF }
        let made = String(format: "0f1e2d3c-4b5a-4968-8776-%012llx", number)
        return Manifest.Entry(name: name, id: id ?? made, kind: kind, size: size,
                              sha256: String(repeating: sha, count: 64),
                       deliveredAt: "2026-10-13T12:00:00-04:00")
    }

    func manifest(_ files: [Manifest.Entry]) -> Manifest {
        Manifest(writtenAt: "2026-10-13T12:00:00-04:00", files: files)
    }

    func held(_ entry: Manifest.Entry) -> HeldFile {
        HeldFile(entry: entry, file: LibraryPlan.fileName(entry))
    }

    func testLibraryFilesAndCoreMapsComeByThemselvesOptionalOnesOnlyWhenAsked() {
        let files = [entry("a.zim"), entry("core.zim", kind: "map-core"), entry("opt.zim", kind: "map-optional"),
                     entry("d.zim", kind: "download"), entry("street.pmtiles", kind: "map")]
        var state = LibraryRecord()
        XCTAssertEqual(LibraryPlan.toFetch(manifest(files), state).map(\.name), ["a.zim", "core.zim"])
        state.requested = ["opt.zim", "street.pmtiles"]
        XCTAssertEqual(LibraryPlan.toFetch(manifest(files), state).map(\.name), ["a.zim", "core.zim", "opt.zim"],
                       "a file the reader can't open is never fetched")
    }

    /// Plan phase 8: a download the Mac keeps for itself is never fetched by a phone, asked for or not; one for the
    /// family only when someone asks, like an optional map. The Mac's own app takes both.
    func testTheMacsOwnDownloadsNeverReachAPhone() {
        var family = entry("family.zim", kind: "download"), mine = entry("mine.zim", kind: "download")
        family.family = true
        mine.family = false
        var state = LibraryRecord()
        XCTAssertEqual(LibraryPlan.toFetch(manifest([family, mine]), state).map(\.name), [])
        state.requested = ["family.zim", "mine.zim"]
        XCTAssertEqual(LibraryPlan.toFetch(manifest([family, mine]), state).map(\.name), ["family.zim"])
        XCTAssertEqual(LibraryPlan.toFetch(manifest([family, mine]), LibraryRecord(), everyKind: true).map(\.name)
            .sorted(), ["family.zim", "mine.zim"])
    }

    func testAnOptionalMapAlreadyHeldIsKeptCurrent() {
        let old = entry("opt.zim", kind: "map-optional", sha: "a")
        let state = LibraryRecord(held: ["opt.zim": held(old)])
        XCTAssertEqual(LibraryPlan.toFetch(manifest([entry("opt.zim", kind: "map-optional", sha: "b")]), state)
            .map(\.name), ["opt.zim"])
    }

    func testOnlyChangedFilesAreFetchedLibraryFirstThenSmallest() {
        let daily = entry("daily.zim", size: 900, sha: "b")
        let state = LibraryRecord(held: ["daily.zim": held(entry("daily.zim", size: 900, sha: "a")),
                                        "same.zim": held(entry("same.zim", sha: "c"))])
        let files = [entry("big.zim", kind: "map-core", size: 3000), entry("small.zim", kind: "map-core", size: 10),
                     daily, entry("same.zim", sha: "c"), entry("ref.zim", size: 5000)]
        XCTAssertEqual(LibraryPlan.toFetch(manifest(files), state).map(\.name),
                       ["daily.zim", "ref.zim", "small.zim", "big.zim"])
    }

    func testACopyRefusedTwiceWaitsUntilTheMacOffersAnother() {
        let bad = entry("daily.zim", sha: "b")
        var state = LibraryRecord()
        XCTAssertFalse(LibraryPlan.refuse(bad, &state), "the first refusal: tried once more")
        XCTAssertEqual(LibraryPlan.toFetch(manifest([bad]), state).map(\.name), ["daily.zim"])
        XCTAssertTrue(LibraryPlan.refuse(bad, &state))
        XCTAssertTrue(LibraryPlan.toFetch(manifest([bad]), state).isEmpty)
        let next = entry("daily.zim", sha: "c")
        XCTAssertEqual(LibraryPlan.toFetch(manifest([next]), state).map(\.name), ["daily.zim"], "another copy")
        LibraryPlan.forgetOldRefusals(manifest([next]), &state)
        XCTAssertEqual(state.refusals, [:])
    }

    func testOneLibraryIDIsOneLibraryTheFirstReadWins() {
        let id = "0f1e2d3c-4b5a-4968-8776-6554433221b1"
        let first = entry("first.zim", id: id), second = entry("second.zim", sha: "b", id: id)
        XCTAssertEqual(LibraryPlan.toFetch(manifest([first, second]), LibraryRecord()).map(\.name), ["first.zim"])
        let state = LibraryRecord(held: ["second.zim": held(second)])
        XCTAssertTrue(LibraryPlan.toFetch(manifest([first, entry("second.zim", sha: "c", id: id)]), state)
            .filter { $0.name == "first.zim" }.isEmpty, "held under another name")
    }

    func testACopyWaitingForItsChecksIsntFetchedAgain() {
        let daily = entry("daily.zim", sha: "b")
        XCTAssertTrue(LibraryPlan.toFetch(manifest([daily]), LibraryRecord(checking: [daily])).isEmpty)
        XCTAssertEqual(LibraryPlan.toFetch(manifest([daily]), LibraryRecord(checking: [entry("daily.zim", sha: "c")]))
            .map(\.name), ["daily.zim"], "an older copy waiting doesn't stop the newer")
        var later = daily
        later.deliveredAt = "2026-10-13T13:00:00-04:00"
        XCTAssertTrue(LibraryPlan.toFetch(manifest([later]), LibraryRecord(checking: [daily])).isEmpty,
                      "the same copy, by its SHA-256, whatever else its entry says (review, I2)")
    }

    func testAStateFromBeforeAFieldReadsWithItEmpty() throws {
        let state = try JSONDecoder().decode(LibraryRecord.self, from: Data("{\"held\": {}}".utf8))
        XCTAssertEqual(state, LibraryRecord())
    }

    func testRoomMeansTheFilePlusAGigabyteSpare() {
        XCTAssertTrue(LibraryPlan.hasRoom(for: 100, available: 100 + (1 << 30)))
        XCTAssertFalse(LibraryPlan.hasRoom(for: 100, available: 99 + (1 << 30)))
    }

    func testEachCopyIsKeptUnderANameOfItsOwn() {
        XCTAssertEqual(LibraryPlan.fileName(entry("prepareme-daily.zim", sha: "b")),
                       "prepareme-daily.bbbbbbbbbbbb.zim")
        XCTAssertNotEqual(LibraryPlan.fileName(entry("x.zim", sha: "b")),
                          LibraryPlan.fileName(entry("x.zim", sha: "c")))
    }

    func testTheGetFileSheetFindsAnIDThePhoneDoesntHold() {
        let maps = entry("opt.zim", kind: "map-optional", size: 2_300_000_000,
                         id: "0f1e2d3c-4b5a-4968-8776-6554433221a3")
        let daily = entry("daily.zim")
        var state = LibraryRecord(held: ["daily.zim": held(daily)], manifest: manifest([daily, maps]))
        XCTAssertEqual(LibraryPlan.missing(id: "0F1E2D3C-4B5A-4968-8776-6554433221A3", state), maps)
        XCTAssertNil(LibraryPlan.missing(id: daily.id, state), "held")
        XCTAssertNil(LibraryPlan.missing(id: "0f1e2d3c-4b5a-4968-8776-000000000000", state), "not the Mac's")
        state.manifest = nil
        XCTAssertNil(LibraryPlan.missing(id: maps.id, state), "no manifest read yet")
    }

    func testTheStateSurvivesBeingWrittenAndRead() throws {
        let daily = entry("daily.zim")
        let state = LibraryRecord(held: ["daily.zim": held(daily)], requested: ["opt.zim"], refusals: [daily.sha256: 1],
                                 manifest: manifest([daily]), checkedAt: "2026-10-13T16:00:00Z", checking: [daily])
        XCTAssertEqual(try JSONDecoder().decode(LibraryRecord.self, from: JSONEncoder().encode(state)), state)
    }

    func testTheInstallsExpiryIsReadFromItsProfile() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>ExpirationDate</key><date>2027-10-13T12:00:00Z</date>
        <key>Name</key><string>made up</string></dict></plist>
        """
        let signed = Data([0x30, 0x80, 0x06, 0x09]) + Data(plist.utf8) + Data([0xA0, 0x00, 0x31])  // as in a profile
        let expiry = try XCTUnwrap(InstallExpiry.date(fromProfile: signed))
        XCTAssertEqual(expiry, ISO8601DateFormatter().date(from: "2027-10-13T12:00:00Z"))
        XCTAssertEqual(InstallExpiry.daysLeft(expiry, now: expiry.addingTimeInterval(-10.5 * 86400)), 10)
        XCTAssertEqual(InstallExpiry.daysLeft(expiry, now: expiry.addingTimeInterval(86400)), 0)
        XCTAssertNil(InstallExpiry.date(fromProfile: Data("not a profile".utf8)))
        XCTAssertNil(InstallExpiry.created(fromProfile: signed))
        let week = expiry.addingTimeInterval(-7 * 86400), year = expiry.addingTimeInterval(-365 * 86400)
        XCTAssertEqual(InstallExpiry.warnDays(created: week, expiry: expiry), 2)
        XCTAssertEqual(InstallExpiry.warnDays(created: year, expiry: expiry), 30)
        XCTAssertEqual(InstallExpiry.warnDays(created: nil, expiry: expiry), 30)
    }

    /// Concept-doc plan, phase B: the backup key a phone learned is kept across saves and never forgotten when a later
    /// list from the Mac comes without one
    func testTheBackupKeyIsKeptInTheRecord() throws {
        var record = LibraryRecord()
        record.backupKey = "a key"
        let again = try JSONDecoder().decode(LibraryRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(again.backupKey, "a key")
        XCTAssertNil(try JSONDecoder().decode(LibraryRecord.self, from: Data("{}".utf8)).backupKey)
    }
}

import Testing

/// Family downloads plan, phase 4 (decisions 1, 2 and 8, owner 2026-11-15, by click): the floor the library needs to
/// update, the question under 10 GB, Today's largest removable file, and a file the Mac set to Always. Made-up lists.
struct LibraryPlanRoomTests {
    static let gb: Int64 = 1_000_000_000

    func entry(_ name: String, fetch: String? = nil, size: Int64 = 1 * gb, kind: String = "map-optional",
               family: Bool? = nil) -> Manifest.Entry {
        Manifest.Entry(name: name, id: UUID().uuidString, kind: kind, size: size,
                       sha256: String(repeating: "a", count: 64), deliveredAt: "2026-11-15T12:00:00-05:00",
                       family: family, fetch: fetch)
    }

    var list: [Manifest.Entry] {
        [entry("prepareme-daily.zim", fetch: "base", size: 1_000_000, kind: "library"),
         entry("prepareme-street-map.pmtiles", fetch: "base", size: 2 * Self.gb, kind: "map"),
         entry("prepareme-maps-home-topo.zim", fetch: "base", size: 3 * Self.gb, kind: "map-core"),
         entry("prepareme-maps-roads.zim", fetch: "room", size: 1 * Self.gb, kind: "map-core"),
         entry("prepareme-maps-topo-today-4.zim", fetch: "room", size: 5 * Self.gb),
         entry("family.zim", size: 2 * Self.gb, kind: "download", family: true),
         entry("mine.zim", size: 40 * Self.gb, kind: "download", family: false)]
    }

    /// A record holding `names`, its list carrying `choices`
    func record(holding names: [String], choices: [String: String]? = nil) -> LibraryRecord {
        var manifest = Manifest(writtenAt: "x", files: list)
        manifest.choices = choices
        var record = LibraryRecord(manifest: manifest)
        for name in names { record.held[name] = HeldFile(entry: list.first { $0.name == name }!, file: name) }
        return record
    }

    @Test func theFloorIsTheLargestBaseFileAndTheSpare() {
        #expect(LibraryPlan.floor(list) == 3 * Self.gb + LibraryPlan.spareBytes)  // the Mac's own 40 GB never counts
        // a list from before phase M: the library files and core maps are the base
        let old = [entry("a.zim", size: 5 * Self.gb, kind: "library"), entry("b.zim", size: 9 * Self.gb)]
        #expect(LibraryPlan.floor(old) == 5 * Self.gb + LibraryPlan.spareBytes)
        #expect(LibraryPlan.floor(nil) == LibraryPlan.spareBytes)  // no list yet: the spare alone, as before
    }

    @Test func anAddUnderTheFloorIsRefusedUnderTenGigabytesAskedAndAboveGoes() {
        let floor = 4 * Self.gb
        #expect(LibraryPlan.adding(2 * Self.gb, free: 5 * Self.gb, floor: floor) == .refused(floor: floor))
        #expect(LibraryPlan.adding(2 * Self.gb, free: 6 * Self.gb, floor: floor) == .ask(left: 4 * Self.gb),
                "exactly the floor left is allowed")
        #expect(LibraryPlan.adding(2 * Self.gb, free: 11 * Self.gb, floor: floor) == .ask(left: 9 * Self.gb))
        #expect(LibraryPlan.adding(2 * Self.gb, free: 12 * Self.gb, floor: floor) == .go, "10 GB left: no question")
        #expect(StorageWords.floorRefusal(floor: floor + 1) == "Not enough room: this would leave less than 4.1 GB "
                + "free, which the library needs to update.")
        #expect(StorageWords.floorReason(floor: floor) == "This would leave less than 4.0 GB free, which the library needs "
                + "to update.")
        #expect(StorageWords.leaves(9_960_000_000) == "It leaves 9.9 GB free on this phone.", "rounded down")
    }

    @Test func aNewFileNeedsTheFloorAnUpdateOrTheBaseTheSpare() {
        let record = record(holding: ["family.zim"])
        let floor = LibraryPlan.floor(list)
        #expect(LibraryPlan.need(list[4], record, floor: floor) == 5 * Self.gb + floor)  // a new map asked for away
        #expect(LibraryPlan.need(list[5], record, floor: floor) == 2 * Self.gb + LibraryPlan.spareBytes)  // held
        #expect(LibraryPlan.need(list[2], record, floor: floor) == 3 * Self.gb + LibraryPlan.spareBytes)  // base
    }

    @Test func theLargestRemovableFileIsOfferedNeverTheBaseOrAnAlways() {
        let names = ["prepareme-maps-home-topo.zim", "prepareme-maps-roads.zim", "prepareme-maps-topo-today-4.zim",
                     "family.zim"]
        #expect(LibraryPlan.largestRemovable(record(holding: names))?.entry.name == "prepareme-maps-topo-today-4.zim")
        let always = record(holding: names, choices: ["prepareme-maps-topo-today-4.zim": "always"])
        #expect(LibraryPlan.largestRemovable(always)?.entry.name == "family.zim")
        #expect(LibraryPlan.largestRemovable(record(holding: ["prepareme-maps-home-topo.zim"])) == nil)
        #expect(HomeMacWords.removeButton(title: "Topo maps, today", size: 5 * Self.gb)
                == "Remove Topo maps, today (5.0 GB)…")
    }

    @Test func aFileTheMacSetToAlwaysHasNoRemove() {
        let record = record(holding: ["family.zim", "prepareme-maps-roads.zim"], choices: ["family.zim": "always"])
        #expect(!LibraryPlan.removable("family.zim", record))
        #expect(LibraryPlan.keptByMac(list[5], record))
        #expect(LibraryPlan.removable("prepareme-maps-roads.zim", record))
        #expect(HomeMacWords.keptByMac(device: "iPad") == "Kept on this iPad (set on the Mac).")
        // a list from a Mac before phase 4 still says "never" for a skip: that keeps Remove
        #expect(LibraryPlan.removable("family.zim", self.record(holding: ["family.zim"],
                                                                 choices: ["family.zim": "never"])))
    }

    @Test func alwaysBeatsAnEarlierRemove() {
        var record = record(holding: [], choices: ["family.zim": "always"])
        record.declined = ["family.zim", "prepareme-maps-roads.zim"]
        #expect(LibraryPlan.wanted(list[5], record))
        #expect(!LibraryPlan.wanted(list[3], record), "without Always, Remove still holds")
    }

    @Test func anAlwaysWaitsRatherThanGoBelowTheFloor() {
        let base = ["prepareme-daily.zim", "prepareme-street-map.pmtiles", "prepareme-maps-home-topo.zim"]
        let record = record(holding: base, choices: ["prepareme-maps-topo-today-4.zim": "always"])
        let manifest = record.manifest!
        let tight = LibraryPlan.Room(free: 8 * Self.gb, capacity: 64 * Self.gb)  // 5 GB would leave 3, under 4
        #expect(!LibraryPlan.toFetch(manifest, record, room: tight).map(\.name).contains("prepareme-maps-topo-today-4.zim"))
        #expect(LibraryPlan.waitingForRoom(manifest, record, room: tight).map(\.name)
            .contains("prepareme-maps-topo-today-4.zim"))
        let enough = LibraryPlan.Room(free: 5 * Self.gb + LibraryPlan.floor(list), capacity: 64 * Self.gb)  // exactly the floor left
        #expect(LibraryPlan.toFetch(manifest, record, room: enough).map(\.name).contains("prepareme-maps-topo-today-4.zim"),
                "under the 10 GB line an Always still comes (decision 1)")
    }

    @Test func theRoomWarningPointsAtItsButtonWhenThereIsAFileToRemove() {
        let words = HomeMacWords.roomWarning(file: "Daily", more: 0, need: 4 * Self.gb, free: 2 * Self.gb, canRemove: true)
        #expect(words == "Not enough room for Daily: it needs 4.0 GB free and this phone has 2.0 GB. Free some space, or "
                + "remove a file.")
        #expect(HomeMacWords.roomWarning(file: "Daily", more: 0, need: 4 * Self.gb, free: 2 * Self.gb)
            .hasSuffix("Free some space, or remove a map under Downloads."))
    }

    /// The check (iOS 27.2 SDK headers): a write that fails mid-download is NSURLErrorCannotWriteToFile (-3003), a
    /// move of the finished file out of space NSFileWriteOutOfSpaceError (640) or POSIX ENOSPC (28)
    @Test func aDownloadThatRanOutOfRoomSaysSoInPlaceOfTheCode() {
        let plenty = 20 * Self.gb, little: Int64 = 500_000_000
        #expect(HomeMacWords.downloadStopped(received: 2 * Self.gb, code: -3003, free: little)
                == "This phone ran out of room. It carries on at the next check once there is space.")
        #expect(HomeMacWords.downloadStopped(received: 2 * Self.gb, code: -1001, free: plenty)
                == "The download stopped after 2.0 GB (code -1001); it carries on at the next check.")
        #expect(HomeMacWords.downloadNotKept(code: 640, free: plenty, device: "iPad")
                == "This iPad ran out of room. It is tried again at the next check once there is space.")
        #expect(HomeMacWords.downloadNotKept(code: 28, free: plenty).hasPrefix("This phone ran out of room."))
        #expect(HomeMacWords.downloadNotKept(code: 516, free: plenty)
                == "The finished download couldn't be kept (code 516); tried again at the next check.")
    }
}
