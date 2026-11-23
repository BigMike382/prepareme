import Foundation
import PrepareMeShared
import XCTest

/// The Mac's guide-groups list (household/guide-topics.json): read exactly as packer/guide_topics.py writes it
/// (pinned by Fixtures/guide-topics.json, which packer's tests also check) and refused for any other shape, so a
/// bad list leaves the Mac with Guides and New only.
final class GuideTopicsTests: XCTestCase {
    let good = #"{"format":1,"new":{"count":2,"page":"new-guides.html"},"topics":[{"count":3,"name":"Medical","page":"topic-medical.html","subs":[{"anchor":"emergency-first-aid","count":2,"name":"Emergency First Aid"}]},{"count":1,"name":"Radio, Phones, Maps","page":"topic-radio-phones-maps.html","subs":[]}]}"#

    func read(_ text: String) throws -> GuideTopics { try GuideTopics(Data(text.utf8)) }

    func assertRefused(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try read(text), text, file: file, line: line) { error in
            XCTAssertEqual(error as? GuideTopics.Problem, .notTheShape, file: file, line: line)
        }
    }

    func testReadsTheFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/guide-topics.json")
        let topics = try GuideTopics(try Data(contentsOf: url))
        XCTAssertEqual(GuideTopics.path, "household/guide-topics.json")
        XCTAssertEqual(topics.newPage, "new-guides.html")
        XCTAssertEqual(topics.newCount, 2)
        XCTAssertEqual(topics.topics.map(\.name), ["Our Home", "Medical", "Radio, Phones, Maps"])
        XCTAssertEqual(topics.topics[0].page, "topic-our-household.html")
        XCTAssertEqual(topics.topics[0].subs, [])
        XCTAssertEqual(topics.topics[1].count, 3)
        XCTAssertEqual(topics.topics[1].subs, [
            GuideTopics.Sub(name: "Emergency First Aid", anchor: "emergency-first-aid", count: 2),
            GuideTopics.Sub(name: "Illness, Medicines", anchor: "illness-medicines", count: 1),
        ])
        XCTAssertEqual(topics.topics[2].page, "topic-radio-phones-maps.html")
    }

    func testTheGoodListReads() throws {
        let topics = try read(good)
        XCTAssertEqual(topics.newCount, 2)
        XCTAssertEqual(topics.topics.count, 2)
    }

    func testRefusesFormat2() {
        assertRefused(good.replacingOccurrences(of: "\"format\":1", with: "\"format\":2"))
        assertRefused(good.replacingOccurrences(of: "\"format\":1", with: "\"format\":true"))
        assertRefused(good.replacingOccurrences(of: "\"format\":1", with: "\"format\":\"1\""))
        assertRefused(good.replacingOccurrences(of: "\"format\":1", with: "\"format\":1.0"))
    }

    func testRefusesExtraKey() {
        assertRefused(good.replacingOccurrences(of: "{\"format\"", with: "{\"extra\":1,\"format\""))
        assertRefused(good.replacingOccurrences(of: "\"count\":2,\"page\"", with: "\"count\":2,\"x\":1,\"page\""))
        assertRefused(good.replacingOccurrences(of: "\"name\":\"Medical\"", with: "\"name\":\"Medical\",\"x\":1"))
        assertRefused(good.replacingOccurrences(of: "\"name\":\"Emergency First Aid\"", with: "\"name\":\"Emergency First Aid\",\"x\":1"))
    }

    func testRefusesAMissingKeyOrARepeatedKey() {
        assertRefused(good.replacingOccurrences(of: "\"subs\":[]", with: "\"zz\":[]"))
        assertRefused(good.replacingOccurrences(of: "{\"format\":1,", with: "{\"format\":1,\"format\":1,"))
        assertRefused(good.replacingOccurrences(of: "\"name\":\"Medical\"", with: "\"name\":\"Medical\",\"name\":\"Medical\""))
    }

    func testRefusesBadPage() {
        for page in ["../x.html", "topic-.html", "topic-Medical.html", "topic-medical.htm", "medical.html",
                     "topic-medical.html\\n", "topic-a/b.html", ""] {
            assertRefused(good.replacingOccurrences(of: "topic-medical.html", with: page))
        }
        assertRefused(good.replacingOccurrences(of: "new-guides.html", with: "other.html"))
    }

    func testRefusesBadAnchor() {
        for anchor in ["Emergency", "a b", "a_b", "", "#x", "a\\n"] {
            assertRefused(good.replacingOccurrences(of: "\"emergency-first-aid\"", with: "\"\(anchor)\""))
        }
    }

    func testRefusesBoolCount() {
        assertRefused(good.replacingOccurrences(of: "\"count\":2,\"page\"", with: "\"count\":true,\"page\""))
        assertRefused(good.replacingOccurrences(of: "\"count\":3", with: "\"count\":false"))
        assertRefused(good.replacingOccurrences(of: "\"count\":2,\"name\"", with: "\"count\":true,\"name\""))
    }

    func testRefusesBadCountsAndNames() {
        assertRefused(good.replacingOccurrences(of: "\"count\":3", with: "\"count\":-1"))
        assertRefused(good.replacingOccurrences(of: "\"count\":3", with: "\"count\":3.5"))
        assertRefused(good.replacingOccurrences(of: "\"count\":3", with: "\"count\":\"3\""))
        assertRefused(good.replacingOccurrences(of: "\"name\":\"Medical\"", with: "\"name\":\"\""))
        assertRefused(good.replacingOccurrences(of: "\"name\":\"Medical\"", with: "\"name\":\"  \""))
        assertRefused(good.replacingOccurrences(of: "\"name\":\"Medical\"", with: "\"name\":7"))
    }

    func testEmptyTopicsIsFine() throws {
        let topics = try read(#"{"format":1,"new":{"count":0,"page":"new-guides.html"},"topics":[]}"#)
        XCTAssertEqual(topics.topics, [])
        XCTAssertEqual(topics.newCount, 0)
    }

    func testNotJSONIsRefused() {
        assertRefused("")
        assertRefused("nope")
        assertRefused("[]")
        assertRefused(String(good.dropLast()))
    }
}
