import CryptoKit
import Foundation

/// Days of water and food counted on the phone (plan phase 7, part 2; owner 2026-10-14: right with the Mac off). The
/// lists job hands each counted row's share in `supply.json` (readiness/appsupply.py, its rules never copied here); the
/// Mac app puts it in the phones' copy, and the phone counts again from its copy and its own changes: each listed row's
/// Quantity × its share, plus the fixed amounts (Private and Bought rows), leaving out what expires today or earlier,
/// ÷ the amount a day, rounded down to a tenth. A listed row whose Item doesn't match its fingerprint (the copy has
/// another row at that number) means the phone shows the Mac's own days instead. Fixtures/supply.json is the lists
/// job's own; readiness/tests/test_appsupply.py's `phone_days` is this count's counterpart. `calculators` (step 8b) is the
/// lists job's figures for the inventory's Calculators line (CalculatorLinks); one of another shape is dropped alone,
/// so it never costs the days.
public struct SupplyShares: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public let row: Int
        public let per: Double
        public let expires: String?
        public let item: String
        /// How the count measured it (entry fixes plan, phase 3's review): its unit and what one is in it, by
        /// `measured`; a copy that now measures it otherwise (a Unit or Each holds changed) shows the Mac's days. Nil
        /// from a lists job before it.
        public var unit: String? = nil
        public var each: Double? = nil
    }

    /// A row's unit and what one of it is in that unit, as the lists job measures it (readiness/supply.py `measured`):
    /// a package counted each whose Each holds is filled, in its Holds unit; any other in its own Unit, 1.
    public static func measured(unit: String, holds: Double?, holdsUnit: String) -> (unit: String, each: Double) {
        func normal(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
        let own = normal(unit), holdsIn = normal(holdsUnit)
        if let holds, holds > 0, Inventory.Label.holdsUnits.contains(holdsIn), ProductLookup.packageUnits.contains(own) {
            return (holdsIn, holds)
        }
        return (own, 1)
    }

    public struct Fixed: Codable, Equatable, Sendable {
        public let amount: Double
        public let expires: String?
    }

    /// A Private row's share by its row number and Item's fingerprint (step 8c, section 4): for the Mac's use log only
    /// (UseLog.swift); never in the phones' copy (`forPhones`). `item` is nil from a lists job before it.
    public struct PrivateRow: Codable, Equatable, Sendable {
        public let row: Int
        public let per: Double
        public var item: String? = nil
    }

    /// An inventory row the count read that counts toward no supply (step 8c, section 4): a Used 1 on it is no use of
    /// a supply, while a row in no list at all (added, moved or renamed since the count) is a use that can't be valued.
    public struct Uncounted: Codable, Equatable, Sendable {
        public let row: Int
        public let item: String
        public let `private`: Bool
    }

    /// An inventory row a supply leaves out (owner, 2026-11-14): its number, Item fingerprint and whether it's Private,
    /// the supply (`kind`) and why, the lists job's key ("unit", "quantity", "expired" and the rest), for the
    /// Inventory's Not counted notice and its Show them.
    public struct LeftOut: Codable, Hashable, Sendable {
        public let row: Int
        public let item: String
        public let `private`: Bool
        public let kind: String
        public let why: String

        public init(row: Int, item: String, private: Bool, kind: String, why: String) {
            self.row = row
            self.item = item
            self.private = `private`
            self.kind = kind
            self.why = why
        }
    }

    public struct Kind: Codable, Equatable, Sendable {
        public let kind: String
        public let unit: String
        public let perDay: Double?
        public let days: Double?
        public let target: Double?
        public let rows: [Row]
        public let other: [Fixed]
        public let privateRows: [PrivateRow]?  // nil from a lists job before step 8c, and in the phones' copy
        // water's containers ticked Empty until needed, in days (the 2026-10-23 plan); nil when none or uncounted
        public var fillableDays: Double? = nil

        enum CodingKeys: String, CodingKey {
            case kind, unit, days, target, rows, other
            case perDay = "per_day"
            case privateRows = "private_rows"
            case fillableDays = "fillable_days"
        }
    }

    public let format: Int
    public let today: String
    public let supplies: [Kind]
    public let calculators: CalculatorFigures?
    public let uncountedRows: [Uncounted]?  // nil from a lists job before step 8c, section 4's fix
    /// What each inventory row counts toward (entry fixes plan, Task 3.4), in the lists job's words; nil before it.
    public let countedToward: [Toward]?
    /// The rows a supply leaves out, and the lists' reasons supplies aren't counted in full, fixed words and counts
    /// (the notes Today showed until 2026-11-14); nil from a lists job before them.
    public let leftOut: [LeftOut]?
    public let notes: [String]?
    /// The unit words the lists job counts each supply in, for the item forms' what's-missing line (ItemNeeds); nil
    /// from a lists job before it. Not private, so the phones' copy carries it.
    public let units: Units?

    public struct Units: Codable, Equatable, Sendable {
        public let water, pounds, calories: [String]

        public init(water: [String], pounds: [String], calories: [String]) {
            self.water = water
            self.pounds = pounds
            self.calories = calories
        }
    }

    public struct Toward: Codable, Equatable, Sendable {
        public let row: Int
        public let item: String
        public let `private`: Bool
        public let kinds: [String]
        /// Why a row that would count doesn't now: "expired" or "quantity"; nil when it counts.
        public var why: String? = nil

        public init(row: Int, item: String, private: Bool, kinds: [String], why: String? = nil) {
            self.row = row
            self.item = item
            self.private = `private`
            self.kinds = kinds
            self.why = why
        }
    }

    public init(format: Int, today: String, supplies: [Kind], calculators: CalculatorFigures? = nil,
                uncountedRows: [Uncounted]? = nil, countedToward: [Toward]? = nil, leftOut: [LeftOut]? = nil,
                notes: [String]? = nil, units: Units? = nil) {
        self.format = format
        self.today = today
        self.supplies = supplies
        self.calculators = calculators
        self.uncountedRows = uncountedRows
        self.countedToward = countedToward
        self.leftOut = leftOut
        self.notes = notes
        self.units = units
    }

    enum CodingKeys: String, CodingKey {
        case format, today, supplies, calculators
        case uncountedRows = "uncounted_rows"
        case countedToward = "counted_toward"
        case leftOut = "left_out"
        case notes, units
    }

    public init(from decoder: Decoder) throws {
        let found = try decoder.container(keyedBy: CodingKeys.self)
        format = try found.decode(Int.self, forKey: .format)
        today = try found.decode(String.self, forKey: .today)
        supplies = try found.decode([Kind].self, forKey: .supplies)
        calculators = try? found.decodeIfPresent(CalculatorFigures.self, forKey: .calculators)
        uncountedRows = try? found.decodeIfPresent([Uncounted].self, forKey: .uncountedRows)
        countedToward = try? found.decodeIfPresent([Toward].self, forKey: .countedToward)
        leftOut = try? found.decodeIfPresent([LeftOut].self, forKey: .leftOut)
        notes = try? found.decodeIfPresent([String].self, forKey: .notes)
        units = try? found.decodeIfPresent(Units.self, forKey: .units)
    }

    /// The item forms' line (Task 3.4): what the row at `row` named `item` counts toward as the last count found it;
    /// "Not counted toward any supply." when it counted toward none; "Counted after tonight's count." for a row the
    /// count hasn't seen as it is now (added, renamed or moved since), or with no count at all.
    public static func countedLine(_ shares: SupplyShares?, row: Int, item: String) -> String {
        let print = fingerprint(item)
        if let found = shares?.countedToward?.first(where: { $0.row == row && $0.item == print }) {
            switch found.why {
            case "expired": return notCountedExpired
            case "quantity": return notCountedNoQuantity
            default: return found.kinds.isEmpty ? notCounted : "Counts toward: " + found.kinds.joined(separator: ", ") + "."
            }
        }
        if shares?.uncountedRows?.contains(where: { $0.row == row && $0.item == print }) == true {
            return notCounted
        }
        return countedTonight
    }

    public static let notCounted = "Not counted toward any supply."
    public static let notCountedExpired = "Not counted now: it's past its Expires date."
    public static let notCountedNoQuantity = "Not counted now: it has no Quantity."
    public static let countedTonight = "Counted after tonight's count."

    public static let fileName = "supply.json"

    /// The Inventory's Not counted notice (owner, 2026-11-14, by click: the reasons left Today): its heading, the
    /// lists' notes under it, and Show them with how many rows it lists, on the Mac and the phones.
    public static let notCountedTitle = "Not counted in the supplies' days"
    public static func showThem(_ count: Int) -> String { "Show Them (\(count))" }
    public static let leftOutTitle = "Not Counted"

    /// The notice's one line: the heading, then each note as a sentence; nil with no notes (nothing to say).
    public var notCountedLine: String? {
        guard let notes, !notes.isEmpty else { return nil }
        return Self.notCountedTitle + ": " + notes.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }

    /// Whether the row at `row` named `item` is one a supply left out at the last count: its number and Item's
    /// fingerprint both match, so a row moved or renamed since isn't shown in its place.
    public func leftOut(row: Int, item: String) -> Bool {
        let print = Self.fingerprint(item)
        return leftOut?.contains { $0.row == row && $0.item == print } ?? false
    }

    /// As the phones' copy carries it: without the Private rows' numbers (step 8c, section 4).
    public var forPhones: SupplyShares {
        SupplyShares(format: format, today: today, supplies: supplies.map {
            Kind(kind: $0.kind, unit: $0.unit, perDay: $0.perDay, days: $0.days, target: $0.target, rows: $0.rows,
                 other: $0.other, privateRows: nil, fillableDays: $0.fillableDays)
        }, calculators: calculators, uncountedRows: uncountedRows?.filter { !$0.private },
           countedToward: countedToward?.filter { !$0.private }, leftOut: leftOut?.filter { !$0.private }, notes: notes,
           units: units)
    }

    public static func read(in folder: URL) -> SupplyShares? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let found = try? JSONDecoder().decode(SupplyShares.self, from: data), found.format == 1 else { return nil }
        return found
    }

    /// An Item as both sides normalize it: runs of spaces made one, the ends trimmed, lowercased; its SHA-256's first
    /// 12 hex digits.
    public static func fingerprint(_ item: String) -> String {
        let normal = item.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return SHA256.hash(data: Data(normal.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// One supply's days as this phone counts them: (days, counted here); the Mac's days and false when a row doesn't
    /// match the copy; nil days without an amount a day.
    public static func days(_ kind: Kind, in copy: PhoneInventory, now: Date = Date()) -> (days: Double?, here: Bool) {
        guard let perDay = kind.perDay, perDay > 0 else { return (nil, false) }
        guard let have = have(kind, in: copy, now: now) else { return (kind.days, false) }
        return ((have / perDay * 10 + 1e-9).rounded(.down) / 10, true)
    }

    /// What's on hand of one supply, in its unit, as this phone counts it; nil when a row doesn't match the copy
    /// (step 8c, section 4: the run-out day divides it by the use).
    public static func have(_ kind: Kind, in copy: PhoneInventory, now: Date = Date()) -> Double? {
        let quantity = copy.column(Inventory.Label.quantity), item = copy.column("Item")
        let unitColumn = copy.column("Unit"), holdsColumn = copy.column(Inventory.Label.eachHolds)
        let holdsUnitColumn = copy.column(Inventory.Label.holdsUnit)
        func text(_ row: PhoneInventory.Row, _ column: PhoneInventory.Column?) -> String {
            column.map { InventoryValues.plain(row.values[$0.colId] ?? .null) } ?? ""
        }
        let byPosition = Dictionary(copy.items.map { ($0.position, $0) }, uniquingKeysWith: { first, _ in first })
        let today = Self.today(now)
        var have = 0.0
        for share in kind.rows {
            guard let row = byPosition[share.row], let item,
                  fingerprint(InventoryValues.plain(row.values[item.colId] ?? .null)) == share.item else {
                return nil
            }
            // measured otherwise since the count: the Mac's days (a copy with no Unit column can't say, so isn't asked)
            if let unit = share.unit, let each = share.each, unitColumn != nil {
                let now = measured(unit: text(row, unitColumn), holds: InventoryValues.parseNumber(text(row, holdsColumn)),
                                   holdsUnit: text(row, holdsUnitColumn))
                guard now.unit == unit, abs(now.each - each) < 1e-9 else { return nil }
            }
            if let expires = share.expires, expires <= today { continue }
            let text = quantity.map { InventoryValues.plain(row.values[$0.colId] ?? .null) } ?? ""
            have += (InventoryValues.parseNumber(text.trimmingCharacters(in: .whitespaces)) ?? 0) * share.per
        }
        for fixed in kind.other where fixed.expires.map({ $0 > today }) ?? true {
            have += fixed.amount
        }
        return (have * 1e9).rounded() / 1e9
    }

    /// Today in the household's time zone as "YYYY-MM-DD" (an Expires date compares as text).
    static func today(_ now: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "America/New_York")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: now)
    }
}
