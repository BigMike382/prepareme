import PrepareMeShared
import XCTest

/// The names behind Today's "Not in the library yet" line, for the Mac's Household pages screen (B2-26).
final class MissingPagesTests: XCTestCase {
    func testReadsTheNamesInOrder() {
        let page = "<ul class=\"go\"></ul>\n<p class=\"missing\">Not in the library yet: Rally points, How we reach each "
            + "other, Rumors &amp; facts.</p><p>Other</p>"
        XCTAssertEqual(MissingPages.names(inPage: page), ["Rally points", "How we reach each other", "Rumors & facts"])
    }

    func testNoLineOrOtherWordsGivesNothing() {
        XCTAssertEqual(MissingPages.names(inPage: "<p>Today</p>"), [])
        XCTAssertEqual(MissingPages.names(inPage: "<p class=\"missing\">Something else: A, B.</p>"), [])
        XCTAssertEqual(MissingPages.names(inPage: "<p class=\"missing\">Not in the library yet: .</p>"), [])
        XCTAssertEqual(MissingPages.names(inPage: ""), [])
    }

    func testAPageWithTwoOfTheSameNameKeepsTheClashNote() {
        let page = "<p class=\"missing\">Not in the library yet: Flood (more than one page has this name).</p>"
        XCTAssertEqual(MissingPages.names(inPage: page), ["Flood (more than one page has this name)"])
    }
}
