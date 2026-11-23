import PrepareMeShared
import XCTest

/// A recall's Status words (top-ten plan phase 6; the owner's words, 2026-10-16): the menu offers the four, and an old
/// "Repaired" shows as "Fixed", never as a blank menu. readiness/tests/test_applists.py pins both lists to the lists
/// job's (readiness.layout).
final class RecallStatusTests: XCTestCase {
    func testStatusMenuWords() {
        XCTAssertEqual(ListsLayout.recallStatuses, ["Not ours", "Fixed", "Replaced", "Thrown away"])
    }

    func testOldRepairedReadsAsFixed() {
        XCTAssertEqual(ListsLayout.recallStatus("Repaired"), "Fixed")
        for word in ListsLayout.recallStatuses + [""] {
            XCTAssertEqual(ListsLayout.recallStatus(word), word)
        }
        XCTAssertTrue(ListsLayout.recallRenamed.values.allSatisfy(ListsLayout.recallStatuses.contains))
    }
}
