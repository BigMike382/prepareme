import Foundation
import XCTest
@testable import PrepareMeShared

/// Look 3 phase 7, the Mac's commands (spec section 7): each change held where it was made, by reading the screen's
/// source, the project's way to pin app-target changes (`PaletteTests`, `PhoneCommandsTests`).
final class MacCommandsTests: XCTestCase {
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

    /// The line before the first line holding `marker`, trimmed: where its `#if` sits.
    func lineBefore(_ text: String, _ marker: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let at = lines.firstIndex(where: { $0.contains(marker) }), at > 0 else { XCTFail("\(marker) wasn't found"); return "" }
        return lines[at - 1].trimmingCharacters(in: .whitespaces)
    }

    /// Change 1: no Random Page (the dice) on the Mac.
    func testChange1NoRandomPageOnTheMac() throws {
        let plist = try file("PrepareMeApp/Info-macOS.plist")
        let after = try XCTUnwrap(plist.range(of: "<key>HIDE_RANDOM_BUTTON</key>"), "HIDE_RANDOM_BUTTON isn't in Info-macOS.plist")
        XCTAssertTrue(plist[after.upperBound...].drop { $0.isWhitespace }.hasPrefix("<true/>"), "Random Page still shows")
    }

    /// Change 2: no Main Page (the house) in the Mac's reading toolbar; clicking the sidebar row again does it.
    func testChange2NoMainPageInTheMacReadingToolbar() throws {
        XCTAssertTrue(lineBefore(try file("Views/BrowserTab.swift"), "ArticleShortcutButtons(")
                        .hasPrefix("#if !(PREPAREME_APP && os(macOS))"), "the Mac's reading toolbar still has Main Page")
    }

    /// Change 3: no Edit › Copy URL and no Copy in the reader's Share menu.
    func testChange3NoCopyURL() throws {
        XCTAssertTrue(lineBefore(try file("App/App_macOS.swift"), "CommandGroup(after: .pasteboard)")
                        .hasPrefix("#if !PREPAREME_APP"), "Edit still has Copy URL")
        XCTAssertTrue(lineBefore(try file("Views/BrowserTab.swift"), "if let url = browser.webView.url {")
                        .hasPrefix("#if !PREPAREME_APP"), "the Share menu still has Copy")
    }

    /// Change 5: no External Link or Search snippet in General; fixed at ask-each-time and on, the stored choices too.
    func testChange5ExternalLinkAndSnippetOutOfGeneral() throws {
        let general = try file("PrepareMeApp/PrepareMeMac.swift")
        XCTAssertFalse(general.contains("reading_settings_external_link_title"), "General still has External Link")
        XCTAssertFalse(general.contains("reading_settings_search_snippet_title"), "General still has Search snippet")
        let launch = part(try file("App/App_macOS.swift"), from: "LibraryProcess.shared.state = .complete", to: "#endif")
        XCTAssertTrue(launch.contains("Defaults[.externalLinkLoadingPolicy] = .alwaysAsk"), "the stored policy isn't reset")
        XCTAssertTrue(launch.contains("Defaults[.searchResultSnippetMode] = .matches"), "the stored snippet choice isn't reset")
    }

    /// Change 9: Event mode in one place on the Mac, the sidebar; out of Inventory › Settings.
    func testChange9EventModeOnlyInTheSidebar() throws {
        XCTAssertFalse(try file("PrepareMeApp/PrepareMeInventorySettings.swift").contains("EventModePicker"),
                       "Inventory › Settings still switches Event mode")
        XCTAssertTrue(try file("PrepareMeApp/PrepareMeMacSidebar.swift").contains("EventModePicker().fixedSize()"),
                      "the sidebar lost Event mode")
        XCTAssertFalse(SettingsForm.parts.map(\.title).contains("Event mode"), "the form's parts still list Event mode")
    }

    /// Change 18: File › Save (⌘S), running the front screen's save: Printable References' card and the household page.
    func testChange18FileSave() throws {
        let app = try file("App/App_macOS.swift")
        let save = part(app, from: "CommandGroup(after: .saveItem)", to: "// File › Print")  // after Close, as Apple's File menu
        XCTAssertTrue(save.contains("Button(\"Save\")") && save.contains("keyboardShortcut(\"s\""), "File has no Save ⌘S")
        XCTAssertTrue(save.contains("macSave?.run()") && save.contains("macSave?.enabled != true"), "Save isn't the screen's")
        for screen in ["PrepareMeApp/PrepareMePrintableReferences.swift", "PrepareMeApp/PrepareMeHouseholdPages.swift"] {
            let text = try file(screen)
            XCTAssertTrue(text.contains(".focusedSceneValue(\\.macSave"), "\(screen) doesn't hand File › Save its save")
            XCTAssertFalse(text.contains(".keyboardShortcut(\"s\""), "\(screen) still holds ⌘S itself")
        }
    }

    /// Change 20, the Mac's pairs: one name for each command wherever it shows, the menu's (Mac menus keep title
    /// capitals, so a pair differing only in capitals stands).
    func testChange20OneNamePerCommandOnTheMac() throws {
        let inventory = try file("PrepareMeApp/PrepareMeInventory.swift")
        XCTAssertFalse(inventory.contains("\"Form…\""), "Form… / Open as Form…")
        XCTAssertFalse(inventory.contains("\"Open as a form\""), "Open as a form / Open as Form…")
        XCTAssertFalse(inventory.contains("\"Add…\""), "Add… / New Item…")
        XCTAssertTrue(inventory.contains("Label(commands.addTitle, systemImage: \"plus\")"), "the toolbar's Add isn't the menu's")
        let map = try file("PrepareMeApp/PrepareMeStreetMapMac.swift")
        // the Map menu's alone since the map pins plan's Task 3.1 took it off the toolbar
        XCTAssertTrue(map.contains("Button(\"Set Printed Directions Start…\")"), "Add Start / Set Printed Directions Start…")
        XCTAssertFalse(map.contains("\"Add Start\""), "Add Start / Set Printed Directions Start…")
        XCTAssertTrue(map.contains("Label(\"Print Household Map…\""), "Print / Print Household Map…")
        XCTAssertFalse(map.contains("Show on the "), "Show on the map / Show on map")
        let documents = try file("PrepareMeApp/PrepareMeDocuments.swift")
        XCTAssertFalse(documents.contains("Add a Document…"), "Add a Document… / Add Documents…")
        let bookmarks = try file("PrepareMeApp/PrepareMeCatalogWindow.swift")
        XCTAssertFalse(bookmarks.contains("\"Bookmark This Page\""), "Bookmark This Page / Add Bookmark")
        XCTAssertTrue(bookmarks.contains("LocalString.common_dialog_button_add_bookmark"), "the menu doesn't say Add Bookmark")
    }

    /// Change 21: what was "Refresh Conditions Now" says what it does, in the View menu and Today's toolbar.
    func testChange21KeepConditionsFresh() throws {
        for path in ["App/App_macOS.swift", "PrepareMeApp/PrepareMeMacSidebar.swift"] {
            let text = try file(path)
            XCTAssertTrue(text.contains("\"Keep Conditions Fresh for 6 Hours\""), "\(path) lacks the new name")
            XCTAssertFalse(text.contains("\"Refresh Conditions"), "\(path) still says Refresh Conditions")
        }
        XCTAssertTrue(try file("App/PrepareMeRequests.swift").contains("\"Keep conditions fresh for 6 hours\""),
                      "Kiwix (PrepareMe)'s sidebar button keeps the old name")
    }
}
