import Foundation
@testable import PrepareMeShared
import XCTest

/// A check that refuses any cell holding "REFUSE", records what it was asked and reads the changed copy it was given;
/// or one that can't run; or one whose whole-file reader refuses (`fileRefusal`).
final class FakeCheck: TextChecking, @unchecked Sendable {
    var asked: [CheckRow] = []
    var files: [URL] = []
    var copies: [[String]] = []  // each changed copy's item names, as the copy held them when checked
    var broken = false
    var brokenAfter: Int?  // answers this many checks, then can't run
    var calls = 0
    var fileRefusal: String?

    func check(_ rows: [CheckRow], file: URL?) async throws -> CheckAnswer {
        asked += rows
        calls += 1
        if broken || brokenAfter.map({ calls > $0 }) ?? false { throw CheckUnavailable(why: "made up") }
        if let file {
            files.append(file)
            let inventory = try Inventory(file: try InventoryFile(url: file, readOnly: true))
            copies.append(inventory.itemRows.map { inventory.name(ofItem: $0) })
        }
        let refused = rows.enumerated().compactMap { n, row in
            row.cells.firstIndex { $0.text.contains("REFUSE") }.map {
                CheckRefusal(row: n, cell: $0, message: "\(row.place), \(row.cells[$0].label): refused")
            }
        }
        return CheckAnswer(refused: refused, file: refused.isEmpty ? fileRefusal : nil)
    }
}

/// Every change the editor makes goes through the check, the rules and one write (plan phase 7). Made-up rehearsal
/// document copies only.
@MainActor
final class InventoryEditorTests: XCTestCase {
    var base: URL!
    var check: FakeCheck!
    var editor: InventoryEditor!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-editor-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        let file = try InventoryFile(url: url)
        try file.ensureColumn("Locations", colId: "Kept_in", label: "Kept in", type: "Ref:Locations")
        check = FakeCheck()
        editor = try InventoryEditor(file: file, checker: check)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    var inventory: Inventory { editor.inventory }

    func item(_ name: String) -> InventoryRow { inventory.itemRows.first { inventory.name(ofItem: $0) == name }! }
    func place(_ name: String) -> Int64 { inventory.locationRows.first { inventory.name(ofLocation: $0.id) == name }!.id }
    func colId(_ table: String, _ label: String) -> String { inventory.table(table).column(label)!.colId }

    func testASetIsCheckedWithItsWholeRowThenWrittenAndUndone() async throws {
        let jugs = item("Drinking water jugs")
        let outcome = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: colId("Inventory", "Notes"),
                                                  value: .text("Rinse first.")))
        guard case .done(let undo, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(check.asked.last?.place, "Inventory row 3")
        XCTAssertTrue(check.asked.last!.cells.contains { $0.label == "Notes" && $0.text == "Rinse first." })
        XCTAssertTrue(check.asked.last!.cells.contains { $0.label == "Item" && $0.text == "Drinking water jugs" })
        XCTAssertEqual(InventoryValues.plain(item("Drinking water jugs").values[colId("Inventory", "Notes")]!),
                       "Rinse first.")
        _ = try await editor.apply(undo)
        XCTAssertEqual(item("Drinking water jugs").values, jugs.values)
    }

    /// The item form's Cancel puts back only what the form saved (the audit, 2026-10-22, finding 1): a phone's change
    /// landing while the form is open stays, on a cell the form saved too.
    func testItemFormCancelPutsBackOnlyItsOwnEdits() async throws {
        let jugs = item("Drinking water jugs")
        let notes = colId("Inventory", "Notes"), quantity = colId("Inventory", "Quantity")
        let opened = jugs.values
        _ = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: notes, value: .text("Rinse first.")))
        _ = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: quantity, value: .text("9")))
        _ = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: quantity, value: .text("8")))  // a phone
        for change in InventoryChange.cancelForm(row: jugs.id, opened: opened,
                                                 saved: [notes: .text("Rinse first."), quantity: .text("9")]) {
            _ = try await editor.apply(change)
        }
        let now = item("Drinking water jugs").values
        XCTAssertEqual(now[notes], opened[notes], "the form's own edit put back")
        XCTAssertEqual(now[quantity], .text("8"), "the phone's edit kept")
        XCTAssertEqual(InventoryChange.cancelForm(row: jugs.id, opened: opened, saved: [notes: opened[notes]!]), [],
                       "a cell saved back to what it held needs nothing")
    }

    /// The Mac reloads only when this changes (InventoryModel.open, every 10 seconds): its own edits leave it, another
    /// writer's change moves it.
    func testDataVersionMovesOnlyForAnotherWriter() async throws {
        let before = try editor.file.dataVersion()
        _ = try await editor.apply(.set(table: "Inventory", row: item("Drinking water jugs").id,
                                        colId: colId("Inventory", "Notes"), value: .text("Rinse first.")))
        XCTAssertEqual(try editor.file.dataVersion(), before)
        try InventoryFile(url: editor.file.url).link("0" + ["0360", "0029", "1452"].joined(), to: 3)
        XCTAssertNotEqual(try editor.file.dataVersion(), before)
    }

    func testARefusedCellIsNeverWritten() async throws {
        let jugs = item("Drinking water jugs")
        let outcome = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: colId("Inventory", "Notes"),
                                                  value: .text("REFUSE this")))
        XCTAssertEqual(outcome, .refused("Inventory row 3, Notes: refused"))
        XCTAssertEqual(item("Drinking water jugs").values, jugs.values)
    }

    func testTheChangeIsMadeOnACopyTheListsJobMustReadFirst() async throws {
        let flashlight = item("Test flashlight")
        let outcome = try await editor.apply(.set(table: "Inventory", row: flashlight.id,
                                                  colId: colId("Inventory", "Item"), value: .text("Headlamp")))
        guard case .done = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(check.files.map(\.lastPathComponent), ["inventory.sqlite"])  // named as the real file is
        XCTAssertTrue(check.copies[0].contains("Headlamp"), "the copy held the change when the reader read it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: check.files[0].path), "the copy is removed")
        check.fileRefusal = "inventory.sqlite: Inventory row 5, Year: made-up refusal"
        let refused = try await editor.apply(.set(table: "Inventory", row: flashlight.id,
                                                  colId: colId("Inventory", "Item"), value: .text("Torch")))
        XCTAssertEqual(refused, .refused("inventory.sqlite: Inventory row 5, Year: made-up refusal"))
        XCTAssertEqual(inventory.name(ofItem: item("Headlamp")), "Headlamp", "the real file never took the change")
    }

    /// Phase K, finding 18: a product lookup's answer, written as the Mac's Fill in the blanks writes it (`.revert`,
    /// only while the cell is still blank), goes through the ID check like any typed text
    func testALookupsTextWrittenAsARevertIsStillChecked() async throws {
        let flashlight = item("Test flashlight")
        let brand = colId("Inventory", "Brand")
        _ = try await editor.apply(.set(table: "Inventory", row: flashlight.id, colId: brand, value: .text("")))
        let before = item("Test flashlight").values
        let info = ProductInfo(name: "Made up lamp", brand: "REFUSE Made Up Lights", source: "Open Food Facts")
        let fill = try XCTUnwrap(inventory.lookupFills(info, row: flashlight.id).first { $0.column.label == "Brand" })
        let asked = check.asked.count
        let outcome = try await editor.apply(.revert(table: "Inventory", row: flashlight.id, colId: fill.column.colId,
                                                     value: fill.value, expected: fill.expected))
        XCTAssertEqual(outcome, .refused("Inventory row 5, Brand: refused"))
        XCTAssertGreaterThan(check.asked.count, asked, "the check was asked")
        XCTAssertTrue(check.asked.last!.cells.contains { $0.label == "Brand" && $0.text == "REFUSE Made Up Lights" })
        XCTAssertEqual(item("Test flashlight").values, before, "never written")
        // a clean answer is checked too, then written
        let clean = ProductInfo(name: "Made up lamp", brand: "Made Up Lights", source: "Open Food Facts")
        let good = try XCTUnwrap(inventory.lookupFills(clean, row: flashlight.id).first { $0.column.label == "Brand" })
        let written = try await editor.apply(.revert(table: "Inventory", row: flashlight.id, colId: good.column.colId,
                                                     value: good.value, expected: good.expected))
        guard case .done = written else { return XCTFail("\(written)") }
        XCTAssertTrue(check.asked.last!.cells.contains { $0.label == "Brand" && $0.text == "Made Up Lights" })
    }

    func testACheckThatCantRunKeepsNothing() async throws {
        check.broken = true
        let jugs = item("Drinking water jugs")
        do {
            _ = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: colId("Inventory", "Notes"),
                                            value: .text("x")))
            XCTFail("must throw")
        } catch is CheckUnavailable {}
        XCTAssertEqual(item("Drinking water jugs").values, jugs.values)
    }

    func testALocationInUseIsNotDeletedAndNamesItsItems() async throws {
        let outcome = try await editor.apply(.delete(table: "Locations", row: place("Garage")))
        XCTAssertEqual(outcome, .refused(String(format: InventoryWords.inUse, "Dual fuel generator")))
        XCTAssertNotNil(inventory.locationRows.first { $0.id == place("Garage") })
        guard case .done(let undo, _) = try await editor.apply(.delete(table: "Locations", row: place("Basement")))
        else { return XCTFail() }
        XCTAssertNil(inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Basement" })
        _ = try await editor.apply(undo)
        XCTAssertNotNil(inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Basement" })
    }

    func testABinCantGoInsideItself() async throws {
        let keptIn = colId("Locations", "Kept in")
        let bin = place("Bin 01"), garage = place("Garage")
        guard case .done = try await editor.apply(.set(table: "Locations", row: bin, colId: keptIn, value: .int(garage)))
        else { return XCTFail() }
        let outcome1 = try await editor.apply(.set(table: "Locations", row: garage, colId: keptIn, value: .int(bin)))
        XCTAssertEqual(outcome1, .refused(InventoryWords.loop))
        let outcome2 = try await editor.apply(.set(table: "Locations", row: bin, colId: keptIn, value: .int(bin)))
        XCTAssertEqual(outcome2, .refused(InventoryWords.loop))
        XCTAssertEqual(inventory.users(of: "Locations", row: garage), ["Dual fuel generator", "Bin 01"])
    }

    func testAnAddedRowIsCheckedAndUndoneByDeleting() async throws {
        let name = colId("Inventory", "Item"), location = colId("Inventory", "Location")
        guard case .done(let undo, let id) = try await editor.apply(.add(table: "Inventory", values: [
            name: .text("Spare batteries"), location: .int(place("Car"))]))
        else { return XCTFail() }
        XCTAssertEqual(check.asked.last?.place, "Inventory row 6")
        let added = try XCTUnwrap(inventory.itemRows.first { $0.id == id })
        XCTAssertEqual(added.values["gristHelper_Display2"], .text("Car"))
        _ = try await editor.apply(undo)
        XCTAssertNil(inventory.itemRows.first { $0.id == id })
        let outcome3 = try await editor.apply(.add(table: "Inventory", values: [name: .text("REFUSE")]))
        XCTAssertEqual(outcome3, .refused("Inventory row 6, Item: refused"))
        XCTAssertEqual(inventory.itemRows.count, 5)
        let outcome4 = try await editor.apply(.add(table: "Settings", values: [:]))
        XCTAssertEqual(outcome4, .refused(InventoryWords.notAddable))
    }

    /// B2-07 (beta run 2): the Mac's Add had saved an empty row at once, already in the phones' copy; a new item is
    /// written only once it has a name, whoever sends it.
    func testANamelessNewItemIsNeverWritten() async throws {
        let name = colId("Inventory", "Item"), location = colId("Inventory", "Location")
        let asked = check.calls
        for values: [String: SQLValue] in [[:], [location: .int(place("Car"))], [name: .text("   ")], [name: .null]] {
            let outcome = try await editor.apply(.add(table: "Inventory", values: values))
            XCTAssertEqual(outcome, .refused(InventoryWords.noName), "\(values)")
        }
        XCTAssertEqual(inventory.itemRows.count, 5, "nothing written")
        XCTAssertEqual(check.calls, asked, "refused before the check or the write")
        guard case .done = try await editor.apply(.add(table: "Inventory", values: [name: .text("Lantern")])) else {
            return XCTFail("a named item is written")
        }
        XCTAssertEqual(inventory.itemRows.count, 6)
        // the other tables' rows are named in their own Name column, and Add there is unchanged
        guard case .done = try await editor.apply(.add(table: "Locations", values: [:])) else { return XCTFail() }
    }

    /// Checkpoint 2: nor is an item's name blanked. A change that empties a named item's Item cell (the Mac's table, or
    /// a phone's form) is refused before the check or the write; an item a phone's barcode add left to name later
    /// (`.addItem`) may still be left without one, and a name changed to another is kept.
    func testAnItemsNameIsNeverBlanked() async throws {
        let name = colId("Inventory", "Item"), jugs = item("Drinking water jugs")
        let asked = check.calls
        for value: SQLValue in [.text(""), .text("   "), .null] {
            let outcome = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: name, value: value))
            XCTAssertEqual(outcome, .refused(InventoryWords.noName), "\(value)")
        }
        XCTAssertEqual(inventory.name(ofItem: item("Drinking water jugs")), "Drinking water jugs", "the name stays")
        XCTAssertEqual(check.calls, asked, "refused before the check or the write")
        guard case .done(let undo, _) = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: name,
                                                                     value: .text("Water jugs"))) else {
            return XCTFail("a name changed to another is kept")
        }
        guard case .done = try await editor.apply(undo) else { return XCTFail("and its undo puts the old name back") }
        let code = ["9638", "5074"].joined()  // a made-up EAN-8 with a good check digit (BarcodeTests)
        guard case .done(_, let later) = try await editor.apply(.addItem(values: [:], barcode: code)) else {
            return XCTFail("a barcode add may still leave its name for later")
        }
        let blank = try await editor.apply(.set(table: "Inventory", row: later, colId: name, value: .text("")))
        guard case .done = blank else { return XCTFail("an item with no name yet has none to blank: \(blank)") }
        guard case .done(let unname, _) = try await editor.apply(.set(table: "Inventory", row: later, colId: name,
                                                                       value: .text("Lantern"))) else { return XCTFail() }
        let back = try await editor.apply(unname)
        guard case .done = back else { return XCTFail("Edit › Undo of naming it puts back what was: \(back)") }
    }

    /// B2-07: Delete of several rows is one change, all or nothing, and one Undo puts them all back (and its Redo
    /// deletes them all again).
    func testDeletingSeveralRowsIsOneChangeAndOneUndo() async throws {
        let jugs = item("Drinking water jugs"), flashlight = item("Test flashlight")
        let outcome = try await editor.apply(.deleteRows(table: "Inventory", rows: [jugs.id, flashlight.id]))
        guard case .done(let undo, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(inventory.itemRows.count, 3)
        XCTAssertNil(inventory.itemRows.first { $0.id == jugs.id || $0.id == flashlight.id })
        guard case .restoreRows(let table, let rows) = undo else { return XCTFail("one undo: \(undo)") }
        XCTAssertEqual(table, "Inventory")
        XCTAssertEqual(Set(rows.map(\.id)), [jugs.id, flashlight.id])
        guard case .done(let redo, _) = try await editor.apply(undo) else { return XCTFail() }
        XCTAssertEqual(inventory.itemRows.count, 5)
        XCTAssertEqual(item("Drinking water jugs").values, jugs.values)
        XCTAssertEqual(item("Test flashlight").values, flashlight.values)
        XCTAssertEqual(redo, .deleteRows(table: "Inventory", rows: [jugs.id, flashlight.id]))
        guard case .done = try await editor.apply(redo) else { return XCTFail() }
        XCTAssertEqual(inventory.itemRows.count, 3)
        // one in use refuses the lot, naming its items, and deletes none
        let refused = try await editor.apply(.deleteRows(table: "Locations", rows: [place("Basement"), place("Garage")]))
        XCTAssertEqual(refused, .refused(String(format: InventoryWords.inUse, "Dual fuel generator")))
        XCTAssertNotNil(inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Basement" })
        XCTAssertNotNil(inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Garage" }, "none deleted")
        let settings = try await editor.apply(.deleteRows(table: "Settings", rows: []))
        XCTAssertEqual(settings, .refused(InventoryWords.notAddable))
    }

    /// B2-07: a bin deleted with the place it's kept in isn't "in use" by that place.
    func testABinAndItsPlaceDeleteTogether() async throws {
        let keptIn = colId("Locations", "Kept in")
        let bin = place("Bin 01"), basement = place("Basement")
        guard case .done = try await editor.apply(.set(table: "Locations", row: bin, colId: keptIn, value: .int(basement)))
        else { return XCTFail() }
        let alone = try await editor.apply(.delete(table: "Locations", row: basement))
        XCTAssertEqual(alone, .refused(String(format: InventoryWords.inUse, "Bin 01")))
        let both = try await editor.apply(.deleteRows(table: "Locations", rows: [basement, bin]))
        guard case .done = both else { return XCTFail("\(both)") }
    }

    /// Remove Empty Places (owner, 2026-10-23): every place with no item in it at any depth; a bin kept keeps the
    /// places it is inside; one change, all or none, and one Undo puts them back.
    func testRemoveEmptyPlaces() async throws {
        let keptIn = colId("Locations", "Kept in")
        let bin = place("Bin 01"), basement = place("Basement"), garage = place("Garage")
        guard case .done = try await editor.apply(.set(table: "Locations", row: bin, colId: keptIn, value: .int(basement)))
        else { return XCTFail() }
        let empty = Set(inventory.emptyPlaces.map(\.id))
        XCTAssertTrue(empty.isSuperset(of: [bin, basement]))
        XCTAssertFalse(empty.contains(garage), "the generator is there")
        for row in inventory.locationRows where !empty.contains(row.id) {
            XCTAssertFalse(inventory.items(in: .location(row.id)).isEmpty, inventory.name(ofLocation: row.id))
        }
        XCTAssertEqual(Set(inventory.removable(empty.subtracting([bin]))), empty.subtracting([bin, basement]),
                       "a bin kept keeps the place it's in")
        let going = inventory.removable(empty), before = inventory.locationRows.count, items = inventory.itemRows
        XCTAssertEqual(Set(going), empty)
        guard case .done(let undo, _) = try await editor.apply(.deleteRows(table: "Locations", rows: going)) else {
            return XCTFail()
        }
        XCTAssertEqual(inventory.locationRows.count, before - going.count)
        XCTAssertEqual(inventory.emptyPlaces, [])
        XCTAssertEqual(inventory.itemRows, items, "no item touched")
        guard case .done = try await editor.apply(undo) else { return XCTFail() }
        XCTAssertEqual(inventory.locationRows.count, before)
        XCTAssertEqual(inventory.keptIn(bin), basement)
        XCTAssertEqual(InventoryWords.removeEmptyButton(1), "Remove 1 Place")
        XCTAssertEqual(InventoryWords.removeEmptyButton(4), "Remove 4 Places")
    }

    /// A place's number is never handed out twice (2026-10-23): a bin label and a phone's Quick add name it. Items keep
    /// theirs as before (their leftovers are dropped instead).
    func testARemovedPlacesNumberNeverComesBack() async throws {
        let name = colId("Locations", "Name")
        let last = try XCTUnwrap(inventory.locationRows.map(\.id).max())
        guard case .done = try await editor.apply(.delete(table: "Locations", row: last)) else { return XCTFail() }
        guard case .done(_, let next) = try await editor.apply(.add(table: "Locations", values: [name: .text("Shelf")]))
        else { return XCTFail() }
        XCTAssertGreaterThan(next, last, "made before the file kept a count, and still not handed out again")
        guard case .done = try await editor.apply(.delete(table: "Locations", row: next)) else { return XCTFail() }
        guard case .done(_, let after) = try await editor.apply(.add(table: "Locations", values: [name: .text("Rack")]))
        else { return XCTFail() }
        XCTAssertEqual(after, next + 1)
        let category = colId("Categories", "Name")
        let unused = inventory.categoryRows.map(\.id).filter { inventory.users(of: "Categories", row: $0).isEmpty }
        let last2 = try XCTUnwrap(unused.max())
        guard case .done = try await editor.apply(.delete(table: "Categories", row: last2)) else { return XCTFail() }
        guard case .done(_, let cat) = try await editor.apply(.add(table: "Categories", values: [category: .text("Kit")]))
        else { return XCTFail() }
        XCTAssertGreaterThan(cat, last2, "a phone's Quick add remembers a category by its number too")
        guard case .done = try await editor.apply(.delete(table: "Categories", row: cat)),
              case .done(_, let fresh) = try await editor.apply(.add(table: "Categories", values: [category: .text("Bag")]))
        else { return XCTFail() }
        XCTAssertEqual(fresh, cat + 1, "a deleted category's number isn't handed out again either")
        // Task 1.9 (2026-10-23): nor an item's, so a phone's late Used 1 never lands on a new item that took it
        let item = colId("Inventory", "Item")
        guard case .done(_, let first) = try await editor.apply(.add(table: "Inventory", values: [item: .text("Mug")])),
              case .done = try await editor.apply(.delete(table: "Inventory", row: first)),
              case .done(_, let second) = try await editor.apply(.add(table: "Inventory", values: [item: .text("Cup")]))
        else { return XCTFail() }
        XCTAssertEqual(second, first + 1)
    }

    /// An item's place or category that isn't there (a phone's pick from before the Mac removed it; 2026-10-23) is
    /// refused, in words the phone shows, so the item is never filed nowhere; a blank one is fine.
    func testAnItemsPlaceOrCategoryMustBeThere() async throws {
        let named = colId("Inventory", "Item"), location = colId("Inventory", "Location")
        let category = colId("Inventory", "Category"), gone = (inventory.locationRows.map(\.id).max() ?? 0) + 7
        let missingCategory = (inventory.categoryRows.map(\.id).max() ?? 0) + 7
        for values: [String: SQLValue] in [[named: .text("Zorvex lantern"), location: .int(gone)],
                                           [named: .text("Zorvex lantern"), category: .int(missingCategory)]] {
            let outcome = try await editor.apply(.add(table: "Inventory", values: values))
            XCTAssertEqual(outcome, .refused(InventoryWords.notThere))
        }
        let jugs = item("Drinking water jugs")
        let moved = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: location, value: .int(gone)))
        XCTAssertEqual(moved, .refused(InventoryWords.notThere))
        guard case .done = try await editor.apply(.add(table: "Inventory", values: [named: .text("Zorvex lantern"),
                                                                                  location: .int(0)]))
        else { return XCTFail("no place yet is fine") }
        XCTAssertEqual(InventoryWords.notThere, "That place or category isn't on the Mac any more. Pick another.")
    }

    /// B2-07: the Mac's question before deleting more than one row, and a phone never sends either change.
    /// Task 1.3 (2026-10-23): a place's name already used by a place kept in the same spot, a category's name already
    /// used, a blank name, or a Counts as the lists don't have, is refused in the editor; the same name in two different
    /// places is fine, and a Counts as in any case is stored as the lists spell it.
    func testLookAlikePlacesAndCategoriesAreRefused() async throws {
        var got: InventoryOutcome
        let name = colId("Locations", "Name"), keptIn = colId("Locations", "Kept in")
        let catName = colId("Categories", "Name"), countsAs = colId("Categories", "Counts as")
        let garage = place("Garage"), shed = place("Shed")
        got = try await editor.apply(.add(table: "Locations", values: [name: .text(" garage ")]))
        XCTAssertEqual(got,
                       .refused(String(format: InventoryWords.samePlace, "Garage")))
        got = try await editor.apply(.add(table: "Locations", values: [name: .text("  ")]))
        XCTAssertEqual(got,
                       .refused(InventoryWords.noPlaceName))
        guard case .done(_, let drawer) = try await editor.apply(.add(table: "Locations", values: [
            name: .text("Drawer 1"), keptIn: .int(garage)])) else { return XCTFail() }
        guard case .done = try await editor.apply(.add(table: "Locations", values: [
            name: .text("Drawer 1"), keptIn: .int(shed)])) else { return XCTFail("another place's Drawer 1 is fine") }
        got = try await editor.apply(.add(table: "Locations", values: [
            name: .text("drawer 1"), keptIn: .int(garage)]))
        XCTAssertEqual(got, .refused(String(format: InventoryWords.samePlace, "Drawer 1")))
        got = try await editor.apply(.set(table: "Locations", row: drawer, colId: keptIn, value: .int(shed)))
        XCTAssertEqual(got,
                       .refused(String(format: InventoryWords.samePlace, "Drawer 1")), "moved beside its double")
        got = try await editor.apply(.set(table: "Locations", row: shed, colId: name, value: .text("GARAGE")))
        XCTAssertEqual(got,
                       .refused(String(format: InventoryWords.samePlace, "Garage")))
        guard case .done = try await editor.apply(.set(table: "Locations", row: shed, colId: name,
                                                       value: .text("Shed"))) else { return XCTFail("its own name") }
        got = try await editor.apply(.add(table: "Categories", values: [catName: .text("WATER")]))
        XCTAssertEqual(got,
                       .refused(String(format: InventoryWords.sameCategory, "Water")))
        got = try await editor.apply(.add(table: "Categories", values: [catName: .text("Kit"),
                                                                                   countsAs: .text("Foods")]))
        XCTAssertEqual(got,
                       .refused(String(format: InventoryWords.countsAsChoices,
                                       ToBuyList.groups.map(InventoryLook.title).joined(separator: ", "))))
        guard case .done(_, let canned) = try await editor.apply(.add(table: "Categories", values: [
            catName: .text("Canned goods"), countsAs: .text(" food ")])) else { return XCTFail() }
        XCTAssertEqual(inventory.group(ofCategory: canned), "Food")
        let row = try XCTUnwrap(inventory.categoryRows.first { $0.id == canned })
        XCTAssertEqual(InventoryValues.plain(row.values[countsAs] ?? .null), "Food", "stored as the lists spell it")
        // the final review (5): look-alikes from before the rule never block a change to another column of theirs, and a
        // blank row from a table's Add takes its Kept in before its name
        let table = try editor.file.table("Categories")
        _ = try editor.file.addRow(table, values: [catName: .text("water")])
        try editor.reload()
        let legacy = try XCTUnwrap(inventory.categoryRows.last).id
        got = try await editor.apply(.set(table: "Categories", row: legacy, colId: countsAs, value: .text("Water")))
        guard case .done = got else { return XCTFail("\(got)") }
        guard case .done(_, let blank) = try await editor.apply(.add(table: "Locations", values: [:])) else {
            return XCTFail()
        }
        got = try await editor.apply(.set(table: "Locations", row: blank, colId: keptIn, value: .int(garage)))
        guard case .done = got else { return XCTFail("\(got)") }
        XCTAssertEqual(InventoryWords.samePlace, "There's already a place called %@ there.")
        XCTAssertEqual(InventoryWords.sameCategory, "There's already a category called %@.")
        XCTAssertEqual(InventoryWords.noPlaceName, "Give it a name.")
        XCTAssertEqual(InventoryWords.countsAsChoices, "Counts as must be one of: %@.")
        // The groups are named in title case (owner, 2026-10-30), the files keeping "Power and fuel"
        XCTAssertEqual(ToBuyList.groups.map(InventoryLook.title).filter { $0.contains(" and ") },
                       ["Power and Fuel", "Heat and Shelter", "Tools and Equipment", "Documents and Plans",
                        "Vehicles and RV", "Skills and Training"])
    }

    func testTheDeleteQuestionAndPhonesNeverSendIt() {
        XCTAssertEqual(InventoryWords.deleteAsk(3, table: "Inventory"), "Delete 3 items? Edit › Undo brings them back.")
        XCTAssertEqual(InventoryWords.deleteAsk(2, table: "Locations"), "Delete 2 rows? Edit › Undo brings them back.")
        XCTAssertEqual(InventoryWords.deleteMenu(3, table: "Inventory"), "Delete 3 items", "the menu says items too")
        XCTAssertEqual(InventoryWords.deleteMenu(2, table: "Locations"), "Delete 2 rows")
        XCTAssertEqual(InventoryWords.noName, "Give the item a name.")
        for change: InventoryChange in [.deleteRows(table: "Inventory", rows: [3]),
                                        .restoreRows(table: "Inventory", rows: [.init(id: 3, cells: [:])])] {
            XCTAssertEqual(PhoneRules.refusal(change, inventory), PhoneRules.notFromAPhone, "\(change)")
        }
    }

    func testUsedSomeGoesDownNeverBelowZeroAndAddsUp() async throws {
        let jugs = item("Drinking water jugs").id
        let quantity = inventory.items.column("Quantity")!
        _ = try await editor.apply(.adjust(row: jugs, by: -2))
        _ = try await editor.apply(.adjust(row: jugs, by: -1))
        XCTAssertEqual(inventory.itemRows.first { $0.id == jugs }![quantity], .text("3"))
        _ = try await editor.apply(.adjust(row: jugs, by: 0.5))
        XCTAssertEqual(inventory.itemRows.first { $0.id == jugs }![quantity], .text("3.5"))
        _ = try await editor.apply(.adjust(row: jugs, by: -10))
        XCTAssertEqual(inventory.itemRows.first { $0.id == jugs }![quantity], .text("0"))
        let flashlight = item("Test flashlight").id  // a blank quantity counts as 0
        _ = try await editor.apply(.adjust(row: flashlight, by: 1))
        XCTAssertEqual(inventory.itemRows.first { $0.id == flashlight }![quantity], .text("1"))
        _ = try await editor.apply(.set(table: "Inventory", row: flashlight, colId: quantity.colId, value: .text("a few")))
        let outcome5 = try await editor.apply(.adjust(row: flashlight, by: -1))
        XCTAssertEqual(outcome5, .refused(InventoryWords.notANumber))
    }

    func testChangesRunOneAtATimeInOrder() async throws {
        let jugs = item("Drinking water jugs").id
        let editor = self.editor!
        let first = Task { try await editor.apply(.adjust(row: jugs, by: -1)) }
        let second = Task { try await editor.apply(.adjust(row: jugs, by: -1)) }
        _ = try await (first.value, second.value)
        XCTAssertEqual(inventory.itemRows.first { $0.id == jugs }![inventory.items.column("Quantity")!], .text("4"))
    }

    func testAChangeRoundTripsAsJSON() throws {
        let change = InventoryChange.add(table: "Inventory", values: ["Item": .text("Lantern"), "Quantity": .text("2"),
                                                                      "Calories_each": .real(2.5), "Expires": .null,
                                                                      "Location": .int(3)])
        let data = try JSONEncoder().encode(change)
        XCTAssertEqual(try JSONDecoder().decode(InventoryChange.self, from: data), change)
        for change: InventoryChange in [.deleteRows(table: "Inventory", rows: [3, 5]),
                                        .restoreRows(table: "Inventory", rows: [.init(id: 3, cells: ["Item": .text("A")])])] {
            XCTAssertEqual(try JSONDecoder().decode(InventoryChange.self, from: try JSONEncoder().encode(change)), change)
        }
    }

    /// Print Labels' item says which it prints, one title in the toolbar's Print menu and the menu bar's Inventory
    /// (Task 13.1; F39; the inventory fresh look, spec 5.5; phase 1 fixes, finding 9).
    func testPrintLabelsSaysWhichItPrints() {
        XCTAssertEqual(InventoryWords.labelsItem(selected: 0), "Print Every Bin's Label")
        XCTAssertEqual(InventoryWords.labelsItem(selected: 1), "Print 1 Label")
        XCTAssertEqual(InventoryWords.labelsItem(selected: 3), "Print 3 Labels")
    }
}
