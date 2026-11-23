import PrepareMeShared
import XCTest

/// The rally view's fixed words when the street map file isn't on the phone (the beta run's F04; owner, 2026-10-16:
/// rally points show anyway).
final class RallyWordsTests: XCTestCase {
    func testWithoutTheMapFile() {
        XCTAssertEqual(RallyWords.mapNotHere(), "The map itself isn't on this phone. Get it at home under Downloads.")
        XCTAssertEqual(RallyWords.mapNotHere(device: "iPad"),
                       "The map itself isn't on this iPad. Get it at home under Downloads.")
    }

    func testNoRallyPoint() {
        XCTAssertEqual(RallyWords.noRallyPoint(.child), "No meeting place yet. They are added on an adult's phone or on the Mac.")
        XCTAssertEqual(RallyWords.noRallyPoint(.adult), "No meeting place yet. Add one on the street map, once the map is on this phone.")
    }

    /// A phone with no copy of the Mac's lists yet (never fetched, or the look after pairing failed) hasn't been told
    /// it has no rally point, and isn't known to be a child's (phase 2 review).
    func testNoCopyYetIsNeitherAChildNorNoRallyPoint() {
        XCTAssertEqual(RallyWords.role(hasCopy: false, canEdit: false), .noCopy)
        XCTAssertEqual(RallyWords.role(hasCopy: true, canEdit: false), .child)
        XCTAssertEqual(RallyWords.role(hasCopy: true, canEdit: true), .adult)
        XCTAssertEqual(RallyWords.noRallyPoint(.noCopy),
                       "The meeting places haven't reached this phone yet. They come from the Mac, at home on Wi-Fi.")
        XCTAssertEqual(RallyWords.noRallyPoint(.noCopy, device: "iPad"),
                       "The meeting places haven't reached this iPad yet. They come from the Mac, at home on Wi-Fi.")
    }

    /// Remaining-findings plan, Task 11.1 (F22): a child who opens the full map can go back to the rally view.
    func testAChildCanGoBackToTheSimpleView() {
        XCTAssertEqual(RallyWords.screen(hasMapFile: true, hasCopy: true, canEdit: false, mapAsked: false), .rally(.child))
        XCTAssertEqual(RallyWords.screen(hasMapFile: true, hasCopy: true, canEdit: false, mapAsked: true),
                       .map(backToRally: true))
        XCTAssertEqual(RallyWords.screen(hasMapFile: true, hasCopy: true, canEdit: true, mapAsked: false),
                       .map(backToRally: false), "an adult's phone opens on the map, with nothing to go back to")
        XCTAssertEqual(RallyWords.screen(hasMapFile: false, hasCopy: true, canEdit: false, mapAsked: true), .rally(.child))
        XCTAssertEqual(RallyWords.screen(hasMapFile: true, hasCopy: false, canEdit: false, mapAsked: false),
                       .map(backToRally: false), "a phone not yet told its role sees the map, as before")
    }

    /// Task 11.4 (F26): a grey "I'm lost" says why, and what to do, in a child's words.
    func testImLostSaysWhyItIsGrey() {
        XCTAssertEqual(RallyWords.lostWaits(),
                       "This works once the phone knows where it is. Go outside if you can and wait a minute.")
        XCTAssertTrue(RallyWords.lostWaits(device: "iPad").contains("once the iPad knows"))
    }

    /// "Nearest:" under the planned rally point (the street map fixes plan, task 1.3): only when another rally point is
    /// nearer than the planned one; routes never count.
    func testTheNearestLineIsShownOnlyWhenItDiffersFromThePlanned() {
        let home = MapMark(id: 1, kind: .rally, name: "Corner park", points: [[-77.02, 38.90]], role: .nearHome)
        let lot = MapMark(id: 2, kind: .rally, name: "Library lot", points: [[-77.04, 38.92]], role: .neighborhood)
        let road = MapMark(id: 3, kind: .route, name: "Route north", points: [[-77.041, 38.90], [-77.041, 38.93]])
        let nearLot = (38.915, -77.035)
        let ways = Position.ways(from: nearLot, to: [home, lot, road])
        XCTAssertEqual(RallyWords.nearestLine(ways, planned: home.id), "Nearest: Library lot, 0.4 miles northwest")
        XCTAssertNil(RallyWords.nearestLine(ways, planned: lot.id), "the planned one is the nearest")
        XCTAssertNil(RallyWords.nearestLine(Position.ways(from: nearLot, to: [home, road]), planned: home.id),
                     "a nearer route is not a rally point")
    }
}
