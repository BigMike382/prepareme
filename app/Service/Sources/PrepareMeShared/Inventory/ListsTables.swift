import Foundation

/// The lists in the app (plan phase 7, part 2; owner 2026-10-14: Numbers retires once this is built). To do, To buy,
/// Bought, Upkeep, Targets, Proposed, Recalls and the lists' Settings live in the inventory file's own tables, which
/// the lists job reads from the same snapshot as the inventory (readiness/applists.py) with its own reader, so every
/// rule the Numbers lists file had stays one set:
/// - PrepareMe_Lists: each sheet's rows in order, (sheet, pos, cells), `cells` a JSON object of the row's columns
///   (`ListsLayout.sheets`); PrepareMe_ListsMeta: "stamp" (the lists job's last rewrite taken in) and "revision" (one
///   higher with each change of the owner's).
/// - The lists job's rewrite comes as `lists.json` in the inventory folder (`ListsPayload`), taken in whole only while
///   the revision is still the one its read saw (`takeIn`), so a change made since is never written over: the next run
///   reads it and writes again.
/// - The owner's changes go through InventoryEditor (its ID check and the lists' reader on a throwaway copy), one cell,
///   an added row or a removed one at a time (`ListsLayout`'s rules), each raising the revision in the same save.
public enum ListCell: Codable, Equatable, Hashable, Sendable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let found = try? container.decode(Bool.self) { self = .bool(found); return }
        if let found = try? container.decode(Double.self) {
            guard found.isFinite else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not finite")
            }
            self = .number(found)
            return
        }
        self = .text(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let found): try container.encode(found)
        case .number(let found): try container.encode(found)
        case .bool(let found): try container.encode(found)
        case .null: try container.encodeNil()
        }
    }

    public var text: String {
        switch self {
        case .text(let found): found
        case .number(let found): InventoryValues.number(found)
        case .bool(let found): found ? "Yes" : ""
        case .null: ""
        }
    }

    public var isTicked: Bool { self == .bool(true) }

    /// A date column's day, from its "YYYY-MM-DD".
    public var day: Date? {
        guard case .text(let found) = self, found.count == 10 else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "America/New_York")
        format.dateFormat = "yyyy-MM-dd"
        return format.date(from: found)
    }

    public static func day(_ date: Date) -> ListCell {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "America/New_York")
        format.dateFormat = "yyyy-MM-dd"
        return .text(format.string(from: date))
    }

    /// Blank as the lists' reader reads a cell: nothing, an empty text or an unticked box.
    public var isBlank: Bool {
        switch self {
        case .null, .bool(false): true
        case .text(let found): found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }
}

/// One row of a sheet: its place in the table and its cells by column.
public struct ListRow: Codable, Equatable, Hashable, Sendable {
    public let pos: Int
    public var cells: [String: ListCell]

    public init(pos: Int, cells: [String: ListCell]) {
        self.pos = pos
        self.cells = cells
    }

    /// The lists job's ID for the row, "" for a row the owner added that it hasn't read yet.
    public var id: String { cells["ID"]?.text ?? "" }

    /// A to-do added on this phone that the Mac hasn't kept yet (`PhoneOutbox.view`): nothing finds it there to change.
    public var waiting: Bool { pos < 0 }

    public subscript(_ column: String) -> ListCell { cells[column] ?? .null }
}

/// Which row a change is for: by its ID once the lists job gave it one (wherever a rewrite has put it since), a
/// Settings row by its name, else by its place and every cell as seen, so a rewrite taken in meanwhile never sends the
/// change to another row.
public struct ListRowRef: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let pos: Int
    public let seen: [String: ListCell]

    public init(_ row: ListRow) {
        id = row.id
        pos = row.pos
        if !row.id.isEmpty {
            seen = [:]
        } else if let name = row.cells["Setting"], Set(row.cells.keys).isSubset(of: ["Setting", "Value"]) {
            seen = ["Setting": name]
        } else {
            seen = row.cells
        }
    }
}

/// The lists as they are in the file now.
public struct Lists: Equatable, Sendable {
    public var sheets: [String: [ListRow]]
    public var stamp: String?
    public var revision: Int
    /// A Mac-only item's recall's title and link by row ID (top-ten plan phase 6, Task 6.3): the Mac's Recalls list
    /// names and opens it, its row holding no title; kept beside the rows taken in, never in a phone's copy
    public var macOnlyRecalls: [String: MacOnlyRecall] = [:]

    public static let none = Lists(sheets: [:], stamp: nil, revision: 0)

    public func rows(_ sheet: String) -> [ListRow] { sheets[sheet] ?? [] }

    public func find(_ ref: ListRowRef, in sheet: String) -> ListRow? {
        if !ref.id.isEmpty { return rows(sheet).first { $0.id == ref.id } }
        if sheet == ListsLayout.settings {
            guard let name = ref.seen["Setting"], !name.isBlank else { return nil }
            return rows(sheet).first { $0["Setting"] == name }
        }
        return rows(sheet).first { $0.pos == ref.pos && $0.id.isEmpty && $0.cells == ref.seen }
    }

    /// A Settings value by its name ("Event mode", "Water target (days)" …).
    public func setting(_ name: String) -> ListCell {
        rows(ListsLayout.settings).first { $0["Setting"].text == name }?["Value"] ?? .null
    }
}

/// A Mac-only item's recall, as the lists job names it for the Mac alone (readiness.listrows, `mac_only_recalls`)
public struct MacOnlyRecall: Codable, Equatable, Sendable {
    public let title: String
    public let link: String

    public init(title: String, link: String) {
        self.title = title
        self.link = link
    }
}

/// The rewrite the lists job leaves in the inventory folder (readiness.applists.payload).
public struct ListsPayload: Decodable, Equatable, Sendable {
    public let format: Int
    public let stamp: String
    public let base: Int?
    public let digest: String
    public let sheets: [String: [[String: ListCell]]]
    /// Absent in a rewrite from before Task 6.3
    public let macOnlyRecalls: [String: MacOnlyRecall]?

    enum CodingKeys: String, CodingKey {
        case format, stamp, base, digest, sheets
        case macOnlyRecalls = "mac_only_recalls"
    }

    public static let fileName = "lists.json"

    /// The rewrite in `folder`, or nil when there is none or it can't be read.
    public static func read(in folder: URL) -> ListsPayload? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let found = try? JSONDecoder().decode(ListsPayload.self, from: data), found.format == 1 else { return nil }
        return found
    }
}

/// readiness/layout.py's sheets and the owner's columns, copied (readiness/tests/test_applists.py pins this copy).
public enum ListsLayout {
    public static let todo = "To do", toBuy = "To buy", bought = "Bought", upkeep = "Upkeep", targets = "Targets"
    public static let proposed = "Proposed", recalls = "Recalls", settings = "Settings"

    /// A sheet's title on screen: the names above are what the lists file is matched by and stay as they are; the
    /// screens show To Do and To Buy, and Bought as the button that opens it says (the owner's wording rule,
    /// 2026-11-19).
    public static func shownTitle(_ sheet: String) -> String {
        switch sheet {
        case todo: "To Do"
        case toBuy: "To Buy"
        case bought: InventoryHomeTiles.More.bought.title
        default: sheet
        }
    }

    public static let sheets: [String: [String]] = [
        "To do": ["Done", "Done on", "Task", "Why", "Category", "Horizon", "Life-safety", "Due", "Cost", "Notes", "ID"],
        "To buy": ["Bought", "Not needed", "Item", "Need", "Unit", "Why", "Category", "Horizon", "Life-safety", "Cost",
                   "Qty bought", "Expires", "Notes", "ID"],
        "Bought": ["Moved", "Item", "Category", "Quantity", "Unit", "Calories each", "Location", "Expires", "Bought on",
                   "Check", "ID"],
        "Upkeep": ["Active", "Task", "Category", "Horizon", "Life-safety", "Source says", "Every", "Unit", "Last done",
                   "Next due", "Source", "Quote", "Check", "ID"],
        "Targets": ["Item or category", "Target", "Unit", "Days", "Horizon", "Life-safety", "Why", "ID"],
        "Proposed": ["Accept", "Decline", "List", "Text", "Why", "Source", "Category", "Horizon", "Life-safety",
                     "Proposed on", "ID"],
        "Recalls": ["Item", "Recall", "Agency", "Date", "Link", "Level", "Status", "Checked on", "ID"],
        "Settings": ["Setting", "Value"],
    ]

    /// On the lists job's own rows, the columns it always writes (layout.SCRIPT_COLUMNS); on a row the owner added,
    /// every column but ID is the owner's.
    public static let scriptColumns: [String: [String]] = [
        "To do": ["Why", "Due", "ID"],
        "To buy": ["Need", "Unit", "Why", "ID"],
        "Bought": ["Bought on", "Check", "ID"],
        "Upkeep": ["Next due", "Check", "ID"],
        "Targets": ["ID"],
        "Proposed": ["List", "Text", "Why", "Source", "Category", "Horizon", "Life-safety", "Proposed on", "ID"],
        "Recalls": ["Item", "Recall", "Agency", "Date", "Link", "Level", "Checked on", "ID"],
    ]

    // The menus (readiness.model and layout), copied likewise.
    public static let horizons = ["first hour", "two weeks", "90 days", "open-ended"]
    public static let costs = ["No-Cost", "Low", "Medium", "High"]
    public static let upkeepUnits = ["days", "weeks", "months", "years"]
    public static let recallStatuses = ["Not ours", "Fixed", "Replaced", "Thrown away"]
    /// A word from before (readiness.layout.RECALL_RENAMED), shown as its new one: never a blank menu or a refusal
    public static let recallRenamed = ["Repaired": "Fixed"]

    /// A recall's Status as shown and offered: an old word as its new one (top-ten plan phase 6)
    public static func recallStatus(_ text: String) -> String { recallRenamed[text] ?? text }
    public static let eventSwitch = ["Auto", "On", "Off"]
    public static let settingsRows = ["Event mode", "Water target (days)", "Food target (days)",
                                      "Pet food target (days)", "Calories per person per day",
                                      "Upkeep heads-up (days)"]
    public static let eventMode = "Event mode"
    public static let dateColumns: Set<String> = ["Done on", "Due", "Expires", "Last done", "Proposed on"]
    public static let tickColumns: Set<String> = ["Done", "Bought", "Not needed", "Moved", "Active", "Accept", "Decline",
                                                  "Life-safety"]
    public static let numberColumns: Set<String> = ["Need", "Qty bought", "Quantity", "Calories each", "Every",
                                                    "Target", "Days"]

    /// To buy is the app's To buy window's (its ticks, ToBuy.swift), and Bought only the Numbers file's leftovers'.
    static let readOnlySheets: Set<String> = ["To buy"]

    /// Whether the owner may change `column` on `row` of `sheet` here: never ID or a column the lists job writes on its
    /// own rows; on Settings only Value; on Proposed only Accept and Decline; on Recalls only Status; on Bought only Moved.
    public static func editable(_ sheet: String, column: String, row: ListRow) -> Bool {
        guard let columns = sheets[sheet], columns.contains(column), column != "ID",
              !readOnlySheets.contains(sheet) else { return false }
        switch sheet {
        case settings: return column == "Value"
        case bought: return column == "Moved"
        default: break
        }
        if row.id.isEmpty, sheet == todo || sheet == upkeep || sheet == targets { return true }
        return !(scriptColumns[sheet] ?? []).contains(column)
    }

    /// Sheets the owner adds rows to here.
    public static let addable: Set<String> = ["To do", "Upkeep", "Targets"]

    /// Whether the owner may remove `row`: their own To do rows the lists job hasn't read yet, and any Upkeep or
    /// Targets row (the lists job then drops it, as it does a row deleted from the Numbers file).
    public static func removable(_ sheet: String, row: ListRow) -> Bool {
        switch sheet {
        case todo: row.id.isEmpty
        case upkeep, targets: true
        default: false
        }
    }
}

public enum ListsWords {
    public static let notThere = "The lists aren't in this file yet: the lists job hands them over at its next run."
    public static let notEditable = "That can't be changed here."
    public static let notAChoice = "Pick one of the menu's choices."
    public static let notANumber = "Type a number here."
    public static let notADate = "Pick a date here."
}

extension InventoryFile {
    static let listsTable = "PrepareMe_Lists"
    static let metaTable = "PrepareMe_ListsMeta"
    /// The meta row holding Lists.macOnlyRecalls (JSON), beside the stamp and revision; the lists job reads only those two
    static let macOnlyKey = "mac_only_recalls"

    private func hasLists() throws -> Bool {
        try db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?)",
                     [.text(Self.listsTable), .text(Self.metaTable)]).count == 2
    }

    private func makeLists() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS "\(Self.listsTable)" (sheet TEXT NOT NULL, pos INTEGER NOT NULL, cells TEXT NOT \
            NULL, PRIMARY KEY (sheet, pos))
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS "\(Self.metaTable)" (key TEXT PRIMARY KEY, value TEXT NOT NULL)
            """)
    }

    /// The lists in the file, or nil before the lists job has handed them over. A row whose cells can't be read is
    /// left out here; the lists job refuses the read for it, naming its place.
    public func lists() throws -> Lists? {
        guard try hasLists() else { return nil }
        var meta: [String: String] = [:]
        for row in try db.query("SELECT key, value FROM \"\(Self.metaTable)\"") {
            if let key = Self.text(row[0]), let value = Self.text(row[1]) { meta[key] = value }
        }
        var sheets: [String: [ListRow]] = [:]
        let decoder = JSONDecoder()
        for row in try db.query("SELECT sheet, pos, cells FROM \"\(Self.listsTable)\" ORDER BY sheet, pos") {
            guard let sheet = Self.text(row[0]), let pos = row[1].whole, let raw = Self.text(row[2]),
                  let cells = try? decoder.decode([String: ListCell].self, from: Data(raw.utf8)) else { continue }
            sheets[sheet, default: []].append(ListRow(pos: Int(pos), cells: cells))
        }
        let macOnly = meta[Self.macOnlyKey].flatMap {
            try? decoder.decode([String: MacOnlyRecall].self, from: Data($0.utf8))
        }
        return Lists(sheets: sheets, stamp: meta["stamp"], revision: Int(meta["revision"] ?? "") ?? 0,
                     macOnlyRecalls: macOnly ?? [:])
    }

    /// The lists job's rewrite, taken in whole when its `base` is the revision now (none: only while the file has no
    /// lists yet), and never the same stamp twice; the revision stays as it was, so the next read sees it unchanged.
    /// True when taken in.
    @discardableResult
    public func takeIn(_ payload: ListsPayload) throws -> Bool {
        guard !readOnly else { throw InventoryFileError.readOnly }
        return try db.transaction {
            let current = try lists()
            if let base = payload.base {
                guard let current, current.revision == base, current.stamp != payload.stamp else { return false }
            } else if current != nil {
                return false
            }
            try makeLists()
            try db.execute("DELETE FROM \"\(Self.listsTable)\"")
            for (sheet, rows) in payload.sheets where ListsLayout.sheets[sheet] != nil {
                for (pos, cells) in rows.enumerated() {
                    try insertListRow(sheet, pos: pos, cells: cells)
                }
            }
            try db.execute("INSERT OR REPLACE INTO \"\(Self.metaTable)\" (key, value) VALUES ('stamp', ?)",
                           [.text(payload.stamp)])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let macOnly = String(decoding: try encoder.encode(payload.macOnlyRecalls ?? [:]), as: UTF8.self)
            try db.execute("INSERT OR REPLACE INTO \"\(Self.metaTable)\" (key, value) VALUES (?, ?)",
                           [.text(Self.macOnlyKey), .text(macOnly)])
            try db.execute("INSERT OR IGNORE INTO \"\(Self.metaTable)\" (key, value) VALUES ('revision', '0')")
            return true
        }
    }

    private func insertListRow(_ sheet: String, pos: Int, cells: [String: ListCell]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let raw = String(decoding: try encoder.encode(cells), as: UTF8.self)
        try db.execute("INSERT INTO \"\(Self.listsTable)\" (sheet, pos, cells) VALUES (?, ?, ?)",
                       [.text(sheet), .int(Int64(pos)), .text(raw)])
    }

    private func bumpRevision() throws {
        try db.execute("UPDATE \"\(Self.metaTable)\" SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) "
                       + "WHERE key = 'revision'")
    }

    /// One row's cells replaced, and the revision raised; what they were.
    @discardableResult
    func setListRow(_ sheet: String, pos: Int, cells: [String: ListCell]) throws -> [String: ListCell]? {
        guard !readOnly else { throw InventoryFileError.readOnly }
        guard let old = try lists()?.rows(sheet).first(where: { $0.pos == pos }) else { return nil }
        try db.transaction {
            try db.execute("DELETE FROM \"\(Self.listsTable)\" WHERE sheet = ? AND pos = ?", [.text(sheet), .int(Int64(pos))])
            try insertListRow(sheet, pos: pos, cells: cells)
            try bumpRevision()
        }
        return old.cells
    }

    /// A row added after the sheet's last (or at `pos` when one is put back), and the revision raised; its place.
    @discardableResult
    func addListRow(_ sheet: String, cells: [String: ListCell], pos: Int? = nil) throws -> Int {
        guard !readOnly else { throw InventoryFileError.readOnly }
        return try db.transaction {
            let last = try db.query("SELECT max(pos) FROM \"\(Self.listsTable)\" WHERE sheet = ?", [.text(sheet)])
                .first?.first?.whole
            let place = pos ?? Int((last ?? -1) + 1)
            try insertListRow(sheet, pos: place, cells: cells)
            try bumpRevision()
            return place
        }
    }

    /// A row removed, and the revision raised; its cells.
    @discardableResult
    func removeListRow(_ sheet: String, pos: Int) throws -> [String: ListCell]? {
        guard !readOnly else { throw InventoryFileError.readOnly }
        guard let old = try lists()?.rows(sheet).first(where: { $0.pos == pos }) else { return nil }
        try db.transaction {
            try db.execute("DELETE FROM \"\(Self.listsTable)\" WHERE sheet = ? AND pos = ?", [.text(sheet), .int(Int64(pos))])
            try bumpRevision()
        }
        return old.cells
    }
}

/// An adult's phone's own Event mode switch (plan phase 7, part 2), shown on that phone's front page at once: while its
/// change waits for the Mac (away from home too), and for `hold` after it was made, by which time the Mac's next pack
/// carries it to every phone. The page's own script then decides the mode from it, as from the Mac's (data-switch).
public enum PhoneEventSwitch {
    public static let hold: TimeInterval = 6 * 3600

    /// The switch this phone shows over the page's, or nil for the page's own. Once the Mac's copy written after
    /// the phone's switch says otherwise (the Mac, or another phone, switched it since), the copy's word is shown
    /// until the page catches up (review 2026-10-14).
    public static func value(waiting: String?, local: String?, setAt: Date?, copy: String? = nil,
                             copyAt: Date? = nil, now: Date = Date()) -> String? {
        if let waiting, ListsLayout.eventSwitch.contains(waiting) { return waiting }
        guard let local, ListsLayout.eventSwitch.contains(local), let setAt, now.timeIntervalSince(setAt) < hold,
              now >= setAt else { return nil }
        if let copy, ListsLayout.eventSwitch.contains(copy), let copyAt, copyAt > setAt { return copy }
        return local
    }

    /// The front page's `#conditions` switch set to `value` (its own words: on, off, auto), before the live block's
    /// apply runs the page's script again.
    public static func script(_ value: String) -> String {
        guard ListsLayout.eventSwitch.contains(value) else { return "" }
        return "(function(){var c=document.getElementById('conditions');if(c)c.setAttribute('data-switch','"
            + value.lowercased() + "');})();"
    }
}
