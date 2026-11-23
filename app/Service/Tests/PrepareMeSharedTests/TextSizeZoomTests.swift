import PrepareMeShared
import XCTest

/// Pages follow the phone's text size (the beta run's F02; plan 2026-10-16, Task 3.1): the page zoom grows with the
/// phone's text size, never shrinks a page below today's, and stops at 300%.
final class TextSizeZoomTests: XCTestCase {
    func testDefaultSizeChangesNothing() {
        XCTAssertEqual(TextSizeZoom.factor("UICTContentSizeCategoryL"), 1)
        XCTAssertEqual(TextSizeZoom.effective(user: 1, category: "UICTContentSizeCategoryL"), 1)
    }

    func testLargestSize() {
        XCTAssertEqual(TextSizeZoom.factor("UICTContentSizeCategoryAccessibilityXXXL"), 53.0 / 17, accuracy: 1e-9)
        XCTAssertEqual(TextSizeZoom.effective(user: 1, category: "UICTContentSizeCategoryAccessibilityXXXL"), 3)
    }

    func testSmallSizesNeverShrinkPages() {
        XCTAssertEqual(TextSizeZoom.effective(user: 1, category: "UICTContentSizeCategoryXS"), 1)
        XCTAssertEqual(TextSizeZoom.effective(user: 1.2, category: "UICTContentSizeCategoryM"), 1.2)
    }

    func testUserZoomMultiplies() {
        XCTAssertEqual(TextSizeZoom.effective(user: 1.5, category: "UICTContentSizeCategoryXL"), 1.5 * 19 / 17,
                       accuracy: 1e-9)
    }

    func testEverySizeGrowsInStep() {
        let sizes = ["UICTContentSizeCategoryL", "UICTContentSizeCategoryXL", "UICTContentSizeCategoryXXL",
                     "UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityM",
                     "UICTContentSizeCategoryAccessibilityL", "UICTContentSizeCategoryAccessibilityXL",
                     "UICTContentSizeCategoryAccessibilityXXL"]
        let zooms = sizes.map { TextSizeZoom.effective(user: 1, category: $0) }
        XCTAssertEqual(zooms, zooms.sorted())
        XCTAssertEqual(Set(zooms).count, zooms.count, "each step bigger than the last")
    }

    /// The script the web view runs on each page (review: the "never sideways" half of the plan's Review Focus had no
    /// test): the text size as a percent, and long words allowed to break only when the text is enlarged.
    func testThePageScript() {
        XCTAssertEqual(TextSizeZoom.script(3),
                       "document.body.style.webkitTextSizeAdjust='300%';"
                       + "document.documentElement.style.overflowWrap='anywhere';"
                       + "document.documentElement.toggleAttribute('data-large',true);")
        XCTAssertEqual(TextSizeZoom.script(1),
                       "document.body.style.webkitTextSizeAdjust='100%';"
                       + "document.documentElement.style.overflowWrap='';"
                       + "document.documentElement.toggleAttribute('data-large',false);")
        XCTAssertTrue(TextSizeZoom.script(1.5).contains("toggleAttribute('data-large',true)"), "150% is large")
        XCTAssertTrue(TextSizeZoom.script(1.49).contains("toggleAttribute('data-large',false)"))
        XCTAssertTrue(TextSizeZoom.script(1.5 * 19 / 17).contains("'168%'"), "rounded to a whole percent")
    }

    func testAnUnknownSizeChangesNothing() {
        XCTAssertEqual(TextSizeZoom.factor("UICTContentSizeCategoryUnspecified"), 1)
        XCTAssertEqual(TextSizeZoom.effective(user: 1.3, category: "something new"), 1.3)
    }
}
