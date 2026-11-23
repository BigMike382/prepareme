import Testing
@testable import PrepareMeShared

/// The owner's wording rule (2026-11-19): the screens show To Do, To Buy and Bought's button words, while the sheet
/// names the lists file is matched by stay as they are.
struct ListsShownTitleTests {
    @Test func theScreensTitleASheetWithoutRenamingIt() {
        #expect(ListsLayout.todo == "To do" && ListsLayout.toBuy == "To buy" && ListsLayout.bought == "Bought",
                "the file's sheet names")
        #expect(ListsLayout.shownTitle(ListsLayout.todo) == "To Do")
        #expect(ListsLayout.shownTitle(ListsLayout.toBuy) == "To Buy")
        #expect(ListsLayout.shownTitle(ListsLayout.bought) == InventoryHomeTiles.More.bought.title)
        for sheet in [ListsLayout.upkeep, ListsLayout.targets, ListsLayout.proposed, ListsLayout.recalls] {
            #expect(ListsLayout.shownTitle(sheet) == sheet)
        }
    }
}
