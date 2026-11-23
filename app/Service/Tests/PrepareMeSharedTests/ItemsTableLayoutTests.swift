import Foundation
import Testing
@testable import PrepareMeShared

/// The Mac's items' table as behavior, not source text (phase 1 fixes, finding 15): what it remembers, which columns
/// it lists and shows, the room it fits them in and the width it fits to.
struct ItemsTableLayoutTests {
    static func column(_ colId: String, _ label: String) -> InventoryColumn {
        InventoryColumn(ref: 0, colId: colId, label: label, type: "Text", kind: .text, isFormula: false, choices: [],
                        shownColId: nil, displayColId: nil)
    }

    static func defaults() -> UserDefaults { UserDefaults(suiteName: "prepareme.tests." + UUID().uuidString)! }

    // MARK: the memory

    @Test func theMemoryKeepsHiddenColumnsAndTheSortPerTable() {
        let memory = InventoryTableMemory(Self.defaults())
        #expect(memory.hidden("items") == ItemsTableColumns.hiddenAtFirst)  // nothing saved: the first list
        #expect(memory.hidden("Locations").isEmpty)
        memory.setHidden(["Unit"], "items")
        memory.setSort(SavedSort(label: "#", ascending: false), "items")
        #expect(memory.hidden("items") == ["Unit"])
        #expect(memory.sort("items") == SavedSort(label: "#", ascending: false))
        #expect(memory.sort("Locations") == nil)  // one memory each
        memory.forget("items")  // Reset Columns: the hidden list only
        #expect(memory.hidden("items") == ItemsTableColumns.hiddenAtFirst)
        #expect(memory.sort("items") != nil)
        memory.setSort(nil, "items")  // a sort whose column was hidden
        #expect(memory.sort("items") == nil)
    }

    @Test func aCorruptSavedValueFallsBackToTheFirstList() {
        let defaults = Self.defaults()
        defaults.set("not json", forKey: InventoryTableMemory.columnsPrefix + "items")
        defaults.set("{\"label\": 3}", forKey: InventoryTableMemory.sortPrefix + "items")
        let memory = InventoryTableMemory(defaults)
        #expect(memory.hidden("items") == ItemsTableColumns.hiddenAtFirst)
        #expect(memory.sort("items") == nil)
    }

    @Test func forgetAllClearsEveryTablesMemoryAndNothingElse() {
        let defaults = Self.defaults()
        defaults.set("kept", forKey: "prepareme.mac.row")
        let memory = InventoryTableMemory(defaults)
        memory.setHidden([], "items")
        memory.setSort(SavedSort(label: "Item", ascending: true), "Categories")
        memory.forgetAll()
        #expect(memory.hidden("items") == ItemsTableColumns.hiddenAtFirst)
        #expect(memory.sort("Categories") == nil)
        #expect(defaults.string(forKey: "prepareme.mac.row") == "kept")
    }

    // MARK: the sort's round trip

    @Test func theSavedSortComesBackOnlyWhereItsColumnShows() {
        let saved = SavedSort(label: "#", ascending: true)
        #expect(ItemsTableColumns.sort(saved, among: ["#", "Item"]) == saved)  // "#" is the file's own order
        let brand = SavedSort(label: "Brand", ascending: false)
        let memory = InventoryTableMemory(Self.defaults())
        memory.setSort(brand, "items")
        #expect(ItemsTableColumns.sort(memory.sort("items"), among: ["#", "Item", "Brand"]) == brand)
        #expect(ItemsTableColumns.sort(memory.sort("items"), among: ["#", "Item"]) == nil)  // a view without Brand
    }

    @Test func hidingTheSortedColumnDropsTheSort() {
        #expect(ItemsTableColumns.dropsSort(hiding: "Brand", sortedBy: "Brand"))
        #expect(ItemsTableColumns.dropsSort(hiding: "brand ", sortedBy: "Brand"))
        #expect(!ItemsTableColumns.dropsSort(hiding: "Unit", sortedBy: "Brand"))
        #expect(!ItemsTableColumns.dropsSort(hiding: "Unit", sortedBy: nil))
        #expect(!ItemsTableColumns.dropsSort(hiding: "#", sortedBy: "#"))  // "#" is never hidden
    }

    // MARK: which columns are listed and shown (finding 7 too)

    @Test func tickableOrdersTheItemsAndLeavesOutWhatTheViewDrops() {
        let all = [Self.column("B", "Brand"), Self.column("I", "Item"), Self.column("C", "Category"),
                   Self.column("N", "Notes")]
        #expect(ItemsTableColumns.tickable(all, items: true, leftOut: []).map(\.colId) == ["I", "C", "B", "N"])
        #expect(ItemsTableColumns.tickable(all, items: true, leftOut: ["category"]).map(\.colId) == ["I", "B", "N"])
        #expect(ItemsTableColumns.tickable(all, items: false, leftOut: []).map(\.colId) == ["B", "I", "C", "N"])
    }

    @Test func twoColumnsWithOneLabelAreBothListedOnce() {
        let all = [Self.column("I", "Item"), Self.column("N1", "Notes"), Self.column("N2", "Notes"),
                   Self.column("I2", "item ")]
        let listed = ItemsTableColumns.tickable(all, items: true, leftOut: []).map(\.colId)
        #expect(listed.sorted() == ["I", "I2", "N1", "N2"])  // none dropped, none twice
        #expect(listed.first == "I")
        #expect(ItemsTableColumns.ordered(["Item", "Notes", "Notes", "item "]).count == 4)
    }

    @Test func shownIsTickableLessHiddenButTheFirstAlwaysShows() {
        let all = [Self.column("I", "Item"), Self.column("U", "Unit"), Self.column("P", "Price"),
                   Self.column("P2", "Price")]
        let shown = ItemsTableColumns.shownColumns(all, hidden: ["unit", "Item", "Gone"], first: "Item")
        #expect(shown.map(\.colId) == ["I", "P", "P2"])  // Item can't be hidden; a label the file lacks is ignored
    }

    @Test func aColumnAddedLaterStartsHidden() {
        let memory = InventoryTableMemory(Self.defaults())
        memory.setHidden(ItemsTableColumns.hiding("Unit", true, in: memory.hidden("items")), "items")
        let later = [Self.column("I", "Item"), Self.column("U", "Unit"), Self.column("S", Insurance.serial)]
        let shown = ItemsTableColumns.shownColumns(later, hidden: memory.hidden("items"), first: "Item")
        #expect(shown.map(\.colId) == ["I"])  // Serial number, added by the insurance record, stays hidden
    }

    // MARK: the room and the width fitted to

    @Test func theRoomIsTheTableLessHashGapsAndScroller() {
        #expect(ItemsTableColumns.room(tableWidth: 989, shown: 8) == 770)
        let starts = ItemsTableColumns.starts([Self.column("I", "Item"), Self.column("C", "Category")],
                                              fitted: ["I": 360, "C": 171], first: "Item", tableWidth: 400)
        #expect(starts["C"] == 100)  // capped, never below 100
        #expect(starts["I"] == 183)  // Item takes what's left: 400 - 48 - 17 * 3 - 18 - 100
        let roomy = ItemsTableColumns.starts([Self.column("I", "Item")], fitted: [:], first: "Item", tableWidth: 2000)
        #expect(roomy["I"] == 120)  // a column not yet measured
    }

    @Test func startsNeverTrapOnARepeatedColumn() {
        let item = Self.column("I", "Item")
        let starts = ItemsTableColumns.starts([item, item], fitted: ["I": 200], first: "Item", tableWidth: 1000)
        #expect(starts.count == 1)
    }

    @Test func aFreshTableFitsToTheLiveWidthAnOpenOneKeepsItsOwn() {
        #expect(ItemsTableColumns.fitWidth(key: "a", fittedKey: nil, fittedWidth: nil, live: nil) == nil)
        #expect(ItemsTableColumns.fitWidth(key: "a", fittedKey: nil, fittedWidth: nil, live: 900) == 900)
        #expect(ItemsTableColumns.fitWidth(key: "a", fittedKey: "a", fittedWidth: 600, live: 900) == 600)  // a resize
        #expect(ItemsTableColumns.fitWidth(key: "b", fittedKey: "a", fittedWidth: 600, live: 900) == 900)  // a switch
    }
}
