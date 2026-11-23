import Foundation
import PrepareMeShared
import XCTest

/// The phone's reading of weather alerts into counts: it must fail loud and never turn "couldn't read" into "none".
final class NWSAlertsTests: XCTestCase {
    let new = "/O.NEW.KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/"

    func feature(status: String = "Actual", messageType: String = "Alert", vtec: [Any]? = nil,
                 parameters: Any? = nil) -> [String: Any] {
        var properties: [String: Any] = ["status": status, "messageType": messageType]
        if let vtec { properties["parameters"] = ["VTEC": vtec] }
        if let parameters { properties["parameters"] = parameters }
        return ["properties": properties]
    }

    func data(_ features: [Any], type: String = "FeatureCollection") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "features": features])
    }

    func count(_ features: [Any]) throws -> AlertCounts { try NWSAlerts.count(data(features)) }

    func testNoFeaturesCountsZero() throws {
        XCTAssertEqual(try count([]), AlertCounts(alerts: 0, events: 0, noVTEC: 0))
    }

    func testOneActualAlertWithVTECIsOneAlertAndOneEvent() throws {
        XCTAssertEqual(try count([feature(vtec: [new])]), AlertCounts(alerts: 1, events: 1, noVTEC: 0))
    }

    func testTwoAlertsOfOneEventAreTwoAlertsButOneEvent() throws {
        let con = "/O.CON.KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/"
        XCTAssertEqual(try count([feature(vtec: [new]), feature(vtec: [con])]),
                       AlertCounts(alerts: 2, events: 1, noVTEC: 0))
    }

    func testEndedCancelledAndTestAlertsAreNotCounted() throws {
        for action in ["CAN", "EXP", "UPG"] {
            let line = "/O.\(action).KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/"
            XCTAssertEqual(try count([feature(vtec: [line])]), AlertCounts(alerts: 0, events: 0, noVTEC: 0), action)
        }
        XCTAssertEqual(try count([feature(messageType: "Cancel", vtec: [new])]),
                       AlertCounts(alerts: 0, events: 0, noVTEC: 0))
        XCTAssertEqual(try count([feature(status: "Test", vtec: [new])]),
                       AlertCounts(alerts: 0, events: 0, noVTEC: 0))
    }

    func testAnActualAlertWithoutVTECCountsAsOneWithNoVTEC() throws {
        XCTAssertEqual(try count([feature()]), AlertCounts(alerts: 1, events: 0, noVTEC: 1))
    }

    func testTheVTECActionNotTheMessageTypeDecidesWhetherAnAlertIsInForce() throws {
        let con = "/O.CON.KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/"
        XCTAssertEqual(try count([feature(messageType: "Alert", vtec: [con])]),
                       AlertCounts(alerts: 1, events: 1, noVTEC: 0))
        let can = "/O.CAN.KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/"
        XCTAssertEqual(try count([feature(messageType: "Alert", vtec: [can])]),
                       AlertCounts(alerts: 0, events: 0, noVTEC: 0))
    }

    func testAnAnswerItCannotReadThrowsInsteadOfCountingNone() throws {
        XCTAssertThrowsError(try NWSAlerts.count(Data("nope".utf8))) {
            XCTAssertEqual($0 as? NWSAlerts.Problem, .notJSON)
        }
        XCTAssertThrowsError(try NWSAlerts.count(data([], type: "Feature"))) {
            XCTAssertEqual($0 as? NWSAlerts.Problem, .notAFeatureCollection)
        }
        let noFeatures = try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection"])
        XCTAssertThrowsError(try NWSAlerts.count(noFeatures)) {
            XCTAssertEqual($0 as? NWSAlerts.Problem, .notAFeatureCollection)
        }
        let badFeatures: [[Any]] = [
            [["id": "x"]],
            [["properties": ["messageType": "Alert"]]],
            [feature(parameters: "text")],
            ["text"],
        ]
        for features in badFeatures {
            XCTAssertThrowsError(try count(features)) { XCTAssertEqual($0 as? NWSAlerts.Problem, .badFeature) }
        }
        XCTAssertThrowsError(try count([feature(parameters: ["VTEC": "text"])])) {
            XCTAssertEqual($0 as? NWSAlerts.Problem, .badVTEC)
        }
        XCTAssertThrowsError(try count([feature(vtec: [5])])) {
            XCTAssertEqual($0 as? NWSAlerts.Problem, .badVTEC)
        }
    }

    func testAVTECLineThatIsntPVTECThrowsInsteadOfReadingAsEnded() throws {
        XCTAssertThrowsError(try count([feature(vtec: ["/O.NEW.KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/",
                                                       "not a VTEC line"])])) {
            XCTAssertEqual($0 as? NWSAlerts.Problem, .badVTEC)
        }
    }

    func testEventNamesALineInForceAndNothingElse() {
        for action in ["NEW", "CON", "EXT", "EXA", "EXB"] {
            XCTAssertEqual(NWSAlerts.event(inForce: "/O.\(action).KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/"),
                           "KXXX.WI.Y.0012", action)
        }
        for action in ["CAN", "EXP", "UPG"] {
            XCTAssertNil(NWSAlerts.event(inForce: "/O.\(action).KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/"))
        }
        for bad in ["", "garbage", "/O.NEW.KXX.WI.Y.0012.x/", "/O.NEW.KXXX.WI.Y.12.x/", "/Q.NEW.KXXX.WI.Y.0012.x/",
                    "O.NEW.KXXX.WI.Y.0012.x/", "/O.new.KXXX.WI.Y.0012.x/", "/O.NEW.KXXX.WI.Y.0012.x"] {
            XCTAssertNil(NWSAlerts.event(inForce: bad), bad)
        }
    }

    func testTheAlertAddressCarriesTheJoinedZones() throws {
        let url = try XCTUnwrap(NWSAlerts.url(zones: ["ZZZ001", "ZZC001"]))
        XCTAssertEqual(url.absoluteString, "https://api.weather.gov/alerts/active?zone=ZZZ001,ZZC001")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items, [URLQueryItem(name: "zone", value: "ZZZ001,ZZC001")])
    }

    func testNoAddressIsMadeFromAnythingButZoneCodes() {
        XCTAssertNil(NWSAlerts.url(zones: []))
        for bad in ["zzz001", "ZZX001", "ZZZ01", "ZZZ001&x=1", "ZZZ0011", "ZZZ00a"] {
            XCTAssertNil(NWSAlerts.url(zones: ["ZZZ001", bad]), bad)
        }
    }

    func testZoneCodesAreTwoLettersZOrCAndThreeDigits() {
        XCTAssertTrue(NWSAlerts.isZoneCode("ZZZ001"))
        XCTAssertTrue(NWSAlerts.isZoneCode("ZZC999"))
        XCTAssertFalse(NWSAlerts.isZoneCode(""))
        XCTAssertFalse(NWSAlerts.isZoneCode("ZZ001"))
        XCTAssertFalse(NWSAlerts.isZoneCode("zzZ001"))
        XCTAssertFalse(NWSAlerts.isZoneCode("ZZZ٠٠١"))
    }
}
