import Foundation

/// A column of one of the inventory file's tables, as `_grist_Tables_column` describes it (plan phase 7).
public struct InventoryColumn: Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case text, numeric, int, bool, date, choice
        case reference(table: String)
        case other  // a type the editor doesn't edit (ChoiceList, RefList, Attachments, DateTime, Any …): shown, kept
    }

    public let ref: Int64  // its row in _grist_Tables_column
    public let colId: String
    public let label: String
    public let type: String
    public let kind: Kind
    public let isFormula: Bool
    public let choices: [String]
    /// For a reference: the target's column it shows (its visibleCol, or the target's column labeled Name), and the
    /// helper column Grist keeps the shown text in (its displayCol), updated with it.
    public let shownColId: String?
    public let displayColId: String?

    public init(ref: Int64, colId: String, label: String, type: String, kind: Kind, isFormula: Bool, choices: [String],
                shownColId: String?, displayColId: String?) {
        self.ref = ref
        self.colId = colId
        self.label = label
        self.type = type
        self.kind = kind
        self.isFormula = isFormula
        self.choices = choices
        self.shownColId = shownColId
        self.displayColId = displayColId
    }

    public var id: String { colId }
    /// Whether the editor may change it: an owner's formula column keeps its last value, and an unknown type is kept.
    public var editable: Bool { !isFormula && kind != .other && (shownColId != nil || !isReference) }
    public var isReference: Bool { if case .reference = kind { true } else { false } }
}

/// One of the file's tables, found by name as the lists job finds it (readiness/grist.py: ignoring case and spaces).
public struct InventoryTable: Equatable, Sendable {
    public let ref: Int64
    public let tableId: String
    public let columns: [InventoryColumn]

    /// The column the owner sees as `label` (ignoring case and surrounding spaces), when exactly one has it.
    public func column(_ label: String) -> InventoryColumn? {
        let hits = columns.filter { InventoryFile.same($0.label, label) }
        return hits.count == 1 ? hits[0] : nil
    }
}

/// A row of a table: its Grist id, its place in Grist's order (manualSort, then id; from 1, as the lists job numbers
/// rows), and its stored values by colId.
public struct InventoryRow: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let position: Int
    public let manualSort: SQLValue
    public let values: [String: SQLValue]

    /// Also a row not yet in the file: the Mac's new-item form's draft (B2-07), id 0.
    public init(id: Int64, position: Int, manualSort: SQLValue = .null, values: [String: SQLValue]) {
        self.id = id
        self.position = position
        self.manualSort = manualSort
        self.values = values
    }

    public subscript(_ column: InventoryColumn) -> SQLValue { values[column.colId] ?? .null }
}

public enum InventoryFileError: Error, Equatable, CustomStringConvertible, Sendable {
    case notAnInventory  // no _grist_Tables or _grist_Tables_column
    case noTable(String)
    case twoTables(String)
    case noRow
    case readOnly

    public var description: String {
        switch self {
        case .notAnInventory: "This file isn't an inventory in the lists' layout."
        case .noTable(let name): "The inventory has no \(name) table."
        case .twoTables(let name): "The inventory has two \(name) tables."
        case .noRow: "That row is no longer there."
        case .readOnly: "The inventory was opened read-only."
        }
    }
}

/// The inventory file (plan phase 7): an SQLite file in the layout the lists job reads (readiness/grist.py), the
/// tables Inventory, Locations, Categories and Settings described by `_grist_Tables` and `_grist_Tables_column`. The Mac
/// app is its only writer. It changes only the data tables' rows and, once, the columns the app adds (`ensureColumn`):
/// Grist's own history and view tables are left as they are, and any table the owner added is never touched.
public final class InventoryFile {
    public static let tableNames = ["Inventory", "Locations", "Categories", "Settings"]
    static let gristColumns: Set<String> = ["id", "manualsort"]  // never shown, with any gristHelper_ column

    public let url: URL
    public let readOnly: Bool
    let db: SQLite  // the tick table (ToBuy.swift) shares the connection
    public private(set) var tables: [String: InventoryTable] = [:]

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        self.readOnly = readOnly
        db = try SQLite(path: url, readOnly: readOnly)
        if !readOnly {
            // One file, as the lists job's snapshot expects (grist.snapshot), and every commit forced to the disk
            // itself: on macOS only F_FULLFSYNC empties the drive's cache (fullfsync; packer/durable.py, F-016).
            try db.execute("PRAGMA journal_mode = DELETE")
            try db.execute("PRAGMA synchronous = FULL")
            try db.execute("PRAGMA fullfsync = ON")
            try db.execute("PRAGMA checkpoint_fullfsync = ON")
        }
        try reload()
    }

    /// SQLite's count of what other connections committed: unchanged means nothing outside this one wrote the file.
    public func dataVersion() throws -> Int64 { try db.query("PRAGMA data_version").first?.first?.whole ?? 0 }

    /// Re-read the tables' descriptions (after the app added a column, or to pick up a file put back).
    public func reload() throws {
        let found = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { Self.text($0[0]) })
        guard found.isSuperset(of: ["_grist_Tables", "_grist_Tables_column"]) else {
            throw InventoryFileError.notAnInventory
        }
        let listed = try db.query("SELECT id, tableId FROM _grist_Tables ORDER BY id")
            .compactMap { row -> (Int64, String)? in
                guard let ref = row[0].whole, let tableId = Self.text(row[1]) else { return nil }
                return (ref, tableId)
            }
        var tables: [String: InventoryTable] = [:]
        for name in Self.tableNames {
            let hits = listed.filter { Self.same($0.1, name) }
            guard !hits.isEmpty else { throw InventoryFileError.noTable(name) }
            guard hits.count == 1 else { throw InventoryFileError.twoTables(name) }
            tables[name] = InventoryTable(ref: hits[0].0, tableId: hits[0].1,
                                          columns: try columns(of: hits[0].0, listed: listed))
        }
        self.tables = tables
    }

    public func table(_ name: String) throws -> InventoryTable {
        guard let found = tables[name] else { throw InventoryFileError.noTable(name) }
        return found
    }

    /// The table's rows in Grist's order (manualSort, then id).
    public func rows(_ table: InventoryTable) throws -> [InventoryRow] {
        let stored = Set(try db.query("PRAGMA table_info(\(SQLite.quoted(table.tableId)))").compactMap { Self.text($0[1]) })
        let wanted = table.columns.map(\.colId).filter(stored.contains)
            + table.columns.compactMap(\.displayColId).filter(stored.contains)
        let hasSort = stored.contains("manualSort")
        let selected = (["id", hasSort ? "manualSort" : "NULL"] + wanted.map(SQLite.quoted)).joined(separator: ", ")
        let order = hasSort ? "manualSort, id" : "id"
        return try db.query("SELECT \(selected) FROM \(SQLite.quoted(table.tableId)) ORDER BY \(order)")
            .enumerated().compactMap { n, cells in
                guard let id = cells[0].whole else { return nil }
                var values: [String: SQLValue] = [:]
                for (colId, cell) in zip(wanted, cells.dropFirst(2)) { values[colId] = cell }
                return InventoryRow(id: id, position: n + 1, manualSort: cells[1], values: values)
            }
    }

    /// Each row's shown text for a reference to `table` through `colId`: {row id: the cell as text}.
    public func shownNames(_ table: InventoryTable, colId: String) throws -> [Int64: String] {
        var names: [Int64: String] = [:]
        for row in try rows(table) {
            names[row.id] = InventoryValues.plain(row.values[colId] ?? .null)
        }
        return names
    }

    /// `body`'s writes in one transaction (each write method inside it is a savepoint of it).
    public func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try db.transaction(body)
    }

    /// A whole copy of the file at `path`, as it stands (InventoryEditor's throwaway copy for the lists job's reader).
    public func copy(to path: URL) throws {
        try db.backup(to: path)
    }

    // MARK: Writing (the app only)

    /// Set one cell, and a reference's shown-text helper with it; the value it held before (for undo).
    @discardableResult
    public func set(_ table: InventoryTable, row: Int64, column: InventoryColumn, to value: SQLValue,
                    shown: String? = nil) throws -> SQLValue {
        guard !readOnly else { throw InventoryFileError.readOnly }
        return try db.transaction {
            let quotedTable = SQLite.quoted(table.tableId)
            let before = try db.query("SELECT \(SQLite.quoted(column.colId)) FROM \(quotedTable) WHERE id = ?",
                                      [.int(row)])
            guard let old = before.first?.first else { throw InventoryFileError.noRow }
            try db.execute("UPDATE \(quotedTable) SET \(SQLite.quoted(column.colId)) = ? WHERE id = ?", [value, .int(row)])
            if let helper = column.displayColId, try hasColumn(table, helper) {
                try db.execute("UPDATE \(quotedTable) SET \(SQLite.quoted(helper)) = ? WHERE id = ?",
                               [shown.map { .text($0) } ?? .null, .int(row)])
            }
            return old
        }
    }

    /// Add a row at the end of Grist's order, the rest of its cells at their columns' defaults (Grist's blanks: "" for
    /// text, 0 for numbers and references, NULL for a date); its id.
    @discardableResult
    public func addRow(_ table: InventoryTable, values: [String: SQLValue] = [:]) throws -> Int64 {
        guard !readOnly else { throw InventoryFileError.readOnly }
        return try db.transaction { try insertRow(table, values: values) }
    }

    /// addRow's insert, inside the caller's transaction.
    func insertRow(_ table: InventoryTable, values: [String: SQLValue]) throws -> Int64 {
        guard !readOnly else { throw InventoryFileError.readOnly }
        let quotedTable = SQLite.quoted(table.tableId)
        var id = (try db.query("SELECT max(id) FROM \(quotedTable)").first?.first?.whole ?? 0) + 1
        if Self.numberedForGood.contains(table.tableId) { id = max(id, try lastIssued(table) + 1) }
        var cells = values
        if try hasColumn(table, "manualSort") {
            let last = try db.query("SELECT max(manualSort) FROM \(quotedTable) WHERE manualSort < 1e300")
            cells["manualSort"] = .real((last.first?.first?.number ?? 0).rounded(.down) + 1)
        }
        try insert(table, id: id, cells: cells)
        if table.tableId == "Inventory" { try forgetItem(id) }  // a deleted last item's number comes back
        if Self.numberedForGood.contains(table.tableId) { try noteIssued(table, id) }
        return id
    }

    /// A place's or category's number is never handed out twice (2026-10-23): a printed bin label
    /// (prepareme://place/<id>) and a phone's Quick add name them by it, so a deleted one's number coming back would
    /// file items in the wrong place.
    /// Items too (Task 1.9, 2026-10-23): a phone's late Used 1 or edit for a deleted item never lands on a new one.
    static let numberedForGood: Set<String> = ["Locations", "Categories", "Inventory"]
    static let issuedTable = "PrepareMe_Issued"

    /// The highest number `table` has handed out, as far as this file has kept it (0 before the first time).
    func lastIssued(_ table: InventoryTable) throws -> Int64 {
        guard try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                            [.text(Self.issuedTable)]).isEmpty else { return 0 }
        return try db.query("SELECT last FROM \"\(Self.issuedTable)\" WHERE tableId = ?", [.text(table.tableId)])
            .first?.first?.whole ?? 0
    }

    func noteIssued(_ table: InventoryTable, _ id: Int64) throws {
        try db.execute(
            "CREATE TABLE IF NOT EXISTS \"\(Self.issuedTable)\" (tableId TEXT PRIMARY KEY, last INTEGER NOT NULL)")
        try db.execute("""
            INSERT INTO "\(Self.issuedTable)" (tableId, last) VALUES (?, ?) \
            ON CONFLICT(tableId) DO UPDATE SET last = max(last, excluded.last)
            """, [.text(table.tableId), .int(id)])
    }

    /// Delete a row; every cell it held, with its manualSort, so `restore` can put it back (undo).
    @discardableResult
    public func deleteRow(_ table: InventoryTable, row: Int64) throws -> [String: SQLValue] {
        guard !readOnly else { throw InventoryFileError.readOnly }
        return try db.transaction {
            let quotedTable = SQLite.quoted(table.tableId)
            let names = try db.query("PRAGMA table_info(\(quotedTable))").compactMap { Self.text($0[1]) }
            let selected = names.map(SQLite.quoted).joined(separator: ", ")
            guard let cells = try db.query("SELECT \(selected) FROM \(quotedTable) WHERE id = ?", [.int(row)]).first
            else { throw InventoryFileError.noRow }
            if Self.numberedForGood.contains(table.tableId) { try noteIssued(table, row) }  // made before the count
            try db.execute("DELETE FROM \(quotedTable) WHERE id = ?", [.int(row)])
            return Dictionary(uniqueKeysWithValues: zip(names, cells).filter { $0.0 != "id" })
        }
    }

    /// Put back a row `deleteRow` removed, with its id and every cell.
    public func restore(_ table: InventoryTable, row: Int64, cells: [String: SQLValue]) throws {
        guard !readOnly else { throw InventoryFileError.readOnly }
        try db.transaction { try insert(table, id: row, cells: cells) }
    }

    /// Add a column to one of the four tables when no column has its label: described in _grist_Tables_column (as Grist
    /// describes one, so the lists job finds it by its label) and added to the table with Grist's blank as its default.
    /// Whether it was added.
    @discardableResult
    public func ensureColumn(_ name: String, colId: String, label: String, type: String,
                             widgetOptions: String = "") throws -> Bool {
        guard !readOnly else { throw InventoryFileError.readOnly }
        let table = try self.table(name)
        guard !table.columns.contains(where: { Self.same($0.label, label) }) else { return false }
        // a stored name the table already uses (an owner's own "Serial" with another label) gets a free one: Serial_2
        let stored = Set(try db.query("PRAGMA table_info(\(SQLite.quoted(table.tableId)))")
            .compactMap { Self.text($0[1])?.lowercased() })
        var colId = colId
        var n = 2
        while stored.contains(colId.lowercased()) {
            colId = "\(colId.split(separator: "_").first.map(String.init) ?? colId)_\(n)"
            n += 1
        }
        try db.transaction {
            let id = (try db.query("SELECT max(id) FROM _grist_Tables_column").first?.first?.whole ?? 0) + 1
            let position = (try db.query("SELECT max(parentPos) FROM _grist_Tables_column WHERE parentId = ?",
                                         [.int(table.ref)]).first?.first?.number ?? 0).rounded(.down) + 1
            try db.execute("""
                INSERT INTO _grist_Tables_column (id, parentId, parentPos, colId, type, widgetOptions, isFormula, \
                formula, label) VALUES (?, ?, ?, ?, ?, ?, 0, '', ?)
                """, [.int(id), .int(table.ref), .real(position), .text(colId), .text(type), .text(widgetOptions),
                      .text(label)])
            let blank = switch type {
            case "Text", "Choice": "TEXT DEFAULT ''"
            case "Bool": "BOOLEAN DEFAULT 0"
            case "Date": "DATE DEFAULT NULL"
            case "Numeric": "NUMERIC DEFAULT 0"
            default: "INTEGER DEFAULT 0"  // Int and Ref:…
            }
            try db.execute("ALTER TABLE \(SQLite.quoted(table.tableId)) ADD COLUMN \(SQLite.quoted(colId)) \(blank)")
        }
        try reload()
        return true
    }

    /// A Choice column's list gains each of `choices` it lacks, after its own (2026-10-30: fl oz joined Holds unit, made
    /// without it): true when one was added. The column's other options are kept as they are.
    @discardableResult
    public func ensureChoices(_ name: String, label: String, _ choices: [String]) throws -> Bool {
        guard !readOnly else { throw InventoryFileError.readOnly }
        guard let column = try table(name).columns.first(where: { Self.same($0.label, label) }),
              column.type == "Choice" else { return false }
        let missing = choices.filter { want in !column.choices.contains { Self.same($0, want) } }
        guard !missing.isEmpty else { return false }
        try db.transaction {
            let raw = try db.query("SELECT widgetOptions FROM _grist_Tables_column WHERE id = ?", [.int(column.ref)])
                .first.flatMap { Self.text($0[0]) } ?? ""
            var options = (raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                           as? [String: Any]) ?? [:]
            options["choices"] = column.choices + missing
            let written = String(decoding: try JSONSerialization.data(withJSONObject: options, options: .sortedKeys),
                                 as: UTF8.self)
            try db.execute("UPDATE _grist_Tables_column SET widgetOptions = ? WHERE id = ?",
                           [.text(written), .int(column.ref)])
        }
        try reload()
        return true
    }

    // MARK: Reading the description

    private func insert(_ table: InventoryTable, id: Int64, cells: [String: SQLValue]) throws {
        let names = ["id"] + cells.keys.sorted()
        let marks = Array(repeating: "?", count: names.count).joined(separator: ", ")
        try db.execute("INSERT INTO \(SQLite.quoted(table.tableId)) (\(names.map(SQLite.quoted).joined(separator: ", "))) "
                       + "VALUES (\(marks))", [.int(id)] + cells.keys.sorted().map { cells[$0]! })
    }

    private func hasColumn(_ table: InventoryTable, _ colId: String) throws -> Bool {
        try db.query("PRAGMA table_info(\(SQLite.quoted(table.tableId)))").contains { Self.text($0[1]) == colId }
    }

    private func columns(of tableRef: Int64, listed: [(Int64, String)]) throws -> [InventoryColumn] {
        let found = try described(tableRef)
        return found.compactMap { column in
            guard !Self.gristColumns.contains(column.colId.lowercased()),
                  !column.colId.lowercased().hasPrefix("gristhelper_") else { return nil }
            var kind: InventoryColumn.Kind = switch column.type {
            case "Text": .text
            case "Numeric": .numeric
            case "Int": .int
            case "Bool": .bool
            case "Date": .date
            case "Choice": .choice
            default: .other
            }
            var shown: String?
            var display: String?
            if column.type.hasPrefix("Ref:") {
                let target = String(column.type.dropFirst(4))
                kind = .reference(table: target)
                if let targetRef = listed.first(where: { $0.1 == target })?.0 {
                    let targetColumns = (try? described(targetRef)) ?? []
                    shown = targetColumns.first(where: { $0.ref == column.visibleCol && column.visibleCol != 0 })?.colId
                    if shown == nil {
                        let named = targetColumns.filter { Self.same($0.label, "Name") }
                        shown = named.count == 1 ? named[0].colId : nil
                    }
                }
                display = found.first(where: { $0.ref == column.displayCol && column.displayCol != 0 })?.colId
            }
            return InventoryColumn(ref: column.ref, colId: column.colId, label: column.label, type: column.type,
                                   kind: kind, isFormula: column.isFormula, choices: column.choices,
                                   shownColId: shown, displayColId: display)
        }
    }

    private struct Described {
        let ref: Int64, colId: String, type: String, label: String, isFormula: Bool, choices: [String]
        let visibleCol: Int64, displayCol: Int64
    }

    private func described(_ tableRef: Int64) throws -> [Described] {
        try db.query("""
            SELECT id, colId, type, label, isFormula, widgetOptions, visibleCol, displayCol FROM _grist_Tables_column \
            WHERE parentId = ? ORDER BY parentPos, id
            """, [.int(tableRef)]).compactMap { row in
            guard let ref = row[0].whole, let colId = Self.text(row[1]) else { return nil }
            return Described(ref: ref, colId: colId, type: Self.text(row[2]) ?? "",
                             label: (Self.text(row[3]) ?? "").trimmingCharacters(in: .whitespaces),
                             isFormula: row[4].whole == 1, choices: Self.choices(row[5]),
                             visibleCol: row[6].whole ?? 0, displayCol: row[7].whole ?? 0)
        }
    }

    static func choices(_ options: SQLValue) -> [String] {
        guard let raw = text(options), let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = parsed["choices"] as? [Any] else { return [] }
        return found.compactMap { $0 as? String }
    }

    static func text(_ value: SQLValue) -> String? {
        if case .text(let found) = value { found } else { nil }
    }

    public static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces))
            == .orderedSame
    }
}
