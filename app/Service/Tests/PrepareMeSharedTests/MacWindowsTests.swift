import Foundation
import XCTest
@testable import PrepareMeShared

/// Look 3 phase 6, the Mac's windows (spec section 5; plan Tasks 6.1 to 6.3): each change held where it was made, by
/// reading the screen's source, the project's way to pin app-target changes (`PaletteTests`, `PhoneCommandsTests`).
final class MacWindowsTests: XCTestCase {
    static let app = PaletteTests.repo.appendingPathComponent("app/Kiwix")

    func file(_ path: String) throws -> String {
        try String(contentsOf: Self.app.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text from `start` up to the next `end` after it.
    func part(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex)
        else { XCTFail("\(start) wasn't found"); return "" }
        return String(text[a.lowerBound..<b.lowerBound])
    }

    /// Code without its `//` comments.
    func code(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    /// Task 6.1: the sidebar in the band color with its contour lines and the PrepareMe wordmark in the book typeface
    /// (phase 0's variant 1: the band behind the sidebar's list, the list drawn dark so its words read).
    func testTheSidebarIsTheBand() throws {
        let look = code(try file("PrepareMeApp/PrepareMeLook.swift"))
        let sidebar = part(look, from: "func pmMacSidebar()", to: "\n    }\n")
        XCTAssertTrue(sidebar.contains("scrollContentBackground(.hidden)"), "the sidebar's own ground still shows")
        XCTAssertTrue(sidebar.contains("PMBandGround("), "the sidebar isn't the band")
        XCTAssertTrue(sidebar.contains("environment(\\.colorScheme, .dark)"), "the sidebar's words aren't drawn light")
        XCTAssertTrue(sidebar.contains("PMWordmark()"), "no wordmark over the sidebar")
        let mark = part(look, from: "struct PMWordmark", to: "\n}\n")
        XCTAssertTrue(mark.contains("Text(\"PrepareMe\")") && mark.contains(".pmTitle"), "the wordmark isn't PrepareMe in pmTitle")
        XCTAssertTrue(mark.contains(".isHeader"), "the wordmark isn't a heading to VoiceOver")
        let root = code(try file("App/RootView_macOS.swift"))
        XCTAssertTrue(part(root, from: "PrepareMeMacSidebar()", to: "#else").contains(".pmMacSidebar()"),
                      "the main window's sidebar doesn't take the band")
    }

    /// Task 6.1: the window's top in the band color, its title and buttons drawn light on it (phase 0: the toolbar takes
    /// a flat color, and the title read dark on teal, 1.33:1, until the window's top was given the dark look), on every
    /// PrepareMe window: the main one, Settings, Add to Library and Bookmarks.
    func testTheWindowTopIsTheBand() throws {
        let look = code(try file("PrepareMeApp/PrepareMeLook.swift"))
        let band = part(look, from: "func pmMacBand()", to: "\n    }\n")
        XCTAssertTrue(band.contains("toolbarBackground(PrepareMeColors.band, for: .windowToolbar)"), "no band at the top")
        XCTAssertTrue(band.contains("toolbarBackgroundVisibility(.visible, for: .windowToolbar)"), "the band can hide")
        XCTAssertTrue(band.contains("PMDarkTitlebar()"), "the title and buttons stay dark on the band")
        XCTAssertTrue(look.contains("NSAppearance(named: .darkAqua)"), "the window's top isn't given the dark look")
        let root = code(try file("App/RootView_macOS.swift"))
        XCTAssertTrue(part(root, from: ".modifier(LibrarySetupOnce())", to: "#endif").contains(".pmMacBand()"),
                      "the main window's top isn't the band")
        let app = code(try file("App/App_macOS.swift"))
        for scene in ["Settings {", "Window(\"Add to Library\"", "Window(\"Bookmarks\""] {
            XCTAssertTrue(part(app, from: scene, to: ".handlesExternalEvents").contains(".pmMacBand()"),
                          "\(scene): its top isn't the band")
        }
    }

    /// Task 6.1: each screen's title in the band: the app's own screens name themselves in the window's title, in the
    /// sidebar's words (Inventory names its own view), and Maps' switch sits in the band as the phone's does (spec section 4).
    func testEachScreensTitleIsInTheBand() throws {
        let root = code(try file("App/RootView_macOS.swift"))
        let screens = part(root, from: "[.householdPages, .documents, .printableReferences]", to: "#else")
        XCTAssertTrue(screens.contains(".navigationTitle(MacSidebar.title(macTabs.row)"),
                      "Edit Household Pages, Essential Documents and Printable References name nothing in the band")
        let maps = part(code(try file("PrepareMeApp/PrepareMeMacSidebar.swift")), from: "struct PrepareMeMacMaps",
                        to: "struct PrepareMeAttentionBar")
        XCTAssertTrue(maps.contains("ToolbarItem(placement: .principal)"), "Maps' switch isn't in the band")
        XCTAssertFalse(maps.contains(".background(.bar)"), "Maps' switch still sits on a row of its own")
    }

    /// Task 6.2, moved by the inventory fresh look's phase 3 (spec 5.1): the counts (items, to buy, expiring soon, days
    /// of water and of food, the supplies' in the phones' words, `InventoryHome.chip`) and the Not counted row sit on
    /// Inventory's home page, never over every table; the category chips and the gray list column are gone, and only
    /// Inventory leaves `ListColumnSplit` (Our Home's editor and the street map keep it).
    func testInventoryHasItsCountsOnTheHomePage() throws {
        let inventory = code(try file("PrepareMeApp/PrepareMeInventory.swift"))
        let homeFile = code(try file("PrepareMeApp/PrepareMeInventoryHome.swift"))
        let home = part(homeFile, from: "struct PrepareMeInventoryHome", to: "\n}\n")
        XCTAssertTrue(home.contains("InventoryCounts(") && home.contains("InventoryNotCounted("),
                      "no counts or Not counted row on the home page")
        let detail = part(inventory, from: "struct InventoryDetail", to: "extension InventoryDetail")
        XCTAssertFalse(detail.contains("InventoryCounts("), "the counts are still over the table")
        let counts = part(homeFile, from: "struct InventoryCounts", to: "\n}\n")
        for words in ["\"All Items\"", "\"To Buy\"", "\"Expiring Soon\"", "InventoryHome.chip(kind:"] {
            XCTAssertTrue(counts.contains(words), "the counts have no \(words)")
        }
        XCTAssertTrue(counts.contains("\"water\"") && counts.contains("\"food\""), "no days of water or food")
        XCTAssertEqual(counts.components(separatedBy: "PMCount(").count - 1, 4,
                       "three counts and one PMCount for each supply (water, food): five on the page")
        XCTAssertTrue(counts.contains("requestedPick ="), "a count opens nothing")
        for gone in ["InventoryChips", "InventorySidebar", "ListColumnSplit"] {
            XCTAssertFalse(inventory.contains(gone) || homeFile.contains(gone), "\(gone) is still on Inventory")
        }
        for keeps in ["PrepareMeApp/PrepareMeHouseholdPages.swift", "PrepareMeApp/PrepareMeStreetMapMac.swift"] {
            XCTAssertTrue(code(try file(keeps)).contains("ListColumnSplit {"), "\(keeps) lost its list column")
        }
    }

    /// Task 6.2: Essential Documents' locked and empty screens in the one shared look (spec section 10, rule 1), and a
    /// document's buttons in the band.
    func testDocumentsTakeTheSharedLookAndTheBand() throws {
        let documents = code(try file("PrepareMeApp/PrepareMeDocuments.swift"))
        for screen in ["struct DocumentsLocked", "struct DocumentsEmpty"] {
            XCTAssertTrue(part(documents, from: screen, to: "\n}\n").contains("PMState("), "\(screen): its own look")
        }
        let viewer = part(documents, from: "struct DocumentViewer", to: "@ViewBuilder private var content")
        XCTAssertTrue(viewer.contains(".toolbar {"), "a document's buttons sit on a row of their own")
        XCTAssertFalse(viewer.contains("Divider()"), "the old button row is still drawn")
    }

    /// Task 6.2: Printable References' switch and buttons in the band, the card's form and its picture left as they are.
    func testPrintableReferencesButtonsInTheBand() throws {
        let printable = code(try file("PrepareMeApp/PrepareMePrintableReferences.swift"))
        let view = part(printable, from: "struct PrepareMePrintableReferencesView", to: "private var statusLine")
        XCTAssertTrue(view.contains(".toolbar {") && view.contains("ToolbarItem(placement: .principal)"),
                      "the card | binder switch isn't in the band")
        XCTAssertFalse(part(view, from: "var body", to: ".padding(.horizontal, 22)").contains("header"),
                       "the old header row is still drawn")
    }

    /// Task 6.2: the household page editor's steps as the drawing's step cards: the number in the rounded typeface on
    /// the teal fill (the tint, so red night's ink reaches it).
    func testTheEditorsStepsAreCards() throws {
        let editor = code(try file("PrepareMeApp/PrepareMeHouseholdPages.swift"))
        let step = part(editor, from: "func step(_ n: Int", to: "VStack(alignment: .leading, spacing: 6)")
        XCTAssertTrue(step.contains(".font(.pmStepNumber)"), "the step's number isn't rounded")
        XCTAssertTrue(step.contains("Circle().fill(.tint)") && step.contains("PrepareMeColors.onTeal"),
                      "the step's number isn't on the teal")
    }

    /// The warnings at the sidebar's bottom, folded, with their count (owner, 2026-11-13: out of the bar across the
    /// window's top), in look 3's amber (spec section 10, rule 4); nothing pads a screen for a top bar any more.
    func testTheWarningsAreFoldedAtTheSidebarsBottom() throws {
        let sidebar = code(try file("PrepareMeApp/PrepareMeMacSidebar.swift"))
        let box = part(sidebar, from: "struct PrepareMeAttentionBar", to: "struct ListColumnSplit")
        XCTAssertTrue(box.contains("DisclosureGroup(isExpanded: $open)"), "the warnings don't fold")
        XCTAssertTrue(box.contains("@State private var open = false"), "the warnings start open")
        XCTAssertTrue(box.contains("\\(all.count)") && box.contains("Needs attention"), "closed, it doesn't say how many")
        XCTAssertTrue(box.contains("PrepareMeColors.accentBg") && box.contains("Open Settings…"), "the box lost its look or button")
        let root = code(try file("App/RootView_macOS.swift"))
        XCTAssertTrue(part(root, from: ".pmMacSidebar()", to: "#else")
            .contains(".safeAreaInset(edge: .bottom, spacing: 0) { PrepareMeAttentionBar() }"), "not at the sidebar's bottom")
        XCTAssertFalse(root.contains("AttentionBarAbove"), "the bar is still across the window's top")
        XCTAssertFalse(code(try file("PrepareMeApp/PrepareMeInventory.swift")).contains("barHeight"),
                       "Inventory still makes room for a top bar")
    }

    /// Task 6.3: the Event mode row shows grayed with a line saying why until the lists are read (spec section 9), the
    /// words here so this test holds them.
    func testTheEventModeRowWaitsGrayed() throws {
        XCTAssertEqual(StateWords.eventModeWaiting, "Shows once the lists are read")
        let row = part(code(try file("PrepareMeApp/PrepareMeMacSidebar.swift")), from: "struct PrepareMeMacEventMode",
                       to: "\n}\n")
        XCTAssertTrue(row.contains("} else {") && row.contains("StateWords.eventModeWaiting"),
                      "the row is missing until the lists are read")
        XCTAssertTrue(row.contains("PrepareMeColors.text2"), "the waiting row isn't grayed")
        // red night's red layer takes gray to 3.34:1 (phase 6's capture): there the line is ink, as the tint is
        XCTAssertTrue(row.contains("redNight.on ? PrepareMeColors.ink : PrepareMeColors.text2"),
                      "the waiting row stays gray under red night")
    }

    /// Task 6.3: the "no inventory yet" message in plain words (spec section 10, rule 6): no Grist, move day or file name.
    func testNoInventoryYetIsPlainWords() throws {
        let words = StateWords.noInventoryYet
        for old in ["Grist", "move day", ".md", "docs/"] {
            XCTAssertFalse(words.contains(old), "the message still says \(old)")
        }
        let missing = part(code(try file("PrepareMeApp/PrepareMeInventory.swift")), from: "struct InventoryMissing",
                           to: "\n}\n")
        XCTAssertTrue(missing.contains("StateWords.noInventoryYet"), "the screen keeps its own words")
    }

    /// Task 6.3, accessibility fix 7 (spec section 9, item 7): To-do, Upkeep and Targets rows get an Edit… button the
    /// keyboard reaches, Delete beside it where the row can go (Remove until 2026-11-13), as the right-click menu has them.
    func testListRowsHaveAnEditButton() throws {
        let lists = code(try file("PrepareMeApp/PrepareMeLists.swift"))
        let buttons = part(lists, from: "@ViewBuilder var buttons", to: "\n    }\n")
        XCTAssertTrue(buttons.contains("hasForm") && buttons.contains("\"Edit…\""), "no Edit… button on the rows")
        XCTAssertTrue(buttons.contains("\"Delete\""), "Delete has no button")
    }

    /// Task 6.3, accessibility fix 12: the street map's trash button has a spoken name.
    func testTheTrashButtonHasAName() throws {
        let map = code(try file("PrepareMeApp/PrepareMeStreetMapMac.swift"))
        let trash = part(map, from: "Image(systemName: \"trash\")", to: ".help(\"Delete")
        XCTAssertTrue(trash.contains(".accessibilityLabel(\"Delete\")"), "VoiceOver reads the trash button as a picture")
    }

    /// Phase 6 review: the window's top keeps the dark look in full screen, where macOS moves the toolbar into a title
    /// bar of its own (set once, it read dark on teal there, 1.33:1).
    func testTheDarkTitleBarHoldsInFullScreen() throws {
        let look = code(try file("PrepareMeApp/PrepareMeLook.swift"))
        let bar = part(look, from: "struct PMDarkTitlebar", to: "\n}\n")
        XCTAssertTrue(bar.contains("didEnterFullScreenNotification") && bar.contains("didExitFullScreenNotification"),
                      "the dark look isn't set again in full screen")
    }

    /// Phase 6 review: a count that opens something and a home page tile (the chips' successor, phase 3) answer a
    /// click anywhere on them, not only on their words.
    func testCountsAndChipsTakeClicksAnywhere() throws {
        let look = code(try file("PrepareMeApp/PrepareMeLook.swift"))
        XCTAssertTrue(part(look, from: "struct PMCount", to: "\n}\n").contains(".contentShape("),
                      "a count's empty area takes no click")
        let home = code(try file("PrepareMeApp/PrepareMeInventoryHome.swift"))
        let counts = part(home, from: "struct InventoryCounts", to: "\n}\n")
        XCTAssertFalse(counts.contains("            .padding(10)\n            .background(PrepareMeColors.panel"),
                       "the tile's padding and panel sit outside its button")
        XCTAssertTrue(part(home, from: "func tile(", to: "\n    }\n").contains(".contentShape("),
                      "a home page tile's empty area takes no click")
    }

    /// Phase 3, fix round 1 (finding 12): the Inventory menu dims each item by its own rule in `InventoryCommands`,
    /// the toolbar's too, so the home page's Export CSV… and Remove Empty Places… (the owner's choice A) work there.
    func testInventoryMenuDimsEachItemByItsRule() throws {
        let menu = part(code(try file("PrepareMeApp/PrepareMeInventory.swift")), from: "CommandMenu(\"Inventory\")",
                        to: "\n    }\n")
        for (item, rule) in [("inventory?.editTable()", "canEditTable"), ("Reset Columns", "canChooseColumns"),
                             ("inventory?.exportCSV()", "canExportCSV"),
                             ("inventory?.removeEmptyPlaces()", "canRemoveEmptyPlaces"),
                             ("inventory?.openForm()", "canOpenForm"), ("inventory?.delete()", "canDelete"),
                             ("inventory?.printBlankSheet()", "canPrintBlankSheet"),
                             ("inventory?.printGrabSheets()", "canPrintGrabSheets"),
                             ("inventory?.addByBarcode()", "canAddByBarcode")] {
            guard let at = menu.range(of: item) else { XCTFail("no \(item) in the menu"); continue }
            XCTAssertTrue(menu[at.upperBound...].prefix(200).contains(".disabled(state?.\(rule) != true)"),
                          "\(item) isn't dimmed by \(rule)")
        }
        XCTAssertFalse(menu.contains("tableShown"), "one rule for four items again")
        let home = part(code(try file("PrepareMeApp/PrepareMeInventoryHome.swift")), from: "struct PrepareMeInventoryHome",
                        to: "\n}\n")
        XCTAssertTrue(home.contains("exportCSV: { InventoryDetail.exportCSV(inventory) }"), "Export CSV… does nothing there")
        XCTAssertTrue(home.contains("removeEmptyPlaces: { removingEmpty = true }") && home.contains("EmptyPlacesSheet("),
                      "Remove Empty Places… does nothing there")
    }

    /// Phase 3, fix round 1 (finding 3, the old chip test's successor): the picked bin is marked by its outline and
    /// its trait as well as its color, in the tint (red night turns every tint to ink: teal is 1.6:1 on black there),
    /// and a click anywhere on its capsule counts; the home page's edit links take the tint too.
    func testPickedBinIsMarkedBeyondColorAndTakesClicks() throws {
        let inventory = code(try file("PrepareMeApp/PrepareMeInventory.swift"))
        let bins = part(inventory, from: "func binsRow(", to: "\n    }\n")
        for needed in [".accessibilityAddTraits(on ? .isSelected : [])", ".strokeBorder(", ".contentShape(Capsule())",
                       ".foregroundStyle(on ? AnyShapeStyle(.tint)"] {
            XCTAssertTrue(bins.contains(needed), "the bins row has no \(needed)")
        }
        XCTAssertFalse([")", ",", " "].contains { bins.contains("PrepareMeColors.teal" + $0) },
                       "teal, too dim on the red night screen (its tint, the picked fill, stays)")
        let home = code(try file("PrepareMeApp/PrepareMeInventoryHome.swift"))
        let heading = part(home, from: "func heading(", to: "\n    }\n")
        XCTAssertTrue(heading.contains(".foregroundStyle(.tint)"), "Edit Categories and Edit Locations aren't the tint")
        XCTAssertFalse(home.contains("PrepareMeColors.teal)"), "teal words on the home page")
    }

    /// Phase 3, fix round 1 (finding 1): Inventory's pane goes by the shared rule (`MacInventoryPage`), and an item a
    /// search hid is shown by clearing the search through it, never by emptying the box under the table.
    func testInventoryGoesByTheSharedPage() throws {
        let inventory = code(try file("PrepareMeApp/PrepareMeInventory.swift"))
        let view = part(inventory, from: "struct PrepareMeInventoryView", to: "\n}\n")
        for needed in ["MacInventoryPage", "page.shown(on: row)", "page.take(", "page.goHome()", "page.moved(to:",
                       "page.showsBack(on: row)", "page.clearSearch(on: row)"] {
            XCTAssertTrue(view.contains(needed), "the view doesn't use \(needed)")
        }
        let show = part(inventory, from: "    func show(_ id: Int64) {", to: "\n    }\n")
        XCTAssertTrue(show.contains("clearSearch()") && !show.contains("search = \"\""),
                      "Add after a home page search drops the table for the home page")
    }

    /// Phase 3, fix round 2 (findings 1 to 3): the toolbar's words come and go through one label style taking a true or
    /// false, never a builder swapping views (a swapped toolbar could take the cursor from the search box after one
    /// letter); the switch reads watched state, so it's right at first draw and on a resize; the bare lock has a tip.
    func testToolbarWordsGoWithoutReplacingAView() throws {
        let inventory = code(try file("PrepareMeApp/PrepareMeInventory.swift"))
        XCTAssertTrue(inventory.contains("struct PMBarLabelStyle: LabelStyle"), "no one label style for the toolbar")
        let bar = part(inventory, from: "func pmBarLabel(", to: "\n    }\n")
        XCTAssertTrue(bar.contains("labelStyle(PMBarLabelStyle(titleShown: !compact))"), "pmBarLabel doesn't use it")
        XCTAssertFalse(bar.contains("if compact") || inventory.contains("@ViewBuilder func pmBarLabel"),
                       "pmBarLabel swaps one view for another")
        let compact = part(inventory, from: "var compactBar: Bool {", to: "}")
        XCTAssertTrue(compact.contains("!tableWide"), "compactBar doesn't read the watched width")
        XCTAssertFalse(compact.contains("liveWidth"), "compactBar reads a width SwiftUI doesn't watch")
        XCTAssertTrue(inventory.contains("@State private var tableWide"), "the table's width isn't watched state")
        let sign = part(inventory, from: "private struct LockedSign: View {", to: "\n}\n")
        XCTAssertTrue(sign.contains(".help(words)"), "the bare lock has no tip")
    }
}
