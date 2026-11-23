import Foundation
import Testing
@testable import PrepareMeShared

/// The Mac's items' table locked until Edit Table (the inventory fresh look, phase 1, spec 5.2), held by reading the
/// app's source, the project's way to pin app-target changes (`MacWindowsTests`). Review focus 2: a save, a search or
/// a sort never touches the lock, and every change of table or view sets it afresh. These pin only where the view
/// wires each rule in; what the rules do is held by behavior tests (`InventoryCommandsLockTests`,
/// `ItemsTableLayoutTests`) and the check build's runs (phase 1 fixes, finding 15).
/// Quit is as it was before the redesign (owner, 2026-11-17, by click, "Take it out", round 3): it asks only about a
/// household page, never holds for or cancels on an inventory cell, so a shutdown is never held or cancelled by one.
struct MacQuitTests {
    @Test func quitOnlyAsksAboutAHouseholdPage() throws {
        let text = try String(contentsOf: PaletteTests.repo.appendingPathComponent("app/Kiwix/App/App_macOS.swift"),
                              encoding: .utf8)
        let body = text.components(separatedBy: "func applicationShouldTerminate(").dropFirst().first?
            .components(separatedBy: "\n    }").first ?? ""
        #expect(body.contains("HouseholdPagesModel.shared.askBeforeQuit()"), "Quit no longer asks about a page")
        #expect(!body.contains(".terminateLater"), "Quit holds again")
        #expect(!body.contains(".terminateCancel"), "Quit cancels again")
    }
}

struct MacInventoryLockTests {
    static func detail() throws -> String { try part("struct InventoryDetail: View {") }

    /// One `struct` of the app's inventory file, without its `//` comments.
    static func part(_ start: String) throws -> String {
        let text = try String(contentsOf: PaletteTests.repo.appendingPathComponent(
            "app/Kiwix/PrepareMeApp/PrepareMeInventory.swift"), encoding: .utf8)
        guard let a = text.range(of: start),
              let b = text.range(of: "\nstruct ", range: a.upperBound..<text.endIndex) else { return "" }
        return text[a.lowerBound..<b.lowerBound].components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    /// Phase 1 fixes, finding 2: every view shares one table, so the selection starts over on each pick, not on a
    /// change of table, or Inventory › Delete could take a row not on screen.
    @Test func everyPickStartsTheSelectionOver() throws {
        let detail = try Self.detail()
        let change = detail.components(separatedBy: ".onChange(of: pick) {").dropFirst().first?.prefix(80) ?? ""
        #expect(change.contains("selection = reveal.map"), "the selection isn't started over on a pick")
        #expect(!detail.contains(".onChange(of: tableKey) {\n                selection"), "still on tableKey")
    }

    /// Phase 1 fixes, findings 1 and 4: a cell torn down while typed in saves from values (its state is gone by then),
    /// and the lock lets a kept refusal go.
    @Test func aTornDownCellSavesAndTheLockLetsARefusalGo() throws {
        let field = try Self.part("private struct TableTextField: NSViewRepresentable {")
        let dismantle = field.components(separatedBy: "static func dismantleNSView(").dropFirst().first?.prefix(400) ?? ""
        #expect(dismantle.contains("coordinator.parent.torn(field.stringValue)"), "a torn-down cell saves nothing")
        // round 2, finding B: once torn down, no end of typing saves it a second time (or blank)
        #expect(dismantle.contains("field.delegate = nil"), "a torn-down cell still hears its end of typing")
        let ended = field.components(separatedBy: "func controlTextDidEndEditing(").dropFirst().first?.prefix(120) ?? ""
        #expect(ended.contains("guard !ended else { return }"), "a torn-down cell's end of typing saves again")
        let cell = try Self.part("struct CellEditor: View {")
        #expect(cell.contains("TableTextField(text: $draft, label: column.label, left: left, torn: tornSave)"))
        let lock = cell.components(separatedBy: ".onChange(of: locked)").dropFirst().first?.prefix(600) ?? ""
        #expect(lock.contains("refused = nil"), "a refusal stays to show at the next opening")
    }

    @Test func everyTableOrViewSetsTheLockAfresh() throws {
        let detail = try Self.detail()
        let change = detail.range(of: "onChange(of: pick, initial: true)")
        #expect(change != nil, "the lock isn't set when the table or view changes")
        if let change {
            #expect(detail[change.upperBound...].prefix(160).contains("InventoryCommands.startsEditing("))
        }
    }

    @Test func aLockedCellIsTextAndTheDeleteKeyAsksTheCommands() throws {
        let detail = try Self.detail()
        #expect(detail.contains("locked: !editing"), "the table's cells aren't told the lock")
        let delete = detail.components(separatedBy: ".onDeleteCommand").dropFirst().first?.prefix(120) ?? ""
        #expect(delete.contains("commands.deleteKeyWorks"), "the Delete key works on a locked table")
    }

    /// The final review's finding 1: Done, a Columns tick and Reset Columns rebuild or lock the table from the toolbar
    /// or the menu bar, which don't take the cursor, so a cell still being typed in must be ended (and saved) first.
    @Test func doneAndTheColumnsEndTheTypingFirst() throws {
        let detail = try Self.detail()
        for name in ["func editTable()", "func setShown(", "func resetColumns()"] {
            let body = detail.components(separatedBy: name).dropFirst().first?.prefix(160) ?? ""
            let firstLine = body.components(separatedBy: "\n").first { $0.contains("{") }.map {
                String($0.split(separator: "{", maxSplits: 1).last ?? "")
            } ?? ""
            let next = body.components(separatedBy: "\n").dropFirst().first ?? ""
            #expect((firstLine + next).contains("endTyping()"), "\(name) doesn't end a cell's typing first")
        }
        #expect(detail.contains("makeFirstResponder(nil)"), "endTyping doesn't end the field editor")
    }

    /// Phase 2 review, 7: a Manual or Holds unit cell opened in the table is the forms' pick (never typed), and closes
    /// once a choice is picked, as the table's place and category list does; the − and + keep the shared 0 to 10,000.
    /// What the pick offers and saves is held by `PhonePicksTests`, the step by `QuickFormSaveTests`.
    @Test func aTableCellsManualAndHoldsUnitArePicks() throws {
        let cell = try Self.part("struct CellEditor: View {")
        #expect(cell.contains("case _ where (boxed || inTable) && PhoneEditRules.isPickOnly(column.label):"),
                "the table still types Manual and Holds unit")
        let pick = cell.components(separatedBy: "PhoneEditRules.isPickOnly(column.label):").dropFirst().first?
            .prefix(500) ?? ""
        #expect(pick.contains("defer { if inTable { editing = false } }"), "the cell stays open after a pick")
        #expect(cell.contains("draft = PhoneEditRules.stepped(draft, by: by)"), "the Mac's step has its own rule")
    }

    @Test func onlyTheButtonAndANewRowChangeTheLock() throws {
        let detail = try Self.detail()
        let sets = detail.components(separatedBy: "\n").filter {
            !$0.contains("var editing") && $0.range(of: #"\bediting\s*=(?!=)|\bediting\.toggle\(\)"#,
                                                    options: .regularExpression) != nil
        }
        #expect(sets.count == 3, "editing is set somewhere else: \(sets)")
        #expect(sets.contains { $0.contains("InventoryCommands.startsEditing(table:") })
        #expect(sets.contains { $0.contains("editing.toggle()") })
        let add = detail.components(separatedBy: "func add(").dropFirst().first?.prefix(600) ?? ""
        #expect(add.contains("editing = true"), "New Row doesn't unlock the table for its Name")
    }
}
