import Foundation
@testable import PrepareMeShared
import XCTest

/// Recalls on the phones (top-ten plan phase 6, Task 6.4; the owner's fix 1, 2026-10-16): the open ones in the phones'
/// copy, never a Mac-only item's; an adult's phone answers one with its Status, the one recall change a phone may send;
/// a child's phone reads the list with no controls; an answer waiting in the outbox takes the recall off at once.
/// Made-up rows on a copy of the rehearsal inventory.
@MainActor
final class PhoneRecallTests: XCTestCase {
    var base: URL!
    var editor: InventoryEditor!

    static func recall(_ id: String, item: String, status: String? = nil) -> [String: ListCell] {
        ["Item": .text(item), "Recall": .text(item.hasPrefix("Mac-only") ? "" : "Made-up recall of \(item)"),
         "Agency": .text("CPSC"), "Date": .text("Sep 30, 2026"), "Link": .text("https://www.cpsc.gov/Recalls"),
         "Level": .text("Match"), "Status": status.map(ListCell.text) ?? .null, "Checked on": .text(""),
         "ID": .text(id)]
    }

    static let rows = [recall("R-1", item: "Dual fuel generator"),
                       recall("R-2", item: "Drinking water jugs", status: "Repaired"),  // the old word, taken in as is
                       recall("R-3", item: "Mac-only item, inventory row 4"),
                       recall("R-5", item: "Made-up odd label")]  // Mac-only by its ID alone (review)

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-phone-recalls-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: FakeCheck())
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ListsTablesTests.sample))
            as? [String: Any])
        raw["base"] = NSNull()
        var sheets = try XCTUnwrap(raw["sheets"] as? [String: Any])
        sheets[ListsLayout.recalls] = try Self.rows.map { row in
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(row))
        }
        raw["sheets"] = sheets
        raw["mac_only_recalls"] = ["R-3": ["title": "Made-up private title", "link": "https://example.test/private"],
                                   "R-5": ["title": "Made-up other private title", "link": "https://example.test/p5"]]
        let made = try JSONDecoder().decode(ListsPayload.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertTrue(try editor.file.takeIn(made))
        try editor.reload()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testThePhonesCopyCarriesTheOpenRecallsAndNoMacOnlyOne() throws {
        let lists = try XCTUnwrap(editor.inventory.lists)
        let sent = PhoneLists(lists)
        XCTAssertEqual(sent.recalls?.map(\.id), ["R-1"])
        XCTAssertEqual(sent.recalls?.first?.item, "Dual fuel generator")
        let text = String(decoding: try JSONEncoder().encode(sent), as: UTF8.self)
        XCTAssertFalse(text.contains("inventory row 4"), "a Mac-only row never reaches a phone")
    }

    /// Review: the whole copy the phones get, encoded, holds no Mac-only recall's title, link, row or ID
    func testTheWholePhoneCopyNeverCarriesAMacOnlyRecall() throws {
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertEqual(copy.lists?.recalls?.map(\.id), ["R-1"])
        let text = String(decoding: try JSONEncoder().encode(copy), as: UTF8.self)
        for held in ["Made-up private title", "Made-up other private title", "example.test", "inventory row 4",
                     "Made-up odd label", "\"R-3\"", "\"R-5\""] {
            XCTAssertFalse(text.contains(held), held)
        }
    }

    /// Review: a phone's answer goes through the Mac's own editor (its expected blank matches a real blank Status), and
    /// a second answer to the same recall is refused as changed meanwhile
    func testAPhonesAnswerIsAppliedByTheMacsEditor() async throws {
        let open = try XCTUnwrap(PhoneLists(try XCTUnwrap(editor.inventory.lists)).recalls?.first)
        let outcome = try await editor.apply(open.answer("Not ours"))
        guard case .done = outcome else { return XCTFail("\(outcome)") }
        let row = try XCTUnwrap(editor.inventory.lists?.rows(ListsLayout.recalls).first { $0.id == "R-1" })
        XCTAssertEqual(row["Status"], .text("Not ours"))
        guard case .refused = try await editor.apply(open.answer("Fixed")) else { return XCTFail("taken twice") }
    }

    /// Review: undoing a change to a row that still holds the old "Repaired" puts back its new word, never refused
    func testUndoOfAnOldWordPutsBackItsNewOne() async throws {
        let old = try XCTUnwrap(editor.inventory.lists?.rows(ListsLayout.recalls).first { $0.id == "R-2" })
        XCTAssertEqual(old["Status"], .text("Repaired"))
        let changed = try await editor.apply(.listSet(sheet: ListsLayout.recalls, row: ListRowRef(old), column: "Status",
                                                      value: .text("Replaced"), expected: old["Status"]))
        guard case .done(let undo, _) = changed else { return XCTFail("\(changed)") }
        guard case .done = try await editor.apply(undo) else { return XCTFail("the undo was refused") }
        let back = try XCTUnwrap(editor.inventory.lists?.rows(ListsLayout.recalls).first { $0.id == "R-2" })
        XCTAssertEqual(back["Status"], .text("Fixed"))
    }

    func testAnOlderCopyWithoutRecallsStillReads() throws {
        let older = #"{"todo":[],"upkeep":[],"eventMode":"Auto"}"#
        let read = try JSONDecoder().decode(PhoneLists.self, from: Data(older.utf8))
        XCTAssertNil(read.recalls)
        XCTAssertEqual(read.eventMode, "Auto")
    }

    func testPhoneRulesAllowOnlyARecallsStatus() throws {
        let inventory = editor.inventory
        let open = try XCTUnwrap(PhoneLists(try XCTUnwrap(inventory.lists)).recalls?.first)
        for word in ListsLayout.recallStatuses {
            XCTAssertNil(PhoneRules.refusal(open.answer(word), inventory), word)
        }
        let ref = ListRowRef(ListRow(pos: 0, cells: ["ID": .text("R-1")]))
        for change: InventoryChange in [
            .listSet(sheet: ListsLayout.recalls, row: ref, column: "Status", value: .text("Maybe"), expected: .null),
            .listSet(sheet: ListsLayout.recalls, row: ref, column: "Status", value: .null, expected: .null),
            .listSet(sheet: ListsLayout.recalls, row: ref, column: "Recall", value: .text("x"), expected: .null),
            .listRemove(sheet: ListsLayout.recalls, row: ref),
        ] {
            XCTAssertEqual(PhoneRules.refusal(change, inventory), PhoneRules.notFromAPhone, "\(change)")
        }
        let macOnly = ListRowRef(ListRow(pos: 0, cells: ["ID": .text("R-3")]))
        XCTAssertEqual(PhoneRules.refusal(.listSet(sheet: ListsLayout.recalls, row: macOnly, column: "Status",
                                                   value: .text("Fixed"), expected: .null), inventory),
                       InventoryWords.noRow, "a Mac-only recall reads to a phone as no row at all")
        let gone = ListRowRef(ListRow(pos: 0, cells: ["ID": .text("R-99")]))
        XCTAssertEqual(PhoneRules.refusal(.listSet(sheet: ListsLayout.recalls, row: gone, column: "Status",
                                                   value: .text("Fixed"), expected: .null), inventory),
                       InventoryWords.noRow)
    }

    func testAClearedRecallLeavesTheListAtOnce() throws {
        let copy = PhoneInventory(writtenAt: "x", columns: [], items: [], places: [], categories: [], headsUpDays: 60,
                                  toBuy: [], results: [:], lists: PhoneLists(try XCTUnwrap(editor.inventory.lists)))
        let open = try XCTUnwrap(copy.lists?.recalls?.first)
        var outbox = PhoneOutbox()
        _ = outbox.add(open.answer("Not ours"), what: "\(open.item): Not ours")
        XCTAssertEqual(outbox.view(copy).lists?.recalls, [])
    }

    func testAChildsPhoneHasNoClearButton() {
        XCTAssertEqual(PhoneRecall.answers(canEdit: false), [])
        XCTAssertEqual(PhoneRecall.answers(canEdit: true), ListsLayout.recallStatuses)
    }
}
