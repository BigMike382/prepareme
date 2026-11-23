import Foundation
import PrepareMeShared
import XCTest

/// The street map's file on a device (plan phase 9): fetched only when asked for, checked by size, SHA-256 and its own
/// PMTiles check in place of the reader's ZIM checks, kept under a name of its own, and never handed to the reader.
@MainActor
final class StreetMapTests: XCTestCase {
    var root: URL!
    var reader: FakeReader!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-streetmap-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = FakeReader()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A made-up map file: a PMTiles header with empty directories, then `tiles` as its tile data to the file's end.
    func mapFile(_ tiles: String = "tile bytes") -> Data {
        var head = Data("PMTiles".utf8) + Data([3])
        func put(_ n: UInt64) { withUnsafeBytes(of: n.littleEndian) { head.append(contentsOf: $0) } }
        for n in [127, 0, 127, 0, 127, 0, 127, UInt64(tiles.utf8.count), 1, 1, 1] as [UInt64] { put(n) }
        head.append(contentsOf: [1, 2, 2, 1, 0, 15] + [UInt8](repeating: 0, count: 16 + 1 + 8))
        XCTAssertEqual(head.count, 127)
        return head + Data(tiles.utf8)
    }

    func entry(for data: Data, name: String = StreetMap.fileName) throws -> Manifest.Entry {
        let file = root.appendingPathComponent("scratch-\(UUID())")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return Manifest.Entry(name: name, id: "prepareme-street-map", kind: "map", size: Int64(data.count),
                              sha256: try FileCheck.sha256(of: file), deliveredAt: "2026-10-14T12:00:00Z",
                              title: "Street map: Example State and its neighbors")
    }

    func store(zimProblem: String? = "the reader's ZIM check ran") -> LibraryStore {
        let made = LibraryStore(root: root, reader: reader, zimProblem: { _, _ in zimProblem })
        made.prepareFolders()
        return made
    }

    func testAWholeMapFilePassesAndACutOrForeignOneDoesNot() throws {
        let file = root.appendingPathComponent("map.pmtiles")
        try mapFile().write(to: file)
        XCTAssertNil(StreetMap.problem(file))
        try mapFile().dropLast(3).write(to: file)
        XCTAssertNotNil(StreetMap.problem(file), "cut short")
        try (mapFile() + Data("extra".utf8)).write(to: file)
        XCTAssertNotNil(StreetMap.problem(file), "longer than its parts")
        try Data("ZIM\u{4}not a map file at all, but long enough to read a header from...........................".utf8)
            .write(to: file)
        XCTAssertNotNil(StreetMap.problem(file))
        XCTAssertNotNil(StreetMap.problem(root.appendingPathComponent("missing.pmtiles")))
    }

    /// A made-up map file whose header says it covers -78 to -76 longitude, 35 to 37 latitude, zooms 0 to 15, and
    /// starts at (-77, 36) at zoom 10.
    func placedMapFile() -> Data {
        var file = mapFile()
        func put(_ value: Int32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { file.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        for (value, offset) in [(-780_000_000, 102), (350_000_000, 106), (-760_000_000, 110), (370_000_000, 114),
                                (-770_000_000, 119), (360_000_000, 123)] as [(Int32, Int)] {
            put(value, at: offset)
        }
        file[118] = 10
        return file
    }

    func testTheFileSaysWhereItIsAndTheViewIsHeldToIt() throws {
        let file = root.appendingPathComponent("map.pmtiles")
        try placedMapFile().write(to: file)
        let info = try XCTUnwrap(StreetMap.info(file))
        XCTAssertEqual([info.west, info.south, info.east, info.north], [-78, 35, -76, 37])
        XCTAssertEqual([info.centerZoom, info.minZoom, info.maxZoom], [10, 0, 15])
        XCTAssertEqual(StreetMap.Camera.start(info), StreetMap.Camera(longitude: -77, latitude: 36, zoom: 10))
        let far = StreetMap.Camera(longitude: -100, latitude: 50, zoom: 30, bearing: 400, pitch: 80).held(to: info)
        XCTAssertEqual(far, StreetMap.Camera(longitude: -78, latitude: 37, zoom: 18, bearing: 40, pitch: 60))
        XCTAssertEqual(StreetMap.Camera(longitude: .nan, latitude: 36, zoom: 12).held(to: info), .start(info))
        try mapFile().dropLast().write(to: file)
        XCTAssertNil(StreetMap.info(file), "a cut file says nothing")
    }

    /// Follow me (the street map fixes plan, task 1.2): Find me with a fix starts it; a drag, or Find me again, ends
    /// it, so the map never pulls back from under a finger (review focus 2).
    func testFollowStartsOnFindMeAndEndsOnADrag() {
        var follow = StreetMap.Follow()
        XCTAssertFalse(follow.on)
        follow.tapFindMe(hasFix: false)
        XCTAssertFalse(follow.on, "no fix: nothing to follow")
        follow.tapFindMe(hasFix: true)
        XCTAssertTrue(follow.on)
        follow.dragged()
        XCTAssertFalse(follow.on, "a drag frees the map")
        follow.dragged()
        XCTAssertFalse(follow.on, "a second drag changes nothing")
        follow.tapFindMe(hasFix: true)
        XCTAssertTrue(follow.on, "Find me after a drag follows again")
        follow.tapFindMe(hasFix: true)
        XCTAssertFalse(follow.on, "Find me again ends it")
    }

    func testTheLastViewIsKeptBetweenUses() throws {
        let file = root.appendingPathComponent("map.pmtiles")
        try placedMapFile().write(to: file)
        let info = try XCTUnwrap(StreetMap.info(file))
        let suite = "prepareme-streetmap-test-\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let memory = StreetMap.Memory(defaults: { UserDefaults(suiteName: suite)! })
        XCTAssertEqual(memory.camera(for: info), .start(info), "nothing kept yet")
        let seen = StreetMap.Camera(longitude: -76.5, latitude: 35.5, zoom: 14.5, bearing: 30, pitch: 20)
        memory.keep(seen)
        XCTAssertEqual(StreetMap.Memory(defaults: { UserDefaults(suiteName: suite)! }).camera(for: info), seen)
    }

    func testItIsFetchedOnlyWhenAskedForAndTheMacAppTakesIt() throws {
        let map = try entry(for: mapFile())
        let list = Manifest(writtenAt: "2026-10-14T12:00:00Z", files: [map])
        var state = LibraryRecord()
        XCTAssertEqual(LibraryPlan.toFetch(list, state).map(\.name), [])
        state.requested = [StreetMap.fileName]
        XCTAssertEqual(LibraryPlan.toFetch(list, state).map(\.name), [StreetMap.fileName])
        XCTAssertEqual(LibraryPlan.toFetch(list, LibraryRecord(), everyKind: true).map(\.name), [StreetMap.fileName])
        XCTAssertTrue(LibraryPlan.fileName(map).hasSuffix(".pmtiles"))
        XCTAssertTrue(LibraryPlan.fileName(map).hasPrefix("prepareme-street-map.\(map.sha256.prefix(12))"))
        var other = map
        other.name = "other.pmtiles"  // only the street map's own name is a map file
        XCTAssertEqual(LibraryPlan.toFetch(Manifest(writtenAt: "x", files: [other]),
                                           LibraryRecord(requested: ["other.pmtiles"])).map(\.name), [])
    }

    func testACheckedMapIsKeptWithoutTheReaderAndANewOneReplacesIt() async throws {
        let store = store()
        let first = mapFile("first tiles")
        let one = try entry(for: first)
        store.request(one)
        try first.write(to: store.incoming(one))
        XCTAssertEqual(store.incoming(one).pathExtension, "pmtiles")
        store.handOver(one)
        await store.checkWaiting()
        XCTAssertEqual(store.record.held[StreetMap.fileName]?.entry, one, "the ZIM check never ran on it")
        XCTAssertEqual(reader.registered, [])
        XCTAssertEqual(reader.swaps, 0)
        XCTAssertEqual(StreetMap.heldFile(store.record, in: store.libraryFolder).map { try? Data(contentsOf: $0) },
                       first)

        let second = mapFile("second tiles, newer")
        let two = try entry(for: second)
        try second.write(to: store.incoming(two))
        store.handOver(two)
        await store.checkWaiting()
        XCTAssertEqual(store.record.held[StreetMap.fileName]?.entry, two)
        let kept = (try FileManager.default.contentsOfDirectory(atPath: store.libraryFolder.path)).sorted()
        XCTAssertEqual(kept, [LibraryPlan.fileName(two)])
        XCTAssertEqual(reader.registered, [])
    }

    func testABadMapIsRefusedAndTheHeldOneKept() async throws {
        let store = store()
        let good = mapFile()
        let one = try entry(for: good)
        store.request(one)
        try good.write(to: store.incoming(one))
        store.handOver(one)
        await store.checkWaiting()
        let cut = Data(mapFile("a longer set of tiles").dropLast(4))
        let bad = try entry(for: cut)  // its list entry matches the bytes, but they aren't a whole map
        try cut.write(to: store.incoming(bad))
        store.handOver(bad)
        await store.checkWaiting()
        XCTAssertEqual(store.record.held[StreetMap.fileName]?.entry, one)
        XCTAssertEqual(store.record.refusals[bad.sha256], 1)
    }

    func testRemoveTakesItOffWithoutTheReaderAndTheTidyUpLeavesItAlone() async throws {
        let store = store()
        let data = mapFile()
        let map = try entry(for: data)
        store.request(map)
        try data.write(to: store.incoming(map))
        store.handOver(map)
        await store.checkWaiting()
        store.read(Manifest(writtenAt: "2026-10-14T12:00:00Z", files: [map]), at: Date())
        await store.reconcile()
        XCTAssertNotNil(store.record.held[StreetMap.fileName], "the tidy-up keeps a map the reader doesn't know")
        XCTAssertEqual(reader.registered, [])
        let removed = await store.remove(StreetMap.fileName)
        XCTAssertTrue(removed)
        XCTAssertEqual(reader.removed, [])
        XCTAssertNil(StreetMap.heldFile(store.record, in: store.libraryFolder))
        XCTAssertEqual(LibraryPlan.toFetch(store.record.manifest!, store.record).map(\.name), [])
    }
    func testTheWatchdogReloadsAStalledOrSilentPageOnly() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func at(_ s: Double) -> Date { start.addingTimeInterval(s) }
        var dog = StreetMap.Watchdog()
        dog.started(now: start)
        XCTAssertFalse(dog.report(tilesLoaded: false, served: 10, now: at(5)), "loading starts")
        XCTAssertFalse(dog.report(tilesLoaded: false, served: 12, now: at(10)), "a tile came: still loading")
        XCTAssertFalse(dog.report(tilesLoaded: false, served: 12, now: at(15)))
        XCTAssertFalse(dog.report(tilesLoaded: false, served: 12, now: at(20)), "not yet 15 s with nothing served")
        XCTAssertTrue(dog.report(tilesLoaded: false, served: 12, now: at(25)), "15 s, nothing served: reload")
        XCTAssertFalse(dog.report(tilesLoaded: false, served: 12, now: at(30)))
        XCTAssertFalse(dog.report(tilesLoaded: false, served: 12, now: at(46)), "never twice within 30 s")
        XCTAssertTrue(dog.report(tilesLoaded: false, served: 12, now: at(60)), "still stalled after the settle time")
        var fine = StreetMap.Watchdog()
        fine.started(now: start)
        for n in 1...20 {
            XCTAssertFalse(fine.report(tilesLoaded: true, served: 3, now: at(Double(n) * 5)))
            XCTAssertFalse(fine.quiet(now: at(Double(n) * 5 + 1)))
        }
        XCTAssertFalse(fine.quiet(now: at(110)), "heard 10 s ago")
        XCTAssertFalse(fine.quiet(now: at(115)))
        XCTAssertTrue(fine.quiet(now: at(120)), "20 s with no report: the page's process is gone")
        XCTAssertFalse(fine.quiet(now: at(125)), "the reload it asked for gets its time")
    }

    /// An audit, 2026-10-14: a page that never comes up is reloaded too, ever more slowly; a pause in the background
    /// or off screen is never a stall.
    func testTheWatchdogBacksOffAndIgnoresPauses() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func at(_ s: Double) -> Date { start.addingTimeInterval(s) }
        var dead = StreetMap.Watchdog()
        dead.started(now: start)
        var reloads: [Double] = []
        for t in stride(from: 0.0, through: 900, by: 5) where dead.quiet(now: at(t)) { reloads.append(t) }
        XCTAssertEqual(reloads, [20, 50, 110, 230, 470], "each wait twice the last: 30 s, 1, 2, then 4 minutes")
        dead.up(now: at(905))
        XCTAssertEqual(dead.wait, 30, "the map came up: back to the first wait")

        var paused = StreetMap.Watchdog()
        paused.started(now: start)
        XCTAssertFalse(paused.quiet(now: at(5)))
        XCTAssertFalse(paused.quiet(now: at(300)), "back from the background: listening starts again")
        XCTAssertFalse(paused.quiet(now: at(305)))
        XCTAssertFalse(paused.quiet(watching: false, now: at(310)), "off screen: nothing judged")
        XCTAssertFalse(paused.quiet(now: at(400)), "back on screen")
        XCTAssertTrue(paused.ended(now: at(401)), "its process ended")
        XCTAssertFalse(paused.ended(now: at(402)), "not again at once; the quiet check tries later")
    }

    func testALinksAreaIsFourNumbersInOrder() {
        XCTAssertEqual(StreetMap.area("-80.5,35.25,-80.375,35.375"), [-80.5, 35.25, -80.375, 35.375])
        XCTAssertNil(StreetMap.area(nil))
        XCTAssertNil(StreetMap.area("-80.5,35.25,-80.375"), "three numbers")
        XCTAssertNil(StreetMap.area("-80.375,35.25,-80.5,35.375"), "west past east")
        XCTAssertNil(StreetMap.area("-80.5,35.25,-80.375,nan"))
        XCTAssertNil(StreetMap.area("-80.5,95,-80.375,96"), "off the globe")
        XCTAssertNil(StreetMap.area("1,2,3,4,5"))
    }

    /// Remaining-findings plan, Task 11.2 (F23): a tap opens "This spot" only on something; a long press anywhere.
    func testATapOnNothingOpensNothing() {
        XCTAssertFalse(MapTap.opensSpot(layers: [], longPress: false), "a stray tap")
        XCTAssertTrue(MapTap.opensSpot(layers: ["pm-pin"], longPress: false), "a pin or a rally point")
        XCTAssertTrue(MapTap.opensSpot(layers: [], longPress: true), "a long press drops a pin")
        XCTAssertFalse(MapTap.opensSpot(layers: [MapTap.warningLayer], longPress: false), "a warning covers the map")
        XCTAssertTrue(MapTap.opensSpot(layers: [MapTap.warningLayer, "pm-gauge"], longPress: false), "a gauge in it")
        XCTAssertTrue(MapTap.opensSpot(layers: [MapTap.warningLayer], longPress: true))
    }

    /// A refused location offers the way to turn it on, and the first ask comes with its why line (Task 11.3; F25, F66).
    func testRefusedLocationOffersSettings() {
        XCTAssertEqual(LocationAsk.offer(.refused), .settings)
        XCTAssertEqual(LocationAsk.offer(.notAsked), .ask)
        XCTAssertEqual(LocationAsk.offer(.allowed), .none)
        XCTAssertEqual(LocationAsk.line(.notAsked), LocationAsk.why)
        XCTAssertTrue(LocationAsk.why.contains("where you are on the map"), LocationAsk.why)
        XCTAssertEqual(LocationAsk.why, "This uses your location to show where you are on the map, and the weather there. "
                       + "It works with no signal.", "B2-17: no app name inside the app")
        XCTAssertTrue(LocationAsk.line(.refused).contains("Settings"), LocationAsk.line(.refused))
        XCTAssertEqual(LocationAsk.turnOn, "Turn on location")
    }

    /// Where am I with no fix: the system's question while unasked, the refusal and its way back when refused, else it
    /// waits for the fix (it used to do nothing when refused; F66).
    func testWhereAmIExplainsARefusal() {
        XCTAssertEqual(LocationAsk.whereAmI(.refused), .explainRefusal)
        XCTAssertEqual(LocationAsk.whereAmI(.notAsked), .ask)
        XCTAssertEqual(LocationAsk.whereAmI(.allowed), .wait)
    }

    /// Cancel throws a short route away at once and asks first past a few points; the hint says the route joins the
    /// clicks with straight lines (Task 11.7; F30).
    func testCancelAsksBeforeLosingAFewPoints() {
        XCTAssertFalse(RouteDrawing.cancelAsks(points: 0))
        XCTAssertFalse(RouteDrawing.cancelAsks(points: 5), "five points cost little to redo")
        XCTAssertTrue(RouteDrawing.cancelAsks(points: 6))
        XCTAssertTrue(RouteDrawing.discardTitle(points: 20).contains("20 points"), RouteDrawing.discardTitle(points: 20))
        XCTAssertTrue(RouteDrawing.hint(points: 0).contains("every bend"), RouteDrawing.hint(points: 0))
        XCTAssertTrue(RouteDrawing.hint(points: 3).hasPrefix("3 points."), RouteDrawing.hint(points: 3))
        XCTAssertFalse(RouteDrawing.hint(points: 3).contains("along the roads"), "it doesn't follow the roads")
    }

    /// The strip holds its route (the street map fixes plan, task 2.2; the review's silent swap): walking past where
    /// the alternate crosses nearer, the main stays named (review focus 4).
    func testTheStripNeverSwapsRoutesByItself() {
        let main = MapMark(id: 1, kind: .route, name: "Main", points: [[-40, 10], [-40, 10.1]], routeRole: .main)
        let alternate = MapMark(id: 2, kind: .route, name: "Alternate", points: [[-40.01, 10], [-39.99, 10.1]],
                                routeRole: .alternate)
        for latitude in stride(from: 10.0, through: 10.1, by: 0.01) {
            let here = (latitude, -39.995)
            let ways = Position.ways(from: here, to: [main, alternate])
            XCTAssertEqual(Position.chosenRoute(ways, alternate: false)?.mark.id, 1, "at \(latitude)")
            XCTAssertEqual(Position.chosenRoute(ways, alternate: true)?.mark.id, 2, "at \(latitude)")
        }
        XCTAssertEqual(StreetMap.useAlternate, "Use the alternate")
        XCTAssertEqual(StreetMap.backToMain, "Back to the main route")
        XCTAssertTrue(StreetMap.routeRoles.contains(StreetMap.useAlternate), "the Mac names the phones' button")
    }

    func testThePhonesPDFWords() {
        XCTAssertEqual(StreetMap.makingPDF, "Making the PDF…")
        XCTAssertEqual(StreetMap.pdfNotReady, "Couldn't make the PDF: the map wasn't ready. Try again in a moment.")
    }
}
