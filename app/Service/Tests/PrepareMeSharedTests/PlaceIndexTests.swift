import Foundation
@testable import PrepareMeShared
import XCTest

/// "Find a place" (plan phase 9, item 7): the name list inside a map file the Mac made (the shared sample, which
/// librarian/tests/test_streetmap.py rebuilds with the real code), and the search over it. Made-up names in open ocean.
final class PlaceIndexTests: XCTestCase {
    var sample: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/street-map-with-places.pmtiles")
    }

    func testTheNamesAreFoundInsideTheMapFile() throws {
        XCTAssertNil(StreetMap.problem(sample), "the list inside it leaves it a whole map file")
        let index = try XCTUnwrap(PlaceIndex(mapFile: sample))
        XCTAssertEqual(index.places.map(\.name).sorted(), ["Made Up Hospital", "Made Up Road", "Madeupville"])
        XCTAssertEqual(index.places.first { $0.name == "Madeupville" }?.kind, "town")
    }

    func testSearchStartsWithFirstThenNearestOrTownsFirst() throws {
        let index = PlaceIndex(places: [
            .init(name: "Oak Street", kind: "road", longitude: -40.0, latitude: 10.0),
            .init(name: "Oakdale", kind: "town", longitude: -41.0, latitude: 11.0),
            .init(name: "Big Oak Clinic", kind: "clinic", longitude: -40.01, latitude: 10.01),
            .init(name: "Pine Hollow", kind: "village", longitude: -40.0, latitude: 10.0),
        ])
        XCTAssertEqual(index.search("oak").map(\.name), ["Oakdale", "Oak Street", "Big Oak Clinic"],
                       "names starting with it first; with no position, towns before roads")
        XCTAssertEqual(index.search("OAK", near: (10.0, -40.0)).map(\.name), ["Oak Street", "Oakdale", "Big Oak Clinic"],
                       "with a position, the nearest of those that start with it first")
        XCTAssertEqual(index.search("hollów").map(\.name), ["Pine Hollow"], "any case or accent")
        XCTAssertEqual(index.search("  "), [])
    }

    func testCurlyAndStraightApostrophesMatch() {
        let index = PlaceIndex(places: [
            .init(name: "Made Up Mill's Pond", kind: "water", longitude: -40.0, latitude: 10.0),
            .init(name: "Made Up Ann\u{2019}s Clinic", kind: "clinic", longitude: -40.0, latitude: 10.0),
        ])
        XCTAssertEqual(index.search("mill\u{2019}s").map(\.name), ["Made Up Mill's Pond"], "the keyboard's curly one")
        XCTAssertEqual(index.search("ann's").map(\.name), ["Made Up Ann\u{2019}s Clinic"])
    }

    func testAMapWithoutAListHasNone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("no-list-\(UUID()).pmtiles")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a map".utf8).write(to: file)
        XCTAssertNil(PlaceIndex(mapFile: file))
        XCTAssertNil(Gzip.inflate(Data("not gzip at all, but long enough".utf8)))
    }

    /// Owner, 2026-10-14: search by what a place is, named or not, nearest first.
    func testAKindIsFoundByWhatItIsNearestFirst() {
        let index = PlaceIndex(places: [
            .init(name: "", kind: "drinking_water", longitude: -40.0, latitude: 10.5),
            .init(name: "Made Up Springs", kind: "town", longitude: -40.0, latitude: 10.3),
            .init(name: "", kind: "spring", longitude: -40.0, latitude: 10.1),
            .init(name: "Made Up Drugs", kind: "pharmacy", longitude: -40.0, latitude: 10.2),
            .init(name: "Waterside Road", kind: "road", longitude: -40.0, latitude: 10.05),
        ])
        XCTAssertEqual(index.search("water", near: (10.0, -40.0)).map(\.title),
                       ["Waterside Road", "Spring", "Drinking water"],
                       "named Water… and every kind of water, nearest first")
        XCTAssertEqual(index.search("PHARM", near: (10.0, -40.0)).map(\.title), ["Made Up Drugs"])
        XCTAssertEqual(index.search("wa").map(\.title), ["Waterside Road"], "two letters find names, no kind")
        XCTAssertEqual(PlaceIndex.kindWords("fuel"), "Gas station")
    }

    /// The list's own reader (a stress test, 2026-10-14: it replaced JSONSerialization to keep memory down): escapes,
    /// any whitespace and key order, non-ASCII names; anything off the format refused whole.
    func testTheListReaderReadsTheFormatAndNothingElse() throws {
        let json = #"{ "places": [["Made \"Up\" Caf\u00e9", 1, -40.5, 10.25], ["Ann’s \ud83c\udf33 Oak", 0, -41, 11e0]],"#
            + #" "kinds" : ["town", "cafe"], "format": 1 }"#
        let index = try XCTUnwrap(PlaceIndex(list: Data(json.utf8)))
        XCTAssertEqual(index.places, [
            .init(name: "Made \"Up\" Café", kind: "cafe", longitude: -40.5, latitude: 10.25),
            .init(name: "Ann’s 🌳 Oak", kind: "town", longitude: -41, latitude: 11),
        ])
        XCTAssertEqual(index.search("cafe").map(\.name), ["Made \"Up\" Café"], "accents folded")
        XCTAssertEqual(index.search("ann's").count, 1)
        for bad in [#"{"format":2,"kinds":[],"places":[]}"#, #"{"format":1,"kinds":["a"],"places":[["x",1,0,0]]}"#,
                    #"{"format":1,"kinds":["a"],"places":[["x",0,0]]}"#, #"{"format":1,"kinds":["a"],"places":[]} x"#,
                    #"{"format":1,"kinds":["a"],"places":[["x",0.5,0,0]]}"#, #"{"format":1,"kinds":["a"],"extra":1}"#,
                    #"{"format":1,"kinds":["a"],"places":[["unended,0,0,0]]}"#, ""] {
            XCTAssertNil(PlaceIndex(list: Data(bad.utf8)), bad)
        }
        XCTAssertEqual(PlaceIndex(list: Data(#"{"format":1,"kinds":[],"places":[]}"#.utf8))?.count, 0)
    }

    func testOneRoadsPiecesNearbyAreFoundOnce() {
        let index = PlaceIndex(places: [
            .init(name: "Made Up Road", kind: "road", longitude: -40.0, latitude: 10.0),
            .init(name: "Made Up Road", kind: "road", longitude: -40.003, latitude: 10.0),  // about 330 m on
            .init(name: "Made Up Road", kind: "road", longitude: -40.1, latitude: 10.0),  // another town's
            .init(name: "", kind: "drinking_water", longitude: -40.0, latitude: 10.0),
            .init(name: "", kind: "drinking_water", longitude: -40.0001, latitude: 10.0),
        ])
        XCTAssertEqual(index.search("made up road", near: (10.0, -40.0)).count, 2)
        XCTAssertEqual(index.search("water", near: (10.0, -40.0)).count, 2, "unnamed taps are each their own")
    }
}
