import Foundation
import PrepareMeShared
import XCTest

/// What a phone may post as feed counts: exactly one shape, counts only, and "couldn't read" never looks like zero.
final class FeedCountsReportTests: XCTestCase {
    let at = "2026-10-12T21:07Z"

    func accepted(_ text: String) -> FeedCountsReport? {
        try? FeedCountsReport.read(Data(text.utf8))
    }

    func refused(_ text: String, _ note: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try FeedCountsReport.read(Data(text.utf8)), note, file: file, line: line) {
            XCTAssertEqual($0 as? FeedCountsReport.Problem, .notTheShape, note, file: file, line: line)
        }
    }

    func report(at: String? = nil, feeds: String = "{\"storms\":{\"storms\":2}}", unread: String = "[]") -> String {
        "{\"at\":\"\(at ?? self.at)\",\"feeds\":\(feeds),\"unread\":\(unread)}"
    }

    func testAGoodReportIsAcceptedAndRoundTrips() throws {
        let full = FeedCountsReport(
            at: at,
            feeds: ["home-alerts": ["alerts": 2, "events": 1, "no_vtec": 0], "evacuations": ["orders": 0, "names_home": 1],
                    "outages": ["home": 0], "gauges": ["flood": 3, "unread": 999]],
            unread: ["tropical-outlook", "storms"])
        XCTAssertEqual(full.unread, ["storms", "tropical-outlook"], "kept sorted")
        let back = try FeedCountsReport.read(full.encoded())
        XCTAssertEqual(back, full)
        XCTAssertEqual(try back.encoded(), try full.encoded())
        XCTAssertEqual(accepted(report())?.feeds["storms"], ["storms": 2])
    }

    func testEveryFeedHasItsOwnKeysAndEachIsAccepted() throws {
        XCTAssertEqual(Set(FeedCounts.keys.keys), ["home-alerts", "evacuations", "outages", "gauges", "storms",
                                                   "tropical-outlook"])
        for (feed, keys) in FeedCounts.keys {
            let counts = keys.map { "\"\($0)\":1" }.joined(separator: ",")
            XCTAssertNotNil(accepted(report(feeds: "{\"\(feed)\":{\(counts)}}")), feed)
        }
    }

    func testAnEmptyReportIsAccepted() throws {
        let empty = try XCTUnwrap(accepted(report(feeds: "{}")))
        XCTAssertTrue(empty.feeds.isEmpty)
        XCTAssertTrue(empty.unread.isEmpty)
    }

    func testAnOversizeBodyIsRefused() {
        XCTAssertNotNil(accepted(report()))
        let justUnder = report() + String(repeating: " ", count: FeedCountsReport.maxBytes - report().utf8.count)
        XCTAssertNotNil(accepted(justUnder), "exactly 2 KB is fine")
        refused(justUnder + " ", "one byte over 2 KB")
        refused(report() + String(repeating: " ", count: 3000))
    }

    func testNotAnObjectIsRefused() {
        for text in ["[1]", "nope", "", "null", "\"x\"", "3"] { refused(text, text) }
    }

    func testAnExtraOrMissingTopLevelKeyIsRefused() {
        refused("{\"at\":\"\(at)\",\"feeds\":{},\"unread\":[],\"zone\":\"x\"}", "extra key")
        refused("{\"feeds\":{},\"unread\":[]}", "no at")
        refused("{\"at\":\"\(at)\",\"unread\":[]}", "no feeds")
        refused("{\"at\":\"\(at)\",\"feeds\":{}}", "no unread")
    }

    func testOnlyARealUTCMinuteIsAcceptedAsATime() {
        for bad in ["2026-10-12T21:07", "2026-10-12T21:07:00Z", "2026-13-01T00:00Z", "2026-10-12T25:00Z",
                    "2026-02-30T10:00Z", "2026-10-12T21:07+05:00", ""] {
            refused(report(at: bad), bad)
        }
        refused("{\"at\":5,\"feeds\":{},\"unread\":[]}", "not a string")
    }

    func testAnUnknownFeedIsRefused() {
        refused(report(feeds: "{\"zone-forecast\":{\"storms\":1}}"))
    }

    func testAFeedMustHaveExactlyItsOwnCountKeys() {
        refused(report(feeds: "{\"home-alerts\":{\"alerts\":1,\"events\":1}}"), "missing no_vtec")
        refused(report(feeds: "{\"home-alerts\":{\"alerts\":1,\"events\":1,\"no_vtec\":0,\"zone\":1}}"), "extra")
        refused(report(feeds: "{\"storms\":{\"chance\":1}}"), "another feed's key")
        refused(report(feeds: "{\"storms\":{}}"), "none")
        refused(report(feeds: "{\"storms\":3}"), "not an object")
        refused(report(feeds: "[]"), "feeds not an object")
    }

    func testCountsOutsideZeroToNineNineNineOrNotWholeNumbersAreRefused() {
        func with(_ value: String) -> String { report(feeds: "{\"storms\":{\"storms\":\(value)}}") }
        XCTAssertNotNil(accepted(with("0")))
        XCTAssertNotNil(accepted(with("999")))
        for bad in ["-1", "1000", "2.5", "true", "false", "\"3\"", "null", "[1]", "{}"] {
            refused(with(bad), bad)
        }
    }

    func testUnreadMustNameKnownFeedsReadNowhereElseAndOnlyOnce() throws {
        let some = try XCTUnwrap(accepted(report(unread: "[\"outages\",\"gauges\"]")))
        XCTAssertEqual(some.unread, ["gauges", "outages"])
        refused(report(unread: "[\"zone-forecast\"]"), "unknown feed")
        refused(report(unread: "[\"storms\"]"), "also in feeds")
        refused(report(unread: "[\"outages\",\"outages\"]"), "repeated")
        refused(report(unread: "[3]"), "not a name")
        refused(report(unread: "\"outages\""), "not a list")
    }
}
