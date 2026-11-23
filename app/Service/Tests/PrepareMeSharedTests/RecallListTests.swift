import Foundation
@testable import PrepareMeShared
import XCTest

/// The Mac's Recalls list (top-ten plan phase 6, Task 6.3; the owner's fix 1, 2026-10-16): the open recalls, then the
/// cleared in their fold; a Mac-only item's row named on the Mac alone. Made-up rows only.
final class RecallListTests: XCTestCase {
    func recall(_ id: String, item: String, status: String? = nil, recall: String = "Made-up recall",
                link: String = "https://www.cpsc.gov/Recalls/2026/made-up") -> ListRow {
        ListRow(pos: 0, cells: ["Item": .text(item), "Recall": .text(recall), "Agency": .text("CPSC"),
                                "Date": .text("Oct 1, 2026"), "Link": .text(link), "Level": .text("Match"),
                                "Status": status.map(ListCell.text) ?? .null, "Checked on": .text(""), "ID": .text(id)])
    }

    func testOpenRecallsComeFirstAndClearedFold() {
        let rows = [recall("R-1", item: "Zorvex generator"), recall("R-4", item: "Quillmark lantern", status: "Fixed"),
                    recall("R-2", item: "Made-up heater"), recall("R-5", item: "Made-up alarm", status: "Not ours")]
        let split = RecallList.split(rows)
        XCTAssertEqual(split.open.map(\.id), ["R-1", "R-2"])
        XCTAssertEqual(split.cleared.map(\.id), ["R-4", "R-5"])
        XCTAssertEqual(RecallList.clearedHeading(2), "Cleared (2)")
    }

    func testTheSidebarCountsTheOpenAndShowsWhileAnyIsListed() {
        XCTAssertEqual(RecallList.sidebar([recall("R-1", item: "A"), recall("R-2", item: "B", status: "Fixed")]),
                       "Recalls (1)")
        XCTAssertEqual(RecallList.sidebar([recall("R-2", item: "B", status: "Replaced")]), "Recalls (0)",
                       "cleared ones only: still there, to set one back to open")
        XCTAssertNil(RecallList.sidebar([]))
    }

    func testAMacOnlyRowIsNamedByItsInventoryItemOnTheMac() {
        var lists = Lists.none
        lists.macOnlyRecalls = ["R-6": MacOnlyRecall(title: "Made-up private recall",
                                                     link: "https://www.cpsc.gov/Recalls/2026/made-up-p")]
        let row = recall("R-6", item: "Mac-only item, inventory row 9", recall: "",
                         link: "https://www.cpsc.gov/Recalls")
        XCTAssertEqual(RecallList.macOnlyRow(row), 9)
        let shown = RecallList.shown(row, in: lists) { $0 == 9 ? "Made-up generator" : nil }
        XCTAssertEqual(shown.item, "Made-up generator")
        XCTAssertEqual(shown.recall, "Made-up private recall")
        XCTAssertEqual(shown.link?.absoluteString, "https://www.cpsc.gov/Recalls/2026/made-up-p")
        let gone = RecallList.shown(row, in: .none) { _ in nil }  // the item gone, or no names yet
        XCTAssertEqual(gone.item, "Mac-only item, inventory row 9")
        XCTAssertEqual(gone.recall, "")
        XCTAssertNil(RecallList.macOnlyRow(recall("R-1", item: "Zorvex generator")))
    }

    func testOnlyAnHTTPSPageIsOpened() {
        XCTAssertNil(RecallList.shown(recall("R-1", item: "A", link: "http://example.test/x"), in: .none) { _ in nil }.link)
        XCTAssertNil(RecallList.shown(recall("R-1", item: "A", link: "not a link"), in: .none) { _ in nil }.link)
    }

    func testPhoneCopyNeverCarriesMacOnlyRecalls() throws {
        var lists = Lists(sheets: [ListsLayout.recalls: [recall("R-6", item: "Mac-only item, inventory row 9",
                                                                recall: "")]], stamp: nil, revision: 0)
        lists.macOnlyRecalls = ["R-6": MacOnlyRecall(title: "Made-up private recall", link: "https://example.test/p")]
        let sent = String(decoding: try JSONEncoder().encode(PhoneLists(lists)), as: UTF8.self)
        XCTAssertFalse(sent.contains("Made-up private recall"))
        XCTAssertFalse(sent.contains("example.test"))
        XCTAssertFalse(sent.contains("inventory row 9"))
    }

    func testTheScriptsNoteSaysCPSCHasntCheckedThem() {
        XCTAssertTrue(RecallList.ours.contains("CPSC hasn't checked them"))
    }
}
