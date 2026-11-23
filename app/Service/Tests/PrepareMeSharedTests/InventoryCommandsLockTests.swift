import Testing
@testable import PrepareMeShared

/// The items' table opens locked until Edit Table (the inventory fresh look, phase 1, spec 5.2 and 5.5).
struct InventoryCommandsLockTests {
    @Test func theItemsStartLockedAndTheOtherTablesOpen() {
        #expect(!InventoryCommands.startsEditing(table: "Inventory"))
        #expect(InventoryCommands.startsEditing(table: "Locations"))
        #expect(InventoryCommands.startsEditing(table: "Categories"))
    }

    @Test func aLockedTableKeepsTheDeleteKeyOff() {
        let locked = InventoryCommands(table: "Inventory", grabView: false, selected: 1)
        #expect(locked.editTitle == "Edit Table")
        #expect(locked.canDelete)  // the menu and the right-click still delete
        #expect(!locked.deleteKeyWorks)
        let open = InventoryCommands(table: "Inventory", grabView: false, selected: 1, editing: true)
        #expect(open.editTitle == "Done")
        #expect(open.editMenuTitle == "Done Editing Table", "the menu bar says what it finishes")
        #expect(locked.editMenuTitle == "Edit Table")
        #expect(open.deleteKeyWorks)
    }

    @Test func deleteAsksFirstForSeveralSoItTakesItsDots() {
        #expect(InventoryCommands(table: "Inventory", grabView: false, selected: 1).deleteTitle == "Delete")
        #expect(InventoryCommands(table: "Inventory", grabView: false, selected: 3).deleteTitle == "Delete…")
    }

    @Test func aPlacesOwnTablePrintsItsLabelAndSheet() {
        let place = InventoryCommands(table: "Inventory", grabView: false, selected: 0, placeView: true)
        #expect(place.canPrintLabels && place.canPrintGrabSheets)
    }

    /// The locked sign beside Edit Table (owner, 2026-11-17, by click, after the review): only on a locked items' table.
    @Test func theLockedSignShowsOnlyWhileTheItemsAreLocked() {
        let locked = InventoryCommands(table: "Inventory", grabView: false, selected: 0)
        #expect(locked.lockedSign == "Locked")
        #expect(locked.lockedSignSpoken == "Locked. Press Edit Table to change cells.")
        #expect(InventoryCommands(table: "Inventory", grabView: false, selected: 0, editing: true).lockedSign == nil)
        #expect(InventoryCommands(table: "Inventory", grabView: true, selected: 2, placeView: false).lockedSign == "Locked")
        for table in ["Locations", "Categories"] {
            #expect(InventoryCommands(table: table, grabView: false, selected: 0, editing: true).lockedSign == nil)
            #expect(InventoryCommands(table: table, grabView: false, selected: 0, editing: false).lockedSign == nil)
        }
    }
}

/// Delete, from the menu or the key, takes only selected rows still on screen (phase 1 fixes round 2, finding F): a
/// row a search hid stays out of it.
struct InventoryOnScreenTests {
    @Test func aSelectedRowHiddenBySearchIsLeftOut() {
        #expect(InventoryCommands.onScreen([1, 2, 3], shown: [2, 3, 4]) == [2, 3])
    }

    @Test func everySelectedRowHiddenLeavesNothing() {
        #expect(InventoryCommands.onScreen([1], shown: [2, 3]).isEmpty)
    }
}

/// Print's own tip says what each of its items prints: tips on the items inside a toolbar menu never show (round 2,
/// finding D).
struct InventoryPrintTipTests {
    @Test func theItemsTipNamesTheBlankSheet() {
        #expect(InventoryWords.printTip(blank: true, labels: false, grab: false, selected: 0)
                == "Print Blank Sheet: an empty sheet to fill in by hand, with a key of today's places and categories")
    }

    @Test func aPlacesTipNamesEachBinOrTheSelectedPlaces() {
        let every = InventoryWords.printTip(blank: false, labels: true, grab: true, selected: 0)
        #expect(every.contains("Labels: a QR label for every bin (a place kept in another)"))
        #expect(every.contains("Grab Sheets: the grab lists, then a page for each vehicle and each bin"))
        #expect(InventoryWords.printTip(blank: false, labels: true, grab: true, selected: 2)
            .contains("Labels: a QR label for each selected place"))
    }

    /// A place's own table (phase 3) prints that place's label and grab sheet: one label, whatever items are picked; on
    /// Locations the places picked, every bin's with none.
    @Test func aPlacesTablePrintsItsOwnLabel() {
        let place = InventoryCommands(table: "Inventory", grabView: false, selected: 3, placeView: true)
        #expect(place.canPrintLabels && place.canPrintGrabSheets)
        #expect(place.labelCount == 1)
        #expect(InventoryWords.labelsItem(selected: place.labelCount) == "Print 1 Label")
        #expect(InventoryCommands(table: "Locations", grabView: false, selected: 2).labelCount == 2)
        #expect(InventoryCommands(table: "Locations", grabView: false, selected: 0).labelCount == 0)
        let items = InventoryCommands(table: "Inventory", grabView: false, selected: 3)
        #expect(!items.canPrintLabels && items.labelCount == 0)
    }

    /// Fix round 1, finding 11: a place's own table names that place's label and grab sheet, never "each selected place"
    /// (nothing there is a place to select).
    @Test func aPlacesTablesTipNamesThatPlace() {
        let tip = InventoryWords.printTip(blank: false, labels: true, grab: true, selected: 1, place: true)
        #expect(tip.contains("Labels: this place's QR label"))
        #expect(tip.contains("Grab Sheets: this place's page of what's in it"))
        #expect(!tip.contains("selected"))
    }
}

/// Inventory's home page (phase 3, board 1): New Item…, Add by Barcode… and Print (the blank sheet, every bin's labels,
/// the grab sheets) work there, and the commands that need a table on screen (Edit Table, Columns, Export CSV…, Remove
/// Empty Places…, Open as Form…, Delete) are dimmed, never hidden.
struct InventoryHomeCommandsTests {
    @Test func theHomePageAddsAndPrintsButHasNoTable() {
        let home = InventoryCommands.home
        #expect(home.canAdd && home.addTitle == "New Item…" && home.canAddByBarcode)
        #expect(home.canPrintBlankSheet && home.canPrintLabels && home.canPrintGrabSheets)
        #expect(home.labelCount == 0, "every bin's labels")
        #expect(!home.canEditTable && !home.canChooseColumns && !home.canOpenForm && !home.canDelete)
        #expect(home.lockedSign == nil, "no table, so nothing locked")
        // the owner's choice A (2026-11-18, "Fix all now"): Inventory opens on its home page, so these work there too
        #expect(home.canExportCSV && home.canRemoveEmptyPlaces)
        for table in ["Inventory", "Locations", "Categories"] {
            let shown = InventoryCommands(table: table, grabView: false, selected: 0)
            #expect(shown.canEditTable && shown.canChooseColumns && shown.canExportCSV && shown.canRemoveEmptyPlaces)
        }
    }
}
