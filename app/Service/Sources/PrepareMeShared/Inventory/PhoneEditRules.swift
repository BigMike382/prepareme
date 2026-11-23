import Foundation

/// What the phone's item form checks at Save, before an edit waits for the Mac (the beta run's F20, F21; plan
/// 2026-10-16, Task 4.1): only the Mac's own rules, so a value the Mac takes is never refused here, and the Mac's
/// refusals in plain words. The Mac's own words stay as they are: its editor and logs use them.
public enum PhoneEditRules {
    /// The columns the lists job reads as amounts that can't be below zero (readiness/inventory.py, Quantity and
    /// Calories each, `not_negative`), matched by header as the Mac matches them (InventoryFile.same).
    public static let notNegative = ["Quantity", "Calories each", "Each holds", "Running watts", "Starting watts"]

    /// A number as the lists job reads one (readiness/sheets.py `_NUMBER`): "1,045", "2.5", ".5", "+3"; never "2." or
    /// "10,45", which the Mac refuses.
    static let number = #"^[+-]?(?:(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+)$"#

    /// Why `typed` won't do in a column, in the form's words, or nil. Rules go by the column's header, as the lists
    /// job finds its columns, never by its kind alone: the inventory's Quantity, Brand, Unit and Year are choice
    /// columns the Mac takes any text in. Grab is never refused: the Mac reads it in any case and only notes a stray
    /// one (inventory/columns.py `grab_choice`; review of phase 4).
    public static func problem(columnLabel: String, kind: String, typed: String, choices: [String] = []) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAmount(columnLabel), !text.isEmpty else { return nil }
        guard text.range(of: number, options: .regularExpression) != nil,
              let found = Double(text.replacingOccurrences(of: ",", with: "")) else {
            return "\(columnLabel): \(lowered(InputProblem.notANumber.description))"
        }
        return found < 0 ? "\(columnLabel): can't be below zero." : nil
    }

    /// A message's first letter in lower case, so every problem reads "Field: message" (R4.3, B2-11): "Write a number"
    /// is "write a number". Only a capital followed by a lower-case letter moves ("USNG" and "I'd" are left alone).
    public static func lowered(_ message: String) -> String {
        let letters = Array(message)
        guard letters.count > 1, letters[0].isUppercase, letters[1].isLowercase else { return message }
        return letters[0].lowercased() + String(letters.dropFirst())
    }

    /// One line under a field a first-timer wouldn't understand (R4.3, B2-11): Year, Manual and Unit, by header.
    public static func hint(columnLabel: String) -> String? {
        let header = columnLabel.trimmingCharacters(in: .whitespaces)
        if InventoryFile.same(header, "Year") {
            return "The year it was made (helps match recalls)."
        }
        if InventoryFile.same(header, "Manual") {
            return "Not needed: it needs no manual. None exists: the maker never made one. "
                + "A manual's PDF can only be added on the Mac."
        }
        if InventoryFile.same(header, "Unit") {
            return "What one is counted in, like can, bottle or box. Use the same word each time."
        }
        if InventoryFile.same(header, Inventory.Label.eachHolds) { return ItemFieldGroup.holdsHint }
        return nil
    }

    /// The phone's words for an item with no name, in its one style ("Field: message"; R4.3's review): the Mac keeps
    /// its own (InventoryWords.noName).
    public static let noName = "\(Inventory.Label.item): \(lowered(InventoryWords.noName))"

    /// An item left with no name is stopped up front, in the form's style ("Item: give the item a name."): the Mac's
    /// editor refuses a new item with none (R4.1), and a change that blanks an item's name (checkpoint 2), so the phone
    /// says so before the change is queued. `was`: the item's name before (nil for a new item); an item with no name
    /// yet (a barcode add named later) has none to blank, and may stay so.
    public static func nameProblem(columnLabel: String, typed: String, was: String?) -> String? {
        guard InventoryFile.same(columnLabel, Inventory.Label.item),
              typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let was, was.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return "\(columnLabel): \(lowered(InventoryWords.noName))"
    }

    /// The line under a refused change (R4.3, B2-11): an item the Mac no longer has is named with its place, never a
    /// "row"; any other reason is the Mac's, in plain words. `item` is "Headlamp (Bin 29)" as the phone knew it; an
    /// entry kept before that falls back on the name in `what` ("Headlamp: used 1").
    public static func refusalLine(message: String, item: String?, what: String) -> String {
        let reason = message.trimmingCharacters(in: .whitespaces)
        if reason == InventoryWords.noName { return noName }  // the form's own style (checkpoint 2)
        if reason == InventoryWords.changedSince { return changedOnMac }  // the Mac's words speak of its Undo
        guard reason == InventoryWords.noRow else { return plainRefusal(message) }
        // `what` is "<name>: <what was done>" ("Radio: NOAA weather: used 1"), and what was done never holds ": ", so
        // the name is all before the last one, kept whole; a line of another shape is shown whole (checkpoint 2)
        let named = item ?? what.range(of: ": ", options: .backwards).map { String(what[..<$0.lowerBound]) } ?? what
        return "Someone removed this \(named) on the Mac; your change wasn't kept."
    }

    /// Unit, Brand and Model, kept as typed (Task 1.4, 2026-10-23): the phone's box adds no capital letter and no
    /// autocorrect, so "can" stays "can" as the Unit hint asks.
    public static func typedAsIs(_ columnLabel: String) -> Bool {
        ["Unit", "Brand", Inventory.Label.model].contains { InventoryFile.same($0, columnLabel) }
    }

    /// Past entries offered under a Unit, Brand or Model box as it's typed (owner, 2026-10-30: auto complete where
    /// there are earlier entries): of `values` (the column's choices, then what its rows hold), those that start with
    /// what's typed, ignoring case and accents, each once as first spelled, A to Z. None for an empty box, and never
    /// the very text typed.
    public static func suggestions(typed: String, from values: [String], limit: Int = 8) -> [String] {
        let key = typed.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }
        var seen = Set<String>(), found: [String] = []
        for value in values.map({ $0.trimmingCharacters(in: .whitespaces) }) where value != key {
            guard value.range(of: key, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil,
                  seen.insert(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted
            else { continue }
            found.append(value)
        }
        return Array(found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(limit))
    }

    /// A name's first typed letter as a capital (owner, 2026-10-30): the Mac's keyboard adds none, as the phone's does.
    /// Only the first keystroke into an empty box, so a small letter put back after it ("iPhone") stays; nil for no
    /// change.
    public static func capitalFirst(was old: String, now new: String) -> String? {
        guard old.isEmpty, new.count == 1, new.first?.isLowercase == true else { return nil }
        return new.uppercased()
    }

    /// A cell changed on the Mac since this phone last saw it (Task 1.8, 2026-10-23): the phone's change wasn't kept.
    public static let changedOnMac = "This was changed on the Mac since you last saw it, so your change wasn't kept. "
        + "Look at it now and change it again if you still need to."

    /// Year's choices (spec 5.4): next year down to 1960, newest first, made by the app. The file's own list is left
    /// as it is: `ensureChoices` only adds at the end, which would put 2028 under 1960.
    public static func yearChoices(now: Date) -> [String] {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        return (1960...(year + 1)).reversed().map(String.init)
    }

    /// What a typed box offers beside it, on the Mac (its form and table) and the phone alike: an amount nothing (spec
    /// 5.4: Quantity's list goes; its − and + stay), the items' Year `yearChoices` with the item's own stored value after
    /// them when it is none of them (review focus 5), any other column the file's own choices. The years are the
    /// Inventory table's Year only, of whatever kind the file gave it (the lists job reads it as a number); a "Year" in
    /// another table keeps its own (phase 4 review, fix 2). The phone's form edits items alone: it passes "Inventory".
    public static func boxChoices(table: String, columnLabel: String, choices: [String], current: String,
                                  now: Date) -> [String] {
        if isAmount(columnLabel) { return [] }
        guard table == "Inventory", InventoryFile.same(columnLabel, "Year") else { return choices }
        let years = yearChoices(now: now), stored = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty || years.contains(stored) ? years : years + [current]
    }

    /// Quantity or Calories each, in any case: the form gives them the number keypad.
    public static func isAmount(_ columnLabel: String) -> Bool {
        notNegative.contains { InventoryFile.same($0, columnLabel) }
    }

    /// The one column the form offers as a list: Grab (Inventory.grabChoices).
    public static func isPicked(_ columnLabel: String) -> Bool {
        InventoryFile.same(columnLabel, Inventory.Label.grab)
    }

    /// The on/off fields the phone's form shows as switches (inventory fresh look, spec 5.3); Private stays Mac only.
    public static let phoneSwitches = [Inventory.Label.emptyUntilNeeded, Inventory.Label.keepPastDate]

    public static func isSwitch(_ columnLabel: String) -> Bool {
        phoneSwitches.contains { InventoryFile.same($0, columnLabel) }
    }

    /// A switch's shown value is on as the Mac stores a tick (InventoryValues.stored: "Yes", a refused edit's "1").
    public static func isOn(_ shown: String) -> Bool {
        let tick = InventoryColumn(ref: 0, colId: "", label: "", type: "Bool", kind: .bool, isFormula: false,
                                   choices: [], shownColId: nil, displayColId: nil)
        return (try? InventoryValues.stored(shown, in: tick).get()) == .int(1)
    }

    /// Manual and Holds unit: picks only, never typed (spec 5.4), so no off-list value gets in from the phone.
    public static func isPickOnly(_ columnLabel: String) -> Bool {
        ["Manual", Inventory.Label.holdsUnit].contains { InventoryFile.same($0, columnLabel) }
    }

    /// Manual's blank as the pick shows it; stored as the blank it is (spec 5.4).
    public static let manualBlank = "Not recorded"

    /// A pick-only column's choices: its blank first (Manual's "Not recorded", Holds unit's ""), then Holds unit's six
    /// as the app adds them to the file (`Inventory.Label.holdsUnits`) or Manual's own from the file (built-in ones for
    /// a file that has none), then the item's stored value when it matches none of them in any case or spacing, so
    /// opening an item never changes it (review focus 5).
    public static func pickChoices(_ columnLabel: String, choices: [String], stored: String) -> [String] {
        let manual = InventoryFile.same(columnLabel, "Manual")
        var own = manual ? choices.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != manualBlank }
            : Inventory.Label.holdsUnits
        if own.isEmpty { own = ["Not needed", "None exists"] }
        let all = [manual ? manualBlank : ""] + own
        return stored.isEmpty || all.contains(where: { InventoryFile.same($0, stored) }) ? all : all + [stored]
    }

    /// A stored pick as the menu selects it, as `grabShown` does for Grab: the choice it matches in any case or
    /// spacing, stored as `pickStored` keeps it (Manual's "Not recorded" is the blank), else as stored.
    public static func pickShown(_ columnLabel: String, stored: String, choices: [String]) -> String {
        guard !stored.isEmpty else { return stored }
        return pickChoices(columnLabel, choices: choices, stored: "").first { InventoryFile.same($0, stored) }
            .map { pickStored(columnLabel, shown: $0) } ?? stored
    }

    /// A pick's shown choice as stored: Manual's "Not recorded" is the blank; anything else as it is.
    public static func pickStored(_ columnLabel: String, shown: String) -> String {
        InventoryFile.same(columnLabel, "Manual") && shown == manualBlank ? "" : shown
    }

    /// Whether the on-screen keyboard is up, from how much of the screen its frame covers: an iPad's hardware keyboard
    /// leaves only its bar of shortcuts and the form's Next and Done on screen, well under 120 points; the smallest
    /// on-screen keyboard (an iPhone's number pad held sideways) is taller. The what's-missing line goes only for it.
    public static func screenKeyboardUp(shownHeight: Double) -> Bool { shownHeight > 120 }

    /// The change an edited item's Save sends for one cell, or nil when it needn't go (not typed in, or the item holds
    /// that value already, `latest`). It says what the form opened with (`opened`), never the copy at Save, so a cell
    /// the Mac changed while the form was open is refused there, never overwritten (Task 1.8; stale edit base fix,
    /// 2026-11-18).
    public static func cellChange(row: Int64, colId: String, value: SQLValue?, opened: [String: SQLValue],
                                  latest: [String: SQLValue]) -> InventoryChange? {
        guard let value, value != (latest[colId] ?? .null) else { return nil }
        return .revert(table: "Inventory", row: row, colId: colId, value: value, expected: opened[colId] ?? .null)
    }

    /// Quantity's − and + (phase 2 review, 4): one up or down from what is typed (a blank or unreadable box as 0),
    /// never under 0 nor stepped over 10,000, as Quick add's card stepped; a figure typed over 10,000 already (a food in
    /// calories) is never pulled down to it, so − takes 1 off and + leaves it (phase 2 review, I1).
    public static func stepped(_ typed: String, by: Double) -> String {
        let n = InventoryValues.parseNumber(typed) ?? 0
        return InventoryValues.number(min(max(n, 10_000), max(0, n + by)))
    }

    /// The fields Save checks and sends: those changed from the item's own (`was`; nil for a new item, all of them),
    /// so a value left alone, an off-list Manual or Holds unit among them, is never rewritten (review of phase 4).
    public static func changed(_ ids: [String], was: [String: String]?, now: [String: String]) -> [String] {
        ids.filter { was?[$0] != now[$0] }
    }

    /// A stored Grab as the list shows it: the choice it matches in any case, else as stored, so opening an item
    /// never changes its Grab.
    public static func grabShown(_ stored: String, choices: [String]) -> String {
        choices.first { InventoryFile.same($0, stored) } ?? stored
    }

    /// The list's choices, with the item's own Grab after them when it's none of them.
    public static func grabOptions(_ choices: [String], current: String) -> [String] {
        current.isEmpty || choices.contains(current) ? choices : choices + [current]
    }

    /// A stored date as seconds at UTC midnight: a number as Grist stores a day, or text the Mac reads as a date (a
    /// date Grist couldn't parse stays as text; readiness/sheets.py `day`); nil for anything else.
    public static func storedDay(_ value: SQLValue) -> Double? {
        switch value {
        case .int, .real: value.number
        case .text(let text): InventoryValues.parseDay(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// The Mac's refusal as its alert shows it: whole, file and row kept, but a reason that repeats its column says it
    /// once ("…row 3, Year: Year must be…" is "…row 3, Year: must be…"), as `plainRefusal` does on the phones. Only the
    /// shown words: the lists job's own message (readiness's YEAR_CELL) and what it refuses are unchanged (owner,
    /// 2026-11-19, "Leave it, note it").
    public static func shownRefusal(_ reason: String) -> String {
        let shape = #"^((?:.+?: )?[A-Za-z][A-Za-z ]* row \d+, ([^:]+): )(.+)$"#
        guard let found = try? NSRegularExpression(pattern: shape)
            .firstMatch(in: reason, range: NSRange(reason.startIndex..., in: reason)),
              let headRange = Range(found.range(at: 1), in: reason), let columnRange = Range(found.range(at: 2), in: reason),
              let whyRange = Range(found.range(at: 3), in: reason)
        else { return reason }
        let column = String(reason[columnRange]), why = String(reason[whyRange])
        guard why.lowercased().hasPrefix(column.lowercased() + " ") else { return reason }
        return String(reason[headRange]) + why.dropFirst(column.count + 1)
    }

    /// The Mac's refusal without its file name and row number, as "Field: message" (R4.3, B2-11, one style):
    /// "PrepareMe Inventory.grist: Inventory row 3006, Quantity: can't be below zero" is "Quantity: can't be below
    /// zero."; a reason that repeats its column ("Year must be…") drops the repeat ("Year: must be…"); a reason of
    /// another shape is kept as it is.
    public static func plainRefusal(_ reason: String) -> String {
        let shape = #"^(?:.+?: )?[A-Za-z][A-Za-z ]* row \d+, ([^:]+): (.+?)\.?$"#
        guard let found = try? NSRegularExpression(pattern: shape)
            .firstMatch(in: reason, range: NSRange(reason.startIndex..., in: reason)),
              let columnRange = Range(found.range(at: 1), in: reason), let whyRange = Range(found.range(at: 2), in: reason)
        else { return reason }
        let column = String(reason[columnRange]), why = String(reason[whyRange])
        if column == "across its cells" { return "This item: \(why)." }  // the row's cells read together (sheets.ACROSS)
        // one shape, "Field: message" (R4.3, B2-11): "Year must be…" is "Year: must be…"
        if why.lowercased().hasPrefix(column.lowercased() + " ") { return "\(column): \(String(why.dropFirst(column.count + 1)))." }
        return "\(column): \(why)."
    }
}
