import XCTest
@testable import PrepareMeShared

/// The Mac's Inventory menu and toolbar (the Apple guidelines plan, phase 2): what each table and selection allows.
final class InventoryCommandsTests: XCTestCase {
    func testTheItemsAllowTheFormsAndPrintsTheirSheet() {
        let none = InventoryCommands(table: "Inventory", grabView: false, selected: 0)
        XCTAssertEqual(none.addTitle, "New Item…", "the New item form opens first")
        XCTAssertTrue(none.canAdd && none.canAddByBarcode && none.canPrintBlankSheet)
        XCTAssertFalse(none.canOpenForm || none.canDelete || none.canPrintLabels || none.canPrintGrabSheets)
        let one = InventoryCommands(table: "Inventory", grabView: false, selected: 1)
        XCTAssertTrue(one.canOpenForm && one.canDelete)
        let two = InventoryCommands(table: "Inventory", grabView: false, selected: 2)
        XCTAssertFalse(two.canOpenForm, "a form is one item's")
        XCTAssertTrue(two.canDelete)
        XCTAssertTrue(InventoryCommands(table: "Inventory", grabView: true, selected: 0).canPrintGrabSheets)
    }

    func testLocationsPrintLabelsAndGrabSheets() {
        let places = InventoryCommands(table: "Locations", grabView: false, selected: 0)
        XCTAssertEqual(places.addTitle, "New Row", "a row goes straight in, no form")
        XCTAssertTrue(places.canAdd && places.canPrintLabels && places.canPrintGrabSheets)
        XCTAssertFalse(places.canAddByBarcode || places.canOpenForm || places.canPrintBlankSheet)
    }
}
