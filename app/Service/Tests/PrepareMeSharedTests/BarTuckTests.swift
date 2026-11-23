@testable import PrepareMeShared
import XCTest

/// The reading tabs' bar tucking away (FINDINGS F-079): it follows the reader's own scrolling, and the bar moving never
/// moves it again.
final class BarTuckTests: XCTestCase {
    /// One drag: each offset in turn, at the inset the bar's state gives (116 shown, 62 hidden, an iPhone's), the bar
    /// changed whenever the tuck says so. Returns how often it changed.
    private func drag(_ offsets: [Double], tuck: inout BarTuck, hidden: inout Bool) -> Int {
        var changes = 0
        for offset in offsets {
            if let now = tuck.scrolled(offset: offset, inset: hidden ? 62 : 116, hidden: hidden, byReader: true) {
                hidden = now
                changes += 1
            }
        }
        return changes
    }

    func testADragDownThePageTucksTheBarAwayOnceAndADragUpBringsItBack() {
        var tuck = BarTuck(), hidden = false
        XCTAssertEqual(drag(Array(stride(from: 0.0, through: 600, by: 10)), tuck: &tuck, hidden: &hidden), 1)
        XCTAssertTrue(hidden)
        XCTAssertEqual(drag(Array(stride(from: 600.0, through: 300, by: -10)), tuck: &tuck, hidden: &hidden), 1)
        XCTAssertFalse(hidden)
    }

    /// The Today bug (2026-10-16): the page's own position (offset plus inset) jumps by the bar's height each time the
    /// bar moves, which Kiwix's page script read as the reader turning back, about 20 times a second.
    func testTheBarMovingIsNeverReadAsTheReaderTurningBack() {
        // the scroll view's offset holds still while the inset changes under it; and when UIKit does move the offset
        // to make up for the inset, either way, that is the bar's doing, not the reader's
        for jump in [0.0, 54, -54] {
            for down in [true, false] {
                var tuck = BarTuck(), hidden = !down, shift = 0.0, changes = 0
                for n in 0...60 {
                    let offset = 1000 + Double(down ? n : -n) * 5 + shift
                    if let now = tuck.scrolled(offset: offset, inset: hidden ? 62 : 116, hidden: hidden,
                                               byReader: true) {
                        hidden = now
                        changes += 1
                        shift += now ? jump : -jump  // the next offset UIKit reports, with the bar's height made up
                    }
                }
                XCTAssertEqual(changes, 1, "jump \(jump), down \(down)")
                XCTAssertEqual(hidden, down, "jump \(jump), down \(down)")
            }
        }
    }

    func testTheBarStaysNearTheTopAndForSmallWobbles() {
        var tuck = BarTuck(), hidden = false
        XCTAssertEqual(drag(Array(stride(from: -116.0, through: -70, by: 2)), tuck: &tuck, hidden: &hidden), 0,
                       "within 50 points of the page's top")
        tuck = BarTuck()
        XCTAssertEqual(drag([300, 305, 300, 306, 301, 307], tuck: &tuck, hidden: &hidden), 0, "under 12 points")
    }

    func testOnlyTheReadersScrollingCounts() {
        var tuck = BarTuck()
        // a jump to a heading or a page placed by WebKit moves the offset without the reader
        XCTAssertNil(tuck.scrolled(offset: 0, inset: 116, hidden: false, byReader: false))
        XCTAssertNil(tuck.scrolled(offset: 900, inset: 116, hidden: false, byReader: false))
        XCTAssertNil(tuck.scrolled(offset: 905, inset: 116, hidden: false, byReader: true), "a fresh start, not 905")
        XCTAssertEqual(tuck.scrolled(offset: 920, inset: 116, hidden: false, byReader: true), true)
    }

    /// Remaining-findings plan, Task 10.2 (F16): a new page shows the bar; a jump within the page doesn't count.
    func testANewPageShowsTheBar() {
        let list = URL(string: "zim://abc/A/guides.html")!, guide = URL(string: "zim://abc/A/severe-bleeding.html")!
        XCTAssertTrue(PagePlace.isNewPage(from: list, to: guide))
        XCTAssertTrue(PagePlace.isNewPage(from: nil, to: guide), "the first page")
        XCTAssertFalse(PagePlace.isNewPage(from: guide, to: URL(string: "zim://abc/A/severe-bleeding.html#fn:8")!),
                       "a citation's jump stays on the page")
        XCTAssertFalse(PagePlace.isNewPage(from: guide, to: guide))
    }

    /// Task 10.2 (F59): the iPad's narrow and wide layouts rebuild the page's view; its place is kept as a share of the
    /// page, so a guide read halfway in Slide Over is still halfway at full width, where its text is shorter.
    func testASizeChangeKeepsTheScrollPlace() {
        let share = PagePlace.share(offset: 2_000 - 100, inset: 100, contentHeight: 6_000, viewHeight: 1_100)
        XCTAssertEqual(share, 0.4, accuracy: 0.0001)
        let wide = PagePlace.offset(share: share, inset: 80, contentHeight: 3_000, viewHeight: 900)
        XCTAssertEqual(PagePlace.share(offset: wide, inset: 80, contentHeight: 3_000, viewHeight: 900), share,
                       accuracy: 0.0001)
        XCTAssertEqual(PagePlace.offset(share: 0, inset: 80, contentHeight: 3_000, viewHeight: 900), -80, "the top")
        XCTAssertEqual(PagePlace.offset(share: 0.7, inset: 80, contentHeight: 500, viewHeight: 900), -80,
                       "a page shorter than the screen stays at its top")
        XCTAssertEqual(PagePlace.share(offset: 9_000, inset: 100, contentHeight: 6_000, viewHeight: 1_100), 1)
    }

    /// Remaining-findings plan, Task 10.4 (F45; owner, 2026-10-18): picking the tab you're on scrolls to the top, and
    /// once at the top goes to the tab's first page.
    func testSecondTapScrollsToTopThirdGoesToFirstPage() {
        XCTAssertEqual(TabRetap.action(offset: 1_400, inset: 116, onFirstPage: false), .scrollToTop, "the second tap")
        XCTAssertEqual(TabRetap.action(offset: -116, inset: 116, onFirstPage: false), .firstPage, "the third tap")
        XCTAssertEqual(TabRetap.action(offset: -116, inset: 116, onFirstPage: true), .nothing)
        XCTAssertEqual(TabRetap.action(offset: 600, inset: 116, onFirstPage: true), .scrollToTop,
                       "the first page scrolled down goes to its top")
        XCTAssertEqual(TabRetap.action(offset: -115, inset: 116, onFirstPage: false), .firstPage, "a point off counts")
    }

    /// Task 10.7 (F33, F67): search at the bottom on the big iPhones only, by their screens' height in points.
    func testSearchSitsAtTheBottomOnBigPhonesOnly() {
        for (height, big) in [(956.0, true), (932, true), (874, false), (852, false), (667, false)] {
            XCTAssertEqual(OneHand.searchAtBottom(phone: true, screenHeight: height), big, "\(height)")
        }
        XCTAssertFalse(OneHand.searchAtBottom(phone: false, screenHeight: 1_180), "the iPad keeps it at the top")
    }
}
