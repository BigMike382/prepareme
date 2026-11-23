import Foundation
import Testing
@testable import PrepareMeShared

/// The Mac's menu bar (docs/plans/2026-11-14-mac-menu-bar.md; owner, 2026-11-14): each item held in its menu by
/// reading the app's source, the project's way to pin app-target changes (`MacCommandsTests`). What the bar really
/// reads is the check build's `PREPAREME_CHECK_MENUS` dump.
struct MacMenuBarTests {
    /// A file under app/Kiwix as text.
    static func source(_ path: String) throws -> String {
        try String(contentsOf: PaletteTests.repo.appendingPathComponent("app/Kiwix").appendingPathComponent(path),
                   encoding: .utf8)
    }

    /// The text from `start` up to the next `end` after it; empty when either is missing.
    static func part(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex)
        else { return "" }
        return String(text[a.lowerBound..<b.lowerBound])
    }

    /// Whether `words` all appear in `text`, in that order.
    static func inOrder(_ text: String, _ words: [String]) -> Bool {
        var from = text.startIndex
        for word in words {
            guard let found = text.range(of: word, range: from..<text.endIndex) else { return false }
            from = found.upperBound
        }
        return true
    }

    static let app = "App/App_macOS.swift"

    @Test("Go lists the screens; Window holds only windows")
    func goMenu() throws {
        let app = try Self.source(Self.app)
        #expect(!app.contains("CommandGroup(before: .windowList)"), "Window still lists screens")
        #expect(!app.contains("prepareMeTab = .phones"), "a menu item still opens Settings › Devices")
        let go = Self.part(app, from: "CommandMenu(\"Go\")", to: "InventoryMenu()")
        #expect(Self.inOrder(go, ["NavigationCommands(", "PrepareMeGoRows("]), "Go: Back and Forward, then the screens")
        let catalog = try Self.source("PrepareMeApp/PrepareMeCatalogWindow.swift")
        let rows = Self.part(catalog, from: "struct PrepareMeGoRows", to: "struct PrepareMeBookmarkCommands")
        #expect(Self.inOrder(rows, ["MacSidebar.topLevel", "MacSidebar.goKey(", "\"Street Map\"",
                                    "PrepareMeOtherLibrariesMenu("]),
                "the nine screens with their keys, Street Map, then the collections")
        #expect(catalog.contains("Menu(MacLibraries.collectionsTitle)"), "the collections aren't a second Library item")
        #expect(rows.contains("showFromMenu("), "a screen opens as Window's items did, bringing the window back (F48)")
        #expect(rows.contains("row == .games ? held[MacLibraries.gamesFile] == nil : row == .shelf && noCollections"),
                "Games dims without its file and Library with no collections, as the sidebar hides those rows")
        #expect(Self.inOrder(rows, ["let off = ", ".disabled(off)"]), "a row the sidebar isn't showing is dimmed, never hidden")
        // a Go item is a pick, as a sidebar click is: Back no longer leads to a Library list (review, 2026-11-14)
        let show = Self.part(try Self.source("PrepareMeApp/PrepareMeMacSidebar.swift"),
                             from: "func showFromMenu(", to: "func openAppLink(")
        #expect(show.contains("forgetReturn()"), "Go › Guides after a collection kept Back leading to the Library list")
    }

    @Test("The Library menu is gone: its items are in File and View")
    func libraryMenuDissolved() throws {
        let app = try Self.source(Self.app)
        #expect(!app.contains("CommandMenu(\"Library\")"), "the Library menu is still there")
        let new = Self.part(app, from: "CommandGroup(replacing: .newItem)", to: "CommandGroup(after: .toolbar)")
        #expect(Self.inOrder(new, ["\"Add to Library…\"", "\"Edit Our Home\""]), "File starts with the two")
        let save = Self.part(app, from: "CommandGroup(after: .saveItem)", to: "// File › Print")
        #expect(Self.inOrder(save, ["Button(\"Save\")", "\"Back Up to iCloud Now\"", "\"Back Up to the Drive Now\""]),
                "the backups follow Save")
        let view = Self.part(app, from: "CommandGroup(after: .toolbar)", to: "CommandGroup(after: .textEditing)")
        #expect(Self.inOrder(view, ["RedNightSwitch()", "\"Keep Conditions Fresh for 6 Hours\"",
                                    "\"Check Conditions Once\""]), "the Conditions items follow Red Night Screen")
        for words in ["\"Add to Library…\"", "\"Edit Our Home\"", "\"Back Up to iCloud Now\"",
                      "\"Back Up to the Drive Now\"", "\"Keep Conditions Fresh for 6 Hours\"", "\"Check Conditions Once\""] {
            #expect(app.components(separatedBy: words).count == 2, "\(words) is in the menu bar once")
        }
    }

    @Test("Inventory ends with its two removing items")
    func inventoryOrder() throws {
        let menu = Self.part(try Self.source("PrepareMeApp/PrepareMeInventory.swift"),
                             from: "CommandMenu(\"Inventory\")", to: "#endif")
        #expect(Self.inOrder(menu, ["\"New Item…\"", "\"Add by Barcode…\"", "\"Open as Form…\"", "Divider()",
                                    // the item's words are the commands' (InventoryCommandsLockTests), not the fallback
                                    "Button(state?.editMenuTitle", "Menu(\"Columns\")", "Divider()", "\"Print Blank Sheet…\"",
                                    "Menu(InventoryWords.labelsItem(selected: state?.labelCount", "\"Print Grab Sheets…\"",
                                    "Divider()",
                                    "\"Export CSV…\"", "Divider()", "state?.deleteTitle",
                                    "InventoryWords.removeEmptyTitle"]),
                "Edit Table and Columns after the forms; Delete and Remove Empty Places… last, as Documents ends")
        #expect(!menu.contains("Button(\"Delete\")"), "Delete takes its \"…\" for several rows (spec 5.5)")
    }

    @Test("Documents has one lock item, and a folder brought in isn't New Folder's double")
    func documentsLockAndFolder() throws {
        let documents = try Self.source("PrepareMeApp/PrepareMeDocuments.swift")
        let menu = Self.part(documents, from: "CommandMenu(\"Documents\")", to: "#endif")
        #expect(!menu.contains("Button(\"Unlock\")"), "Unlock is still an item of its own")
        #expect(menu.contains("open ? \"Lock\" : \"Unlock\""), "one item that reads Lock or Unlock")
        #expect(menu.contains("if open { documents?.model.lock() } else { documents?.model.unlock() }"),
                "it does what it reads")
        #expect(Self.inOrder(menu, ["open ? \"Lock\" : \"Unlock\"", ".disabled(documents == nil)", "Divider()"]),
                "dimmed only off Essential Documents")
        #expect(menu.components(separatedBy: "keyboardShortcut(\"l\"").count == 2, "⌥⌘L once, either way")
        #expect(!documents.contains("\"Add a Folder…\""), "Add a Folder… / Add Folder of Documents…")
        #expect(documents.components(separatedBy: "Button(DocumentsWords.addFolder)").count == 3,
                "the menu and the empty screen's button say the same")
        #expect(DocumentsWords.addFolder == "Add Folder of Documents…")
    }

    @Test("Back and Forward left View for Go, in PrepareMe only")
    func backAndForward() throws {
        let view = Self.part(try Self.source(Self.app), from: "CommandGroup(after: .toolbar)", to: "CommandGroup(after: .textEditing)")
        let navigation = try #require(view.range(of: "NavigationCommands("))
        let before = view[..<navigation.lowerBound].components(separatedBy: "\n").dropLast()
        #expect(before.last?.trimmingCharacters(in: .whitespaces).hasPrefix("#if !PREPAREME_APP") == true,
                "View's Back and Forward are Kiwix's build's only")
    }
}
