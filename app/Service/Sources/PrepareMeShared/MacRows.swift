import Foundation

/// The Mac sidebar's rows (Mac sidebar plan, part 2): Today, Guides with its New and category rows, Maps, Inventory
/// and News, like the iPhone's tabs. Kept here, apart from the app, so `swift test` holds which reader and which page
/// each row opens, and how a link inside a page picks its row.
public enum MacRow: Hashable, Codable, Sendable {
    case today, guides, new, category(page: String), sub(page: String, anchor: String), maps, inventory
    case householdPages  // the household's own step-by-step pages (concept-doc plan, phase C): the app's own screen
    case news  // the News page (step 7; R6.1, 2026-10-20: its own sidebar row under Inventory, no longer inside Guides)
    case printableReferences  // the Family Emergency Card and the Essential Guides Binder (2026-10-21): the app's own
    case documents  // Essential Documents (2026-10-24, docs/documents.md): the app's own screen, locked
    case library(id: UUID)  // a collection besides the daily library, its front page (owner, 2026-10-25)
    /// The Library (owner, 2026-11-12; docs/plans/2026-11-12-library-section.md): its list of every category, New,
    /// one category (a `LibraryShelf.Category` id) and Needs a category. The app's own screens.
    case shelf, shelfNew, shelfCategory(id: String), shelfUnsorted
    /// The games file's front page (games plan phase 4, owner 2026-11-14): its own row under the Library, shown while
    /// the Mac holds the file (`MacLibraries.gamesFile`), which the Library's lists leave out.
    case games
    /// One of the five rows under Inventory (the inventory fresh look, phase 3; spec 5.1): the app's own screen, as
    /// Inventory, showing that list.
    case inventoryList(MacInventoryList)

    /// The reader a row opens: Today's page, the guides library (Guides, New and the category rows) or the maps
    /// library. Inventory has none: it is the app's own screen.
    public enum Reader: String, Codable, Sendable { case today, guides, maps }

    public var reader: Reader? {
        switch self {
        case .today: return .today
        case .guides, .news, .new, .category, .sub, .library, .games: return .guides
        case .maps: return .maps
        case .inventory, .householdPages, .printableReferences, .documents: return nil
        case .shelf, .shelfNew, .shelfCategory, .shelfUnsorted, .inventoryList: return nil
        }
    }

    /// The page a row shows in its reader: Guides' own list, the News page, the New page (named by the caller, `GuideTopics.newPage`),
    /// a category's page, or a sub-category's page at its anchor. Today, Maps and Inventory open no one page.
    public func page(newPage: String) -> String? {
        switch self {
        case .guides: return "guides.html"
        case .news: return "news-board.html"  // packer/build.py's NEWS_BOARD_PAGE (news plan phase 3)
        case .new: return newPage
        case let .category(page): return page
        case let .sub(page, anchor): return "\(page)#\(anchor)"
        case .today, .maps, .inventory, .householdPages, .printableReferences, .documents, .library, .games: return nil
        case .shelf, .shelfNew, .shelfCategory, .shelfUnsorted, .inventoryList: return nil
        }
    }

    /// A page of the daily library beside its front page `main`, as the phone's Guides tab finds guides.html, with a
    /// sub-category's anchor kept as the address's fragment (never escaped into its path). Kiwix's addresses are
    /// relative to the library's (`URL(zimFileID:contentPath:)`), so the address is resolved whole before the fragment
    /// goes on: unresolved, it lost the library and every sub-category row failed to load (seen on screen, 2026-10-16).
    public static func address(_ page: String, beside main: URL) -> URL {
        let parts = page.split(separator: "#", maxSplits: 1).map(String.init)
        let url = main.deletingLastPathComponent().appendingPathComponent(parts[0]).absoluteURL
        guard parts.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url
        }
        components.fragment = parts[1]
        return components.url ?? url
    }

    /// The row a followed link belongs to: a link into a map file is Maps, any other is Guides.
    public static func forLink(isMapFile: Bool) -> MacRow {
        isMapFile ? .maps : .guides
    }

    /// packer/inventory_page.py's INVENTORY_PAGE: the library's Inventory page, laid out at a phone's width.
    public static let inventoryPage = "inventory.html"

    /// Whether `url` is any library's Inventory page, which the Mac opens as its own Inventory screen instead (owner,
    /// 2026-10-28: Today's Inventory button showed the phone page narrow in the window).
    public static func isInventoryPage(_ url: URL) -> Bool {
        url.scheme == "zim" && url.lastPathComponent == inventoryPage
    }
}

/// The lists under Inventory in the Mac's sidebar, in their order (the inventory fresh look, phase 3; spec 5.1).
public enum MacInventoryList: String, Codable, CaseIterable, Sendable {
    case all, toBuy, expiringSoon, toDo, upkeep

    /// The list the row shows.
    public var pick: InventoryPick {
        switch self {
        case .all: .table("Inventory")
        case .toBuy: .toBuy
        case .expiringSoon: .view(.expiringSoon)
        case .toDo: .list(ListsLayout.todo)
        case .upkeep: .list(ListsLayout.upkeep)
        }
    }

    /// The sidebar row a pick is shown under: one of the five for its list, else Inventory itself (its home page's
    /// tiles and buttons, a guide's In the house, Show Them). A tile's table is never remembered between launches.
    public static func row(for pick: InventoryPick) -> MacRow {
        allCases.first { $0.pick == pick }.map(MacRow.inventoryList) ?? .inventory
    }
}

/// What the Mac's Inventory shows (moved here from the app in the inventory fresh look's phase 3, so `swift test` holds
/// which row shows which): a table, a view of the items, To Buy, or one of the lists' sheets (PrepareMeLists.swift).
public enum InventoryPick: Hashable, Sendable {
    case table(String)
    case view(Inventory.View)
    case toBuy
    case list(String)  // plan phase 7, part 2: a sheet of the lists
}

/// What Inventory's pane shows (the inventory fresh look, phase 3; fix round 1, finding 1): the sidebar's row,
/// Inventory's own pick and the one search box together, so each move is tested here, not only on screen.
public struct MacInventoryPage: Equatable, Sendable {
    /// On Inventory's own row: a tile's, an edit link's or a list button's table; nil is the home page.
    public var pick: InventoryPick?
    /// The one search box, the home page's and the tables', so typing keeps its place as the page changes.
    public var search: String

    public init(pick: InventoryPick? = nil, search: String = "") {
        self.pick = pick
        self.search = search
    }

    /// A list row's own list; on Inventory's row the pick, or All Items while the home page's search has words
    /// (spec 5.1: the whole inventory searched from the home page); nil for the home page.
    public func shown(on row: MacRow) -> InventoryPick? {
        if case .inventoryList(let list) = row { return list.pick }
        return pick ?? (search.isEmpty ? nil : .table("Inventory"))
    }

    /// The back button, home: on Inventory's row over a tile's table or a home page search's All Items.
    public func showsBack(on row: MacRow) -> Bool { row == .inventory && shown(on: row) != nil }

    /// Inventory's row clicked while it shows, or the back button: the home page, its search box empty.
    public mutating func goHome() {
        pick = nil
        search = ""
    }

    /// A pick asked for from elsewhere (Today's counts, a guide's In the house, Show Them, Go to that item): kept as
    /// Inventory's own pick when it belongs there; the row it belongs under is returned, for the sidebar to pick.
    public mutating func take(_ asked: InventoryPick) -> MacRow {
        let target = MacInventoryList.row(for: asked)
        pick = target == .inventory ? asked : nil
        return target
    }

    /// The sidebar moved to `now`: leaving Inventory's row drops its pick, so a click on Inventory shows the home page
    /// again; coming to it with no tile open drops a list row's search words, which would show All Items there.
    public mutating func moved(to now: MacRow) {
        if now != .inventory {
            pick = nil
        } else if pick == nil {
            search = ""
        }
    }

    /// The search cleared to show an item it hid (Add, Go to that item). A home page search's All Items would turn
    /// back into the home page, taking the table and its open form with it, so All Items moves to its own row, where it
    /// shows with no search: that row is returned, for the sidebar to pick in the same moment. Nil: the row stays.
    public mutating func clearSearch(on row: MacRow) -> MacRow? {
        let moving = row == .inventory && pick == nil && !search.isEmpty
        search = ""
        return moving ? .inventoryList(.all) : nil
    }
}

/// The sidebar's order and words (R6.1; the owner's requests, 2026-10-20, and mockup 6): Today, one Guides row (its
/// click opens the guide list, its arrow shows New and then the categories), Maps, Inventory, News under it as a row
/// of its own, and Printable References (the owner's name, 2026-10-21, kept as typed). The
/// Categories folder row is gone; the Mac's Today has no News link (this row is the way in; the phone's and iPad's
/// Today end with one). Essential Documents sits right under Inventory (2026-10-24; Apple: important rows not at a
/// sidebar's foot). Under them, a section of the other libraries the Mac holds, one row each (owner, 2026-10-25, by
/// click: "a category for downloads that aren't guides", in place of only Window › Other libraries). The household
/// pages' editor left the sidebar for the Library menu (owner, 2026-10-26), then File (owner, 2026-11-14).
public enum MacSidebar {
    public static let topLevel: [MacRow] = [.today, .guides, .shelf, .games, .maps, .inventory, .documents, .news,
                                            .printableReferences]

    /// The Our Home pages' editor: its heading, its toolbar title and File's item (Our Home phase 1, owner 2026-11-16, by
    /// click; "Edit household pages" until then).
    public static let editHouseholdPages = "Edit Our Home"
    public static let printableReferences = "Printable References"

    /// The row's words; nil for the rows inside Guides (the category rows carry the list's own names).
    public static func title(_ row: MacRow) -> String? {
        switch row {
        case .today: return "Today"
        case .guides: return "Guides"
        case .maps: return "Maps"
        case .inventory: return "Inventory"
        case .news: return "News"
        case .householdPages: return editHouseholdPages
        case .printableReferences: return printableReferences
        case .documents: return DocumentsWords.title
        case .new, .shelfNew: return "New"
        case .shelf: return MacLibraries.menuTitle
        case .games: return MacLibraries.gamesTitle
        case .shelfUnsorted: return "Needs a category"
        case .inventoryList(let list):
            switch list {
            case .all: return "All Items"
            case .toBuy: return "To Buy"
            case .expiringSoon: return "Expiring Soon"
            case .toDo: return "To Do"
            case .upkeep: return "Upkeep"
            }
        case .category, .sub, .library, .shelfCategory: return nil
        }
    }

    /// The Go menu's key for a sidebar row (menu bar plan, owner 2026-11-14): "1" to "9" by its place in `rows`; none
    /// for a row that isn't there or sits past the ninth, so a tenth row shows without a key.
    public static func goKey(_ row: MacRow, in rows: [MacRow] = topLevel) -> Character? {
        guard let at = rows.firstIndex(of: row), at < 9 else { return nil }
        return Character(String(at + 1))
    }

    /// What Guides' arrow shows: New, then each category (by its page, in the list's order).
    public static func insideGuides(pages: [String]) -> [MacRow] {
        [.new] + pages.map { MacRow.category(page: $0) }
    }

    /// Whether Guides is unfolded, remembered as the owner leaves it (`@AppStorage`); open on the first launch.
    public static let guidesOpenKey = "prepareme.mac.guidesOpen"
    public static let guidesOpenAtStart = true

    /// Whether Inventory is unfolded to its five rows (the inventory fresh look, phase 3), as the owner leaves it.
    public static let inventoryOpenKey = "prepareme.mac.inventoryOpen"
    /// The rows inside Inventory's fold, in order: none is in `topLevel`, so ⌘6 stays Inventory.
    public static let inventoryRows: [MacRow] = MacInventoryList.allCases.map(MacRow.inventoryList)

    /// Whether the Library is unfolded (the old Other libraries section's key, kept); open on the first launch.
    public static let shelfOpenKey = "prepareme.mac.librariesOpen"
    /// The Library's categories unfolded to show their subcategories, by id, one per line (library redesign 4.2; a
    /// line, not a comma, since an id keeps a name's commas: phase 4 review).
    public static let shelfFoldsKey = "prepareme.mac.shelfFolds"

    /// The unfolded ids kept under `shelfFoldsKey`, in order.
    public static func shelfFolds(_ kept: String) -> [String] {
        kept.split(separator: "\n").map(String.init)
    }

    /// The unfolded ids as kept.
    public static func shelfFolds(_ ids: [String]) -> String {
        ids.joined(separator: "\n")
    }

    /// A kept row at launch: a Library category the shelf no longer has opens the Library's list instead.
    public static func restore(_ row: MacRow, shelf: LibraryShelf) -> MacRow {
        if case let .shelfCategory(id) = row, !shelf.categories.contains(where: { $0.id == id }) { return .shelf }
        return row
    }
}

/// PrepareMe's help page (remaining-findings plan, Task 13.3; F48, F60; owner, 2026-10-18, by click): a page in the
/// daily library beside its front page (packer/help_page.py, which pins this path), its words the owner's, reached
/// from the Mac's Help menu, the iPad's, and the phone's Settings.
public enum PrepareMeHelp {
    public static let page = "help.html"
    public static let menuTitle = "PrepareMe Help"
}

/// The libraries besides the daily one (reference, vehicles, video, equipment manuals, and a catalog download): the Mac
/// sidebar's Library section and Go › Library Collections, the phone's Guides | Other libraries switch and its
/// ••• › Other libraries (R6.3; B2-24; owner, 2026-10-25). The What to do now page names them.
public enum MacLibraries {
    public static let menuTitle = "Library"  // owner, 2026-11-12: was "Other libraries"
    /// The Mac's Go menu's list of them (menu bar plan, owner 2026-11-14), so it doesn't sit beside the Library
    /// screen's own item under the same name; the phone's ••• menu keeps `menuTitle`.
    public static let collectionsTitle = "Library Collections"
    /// The games file (packer/volumes.toml's prepareme-games; games plan phase 4): Games on the phone's Guides switch
    /// and in the Mac's sidebar, so the Library's lists leave it out and it shows in one place.
    public static let gamesFile = "prepareme-games.zim"
    public static let gamesTitle = "Games"

    /// The libraries held besides the daily file, by title: `named` (the reader's own name for it, when it has one),
    /// else `HomeMacWords.title` (a catalog title, else the plain name).
    public static func others(_ held: [String: HeldFile], dailyFile: String,
                              named: (UUID) -> String? = { _ in nil }) -> [(id: UUID, title: String)] {
        held.values
            // a catalog download too: this menu is its only way open (owner's check, 2026-10-25)
            .filter { ["library", "download"].contains($0.entry.kind) && ![dailyFile, gamesFile].contains($0.entry.name) }
            .compactMap { file -> (id: UUID, title: String)? in
                guard let id = UUID(uuidString: file.entry.id) else { return nil }
                return (id, named(id) ?? HomeMacWords.title(file.entry))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
