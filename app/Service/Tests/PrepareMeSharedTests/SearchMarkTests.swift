import Foundation
import PrepareMeShared
import XCTest

/// The mark on a search result (owner, 2026-10-21): our pages show their group's emoji and a kind word, a map file's
/// pages and maps the maps' emoji, and any other library its plain name. Every mark has a word.
final class SearchMarkTests: XCTestCase {
    private let groups = ["water-bleach.html": "Water and Food", "made-up-steps.html": "Our Home",
                          "inventory.html": "Our Home", "sample-other.html": "Other", "adults.html": "For Adults",
                          "splint.html": "Medical"]
    private var daily: SearchMark.Library { .guides(groups: groups, title: "PrepareMe: guides & household") }

    func testOurPagesShowTheirGroupAndKind() {
        XCTAssertEqual(SearchMark.mark(path: "water-bleach.html", in: daily),
                       SearchMark(emoji: "💧", word: "Guide", group: "Water and Food"))
        XCTAssertEqual(SearchMark.mark(path: "splint.html", in: daily).emoji, "⛑️")
        XCTAssertEqual(SearchMark.mark(path: "made-up-steps.html", in: daily),
                       SearchMark(emoji: "🏠", word: "Our Home", group: "Our Home"))
        XCTAssertEqual(SearchMark.mark(path: "x.html", in: .guides(groups: ["x.html": "Our Household"], title: "")),
                       SearchMark(emoji: "🏠", word: "Our Home", group: "Our Household"),
                       "a library built before Our Home's name (2026-11-16)")
        XCTAssertEqual(SearchMark.mark(path: "sample-other.html", in: daily),
                       SearchMark(symbol: "doc.text", word: "Guide", group: "Other"), "no emoji: its sidebar symbol")
        XCTAssertEqual(SearchMark.mark(path: "adults.html", in: daily).symbol, "person")
        XCTAssertEqual(SearchMark.mark(path: "walkthrough-co-alarm.html", in: daily, walkthroughGroup: "Medical"),
                       SearchMark(emoji: "⛑️", word: "Walk-through", group: "Medical"))
        XCTAssertEqual(SearchMark.mark(path: "walkthrough-co-alarm-kids.html", in: daily).word, "Walk-through")
        XCTAssertEqual(SearchMark.mark(path: "walkthrough-co-alarm-kids.html", in: daily).emoji, nil,
                       "its guide not found: the word alone")
    }

    func testAPageNoGroupListsShowsTheLibrarysName() {
        XCTAssertEqual(SearchMark.mark(path: "guides.html", in: daily), SearchMark(word: "Guides and today's page"))
        XCTAssertEqual(SearchMark.mark(path: "index.html", in: daily).word, "Guides and today's page")
    }

    func testMapsAndOtherLibraries() {
        XCTAssertEqual(SearchMark.mark(path: "find-a-map.html", in: .maps), SearchMark(emoji: "🗺️", word: "Map page"))
        XCTAssertEqual(SearchMark.mark(path: "roads/Example County.PDF", in: .maps), SearchMark(emoji: "🗺️", word: "Map"))
        XCTAssertEqual(SearchMark.mark(path: "cholera.html", in: .other(title: "PrepareMe: reference")),
                       SearchMark(word: "Medical references and manuals"))
        XCTAssertEqual(SearchMark.mark(path: "A/Cholera", in: .other(title: "Wikipedia (English) Medicine")),
                       SearchMark(word: "Wikipedia (English) Medicine"), "a download's own title, as it is")
        XCTAssertEqual(SearchMark.mark(path: "x.html", in: .other(title: " ")).word, "Library", "no title")
        for library in [SearchMark.Library.maps, .other(title: ""), daily, .guides(groups: [:], title: "")] {
            XCTAssertFalse(SearchMark.mark(path: "x.html", in: library).word.isEmpty, "never a mark without a word")
        }
    }

    func testWhatVoiceOverSays() {
        XCTAssertEqual(SearchMark.mark(path: "water-bleach.html", in: daily).spoken, "Guide, Water and Food")
        XCTAssertEqual(SearchMark.mark(path: "made-up-steps.html", in: daily).spoken, "Our Home")
        XCTAssertEqual(SearchMark.mark(path: "x.pdf", in: .maps).spoken, "Map")
    }

    /// The category pages' shape (packer/tests/test_build.py pins the packer's side): the list items' links, never the
    /// link back to the guide list; a walk-through's group is its first listed link's
    func testTheGroupsComeFromTheCategoryPages() async throws {
        let medical = "<body class=\"guides-page side-page\"><p><a href=\"guides.html\">All guides</a></p><h1>Medical</h1>"
            + "<h2 id=\"first-aid\">First aid (2)</h2><ul><li><a href=\"water-bleach.html\"><span>★</span> Bleach</a>"
            + "</li><li><a href=\"splint.html\">Splint</a></li></ul><h2 id=\"x\">X (1)</h2><ul><li><a href=\"a&amp;b.html\">"
            + "AB</a></li></ul>"
        let radio = "<p><a href=\"guides.html\">All guides</a></p><ul><li><a href=\"radio.html\">Radio</a></li>"
            + "<li><a href=\"splint.html\">Splint again</a></li></ul>"
        XCTAssertEqual(SearchMark.listed(medical), ["water-bleach.html", "splint.html", "a&b.html"])
        let json = """
            {"format":1,"new":{"count":0,"page":"new-guides.html"},"topics":[\
            {"count":3,"name":"Medical","page":"topic-medical.html","subs":[]},\
            {"count":1,"name":"Radio, Phones, Maps","page":"topic-radio-phones-maps.html","subs":[]},\
            {"count":1,"name":"Gone","page":"topic-gone.html","subs":[]}]}
            """
        let topics = try GuideTopics(Data(json.utf8))
        let pages = ["topic-medical.html": medical, "topic-radio-phones-maps.html": radio]
        let found = await SearchMark.groups(topics) { pages[$0] }
        XCTAssertEqual(found, ["water-bleach.html": "Medical", "splint.html": "Medical", "a&b.html": "Medical",
                               "radio.html": "Radio, Phones, Maps"], "a page that can't be read is skipped")
        let walk = "<p>Step</p><a href=\"#s2\">Next</a><a href=\"guides.html\">Guides</a>"
            + "<a href=\"radio.html#top\">The whole guide</a>"
        XCTAssertEqual(SearchMark.walkthroughGroup(links: walk, groups: found), "Radio, Phones, Maps")
        XCTAssertNil(SearchMark.walkthroughGroup(links: "<p>No links</p>", groups: found))
        XCTAssertTrue(SearchMark.isWalkthrough("walkthrough-co-alarm.html"))
        XCTAssertFalse(SearchMark.isWalkthrough("walkthrough.html"))
        XCTAssertFalse(SearchMark.isWalkthrough("guides/walkthrough-x.html"))
    }
}
