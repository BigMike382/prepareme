import Foundation
import PrepareMeShared
import XCTest

/// What a phone may post to the Mac: exactly one shape, and "couldn't read" never looks like "none".
final class CountsReportTests: XCTestCase {
    func body(_ text: String) -> Data { Data(text.utf8) }

    func good(_ extra: String = "") -> String {
        "{\"at\":\"2026-10-12T21:07Z\",\"read\":true,\"alerts\":2,\"events\":1,\"no_vtec\":0\(extra)}"
    }

    func problem(_ text: String) -> CountsReport.Problem? {
        do { _ = try CountsReport.read(body(text)); return nil } catch { return error as? CountsReport.Problem }
    }

    func testAGoodReadReportIsAccepted() throws {
        let report = try CountsReport.read(body(good()))
        XCTAssertEqual(report, CountsReport(at: "2026-10-12T21:07Z",
                                            counts: AlertCounts(alerts: 2, events: 1, noVTEC: 0)))
    }

    func testAGoodCouldNotReadReportHasNoCountsOrNullCounts() throws {
        let bare = try CountsReport.read(body("{\"at\":\"2026-10-12T21:07Z\",\"read\":false}"))
        XCTAssertFalse(bare.read)
        XCTAssertNil(bare.alerts)
        let nulls = "{\"at\":\"2026-10-12T21:07Z\",\"read\":false,\"alerts\":null,\"events\":null,\"no_vtec\":null}"
        XCTAssertEqual(try CountsReport.read(body(nulls)), bare)
    }

    func testACouldNotReadReportWithACountIsRefused() {
        XCTAssertEqual(problem("{\"at\":\"2026-10-12T21:07Z\",\"read\":false,\"alerts\":0}"), .badCounts)
    }

    func testAReadReportMissingACountIsRefused() {
        XCTAssertEqual(problem("{\"at\":\"2026-10-12T21:07Z\",\"read\":true,\"alerts\":1,\"events\":1}"), .badCounts)
    }

    func testAnExtraKeyAndAnOversizeBodyAreRefused() {
        XCTAssertEqual(problem(good(",\"zone\":\"x\"")), .unknownKey)
        XCTAssertEqual(problem(good() + String(repeating: " ", count: 1100)), .tooBig)
        XCTAssertEqual(problem("[1]"), .notAnObject)
        XCTAssertEqual(problem("nope"), .notAnObject)
    }

    func testOnlyARealUTCMinuteIsAcceptedAsATime() {
        for at in ["2026-10-12T21:07:00Z", "2026-13-01T00:00Z", "2026-10-12T25:00Z", "2026-10-12T21:07+05:00", ""] {
            XCTAssertEqual(problem("{\"at\":\"\(at)\",\"read\":false}"), .badTime, at)
        }
        XCTAssertNil(problem("{\"at\":\"2026-10-12T21:07Z\",\"read\":false}"))
    }

    func testCountsOutsideZeroToNineNineNineOrNotWholeNumbersAreRefused() {
        func with(_ value: String) -> String {
            "{\"at\":\"2026-10-12T21:07Z\",\"read\":true,\"alerts\":\(value),\"events\":0,\"no_vtec\":0}"
        }
        XCTAssertNil(problem(with("999")))
        XCTAssertNil(problem(with("0")))
        for bad in ["-1", "1000", "1.5", "true", "\"3\"", "null"] {
            XCTAssertEqual(problem(with(bad)), .badCounts, bad)
        }
    }

    func testReadGivenAsANumberIsRefused() {
        XCTAssertEqual(problem("{\"at\":\"2026-10-12T21:07Z\",\"read\":1,\"alerts\":0,\"events\":0,\"no_vtec\":0}"),
                       .badCounts)
        XCTAssertEqual(problem("{\"at\":\"2026-10-12T21:07Z\",\"read\":0}"), .badCounts)
    }

    func testEncodedReportsReadBackTheSame() throws {
        let read = CountsReport(at: "2026-10-12T21:07Z", counts: AlertCounts(alerts: 3, events: 2, noVTEC: 1))
        XCTAssertEqual(try CountsReport.read(read.encoded()), read)
        let unread = CountsReport(at: "2026-10-12T21:07Z", counts: nil)
        XCTAssertEqual(try CountsReport.read(unread.encoded()), unread)
    }

    func testMinuteFormatsUTCAndIsMinuteChecksTheShape() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(CountsReport.minute(date), "1970-01-01T00:00Z")
        XCTAssertTrue(CountsReport.isMinute(CountsReport.minute(Date())))
        XCTAssertFalse(CountsReport.isMinute("1970-01-01 00:00Z"))
    }
}
