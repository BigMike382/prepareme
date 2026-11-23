import Foundation
@testable import PrepareMeShared
import XCTest

/// Where the phone is, and the way to each rally point (plan phase 9). The USNG references are GeographicLib's
/// (GeoConvert 2.5.2, its online converter, 2026-10-14; MGRS truncated to 1 m, written the USNG way), for points from
/// Washington to Hawaii and Alaska, two on either side of the 17/18 zone line at 78° W, and a zone's central meridian.
final class PositionTests: XCTestCase {
    func testUSNGMatchesGeographicLib() {
        let reference: [(Double, Double, String)] = [
            (38.8895, -77.0352, "18S UJ 23486 06483"),
            (35.7796, -78.6382, "17S QV 13473 62076"),
            (35.5951, -82.5515, "17S LV 59450 40148"),
            (36.5, -75.5, "18S VF 55222 39524"),
            (35.0, -84.0, "17S KU 26201 77156"),
            (24.55, -81.8, "17R MH 18978 15356"),
            (47.6, -122.3, "10T ET 52619 72080"),
            (61.2, -149.9, "6V UN 44173 88521"),
            (21.3, -157.85, "4Q FJ 19283 55784"),
            (40.0, -102.0, "14T KK 43900 32069"),
            (33.99999, -78.000001, "17S QT 77091 66213"),
            (34.0, -78.0, "18S TC 22908 66214"),
            (36.58812, -81.67951, "17S MA 39214 49397"),
            (31.0, -88.0, "16R DV 04531 30031"),
            (45.0, -69.0, "19T EK 00000 82950"),
        ]
        for (latitude, longitude, expected) in reference {
            XCTAssertEqual(Position.usng(latitude, longitude), expected, "\(latitude), \(longitude)")
        }
    }

    func testFewerDigitsTruncateAndThePolesAreLeftOut() {
        XCTAssertEqual(Position.usng(38.8895, -77.0352, digits: 4), "18S UJ 2348 0648")
        XCTAssertEqual(Position.usng(38.8895, -77.0352, digits: 1), "18S UJ 2 0")
        XCTAssertNil(Position.usng(85, 10))
        XCTAssertNil(Position.usng(-81, 10))
        XCTAssertNil(Position.usng(.nan, 10))
    }

    func testLatitudeAndLongitudeReadOut() {
        XCTAssertEqual(Position.latLon(35.7796, -78.6382), "35.77960° N, 78.63820° W")
        XCTAssertEqual(Position.latLon(-21.3, 157.85), "21.30000° S, 157.85000° E")
    }

    func testDistanceAndDirection() {
        let degree = Position.meters(from: (35, -78), to: (36, -78))
        XCTAssertEqual(degree, 111_195, accuracy: 10)  // a degree of latitude on the mean sphere
        XCTAssertEqual(Position.bearing(from: (35, -78), to: (36, -78)), 0, accuracy: 0.001)
        XCTAssertEqual(Position.bearing(from: (0, 0), to: (0, 1)), 90, accuracy: 0.001)
        XCTAssertEqual(Position.bearing(from: (35, -78), to: (34, -78)), 180, accuracy: 0.001)
        XCTAssertEqual(Position.compass(44), "northeast")
        XCTAssertEqual(Position.compass(350), "north")
        XCTAssertEqual(Position.compass(181), "south")
        XCTAssertEqual(Position.distance(3700), "2.3 miles")
        XCTAssertEqual(Position.distance(130), "430 feet")
        XCTAssertEqual(Position.distance(40_000), "25 miles")
    }

    func testRallyPointsAndRoutesNearestFirst() {
        let near = MapMark(id: 1, kind: .rally, name: "Near", points: [[-40.0, 10.01]])
        let far = MapMark(id: 2, kind: .rally, name: "Far", points: [[-40.0, 10.5]])
        // a route passing 0.02° east of here (about 2.2 km; Near is about 1.1 km north), its middle the nearest part
        let route = MapMark(id: 3, kind: .route, name: "Road out", points: [[-39.98, 9.9], [-39.98, 10.1]])
        let ways = Position.ways(from: (10, -40), to: [far, route, near])
        XCTAssertEqual(ways.map(\.mark.name), ["Near", "Road out", "Far"])
        XCTAssertEqual(ways[1].nearest[1], 10, accuracy: 1e-9, "the route's nearest spot is level with here")
        XCTAssertEqual(ways[1].bearing, 90, accuracy: 0.5)
        XCTAssertEqual(ways[0].words, "Near: 0.7 miles north")
    }

    func testOldOrUnknownFixesAreRefusedAndTheirQualityIsSaid() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(Position.usable(accuracy: 8, taken: now.addingTimeInterval(-5), now: now))
        XCTAssertFalse(Position.usable(accuracy: 8, taken: now.addingTimeInterval(-3 * 3600), now: now), "iOS's saved one")
        XCTAssertFalse(Position.usable(accuracy: -1, taken: now, now: now), "no fix at all")
        XCTAssertEqual(Position.fix(accuracy: 4.6, taken: now, now: now), "Within 15 feet")
        XCTAssertEqual(Position.fix(accuracy: 1, taken: now, now: now), "Within 10 feet")
        XCTAssertEqual(Position.fix(accuracy: 30, taken: now.addingTimeInterval(-70), now: now),
                       "Within 100 feet, 1 minute ago")
        XCTAssertEqual(Position.fix(accuracy: 400, taken: now.addingTimeInterval(-6 * 60), now: now),
                       "Within 0.2 miles, 6 minutes ago")
    }

    /// A kept fix grays at half a minute and is stale at two (the street map fixes plan, task 1.1); a fix that only
    /// arrives once it is that old is still refused, so the stale look stays until a fresh one comes (review focus 1).
    func testAFixAgesAt30SecondsAndIsStaleAt2Minutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Position.agingAfter, 30)
        XCTAssertEqual(Position.staleAfter, 120)
        XCTAssertEqual(Position.freshness(taken: now.addingTimeInterval(-29), now: now), .fresh)
        XCTAssertEqual(Position.freshness(taken: now.addingTimeInterval(-30), now: now), .aging)
        XCTAssertEqual(Position.freshness(taken: now.addingTimeInterval(-119), now: now), .aging)
        XCTAssertEqual(Position.freshness(taken: now.addingTimeInterval(-120), now: now), .stale)
        XCTAssertEqual(Position.freshness(taken: now.addingTimeInterval(-3 * 3600), now: now), .stale)
        XCTAssertFalse(Position.usable(accuracy: 8, taken: now.addingTimeInterval(-180), now: now),
                       "a late fix after a long gap is refused: the old one stays, stale")
    }

    func testTheStaleBannerNamesTheMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func banner(_ minutes: Double) -> String { Position.staleWords(taken: now.addingTimeInterval(-minutes * 60), now: now) }
        XCTAssertEqual(banner(1), "GPS lost 1 minute ago. Distances are from where you were.")
        XCTAssertEqual(banner(4.5), "GPS lost 4 minutes ago. Distances are from where you were.")
        XCTAssertEqual(banner(61), "GPS lost 1 h 1 min ago. Distances are from where you were.")
        XCTAssertEqual(banner(120), "GPS lost 2 h ago. Distances are from where you were.")
        // the folded strip's short age after the distance, from a minute on
        XCTAssertNil(Position.ageBrief(taken: now.addingTimeInterval(-59), now: now))
        XCTAssertEqual(Position.ageBrief(taken: now.addingTimeInterval(-4 * 60), now: now), "4 min ago")
        XCTAssertEqual(Position.ageBrief(taken: now.addingTimeInterval(-61 * 60), now: now), "1 h 1 min ago")
    }

    /// GPS eases to about 10 m after a good fix, or after a minute of fixes even when none got that good (the street
    /// map fixes plan, task 1.4; the review: under trees it never eased, at best accuracy all walk).
    func testGPSEasesAfterAMinuteOfRoughFixes() {
        XCTAssertEqual(Position.easeAfter, 60)
        XCTAssertTrue(Position.shouldEase(bestAccuracy: 12, sinceFirstFix: 2), "a good fix: at once")
        XCTAssertTrue(Position.shouldEase(bestAccuracy: 25, sinceFirstFix: 0))
        XCTAssertFalse(Position.shouldEase(bestAccuracy: 40, sinceFirstFix: 59), "rough, under a minute: keep trying")
        XCTAssertTrue(Position.shouldEase(bestAccuracy: 40, sinceFirstFix: 60), "rough for a minute: ease anyway")
    }

    /// The Mac's Where am I line with no fix to show (Mac sidebar plan, task 12): its exact words, and the age past
    /// which a fix leaves its screen (`freshFix`, the same as the phone's).
    func testTheMacSaysPlainlyWhenItCantTell() {
        XCTAssertEqual(Position.macNoFix, "This Mac can't tell where it is right now.")
        XCTAssertEqual(Position.macLocationOff, "Location is off for PrepareMe: turn it on in System Settings › "
                       + "Privacy & Security › Location Services.", "location off for PrepareMe")
        XCTAssertEqual(Position.freshFix, 120)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(Position.usable(accuracy: 65, taken: now.addingTimeInterval(-Position.freshFix), now: now))
        XCTAssertFalse(Position.usable(accuracy: 65, taken: now.addingTimeInterval(-Position.freshFix - 1), now: now),
                       "older than freshFix: the line shows instead")
    }

    func testOnFootIsARangeAtTheArmysTwoRates() {
        XCTAssertEqual(Position.onFoot(1300, straightLine: true), "at least 20 to 35 min on foot")  // 19.5, 32.5 min
        XCTAssertEqual(Position.onFoot(4800, straightLine: false), "about 1 h 10 min to 2 h on foot")  // 72, 120 min
        XCTAssertEqual(Position.onFoot(50, straightLine: true), "at least 5 min on foot")
        XCTAssertEqual(Position.walkTime(9000), "2 h 15 min")
    }

    func testARoutesLengthToItsEndFromWhereYouJoinIt() throws {
        // north along a meridian: 10.0 to 10.1 to 10.2, joined level with 10.05
        let route = MapMark(id: 1, kind: .route, name: "Road out", points: [[-40, 10.0], [-40, 10.1], [-40, 10.2]])
        let way = try XCTUnwrap(Position.ways(from: (10.05, -39.99), to: [route]).first)
        XCTAssertEqual(try XCTUnwrap(way.toEnd), 0.15 * 111_195, accuracy: 30, "half the first piece and all the second")
        let point = MapMark(id: 2, kind: .rally, name: "Oak", points: [[-40, 10]])
        XCTAssertNil(Position.ways(from: (10, -40), to: [point]).first?.toEnd)
    }

    func testTheKidsArrowFollowsTheRolesAndEventMode() {
        let near = MapMark(id: 1, kind: .rally, name: "Near", points: [[-40, 10]], role: .nearHome)
        let away = MapMark(id: 2, kind: .rally, name: "Away", points: [[-41, 11]], role: .outOfTown)
        let mid = MapMark(id: 3, kind: .rally, name: "Mid", points: [[-40.5, 10.5]], role: .neighborhood)
        let plain = MapMark(id: 4, kind: .rally, name: "Plain", points: [[-40.2, 10.2]])
        let route = MapMark(id: 5, kind: .route, name: "Road", points: [[-40, 10], [-41, 11]])
        XCTAssertEqual(Position.planned([plain, away, near], eventOn: false)?.name, "Near")
        XCTAssertEqual(Position.planned([plain, away, near], eventOn: true)?.name, "Away")
        XCTAssertEqual(Position.planned([plain, near], eventOn: true)?.name, "Near", "no out-of-town point")
        XCTAssertNil(Position.planned([plain, mid, route], eventOn: false), "then the nearest")
        XCTAssertEqual(Position.plannedOrFirst([plain, away, near], eventOn: true)?.name, "Away")
        XCTAssertEqual(Position.plannedOrFirst([route, plain, mid], eventOn: false)?.name, "Mid",
                       "with no planned one, the first in role order (Today's rally line names it too, R9.1)")
        XCTAssertNil(Position.plannedOrFirst([route], eventOn: false))
        XCTAssertEqual(Position.ordered([route, plain, away, mid, near]).map(\.name),
                       ["Near", "Mid", "Away", "Plain", "Road"])
    }

    /// A new rally point starts as Near home until one has that role, and the sheet says what the role does
    /// (remaining-findings plan, Task 11.5; F27: a point with no role never reached the kids' arrow).
    func testFirstRallyPointIsNearHome() {
        let near = MapMark(id: 1, kind: .rally, name: "Near", points: [[-40, 10]], role: .nearHome)
        let plain = MapMark(id: 2, kind: .rally, name: "Plain", points: [[-40.2, 10.2]])
        let route = MapMark(id: 3, kind: .route, name: "Road", points: [[-40, 10], [-41, 11]])
        XCTAssertEqual(Position.newRallyRole([]), .nearHome, "the first")
        XCTAssertEqual(Position.newRallyRole([plain, route]), .nearHome, "none is Near home yet")
        XCTAssertNil(Position.newRallyRole([near, plain]), "Near home is taken")
        XCTAssertTrue(Position.kidsPointTo.contains("Near home"), Position.kidsPointTo)
    }

    /// The printed map's rally points are numbered as its legend lists them (Task 11.6; F29: green on grey in black and
    /// white), and the map's data carries each number.
    func testRallyPointsAreNumberedAsTheLegendListsThem() throws {
        let plain = MapMark(id: 1, kind: .rally, name: "Plain", points: [[-40.2, 10.2]])
        let route = MapMark(id: 2, kind: .route, name: "Road", points: [[-40, 10], [-41, 11]])
        let away = MapMark(id: 3, kind: .rally, name: "Away", points: [[-41, 11]], role: .outOfTown)
        let near = MapMark(id: 4, kind: .rally, name: "Near", points: [[-40, 10]], role: .nearHome)
        let marks = [plain, route, away, near]
        let numbers = Position.rallyNumbers(marks)
        XCTAssertEqual(Position.ordered(marks).compactMap { numbers[$0.id] }, [1, 2, 3], "the legend's order")
        XCTAssertEqual(numbers[near.id], 1)
        XCTAssertNil(numbers[route.id], "routes are lines, not numbered")
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: MapMark.geoJSON(marks)) as? [String: Any])
        let features = try XCTUnwrap(all["features"] as? [[String: Any]])
        let found = features.compactMap { f -> (String, Int)? in
            guard let p = f["properties"] as? [String: Any], let n = p["number"] as? Int else { return nil }
            return (p["name"] as? String ?? "", n)
        }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: found), ["Near": 1, "Away": 2, "Plain": 3])
    }

    func testTheSharedTextLeadsWithTheGridNumber() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = Position.shareText(latitude: 38.8905, longitude: -77.012, accuracy: 4.6, taken: now, now: now)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "My location (from PrepareMe):")
        XCTAssertEqual(lines[1], "USNG 18S UJ 25501 06549")
        XCTAssertEqual(lines[2], Position.latLon(38.8905, -77.012))
        XCTAssertTrue(lines[3].hasPrefix("Within 15 feet; taken "), lines[3])
    }

    /// The printed map's grid: the 1 km lines either side of a spot whose grid number is known (18S UJ 25501 06549,
    /// checked against GeographicLib in testUSNGMatchesGeographicLib's pattern) fall where the number says.
    func testTheGridsLinesFallWhereTheNumbersSay() throws {
        let (zone, lines) = Position.grid(west: -77.03, south: 38.88, east: -76.99, north: 38.90, step: 1000)
        XCTAssertEqual(zone, "18S")
        let east = try XCTUnwrap(lines.first { $0.easting && $0.meters == 325_000 })
        XCTAssertEqual(east.label, "25")
        // the spot is 501 m east of the 325 km line, at its latitude
        let at = try XCTUnwrap(east.points.min { abs($0[1] - 38.8905) < abs($1[1] - 38.8905) })
        let spot = Position.usng(at[1], at[0])!
        XCTAssertTrue(spot.hasPrefix("18S UJ 2499") || spot.hasPrefix("18S UJ 2500"), spot)
        let north = try XCTUnwrap(lines.first { !$0.easting && $0.meters == 4_306_000 })
        XCTAssertEqual(north.label, "06")
        let eastings = lines.filter(\.easting).map(\.meters)
        XCTAssertTrue((3...4).contains(eastings.count), "about 3.5 km across: \(eastings)")
        XCTAssertEqual(zip(eastings, eastings.dropFirst()).map { $1 - $0 }, Array(repeating: 1000, count: eastings.count - 1))
        XCTAssertEqual(Position.scaleMiles(fitting: 1000), 0.5)
        XCTAssertEqual(Position.scaleMiles(fitting: 50), 0.1)
    }

    /// Which route the strip names (the street map fixes plan, task 2.1): the main route, or the alternate once it is
    /// chosen; with no role, the nearest; a lone route with no role is still shown and never called main or alternate
    /// (review focus 3). Lists put routes main, alternate, then the rest.
    func testTheChosenRouteIsMainThenAlternateThenNearest() {
        let here = (10.0, -40.0)
        func line(_ id: Int64, _ latitude: Double, _ role: MapMark.RouteRole?) -> MapMark {
            MapMark(id: id, kind: .route, name: "Route \(id)", points: [[-40.01, latitude], [-39.99, latitude]],
                    routeRole: role)
        }
        let near = line(1, 10.001, nil), main = line(2, 10.01, .main), alternate = line(3, 10.005, .alternate)
        let rally = MapMark(id: 4, kind: .rally, name: "Oak", points: [[-40, 10.0001]], role: .nearHome)
        let all = Position.ways(from: here, to: [near, main, alternate, rally])
        XCTAssertEqual(Position.chosenRoute(all, alternate: false)?.mark.id, 2, "the main, though two are nearer")
        XCTAssertEqual(Position.chosenRoute(all, alternate: true)?.mark.id, 3)
        XCTAssertEqual(Position.chosenRoute(Position.ways(from: here, to: [near, main]), alternate: true)?.mark.id, 2,
                       "no alternate: the main")
        XCTAssertEqual(Position.chosenRoute(Position.ways(from: here, to: [near, line(5, 10.02, nil)]),
                                            alternate: false)?.mark.id, 1, "no roles: the nearest")
        let lone = Position.ways(from: here, to: [near])
        XCTAssertEqual(Position.chosenRoute(lone, alternate: true)?.mark.id, 1)
        XCTAssertNil(lone[0].mark.routeRole, "shown with no role word")
        XCTAssertNil(Position.chosenRoute(Position.ways(from: here, to: [rally]), alternate: false))
        XCTAssertEqual(Position.chosenRoute(Position.ways(from: here, to: [main, line(6, 10.0005, .main)]),
                                            alternate: false)?.mark.id, 2, "two mains: the first made, not the nearer")
        XCTAssertEqual(Position.ordered([near, alternate, rally, main]).map(\.id), [4, 2, 3, 1])
        XCTAssertEqual(MapMark.RouteRole.main.words, "Main route")
        XCTAssertEqual(MapMark.RouteRole.alternate.words, "Alternate route")
        XCTAssertTrue(Position.canSwitchRoutes([near, main, alternate]))
        XCTAssertFalse(Position.canSwitchRoutes([near, main]), "the button shows only when both are marked")
    }

    /// Off the route by more than about a block (task 2.2): how far and which way back, in caution amber; under 300
    /// feet nothing, as a fix wanders that much; never for a rally point.
    func testOffRouteWordsStartAt300Feet() {
        let route = MapMark(id: 1, kind: .route, name: "Way out", points: [[-40, 10], [-40, 10.1]])
        let rally = MapMark(id: 2, kind: .rally, name: "Oak", points: [[-40, 10]])
        func way(_ meters: Double, _ bearing: Double, _ mark: MapMark = route) -> Position.Way {
            Position.Way(mark: mark, meters: meters, bearing: bearing, nearest: [-40, 10], toEnd: 5)
        }
        XCTAssertNil(Position.offRoute(way(90, 45), accuracy: 0, joined: true))
        XCTAssertEqual(Position.offRoute(way(92, 45), accuracy: 0, joined: true), "Off route by 300 feet, head northeast")
        XCTAssertEqual(Position.offRoute(way(700, 270), accuracy: 5, joined: true), "Off route by 0.4 miles, head west")
        XCTAssertNil(Position.offRoute(way(700, 270, rally), accuracy: 5, joined: true))
        XCTAssertTrue(Position.onRoute(way(90, 45), accuracy: 0))
        XCTAssertFalse(Position.onRoute(way(92, 45), accuracy: 0))
        XCTAssertFalse(Position.onRoute(way(10, 45, rally), accuracy: 0))
    }

    /// The W9 review's two false warnings (owner, 2026-10-25): at home before setting out, the strip says where the
    /// route joins, not "Off route"; and a rough fix (Low Power Mode's 100 m) warns only once even its near edge is
    /// past 300 feet.
    func testOffRouteWaitsForTheRouteAndASureFix() {
        let route = MapMark(id: 1, kind: .route, name: "Way out", points: [[-40, 10], [-40, 10.1]])
        let far = Position.Way(mark: route, meters: 1000, bearing: 0, nearest: [-40, 10], toEnd: 5)
        XCTAssertNil(Position.offRoute(far, accuracy: 5, joined: false), "not yet on it: no warning")
        let rough = Position.Way(mark: route, meters: 150, bearing: 0, nearest: [-40, 10], toEnd: 5)
        XCTAssertNil(Position.offRoute(rough, accuracy: 100, joined: true), "maybe on it: 150 m with a 100 m circle")
        XCTAssertEqual(Position.offRoute(rough, accuracy: 50, joined: true), "Off route by 490 feet, head north")
        XCTAssertNil(Position.offRoute(rough, accuracy: 65, joined: true), "85 m at the near edge: under 300 feet")
        // home 200 m from the route, a first fix 80 m from it with a 100 m circle: maybe on it, so never joined, and
        // the strip can't say "Off route by 650 feet" at home once GPS settles (the 2026-10-25 review)
        let firstFix = Position.Way(mark: route, meters: 80, bearing: 0, nearest: [-40, 10], toEnd: 5)
        XCTAssertFalse(Position.onRoute(firstFix, accuracy: 100), "the circle's far edge is 180 m out")
        XCTAssertTrue(Position.onRoute(firstFix, accuracy: 10), "a sure fix 90 m out at most: on it")
    }

    // MARK: The map pins plan (2026-11-14): the kids' target and the Pins list's groups

    func testTheKidsTargetIsThePlannedMeetingPlace() {
        let near = MapMark(id: 1, kind: .rally, name: "Oak", points: [[0, 0]], role: .nearHome)
        let far = MapMark(id: 2, kind: .rally, name: "Farm", points: [[1, 1]], role: .outOfTown)
        XCTAssertEqual(Position.kidsTarget([near, far], eventOn: false), 1)
        XCTAssertEqual(Position.kidsTarget([near, far], eventOn: true), 2)
        let other = MapMark(id: 3, kind: .rally, name: "Church", points: [[2, 2]])
        XCTAssertNil(Position.kidsTarget([other], eventOn: false), "no role plans it")
        XCTAssertNil(Position.kidsTarget([], eventOn: true))
    }

    func testPinGroupsNearestFirstWithAFixNewestFirstWithout() {
        func pin(_ id: Int64, _ lon: Double, _ made: String?) -> MapMark {
            var mark = MapMark(id: id, kind: .pin, name: "P\(id)", points: [[lon, 0]])
            mark.made = made
            return mark
        }
        let pins = [pin(1, 0.3, "2026-11-01T10:00:00Z"), pin(2, 0.1, nil), pin(3, 0.2, "2026-11-10T10:00:00Z")]
        let marks = [MapMark(id: 10, kind: .route, name: "Alt", points: [[0, 0], [1, 1]], routeRole: .alternate),
                     MapMark(id: 11, kind: .start, name: "Start", points: [[0, 0]]),
                     MapMark(id: 12, kind: .rally, name: "Church", points: [[0, 0]]),
                     MapMark(id: 13, kind: .route, name: "Main", points: [[0, 0], [1, 1]], routeRole: .main),
                     MapMark(id: 14, kind: .rally, name: "Oak", points: [[0, 0]], role: .nearHome)]
        let fixed = Position.pinGroups(marks: marks, pins: pins, here: (latitude: 0, longitude: 0))
        XCTAssertEqual(fixed.meeting.map(\.id), [14, 12])
        XCTAssertEqual(fixed.pins.map(\.id), [2, 3, 1], "nearest first")
        XCTAssertEqual(fixed.routes.map(\.id), [13, 10], "main first")
        let blind = Position.pinGroups(marks: marks, pins: pins, here: nil)
        XCTAssertEqual(blind.pins.map(\.id), [3, 1, 2], "newest first, one with no date last")
        let all = (blind.meeting + blind.pins + blind.routes).map(\.kind)
        XCTAssertFalse(all.contains(.start), "the Start point is in no group")
    }

}
