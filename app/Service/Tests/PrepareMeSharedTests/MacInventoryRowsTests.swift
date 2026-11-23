import Foundation
import PrepareMeShared
import Testing

/// The five rows under Inventory in the Mac's sidebar (the inventory fresh look, phase 3, Task 3.1; spec 5.1).
struct MacInventoryRowsTests {
    @Test func theFiveRowsInOrderWithTheirWords() {
        #expect(MacSidebar.inventoryRows == [.inventoryList(.all), .inventoryList(.toBuy), .inventoryList(.expiringSoon),
                                             .inventoryList(.toDo), .inventoryList(.upkeep)])
        #expect(MacSidebar.inventoryRows.map(MacSidebar.title) == ["All Items", "To Buy", "Expiring Soon", "To Do",
                                                                     "Upkeep"])
        #expect(MacSidebar.inventoryOpenKey == "prepareme.mac.inventoryOpen")
    }

    @Test func noneHasAReaderOrAPage() {
        for row in MacSidebar.inventoryRows {
            #expect(row.reader == nil, "the app's own screen, as Inventory")
            #expect(row.page(newPage: "new-guides.html") == nil)
        }
    }

    /// ⌘6 is still Inventory: the five sit inside its fold, never in `topLevel`.
    @Test func theTopLevelIsUnchanged() {
        #expect(MacSidebar.topLevel == [.today, .guides, .shelf, .games, .maps, .inventory, .documents, .news,
                                        .printableReferences])
        #expect(MacSidebar.goKey(.inventory) == "6")
        #expect(MacSidebar.inventoryRows.allSatisfy { MacSidebar.goKey($0) == nil })
    }

    /// Each row's fixed list, and the way back: every pick names the sidebar row it is shown under (`row(for:)`), so
    /// Today, a guide's In the house, Show Them, Go to that item and a count each land on the row they belong to.
    @Test func eachRowShowsItsListAndEachPickItsRow() {
        #expect(MacInventoryList.all.pick == .table("Inventory"))
        #expect(MacInventoryList.toBuy.pick == .toBuy)
        #expect(MacInventoryList.expiringSoon.pick == .view(.expiringSoon))
        #expect(MacInventoryList.toDo.pick == .list(ListsLayout.todo))
        #expect(MacInventoryList.upkeep.pick == .list(ListsLayout.upkeep))
        for list in MacInventoryList.allCases {
            #expect(MacInventoryList.row(for: list.pick) == .inventoryList(list), "\(list) back to its own row")
        }
        for other: InventoryPick in [.table("Locations"), .table("Categories"), .view(.category(3)), .view(.location(2)),
                                     .view(.grab(1)), .view(.privateOnly), .view(.insured), .view(.all),
                                     .view(.guide(title: "Water storage", words: ["water"])), .view(.leftOut([])),
                                     .list(ListsLayout.targets), .list(ListsLayout.proposed), .list(ListsLayout.recalls),
                                     .list(ListsLayout.bought)] {
            #expect(MacInventoryList.row(for: other) == .inventory, "\(other) is shown under Inventory itself")
        }
    }
}

/// What Inventory's pane shows from the sidebar's row, Inventory's own pick and the one search box (phase 3, fix round
/// 1, finding 1): moved here from the view so each move is tested through the real rule.
struct MacInventoryPageTests {
    @Test func whatShowsOnEachRow() {
        var page = MacInventoryPage()
        #expect(page.shown(on: .inventory) == nil, "the home page")
        #expect(!page.showsBack(on: .inventory))
        page.search = "lantern"
        #expect(page.shown(on: .inventory) == .table("Inventory"), "a home page search shows All Items")
        #expect(page.showsBack(on: .inventory), "and a way back home")
        for list in MacInventoryList.allCases {
            #expect(page.shown(on: .inventoryList(list)) == list.pick, "a list row shows its own list, search or not")
            #expect(!page.showsBack(on: .inventoryList(list)))
        }
        page = MacInventoryPage(pick: .view(.category(3)))
        #expect(page.shown(on: .inventory) == .view(.category(3)))
        #expect(page.showsBack(on: .inventory))
    }

    @Test func homeClearsThePickAndTheSearch() {
        var page = MacInventoryPage(pick: .view(.location(2)), search: "rope")
        page.goHome()
        #expect(page == MacInventoryPage())
    }

    /// A pick asked for from elsewhere lands on the row it belongs under; Inventory's row keeps it.
    @Test func aRequestTakesItsRow() {
        var page = MacInventoryPage(search: "rope")
        #expect(page.take(.view(.category(3))) == .inventory)
        #expect(page.pick == .view(.category(3)))
        #expect(page.take(.table("Inventory")) == .inventoryList(.all))
        #expect(page.pick == nil, "a list row's pick isn't Inventory's")
        #expect(page.take(.toBuy) == .inventoryList(.toBuy))
    }

    /// Leaving Inventory's row drops its tile; coming back with none open drops a list row's search words, so the
    /// home page shows, not All Items.
    @Test func movingRows() {
        var page = MacInventoryPage(pick: .view(.category(3)), search: "rope")
        page.moved(to: .inventoryList(.toBuy))
        #expect(page.pick == nil && page.search == "rope")
        page.moved(to: .inventory)
        #expect(page == MacInventoryPage())
        page = MacInventoryPage(pick: .view(.category(3)), search: "rope")
        page.moved(to: .inventory)
        #expect(page.search == "rope", "a tile's table keeps its search")
    }

    /// The finding: a search on the home page, then Add (or Go to that item) for an item the search hides. Clearing
    /// the words must not drop the table (and its open form) for the home page: All Items moves to its own row, where
    /// it shows with no search, so the table and its sheet stay.
    @Test func clearingAHomePageSearchKeepsAllItems() {
        var page = MacInventoryPage(search: "lantern")
        let before = page.shown(on: .inventory)
        let moveTo = page.clearSearch(on: .inventory)
        #expect(moveTo == .inventoryList(.all))
        #expect(page.search.isEmpty)
        let row = moveTo ?? .inventory
        #expect(page.shown(on: row) == before, "the same table, so the same view and its sheet")
        page.moved(to: row)
        #expect(page.shown(on: row) == .table("Inventory"))
    }

    /// Anywhere else the search clears in place: the row and the table stay.
    @Test func clearingAnyOtherSearchStaysPut() {
        var page = MacInventoryPage(pick: .view(.category(3)), search: "rope")
        #expect(page.clearSearch(on: .inventory) == nil)
        #expect(page == MacInventoryPage(pick: .view(.category(3))))
        page.search = "rope"
        #expect(page.clearSearch(on: .inventoryList(.all)) == nil)
        #expect(page.search.isEmpty)
        var home = MacInventoryPage()
        #expect(home.clearSearch(on: .inventory) == nil, "nothing to clear on the home page")
    }
}
