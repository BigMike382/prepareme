import Foundation
import PrepareMeShared
import XCTest

/// The phone's conditions settings file: read exactly as the Mac writes it, and refused for any other shape, so a
/// coordinate or a stray key can never ride in it.
final class ConditionsSettingsTests: XCTestCase {
    let good = #"{"county":"Example","format":1,"gauges":["ZZZZ1","ZZZZ2"],"live_alerts":false,"nws_county":"ZZC183","nws_fire_zone":"ZZZ041","nws_zone":"ZZZ041"}"#

    func read(_ text: String) throws -> ConditionsSettings { try ConditionsSettings(Data(text.utf8)) }

    func assertRefused(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try read(text), text, file: file, line: line) { error in
            XCTAssertEqual(error as? ConditionsSettings.Problem, .notTheShape, file: file, line: line)
        }
    }

    func testTheGoodFileReads() throws {
        let settings = try read(good)
        XCTAssertEqual(settings.zone, "ZZZ041")
        XCTAssertEqual(settings.county, "ZZC183")
        XCTAssertEqual(settings.fireZone, "ZZZ041")
        XCTAssertEqual(settings.countyName, "Example")
        XCTAssertEqual(settings.gauges, ["ZZZZ1", "ZZZZ2"])
        XCTAssertFalse(settings.liveAlerts)
    }

    func testLiveAlertsTrueReads() throws {
        XCTAssertTrue(try read(good.replacingOccurrences(of: "\"live_alerts\":false", with: "\"live_alerts\":true")).liveAlerts)
    }

    func testAlertCodesListTheFireZoneOnlyWhenItDiffers() throws {
        XCTAssertEqual(try read(good).alertCodes, ["ZZZ041", "ZZC183"])
        let other = good.replacingOccurrences(of: "\"nws_fire_zone\":\"ZZZ041\"", with: "\"nws_fire_zone\":\"ZZZ042\"")
        XCTAssertEqual(try read(other).alertCodes, ["ZZZ041", "ZZC183", "ZZZ042"])
    }

    func testCountyNamesWithCapitalsAndTwoWordsRead() throws {
        for name in ["McExample", "New Example"] {
            let text = good.replacingOccurrences(of: "\"Example\"", with: "\"\(name)\"")
            XCTAssertEqual(try read(text).countyName, name)
        }
    }

    func testNoGaugesReads() throws {
        let text = good.replacingOccurrences(of: "[\"ZZZZ1\",\"ZZZZ2\"]", with: "[]")
        XCTAssertEqual(try read(text).gauges, [])
    }

    func testSixGaugesReadButSevenAreRefused() throws {
        func gauges(_ n: Int) -> String {
            "[" + (1...n).map { "\"ZZZZ\($0)\"" }.joined(separator: ",") + "]"
        }
        let six = good.replacingOccurrences(of: "[\"ZZZZ1\",\"ZZZZ2\"]", with: gauges(6))
        XCTAssertEqual(try read(six).gauges.count, 6)
        assertRefused(good.replacingOccurrences(of: "[\"ZZZZ1\",\"ZZZZ2\"]", with: gauges(7)))
    }

    func testAnExtraKeyIsRefused() {
        assertRefused(good.replacingOccurrences(of: "{", with: "{\"latitude\":35,"))
        assertRefused(good.replacingOccurrences(of: "{", with: "{\"extra\":\"x\","))
    }

    func testAnyNumberWithADecimalPointIsRefused() {
        assertRefused(good.replacingOccurrences(of: "{", with: "{\"latitude\":38.89,"))
        assertRefused(good.replacingOccurrences(of: "\"format\":1", with: "\"format\":1.0"))
        assertRefused(good.replacingOccurrences(of: "\"ZZZZ1\"", with: "38.89"))
        assertRefused(good.replacingOccurrences(of: "\"Example\"", with: "\"Example\",\"x\":[-77.03]").replacingOccurrences(of: "{", with: "{ "))
    }

    func testAMissingKeyIsRefused() {
        for key in ["county", "format", "gauges", "live_alerts", "nws_county", "nws_fire_zone", "nws_zone"] {
            var object = (try? JSONSerialization.jsonObject(with: Data(good.utf8))) as! [String: Any]
            object[key] = nil
            let data = try! JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try ConditionsSettings(data), key)
        }
    }

    func testAnotherFormatNumberOrABooleanIsRefused() {
        assertRefused(good.replacingOccurrences(of: "\"format\":1", with: "\"format\":2"))
        assertRefused(good.replacingOccurrences(of: "\"format\":1", with: "\"format\":true"))
        assertRefused(good.replacingOccurrences(of: "\"format\":1", with: "\"format\":\"1\""))
    }

    func testZonesMustBeUpperCaseZoneCodes() {
        assertRefused(good.replacingOccurrences(of: "\"nws_zone\":\"ZZZ041\"", with: "\"nws_zone\":\"zzz041\""))
        assertRefused(good.replacingOccurrences(of: "\"nws_zone\":\"ZZZ041\"", with: "\"nws_zone\":\"ZZC041\""))
        assertRefused(good.replacingOccurrences(of: "\"nws_zone\":\"ZZZ041\"", with: "\"nws_zone\":\"ZZZ0411\""))
        assertRefused(good.replacingOccurrences(of: "\"nws_fire_zone\":\"ZZZ041\"", with: "\"nws_fire_zone\":\"zzz041\""))
        assertRefused(good.replacingOccurrences(of: "\"nws_fire_zone\":\"ZZZ041\"", with: "\"nws_fire_zone\":\"ZZC183\""))
    }

    func testACountyCodeInTheZonesPlaceIsRefused() {
        assertRefused(good.replacingOccurrences(of: "\"nws_zone\":\"ZZZ041\"", with: "\"nws_zone\":\"ZZC183\""))
    }

    func testTheCountyCodeMustBeACountyCode() {
        assertRefused(good.replacingOccurrences(of: "\"nws_county\":\"ZZC183\"", with: "\"nws_county\":\"ZZZ183\""))
        assertRefused(good.replacingOccurrences(of: "\"nws_county\":\"ZZC183\"", with: "\"nws_county\":\"zzc183\""))
    }

    func testGaugesMustBeAListOfUpperCaseFiveCharacterIDs() {
        assertRefused(good.replacingOccurrences(of: "[\"ZZZZ1\",\"ZZZZ2\"]", with: "\"ZZZZ1\""))
        assertRefused(good.replacingOccurrences(of: "[\"ZZZZ1\",\"ZZZZ2\"]", with: "[\"zzzz1\"]"))
        assertRefused(good.replacingOccurrences(of: "[\"ZZZZ1\",\"ZZZZ2\"]", with: "[\"ZZZZ\"]"))
        assertRefused(good.replacingOccurrences(of: "[\"ZZZZ1\",\"ZZZZ2\"]", with: "[\"ZZZZ12\"]"))
        assertRefused(good.replacingOccurrences(of: "[\"ZZZZ1\",\"ZZZZ2\"]", with: "[7]"))
    }

    func testLiveAlertsMustBeABoolean() {
        assertRefused(good.replacingOccurrences(of: "\"live_alerts\":false", with: "\"live_alerts\":\"false\""))
        assertRefused(good.replacingOccurrences(of: "\"live_alerts\":false", with: "\"live_alerts\":0"))
        assertRefused(good.replacingOccurrences(of: "\"live_alerts\":false", with: "\"live_alerts\":1"))
    }

    func testARepeatedKeyIsRefused() {
        assertRefused(good.replacingOccurrences(of: "{", with: "{\"format\":1,"))
        assertRefused(good.replacingOccurrences(of: "\"live_alerts\":false", with: "\"live_alerts\":false,\"live_alerts\":true"))
    }

    func testNotJSONIsRefused() {
        assertRefused("")
        assertRefused("nope")
        assertRefused("[]")
        assertRefused(String(good.dropLast()))
    }

    func testCountyNamesOfAnotherShapeAreRefused() {
        for name in ["Example2", "example", "Example County 2", "New  Example", "", "A B C", "Example\\nX"] {
            assertRefused(good.replacingOccurrences(of: "\"Example\"", with: "\"\(name)\""))
        }
    }

    // MARK: Any state's codes, by shape (Unlisted plan, phase 4): the state itself is never in this code

    func testAnyStatesLettersReadWhenAllThreeAgree() throws {
        let other = good.replacingOccurrences(of: "ZZZ", with: "QQZ").replacingOccurrences(of: "ZZC", with: "QQC")
        XCTAssertEqual(try read(other).alertCodes, ["QQZ041", "QQC183"])
        assertRefused(good.replacingOccurrences(of: "\"nws_county\":\"ZZC183\"", with: "\"nws_county\":\"QQC183\""))
        assertRefused(good.replacingOccurrences(of: "\"nws_fire_zone\":\"ZZZ041\"", with: "\"nws_fire_zone\":\"QQZ041\""))
        assertRefused(good.replacingOccurrences(of: "ZZZ", with: "Z1Z").replacingOccurrences(of: "ZZC", with: "Z1C"))
    }

    func testTheStatesFileRidesBesideAndADamagedOneIsNone() throws {
        let area = Data(ConditionsAreaTests.good.utf8)
        XCTAssertEqual(try ConditionsSettings(Data(good.utf8), area: area).area?.agency, "Example Emergency Office")
        XCTAssertNil(try ConditionsSettings(Data(good.utf8), area: Data("{}".utf8)).area)
        XCTAssertNil(try read(good).area, "an older library: no state feeds, nothing built in")
    }

    // MARK: The DC test area (owner, 2026-10-21): a simulator reads it, a phone's build and the Mac's packer never

    static let dcURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/conditions/settings-dc.json")

    func testTheDCFileIsRefusedUnlessTheTestAreaIsAllowed() throws {
        let data = try Data(contentsOf: Self.dcURL)
        XCTAssertThrowsError(try ConditionsSettings(data))
        let settings = try ConditionsSettings(data, allowingTestArea: true)
        XCTAssertTrue(settings.isTestArea)
        XCTAssertEqual(settings.alertCodes, ["DCZ001", "DCC001"])
        XCTAssertEqual(settings.countyName, "District of Columbia")
        XCTAssertEqual(settings.gauges, ["BRKM2"])
        XCTAssertTrue(settings.liveAlerts)
    }

    func testHomeFilesStillReadWithTheTestAreaAllowedAndAreNotTheTestArea() throws {
        let settings = try ConditionsSettings(Data(good.utf8), allowingTestArea: true)
        XCTAssertFalse(settings.isTestArea)
        XCTAssertFalse(try read(good).isTestArea)
    }

    func testOnlyTheTestAreasExactCodesAndNameRead() throws {
        let dc = try String(contentsOf: Self.dcURL, encoding: .utf8)
        func refused(_ text: String, line: UInt = #line) {
            XCTAssertThrowsError(try ConditionsSettings(Data(text.utf8), allowingTestArea: true), text, line: line)
        }
        refused(dc.replacingOccurrences(of: "\"nws_zone\":\"DCZ001\"", with: "\"nws_zone\":\"DCZ002\""))
        refused(dc.replacingOccurrences(of: "\"nws_zone\":\"DCZ001\"", with: "\"nws_zone\":\"VAZ054\""))
        refused(dc.replacingOccurrences(of: "DCC001", with: "MDC031"))
        refused(dc.replacingOccurrences(of: "\"nws_fire_zone\":\"DCZ001\"", with: "\"nws_fire_zone\":\"ZZZ041\""))
        refused(dc.replacingOccurrences(of: "District of Columbia", with: "Example"))
        refused(dc.replacingOccurrences(of: "District of Columbia", with: "district of columbia"))
        refused(dc.replacingOccurrences(of: "{", with: "{\"latitude\":38.9,"))
        // another area's codes with the DC name, or DC's with another name: neither home nor the test area
        refused(good.replacingOccurrences(of: "\"Example\"", with: "\"District of Columbia\""))
        refused(good.replacingOccurrences(of: "ZZZ041", with: "DCZ001").replacingOccurrences(of: "ZZC183", with: "DCC001"))
        // DC's letters as home's, with any other code, are never home: only the exact test area, where allowed
        refused(good.replacingOccurrences(of: "ZZZ", with: "DCZ").replacingOccurrences(of: "ZZC", with: "DCC"))
        XCTAssertThrowsError(try read(good.replacingOccurrences(of: "ZZZ", with: "DCZ").replacingOccurrences(of: "ZZC", with: "DCC")))
    }
}
