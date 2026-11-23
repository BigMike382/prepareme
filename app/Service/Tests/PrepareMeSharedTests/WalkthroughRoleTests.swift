import PrepareMeShared
import XCTest

/// The phone marks each page with its role, as packer.reading_style reads it (step 10, the walk-throughs).
final class WalkthroughRoleTests: XCTestCase {
    func testTheRoleScript() {
        XCTAssertEqual(WalkthroughRole.attribute, "data-role")
        XCTAssertEqual(WalkthroughRole.script(child: true), "document.documentElement.setAttribute('data-role','child')")
        XCTAssertEqual(WalkthroughRole.script(child: false), "document.documentElement.setAttribute('data-role','adult')")
    }

    /// F-092 and F-094: a phone page's two marks, set before it draws and again when the role arrives. Not yet told
    /// (a just-paired phone: no edits, taken as a child's) gives the child's words in both; an adult's, the adult's.
    func testThePhonesMarksFailClosedUntilTheRoleIsKnown() {
        let root = "document.documentElement.setAttribute"
        XCTAssertEqual(WalkthroughRole.phoneMarks(canEdit: false, child: true),
                       "\(root)('data-host','phone-readonly');\(root)('data-role','child')")
        XCTAssertEqual(WalkthroughRole.phoneMarks(canEdit: true, child: false),
                       "\(root)('data-host','phone');\(root)('data-role','adult')")
        XCTAssertFalse(WalkthroughRole.phoneMarks(canEdit: false, child: true).contains("'phone'"),
                       "never the adult's words before the role is known")
    }
}
