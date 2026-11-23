import Foundation
import PrepareMeShared
import XCTest

/// The Mac sidebar's rows (Mac sidebar plan, task 5): which reader each opens, which page it shows, and how a link
/// from inside a page picks its row.
final class MacRowsTests: XCTestCase {
    let category = MacRow.category(page: "topic-medical.html")
    let sub = MacRow.sub(page: "topic-medical.html", anchor: "first-aid")
    let library = MacRow.library(id: UUID(uuidString: "0F1E2D3C-4B5A-4968-8776-6554433221B1")!)

    func testEachRowOpensItsReader() {
        XCTAssertEqual(MacRow.today.reader, .today)
        XCTAssertEqual(MacRow.guides.reader, .guides)
        XCTAssertEqual(MacRow.new.reader, .guides)
        XCTAssertEqual(MacRow.news.reader, .guides, "News is a page of the daily library (step 7)")
        XCTAssertEqual(category.reader, .guides)
        XCTAssertEqual(sub.reader, .guides)
        XCTAssertEqual(library.reader, .guides, "an other library opens in the Guides tab, as its menu did (2026-10-25)")
        XCTAssertEqual(MacRow.maps.reader, .maps)
        XCTAssertNil(MacRow.inventory.reader)
        XCTAssertNil(MacRow.householdPages.reader, "Edit Our Home is the app's own screen (phase C)")
        XCTAssertEqual(MacSidebar.editHouseholdPages, "Edit Our Home", "Our Home Task 1.2: its heading and toolbar title")
        XCTAssertNil(MacRow.printableReferences.reader, "Printable References is the app's own screen")
        for row in [MacRow.shelf, .shelfNew, .shelfCategory(id: "medical"), .shelfUnsorted] {
            XCTAssertNil(row.reader, "the Library's lists are the app's own screen (Library plan, task 2.1)")
            XCTAssertNil(row.page(newPage: "new-guides.html"))
        }
    }

    func testEachRowShowsItsPage() {
        XCTAssertNil(MacRow.today.page(newPage: "new-guides.html"))
        XCTAssertEqual(MacRow.guides.page(newPage: "new-guides.html"), "guides.html")
        XCTAssertEqual(MacRow.new.page(newPage: "new-guides.html"), "new-guides.html")
        XCTAssertEqual(MacRow.new.page(newPage: "other.html"), "other.html")
        XCTAssertEqual(MacRow.news.page(newPage: "new-guides.html"), "news-board.html",
                       "packer/build.py's NEWS_BOARD_PAGE (news plan phase 3)")
        XCTAssertEqual(category.page(newPage: "new-guides.html"), "topic-medical.html")
        XCTAssertEqual(sub.page(newPage: "new-guides.html"), "topic-medical.html#first-aid")
        XCTAssertNil(MacRow.maps.page(newPage: "new-guides.html"))
        XCTAssertNil(library.page(newPage: "new-guides.html"), "its own front page, not a daily library page")
        XCTAssertNil(MacRow.inventory.page(newPage: "new-guides.html"))
        XCTAssertNil(MacRow.householdPages.page(newPage: "new-guides.html"))
        XCTAssertNil(MacRow.printableReferences.page(newPage: "new-guides.html"))
    }

    /// Kiwix's page addresses are relative to the library's (`URL(zimFileID:contentPath:)`): the page beside one keeps
    /// the library, and a sub-category's anchor stays the fragment. Its first build dropped the library, so every
    /// sub-category row failed to load ("Unable to load the page requested", seen on screen 2026-10-16).
    func testAPageBesideTheFrontPageKeepsItsLibraryAndAnchor() {
        let main = URL(string: "index.html", relativeTo: URL(string: "zim://0F1E2D3C-4B5A-4968-8776-6554433221B1"))!
        XCTAssertEqual(MacRow.address("topic-medical.html#first-aid", beside: main).absoluteString,
                       "zim://0F1E2D3C-4B5A-4968-8776-6554433221B1/topic-medical.html#first-aid")
        XCTAssertEqual(MacRow.address("guides.html", beside: main).absoluteString,
                       "zim://0F1E2D3C-4B5A-4968-8776-6554433221B1/guides.html")
        let absolute = URL(string: "zim://0F1E2D3C-4B5A-4968-8776-6554433221B1/index.html")!
        XCTAssertEqual(MacRow.address("topic-medical.html#first-aid", beside: absolute).absoluteString,
                       "zim://0F1E2D3C-4B5A-4968-8776-6554433221B1/topic-medical.html#first-aid")
    }

    func testALinkPicksMapsForAMapFileElseGuides() {
        XCTAssertEqual(MacRow.forLink(isMapFile: true), .maps)
        XCTAssertEqual(MacRow.forLink(isMapFile: false), .guides)
    }

    /// Today's Inventory button, any library's (owner, 2026-10-28): the Mac's Inventory screen, never the phone page.
    func testTheInventoryPageOfAnyLibraryIsTheInventoryScreen() {
        let id = "0F1E2D3C-4B5A-4968-8776-6554433221B1"
        XCTAssertTrue(MacRow.isInventoryPage(URL(string: "zim://\(id)/inventory.html")!))
        XCTAssertTrue(MacRow.isInventoryPage(URL(string: "zim://\(id)/A/inventory.html")!))
        let main = URL(string: "index.html", relativeTo: URL(string: "zim://\(id)"))!
        XCTAssertTrue(MacRow.isInventoryPage(URL(string: "inventory.html", relativeTo: main)!))
        XCTAssertFalse(MacRow.isInventoryPage(URL(string: "zim://\(id)/guides.html")!))
        XCTAssertFalse(MacRow.isInventoryPage(URL(string: "zim://\(id)/inventory.html.bak")!))
        XCTAssertFalse(MacRow.isInventoryPage(URL(string: "https://example.org/inventory.html")!))
    }

    func testEveryRowSurvivesASaveAndReload() throws {
        for row in [MacRow.today, .guides, .new, .news, category, sub, .maps, .inventory, .documents, .games,
                    .householdPages, .printableReferences, library, .shelf, .shelfNew, .shelfCategory(id: "medical"), .shelfUnsorted]
                + MacInventoryList.allCases.map(MacRow.inventoryList) {
            let data = try JSONEncoder().encode(row)
            XCTAssertEqual(try JSONDecoder().decode(MacRow.self, from: data), row)
        }
    }

    /// The Go menu's keys (menu bar plan, owner 2026-11-14): ⌘1 to ⌘9 in the sidebar's order; none for a row off the
    /// list or past the ninth, so a tenth row would show without a key.
    func testGoKeysFollowTheSidebar() {
        XCTAssertEqual(MacSidebar.topLevel.map { MacSidebar.goKey($0) }, ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        XCTAssertNil(MacSidebar.goKey(.householdPages), "not a sidebar row")
        let ten = (0..<10).map { MacRow.category(page: "p\($0)") }
        XCTAssertEqual(MacSidebar.goKey(ten[8], in: ten), "9")
        XCTAssertNil(MacSidebar.goKey(ten[9], in: ten), "no key past ⌘9")
        XCTAssertEqual(MacLibraries.collectionsTitle, "Library Collections", "Go's list, beside the Library screen's item")
        XCTAssertEqual(MacLibraries.menuTitle, "Library", "the phone's ••• menu keeps its name")
    }

    /// R6.1 (owner, 2026-10-20; mockup 6): one Guides row with New and the categories inside it, News under Inventory
    /// as its own row, no Categories folder row; the household pages' editor is in the File menu (owner, 2026-11-14).
    func testSidebarRowsAreTodayGuidesMapsInventoryNewsAndPrintableReferences() {
        XCTAssertEqual(MacSidebar.topLevel,
                       [.today, .guides, .shelf, .games, .maps, .inventory, .documents, .news, .printableReferences],
                       "Library right under Guides (owner, 2026-11-12), Games under it (games plan phase 4)")
        XCTAssertEqual(MacSidebar.title(.printableReferences), "Printable References", "the owner's name, as typed")
        XCTAssertEqual(MacSidebar.topLevel.map(MacSidebar.title),
                       ["Today", "Guides", "Library", "Games", "Maps", "Inventory", "Essential Documents", "News",
                        "Printable References"])
        XCTAssertEqual(MacSidebar.title(.shelfNew), "New")
        XCTAssertEqual(MacSidebar.title(.shelfUnsorted), "Needs a category")
        XCTAssertNil(MacSidebar.title(.shelfCategory(id: "medical")), "a category row carries its own name and emoji")
        XCTAssertEqual(MacSidebar.insideGuides(pages: ["topic-medical.html", "topic-water.html"]),
                       [.new, .category(page: "topic-medical.html"), .category(page: "topic-water.html")],
                       "New first, then the categories, inside Guides; nothing else")
        XCTAssertEqual(MacSidebar.insideGuides(pages: []), [.new], "a library with no list still has New")
        XCTAssertFalse(MacSidebar.topLevel.contains(.new), "New is no longer a top-level row")
        XCTAssertEqual(MacSidebar.title(.new), "New")  // the sidebar's words come only from this table (checkpoint 3)
        XCTAssertEqual(MacSidebar.topLevel.filter { $0.reader == nil },
                       [.shelf, .inventory, .documents, .printableReferences],
                       "the app's own screens: every other top-level row reloads its page when picked again")
        XCTAssertFalse(MacSidebar.topLevel.contains(library), "a collection opens from the Library's lists")
        XCTAssertNil(MacSidebar.title(library), "a collection carries its own name")
        XCTAssertEqual(InventoryLook.title("Medical references and manuals"), "Medical References and Manuals")
        XCTAssertEqual(MacSidebar.shelfOpenKey, "prepareme.mac.librariesOpen", "the old section's fold, kept")
        XCTAssertEqual(MacSidebar.guidesOpenKey, "prepareme.mac.guidesOpen")
        XCTAssertTrue(MacSidebar.guidesOpenAtStart, "Guides starts open (mockup 6), then stays as the owner leaves it")
    }

    /// Go › Library Collections (R6.3, B2-24; Window › Other libraries at first): the libraries the Mac holds besides the daily one, by title.
    func testOtherLibrariesAreTheHeldLibrariesBesideTheDailyOneByTitle() {
        func held(_ name: String, kind: String = "library", title: String? = nil) -> HeldFile {
            let entry = Manifest.Entry(name: name, id: "0F1E2D3C-4B5A-4968-8776-6554433221B1", kind: kind, size: 1,
                                       sha256: "a", deliveredAt: "2026-10-20T00:00:00Z", title: title)
            return HeldFile(entry: entry, file: name)
        }
        let files = ["prepareme-daily.zim": held("prepareme-daily.zim"),
                     "prepareme-vehicles.zim": held("prepareme-vehicles.zim"),
                     "prepareme-reference.zim": held("prepareme-reference.zim"),
                     "prepareme-maps.zim": held("prepareme-maps.zim", kind: "map", title: "A map"),
                     "wikipedia_en_100.zim": held("wikipedia_en_100.zim", kind: "download", title: "Wikipedia 100"),
                     MacLibraries.gamesFile: held(MacLibraries.gamesFile)]
        let others = MacLibraries.others(files, dailyFile: "prepareme-daily.zim")
        XCTAssertEqual(others.map(\.title), ["Medical references and manuals", "Vehicle manuals", "Wikipedia 100"],
                       "the plain names (HomeMacWords.title), never a file name: only a catalog download has a title; "
                       + "a download is listed too, its only way open on the Mac (owner's check, 2026-10-25); "
                       + "the games file isn't: it has its own Games row and side (games plan phase 4)")
        let named = MacLibraries.others(files, dailyFile: "prepareme-daily.zim") { _ in "Reader's name" }
        XCTAssertEqual(named.map(\.title), ["Reader's name", "Reader's name", "Reader's name"], "the phone passes Kiwix's own name")
        XCTAssertEqual(MacLibraries.menuTitle, "Library", "the Library screen and the phone's ••• menu (owner, 2026-11-12)")
        XCTAssertTrue(MacLibraries.others([:], dailyFile: "prepareme-daily.zim").isEmpty)
        XCTAssertEqual(MacLibraries.gamesFile, "prepareme-games.zim", "packer/volumes.toml's prepareme-games")
        XCTAssertEqual(MacRow.games.reader, .guides, "its front page opens in the Guides reader, as a collection's")
        XCTAssertNil(MacRow.games.page(newPage: "new.html"), "no page beside the daily front page")
    }

    /// A kept Library row whose category has gone (removed or renamed away) opens the Library's list instead
    /// (Library plan, Review Focus 5); any other row stands.
    func testAKeptCategoryRowFallsBackToTheLibrary() {
        XCTAssertEqual(MacSidebar.restore(.shelfCategory(id: "gone"), shelf: .starting), .shelf)
        XCTAssertEqual(MacSidebar.restore(.shelfCategory(id: "medical"), shelf: .starting), .shelfCategory(id: "medical"))
        XCTAssertEqual(MacSidebar.restore(.today, shelf: .starting), .today)
    }

    /// Library redesign plan 4.2 (Review Focus 4): a kept subcategory row stands while it's there, opens the Library's
    /// list once it's gone, its category deleted with it included; a subcategory's row opens its category's page.
    func testKeptSubRowGoneFallsBack() throws {
        let (one, books) = try XCTUnwrap(LibraryShelf.starting.adding(name: "Books", emoji: "📖"))
        let (shelf, sub) = try XCTUnwrap(one.addingSub(name: "Homesteading", to: books))
        XCTAssertEqual(MacSidebar.restore(.shelfCategory(id: sub), shelf: shelf), .shelfCategory(id: sub))
        let gone = try XCTUnwrap(shelf.removing(id: books, movingFilesTo: "reference", keys: []))
        XCTAssertEqual(MacSidebar.restore(.shelfCategory(id: sub), shelf: gone), .shelf)
        XCTAssertEqual(MacSidebar.restore(.shelfCategory(id: books), shelf: gone), .shelf)
        XCTAssertEqual(shelf.top(of: sub), books)
        XCTAssertEqual(shelf.top(of: books), books)
    }

    /// Phase 4 review: the unfolded categories are kept one id per line, since an id keeps a name's commas
    /// ("Food, Water" is `food,-water`), which a comma-joined list split in two.
    func testShelfFoldsKeepAnIDWithACommaWhole() {
        let kept = MacSidebar.shelfFolds(["food,-water", "books"])
        XCTAssertEqual(MacSidebar.shelfFolds(kept), ["food,-water", "books"])
        XCTAssertFalse(MacSidebar.shelfFolds(kept).contains("food"))
        XCTAssertEqual(MacSidebar.shelfFolds(""), [])
    }
}
