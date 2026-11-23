import Foundation
import XCTest
@testable import PrepareMeShared

/// Look 3 phase 5, the phone's and iPad's commands (spec section 7): each change held where it was made, by reading
/// the screen's source, the project's way to pin app-target changes (`PaletteTests`).
final class PhoneCommandsTests: XCTestCase {
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

    /// Change 4: a link's long-press has no "Open in New Tab"; there are no tabs.
    func testChange4NoOpenInNewTabOnALinkLongPress() throws {
        let model = try file("ViewModel/BrowserViewModel.swift")
        XCTAssertFalse(model.contains("common_dialog_button_open_in_new_tab"), "the long-press still offers a new tab")
        let menu = part(model, from: "// open url", to: "// bookmark")  // the long-press's first two actions
        XCTAssertFalse(menu.contains("inNewTab"), "the long-press still opens a new tab")
    }

    /// Change 5: no External Link or Search snippet in Settings; fixed at ask-each-time and on, the stored choices too.
    func testChange5ExternalLinkAndSnippetAreFixed() throws {
        let plist = try file("PrepareMeApp/Info.plist")
        for key in ["SETTINGS_SHOW_EXTERNAL_LINK_OPTION", "SETTINGS_SHOW_SEARCH_SNIPPET"] {
            let after = try XCTUnwrap(plist.range(of: "<key>\(key)</key>"), "\(key) isn't in Info.plist")
            XCTAssertTrue(plist[after.upperBound...].drop { $0.isWhitespace }.hasPrefix("<false/>"), "\(key) isn't false")
        }
        let launch = part(try file("App/App_iOS.swift"), from: "PrepareMeLibrary.launch()", to: "#endif")
        XCTAssertTrue(launch.contains("Defaults[.externalLinkLoadingPolicy] = .alwaysAsk"), "the stored policy isn't reset")
        XCTAssertTrue(launch.contains("Defaults[.searchResultSnippetMode] = .matches"), "the stored snippet choice isn't reset")
    }

    /// The reading tabs' ••• menu, from its Menu to its label.
    func moreMenu() throws -> String {
        part(try file("PrepareMeApp/PrepareMeTabs.swift"), from: "ContentSearchButton(browser: browser)", to: "Label(\"More\"")
    }

    /// Change 6: "Other libraries" leaves the ••• menu on Guides only, where its switch is on the screen.
    func testChange6OtherLibrariesOutOfTheMenuOnGuides() throws {
        let menu = try moreMenu()
        XCTAssertTrue(menu.contains("Menu(MacLibraries.menuTitle"), "Today and Maps keep the Library menu")
        XCTAssertTrue(menu.contains("tab != .guides"), "Guides' menu still holds Other libraries")
    }


    /// Change 7: "Bookmark this page" leaves the ••• menu; the Bookmarks screen has its own add and remove button.
    func testChange7BookmarkThisPageOutOfTheMenu() throws {
        let tabs = try file("PrepareMeApp/PrepareMeTabs.swift")
        let bar = part(tabs, from: "OutlineButton(browser: browser)", to: "ContentSearchButton(browser: browser)")
        XCTAssertFalse(bar.contains("Bookmark this page"), "the menu still adds a bookmark")
        XCTAssertFalse(bar.contains("Remove bookmark"), "the menu still removes one")
        XCTAssertTrue(bar.contains("Button(\"Bookmarks\""), "the Bookmarks screen has no way in")
        let listing = try file("Views/Buttons/BookmarksListing.swift")
        XCTAssertTrue(listing.contains("createBookmark"), "the Bookmarks screen can't add one")
    }


    /// Change 11: the Diagnostic report moves inside About on the phone, at its foot as on the Mac.
    func testChange11DiagnosticReportInsideAbout() throws {
        XCTAssertFalse(try file("Views/Settings/Settings.swift").contains("\"Diagnostic report\""),
                       "Settings still lists the Diagnostic report")
        let about = try file("Views/Settings/About.swift")
        let phone = part(about, from: "#elseif os(iOS)", to: ".navigationTitle(LocalString.settings_about_title)")
        XCTAssertTrue(phone.contains("NavigationLink(\"Diagnostic report\") { DiagnosticsView() }"),
                      "About has no Diagnostic report on the phone")
    }


    /// Change 13: one Add, the bottom bar's button, on Inventory, Documents, To Buy and To Do; none in a toolbar.
    func testChange13OneAddAtTheBottom() throws {
        XCTAssertTrue(try file("PrepareMeApp/PrepareMeLook.swift").contains("func pmAddBar"), "the shared Add bar is missing")
        for name in ["PhoneInventory", "PhoneDocuments", "PhoneLists"] {
            let text = try file("PrepareMeApp/PrepareMe\(name).swift")
            XCTAssertTrue(text.contains(".pmAddBar"), "\(name) has no bottom Add")
            XCTAssertFalse(text.contains("systemImage: \"plus\") }\n            }\n        }\n        .sheet"), "\(name) keeps a toolbar plus")
        }
        let inv = try file("PrepareMeApp/PrepareMePhoneInventory.swift")
        XCTAssertTrue(inv.contains(".pmAddBar(show: model.canEdit && PhoneSearch.showsNotes(search: search))"), "Inventory's Add shows in a read-only copy or a search")
        XCTAssertEqual(try file("PrepareMeApp/PrepareMePhoneLists.swift").components(separatedBy: ".pmAddBar(show: model.canEdit)").count - 1, 1, "To Do's Add shows to a child")
        XCTAssertTrue(part(inv, from: "struct PhoneToBuyView", to: "struct PhoneOwnItemForm").contains(".pmAddBar(show: model.canEdit)"), "To Buy's Add shows to a child")
        let toBuy = part(try file("PrepareMeApp/PrepareMePhoneInventory.swift"), from: "struct PhoneToBuyView", to: "struct PhoneOwnItemForm")
        XCTAssertTrue(toBuy.contains(".pmAddBar"), "To Buy has no bottom Add")
        XCTAssertFalse(toBuy.contains("Label(\"Add your own\", systemImage: \"plus\") } }\n        }"), "To Buy keeps its top plus")
        let toDo = part(try file("PrepareMeApp/PrepareMePhoneLists.swift"), from: ".navigationTitle(\"To Do\")", to: ".sheet(item: $editing)")
        XCTAssertFalse(toDo.contains(".toolbar"), "To Do keeps its top plus")
        let docs = part(try file("PrepareMeApp/PrepareMePhoneDocuments.swift"), from: ".navigationTitle(model.index.folder", to: ".fullScreenCover")
        XCTAssertFalse(docs.contains("ToolbarItem(placement: .topBarLeading)"), "Documents keeps its top Add")
    }


    /// Change 15: a Lock button on the phone's Essential Documents, on every folder screen, calling the model's lock().
    func testChange15ALockButtonOnDocuments() throws {
        let docs = try file("PrepareMeApp/PrepareMePhoneDocuments.swift")
        let folder = part(docs, from: "private struct PhoneDocumentsFolder", to: "private var footer")
        XCTAssertTrue(folder.contains("Button(\"Lock\", systemImage: \"lock\") { model.lock() }"), "no Lock button")
        XCTAssertTrue(folder.contains(".labelStyle(.titleAndIcon)"), "Lock isn't a labeled button")
    }


    /// Change 16 (with accessibility fix 5): a visible ••• on each folder row and each document row opens the menu
    /// that was long-press only, a target of 44 points, named for its row.
    func testChange16AVisibleMoreOnFolderAndDocumentRows() throws {
        let docs = try file("PrepareMeApp/PrepareMePhoneDocuments.swift")
        let rows = part(docs, from: "ForEach(folders) { item in", to: "if folder == nil {")
        XCTAssertFalse(rows.contains("NavigationLink"), "a row's link wraps its •••: a tap may open the row instead")
        XCTAssertEqual(rows.components(separatedBy: ".buttonStyle(.borderless)").count - 1, 2, "a row's button isn't its own target")
        XCTAssertTrue(rows.contains("PhoneDocumentsFolderMenu(folder: item)"), "folder rows have no menu")
        XCTAssertTrue(rows.contains("PhoneDocumentsRowMenu(document: document)"), "document rows have no menu")
        XCTAssertEqual(rows.components(separatedBy: "PhoneRowMore(").count - 1, 2, "a row has no visible •••")
        let more = part(docs, from: "private struct PhoneRowMore", to: "private struct PhoneDocumentsRowMenu")
        XCTAssertTrue(more.contains("\"ellipsis\""), "the ••• isn't drawn")
        XCTAssertTrue(more.contains(".buttonStyle(.borderless)"), "the ••• isn't its own tap target")
        XCTAssertTrue(more.contains("minWidth: 44") && more.contains("minHeight: 44"), "the ••• is under 44 points")
        XCTAssertTrue(more.contains(".accessibilityLabel(\"More actions for"), "the ••• isn't named for its row")
    }


    /// Change 17: the Red night switch on Home Mac, reachable from Inventory and Documents, which have no ••• menu.
    func testChange17RedNightSwitchOnHomeMac() throws {
        let home = part(try file("PrepareMeApp/PrepareMeViews.swift"), from: "struct HomeMacView", to: "/// One file of the Mac's library")
        XCTAssertTrue(home.contains("RedNightSwitch(title: PrepareMeRedNight.title)"), "Downloads has no Red night switch")
    }


    /// Change 19: the phone's outline button is named "Contents".
    func testChange19ContentsAsTheOutlineButtonsName() throws {
        let button = try file("Views/Buttons/OutlineButton.swift")
        let phone = part(button, from: "#elseif os(iOS)", to: ".popover(isPresented: $isShowingOutline)")
        XCTAssertTrue(phone.contains("Label(\"Contents\", systemImage: \"list.bullet\").labelStyle(.iconOnly)"),
                      "the phone's outline button isn't named Contents")
    }


    /// Change 22: "Find in page" inside a page, on the phone and the iPad alike (Kiwix's string said "Search in page").
    func testChange22FindInPage() throws {
        let strings = try file("Support/en.lproj/Localizable.strings")
        XCTAssertTrue(strings.contains("\"common.search.inpage\" = \"Find in page\";"), "the string still says Search in page")
        XCTAssertFalse(try file("UITests_iPhone/LoadingUI_iPhone_Test.swift").contains("buttons[\"Search in page\"]"),
                       "Kiwix's own UI test still looks for the old name")
    }


    /// Change 23: the two buttons called "Scan" say what they scan; a scanned document's file name stays "Scan …".
    func testChange23ScanNamesWhatItScans() throws {
        XCTAssertEqual(InventoryHome.scanLabel, "Scan a barcode")
        XCTAssertEqual(DocumentsWords.scanButton, "Scan a paper")
        XCTAssertEqual(DocumentsWords.scanName, "Scan")
        let docs = try file("PrepareMeApp/PrepareMePhoneDocuments.swift")
        XCTAssertTrue(docs.contains("Button(DocumentsWords.scanButton, systemImage: \"doc.viewfinder\")"), "Documents' Scan isn't named")
    }


    /// Change 24: the map's "Open Home Mac" goes through the route that picks Home Mac's sheet where it is a button
    /// in the bars (an adult's iPhone), not a tab the bar doesn't have (`HomeMacRoute`, in `StateWordsTests`).
    func testChange24OpenHomeMacOnTheMapUsesTheRoute() throws {
        let map = try file("PrepareMeApp/PrepareMeStreetMap.swift")
        XCTAssertTrue(map.contains("Button(\"Open Downloads\") { PrepareMeTabs.shared.openHomeMac() }"), "the map picks a tab")
        XCTAssertFalse(map.contains("selected = .homeMac"), "the map still sets the tab itself")
        XCTAssertEqual(HomeMacRoute.opens(inBar: true), .sheet)
        XCTAssertEqual(HomeMacRoute.opens(inBar: false), .tab)
    }


    /// Change 20, the phone's pairs: one name for each command wherever it shows (the Mac's pairs are phase 7's). The
    /// names kept are the ones the screen already shows as the button's word, so Voice Control's "Tap Find me" works.
    func testChange20OneNamePerCommandOnThePhone() throws {
        let screen = try file("PrepareMeApp/PrepareMeStreetMapScreen.swift")
        XCTAssertTrue(screen.contains("\"Find me\", word: \"Find me\""), "Find me / Where am I")
        XCTAssertTrue(screen.contains("PrepareMeRedNight.title, word: \"Red night screen\""), "Red night / Red night screen")
        let strip = try file("PrepareMeApp/PrepareMeStreetMap.swift")
        XCTAssertTrue(strip.contains(".accessibilityAction(named: \"Show on map\")"), "Show on map / Show on the map")
        let inventory = try file("PrepareMeApp/PrepareMePhoneInventory.swift")
        XCTAssertTrue(inventory.contains("model.busy ? \"Checking…\" : \"Check now\""), "Check now / Look now")
        XCTAssertFalse(inventory.contains("Look now"), "Look now is still on the phone")
        XCTAssertTrue(try file("PrepareMeApp/PrepareMePhoneLists.swift").contains(".navigationTitle(\"Grab-and-Go Checklist\")"),
                      "Grab-and-Go Checklist / Grab and Go")
        XCTAssertTrue(try file("PrepareMeApp/PrepareMeQuickAdd.swift").contains(".navigationTitle(\"Quick Add with the Camera\")"),
                      "Quick Add with the Camera / Quick add")
        XCTAssertEqual(FindAMapWords.getThisFile, "Download")  // Get this file / Get it now
        XCTAssertTrue(try file("PrepareMeApp/PrepareMeTabs.swift").contains("action: (FindAMapWords.getThisFile"))
        XCTAssertFalse(try file("PrepareMeApp/PrepareMeStreetMapScreen.swift").contains("\"Where am I\""), "Where am I")
    }
}
