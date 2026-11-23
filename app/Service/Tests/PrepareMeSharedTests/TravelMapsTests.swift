import Foundation
import JavaScriptCore
import PrepareMeShared
import XCTest

/// The travel street maps on a phone (combined step 9; docs/plans/2026-10-20-step-9-travel-maps.md): one file per state
/// from the PrepareMe Travel Maps folder, checked three ways against that folder's list (named, size, SHA-256) and as a
/// whole map file, kept in the app's own storage, drawn on the street map with the home file, and removed on an adult's
/// word. Made-up map files and lists in a fresh temporary folder; the "states" are Washington, DC and far from it.
@MainActor
final class TravelMapsTests: XCTestCase {
    var root: URL!
    var folder: URL!  // stands in for iCloud Drive › PrepareMe Travel Maps

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-travel-\(UUID())")
        folder = root.appendingPathComponent("PrepareMe Travel Maps")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// A made-up whole map file (a PMTiles header, then `tiles` as its tile data to the end), covering a box.
    func mapFile(_ tiles: String = "tile bytes", box: [Int32] = [-772_000_000, 388_000_000, -769_000_000, 390_000_000],
                 maxZoom: UInt8 = 15) -> Data {
        var head = Data("PMTiles".utf8) + Data([3])
        func put(_ n: UInt64) { withUnsafeBytes(of: n.littleEndian) { head.append(contentsOf: $0) } }
        for n in [127, 0, 127, 0, 127, 0, 127, UInt64(tiles.utf8.count), 1, 1, 1] as [UInt64] { put(n) }
        head.append(contentsOf: [1, 2, 2, 1, 0, maxZoom])
        for value in box { withUnsafeBytes(of: value.littleEndian) { head.append(contentsOf: $0) } }
        head.append(10)
        for value in [Int32((Int64(box[0]) + Int64(box[2])) / 2), Int32((Int64(box[1]) + Int64(box[3])) / 2)] {
            withUnsafeBytes(of: value.littleEndian) { head.append(contentsOf: $0) }
        }
        XCTAssertEqual(head.count, 127)
        return head + Data(tiles.utf8)
    }

    /// `data` written into the folder under the state's name, and the list's entry for it
    @discardableResult
    func put(_ state: String, _ data: Data, build: String = "20261014", made: String = "2026-10-20T12:00:00+00:00")
        throws -> TravelMaps.Entry {
        let name = TravelMaps.fileName(state)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        return TravelMaps.Entry(state: state, name: name, build: build, size: Int64(data.count),
                                sha256: try FileCheck.sha256(of: file), made: made)
    }

    func listData(_ entries: [TravelMaps.Entry]) throws -> Data {
        try JSONEncoder().encode(TravelMaps.List(format: TravelMaps.format, files: entries))
    }

    // MARK: The folder's list

    func testTheListIsReadInTheShapeTheMacWritesIt() throws {
        let list = try TravelMaps.read(Data(contentsOf: Self.fixtures.appendingPathComponent("travel-maps-manifest.json")))
        XCTAssertEqual(list.format, 1)
        XCTAssertEqual(list.files.map(\.state), ["DC", "WA"])
        XCTAssertEqual(list.files[0].name, TravelMaps.fileName("DC"))
        XCTAssertEqual(list.files[0].name, "prepareme-travel-map-dc.pmtiles", "the name librarian/streetmap.py gives")
        XCTAssertEqual(list.files[1].size, 2_097_152)
        XCTAssertEqual(TravelMaps.built(list.files[0].build), "2026-10-14")
    }

    func testAListThatIsntWholeOrRightIsRefused() throws {
        let good = TravelMaps.Entry(state: "DC", name: TravelMaps.fileName("DC"), build: "20261014", size: 5,
                                    sha256: String(repeating: "a", count: 64), made: "2026-10-20T12:00:00+00:00")
        XCTAssertNoThrow(try TravelMaps.read(listData([good])))
        XCTAssertThrowsError(try TravelMaps.read(Data("{not json".utf8)))
        XCTAssertThrowsError(try TravelMaps.read(try JSONEncoder().encode(TravelMaps.List(format: 2, files: [good]))))
        var bad = good
        bad.name = "../prepareme-travel-map-dc.pmtiles"
        XCTAssertThrowsError(try TravelMaps.read(listData([bad])), "a name that isn't the state's own")
        bad = good
        bad.name = "prepareme-daily.zim"
        XCTAssertThrowsError(try TravelMaps.read(listData([bad])))
        bad = good
        bad.sha256 = "not a hash"
        XCTAssertThrowsError(try TravelMaps.read(listData([bad])))
        bad = good
        bad.size = 0
        XCTAssertThrowsError(try TravelMaps.read(listData([bad])))
        bad = good
        bad.state = "ZZ"
        bad.name = TravelMaps.fileName("ZZ")
        XCTAssertThrowsError(try TravelMaps.read(listData([bad])), "not a state")
        XCTAssertThrowsError(try TravelMaps.read(listData([good, good])), "a state listed twice")
    }

    // MARK: What the folder offers, against what the phone holds

    func testEachStateIsOfferedAgainstThisPhonesCopy() throws {
        let dc = try put("DC", mapFile("dc new"), build: "20261015")
        let wa = try put("WA", mapFile("wa"))
        let md = TravelMaps.Entry(state: "MD", name: TravelMaps.fileName("MD"), build: "20261014", size: 9,
                                  sha256: String(repeating: "b", count: 64), made: "x")  // listed, not in the folder yet
        let list = TravelMaps.List(format: 1, files: [dc, md, wa])
        var oldDC = dc
        oldDC.sha256 = String(repeating: "c", count: 64)
        oldDC.build = "20261001"
        let held = [TravelHeld(entry: oldDC, file: "a"), TravelHeld(entry: wa, file: "b")]
        let present = try Backup.listing(in: folder)
        let items = TravelMaps.offer(list, present: present, held: held)
        XCTAssertEqual(items.map(\.entry.state), ["DC", "MD", "WA"])
        XCTAssertEqual(items.map(\.standing), [.newer, .notWhole, .same])
        XCTAssertEqual(items[0].held?.build, "20261001")
        XCTAssertTrue(items[0].canAdd)
        XCTAssertFalse(items[1].canAdd, "not whole in the folder yet: iCloud is still bringing it")
        XCTAssertFalse(items[2].canAdd)
        // a file of another size than listed (an older copy iCloud hasn't replaced yet) isn't whole either
        let cut = TravelMaps.offer(list, present: present.merging([wa.name: 3]) { _, b in b }, held: [])
        XCTAssertEqual(cut.map(\.standing), [.missing, .notWhole, .notWhole])
        // a file iCloud keeps off the phone (its placeholder only) is offered: the copy downloads it
        let placeholder = FolderOffer.present(names: [".\(md.name).icloud"], sizes: [:])
        XCTAssertEqual(TravelMaps.offer(list, present: placeholder, held: [])[1].standing, .missing)
        // the phone's copy newer than the folder's: never taken back to the older one
        var newer = wa
        newer.build = "20261030"
        newer.sha256 = String(repeating: "d", count: 64)
        XCTAssertEqual(TravelMaps.offer(list, present: present, held: [TravelHeld(entry: newer, file: "c")])[2].standing,
                       .older)
    }

    // MARK: The three checks, and room

    func testACopyPassesOnlyWhenTheListNamesItAndItsSizeAndSHAMatch() throws {
        let dc = try put("DC", mapFile())
        let list = TravelMaps.List(format: 1, files: [dc])
        let copy = root.appendingPathComponent("copy.pmtiles")
        try mapFile().write(to: copy)
        XCTAssertEqual(try TravelMaps.check(copy, as: dc.name, against: list), .ok)
        XCTAssertEqual(try TravelMaps.check(copy, as: TravelMaps.fileName("WA"), against: list), .notNamed)
        try mapFile().dropLast(2).write(to: copy)
        XCTAssertEqual(try TravelMaps.check(copy, as: dc.name, against: list), .wrongSize(dc.size - 2))
        try mapFile("tile bytez").write(to: copy)  // the same size, one byte off
        XCTAssertEqual(try TravelMaps.check(copy, as: dc.name, against: list), .wrongHash)
        // listed whole but not a map file at all: refused by the map check after the three
        let junk = Data(repeating: 7, count: 200)
        let fake = try put("WA", junk)
        try junk.write(to: copy)
        guard case .notAMap = try TravelMaps.check(copy, as: fake.name, against: TravelMaps.List(format: 1, files: [fake]))
        else { return XCTFail("a file that isn't a map is refused") }
        XCTAssertTrue(TravelMaps.refusal(.wrongSize(1)).contains("wait"), "a cut copy says to wait for iCloud")
        XCTAssertEqual(TravelMaps.refusal(.wrongHash), TravelMaps.refusal(.wrongSize(1)))
    }

    func testRoomIsTheFilesSizeAndTheSpareGigabyteTwiceForOneStillInICloud() {
        let entry = TravelMaps.Entry(state: "DC", name: TravelMaps.fileName("DC"), build: "20261014",
                                     size: 3_000_000_000, sha256: String(repeating: "a", count: 64), made: "x")
        XCTAssertEqual(TravelMaps.need(entry, inICloudOnly: false), 3_000_000_000 + LibraryPlan.spareBytes)
        XCTAssertEqual(TravelMaps.need(entry, inICloudOnly: true), 6_000_000_000 + LibraryPlan.spareBytes)
        XCTAssertNil(TravelMaps.noRoom(entry, inICloudOnly: false, free: 5_000_000_000))
        let said = TravelMaps.noRoom(entry, inICloudOnly: true, free: 5_000_000_000, device: "iPad")
        XCTAssertEqual(said, "Washington, DC's map needs 7.1 GB free to copy and check; this iPad has 5.0 GB. "
                       + "Remove something under Downloads first.")
        XCTAssertEqual(TravelMaps.takes(entry), "Takes 3.0 GB on this phone.")
    }

    // MARK: Kept on the phone, and Remove

    func testACheckedCopyIsKeptOutOfBackupsAndANewOneReplacesIt() throws {
        let store = TravelStore(root: root.appendingPathComponent("travel"))
        store.prepareFolders()
        let first = try put("DC", mapFile("first"))
        let copy = store.incoming(first)
        try mapFile("first").write(to: copy)
        try store.keep(copy, entry: first)
        XCTAssertEqual(store.held.map(\.entry), [first])
        let kept = try XCTUnwrap(store.files.first)
        XCTAssertEqual(try Data(contentsOf: kept), mapFile("first"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "moved in, not copied")
        XCTAssertEqual(try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
                       "the app's own storage, never in the phone's iCloud backup")
        let again = TravelStore(root: store.root)
        XCTAssertEqual(again.held, store.held, "the record is saved whole and read back")
        // a newer copy of the same state takes the old one's place, which goes only once the record names the new one
        let second = try put("DC", mapFile("second"), build: "20261020")
        try mapFile("second").write(to: store.incoming(second))
        try store.keep(store.incoming(second), entry: second)
        XCTAssertEqual(store.held.map(\.entry), [second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path), "the old copy is gone")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folder.path).count, 1)
    }

    func testRemoveTakesAStateOffAndKeepsTheOthers() throws {
        let store = TravelStore(root: root.appendingPathComponent("travel"))
        store.prepareFolders()
        for (state, text) in [("WA", "wa"), ("DC", "dc")] {
            let entry = try put(state, mapFile(text))
            try mapFile(text).write(to: store.incoming(entry))
            try store.keep(store.incoming(entry), entry: entry)
        }
        XCTAssertEqual(store.held.map(\.entry.state), ["DC", "WA"], "listed by state")
        let dcFile = store.files[0]
        try store.remove("DC")
        XCTAssertEqual(store.held.map(\.entry.state), ["WA"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dcFile.path))
        XCTAssertEqual(TravelStore(root: store.root).held.map(\.entry.state), ["WA"])
    }

    func testARecordThatCantBeReadIsNeverWrittenOver() throws {
        let travel = root.appendingPathComponent("travel")
        try FileManager.default.createDirectory(at: travel, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: travel.appendingPathComponent(TravelStore.recordName))
        let store = TravelStore(root: travel)
        store.prepareFolders()
        let dc = try put("DC", mapFile())
        try mapFile().write(to: store.incoming(dc))
        XCTAssertThrowsError(try store.keep(store.incoming(dc), entry: dc))
        XCTAssertEqual(try String(contentsOf: travel.appendingPathComponent(TravelStore.recordName), encoding: .utf8),
                       "{not json")
    }

    /// Phase K, finding 9: a Remove that fails says why, and the state stays listed with its file
    func testARemoveThatFailsSaysWhyAndKeepsTheState() throws {
        let store = TravelStore(root: root.appendingPathComponent("travel"))
        store.prepareFolders()
        let dc = try put("DC", mapFile())
        try mapFile().write(to: store.incoming(dc))
        try store.keep(store.incoming(dc), entry: dc)
        let kept = try XCTUnwrap(store.files.first)
        // the record can't be saved: its folder made read-only
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.root.path) }
        var failure: Error?
        XCTAssertThrowsError(try store.remove("DC")) { failure = $0 }
        XCTAssertEqual(store.held.map(\.entry), [dc], "the row stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        let reason = FileCopy.reason(try XCTUnwrap(failure))
        XCTAssertEqual(reason, "Permission denied")
        XCTAssertEqual(TravelMaps.removeFailed(dc, reason: reason),
                       "Couldn't remove Washington, DC: Permission denied. It's still on this phone.")
        XCTAssertEqual(TravelMaps.removeFailed(dc, reason: reason, device: "iPad"),
                       "Couldn't remove Washington, DC: Permission denied. It's still on this iPad.")
    }

    /// Phase K, finding 10 and the owner's choice 2: a damaged record is said, and Start over deletes the record and
    /// every travel map, leaving a store that works; on a readable record it does nothing
    func testStartOverEmptiesADamagedStoreAndLeavesOneThatWorks() throws {
        let travel = root.appendingPathComponent("travel")
        let fresh = TravelStore(root: travel)
        fresh.prepareFolders()
        let dc = try put("DC", mapFile())
        try mapFile().write(to: fresh.incoming(dc))
        try fresh.keep(fresh.incoming(dc), entry: dc)
        try fresh.startOver()
        XCTAssertEqual(fresh.held.map(\.entry), [dc], "a readable record: Start over does nothing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fresh.folder.path).count, 1)

        try Data("{not json".utf8).write(to: travel.appendingPathComponent(TravelStore.recordName))
        try Data("part".utf8).write(to: fresh.incomingFolder.appendingPathComponent("stopped.pmtiles"))
        let store = TravelStore(root: travel)
        XCTAssertTrue(store.locked)
        XCTAssertEqual(store.held, [])
        try store.startOver()
        XCTAssertFalse(store.locked)
        XCTAssertEqual(store.held, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folder.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.incomingFolder.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordFile.path))
        // and it works again
        try mapFile().write(to: store.incoming(dc))
        try store.keep(store.incoming(dc), entry: dc)
        XCTAssertEqual(TravelStore(root: travel).held.map(\.entry), [dc])
    }

    /// Phase K, finding 11: a stopped add's copy in `incoming`, and a file in `maps` the record doesn't name, are
    /// cleared; `maps` is left alone while the record can't be read
    func testLeftoversAreClearedAndKeptMapsStay() throws {
        let travel = root.appendingPathComponent("travel")
        let store = TravelStore(root: travel)
        store.prepareFolders()
        let dc = try put("DC", mapFile())
        try mapFile().write(to: store.incoming(dc))
        try store.keep(store.incoming(dc), entry: dc)
        let kept = try XCTUnwrap(store.files.first)
        let stray = store.folder.appendingPathComponent("prepareme-travel-map-wa.0123456789ab.pmtiles")
        try Data("left".utf8).write(to: stray)
        try Data("part".utf8).write(to: store.incomingFolder.appendingPathComponent("stopped.pmtiles"))
        store.clearLeftovers()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.incomingFolder.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folder.path), [kept.lastPathComponent])
        XCTAssertEqual(store.held.map(\.entry), [dc])

        try Data("{not json".utf8).write(to: travel.appendingPathComponent(TravelStore.recordName))
        try Data("part".utf8).write(to: store.incomingFolder.appendingPathComponent("stopped.pmtiles"))
        let locked = TravelStore(root: travel)
        locked.clearLeftovers()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locked.incomingFolder.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locked.folder.path),
                       [kept.lastPathComponent],
                       "a record that can't be read names nothing, so nothing in maps is taken for a leftover")
    }

    func testTheDamagedListsWords() {
        XCTAssertEqual(TravelMaps.damagedRecord(),
                       "This phone's list of travel maps is damaged, so they can't be shown or removed.")
        XCTAssertEqual(TravelMaps.damagedRecord(device: "iPad"),
                       "This iPad's list of travel maps is damaged, so they can't be shown or removed.")
        XCTAssertEqual(TravelMaps.startOver, "Start over")
        XCTAssertEqual(TravelMaps.startOverQuestion(),
                       "Remove every travel map from this phone? You can add them again from Files.")
        XCTAssertEqual(TravelMaps.startOverQuestion(device: "iPad"),
                       "Remove every travel map from this iPad? You can add them again from Files.")
    }

    // MARK: The street map's sources

    func testTheMapReadsTheHomeFileThenEachTravelFile() throws {
        let home = root.appendingPathComponent("home.pmtiles")
        let dc = root.appendingPathComponent("dc.pmtiles")
        let wa = root.appendingPathComponent("wa.pmtiles")
        XCTAssertEqual(StreetMap.pageFiles(travel: 0), ["prepareme-map://tiles/street.pmtiles"])
        XCTAssertEqual(StreetMap.pageFiles(travel: 2), ["prepareme-map://tiles/street.pmtiles",
                                                        "prepareme-map://tiles/travel/0.pmtiles",
                                                        "prepareme-map://tiles/travel/1.pmtiles"])
        func served(_ text: String) -> URL? { StreetMap.served(URL(string: text)!, home: home, travel: [dc, wa]) }
        XCTAssertEqual(served("prepareme-map://tiles/street.pmtiles"), home)
        XCTAssertEqual(served("prepareme-map://tiles/travel/0.pmtiles"), dc)
        XCTAssertEqual(served("prepareme-map://tiles/travel/1.pmtiles"), wa)
        for bad in ["prepareme-map://tiles/travel/2.pmtiles", "prepareme-map://tiles/travel/-1.pmtiles",
                    "prepareme-map://tiles/travel/../street.pmtiles", "prepareme-map://tiles/travel/0x1.pmtiles",
                    "prepareme-map://app/travel/0.pmtiles", "prepareme-map://tiles/other.pmtiles"] {
            XCTAssertNil(served(bad), bad)
        }
    }

    func testTheMapCoversEveryFileAndStartsAtHome() throws {
        let home = root.appendingPathComponent("home.pmtiles")
        let far = root.appendingPathComponent("far.pmtiles")
        try mapFile().write(to: home)
        try mapFile(box: [-1_247_000_000, 455_000_000, -1_169_000_000, 490_000_000], maxZoom: 14).write(to: far)
        let homeInfo = try XCTUnwrap(StreetMap.info(home))
        let both = try XCTUnwrap(StreetMap.covering([homeInfo, try XCTUnwrap(StreetMap.info(far))]))
        XCTAssertEqual([both.west, both.south, both.east, both.north], [-124.7, 38.8, -76.9, 49.0])
        XCTAssertEqual([both.centerLongitude, both.centerLatitude], [homeInfo.centerLongitude, homeInfo.centerLatitude])
        XCTAssertEqual([both.centerZoom, both.minZoom, both.maxZoom], [10, 0, 15])
        XCTAssertEqual(StreetMap.covering([homeInfo]), homeInfo)
        XCTAssertNil(StreetMap.covering([]))
    }

    /// The page's stacking (app/StreetMapAssets/web/stack.js), run in JavaScriptCore with made-up files: each tile
    /// comes from the first file that holds it, the home file first, so where two files overlap one tile is drawn.
    func testEachTileComesFromTheFirstFileThatHoldsIt() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StreetMapAssets/web/stack.js")
        let context = try XCTUnwrap(JSContext())
        var problem: String?
        context.exceptionHandler = { _, value in problem = value?.toString() }
        context.evaluateScript(try String(contentsOf: script, encoding: .utf8))
        XCTAssertNil(problem)
        context.evaluateScript("""
            var asked = [];
            function file(name, held) {
              return { getZxy: function (z, x, y) {
                asked.push(name + " " + z + "/" + x + "/" + y);
                var key = z + "/" + x + "/" + y;
                return Promise.resolve(held[key] ? { data: new Uint8Array(held[key]).buffer } : undefined);
              } };
            }
            var home = file("home", { "5/1/2": [1, 1], "6/2/4": [1] });
            var dc = file("dc", { "5/1/2": [2, 2, 2], "5/9/9": [2] });
            var got = {};
            var stack = pmStack.protocol([home, dc]);
            ["5/1/2", "5/9/9", "7/0/0"].forEach(function (key) {
              stack({ url: "pmstack://" + key }, { signal: undefined }).then(function (answer) {
                got[key] = Array.from(answer.data);
              });
            });
            """)
        XCTAssertNil(problem)
        let got = try XCTUnwrap(context.objectForKeyedSubscript("got").toDictionary() as? [String: [Int]])
        XCTAssertEqual(got["5/1/2"], [1, 1], "the home file's tile, where both hold one")
        XCTAssertEqual(got["5/9/9"], [2], "a travel file's tile where the home file has none")
        XCTAssertEqual(got["7/0/0"], [], "an empty tile where no file has one")
        let asked = try XCTUnwrap(context.objectForKeyedSubscript("asked").toArray() as? [String])
        XCTAssertFalse(asked.contains("dc 5/1/2"), "the travel file isn't even read where the home file has the tile")
        let source = context.evaluateScript("""
            JSON.stringify(pmStack.source({ type: "vector", url: "pmtiles://x", attribution: "© OpenStreetMap" },
                                          [-124.7, 38.8, -76.9, 49], 15))
            """)?.toString()
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((source ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(parsed["tiles"] as? [String], ["pmstack://{z}/{x}/{y}"])
        XCTAssertEqual(parsed["attribution"] as? String, "© OpenStreetMap", "OpenStreetMap's credit stays")
        XCTAssertEqual(parsed["maxzoom"] as? Int, 15)
        XCTAssertEqual(parsed["bounds"] as? [Double], [-124.7, 38.8, -76.9, 49])
        XCTAssertNil(parsed["url"])
        XCTAssertNil(problem)
    }

    // MARK: Words, and the backup

    func testTheThreeLimitsAreSaidOnTheScreenInTheseWords() {
        XCTAssertEqual(TravelMaps.limits, [
            "Taking a map from iCloud needs internet: do it before you leave.",
            "Turn-by-turn directions come from Organic Maps: download the same states there too.",
            "A map is as old as the day the Mac made it. Its date shows under it.",
        ])  // shortened in beta run 2 (B2-17): the same three limits, one short line each
        XCTAssertEqual(TravelMaps.waitForICloud, "Not in the folder whole yet: iCloud is still bringing it from the "
                       + "Mac. Wait a while with internet on, then try again.")
        let held = TravelHeld(entry: TravelMaps.Entry(state: "WA", name: TravelMaps.fileName("WA"), build: "20261014",
                                                      size: 2_400_000_000, sha256: String(repeating: "a", count: 64),
                                                      made: "x"), file: "f")
        XCTAssertEqual(TravelMaps.title(held.entry), "Washington")
        XCTAssertEqual(TravelMaps.heldLine(held), "OpenStreetMap as of 2026-10-14, 2.4 GB.")
    }

    func testTheBackupLeavesTheTravelFolderOut() throws {
        XCTAssertNotEqual(TravelMaps.folderName, Backup.folderName)
        XCTAssertFalse(TravelMaps.folderName.hasPrefix(Backup.folderName + "/"))
        XCTAssertTrue(Backup.readMe.contains("travel street maps"), "the Read me first page says they aren't there")
        XCTAssertTrue(Backup.readMe.contains(TravelMaps.folderName))
        // a travel map dropped into the backup folder by hand is neither copied, named nor removed: it isn't the
        // backup's own (and the delivery never lists one)
        let backup = root.appendingPathComponent("PrepareMe Backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let daily = Manifest.Entry(name: "prepareme-daily.zim", id: "0f1e2d3c-4b5a-4968-8776-6554433221a1",
                                   kind: "library", size: 4, sha256: String(repeating: "a", count: 64),
                                   deliveredAt: "2026-10-20T12:00:00-04:00")
        let plan = Backup.plan(delivery: Manifest(writtenAt: "x", files: [daily]),
                               held: ["prepareme-daily.zim": HeldFile(entry: daily, file: "copy")], backup: nil,
                               present: [TravelMaps.fileName("DC"): 10])
        XCTAssertEqual(plan.final.map(\.name), ["prepareme-daily.zim"])
        XCTAssertEqual(plan.removals, [])
        XCTAssertFalse(plan.copies.contains { TravelMaps.isFileName($0.entry.name) })
    }
}
