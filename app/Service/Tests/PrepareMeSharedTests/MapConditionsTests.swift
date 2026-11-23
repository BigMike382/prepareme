import Foundation
@testable import PrepareMeShared
import XCTest

/// Conditions on the street map (plan phase 9, item 5): the Mac's road events and gauges as the packer packs them, and
/// storm warnings' outlines from the phone's own reading; made-up places in open ocean only.
final class MapConditionsTests: XCTestCase {
    func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/map-conditions.json"))  // packer/tests/test_map_conditions.py pins it
    }

    func testTheFileThePackerWritesIsRead() throws {
        let found = try MapConditions(fixture())
        XCTAssertEqual(found.roads.count, 2)
        XCTAssertEqual(found.roads[0].place, [-40.1, 10.9])
        XCTAssertTrue(found.roads[0].closure)
        XCTAssertEqual(found.roads[1].place, [-40.1, 10.9, -40.2, 11.0])
        XCTAssertNil(found.roads[1].when)
        XCTAssertEqual(found.gauges.map(\.text), ["Made Up Creek: 2.1 ft, no flooding."])
    }

    func testAnythingElseIsRefusedWhole() throws {
        var top = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        top["home"] = [-78.6, 35.7]
        XCTAssertThrowsError(try MapConditions(JSONSerialization.data(withJSONObject: top)))
        for bad in [#"{"format":2,"roads":[],"gauges":[]}"#,
                    #"{"format":1,"roads":[{"text":"x","detail":"","closure":true,"when":null,"place":[-200,1],"as_of":"t"}],"gauges":[]}"#,
                    #"{"format":1,"roads":[{"text":"x","detail":"","closure":1,"when":null,"place":[-40,1],"as_of":"t"}],"gauges":[]}"#,
                    #"{"format":1,"roads":[],"gauges":[{"text":"x","flag":"","code":"","place":[-40,1,-41,2],"as_of":"t"}]}"#] {
            XCTAssertThrowsError(try MapConditions(Data(bad.utf8)), bad)
        }
    }

    func testOldReadingsAreMarkedOldAndEndedWarningsAreNotDrawn() throws {
        let found = try MapConditions(fixture())
        let read = ISO8601DateFormatter().date(from: "2026-10-14T10:07:00-04:00")!
        let warning = WarningShape(title: "Tornado Warning", code: "TO.W", expires: "2026-10-14T11:00:00-04:00",
                                   asOf: "2026-10-14T10:30:00-04:00",
                                   polygons: [[[[-40, 10], [-39, 10], [-39, 11], [-40, 10]]]])
        func features(_ now: Date) throws -> [[String: Any]] {
            let all = try JSONSerialization.jsonObject(with: found.geoJSON(warnings: [warning], now: now)) as? [String: Any]
            return try XCTUnwrap(all?["features"] as? [[String: Any]])
        }
        let soon = try features(read.addingTimeInterval(1800))
        XCTAssertEqual(soon.count, 4)
        XCTAssertEqual(soon.compactMap { ($0["properties"] as? [String: Any])?["old"] as? Bool }, [false, false, false, false])
        XCTAssertEqual(soon.compactMap { ($0["geometry"] as? [String: Any])?["type"] as? String },
                       ["Point", "LineString", "Point", "MultiPolygon"])
        let seven = try features(read.addingTimeInterval(7 * 3600))  // within 8 hours: still fresh (6 dimmed it)
        XCTAssertTrue(seven.prefix(3).allSatisfy { ($0["properties"] as? [String: Any])?["old"] as? Bool == false })
        let later = try features(read.addingTimeInterval(9 * 3600))
        XCTAssertEqual(later.count, 3, "the warning ended")
        XCTAssertTrue(later.allSatisfy { ($0["properties"] as? [String: Any])?["old"] as? Bool == true })
    }

    func testWarningOutlinesComeFromTheWeatherServicesAnswer() throws {
        let answer = #"""
        {"type":"FeatureCollection","features":[
         {"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-40,10],[-39,10],[-39,11],[-40,10]]]},
          "properties":{"status":"Actual","messageType":"Alert","event":"Tornado Warning","headline":"Tornado Warning",
           "parameters":{"NWSheadline":["A MADE UP TORNADO WARNING"],
            "VTEC":["/O.NEW.KXXX.TO.W.0001.261014T1400Z-261014T1500Z/"]},"description":"Made up.","instruction":""}},
         {"type":"Feature","geometry":null,
          "properties":{"status":"Actual","messageType":"Alert","event":"Freeze Warning","headline":"Freeze Warning",
           "parameters":{},"description":"Made up.","instruction":""}}]}
        """#
        let shapes = try NWSAPI.shapes(Data(answer.utf8), asOf: "2026-10-14T10:30:00-04:00")
        XCTAssertEqual(shapes.count, 1, "a zone-based alert has no outline")
        XCTAssertEqual(shapes[0].title, "A MADE UP TORNADO WARNING")
        XCTAssertEqual(shapes[0].code, "TO.W")
        XCTAssertEqual(shapes[0].polygons, [[[[-40, 10], [-39, 10], [-39, 11], [-40, 10]]]])
        XCTAssertThrowsError(try NWSAPI.shapes(Data("not json".utf8), asOf: ""))
    }

    /// Two warnings with one headline each keep their own end; an outline with no end it can read is drawn only while
    /// the reading is fresh, and an old reading's outline is dimmed (an audit, 2026-10-14).
    func testEachOutlineKeepsItsOwnEndAndAnUnendedOneGoesWhenOld() throws {
        func feature(_ vtec: String) -> String {
            #"{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-40,10],[-39,10],[-39,11],[-40,10]]]},"#
                + #""properties":{"status":"Actual","messageType":"Alert","event":"Tornado Warning","#
                + #""headline":"Tornado Warning","parameters":{"VTEC":[\#(vtec)]},"description":"","instruction":""}}"#
        }
        let answer = #"{"type":"FeatureCollection","features":["#
            + [feature(#""/O.NEW.KXXX.TO.W.0001.261014T1400Z-261014T1500Z/""#),
               feature(#""/O.NEW.KXXX.TO.W.0002.261014T1400Z-261014T1700Z/""#), feature("")].joined(separator: ",")
            + "]}"
        let shapes = try NWSAPI.shapes(Data(answer.utf8), asOf: "2026-10-14T10:30:00-04:00")
        XCTAssertEqual(shapes.count, 3)
        let ends = shapes.map { $0.expires.flatMap { ISO8601DateFormatter().date(from: $0) } }
        XCTAssertEqual(ends[0], ISO8601DateFormatter().date(from: "2026-10-14T15:00:00Z"))
        XCTAssertEqual(ends[1], ISO8601DateFormatter().date(from: "2026-10-14T17:00:00Z"))
        XCTAssertNil(shapes[2].expires)
        let read = ISO8601DateFormatter().date(from: "2026-10-14T10:30:00-04:00")!
        XCTAssertTrue(shapes[2].inForce(at: read.addingTimeInterval(3600)))
        XCTAssertFalse(shapes[2].inForce(at: read.addingTimeInterval(9 * 3600)), "no end, and the reading is old")

        let late = WarningShape(title: "Tornado Warning", code: "TO.W", expires: "2026-10-15T10:00:00-04:00",
                                asOf: "2026-10-14T10:30:00-04:00", polygons: shapes[0].polygons)
        let drawn = try XCTUnwrap(JSONSerialization.jsonObject(
            with: MapConditions().geoJSON(warnings: [late], now: read.addingTimeInterval(9 * 3600))) as? [String: Any])
        let properties = (drawn["features"] as? [[String: Any]])?.first?["properties"] as? [String: Any]
        XCTAssertEqual(properties?["old"] as? Bool, true, "a reading over 8 hours old is dimmed")
    }

    /// Owner, 2026-10-14: road events and gauges leave the map after 3 days unless old ones are asked for.
    func testRoadsAndGaugesLeaveAfterThreeDaysUnlessAsked() throws {
        let found = try MapConditions(fixture())
        let read = ISO8601DateFormatter().date(from: "2026-10-14T10:07:00-04:00")!
        func count(_ now: Date, showOld: Bool = false) throws -> Int {
            let all = try JSONSerialization.jsonObject(with: found.geoJSON(now: now, showOld: showOld)) as? [String: Any]
            return try XCTUnwrap(all?["features"] as? [[String: Any]]).count
        }
        XCTAssertEqual(try count(read.addingTimeInterval(71 * 3600)), 3, "dimmed, still drawn")
        XCTAssertEqual(found.hidden(now: read.addingTimeInterval(71 * 3600)), 0)
        XCTAssertEqual(try count(read.addingTimeInterval(73 * 3600)), 0)
        XCTAssertEqual(found.hidden(now: read.addingTimeInterval(73 * 3600)), 3)
        XCTAssertEqual(try count(read.addingTimeInterval(73 * 3600), showOld: true), 3)
    }
}
