import Foundation
import PrepareMeShared
import XCTest

/// The phone's ports of the Mac's feed readers (plan phase 5), held to the Mac's own readers' output: every case in
/// the shared cases (SharedCases), which dashboard/tests/phone_cases.py writes from dashboard/weather.py and
/// dashboard/local.py on the recorded samples and on made-up answers, with the state's file the outage reader checks
/// counties against.
final class ConditionFeedsTests: XCTestCase {
    struct Case: Decodable {
        let name: String, reader: String, input: String
        let now: String?, county: String?, id: String?
        let items: [ConditionItem]?
        let error: String?
        let rows: [[String]]??
    }

    struct Cases: Decodable {
        let cases: [Case]
    }

    static func load() throws -> Cases {
        let url = try SharedCases.url.skippingWhenAbsent()
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
    }

    func read(_ found: Case) throws -> [ConditionItem] {
        let data = Data(found.input.utf8)
        let now = found.now.flatMap(ConditionTime.moment) ?? Date()
        switch found.reader {
        case "gauge": return try MacFeeds.gauge(data, now: now)
        case "crest": return try MacFeeds.crest(data, now: now)
        case "tropical_outlook": return try MacFeeds.tropicalOutlook(data)
        case "storms": return try MacFeeds.storms(data)
        case "outages": return try MacFeeds.outages(data, county: found.county!, area: SharedCases.area())
        case "evacuations": return try MacFeeds.evacuations(data, county: found.county!)
        default: throw FeedFormatError("no reader \(found.reader)")
        }
    }

    func testEveryCaseReadsAsTheMacReadsIt() throws {
        let all = try Self.load().cases
        XCTAssertGreaterThan(all.count, 30)
        for found in all {
            if found.reader == "table_rows" {
                XCTAssertEqual(HTMLTable.rows(found.input, id: found.id!), found.rows ?? nil, found.name)
                continue
            }
            do {
                let items = try read(found)
                XCTAssertNil(found.error, "\(found.name): read, but the Mac refused it")
                XCTAssertEqual(items, found.items, found.name)
            } catch let error as FeedFormatError {
                XCTAssertEqual(error.message, found.error, found.name)
            }
        }
    }

    /// Times read in the forms Python's fromisoformat reads (whole-branch review M2), each the same moment.
    func testTimesReadInEveryFormTheMacReads() {
        let moment = ConditionTime.moment("2026-10-06T14:00:00Z")
        XCTAssertNotNil(moment)
        for form in ["2026-10-06T14:00Z", "2026-10-06T14:00:00+0000", "2026-10-06T10:00-04:00", "2026-10-06T10:00:00-0400",
                     "2026-10-06T14:00:00.000Z", "2026-10-06T10:00:00.000000-04:00", "2026-10-06 10:00:00-04:00"] {
            XCTAssertEqual(ConditionTime.moment(form), moment, form)
        }
        for bad in ["2026-10-06T14:00:00", "0001-01-01T00:00:00Z", "yesterday", ""] {
            XCTAssertNil(ConditionTime.moment(bad), bad)
        }
    }

    /// Character references decode as Python's html.unescape decodes them (the Mac's table reader).
    func testCharacterReferencesDecodeAsTheMacDecodesThem() throws {
        struct Entity: Decodable { let text, decoded: String }
        struct File: Decodable { let entities: [Entity] }
        let url = try SharedCases.url.skippingWhenAbsent()
        let entities = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).entities
        XCTAssertGreaterThan(entities.count, 10)
        for found in entities {
            XCTAssertEqual(Entities.decode(found.text).unicodeScalars.map(\.value),
                           found.decoded.unicodeScalars.map(\.value), found.text)
        }
    }
}
