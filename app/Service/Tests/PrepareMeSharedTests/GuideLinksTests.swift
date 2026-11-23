import Foundation
import PrepareMeShared
import XCTest

/// A guide's links to the house's things (household/guide-links.json; phase 14, F57): read exactly as
/// packer/guide_links.py writes it (pinned by Fixtures/guide-links.json, which packer's tests also check), refused for
/// any other shape, and matched against item names by whole words.
final class GuideLinksTests: XCTestCase {
    func read(_ text: String) throws -> GuideLinks { try GuideLinks(Data(text.utf8)) }

    var fixture: GuideLinks {
        get throws {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/guide-links.json")
            return try GuideLinks(try Data(contentsOf: url))
        }
    }

    func testReadsTheFixture() throws {
        XCTAssertEqual(GuideLinks.path, "household/guide-links.json")
        XCTAssertEqual(try fixture.guides, [
            GuideLinks.Guide(page: "offline-maps.html", title: "SAMPLE Paper maps", words: ["map", "compass"]),
            GuideLinks.Guide(page: "severe-bleeding.html", title: "SAMPLE Stopping heavy bleeding",
                             words: ["tourniquet", "pressure bandage"]),
        ])
    }

    func testRefusesAnyOtherShape() {
        for text in [
            #"{"format":2,"guides":[]}"#,
            #"{"format":1,"guides":[],"extra":1}"#,
            #"{"format":1,"format":1,"guides":[]}"#,
            #"{"format":1.0,"guides":[]}"#,
            #"{"format":1,"guides":[{"page":"a.pdf","title":"T","words":["gauze"]}]}"#,
            #"{"format":1,"guides":[{"page":"a.html","title":" ","words":["gauze"]}]}"#,
            #"{"format":1,"guides":[{"page":"a.html","title":"T","words":[]}]}"#,
            #"{"format":1,"guides":[{"page":"a.html","title":"T","words":["Gauze"]}]}"#,
            #"{"format":1,"guides":[{"page":"a.html","title":"T","words":["ab"]}]}"#,
            #"{"format":1,"guides":[{"page":"a.html","title":"T","words":["gauze","gauze"]}]}"#,
            #"{"format":1,"guides":[{"page":"a.html","title":"T","words":["gauze"],"x":1}]}"#,
        ] {
            XCTAssertThrowsError(try read(text), text) { error in
                XCTAssertEqual(error as? GuideLinks.Problem, .notTheShape)
            }
        }
        XCTAssertNoThrow(try read(#"{"format":1,"guides":[]}"#))
    }

    func testItemLinksItsGuide() throws {
        let links = try fixture
        XCTAssertEqual(links.guides(forItem: "Tourniquets (CAT, black)").map(\.page), ["severe-bleeding.html"])
        XCTAssertEqual(links.guides(forItem: "Israeli PRESSURE bandage, 6 in").map(\.page), ["severe-bleeding.html"])
        XCTAssertEqual(links.guides(forItem: "Road maps of the county").map(\.page), ["offline-maps.html"])
        XCTAssertEqual(links.guides(forItem: "Compasses").map(\.page), ["offline-maps.html"])
        XCTAssertEqual(links.guides(forItem: "Map and compass kit").map(\.page), ["offline-maps.html"])
        let both = GuideLinks(guides: try fixture.guides + [
            GuideLinks.Guide(page: "a.html", title: "A", words: ["tourniquet"])])
        XCTAssertEqual(both.guides(forItem: "Tourniquet").map(\.page), ["severe-bleeding.html", "a.html"])
    }

    func testNoLinkWithoutAMatch() throws {
        let links = try fixture
        for name in ["Maple syrup", "Bandage", "Pressure cooker", "Mapping pens", "Tourniquet-style strap",
                     "", "Compassion"] {
            XCTAssertEqual(links.guides(forItem: name).map(\.page),
                           name == "Tourniquet-style strap" ? ["severe-bleeding.html"] : [], name)
        }
        XCTAssertTrue(GuideLinks.matches("Crème brûlée torch", ["creme brulee"]), "accents fold")
        XCTAssertFalse(GuideLinks.matches("bandage pressure", ["pressure bandage"]), "in order")
    }

    func testTheHouseLink() throws {
        let url = try XCTUnwrap(URL(string:
            "prepareme://inventory?for=SAMPLE%20Stopping%20heavy%20bleeding&words=tourniquet,pressure%20bandage"))
        let link = try XCTUnwrap(GuideLinks.houseLink(url))
        XCTAssertEqual(link.title, "SAMPLE Stopping heavy bleeding")
        XCTAssertEqual(link.words, ["tourniquet", "pressure bandage"])
        XCTAssertNil(GuideLinks.houseLink(try XCTUnwrap(URL(string: "prepareme://streetmap"))))
        XCTAssertNil(GuideLinks.houseLink(try XCTUnwrap(URL(string: "prepareme://inventory?for=T&words=Ab,x"))))
        XCTAssertNil(GuideLinks.houseLink(try XCTUnwrap(URL(string: "prepareme://inventory?words=gauze"))))
        XCTAssertEqual(GuideLinks.houseLink(try XCTUnwrap(URL(string:
            "prepareme://inventory?for=T&words=GAUZE,gauze,chest%20seal")))?.words, ["gauze", "chest seal"])
        // as packer.guide_links.house_url writes one (quote(safe='')): every character of a title comes back
        let made = try XCTUnwrap(GuideLinks.houseLink(try XCTUnwrap(URL(string:
            "prepareme://inventory?for=Fire%20%26%20smoke%3A%20%22what%22%20%2B%20Cr%C3%A8me%20100%25"
            + "&words=gauze,chest%20seal"))))
        XCTAssertEqual(made.title, "Fire & smoke: \"what\" + Crème 100%")
        XCTAssertEqual(made.words, ["gauze", "chest seal"])
    }

    func testTheWords() {
        XCTAssertEqual(GuideLinks.howToUse, "How to use it")
        XCTAssertEqual(GuideLinks.houseTitle, "In the House")
    }
}
