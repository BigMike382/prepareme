import PrepareMeShared
import XCTest

/// The top bar's words on a small iPhone (F63, B2-17): the whole title, then its subject, then the tab's name, so a
/// title is never cut short with "…"
final class BarTitleTests: XCTestCase {
    func testTheWholeTitleThenItsSubjectThenTheTab() {
        XCTAssertEqual(BarTitle.choices(title: "Tornadoes: watches, warnings and safe rooms", tab: "Guides"),
                       ["Tornadoes: watches, warnings and safe rooms", "Tornadoes", "Guides"])
        XCTAssertEqual(BarTitle.choices(title: "Boiling water so it's safe to drink", tab: "Guides"),
                       ["Boiling water so it's safe to drink", "Guides"], "no colon: no subject")
        XCTAssertEqual(BarTitle.choices(title: "Today", tab: "Today"), ["Today"], "never the same words twice")
        XCTAssertEqual(BarTitle.choices(title: "", tab: "Maps"), ["Maps"], "a page without a title: the tab")
        XCTAssertEqual(BarTitle.choices(title: ": odd", tab: "Guides"), [": odd", "Guides"])
        XCTAssertEqual(BarTitle.choices(title: "Heart attack, stroke: signs", tab: "Guides")[1], "Heart attack, stroke")
    }
}
