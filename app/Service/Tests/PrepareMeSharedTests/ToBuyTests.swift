import Foundation
@testable import PrepareMeShared
import XCTest

/// To buy in the app (plan phase 7, slice 4): Bought adds the item and keeps its tick in one save, Not needed and an
/// own item are ticks, and the list the lists job writes reads back. Made-up rehearsal copies only.
@MainActor
final class ToBuyTests: XCTestCase {
    var base: URL!
    var check: FakeCheck!
    var editor: InventoryEditor!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-tobuy-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("PrepareMe Inventory.grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        check = FakeCheck()
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: check)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    var inventory: Inventory { editor.inventory }
    func colId(_ label: String) -> String { inventory.items.column(label)!.colId }

    func boughtValues(_ name: String = "Water jugs") -> [String: SQLValue] {
        [colId("Item"): .text(name), colId("Quantity"): .text("6"), colId("Unit"): .text("gallons"),
         colId("Location"): .int(1)]
    }

    func testBoughtAddsTheItemAndItsTickTogether() async throws {
        let tick = ToBuyTick(kind: .bought, item: "S-G-water-n1")
        let outcome = try await editor.apply(.bought(values: boughtValues(), tick: tick))
        guard case .done(let undo, let row) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(inventory.name(ofItem: inventory.itemRows.first { $0.id == row }!), "Water jugs")
        XCTAssertEqual(inventory.itemRows.first { $0.id == row }!.values["gristHelper_Display2"], .text("Pantry"))
        XCTAssertEqual(try editor.file.ticks().map(\.id), [tick.id])
        XCTAssertEqual(check.asked.last?.place, "Inventory row 6")
        _ = try await editor.apply(undo)
        XCTAssertNil(inventory.itemRows.first { $0.id == row })
        XCTAssertEqual(try editor.file.ticks(), [])
    }

    func testARefusedBoughtKeepsNeitherTheItemNorItsTick() async throws {
        let outcome = try await editor.apply(.bought(values: boughtValues("REFUSE"),
                                                     tick: ToBuyTick(kind: .bought, item: "S-G-water-n1")))
        XCTAssertEqual(outcome, .refused("Inventory row 6, Item: refused"))
        XCTAssertEqual(inventory.itemRows.count, 5)
        XCTAssertEqual(try editor.file.ticks(), [])
    }

    func testNotNeededAndAnOwnItemAreTicksAndAnOwnItemIsChecked() async throws {
        _ = try await editor.apply(.tick(ToBuyTick(kind: .notNeeded, item: "S-G-food-n1")))
        let own = ToBuyTick(kind: .add, text: "Lantern mantles", need: 2, unit: "packs", category: "Power and fuel")
        _ = try await editor.apply(.tick(own))
        XCTAssertEqual(check.asked.last?.place, "To buy (PrepareMe)")
        XCTAssertEqual(check.asked.last?.cells.map(\.text), ["Lantern mantles", "2", "packs", ""])
        XCTAssertEqual(Set(try editor.file.ticks().map(\.kind.rawValue)), ["not needed", "add"])
        let refused = try await editor.apply(.tick(ToBuyTick(kind: .add, text: "REFUSE")))
        XCTAssertEqual(refused, .refused("To buy (PrepareMe), Item: refused"))
        XCTAssertEqual(try editor.file.ticks().count, 2)
        XCTAssertEqual(try editor.file.dropTicks(try editor.file.ticks().map(\.id)), 2)
        XCTAssertEqual(try editor.file.ticks(), [])
    }

    func testTheListTheListsJobWritesReadsBack() throws {
        let json = """
            {"folded": ["t1"], "items": [{"category": "Water", "cost": "low", "horizon": "two weeks", "id": "S-G-water-n1",
             "life_safety": true, "need": 12, "text": "Water jugs", "unit": "gallons", "why": "Short of 30 days"}],
             "written_at": "2026-10-14T14:00:00Z"}
            """
        try Data(json.utf8).write(to: base.appendingPathComponent(ToBuyList.fileName))
        let list = try XCTUnwrap(ToBuyList.read(in: base))
        XCTAssertEqual(list.folded, ["t1"])
        XCTAssertEqual(list.items.first?.need, 12)
        XCTAssertTrue(list.items.first?.lifeSafety ?? false)
        XCTAssertNil(ToBuyList.read(in: base.appendingPathComponent("none")))
    }
}

/// The slice 4 review's findings 3, 4, 5 and 7.
@MainActor
final class ToBuyReviewTests: XCTestCase {
    var base: URL!
    var editor: InventoryEditor!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-tobuy-review-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("PrepareMe Inventory.grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: FakeCheck())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testUndoAfterTheListsCountedATickIsRefusedNeverPretended() async throws {
        let tick = ToBuyTick(kind: .notNeeded, item: "S-G-food-n1")
        guard case .done(let undo, _) = try await editor.apply(.tick(tick)) else { return XCTFail() }
        try editor.file.dropTicks([tick.id])  // the lists counted it, and the app dropped it
        let outcome = try await editor.apply(undo)
        XCTAssertEqual(outcome, .refused(InventoryWords.counted))
        let bought = ToBuyTick(kind: .bought, item: "S-G-water-n1")
        let item = editor.inventory.items.column("Item")!.colId
        guard case .done(let unbuy, _) = try await editor.apply(.bought(values: [item: .text("Water")], tick: bought))
        else { return XCTFail() }
        try editor.file.dropTicks([bought.id])
        let refused = try await editor.apply(unbuy)
        XCTAssertEqual(refused, .refused(InventoryWords.counted))
        XCTAssertEqual(editor.inventory.itemRows.count, 6, "the bought item stays")
    }

    func testAnOwnItemOverTheListsLimitIsRefusedHere() async throws {
        let long = String(repeating: "x", count: ToBuyTick.textLimit + 1)
        let outcome = try await editor.apply(.tick(ToBuyTick(kind: .add, text: "Mantles", why: long)))
        XCTAssertEqual(outcome, .refused(InventoryWords.tooLong))
        XCTAssertEqual(try editor.file.ticks(), [])
    }

    func testACategoryWithABlankCountsAsFallsBackByItsName() throws {
        let file = editor.file
        let categories = try file.table("Categories")
        let water = editor.inventory.categoryRows.first { InventoryValues.plain($0.values["Name"] ?? .null) == "Water" }!
        try file.set(categories, row: water.id, column: categories.column("Counts as")!, to: .text(""))
        let inventory = try Inventory(file: file)
        XCTAssertEqual(inventory.group(ofCategory: water.id), "Water")
        XCTAssertEqual(ToBuyList.group(ofName: "first aid"), "Medical")
        XCTAssertNil(ToBuyList.group(ofName: "Made-up shelf"))
    }

    func testNumbersAreWrittenAsTheListsJobWritesThem() {
        // readiness.sheets.number_text's answers for the same numbers
        XCTAssertEqual(InventoryValues.number(2.5), "2.5")
        XCTAssertEqual(InventoryValues.number(0.1 + 0.2), "0.3")
        XCTAssertEqual(InventoryValues.number(1234567.891), "1234567.891")
        XCTAssertEqual(InventoryValues.number(1e16), "10000000000000000")
        XCTAssertEqual(InventoryValues.number(6), "6")
        XCTAssertEqual(InventoryValues.number(1.0 / 3.0), "0.333333333333333")
    }
}
