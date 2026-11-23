import Foundation
@testable import PrepareMeServer
import PrepareMeShared
import XCTest

/// The phones' feed counts at the library service (plan phase 5): the store keeps them by phone label, and the
/// library router takes them at `POST /counts`. Made-up values in a fresh temporary folder, no network.
final class FeedCountsStoreTests: XCTestCase {
    var root: URL!
    var served: URL!
    var tokens: TokenStore!
    var store: FeedCountsStore!
    var router: Router!
    var token = ""
    let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-feedcounts-\(UUID())")
        served = root.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        tokens = TokenStore(url: root.appendingPathComponent("tokens.json"))
        token = try tokens.add(now: now).token
        store = FeedCountsStore(url: root.appendingPathComponent("jobs").appendingPathComponent("phone-feed-counts.json"))
        router = Router(folder: served, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                        manifestOnly: true, feedCounts: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func report(_ at: String, storms: Int = 1, unread: [String] = []) -> FeedCountsReport {
        FeedCountsReport(at: at, feeds: ["storms": ["storms": storms]], unread: unread)
    }

    func minute(_ date: Date) -> String { CountsReport.minute(date) }

    func post(_ body: Data, token: String?, to router: Router? = nil) -> Reply {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer " + token }
        return (router ?? self.router).reply(to: HTTPRequest(method: "POST", path: "/counts", headers: headers,
                                                              body: body), now: now).0
    }

    func testAReportIsKeptUnderThePhonesLabelWithWhenItArrived() throws {
        try store.add(report("2026-10-12T21:07Z", storms: 2, unread: ["outages"]), from: "phone 1", now: now)
        let kept = try XCTUnwrap(store.readings()["phone 1"])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].at, "2026-10-12T21:07Z")
        XCTAssertEqual(kept[0].feeds, ["storms": ["storms": 2]])
        XCTAssertEqual(kept[0].unread, ["outages"])
        XCTAssertEqual(kept[0].received, ISO.now(now))
        XCTAssertNil(store.readings()["phone 2"])
    }

    func testNothingStoredReadsAsEmpty() {
        XCTAssertTrue(store.readings().isEmpty)
        try? FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{not json".utf8).write(to: store.url)
        XCTAssertTrue(store.readings().isEmpty, "a damaged file reads as none")
    }

    func testTheFileIsCreatedWithItsFolderAndHoldsCountsOnly() throws {
        try store.add(report(minute(now)), from: "phone 1", now: now)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"phones\""))
        XCTAssertTrue(text.contains("\"storms\""))
        XCTAssertFalse(text.contains("Bearer"))
        XCTAssertFalse(text.contains(token))
    }

    func testAnotherReportForTheSameMinuteReplacesTheFirst() throws {
        try store.add(report("2026-10-12T21:07Z", storms: 1), from: "phone 1", now: now)
        try store.add(report("2026-10-12T21:07Z", storms: 4), from: "phone 1", now: now)
        let kept = try XCTUnwrap(store.readings()["phone 1"])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].feeds["storms"]?["storms"], 4)
    }

    func testTheSameMinuteFromTwoPhonesIsKeptForBoth() throws {
        try store.add(report("2026-10-12T21:07Z"), from: "phone 1", now: now)
        try store.add(report("2026-10-12T21:07Z"), from: "phone 2", now: now)
        XCTAssertEqual(store.readings()["phone 1"]?.count, 1)
        XCTAssertEqual(store.readings()["phone 2"]?.count, 1)
    }

    func testReadingsAreKeptInTimeOrder() throws {
        let later = minute(now.addingTimeInterval(-3600)), earlier = minute(now.addingTimeInterval(-7200))
        try store.add(report(later), from: "phone 1", now: now)
        try store.add(report(earlier), from: "phone 1", now: now)
        XCTAssertEqual(store.readings()["phone 1"]?.map(\.at), [earlier, later])
    }

    func testReportsOlderThan30DaysAreDropped() throws {
        let old = minute(now.addingTimeInterval(-31 * 86400))
        let edge = minute(now.addingTimeInterval(-29 * 86400))
        try store.add(report(old), from: "phone 1", now: now.addingTimeInterval(-31 * 86400))
        try store.add(report(edge), from: "phone 1", now: now.addingTimeInterval(-29 * 86400))
        XCTAssertEqual(store.readings()["phone 1"]?.count, 2, "both were young when they came")
        try store.add(report(minute(now)), from: "phone 1", now: now)
        XCTAssertEqual(store.readings()["phone 1"]?.map(\.at), [edge, minute(now)])
    }

    // The router

    func testTheLibraryTakesAGoodFeedCountsReportAs204AndKeepsIt() throws {
        let answer = post(try report(minute(now), storms: 3).encoded(), token: token)
        XCTAssertEqual(answer.status, 204)
        let kept = try XCTUnwrap(store.readings().values.first)
        XCTAssertEqual(kept.first?.feeds["storms"]?["storms"], 3)
        XCTAssertEqual(store.readings().count, 1)
    }

    func testABadBodyIs400AndKeepsNothing() throws {
        for body in ["{\"at\":1}", "nope", "", "{\"at\":\"2026-10-12T21:07Z\",\"feeds\":{\"zone\":{}},\"unread\":[]}"] {
            XCTAssertEqual(post(Data(body.utf8), token: token).status, 400, body)
        }
        // phase 1's shape is not this one
        let phase1 = CountsReport(at: "2026-10-12T21:07Z", counts: AlertCounts(alerts: 1, events: 1, noVTEC: 0))
        XCTAssertEqual(post(try phase1.encoded(), token: token).status, 400)
        XCTAssertTrue(store.readings().isEmpty)
    }

    func testWithoutAFeedCountsStoreTheLibraryAnswers404() throws {
        let bare = Router(folder: served, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                          manifestOnly: true)
        XCTAssertEqual(post(try report(minute(now)).encode(), token: token, to: bare).status, 404)
    }

    func testWithoutAValidTokenTheAnswerIs401AndNothingIsKept() throws {
        let body = try report(minute(now)).encoded()
        XCTAssertEqual(post(body, token: nil).status, 401)
        XCTAssertEqual(post(body, token: "not-a-token").status, 401)
        XCTAssertTrue(store.readings().isEmpty)
    }

    func testTheProbeModeStillTakesPhase1sCountsReportAndNotFeedCounts() throws {
        let probeCounts = CountsStore(url: root.appendingPathComponent("probe-counts.json"))
        let probe = Router(folder: served, tokens: tokens, counts: probeCounts, feedCounts: store)
        let phase1 = CountsReport(at: "2026-10-12T21:07Z", counts: AlertCounts(alerts: 1, events: 1, noVTEC: 0))
        XCTAssertEqual(post(try phase1.encoded(), token: token, to: probe).status, 204)
        XCTAssertEqual(probeCounts.readings().values.first?.first?.alerts, 1)
        XCTAssertEqual(post(try report(minute(now)).encoded(), token: token, to: probe).status, 400)
        XCTAssertTrue(store.readings().isEmpty, "the probe never writes the feed store")
    }

    /// The file the store writes is the one dashboard/feed_counts.py reads (whole-branch review I3): this store's
    /// output, kept as PrepareMeSharedTests' Fixtures/conditions/phone-feed-counts.json, which
    /// dashboard/tests/test_feed_counts.py reads. Rewrite with PREPAREME_WRITE_FIXTURE=1 after a deliberate change.
    func testTheFileTheStoreWritesIsTheOneTheMacReads() throws {
        try store.add(FeedCountsReport(at: "2027-01-15T07:40Z",
                                       feeds: ["home-alerts": ["alerts": 1, "events": 1, "no_vtec": 0],
                                               "gauges": ["flood": 0, "unread": 1]],
                                       unread: ["outages"]), from: "phone 1", now: now)
        try store.add(FeedCountsReport(at: "2027-01-15T07:55Z", feeds: ["storms": ["storms": 2]], unread: []),
                      from: "phone 2", now: now)
        let written = try Data(contentsOf: store.url)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../PrepareMeSharedTests/Fixtures/conditions/phone-feed-counts.json").standardized
        if ProcessInfo.processInfo.environment["PREPAREME_WRITE_FIXTURE"] == "1" {
            try written.write(to: fixture)
        }
        XCTAssertEqual(String(decoding: try Data(contentsOf: fixture), as: UTF8.self),
                       String(decoding: written, as: UTF8.self))
    }
}

private extension FeedCountsReport {
    func encode() throws -> Data { try encoded() }

}
