import Foundation
import PrepareMeShared
import XCTest

/// The phone's own reading of api.weather.gov: alerts, a zone's forecast and the lookup of a spot. Each must read
/// the real answers it was captured from, and fail loud (FeedFormatError) rather than turn "couldn't read" into "none".
final class NWSAPITests: XCTestCase {
    let nd = "Fixtures/conditions/nws/nd-freeze-2026-10-13/"
    let ca = "Fixtures/conditions/nws/ca-freeze-2026-10-13/"

    func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(path))
    }

    func collection(_ features: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }

    /// A made-up alert feature; `parameters` and extra properties can be replaced.
    func feature(status: String = "Actual", messageType: String = "Alert", headline: String? = "A made-up headline",
                 event: String? = "Wind Advisory", description: String = "Made-up description.",
                 vtec: [Any]? = ["/O.NEW.KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/"],
                 extra: [String: Any] = [:]) -> [String: Any] {
        var properties: [String: Any] = ["status": status, "messageType": messageType, "description": description]
        if let headline { properties["headline"] = headline }
        if let event { properties["event"] = event }
        if let vtec { properties["parameters"] = ["VTEC": vtec] }
        for (key, value) in extra { properties[key] = value }
        return ["properties": properties]
    }

    func line(_ action: String, _ phenomenon: String, _ significance: String, end: String = "261013T0000Z",
              number: String = "0012") -> String {
        "/O.\(action).KXXX.\(phenomenon).\(significance).\(number).261012T1800Z-\(end)/"
    }

    func assertRefused(_ data: Data, file: StaticString = #filePath, line: UInt = #line,
                       _ read: (Data) throws -> [ConditionItem]) {
        XCTAssertThrowsError(try read(data), file: file, line: line) { error in
            XCTAssertTrue(error is FeedFormatError, "\(error)", file: file, line: line)
        }
    }

    // MARK: North Dakota alerts

    func testNorthDakotaFreezeWarningReadsAsOneItem() throws {
        let items = try NWSAPI.alerts(fixture(nd + "api-alerts.json"))
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.text, "FREEZE WARNING IN EFFECT FROM 1 AM TO 9 AM CDT WEDNESDAY")
        XCTAssertEqual(item.flag, "warn")
        XCTAssertEqual(item.code, "FZ.W")
        XCTAssertEqual(item.vtec, ["NEW.KFGF.FZ.W.0005"])
        XCTAssertEqual(item.expires, "2026-10-14T10:00:00-04:00")
        XCTAssertFalse(item.detail.isEmpty)
        XCTAssertFalse(item.detail.contains("LAT...LON"))
        XCTAssertTrue(item.detail.contains("Sub-freezing temperatures"))
    }

    // MARK: California alerts

    /// F-062's real capture: one product carrying a Freeze Warning and a Frost Advisory, which the API splits into two
    /// alerts with the same headline and text. It is one item, as the Mac's page shows it, with both VTEC lines and
    /// the warning's code: the advisory never hides the warning.
    func testCaliforniaProductIsOneItemWithTheWarningsCodeAndBothVTECLines() throws {
        let items = try NWSAPI.alerts(fixture(ca + "api-alerts.json"))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.code, "FZ.W")
        XCTAssertEqual(Set(items.first?.vtec ?? []), ["NEW.KEKA.FZ.W.0008", "CON.KEKA.FR.Y.0021"])
        XCTAssertEqual(items.first?.flag, "warn")
        XCTAssertEqual(items.first?.expires, "2026-10-13T11:00:00-04:00")
    }

    /// The same headline and text with different hazards in either order: the warning's code wins.
    func testAnAdvisoryListedFirstNeverHidesTheWarning() throws {
        func feature(_ vtec: String) -> [String: Any] {
            ["properties": ["status": "Actual", "messageType": "Alert", "headline": "Made-up statement",
                            "description": "Made-up text.", "parameters": ["VTEC": [vtec]]]]
        }
        let warning = "/O.NEW.KXXX.TO.W.0001.261014T1800Z-261014T1900Z/"
        let advisory = "/O.CON.KXXX.WI.Y.0002.261014T1800Z-261014T2000Z/"
        for order in [[advisory, warning], [warning, advisory]] {
            let items = try NWSAPI.alerts(collection(order.map(feature)))
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.code, "TO.W")
            XCTAssertEqual(items.first?.vtec.count, 2)
        }
    }

    // MARK: refusals

    func testNotJSONIsRefused() {
        assertRefused(Data("<html>nope</html>".utf8), NWSAPI.alerts)
    }

    func testJSONThatIsNotAFeatureCollectionIsRefused() throws {
        assertRefused(try JSONSerialization.data(withJSONObject: ["type": "Feature", "features": []]), NWSAPI.alerts)
        assertRefused(try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection"]), NWSAPI.alerts)
        assertRefused(try JSONSerialization.data(withJSONObject: [1, 2]), NWSAPI.alerts)
    }

    func testAFeatureWithoutPropertiesStatusOrMessageTypeIsRefused() throws {
        assertRefused(try collection([["id": "x"]]), NWSAPI.alerts)
        assertRefused(try collection([["properties": ["messageType": "Alert"]]]), NWSAPI.alerts)
        assertRefused(try collection([["properties": ["status": "Actual"]]]), NWSAPI.alerts)
    }

    func testAVTECEntryThatIsNotTextIsRefused() throws {
        assertRefused(try collection([feature(vtec: [42])]), NWSAPI.alerts)
    }

    func testVTECThatIsNotAListIsRefused() throws {
        assertRefused(try collection([feature(vtec: nil, extra: ["parameters": ["VTEC": "/O.NEW.KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/"]])]),
                      NWSAPI.alerts)
    }

    func testAVTECStringThatIsNotAValidLineIsRefused() throws {
        for bad in ["not a vtec", "/O.NEW.KXXX.WI.Y.0012.261012T1800Z/", "/O.NEW.KXXX.WI.Y.0012.261012T1800Z-261013T0000/",
                    "/Q.NEW.KXXX.WI.Y.0012.261012T1800Z-261013T0000Z/", "/O.NEW.kxxx.WI.Y.0012.261012T1800Z-261013T0000Z/",
                    ""] {
            assertRefused(try collection([feature(vtec: [bad])]), NWSAPI.alerts)
        }
    }

    func testAnAlertWithNoHeadlineAndNoEventIsRefused() throws {
        assertRefused(try collection([feature(headline: nil, event: nil)]), NWSAPI.alerts)
        assertRefused(try collection([feature(headline: "  ", event: "")]), NWSAPI.alerts)
    }

    func testHeadlineThenEventIsTheFallbackForTheTitle() throws {
        let noHeadline = try NWSAPI.alerts(collection([feature(headline: nil, event: "Wind  Advisory")]))
        XCTAssertEqual(noHeadline.map(\.text), ["Wind Advisory"])
        let headline = try NWSAPI.alerts(collection([feature(headline: "Wind Advisory until noon")]))
        XCTAssertEqual(headline.map(\.text), ["Wind Advisory until noon"])
    }

    // MARK: left out

    func testTestAndExerciseAlertsAndCancelMessagesAreLeftOut() throws {
        let items = try NWSAPI.alerts(collection([
            feature(status: "Test"), feature(status: "Exercise"), feature(messageType: "Cancel"),
        ]))
        XCTAssertEqual(items, [])
    }

    func testAnEmptyFeatureCollectionIsNone() throws {
        XCTAssertEqual(try NWSAPI.alerts(collection([])), [])
    }

    func testALeftOutAlertDoesNotHideAnotherThatIsRead() throws {
        let items = try NWSAPI.alerts(collection([feature(status: "Test"), feature(headline: "Real one")]))
        XCTAssertEqual(items.map(\.text), ["Real one"])
    }

    // MARK: ended alerts

    func testACancelledAlertIsStillReturnedAsEndedWithNoCode() throws {
        for action in ["CAN", "EXP", "UPG"] {
            let items = try NWSAPI.alerts(collection([feature(vtec: [line(action, "WI", "Y")])]))
            XCTAssertEqual(items.count, 1, action)
            XCTAssertEqual(items[0].code, "", action)
            XCTAssertTrue(NWSVTEC.allEnded(items[0].vtec), action)
            XCTAssertEqual(items[0].vtec, ["\(action).KXXX.WI.Y.0012"])
        }
    }

    func testAnAlertInForceIsNotEnded() throws {
        let items = try NWSAPI.alerts(collection([feature()]))
        XCTAssertFalse(NWSVTEC.allEnded(items[0].vtec))
    }

    // MARK: no VTEC

    func testWithoutVTECExpiresFallsBackToEndsThenExpires() throws {
        let both = try NWSAPI.alerts(collection([feature(vtec: nil, extra: [
            "ends": "2026-10-14T09:00:00-05:00", "expires": "2026-10-13T21:45:00-05:00"])]))
        XCTAssertEqual(both[0].expires, "2026-10-14T10:00:00-04:00")
        XCTAssertEqual(both[0].code, "")
        XCTAssertEqual(both[0].vtec, [])
        let onlyExpires = try NWSAPI.alerts(collection([feature(vtec: nil, extra: [
            "ends": NSNull(), "expires": "2026-10-13T21:45:00-05:00"])]))
        XCTAssertEqual(onlyExpires[0].expires, "2026-10-13T22:45:00-04:00")
        let neither = try NWSAPI.alerts(collection([feature(vtec: nil)]))
        XCTAssertNil(neither[0].expires)
    }

    // MARK: machine lines and duplicates

    func testMachineLinesAreDroppedFromTheDetailAndOtherLinesKept() throws {
        let text = "First line.\nLAT...LON 3512 7856 3520 7840\n3500 7830 3490 7820\nTIME...MOT...LOC 1800Z 270DEG 30KT 3510 7850\n3511 7851\nLast line.\n1234 is not continuing"
        let items = try NWSAPI.alerts(collection([feature(description: text)]))
        let detail = items[0].detail
        XCTAssertFalse(detail.contains("LAT...LON"))
        XCTAssertFalse(detail.contains("TIME...MOT...LOC"))
        XCTAssertFalse(detail.contains("3500 7830"))
        XCTAssertFalse(detail.contains("3511 7851"))
        XCTAssertTrue(detail.contains("First line."))
        XCTAssertTrue(detail.contains("Last line."))
        XCTAssertTrue(detail.contains("1234 is not continuing"))
    }

    func testADigitLineNotAfterAMachineLineIsKept() throws {
        let items = try NWSAPI.alerts(collection([feature(description: "Intro.\n3500 7830\nEnd.")]))
        XCTAssertTrue(items[0].detail.contains("3500 7830"))
    }

    func testInstructionFollowsDescriptionInTheDetail() throws {
        let items = try NWSAPI.alerts(collection([feature(description: "Made-up description.",
                                                          extra: ["instruction": "Made-up instruction."])]))
        XCTAssertEqual(items[0].detail, "Made-up description.\n\nMade-up instruction.")
        XCTAssertEqual(items[0].instruction, "Made-up instruction.", "and on its own, for the band (R9.1)")
        let none = try NWSAPI.alerts(collection([feature(description: "Made-up description.")]))
        XCTAssertNil(none[0].instruction, "an alert with no instruction has none")
    }

    func testTheSameAlertTwiceIsReturnedOnce() throws {
        let items = try NWSAPI.alerts(collection([feature(), feature()]))
        XCTAssertEqual(items.count, 1)
    }

    func testDifferentDetailWithTheSameHeadlineIsKeptTwice() throws {
        let items = try NWSAPI.alerts(collection([feature(description: "One."), feature(description: "Two.")]))
        XCTAssertEqual(items.count, 2)
    }

    // MARK: VTEC

    func testVTECParsesAWholeLineAndNothingElse() throws {
        let parsed = try XCTUnwrap(NWSVTEC.parse("/O.NEW.KFGF.FZ.W.0005.261014T0600Z-261014T1400Z/"))
        XCTAssertEqual(parsed.action, "NEW")
        XCTAssertEqual(parsed.office, "KFGF")
        XCTAssertEqual(parsed.phenomenon, "FZ")
        XCTAssertEqual(parsed.significance, "W")
        XCTAssertEqual(parsed.number, "0005")
        XCTAssertEqual(parsed.start, "261014T0600Z")
        XCTAssertEqual(parsed.end, "261014T1400Z")
        XCTAssertNil(NWSVTEC.parse("x /O.NEW.KFGF.FZ.W.0005.261014T0600Z-261014T1400Z/"))
        XCTAssertNil(NWSVTEC.parse("/O.NEW.KFGF.FZ.W.0005.261014T0600Z-261014T1400Z/ extra"))
    }

    func lines(_ texts: [String]) throws -> [NWSVTEC.Line] {
        try texts.map { try XCTUnwrap(NWSVTEC.parse($0)) }
    }

    func testEventModeWarningsComeFirstEvenWhenListedAfterAnotherWarning() throws {
        XCTAssertEqual(NWSVTEC.code(try lines([line("NEW", "SS", "W"), line("NEW", "HU", "W")])), "HU.W")
        XCTAssertEqual(NWSVTEC.code(try lines([line("NEW", "FZ", "W"), line("NEW", "FF", "W")])), "FF.W")
        XCTAssertEqual(NWSVTEC.code(try lines([line("NEW", "HU", "W"), line("NEW", "TO", "W")])), "TO.W")
        XCTAssertEqual(NWSVTEC.code(try lines([line("NEW", "FF", "W"), line("NEW", "HU", "W")])), "FF.W")
    }

    func testAWarningBeatsAWatchAndAdvisory() throws {
        XCTAssertEqual(NWSVTEC.code(try lines([line("NEW", "WI", "Y"), line("NEW", "SS", "W")])), "SS.W")
    }

    /// Review I2 (phase 5): a watch outranks an advisory, so it beats an advisory listed ahead of it
    /// (weather.py `_vtec_code`), and a warning still beats both.
    func testAWatchBeatsAnAdvisoryListedFirst() throws {
        XCTAssertEqual(NWSVTEC.code(try lines([line("NEW", "WW", "Y"), line("CON", "WS", "A")])), "WS.A")
        XCTAssertEqual(NWSVTEC.code(try lines([line("NEW", "WW", "Y"), line("CON", "WS", "A"), line("NEW", "WS", "W")])),
                       "WS.W")
    }

    func testAWatchAloneGivesTheWatch() throws {
        XCTAssertEqual(NWSVTEC.code(try lines([line("NEW", "TO", "A")])), "TO.A")
    }

    func testEndedLinesDoNotGiveACode() throws {
        XCTAssertEqual(NWSVTEC.code(try lines([line("CAN", "TO", "W"), line("EXP", "FF", "W")])), "")
        XCTAssertEqual(NWSVTEC.code(try lines([line("CAN", "TO", "W"), line("CON", "WI", "Y")])), "WI.Y")
        XCTAssertEqual(NWSVTEC.code([]), "")
    }

    func testUntilFurtherNoticeInForceGivesNoEnd() throws {
        let set = try lines([line("NEW", "FF", "W", end: "000000T0000Z"), line("CON", "WI", "Y", end: "261013T0000Z")])
        XCTAssertNil(NWSVTEC.end(set))
    }

    func testTheLatestInForceEndWins() throws {
        let set = try lines([line("NEW", "WI", "Y", end: "261013T0000Z"), line("CON", "FZ", "W", end: "261014T1400Z"),
                             line("CAN", "SS", "W", end: "261020T0000Z")])
        XCTAssertEqual(NWSVTEC.end(set), "2026-10-14T10:00:00-04:00")
    }

    func testWithNothingInForceTheLatestRealEndWins() throws {
        let set = try lines([line("CAN", "WI", "Y", end: "261013T0000Z"), line("EXP", "FZ", "W", end: "261014T1400Z"),
                             line("UPG", "SS", "W", end: "000000T0000Z")])
        XCTAssertEqual(NWSVTEC.end(set), "2026-10-14T10:00:00-04:00")
    }

    func testEndedWithOnlyUntilFurtherNoticeHasNoEnd() throws {
        XCTAssertNil(NWSVTEC.end(try lines([line("CAN", "WI", "Y", end: "000000T0000Z")])))
        XCTAssertNil(NWSVTEC.end([]))
    }

    func testAllEndedNeedsEveryLineEndedAndAtLeastOne() {
        XCTAssertTrue(NWSVTEC.allEnded(["CAN.KXXX.WI.Y.0012", "EXP.KXXX.FZ.W.0003"]))
        XCTAssertFalse(NWSVTEC.allEnded(["CAN.KXXX.WI.Y.0012", "CON.KXXX.FZ.W.0003"]))
        XCTAssertFalse(NWSVTEC.allEnded([]))
    }

    // MARK: zone forecast

    func testNorthDakotaZoneForecastGivesOneItemPerPeriodInOrder() throws {
        let data = try fixture(nd + "api-zone-forecast.json")
        let items = try NWSAPI.zoneForecast(data)
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let periods = try XCTUnwrap((top["properties"] as? [String: Any])?["periods"] as? [[String: Any]])
        XCTAssertEqual(items.count, periods.count)
        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items[0].text, "Rest Of Today: Mostly cloudy. Highs 50 to 55. Northwest winds around 10 mph.")
        for (item, period) in zip(items, periods) {
            let name = try XCTUnwrap(period["name"] as? String)
            XCTAssertTrue(item.text.hasPrefix(name + ": "), item.text)
            XCTAssertEqual(item.text, item.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        }
    }

    func testForecastWhitespaceIsCollapsed() throws {
        let body: [String: Any] = ["properties": ["periods": [["name": " Tonight ", "detailedForecast": "Clear.\n  Lows   30."]]]]
        let items = try NWSAPI.zoneForecast(JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(items.map(\.text), ["Tonight: Clear. Lows 30."])
    }

    func testForecastWithoutPeriodsEmptyPeriodsOrIncompletePeriodsIsRefused() throws {
        func data(_ body: Any) throws -> Data { try JSONSerialization.data(withJSONObject: body) }
        assertRefused(try data(["properties": [String: Any]()]), NWSAPI.zoneForecast)
        assertRefused(try data([String: Any]()), NWSAPI.zoneForecast)
        assertRefused(try data(["properties": ["periods": [Any]()]]), NWSAPI.zoneForecast)
        assertRefused(try data(["properties": ["periods": [["detailedForecast": "Clear."]]]]), NWSAPI.zoneForecast)
        assertRefused(try data(["properties": ["periods": [["name": "Tonight"]]]]), NWSAPI.zoneForecast)
        assertRefused(try data(["properties": ["periods": [["name": "Tonight", "detailedForecast": "  "]]]]), NWSAPI.zoneForecast)
        assertRefused(try data(["properties": ["periods": [["name": "A", "detailedForecast": "ok"], ["name": "B"]]]]),
                      NWSAPI.zoneForecast)
        assertRefused(Data("nope".utf8), NWSAPI.zoneForecast)
    }

    // MARK: points

    func testNorthDakotaLookupGivesItsCodesAndTown() throws {
        let place = try NWSAPI.points(fixture(nd + "api-points.json"))
        XCTAssertEqual(place.zone, "NDZ006")
        XCTAssertEqual(place.county, "NDC095")
        XCTAssertEqual(place.fireZone, "NDZ006")
        XCTAssertEqual(place.area, "Rocklake ND")
        XCTAssertEqual(place.codes, ["NDZ006", "NDC095"])
    }

    func testAreaNeverHoldsTheDistance() throws {
        let place = try NWSAPI.points(fixture(nd + "api-points.json"))
        XCTAssertFalse(place.area.contains("10737"))
        XCTAssertFalse(place.area.contains("181"))
    }

    func pointsData(zone: String = "https://api.weather.gov/zones/forecast/NDZ006",
                    county: String = "https://api.weather.gov/zones/county/NDC095",
                    fire: String = "https://api.weather.gov/zones/fire/NDZ007",
                    city: String = "Town") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["properties": [
            "forecastZone": zone, "county": county, "fireWeatherZone": fire,
            "relativeLocation": ["properties": ["city": city, "state": "ND"]],
        ]])
    }

    func testADifferentFireZoneIsKeptInTheCodes() throws {
        let place = try NWSAPI.points(pointsData())
        XCTAssertEqual(place.codes, ["NDZ006", "NDC095", "NDZ007"])
    }

    func testALookupCodeOfAnotherShapeIsRefused() throws {
        let read: (Data) throws -> NWSAPI.Place = NWSAPI.points
        for data in [try pointsData(zone: "https://api.weather.gov/zones/forecast/nope"),
                     try pointsData(zone: "https://api.weather.gov/zones/forecast/NDC006"),
                     try pointsData(county: "https://api.weather.gov/zones/county/NDZ095"),
                     try pointsData(fire: "https://api.weather.gov/zones/fire/ND0061"),
                     try pointsData(zone: ""),
                     Data("{}".utf8), Data("nope".utf8)] {
            XCTAssertThrowsError(try read(data)) { XCTAssertTrue($0 is FeedFormatError, "\($0)") }
        }
    }

    func testATownThatCannotBeShownIsRefused() throws {
        XCTAssertThrowsError(try NWSAPI.points(pointsData(city: String(repeating: "A", count: 70)))) {
            XCTAssertTrue($0 is FeedFormatError)
        }
    }

    // MARK: URLs

    func testURLBuilders() {
        XCTAssertTrue(NWSAPI.pointsURL(latitude: 48.6912, longitude: -99.2481).absoluteString.hasSuffix("/points/48.69,-99.25"))
        XCTAssertTrue(NWSAPI.alertsURL(["ZZZ041", "ZZC183"]).absoluteString.hasSuffix("/alerts/active?zone=ZZZ041,ZZC183"))
        XCTAssertEqual(NWSAPI.forecastURL(zone: "NDZ006").absoluteString, "https://api.weather.gov/zones/forecast/NDZ006/forecast")
        XCTAssertEqual(NWSAPI.alertsURL(["ZZZ041"]).host, "api.weather.gov")
    }
}
