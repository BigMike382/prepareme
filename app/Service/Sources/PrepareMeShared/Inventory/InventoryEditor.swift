import Foundation

/// One change to the inventory file (plan phase 7): what the Mac's editor makes, what a phone sends (slice 5), and what
/// undoes a change.
public enum InventoryChange: Codable, Equatable, Sendable {
    case set(table: String, row: Int64, colId: String, value: SQLValue)
    case add(table: String, values: [String: SQLValue])
    case delete(table: String, row: Int64)
    case restore(table: String, row: Int64, cells: [String: SQLValue])  // a deleted row put back (undo)
    case adjust(row: Int64, by: Double)  // an Inventory row's Quantity, up or down ("used some")
    // To buy (plan phase 7, slice 4; ToBuy.swift): Bought adds the item and keeps its tick in one save; Not needed and
    // an own item are a tick alone. Their undos remove what they kept.
    case bought(values: [String: SQLValue], tick: ToBuyTick)
    case unbuy(row: Int64, values: [String: SQLValue], tick: ToBuyTick)
    case tick(ToBuyTick)
    case untick(ToBuyTick)
    // An undo of a cell (plan phase 7, slice 5 review): puts `value` back only while the cell still holds `expected`,
    // so a phone's change made since is never overwritten by the Mac's Edit › Undo.
    case revert(table: String, row: Int64, colId: String, value: SQLValue, expected: SQLValue)
    // Barcodes (slice 6; Barcodes.swift): a product's code linked to an item, or unlinked; a new item with its code in
    // one save.
    case linkBarcode(code: String, row: Int64)
    case unlinkBarcode(code: String, row: Int64)
    case addItem(values: [String: SQLValue], barcode: String)
    // The insurance record (slice 7; Insurance.swift), Mac only: its two columns added, a photo kept or removed, and
    // a removed one put back (undo).
    case startInsurance
    case addPhoto(row: Int64, jpeg: Data)
    case removePhoto(id: Int64, row: Int64)
    case putBackPhoto(id: Int64, row: Int64, added: String, jpeg: Data)
    // An undo of a barcode change (review, 2026-10-14): links the code to `row` (0: unlinks it) only while it still
    // names `expected` (0: none), so a phone's change made since is never overwritten.
    case moveBarcode(code: String, row: Int64, expected: Int64)
    // The street map's rally points and routes (plan phase 9; MapMarks.swift), Mac only: one added, changed (only while
    // it is still `expected`), removed (likewise), or a removed one put back at its own id (undo).
    case addMark(MapMark)
    case changeMark(MapMark, expected: MapMark)
    case removeMark(id: Int64, expected: MapMark)
    case putBackMark(MapMark)
    // The lists (plan phase 7, part 2; ListsTables.swift): one cell set (only while it is still `expected`), a row
    // added, a row removed, or a removed one put back at its place (undo).
    case listSet(sheet: String, row: ListRowRef, column: String, value: ListCell, expected: ListCell)
    case listAdd(sheet: String, cells: [String: ListCell])
    case listRemove(sheet: String, row: ListRowRef)
    case listPutBack(sheet: String, pos: Int, cells: [String: ListCell])
    // The Settings' household members (step 8a; HouseholdMembers.swift), Mac only: the whole list put in place, only
    // while it is still `expected`, so its undo never overwrites a change made since.
    case setMembers([HouseholdMember], expected: [HouseholdMember])
    // The Settings' pets (the settings redesign; HouseholdPets.swift), Mac only, the same way.
    case setPets([HouseholdPet], expected: [HouseholdPet])
    // A Used 1's undo, and that undo's (step 8c, section 4; UseLog.swift), Mac only: an Inventory row's cell put back
    // as `.revert` does, and the use log's row removed (or a removed one kept again), in one save.
    case revertUse(row: Int64, colId: String, value: SQLValue, expected: SQLValue, log: UseLogStep)
    // The Mac's Delete of several rows (B2-07, beta run 2), Mac only: all of them in one save, all or none, so one
    // Edit › Undo puts them all back (each its own change had been its own Undo step); its undo puts them back at
    // their own ids, and that undo's deletes them again.
    case deleteRows(table: String, rows: [Int64])
    // A phone's delete of an item (owner, 2026-11-18, by click: "Warn and refuse stale"): only while the item still holds
    // `cells`, the values that phone saw (the phones' copy's columns), so an item changed since is kept and listed as
    // Not saved. The Mac's own Edit › Undo never gets it (PhoneInbox keeps no undo): a phone's delete can't be undone.
    case deleteSeen(row: Int64, cells: [String: SQLValue])
    case restoreRows(table: String, rows: [DeletedRow])

    /// A row a `deleteRows` removed: its id and its cells, to put back.
    public struct DeletedRow: Codable, Equatable, Sendable {
        public let id: Int64
        public let cells: [String: SQLValue]

        public init(id: Int64, cells: [String: SQLValue]) {
            self.id = id
            self.cells = cells
        }
    }
}

/// What became of a change: done, with the change that undoes it (and an added row's id), or refused in fixed words
/// (or the ID check's own message, which never holds the text).
public enum InventoryOutcome: Equatable, Sendable {
    case done(undo: InventoryChange, row: Int64)
    case refused(String)
}

/// The editor's fixed words for a refused change.
public enum InventoryWords {
    /// The bar over an items' table while Edit Table is on (the inventory fresh look, spec 5.2).
    public static let editingTable = "Editing the table. Click a cell to change it; Return keeps it. Edit › Undo takes "
        + "a change back."

    /// Print Labels' one title, in the toolbar's Print menu and the menu bar's Inventory, saying both what it does and
    /// what will print, the sizes inside it (the inventory fresh look, spec 5.5; phase 1 fixes, finding 9; F39: it
    /// printed every place and bin, 7 pages for 69, and nothing said a selection would narrow it).
    public static func labelsItem(selected: Int) -> String {
        selected == 0 ? "Print Every Bin's Label" : "Print \(selected) Label\(selected == 1 ? "" : "s")"
    }

    /// The toolbar Print menu's own tip, one line for each item it holds: a tip on an item inside a toolbar menu never
    /// shows (phase 1 fixes round 2, finding D).
    public static func printTip(blank: Bool, labels: Bool, grab: Bool, selected: Int, place: Bool = false) -> String {
        var lines: [String] = []
        if blank { lines.append("Print Blank Sheet: an empty sheet to fill in by hand, with a key of today's places and categories") }
        if labels {
            lines.append(place ? "Labels: this place's QR label" : selected == 0 ? "Labels: a QR label for every bin (a place kept in another); select places to print only theirs"
                                       : "Labels: a QR label for each selected place")
        }
        if grab {
            lines.append(place ? "Grab Sheets: this place's page of what's in it"
                               : "Grab Sheets: the grab lists, then a page for each vehicle and each bin of what's in it"
                                 + (selected == 0 ? "" : " (each selected place)"))
        }
        return lines.joined(separator: "\n")
    }

    /// The sidebars' two lists of places, on the Mac and the phone (step 8a; owner, 2026-10-19: "Places and bins"
    /// becomes Locations, and vehicles get their own section).
    public static let locations = "Locations", vehicles = "Vehicles"

    public static let inUse = "Still in use, so it can't be deleted: %@. Move or delete those first."
    public static let loop = "A bin can't be kept inside itself or inside one of its own bins."
    public static let notEditable = "This column can't be changed here."
    public static let noRow = "That row is no longer there."
    /// An item's place or category the Mac no longer has (a phone's pick from before it was removed; 2026-10-23).
    public static let notThere = "That place or category isn't on the Mac any more. Pick another."
    /// A phone's change made from a copy of the inventory newer than this file (offline fixes, task 1.4)
    public static let restoredSince = "The Mac was set up from an older copy of the inventory, so this change wasn't "
        + "kept. Look at the item and change it again if you still need to."
    /// The Mac's New item, Add and Next (entry fixes plan, Task 2.1, 2026-10-23): ⌘Return keeps the item and starts the
    /// next with its place, category and unit.
    public static let addAndNext = "Add and Next"
    public static let addAnother = "Add Another"  // the phone's, Task 2.2
    public static let doneAdding = "Done"  // beside it on the phone's bar: adds and closes (owner, 2026-10-23)
    public static func addedTypeNext(_ name: String) -> String { "Added \(name). Type the next." }
    // Look-alikes and Counts as (entry fixes plan, Task 1.3, 2026-10-23)
    public static let samePlace = "There's already a place called %@ there."
    public static let sameCategory = "There's already a category called %@."
    public static let noPlaceName = "Give it a name."
    public static let countsAsChoices = "Counts as must be one of: %@."
    public static let notANumber = "This item's quantity isn't a number, so it can't go up or down; change it by hand."
    public static let noQuantity = "The inventory has no Quantity column."
    public static let notAddable = "Rows can't be added to or deleted from Settings here."
    public static let counted = "The lists have already counted this, so it can't be undone here; change it in the "
        + "inventory or the lists."
    public static let tooLong = "Keep an item's words, unit and why under 300 characters each."
    public static let changedSince = "This has changed since (on a phone, perhaps), so Undo leaves it as it is now."
    public static let alreadySent = "This was already sent."
    public static let notABarcode = "That isn't a product's barcode (8, 12, 13 or 14 digits with a good check digit)."
    /// B2-07 (beta run 2): a new item is kept only once it has a name (the Mac's Add had saved an empty row at once).
    public static let noName = "Give the item a name."

    /// B2-07: the Mac asks before deleting more than one row (one is deleted at once, as before, with Edit › Undo).
    public static func deleteAsk(_ count: Int, table: String) -> String {
        "\(deleteMenu(count, table: table))? Edit › Undo brings them back."
    }

    /// The table's context menu for more than one row, in the question's words ("Delete 3 items"; R4.1's review).
    public static func deleteMenu(_ count: Int, table: String) -> String {
        "Delete \(count) \(table == "Inventory" ? "items" : "rows")"
    }

    // Remove Empty Places (owner, 2026-10-23, by click)
    public static let removeEmptyTitle = "Remove Empty Places"
    public static let removeEmptyWhy = "These places hold no items, in them or in a bin inside them. Untick any to "
        + "keep, like a vehicle or a bin that already has a label. Edit › Undo brings them back."
    public static let noEmptyPlaces = "Every place holds at least one item."
    public static let staysForBin = "Stays: a place inside it stays."
    public static func removeEmptyButton(_ count: Int) -> String {
        count == 1 ? "Remove 1 Place" : "Remove \(count) Places"
    }
}

extension InventoryChange {
    /// The Mac item form's Cancel (owner, 2026-10-22): each cell the form saved goes back to what it held as the form
    /// opened, and only while it still holds what the form saved, so a change made since by anyone else (a phone's
    /// Used 1) stays (the audit, 2026-10-22, finding 1: Cancel had put back every cell that differed).
    public static func cancelForm(row: Int64, opened: [String: SQLValue], saved: [String: SQLValue]) -> [InventoryChange] {
        saved.keys.sorted().compactMap { colId in
            let was = opened[colId] ?? .null, mine = saved[colId] ?? .null
            return was == mine ? nil : .revert(table: "Inventory", row: row, colId: colId, value: was, expected: mine)
        }
    }
}

/// Every change to the inventory file goes through here (plan phase 7): the ID check first (TextChecking: on the Mac,
/// the lists job's own rules through Python), then the rules (a location or category in use isn't deleted; a bin isn't
/// kept inside itself; a quantity never goes below 0, which the lists job would refuse), then one write. Changes run
/// one at a time, in the order they were asked for. A check that can't run throws CheckUnavailable: nothing is kept.
@MainActor
public final class InventoryEditor {
    public let file: InventoryFile
    let checker: TextChecking
    public private(set) var inventory: Inventory
    private var last: Task<Void, Never>?
    /// What the Mac knows of event mode (EventModeFile.start), set by the app before it applies changes: a Used 1 is
    /// logged unless it's off (step 8c, section 4; UseLog.swift).
    public var useLogStart: UseLog.Start = .unknown
    /// The lists job's shares (supply.json) as they stand, set by the app with `useLogStart`: a Used 1 is valued from
    /// them when it's applied (UseLog.value), never later.
    public var useLogShares: SupplyShares?
    /// The change being planned's tap time: a phone's own (PhoneTag.at), else now.
    private var tapAt = Date()
    /// The change being planned's phone, or nil for the Mac's own (a use's change id; a 1 more's cancel, B2-08).
    private var tapPhone: PhoneTag?

    public init(file: InventoryFile, checker: TextChecking) throws {
        self.file = file
        self.checker = checker
        if !file.readOnly { _ = try? file.dropLeftovers() }  // no undo outlives the editor
        inventory = try Inventory(file: file)
    }

    /// Re-read the file (after another of the app's windows changed it, or a file was put back).
    public func reload() throws {
        try file.reload()
        inventory = try Inventory(file: file)
    }

    /// A phone's edit (slice 5): its id and the phone's label. Its outcome is recorded in the file in the same save as
    /// the change, and an id already recorded gets that outcome again with nothing changed, so an edit is applied once
    /// whatever happens between (PhoneInbox).
    public struct PhoneTag: Sendable {
        public let id: String
        public let phone: String
        public let at: Date?  // when it was made on the phone (PhoneEdit.at), for the use log
        /// PhoneEdit.correction (B2-08): the item screen's 1 more, or quick add's 1 less
        public let correction: Bool
        /// What the phone had in view as it was made (S4.4): the copy it showed (PhoneEdit.seen), else its tap time;
        /// nil with neither. Kept for a change to an item's cells, for PhoneInventory.AlsoChanged.
        public let seen: Date?
        /// The Mac's copy the phone showed (PhoneEdit.seen) alone, never its tap time: for the restored-Mac guard
        public let copy: Date?
        /// The phone's pairing label as the service named its inbox file ("phone1"), kept on a mark it adds so the
        /// Mac can show the owner's name for that phone (MapMark.makerName); "" when it isn't known.
        public let label: String

        public init(id: String, phone: String, at: Date? = nil, correction: Bool = false, seen: Date? = nil,
                    copy: Date? = nil, label: String = "") {
            self.label = label
            self.id = id
            self.phone = phone
            self.at = at
            self.correction = correction
            self.seen = seen
            self.copy = copy
        }
    }

    /// `rule`: a refusal read against the inventory as it is when the change's turn comes (a phone's rules), or nil.
    public func apply(_ change: InventoryChange, phone: PhoneTag? = nil,
                      rule: (@MainActor (Inventory) -> String?)? = nil) async throws -> InventoryOutcome {
        let before = last
        let task = Task { @MainActor () -> Result<InventoryOutcome, Error> in
            await before?.value
            do { return .success(try await applyNow(change, phone: phone, rule: rule)) } catch { return .failure(error) }
        }
        last = Task { _ = await task.value }
        return try await task.value.get()
    }

    /// The lists job's rewrite (ListsTables.swift), taken in at its turn behind the changes already asked for, so it
    /// never lands between a change's check and its write; true when taken in.
    @discardableResult
    public func takeIn(_ payload: ListsPayload) async throws -> Bool {
        let before = last
        let task = Task { @MainActor () -> Result<Bool, Error> in
            await before?.value
            do {
                try reload()
                let done = try file.takeIn(payload)
                if done { try? reload() }
                return .success(done)
            } catch {
                return .failure(error)
            }
        }
        last = Task { _ = await task.value }
        return try await task.value.get()
    }

    /// One write, once the rules have passed: what it changes, and the rows the ID check reads.
    private enum Write {
        case set(InventoryTable, row: Int64, InventoryColumn, SQLValue, shown: String?)
        case add(InventoryTable, cells: [String: SQLValue])
        case delete(InventoryTable, row: Int64)
        case restore(InventoryTable, row: Int64, cells: [String: SQLValue])
        case deleteRows(InventoryTable, rows: [Int64])
        case restoreRows(InventoryTable, rows: [InventoryChange.DeletedRow])
        case bought(InventoryTable, cells: [String: SQLValue], values: [String: SQLValue], tick: ToBuyTick)
        case unbuy(InventoryTable, row: Int64, values: [String: SQLValue], tick: ToBuyTick)
        case tick(ToBuyTick)
        case untick(ToBuyTick)
        case link(code: String, row: Int64)
        case unlink(code: String)
        case addItem(InventoryTable, cells: [String: SQLValue], code: String)
        case startInsurance
        case addPhoto(item: Int64, jpeg: Data, id: Int64?, added: String?)
        case removePhoto(id: Int64)
        case addMark(MapMark, keepID: Bool)
        case noMark(Int64)  // an add of a mark already here (its row): done, nothing written
        case changeMark(MapMark)
        case removeMark(Int64)
        case listRow(sheet: String, pos: Int, cells: [String: ListCell], ref: ListRowRef, column: String,
                     old: ListCell)
        case listAdd(sheet: String, cells: [String: ListCell], pos: Int?)
        case listRemove(sheet: String, pos: Int)
        case members([HouseholdMember])
        case pets([HouseholdPet])
        case use(InventoryTable, row: Int64, InventoryColumn, SQLValue, shown: String?, step: UseLogStep, keepFrom: Date?,
                 edit: String? = nil)
    }

    private enum Planned {
        case refused(String)
        case write(Write, name: String, check: [CheckRow])
    }

    /// The rules (from the file as it is now), then the change on a throwaway copy that the lists job's own reader must
    /// read whole (with the changed row's ID check), then the one real write. A failed re-read afterwards doesn't undo
    /// a write that happened: the outcome is still done, and the next change reads the file again.
    private func applyNow(_ change: InventoryChange, phone: PhoneTag?, rule: (@MainActor (Inventory) -> String?)?)
        async throws -> InventoryOutcome {
        try reload()
        if let phone, let known = try file.phoneEditResult(phone.id) {  // applied (or refused) once already
            return known.refused.map { .refused($0) } ?? .done(undo: change, row: known.row ?? 0)
        }
        func refuse(_ why: String) throws -> InventoryOutcome {
            if let phone { try file.recordPhoneEdit(phone, refused: why, row: nil) }
            return .refused(why)
        }
        // made from a copy this file's Mac never wrote: a newer file's, since replaced by an older backup (task 1.4)
        if let copy = phone?.copy, try file.copyUnknown(copy) { return try refuse(InventoryWords.restoredSince) }
        if let rule, let why = rule(inventory) { return try refuse(why) }
        var photoText: String?
        switch change {
        case .addPhoto(_, let jpeg), .putBackPhoto(_, _, _, let jpeg):  // its text, for the ID check
            guard PhotoText.isJPEG(jpeg) else { return try refuse(InventoryWords.notAPhoto) }
            guard let text = await PhotoText.read(jpeg) else { return try refuse(InventoryWords.unreadablePhoto) }
            photoText = text
        default:
            break
        }
        tapAt = phone?.at ?? Date()
        tapPhone = phone
        let planned = plan(change, ticks: (try? file.ticks().map(\.id)) ?? [], photoText: photoText ?? "")
        guard case .write(let write, let name, let rows) = planned else {
            if case .refused(let why) = planned { return try refuse(why) }
            return try refuse(InventoryWords.notEditable)
        }
        let trial = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-trial-\(UUID())")
        try FileManager.default.createDirectory(at: trial, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trial) }
        let copy = trial.appendingPathComponent(file.url.lastPathComponent)  // the reader names the file by its name
        try file.copy(to: copy)
        _ = try perform(write, on: try InventoryFile(url: copy))
        if let refused = try await checker.check(rows, file: copy).refusal { return try refuse(refused) }
        let (undo, row) = try file.inTransaction {  // the change and a phone's record of it, together or not at all
            let done = try perform(write, on: file)
            if let phone {
                try file.recordPhoneEdit(phone, refused: nil, row: done.1, item: PhoneEdit.item(of: change))
                // a phone's delete, kept for the Mac's Put back (owner, 2026-11-12)
                if case .removeMark(let id, let expected) = change, let old = found(id, expected) {
                    try file.keepDeletedMark(old, edit: phone.id)
                }
            }
            return done
        }
        try? reload()
        return .done(undo: undo(name), row: row)
    }

    /// Whether any of an item's `values` names a place or category that isn't a row (2026-10-23), so an item is never
    /// filed nowhere; 0, "none yet", is fine.
    func pointsNowhere(_ values: [String: SQLValue]) -> Bool {
        values.contains { colId, value in
            guard let column = inventory.items.columns.first(where: { $0.colId == colId }),
                  case .reference(let target) = column.kind, let id = value.whole, id != 0 else { return false }
            return !inventory.rows(target).contains { $0.id == id }
        }
    }

    /// A place or category row as it would be (Task 1.3, 2026-10-23): a blank name, a name a place kept in the same
    /// spot or another category already has (folded as the phones fold, so a curly quote matches), or a Counts as the
    /// lists don't have; nil when fine, and for any other table. `id`: the row's own, nil for a new one.
    /// `checkName` false: only the Counts as is checked (a change to it, or a blank row's Kept in; the final review, 5).
    func nameProblem(_ name: String, id: Int64?, values: [String: SQLValue], checkName: Bool = true) -> String? {
        let table = inventory.table(name)
        guard name == "Locations" || name == "Categories", let nameColumn = table.column(Inventory.Label.name) else {
            return nil
        }
        let typed = InventoryValues.plain(values[nameColumn.colId] ?? .null)
        // a table's bare Add makes a blank row to type the name into (B2-07), so only a name given or changed is checked
        let given = checkName && (id != nil || values[nameColumn.colId] != nil)
        if name == "Locations" {
            let keptIn = table.column(Inventory.Label.keptIn).flatMap { values[$0.colId]?.whole } ?? 0
            let others = inventory.locationRows.filter { $0.id != id }
                .map { (id: $0.id, name: inventory.name(ofLocation: $0.id), keptIn: inventory.keptIn($0.id)) }
            return given ? PickLists.placeProblem(name: typed, keptIn: keptIn, among: others) : nil
        }
        if given, let why = PickLists.categoryProblem(
            name: typed, among: inventory.categoryRows.filter { $0.id != id }.map { InventoryValues.plain($0[nameColumn]) }) {
            return why
        }
        if let column = table.column(Inventory.Label.countsAs),
           !InventoryValues.plain(values[column.colId] ?? .null).trimmingCharacters(in: .whitespaces).isEmpty,
           !ToBuyList.groups.contains(where: { InventoryFile.same($0, InventoryValues.plain(values[column.colId]!)) }) {
            return String(format: InventoryWords.countsAsChoices, ToBuyList.groups.map(InventoryLook.title).joined(separator: ", "))
        }
        return nil
    }

    /// A Counts as typed in any case, as the lists spell it ("food" is "Food"; Task 1.3); any other cell as given.
    func spelled(_ name: String, _ colId: String, _ value: SQLValue) -> SQLValue {
        guard name == "Categories", inventory.categories.column(Inventory.Label.countsAs)?.colId == colId,
              case .text(let typed) = value,
              let group = ToBuyList.groups.first(where: { InventoryFile.same($0, typed) }) else { return value }
        return .text(group)
    }

    /// An Item cell with no name in it: empty, spaces only, or none.
    static func blank(_ value: SQLValue) -> Bool {
        InventoryValues.plain(value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `ticks`: the ids of the To buy ticks still in the file (the lists drop none; the app drops those they counted).
    /// `undoing`: a revert's own set, which puts back what was there (an item's name it had none of included).
    private func plan(_ change: InventoryChange, ticks: [String], photoText: String = "",
                      undoing: Bool = false) -> Planned {
        switch change {
        case .set(let name, let id, let colId, let given):
            let value = spelled(name, colId, given)
            let table = inventory.table(name)
            guard let column = table.columns.first(where: { $0.colId == colId }), column.editable else {
                return .refused(InventoryWords.notEditable)
            }
            guard let row = inventory.rows(name).first(where: { $0.id == id }) else {
                return .refused(InventoryWords.noRow)
            }
            // checkpoint 2: an item's name is never blanked (the Mac's table, a phone's form); an item with none yet (a
            // barcode add named later) has none to blank, and an Undo puts back what was
            if !undoing, name == "Inventory", InventoryFile.same(column.label, Inventory.Label.item),
               Self.blank(value), !Self.blank(row[column]) {
                return .refused(InventoryWords.noName)
            }
            if name == "Inventory", pointsNowhere([colId: value]) { return .refused(InventoryWords.notThere) }
            if name == "Locations", InventoryFile.same(column.label, Inventory.Label.keptIn), let target = value.whole,
               inventory.wouldLoop(id, keptIn: target) {
                return .refused(InventoryWords.loop)
            }
            if !undoing, [Inventory.Label.name, Inventory.Label.keptIn, Inventory.Label.countsAs]
                .contains(where: { InventoryFile.same($0, column.label) }),
               let why = nameProblem(name, id: id, values: row.values.merging([colId: value]) { $1 },
                                     checkName: !InventoryFile.same(column.label, Inventory.Label.countsAs)
                                         && !(InventoryFile.same(column.label, Inventory.Label.keptIn)
                                              && Self.blank(table.column(Inventory.Label.name).map { row[$0] } ?? .null))) {
                return .refused(why)
            }
            var values = row.values
            values[colId] = value
            if let why = inventory.priceProblem(name, [colId: value]) { return .refused(why) }
            let shown = column.isReference ? InventoryValues.shown(value, in: column, names: inventory.names(for: column))
                : nil
            return .write(.set(table, row: id, column, value, shown: shown), name: name,
                          check: [inventory.checkRow(name, values: values, position: row.position)])
        case .add(let name, let given):
            guard name != "Settings" else { return .refused(InventoryWords.notAddable) }
            let values = Dictionary(uniqueKeysWithValues: given.map { ($0.key, spelled(name, $0.key, $0.value)) })
            let table = inventory.table(name)
            let known = Set(table.columns.filter(\.editable).map(\.colId))
            guard values.keys.allSatisfy(known.contains) else { return .refused(InventoryWords.notEditable) }
            if name == "Inventory", let item = table.column(Inventory.Label.item),  // B2-07: never a nameless item
               Self.blank(values[item.colId] ?? .null) {
                return .refused(InventoryWords.noName)
            }
            if name == "Inventory", pointsNowhere(values) { return .refused(InventoryWords.notThere) }
            if name == "Locations", let keptIn = table.column(Inventory.Label.keptIn),
               let target = values[keptIn.colId]?.whole, target != 0,
               !inventory.locationRows.contains(where: { $0.id == target }) {
                return .refused(InventoryWords.noRow)
            }
            if let why = nameProblem(name, id: nil, values: values) { return .refused(why) }
            if let why = inventory.priceProblem(name, values) { return .refused(why) }
            return .write(.add(table, cells: helpers(table, values)), name: name,
                          check: [inventory.checkRow(name, values: values, position: inventory.rows(name).count + 1)])
        case .delete(let name, let id):
            guard name != "Settings" else { return .refused(InventoryWords.notAddable) }
            guard inventory.rows(name).contains(where: { $0.id == id }) else { return .refused(InventoryWords.noRow) }
            let users = inventory.users(of: name, row: id)
            if !users.isEmpty {
                return .refused(String(format: InventoryWords.inUse, users.joined(separator: ", ")))
            }
            return .write(.delete(inventory.table(name), row: id), name: name, check: [])
        case .deleteSeen(let id, let cells):
            let table = inventory.items
            guard let row = inventory.itemRows.first(where: { $0.id == id }) else { return .refused(InventoryWords.noRow) }
            for column in table.columns where column.editable {  // only what the phone could see; a Mac-only field isn't
                guard let saw = cells[column.colId] else { continue }
                let now = row[column]
                guard now == saw || (now.number != nil && now.number == saw.number) else {
                    return .refused(InventoryWords.changedSince)
                }
            }
            return plan(.delete(table: "Inventory", row: id), ticks: ticks)
        case .deleteRows(let name, let ids):  // B2-07: all or none, a row in use by one not going refusing the lot
            guard name != "Settings" else { return .refused(InventoryWords.notAddable) }
            let present = Set(inventory.rows(name).map(\.id)), going = Set(ids)
            guard !ids.isEmpty, going.count == ids.count, going.isSubset(of: present) else {
                return .refused(InventoryWords.noRow)
            }
            let users = ids.flatMap { inventory.users(of: name, row: $0, besides: going) }
            if !users.isEmpty {
                return .refused(String(format: InventoryWords.inUse, users.joined(separator: ", ")))
            }
            return .write(.deleteRows(inventory.table(name), rows: ids), name: name, check: [])
        case .restoreRows(let name, let rows):
            let present = Set(inventory.rows(name).map(\.id))
            guard name != "Settings", !rows.isEmpty, !rows.contains(where: { present.contains($0.id) }) else {
                return .refused(InventoryWords.noRow)
            }
            let start = inventory.rows(name).count
            return .write(.restoreRows(inventory.table(name), rows: rows), name: name,
                          check: rows.enumerated().map { n, row in
                              inventory.checkRow(name, values: row.cells, position: start + n + 1)
                          })
        case .restore(let name, let id, let cells):
            guard !inventory.rows(name).contains(where: { $0.id == id }) else { return .refused(InventoryWords.noRow) }
            return .write(.restore(inventory.table(name), row: id, cells: cells), name: name,
                          check: [inventory.checkRow(name, values: cells, position: inventory.rows(name).count + 1)])
        case .bought(let values, let tick):
            guard tick.kind == .bought, !tick.item.isEmpty else { return .refused(InventoryWords.notEditable) }
            guard !ticks.contains(tick.id) else { return .refused(InventoryWords.alreadySent) }
            let table = inventory.items
            let known = Set(table.columns.filter(\.editable).map(\.colId))
            guard values.keys.allSatisfy(known.contains) else { return .refused(InventoryWords.notEditable) }
            if pointsNowhere(values) { return .refused(InventoryWords.notThere) }
            if let why = inventory.priceProblem("Inventory", values) { return .refused(why) }
            return .write(.bought(table, cells: helpers(table, values), values: values, tick: tick), name: "Inventory",
                          check: [inventory.checkRow("Inventory", values: values,
                                                     position: inventory.itemRows.count + 1)])
        case .unbuy(let id, let values, let tick):
            guard ticks.contains(tick.id) else { return .refused(InventoryWords.counted) }
            guard inventory.itemRows.contains(where: { $0.id == id }) else { return .refused(InventoryWords.noRow) }
            return .write(.unbuy(inventory.items, row: id, values: values, tick: tick), name: "Inventory", check: [])
        case .linkBarcode(let typed, let id):
            guard let code = Barcode.valid(typed) else { return .refused(InventoryWords.notABarcode) }
            guard inventory.itemRows.contains(where: { $0.id == id }) else { return .refused(InventoryWords.noRow) }
            return .write(.link(code: code, row: id), name: "Inventory", check: [Self.barcodeRow(code)])
        case .unlinkBarcode(let code, let id):  // only from the item it names now (0: whichever)
            guard let current = inventory.barcodes[code], id == 0 || current == id else {
                return .refused(InventoryWords.changedSince)
            }
            return .write(.unlink(code: code), name: "Inventory", check: [])
        case .moveBarcode(let code, let id, let expected):
            guard inventory.barcodes[code] ?? 0 == expected else { return .refused(InventoryWords.changedSince) }
            if id == 0 { return .write(.unlink(code: code), name: "Inventory", check: []) }
            guard inventory.itemRows.contains(where: { $0.id == id }) else { return .refused(InventoryWords.noRow) }
            return .write(.link(code: code, row: id), name: "Inventory", check: [Self.barcodeRow(code)])
        case .addItem(let values, let typed):
            guard let code = Barcode.valid(typed) else { return .refused(InventoryWords.notABarcode) }
            let table = inventory.items
            let known = Set(table.columns.filter(\.editable).map(\.colId))
            guard values.keys.allSatisfy(known.contains) else { return .refused(InventoryWords.notEditable) }
            if let why = inventory.priceProblem("Inventory", values) { return .refused(why) }
            return .write(.addItem(table, cells: helpers(table, values), code: code), name: "Inventory",
                          check: [inventory.checkRow("Inventory", values: values,
                                                     position: inventory.itemRows.count + 1), Self.barcodeRow(code)])
        case .startInsurance:
            return .write(.startInsurance, name: "Inventory", check: [])
        case .addPhoto(let id, let jpeg):
            guard let row = inventory.itemRows.first(where: { $0.id == id }) else { return .refused(InventoryWords.noRow) }
            let counts = (try? file.photoCounts()) ?? (byItem: [:], bytes: 0)
            guard counts.byItem[id, default: 0] < Insurance.photosPerItem else {
                return .refused(InventoryWords.tooManyPhotos)
            }
            guard counts.bytes + jpeg.count <= Insurance.allPhotos else { return .refused(InventoryWords.photosFull) }
            return .write(.addPhoto(item: id, jpeg: jpeg, id: nil, added: nil), name: "Inventory",
                          check: [Self.photoRow(photoText, position: row.position)])
        case .putBackPhoto(let photo, let id, let added, let jpeg):
            guard let row = inventory.itemRows.first(where: { $0.id == id }) else { return .refused(InventoryWords.noRow) }
            guard (try? file.photo(photo)) == .some(nil) else { return .refused(InventoryWords.changedSince) }
            return .write(.addPhoto(item: id, jpeg: jpeg, id: photo, added: added), name: "Inventory",
                          check: [Self.photoRow(photoText, position: row.position)])
        case .removePhoto(let id, let item):  // only from the item it belongs to
            guard (try? file.photo(id))??.item == item else { return .refused(InventoryWords.changedSince) }
            return .write(.removePhoto(id: id), name: "Inventory", check: [])
        case .addMark(let mark), .putBackMark(let mark):
            var kept = mark.rounded
            let all = inventory.marks + inventory.pins
            let putBack: Bool = if case .putBackMark = change { true } else { false }
            if !putBack {  // who made it and when are the editor's to say, never the sender's (a Put back keeps its own)
                if kept.kind == .pin, kept.uid == nil { kept.uid = UUID().uuidString.lowercased() }
                kept.uid = kept.uid?.lowercased()
                (kept.made, kept.by, kept.byLabel, kept.byName) = (nil, nil, nil, nil)
                if kept.uid != nil {
                    kept.made = Self.madeText(tapAt)
                    kept.by = tapPhone.map(\.phone) ?? MapMark.byMac
                    kept.byLabel = tapPhone.flatMap { $0.label.isEmpty ? nil : $0.label }
                }
            }
            if let why = kept.problem { return .refused(why) }
            if let uid = kept.uid, !putBack {
                // the same mark again (a shared file, then the Mac): done, adding nothing
                if let here = all.first(where: { $0.uid == uid }) { return .write(.noMark(here.id), name: "Map", check: []) }
                // a phone's late copy of one a phone deleted (kept 30 days): never back by itself, and said so
                if tapPhone != nil, inventory.deletedMarks.contains(where: { $0.mark.uid == uid }) {
                    return .refused(MapMarkWords.deletedSince)
                }
            }
            if kept.kind == .pin {
                guard inventory.pins.count < MapMark.pinLimit else { return .refused(MapMarkWords.pinsFull) }
            } else {
                guard inventory.marks.count < MapMark.markLimit else { return .refused(MapMarkWords.full) }
            }
            if Self.secondStart(kept, in: inventory.marks) { return .refused(MapMarkWords.oneStart) }
            if putBack, all.contains(where: { $0.id == mark.id }) { return .refused(InventoryWords.changedSince) }
            return .write(.addMark(kept, keepID: putBack), name: "Map", check: [Self.markRow(kept)])
        case .changeMark(let mark, let expected):
            guard let current = found(mark.id, expected) else { return .refused(InventoryWords.noRow) }
            guard current.content == expected.content.with(id: current.id) else {
                return .refused(InventoryWords.changedSince)
            }
            var kept = mark.rounded
            (kept.id, kept.uid, kept.made, kept.by) = (current.id, current.uid, current.made, current.by)
            (kept.byLabel, kept.byName) = (current.byLabel, nil)
            if let why = kept.problem { return .refused(why) }
            if Self.secondStart(kept, in: inventory.marks) { return .refused(MapMarkWords.oneStart) }
            return .write(.changeMark(kept), name: "Map", check: [Self.markRow(kept)])
        case .removeMark(let id, let expected):
            guard let current = found(id, expected) else {
                // a phone's delete of one already gone (another phone's, or the Mac's) is done, changing nothing
                return tapPhone == nil ? .refused(InventoryWords.noRow) : .write(.removeMark(id), name: "Map", check: [])
            }
            guard current.content == expected.content.with(id: current.id) else {
                return .refused(InventoryWords.changedSince)
            }
            return .write(.removeMark(current.id), name: "Map", check: [])
        case .listSet(let sheet, let ref, let column, let value, let expected):
            guard let lists = inventory.lists else { return .refused(ListsWords.notThere) }
            guard let row = lists.find(ref, in: sheet) else { return .refused(InventoryWords.noRow) }
            guard ListsLayout.editable(sheet, column: column, row: row) else { return .refused(ListsWords.notEditable) }
            guard row[column] == expected else { return .refused(InventoryWords.changedSince) }
            if let why = Self.listValueProblem(sheet, column: column, row: row, value: value) { return .refused(why) }
            var cells = row.cells
            cells[column] = value
            return .write(.listRow(sheet: sheet, pos: row.pos, cells: cells, ref: ListRowRef(row), column: column,
                                   old: expected), name: sheet, check: [])
        case .listAdd(let sheet, let cells):
            guard let lists = inventory.lists else { return .refused(ListsWords.notThere) }
            guard ListsLayout.addable.contains(sheet) else { return .refused(InventoryWords.notAddable) }
            let blank = ListRow(pos: -1, cells: [:])
            for (column, value) in cells {
                guard ListsLayout.editable(sheet, column: column, row: blank) else {
                    return .refused(ListsWords.notEditable)
                }
                if let why = Self.listValueProblem(sheet, column: column, row: blank, value: value) {
                    return .refused(why)
                }
            }
            _ = lists
            return .write(.listAdd(sheet: sheet, cells: cells, pos: nil), name: sheet, check: [])
        case .listRemove(let sheet, let ref):
            guard let lists = inventory.lists else { return .refused(ListsWords.notThere) }
            guard let row = lists.find(ref, in: sheet) else { return .refused(InventoryWords.noRow) }
            guard ListsLayout.removable(sheet, row: row) else { return .refused(InventoryWords.notAddable) }
            return .write(.listRemove(sheet: sheet, pos: row.pos), name: sheet, check: [])
        case .listPutBack(let sheet, let pos, let cells):
            guard let lists = inventory.lists else { return .refused(ListsWords.notThere) }
            guard !lists.rows(sheet).contains(where: { $0.pos == pos }) else {
                return .refused(InventoryWords.changedSince)
            }
            let id = cells["ID"]?.text ?? ""
            if !id.isEmpty, lists.rows(sheet).contains(where: { $0.id == id }) {
                return .refused(InventoryWords.changedSince)
            }
            return .write(.listAdd(sheet: sheet, cells: cells, pos: pos), name: sheet, check: [])
        case .setMembers(let members, let expected):
            guard !inventory.membersUnreadable else { return .refused(HouseholdMembers.unreadable) }
            guard inventory.members == expected else { return .refused(InventoryWords.changedSince) }
            guard members.count <= HouseholdMembers.most else { return .refused(HouseholdMembers.tooMany) }
            if let why = members.lazy.compactMap(HouseholdMembers.problem).first { return .refused(why) }
            // its choices are the table's own words, never typed text, so no row goes to the ID check; the lists
            // job's reader still reads the changed copy whole
            return .write(.members(members), name: "Settings", check: [])
        case .setPets(let pets, let expected):
            guard !inventory.petsUnreadable else { return .refused(HouseholdPets.unreadable) }
            guard inventory.pets == expected else { return .refused(InventoryWords.changedSince) }
            guard pets.count <= HouseholdPets.most else { return .refused(HouseholdPets.tooMany) }
            if let why = pets.lazy.compactMap(HouseholdPets.problem).first { return .refused(why) }
            let kept = pets.map(HouseholdPets.normalized)
            // the names are typed and reach the phones, so each goes through the ID check as the inventory's words do
            return .write(.pets(kept), name: "Settings", check: kept.enumerated().map { Self.petRow($1, position: $0 + 1) })
        case .revert(let name, let id, let colId, let value, let expected):
            let table = inventory.table(name)
            guard let column = table.columns.first(where: { $0.colId == colId }), column.editable,
                  let row = inventory.rows(name).first(where: { $0.id == id }) else {
                return .refused(InventoryWords.noRow)
            }
            guard row[column] == expected || (row[column].number != nil && row[column].number == expected.number) else {
                return .refused(InventoryWords.changedSince)
            }
            return plan(.set(table: name, row: id, colId: colId, value: value), ticks: ticks, undoing: true)
        case .tick(let tick):
            guard tick.kind != .bought else { return .refused(InventoryWords.notEditable) }
            guard !ticks.contains(tick.id) else { return .refused(InventoryWords.alreadySent) }
            guard [tick.text, tick.unit, tick.why, tick.category].allSatisfy({ $0.count <= ToBuyTick.textLimit }) else {
                return .refused(InventoryWords.tooLong)
            }
            let check = tick.kind == .add ? [Self.ownItemRow(tick)] : []
            return .write(.tick(tick), name: "Inventory", check: check)
        case .untick(let tick):
            guard ticks.contains(tick.id) else { return .refused(InventoryWords.counted) }
            return .write(.untick(tick), name: "Inventory", check: [])
        case .adjust(let id, let by):
            guard let column = inventory.items.column(Inventory.Label.quantity) else {
                return .refused(InventoryWords.noQuantity)
            }
            guard let row = inventory.itemRows.first(where: { $0.id == id }) else { return .refused(InventoryWords.noRow) }
            let current = InventoryValues.plain(row[column]).trimmingCharacters(in: .whitespaces)
            guard let found = current.isEmpty ? 0 : InventoryValues.parseNumber(current) else {
                return .refused(InventoryWords.notANumber)
            }
            let next = max(0, found + by)
            let value: SQLValue = switch column.kind {
            case .numeric: .real(next)
            case .int: .int(Int64(next.rounded()))
            default: .text(InventoryValues.number(next))
            }
            let planned = plan(.set(table: "Inventory", row: id, colId: column.colId, value: value), ticks: ticks)
            // A use (step 8c, section 4) is logged with its tap time unless event mode is off or the log unreadable
            let now = Date()
            if tapPhone?.correction == true, by < 0 { return planned }  // quick add's 1 less takes back a scan: no use
            if by == 1, next > found, let cancelled = cancelledUse(row: id, now: now),  // B2-08: a mistake put right
               case .write(.set(let table, let row, let column, let value, let shown), let name, let check) = planned {
                return .write(.use(table, row: row, column, value, shown: shown, step: .remove(cancelled.id),
                                   keepFrom: nil), name: name, check: check)
            }
            guard found - next > 0, let log = try? file.useLog(),
                  case .write(.set(let table, let row, let column, let value, let shown), let name, let check) = planned
            else { return planned }
            guard let keepFrom = UseLog.keepFrom(useLogStart, now: now) else {  // off: nothing kept, the log emptied
                return log.isEmpty ? planned
                    : .write(.use(table, row: row, column, value, shown: shown, step: .clear, keepFrom: nil), name: name,
                             check: check)
            }
            let at = min(tapAt, now)  // a phone's clock ahead of the Mac's never logs a tap in the future
            let used = found - next
            let amounts = inventory.itemRows.first { $0.id == row }.flatMap { item in
                UseLog.value(position: item.position, item: inventory.name(ofItem: item), isPrivate: inventory.isPrivate(item),
                             used: used, shares: useLogShares)
            }
            return .write(.use(table, row: row, column, value, shown: shown,
                               step: .add(at: UseLog.stamp(at), used: used, amounts: amounts), keepFrom: keepFrom,
                               edit: tapPhone?.id),
                          name: name, check: check)
        case .revertUse(let id, let colId, let value, let expected, let step):
            guard (try? file.useLog()) != nil else {
                return plan(.revert(table: "Inventory", row: id, colId: colId, value: value, expected: expected),
                            ticks: ticks)
            }
            let planned = plan(.revert(table: "Inventory", row: id, colId: colId, value: value, expected: expected),
                               ticks: ticks)
            guard case .write(.set(let table, let row, let column, let value, let shown), let name, let check) = planned
            else { return planned }
            return .write(.use(table, row: row, column, value, shown: shown, step: step, keepFrom: nil), name: name,
                          check: check)
        }
    }

    /// The use a phone's "1 more" on `row` cancels (B2-08, beta run 2), or nil. Only the item screen's 1 more cancels
    /// (marked PhoneEdit.correction; a scan's, a held one's or an older phone's is a restock), and only when, in event
    /// mode (or not yet known), the very last change that same phone made to that item, applied here, was a Used 1
    /// still in the log, tapped within `UseLog.cancelWithin` of this one by the phone's own times. The Mac's own 1 more cancels nothing (its Edit › Undo
    /// removes a mistaken Used 1), nor does one from a phone whose name isn't known.
    private func cancelledUse(row: Int64, now: Date) -> UseLog.Entry? {
        guard let phone = tapPhone, phone.correction, !phone.phone.isEmpty,
              UseLog.keepFrom(useLogStart, now: now) != nil,
              let last = try? file.lastPhoneEdit(phone: phone.phone, row: row),
              let found = try? file.use(byEdit: last), found.row == row,
              abs(min(tapAt, now).timeIntervalSince(found.at)) <= UseLog.cancelWithin else { return nil }
        return found
    }

    /// Why a list cell can't hold `value`, in fixed words, or nil: a tick is true or false, a date "YYYY-MM-DD", a
    /// number a number (or blank), a menu one of its choices (or blank); Settings' Event mode one of its three, its
    /// other values numbers. The lists' reader on the throwaway copy reads the rest (its text checks and rules).
    static func listValueProblem(_ sheet: String, column: String, row: ListRow, value: ListCell) -> String? {
        if case .text(let text) = value, text.count > ToBuyTick.textLimit * 10 { return InventoryWords.tooLong }
        if sheet == ListsLayout.settings {
            if row["Setting"].text == ListsLayout.eventMode {
                guard case .text(let choice) = value, ListsLayout.eventSwitch.contains(choice) else {
                    return ListsWords.notAChoice
                }
                return nil
            }
            switch value {
            case .number, .null: return nil
            default: return ListsWords.notANumber
            }
        }
        if ListsLayout.tickColumns.contains(column) {
            if case .bool = value { return nil }
            return ListsWords.notEditable
        }
        if ListsLayout.dateColumns.contains(column) {
            if value == .null || value.day != nil { return nil }
            return ListsWords.notADate
        }
        if ListsLayout.numberColumns.contains(column) {
            switch value {
            case .number, .null: return nil
            default: return ListsWords.notANumber
            }
        }
        let menu: [String]? = switch column {
        case "Horizon": ListsLayout.horizons
        case "Cost": ListsLayout.costs
        case "Category": ToBuyList.groups
        case "Status": ListsLayout.recallStatuses
        case "Unit" where sheet == ListsLayout.upkeep: ListsLayout.upkeepUnits
        default: nil
        }
        if let menu {
            if value == .null { return nil }
            guard case .text(let choice) = value, menu.contains(choice) else { return ListsWords.notAChoice }
        }
        switch value {
        case .text, .null: return nil
        default: return ListsWords.notEditable
        }
    }

    /// `values` with each reference's shown-text helper beside it, as set() keeps them.
    private func helpers(_ table: InventoryTable, _ values: [String: SQLValue]) -> [String: SQLValue] {
        var cells = values
        for column in table.columns where column.isReference {
            if let helper = column.displayColId, let value = values[column.colId] {
                let shown = InventoryValues.shown(value, in: column, names: inventory.names(for: column))
                cells[helper] = shown.isEmpty ? .null : .text(shown)
            }
        }
        return cells
    }

    /// A barcode through the lists job's ID check, as Model is read (long numbers allowed): a code that is also a card
    /// number's shape is refused, never kept as a barcode.
    static func barcodeRow(_ code: String) -> CheckRow {
        CheckRow(place: "Barcodes", cells: [CheckCell(label: "Barcode", text: code, longNumbersOK: true)])
    }

    /// A photo's text, read on the Mac, through the ID check as one cell with long numbers and dollar amounts allowed
    /// (a product label's or a receipt's numbers are long, and a receipt's prices are the proof: owner, 2026-10-14); an
    /// ID number's shape and a labeled account, code or PIN are still refused.
    static func photoRow(_ text: String, position: Int) -> CheckRow {
        CheckRow(place: "Inventory row \(position), a photo", cells: [
            CheckCell(label: "Photo text", text: text, longNumbersOK: true, amountsOK: true)])
    }

    /// A rally point's or route's words through the lists job's ID check, as the inventory's own words are read; its
    /// points are numbers on the map, not words, and aren't.
    /// The mark a change or a delete means: the row with its id, or, for one a phone made and has no row number
    /// for yet (id 0 or below), the one with the `uid` the phone saw.
    func found(_ id: Int64, _ expected: MapMark) -> MapMark? {
        let all = inventory.marks + inventory.pins
        if id > 0 { return all.first { $0.id == id } }
        return expected.uid.flatMap { uid in all.first { $0.uid == uid.lowercased() } }
    }

    static func madeText(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func markRow(_ mark: MapMark) -> CheckRow {
        let place = switch mark.kind {
        case .rally: "a meeting place"
        case .route: "a route"
        case .start: "the printed directions' start"
        case .pin: "a pin"
        }
        return CheckRow(place: "Map, \(place)", cells: [
            CheckCell(label: "Name", text: mark.name), CheckCell(label: "Note", text: mark.note)])
    }

    /// A Start point while another mark is the Start point: there is one at most (hand-off improvements, phase 3).
    static func secondStart(_ mark: MapMark, in marks: [MapMark]) -> Bool {
        mark.kind == .start && marks.contains { $0.kind == .start && $0.id != mark.id }
    }

    /// A pet's name through the lists job's ID check, as the inventory's own words are read; its weight is a number.
    static func petRow(_ pet: HouseholdPet, position: Int) -> CheckRow {
        CheckRow(place: "Settings, pet \(position)", cells: [CheckCell(label: HouseholdPets.name, text: pet.name)])
    }

    /// An own To buy item's cells as the lists job reads them (readiness.engine._app_own_item): Item, Need, Unit, Why.
    static func ownItemRow(_ tick: ToBuyTick) -> CheckRow {
        CheckRow(place: "To buy (PrepareMe)", cells: [
            CheckCell(label: "Item", text: tick.text),
            CheckCell(label: "Need", text: tick.need.map(InventoryValues.number) ?? ""),
            CheckCell(label: "Unit", text: tick.unit),
            CheckCell(label: "Why", text: tick.why),
        ])
    }

    /// The write on `target` (the throwaway copy or the real file): the change that undoes it, by table name, and the
    /// row it touched.
    private func perform(_ write: Write, on target: InventoryFile) throws -> ((String) -> InventoryChange, Int64) {
        switch write {
        case .set(let table, let id, let column, let value, let shown):
            let old = try target.set(table, row: id, column: column, to: value, shown: shown)
            return ({ .revert(table: $0, row: id, colId: column.colId, value: old, expected: value) }, id)
        case .add(let table, let cells):
            let id = try target.addRow(table, values: cells)
            return ({ .delete(table: $0, row: id) }, id)
        case .delete(let table, let id):
            let cells = try target.deleteRow(table, row: id)
            return ({ .restore(table: $0, row: id, cells: cells) }, id)
        case .restore(let table, let id, let cells):
            try target.restore(table, row: id, cells: cells)
            return ({ .delete(table: $0, row: id) }, id)
        case .deleteRows(let table, let ids):
            let rows = try target.inTransaction {
                try ids.map { InventoryChange.DeletedRow(id: $0, cells: try target.deleteRow(table, row: $0)) }
            }
            return ({ .restoreRows(table: $0, rows: rows) }, ids.first ?? 0)
        case .restoreRows(let table, let rows):
            try target.inTransaction {
                for row in rows { try target.restore(table, row: row.id, cells: row.cells) }
            }
            return ({ .deleteRows(table: $0, rows: rows.map(\.id)) }, rows.first?.id ?? 0)
        case .bought(let table, let cells, let values, let tick):
            let id = try target.addRow(table, values: cells, tick: tick)
            return ({ _ in .unbuy(row: id, values: values, tick: tick) }, id)
        case .unbuy(let table, let id, let values, let tick):
            try target.removeRow(table, row: id, tick: tick.id)
            return ({ _ in .bought(values: values, tick: tick) }, id)
        case .tick(let tick):
            try target.addTick(tick)
            return ({ _ in .untick(tick) }, 0)
        case .untick(let tick):
            try target.dropTicks([tick.id])
            return ({ _ in .tick(tick) }, 0)
        case .link(let code, let id):
            let before = try target.link(code, to: id)
            return ({ _ in .moveBarcode(code: code, row: before ?? 0, expected: id) }, id)
        case .unlink(let code):
            let before = try target.unlink(code)
            return ({ _ in .moveBarcode(code: code, row: before ?? 0, expected: 0) }, before ?? 0)
        case .addItem(let table, let cells, let code):
            let id = try target.inTransaction {
                let id = try target.addRow(table, values: cells)
                try target.link(code, to: id)
                return id
            }
            return ({ _ in .delete(table: "Inventory", row: id) }, id)
        case .startInsurance:
            try target.startInsuranceRecord()
            return ({ _ in .startInsurance }, 0)  // the columns stay: blank ones change nothing anyone reads
        case .addPhoto(let item, let jpeg, let id, let added):
            let kept = try target.addPhoto(item: item, jpeg: jpeg, id: id, added: added)
            return ({ _ in .removePhoto(id: kept, row: item) }, item)
        case .removePhoto(let id):
            guard let photo = try target.removePhoto(id) else { return ({ _ in .removePhoto(id: id, row: 0) }, 0) }
            return ({ _ in .putBackPhoto(id: photo.id, row: photo.item, added: photo.added, jpeg: photo.jpeg) },
                    photo.item)
        case .noMark(let id):
            return ({ _ in .removeMark(id: 0, expected: .gone) }, id)  // nothing was added, so nothing to undo
        case .addMark(let mark, let keepID):
            let id = try target.addMark(mark, keepID: keepID)
            var made = mark
            made.id = id
            return ({ _ in .removeMark(id: id, expected: made) }, id)
        case .changeMark(let mark):
            guard let old = try target.changeMark(mark) else { return ({ _ in .changeMark(mark, expected: mark) }, 0) }
            return ({ _ in .changeMark(old, expected: mark) }, mark.id)
        case .removeMark(let id):
            guard let old = try target.removeMark(id) else { return ({ _ in .removeMark(id: id, expected: .gone) }, 0) }
            return ({ _ in .putBackMark(old) }, id)
        case .listRow(let sheet, let pos, let cells, let ref, let column, let old):
            try target.setListRow(sheet, pos: pos, cells: cells)
            let after = ListRow(pos: pos, cells: cells)
            let undoRef = ref.id.isEmpty ? ListRowRef(after) : ref
            // an old recall word undoes as its new one, never refused off the menu (top-ten plan phase 6 review)
            let back: ListCell = sheet == ListsLayout.recalls && column == "Status" && old.text != ""
                ? .text(ListsLayout.recallStatus(old.text)) : old
            return ({ _ in .listSet(sheet: sheet, row: undoRef, column: column, value: back,
                                    expected: cells[column] ?? .null) }, Int64(pos))
        case .listAdd(let sheet, let cells, let pos):
            let place = try target.addListRow(sheet, cells: cells, pos: pos)
            return ({ _ in .listRemove(sheet: sheet, row: ListRowRef(ListRow(pos: place, cells: cells))) }, Int64(place))
        case .listRemove(let sheet, let pos):
            guard let old = try target.removeListRow(sheet, pos: pos) else {
                return ({ _ in .listPutBack(sheet: sheet, pos: pos, cells: [:]) }, 0)
            }
            return ({ _ in .listPutBack(sheet: sheet, pos: pos, cells: old) }, Int64(pos))
        case .members(let members):
            let old = try target.setMembers(members)
            return ({ _ in .setMembers(old, expected: members) }, 0)
        case .pets(let pets):
            let old = try target.setPets(pets)
            return ({ _ in .setPets(old, expected: pets) }, 0)
        case .use(let table, let id, let column, let value, let shown, let step, let keepFrom, let edit):
            return try target.inTransaction {  // the quantity and the use log's row, together or not at all
                let old = try target.set(table, row: id, column: column, to: value, shown: shown)
                let back: UseLogStep
                switch step {
                case .add(let at, let used, let amounts):
                    back = .remove(try target.addUse(row: id, at: at, used: used, amounts: amounts, keepFrom: keepFrom,
                                                     edit: edit))
                case .remove(let log):
                    back = try target.removeUse(log).map { .add(at: UseLog.stamp($0.at), used: $0.used,
                                                                amounts: $0.amounts) } ?? .remove(log)
                case .clear:
                    try target.clearUseLog()
                    back = .clear
                }
                return ({ _ in .revertUse(row: id, colId: column.colId, value: old, expected: value, log: back) }, id)
            }
        }
    }
}

extension SQLValue: Codable {
    enum CodingKeys: String, CodingKey { case null, int, real, text }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let found = try container.decodeIfPresent(Int64.self, forKey: .int) { self = .int(found); return }
        if let found = try container.decodeIfPresent(Double.self, forKey: .real) {
            guard found.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .real, in: container, debugDescription: "not finite")
            }
            self = .real(found)
            return
        }
        if let found = try container.decodeIfPresent(String.self, forKey: .text) { self = .text(found); return }
        if try container.decodeIfPresent(Bool.self, forKey: .null) == true { self = .null; return }
        throw DecodingError.dataCorruptedError(forKey: .null, in: container, debugDescription: "no value")
    }

    /// A blob is never sent (the inventory's cells the editor changes are never blobs).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null, .blob: try container.encode(true, forKey: .null)
        case .int(let found): try container.encode(found, forKey: .int)
        case .real(let found): try container.encode(found, forKey: .real)
        case .text(let found): try container.encode(found, forKey: .text)
        }
    }
}
