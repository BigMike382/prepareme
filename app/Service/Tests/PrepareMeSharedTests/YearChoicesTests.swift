import Foundation
import Testing
@testable import PrepareMeShared

/// Task 4.1 (inventory fresh look, spec 5.4): Year offers next year down to 1960, made by the app, and an amount's box
/// offers no list; a Year already in the inventory survives (review focus 5 applied to Year). Made-up items only.
struct YearChoicesTests {
    static func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func nextYearDownTo1960NewestFirst() {
        let now = PhoneEditRules.yearChoices(now: Self.day("2026-11-19T12:00:00Z"))
        #expect(now.first == "2027")
        #expect(now.last == "1960")
        #expect(now.count == 2027 - 1960 + 1)
        #expect(now == now.sorted(by: >), "newest first")
        let later = PhoneEditRules.yearChoices(now: Self.day("2031-06-01T12:00:00Z"))
        #expect(later.first == "2032")
        #expect(later.last == "1960")
    }

    @Test func theYearHint() {
        #expect(PhoneEditRules.hint(columnLabel: "Year") == "The year it was made (helps match recalls).")
        #expect(PhoneEditRules.hint(columnLabel: " year ") == "The year it was made (helps match recalls).")
    }

    /// The file's own Year list (2027 down to 1960 in the rehearsal file) is never offered: the app's list is.
    @Test func yearOffersTheAppsListInPlaceOfTheFiles() {
        let now = Self.day("2031-06-01T12:00:00Z")
        let file = (1960...2027).reversed().map(String.init)
        let offered = PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Year", choices: file, current: "", now: now)
        #expect(offered == PhoneEditRules.yearChoices(now: now))
        #expect(offered.first == "2032")
    }

    /// Review focus 5 applied to Year: a stored value on none of the offered years is one more choice, at the end;
    /// one that is offered, or a blank, adds nothing.
    @Test func aStoredYearOffTheListIsOneMoreChoice() {
        let now = Self.day("2026-11-19T12:00:00Z")
        let years = PhoneEditRules.yearChoices(now: now)
        for stored in ["1955", "about 1990", "1850", "2030"] {
            let offered = PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Year", choices: [], current: stored, now: now)
            #expect(offered == years + [stored], "\(stored)")
        }
        #expect(PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Year", choices: [], current: "2019", now: now) == years)
        #expect(PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Year", choices: [], current: " 2027 ", now: now) == years,
                "a stored year with spaces is the year offered")
        #expect(PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Year", choices: [], current: "", now: now) == years)
        // spaces or a newline around an off-list year: still one more choice, kept exactly as stored (fix round 1, 3)
        for stored in [" 1955 ", "1955\n", "\t1850\n"] {
            #expect(PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Year", choices: [], current: stored,
                                              now: now) == years + [stored], "\(stored.debugDescription)")
        }
        #expect(PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Year", choices: [], current: "2019\n",
                                          now: now) == years, "a listed year with a newline adds nothing")
    }

    /// A Year the file keeps as a real number (2019.0, as a Numeric column reads back) is shown as the Mac shows it,
    /// "2019", so it is the year offered and adds nothing; 1955.0 is "1955", one more choice (fix round 1, 3).
    @Test func aRealNumberYearIsTheYearShown() {
        let now = Self.day("2026-11-19T12:00:00Z"), years = PhoneEditRules.yearChoices(now: now)
        let shown = InventoryValues.plain(.real(2019.0))
        #expect(shown == "2019")
        #expect(PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Year", choices: [], current: shown,
                                          now: now) == years)
        #expect(PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Year", choices: [],
                                          current: InventoryValues.plain(.real(1955.0)), now: now) == years + ["1955"])
    }

    /// The years are the Inventory table's Year only: a column labelled Year in another table keeps its own choices,
    /// none when it has none (fix round 1, 2).
    @Test func aYearInAnotherTableKeepsItsOwn() {
        let now = Self.day("2026-11-19T12:00:00Z")
        for table in ["Locations", "Categories", "To buy", "inventory"] {
            #expect(PhoneEditRules.boxChoices(table: table, columnLabel: "Year", choices: [], current: "1955",
                                              now: now) == [], "\(table)")
            #expect(PhoneEditRules.boxChoices(table: table, columnLabel: "Year", choices: ["Old", "New"],
                                              current: "", now: now) == ["Old", "New"], "\(table)")
        }
    }

    /// The year turns over at midnight on Jan 1, by the calendar the device keeps: Dec 31 offers next year, Jan 1 the
    /// one after (fix round 1, 3). Local noon, so no time zone moves either across midnight.
    @Test func theListTurnsOverOnJanuaryFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func noon(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
        }
        #expect(PhoneEditRules.yearChoices(now: try noon(2026, 12, 31)).first == "2027")
        #expect(PhoneEditRules.yearChoices(now: try noon(2027, 1, 1)).first == "2028")
        #expect(PhoneEditRules.yearChoices(now: try noon(2027, 1, 1)).last == "1960")
    }

    /// An amount's box offers no list (spec 5.4: Quantity's 1 to 12, 15, 16 … 100 goes); other choice columns keep
    /// the file's.
    @Test func anAmountOffersNoListAndOtherColumnsTheirOwn() {
        let now = Self.day("2026-11-19T12:00:00Z")
        let quantities = ["1", "2", "3", "12", "15", "100"]
        for label in ["Quantity", " quantity ", "Calories each", Inventory.Label.eachHolds, "Running watts"] {
            #expect(PhoneEditRules.boxChoices(table: "Inventory", columnLabel: label, choices: quantities, current: "4", now: now) == [],
                    "\(label)")
        }
        #expect(PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Unit", choices: ["each", "cans"], current: "jugs", now: now)
                == ["each", "cans"], "Unit's list as the file holds it; a typed unit is kept by its box, as before")
        #expect(PhoneEditRules.boxChoices(table: "Inventory", columnLabel: "Brand", choices: ["Zorvex"], current: "", now: now) == ["Zorvex"])
    }
}

/// Wiring only: the Mac's typed box (form and table, one `CellEditor` case) and the phone's `box` each offer what
/// `boxChoices` gives (its behavior is tested above), never the column's stored list.
struct YearChoicesWiringTests {
    @Test func bothBoxesOfferTheSharedRulesChoices() throws {
        func app(_ name: String) throws -> String {
            try String(contentsOf: PaletteTests.repo.appendingPathComponent("app/Kiwix/PrepareMeApp/\(name)"),
                       encoding: .utf8)
        }
        let mac = try app("PrepareMeInventory.swift"), phone = try app("PrepareMePhoneInventory.swift")
        #expect(mac.contains("let offered = PhoneEditRules.boxChoices(table: tableName, columnLabel: column.label,"))
        #expect(mac.contains("current: shown, now: .now)"))
        #expect(phone.contains("let offered = PhoneEditRules.boxChoices(table: \"Inventory\", columnLabel: column.label,"))
        #expect(phone.contains("current: first?.typed[column.colId] ?? \"\", now: .now)"))
        for source in [mac, phone] {
            #expect(source.contains("ForEach(offered, id: \\.self) { choice in"))
            #expect(!source.contains("ForEach(column.choices, id: \\.self) { choice in"), "the column's own list")
        }
    }
}

/// Review focus 5 applied to Year, through the phone's send path (`QuickForm.sent`, `PhoneEditRules.cellChange`): an
/// edit of another field never sends Year, whatever it holds; a year picked is sent as the Mac stores it.
struct YearSurvivesAPhoneEditTests {
    static let columns = QuickFormSaveTests.columns + [QuickFormSaveTests.column("Y", "Year", "choice")]

    func sent(_ row: PhoneInventory.Row, was: [String: String], now: [String: String]) -> QuickForm.Sent {
        var saving = false
        let copy = PhoneInventory(writtenAt: "", columns: Self.columns, items: [row], places: [], categories: [],
                                  headsUpDays: 60, toBuy: [], results: [:])
        return QuickForm.sent(copy: copy, columns: Self.columns, row: row, openedID: row.id, openedValues: row.values,
                              was: was, now: now, new: .add(editAgain: false), barcode: nil, saving: &saving)
    }

    @Test func anotherFieldsSaveNeverSendsYear() {
        for stored: SQLValue in [.int(1955), .text("about 1990"), .null, .text(""), .int(2027), .real(1850)] {
            let row = PhoneInventory.Row(id: 7, position: 1, values: ["A": .text("Zorvex Stove"), "Y": stored])
            let shown = QuickFormSaveTests.texts(["A": "Zorvex Stove", "Y": InventoryValues.plain(stored)])
            let notes = shown.merging(["N": "Top shelf"]) { $1 }
            #expect(sent(row, was: shown, now: notes)
                    == .cells([QuickForm.Cell(change: .revert(table: "Inventory", row: 7, colId: "N",
                                                              value: .text("Top shelf"), expected: .null),
                                              what: "Zorvex Stove: Notes")]), "\(stored)")
        }
    }

    @Test func aYearPickedIsSentSayingWhatTheFormOpenedWith() {
        let row = PhoneInventory.Row(id: 7, position: 1, values: ["A": .text("Zorvex Stove"), "Y": .int(1955)])
        let shown = QuickFormSaveTests.texts(["A": "Zorvex Stove", "Y": "1955"])
        guard case .cells(let cells) = sent(row, was: shown, now: shown.merging(["Y": "2019"]) { $1 }) else {
            Issue.record("not an edit's cells")
            return
        }
        #expect(cells.map(\.what) == ["Zorvex Stove: Year"])
        guard case .revert(_, let id, let colId, let value, let expected) = cells.first?.change else {
            Issue.record("not a cell change")
            return
        }
        #expect(id == 7 && colId == "Y" && expected == .int(1955))
        #expect(InventoryValues.plain(value) == "2019")
    }
}

/// Review focus 5 applied to Year, through the Mac's editor, as the Mac's form and table cell save (`CellEditor.save`:
/// one `.set` of that one cell): saving another cell leaves Year exactly as stored, and a year offered past the file's
/// own list (2028 and on) is taken, as the Year column takes any text. A copy of the made-up rehearsal file.
@MainActor
struct YearSurvivesAMacEditTests {
    @Test func anotherCellsSaveLeavesYearAsStored() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-year-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        let file = try InventoryFile(url: url)
        let editor = try InventoryEditor(file: file, checker: FakeCheck())
        let items = editor.inventory.items
        let year = try #require(items.column("Year")), notes = try #require(items.column("Notes"))
        let row = try #require(editor.inventory.itemRows.first).id
        func now() -> SQLValue { editor.inventory.itemRows.first { $0.id == row }![year] }
        for stored: SQLValue in [.int(1955), .text("about 1990"), .int(2027), .text(""), .null] {
            try file.set(items, row: row, column: year, to: stored)
            try editor.reload()
            let before = now()  // as the file keeps it (a Choice column's 1955 reads back as text)
            #expect(InventoryValues.plain(before) == InventoryValues.plain(stored))
            let outcome = try await editor.apply(.set(table: "Inventory", row: row, colId: notes.colId,
                                                      value: .text("Top shelf \(stored)")))
            guard case .done = outcome else { Issue.record("\(stored): \(outcome)"); continue }
            #expect(now() == before, "\(stored) read back \(now())")
        }
        // a year the app offers past the file's own list is stored as the Mac's form stores a pick (`commit`)
        guard case .success(let picked) = InventoryValues.stored("2032", in: year, names: [:]) else {
            Issue.record("2032 refused by the Year column")
            return
        }
        guard case .done = try await editor.apply(.set(table: "Inventory", row: row, colId: year.colId, value: picked))
        else { Issue.record("2032 not saved"); return }
        #expect(InventoryValues.plain(now()) == "2032")
    }
}

/// Pinned for the owner, unchanged (fix round 1, item 7): a Year the lists job can't read (text, or a number outside
/// 1900 to 2100, inventory/columns.py's YEAR_RANGE) makes the real check refuse every edit to the file, since each is
/// tried on a copy the lists job must read whole; through the real editor and Python check, Mac and phone alike. The
/// app itself can't store one: typing it in Year is refused the same way. Skipped without the venv.
@MainActor
struct AnUnreadableYearTests {
    nonisolated static let python = PythonTextCheck.venvPython()
    nonisolated static var hasVenv: Bool { python.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }

    @Test(.enabled(if: hasVenv)) func everyEditIsRefusedWhileItStands() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-year-real-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        let file = try InventoryFile(url: url)
        let editor = try InventoryEditor(file: file, checker: PythonTextCheck(python: try #require(Self.python),
                                                                              code: InventoryTests.repo))
        let items = editor.inventory.items
        let year = try #require(items.column("Year")), notes = try #require(items.column("Notes"))
        let first = try #require(editor.inventory.itemRows.first), other = try #require(editor.inventory.itemRows.last)
        let at = "inventory.sqlite: Inventory row \(first.position), Year"  // the file's own name first
        // the app can't store one: typed in Year, it is refused, in these words
        let typed = try await editor.apply(.set(table: "Inventory", row: first.id, colId: year.colId,
                                                value: .text("about 1990")))
        #expect(typed == .refused("\(at): isn't a number"))
        // put in the file another way (by hand, an old copy): every edit is refused, to that item and to any other,
        // from the Mac or a phone, until Year is put right
        for (stored, why) in [(SQLValue.text("about 1990"), "isn't a number"),
                              (.text("1850"), "Year must be a whole number from 1900 to 2100"),
                              (.int(2150), "Year must be a whole number from 1900 to 2100")] {
            try file.set(items, row: first.id, column: year, to: stored)
            try editor.reload()
            let refusal = "\(at): \(why)"
            let same = try await editor.apply(.set(table: "Inventory", row: first.id, colId: notes.colId,
                                                   value: .text("Top shelf")))
            let another = try await editor.apply(.set(table: "Inventory", row: other.id, colId: notes.colId,
                                                      value: .text("Top shelf")))
            let phone = try await editor.apply(.set(table: "Inventory", row: first.id, colId: notes.colId,
                                                    value: .text("Top shelf")),
                                               phone: .init(id: "edit-\(UUID())", phone: "made-up phone"))
            #expect(same == .refused(refusal), "\(stored)")
            #expect(another == .refused(refusal), "\(stored), another item")
            #expect(phone == .refused(refusal), "\(stored), from a phone")
            // putting Year right is the one edit that goes through
            let fixed = try await editor.apply(.set(table: "Inventory", row: first.id, colId: year.colId,
                                                    value: .text("1955")))
            guard case .done = fixed else { Issue.record("\(stored): putting Year right was \(fixed)"); return }
        }
        // emptying Year clears it too (the docs' note, owner's ruling of 2026-11-19)
        try file.set(items, row: first.id, column: year, to: .text("about 1990"))
        try editor.reload()
        let emptied = try await editor.apply(.set(table: "Inventory", row: first.id, colId: year.colId, value: .text("")))
        guard case .done = emptied else { Issue.record("emptying Year was \(emptied)"); return }
        guard case .done = try await editor.apply(.set(table: "Inventory", row: other.id, colId: notes.colId,
                                                       value: .text("Top shelf"))) else {
            Issue.record("an edit after emptying Year refused")
            return
        }
        try file.set(items, row: first.id, column: year, to: .text("1955"))
        try editor.reload()
        // 1955, stored as text in the Choice column, reads as a number: edits go through
        guard case .done = try await editor.apply(.set(table: "Inventory", row: first.id, colId: notes.colId,
                                                       value: .text("Top shelf"))) else {
            Issue.record("a text 1955 refused")
            return
        }
    }
}

/// The owner's ruling on the unreadable Year (2026-11-19, "Leave it, note it"): the guard stays as it is, but the Mac's
/// alert says the column once, as the phones already do; any other refusal is shown exactly as the editor gave it.
struct TheMacsRefusalSaysYearOnceTests {
    @Test func aRepeatedColumnIsSaidOnce() {
        #expect(PhoneEditRules.shownRefusal("inventory.sqlite: Inventory row 4, Year: Year must be a whole number from "
                                            + "1900 to 2100") == "inventory.sqlite: Inventory row 4, Year: must be a "
                                            + "whole number from 1900 to 2100")
        #expect(PhoneEditRules.shownRefusal("Inventory row 2, Model: Model holds only the model number")
                == "Inventory row 2, Model: holds only the model number")
    }

    @Test func otherRefusalsAreShownAsGiven() {
        for given in ["inventory.sqlite: Inventory row 1, Year: isn't a number",
                      "Inventory row 3, across its cells: holds a cash amount",
                      "Inventory row 3, Quantity: can't be below zero",
                      "The inventory changed since you opened this item.", ""] {
            #expect(PhoneEditRules.shownRefusal(given) == given)
        }
    }

    @Test func theMacsAlertUsesIt() throws {
        let source = try String(contentsOf: PaletteTests.repo.appendingPathComponent(
            "app/Kiwix/PrepareMeApp/PrepareMeInventory.swift"), encoding: .utf8)
        #expect(source.contains("message = PhoneEditRules.shownRefusal(why)"))
    }
}
