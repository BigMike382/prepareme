import Foundation

/// To buy in the app (plan phase 7, slice 4). The lists job ranks what to buy and, after cutover, writes it for the app
/// as `to-buy.json` in the inventory folder (readiness/apptobuy.py), each item with its ID. The app answers with ticks
/// kept in its own inventory file's PrepareMe_Ticks table, which the lists job reads with the inventory and folds once,
/// as it folds a tick in the Numbers lists file: Bought (the app has already added the item to the inventory), Not
/// needed, or an item of the owner's own. The job lists the ticks it has folded, and the app then drops them.
public struct ToBuyList: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let text: String
        public let why: String
        public let need: Double?
        public let unit: String
        public let category: String?  // the lists' group (readiness.model.CATEGORY_CHOICES)
        public let horizon: String?
        public let lifeSafety: Bool
        public let cost: String?

        enum CodingKeys: String, CodingKey {
            case id, text, why, need, unit, category, horizon, cost
            case lifeSafety = "life_safety"
        }

        /// A supply shortfall the lists job worked out ("Water: 1.3 of 30 days; 126 gallons short"), told by its ID:
        /// S-<target>-n<k>, the lists' own form for one (readiness/engine.py `_FORMS`, readiness/propose.py), so its
        /// text is the list's sentence, never a thing's name (addition A, owner 2026-11-18: Bought starts clean).
        public var isShortfall: Bool { id.hasPrefix("S-") }

        /// A line whose text is the list's own sentence, a shortfall's or an expiry's (E-…, readiness/propose.py
        /// `_expiring`: "Replace or use up: … (expires …)"), so Bought starts with Name blank (round 2, 2): an expiry
        /// line carries no item name as data (its ID is a hash, its why another sentence), and none is cut out of words.
        public var isListSentence: Bool { isShortfall || id.hasPrefix("E-") }
    }

    public let writtenAt: String
    public let items: [Item]
    public let folded: [String]  // tick ids the lists job has counted

    enum CodingKeys: String, CodingKey {
        case items, folded
        case writtenAt = "written_at"
    }

    public static let fileName = "to-buy.json"
    /// The lists' groups, as readiness.model.CATEGORY_CHOICES spells them (readiness/tests/test_apptobuy.py pins this
    /// copy): an own item's group is one of them.
    public static let groups = ["Water", "Food", "Medical", "Power and fuel", "Heat and shelter", "Tools and equipment",
                                "Communications", "Pets", "Documents and plans", "Security", "Vehicles and RV",
                                "Skills and training", "Other"]

    /// A category's group when its Counts as is blank, by its name (readiness.model.CATEGORY_MAP; the test there pins
    /// this copy), as the lists job reads it.
    public static let categoryMap: [String: String] = [
        "Water": "Water", "Food": "Food", "Medicine": "Medical", "First aid": "Medical",
        "Power and batteries": "Power and fuel", "Fuel": "Power and fuel", "Hygiene and sanitation": "Water",
        "Tools": "Tools and equipment", "Gear": "Tools and equipment", "Materials": "Tools and equipment",
        "Communications": "Communications", "Pet supplies": "Pets", "Firearms and ammunition": "Security",
        "Vehicles": "Vehicles and RV", "Other": "Other", "Medical": "Medical", "Power and fuel": "Power and fuel",
        "Heat and shelter": "Heat and shelter", "Tools and equipment": "Tools and equipment", "Pets": "Pets",
        "Documents and plans": "Documents and plans", "Security": "Security", "Vehicles and RV": "Vehicles and RV",
        "Skills and training": "Skills and training",
    ]

    /// The group a category of this name counts in when it has no Counts as; nil for a name the map doesn't hold.
    public static func group(ofName name: String) -> String? {
        categoryMap.first { InventoryFile.same($0.key, name) }?.value
    }

    /// The list in `folder`, or nil when there is none yet (before cutover) or it can't be read.
    public static func read(in folder: URL) -> ToBuyList? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(ToBuyList.self, from: data)
    }
}

/// One tick the app keeps until the lists job has folded it.
public struct ToBuyTick: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case bought, notNeeded = "not needed", add }

    /// The longest an own item's words, unit, group or why may be (readiness/apptobuy.py's TEXT_LIMIT).
    public static let textLimit = 300

    public let id: String
    public let kind: Kind
    public let item: String  // the To buy item's ID; "" for an item of the owner's own
    public let text: String  // an own item's words; "" otherwise
    public let need: Double?
    public let unit: String
    public let category: String  // an own item's group, as the lists spell it; "" otherwise
    public let why: String
    public let at: String  // ISO 8601, UTC

    public init(id: String = UUID().uuidString.lowercased(), kind: Kind, item: String = "", text: String = "",
                need: Double? = nil, unit: String = "", category: String = "", why: String = "", at: Date = Date()) {
        self.id = id
        self.kind = kind
        self.item = item
        self.text = text
        self.need = need
        self.unit = unit
        self.category = category
        self.why = why
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]  // ticks keep the order they were made in
        self.at = format.string(from: at)
    }

    init(id: String, kind: Kind, item: String, text: String, need: Double?, unit: String, category: String, why: String,
         atText: String) {
        self.id = id
        self.kind = kind
        self.item = item
        self.text = text
        self.need = need
        self.unit = unit
        self.category = category
        self.why = why
        self.at = atText
    }
}

extension InventoryFile {
    static let ticksTable = "PrepareMe_Ticks"  // not in _grist_Tables, so Grist's reader of tables never sees it

    /// The ticks table, made when it isn't there yet.
    public func ensureTicks() throws {
        guard !readOnly else { throw InventoryFileError.readOnly }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS "\(Self.ticksTable)" (id TEXT PRIMARY KEY, kind TEXT NOT NULL, item TEXT NOT NULL \
            DEFAULT '', text TEXT NOT NULL DEFAULT '', need REAL, unit TEXT NOT NULL DEFAULT '', category TEXT NOT NULL \
            DEFAULT '', why TEXT NOT NULL DEFAULT '', at TEXT NOT NULL)
            """)
    }

    public func ticks() throws -> [ToBuyTick] {
        let found = try db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                                 [.text(Self.ticksTable)])
        guard !found.isEmpty else { return [] }
        return try db.query("SELECT id, kind, item, text, need, unit, category, why, at FROM \"\(Self.ticksTable)\" "
                            + "ORDER BY at, id").compactMap { row in
            guard let id = Self.text(row[0]), let kind = Self.text(row[1]).flatMap(ToBuyTick.Kind.init) else {
                return nil
            }
            return ToBuyTick(id: id, kind: kind, item: Self.text(row[2]) ?? "", text: Self.text(row[3]) ?? "",
                             need: row[4].number, unit: Self.text(row[5]) ?? "", category: Self.text(row[6]) ?? "",
                             why: Self.text(row[7]) ?? "", atText: Self.text(row[8]) ?? "")
        }
    }

    /// Keep a tick.
    public func addTick(_ tick: ToBuyTick) throws {
        try ensureTicks()
        try db.transaction { try insertTick(tick) }
    }

    /// Bought: the item added to the Inventory and its tick kept in one transaction, so neither is ever kept alone;
    /// the new row's id.
    @discardableResult
    public func addRow(_ table: InventoryTable, values: [String: SQLValue], tick: ToBuyTick) throws -> Int64 {
        try ensureTicks()
        return try db.transaction {
            let id = try insertRow(table, values: values)
            try insertTick(tick)
            return id
        }
    }

    /// Bought undone: the row and its tick gone together (the tick may already have been counted and dropped).
    public func removeRow(_ table: InventoryTable, row: Int64, tick: String) throws {
        guard !readOnly else { throw InventoryFileError.readOnly }
        try db.transaction {
            try db.execute("DELETE FROM \(SQLite.quoted(table.tableId)) WHERE id = ?", [.int(row)])
            if try hasTicks() { try db.execute("DELETE FROM \"\(Self.ticksTable)\" WHERE id = ?", [.text(tick)]) }
        }
    }

    func hasTicks() throws -> Bool {
        try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                      [.text(Self.ticksTable)]).isEmpty
    }

    private func insertTick(_ tick: ToBuyTick) throws {
        try db.execute("""
            INSERT INTO "\(Self.ticksTable)" (id, kind, item, text, need, unit, category, why, at) \
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(tick.id), .text(tick.kind.rawValue), .text(tick.item), .text(tick.text),
                  tick.need.map { .real($0) } ?? .null, .text(tick.unit), .text(tick.category), .text(tick.why),
                  .text(tick.at)])
    }

    /// Drop the ticks the lists job has folded; how many went.
    @discardableResult
    public func dropTicks(_ ids: [String]) throws -> Int {
        guard !readOnly else { throw InventoryFileError.readOnly }
        guard !ids.isEmpty, try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                                          [.text(Self.ticksTable)]).isEmpty else { return 0 }
        return try db.transaction {
            var dropped = 0
            for id in ids {
                let before = try db.query("SELECT count(*) FROM \"\(Self.ticksTable)\" WHERE id = ?", [.text(id)])
                dropped += Int(before.first?.first?.whole ?? 0)
                try db.execute("DELETE FROM \"\(Self.ticksTable)\" WHERE id = ?", [.text(id)])
            }
            return dropped
        }
    }
}
