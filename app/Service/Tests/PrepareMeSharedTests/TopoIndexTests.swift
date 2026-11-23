import Foundation
import PrepareMeShared
import XCTest

/// "Topo map for here" (plan phase 9, item 6): the Find a map page's links read as maps with corners. The page text is
/// the shape packer/map_pages.py writes (its test_each_map_link_carries_its_corners_for_the_street_map), made-up maps.
final class TopoIndexTests: XCTestCase {
    let page = """
    <li>PrepareMe: topo today 3 of 10: <a href="zim://c95b86fe-641e-4d76-aa9e-6b8e82cd8de2/ustopo-nc-sampleton.pdf" \
    data-bounds="-81 35.5 -80.875 35.625">Sampleton</a>, <a href="zim://c95b86fe-641e-4d76-aa9e-6b8e82cd8de2/ustopo-nc-b.pdf" \
    data-bounds="-80.875 35.5 -80.75 35.625">B &amp; C</a></li>
    <li>Again under another county: <a href="zim://c95b86fe-641e-4d76-aa9e-6b8e82cd8de2/ustopo-nc-sampleton.pdf" \
    data-bounds="-81 35.5 -80.875 35.625">Sampleton</a></li>
    <li>older editions: <a href="zim://11d15a18-fc9f-4da5-b924-16572f4bade2/topo-maps-in-this-file.html">older</a></li>
    """

    func testMapsAreReadOnceEachWithTheirCorners() {
        let index = TopoIndex(page: page)
        XCTAssertEqual(index.maps.map(\.name), ["Sampleton", "B & C"])
        XCTAssertEqual(index.maps[0].fileID, "c95b86fe-641e-4d76-aa9e-6b8e82cd8de2")
        XCTAssertEqual(index.maps[0].path, "ustopo-nc-sampleton.pdf")
        XCTAssertEqual([index.maps[0].west, index.maps[0].south, index.maps[0].east, index.maps[0].north],
                       [-81, 35.5, -80.875, 35.625])
        XCTAssertEqual(TopoIndex.url(index.maps[0])?.absoluteString,
                       "zim://c95b86fe-641e-4d76-aa9e-6b8e82cd8de2/ustopo-nc-sampleton.pdf")
    }

    func testTheMapForASpotAndBothOnAnEdge() {
        let index = TopoIndex(page: page)
        XCTAssertEqual(index.covering(longitude: -80.95, latitude: 35.55).map(\.name), ["Sampleton"])
        XCTAssertEqual(index.covering(longitude: -80.875, latitude: 35.55).map(\.name).sorted(), ["B & C", "Sampleton"])
        XCTAssertEqual(index.covering(longitude: -70, latitude: 35.55), [])
        XCTAssertEqual(TopoIndex(page: "<p>No maps</p>").maps, [])
    }

    func testOnlyMapsInFilesThePhoneHoldsAreOffered() {
        let index = TopoIndex(page: page)
        XCTAssertEqual(index.covering(longitude: -80.95, latitude: 35.55, held: []), [], "an optional file not taken")
        XCTAssertEqual(index.covering(longitude: -80.95, latitude: 35.55,
                                      held: ["C95B86FE-641E-4D76-AA9E-6B8E82CD8DE2"]).map(\.name), ["Sampleton"])
    }

    /// Maps opens Find a map (phase L, finding 1): the overview's front page is only a title and two links
    /// (packer/build.py's plain front page), so Maps opens Find a map beside it, as Guides opens guides.html; an
    /// overview without the page (an older or made-up file) opens its front page rather than a missing one.
    func testMapsOpensFindAMapBesideTheOverviewsFrontPage() async {
        let main = URL(string: "index.html", relativeTo: URL(string: "zim://11d15a18-fc9f-4da5-b924-16572f4bade2"))!
        let find = "zim://11d15a18-fc9f-4da5-b924-16572f4bade2/find-a-map.html"
        let found = await TopoIndex.firstPage(beside: main) { $0.absoluteString == find }
        XCTAssertEqual(found.absoluteString, find)
        let missing = await TopoIndex.firstPage(beside: main) { _ in false }
        XCTAssertEqual(missing, main, "no Find a map in the file: its front page")
    }

    /// The page's name is the packer's own (packer/map_pages.py MAP_PAGES["find"]), so the app never asks for a page
    /// the overview doesn't hold.
    func testThePageIsThePackersFindAMap() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packer = try String(contentsOf: repo.appendingPathComponent("packer/map_pages.py"), encoding: .utf8)
        XCTAssertTrue(packer.contains("\"find\": \"\(TopoIndex.page)\","),
                      "MAP_PAGES[\"find\"] isn't \(TopoIndex.page)")
    }
}
