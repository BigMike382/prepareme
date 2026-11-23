import Testing
@testable import PrepareMeShared

/// Which columns the Mac's items' table shows, in what order (the inventory fresh look, phase 1, spec 5.2).
struct ItemsTableColumnsTests {
    @Test func theSixteenLeftOffTodayStartHidden() {
        #expect(ItemsTableColumns.hiddenAtFirst == [
            "Model", "Year", "Manual", "Notes", "Calories each", "Each holds", "Holds unit", "Pet food for",
            "Running watts", "Starting watts", "Empty until needed", "Keep past date", "Mac only", "Purchased",
            "Price", "Serial number",
        ])
    }

    @Test func theFirstColumnsLeadThenTheFilesOrder() {
        #expect(ItemsTableColumns.ordered(["Brand", "Item", "Notes", "Unit"]) == ["Item", "Unit", "Brand", "Notes"])
    }

    @Test func aViewLeavesOutTheColumnEveryRowWouldRepeat() {
        #expect(ItemsTableColumns.leftOut(.category(3), binsInside: 0) == ["Category"])
        #expect(ItemsTableColumns.leftOut(.location(2), binsInside: 0) == ["Location"])
        #expect(ItemsTableColumns.leftOut(.location(2), binsInside: 4).isEmpty)  // Location tells the bins apart
        #expect(ItemsTableColumns.leftOut(.all, binsInside: 0).isEmpty)
    }

    // Review focus 1: a remembered layout that no longer fits the file.
    @Test func aSavedSortOnAColumnNoLongerThereIsDropped() {
        #expect(ItemsTableColumns.sort(SavedSort(label: "Price", ascending: true), among: ["Item"]) == nil)
        let kept = SavedSort(label: "item", ascending: false)
        #expect(ItemsTableColumns.sort(kept, among: ["Item"]) == kept)
        #expect(ItemsTableColumns.sort(nil, among: ["Item"]) == nil)
    }

    @Test func aColumnInNeitherListComesLastAndShows() {
        #expect(ItemsTableColumns.ordered(["Warranty", "Item", "Brand"]) == ["Item", "Brand", "Warranty"])
        #expect(!ItemsTableColumns.hiddenAtFirst.contains("Warranty"))
    }

    // Task 1.3: the starting widths, fitted to the window.
    @Test func theCapLeavesColumnsWholeWhenTheyFit() {
        #expect(ItemsTableColumns.cap([50, 60], room: 200) == .infinity)
    }

    @Test func theWidestShareOneCapAndTheNarrowStayWhole() {
        #expect(ItemsTableColumns.cap([300, 300, 80], room: 480) == 200)
    }

    @Test func theCapNeverGoesBelowItsLeast() {
        #expect(ItemsTableColumns.cap([300, 80], room: 100) == 100)  // so the row runs past
    }

    @Test(arguments: [([300, 300, 80], 480), ([500, 220, 130, 90, 70], 700), ([400, 400, 400, 60], 900),
                      ([250, 249, 248], 600)] as [([Double], Double)])
    func theCappedRowNeverRunsPastItsRoom(wants: [Double], room: Double) {
        let cap = ItemsTableColumns.cap(wants, room: room)
        #expect(cap > 100)
        #expect(wants.map { min($0, cap) }.reduce(0, +) <= room + 0.0001)
    }

    @Test func itemIsTheLastColumnTrimmed() {
        let wants: [Double] = [300, 150, 150, 60]
        #expect(ItemsTableColumns.widths(wants, first: 0, room: 700) == wants)  // they fit
        #expect(ItemsTableColumns.widths(wants, first: 0, room: 600) == [300, 120, 120, 60])  // Item whole
        #expect(ItemsTableColumns.widths(wants, first: 0, room: 400) == [140, 100, 100, 60])  // Item takes the rest
        #expect(ItemsTableColumns.widths(wants, first: 0, room: 300) == [100, 100, 100, 60])  // the row runs past
    }

    @Test func withNoFirstColumnOneCapServesAll() {
        #expect(ItemsTableColumns.widths([300, 300, 80], first: nil, room: 480) == [200, 200, 80])
    }

    // Review focus 1: the remembered hidden labels against today's file.
    @Test func theFirstColumnAlwaysShowsAndUnknownSavedLabelsAreIgnored() {
        let shown = ItemsTableColumns.shown(["Item", "Unit", "Category", "Price"], hidden: ["Item", "Price", "Gone"],
                                            leftOut: ["Category"], first: "Item")
        #expect(shown == ["Item", "Unit"])
    }

    @Test func aColumnTheFileGainsLaterFollowsTheHiddenAtFirstList() {
        // Notes ticked on while the file had no Price: Price stays hidden for the day the insurance record adds it
        let saved = ItemsTableColumns.hiding("Notes", false, in: ItemsTableColumns.hiddenAtFirst)
        #expect(saved.contains("Price") && !saved.contains("Notes"))
        #expect(ItemsTableColumns.hiding("unit", true, in: ["Price"]) == ["Price", "unit"])
        #expect(ItemsTableColumns.hiding("Unit", true, in: ["unit"]) == ["Unit"])  // never twice
    }
}
