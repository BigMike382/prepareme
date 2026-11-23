import Foundation

/// "Runs out on" during an event (step 8c plan, section 4; the owner's answers, 2026-10-20: the rate counts the taps
/// since event mode came on, and shows on the phone's Supplies only).
///
/// - The Mac's use log: each Used 1 the Mac applies (InventoryEditor's `.adjust` down), from a phone or the Mac, adds a
///   row to the inventory file's own PrepareMe_UseLog (beside PrepareMe_Pets, outside Grist's tables): when it was
///   tapped (a phone's own tap time, PhoneEdit.at; now for the Mac's), the item's row id, how much of it was used, and
///   what that was worth to each supply, valued right then (`value`) from the lists job's own shares in supply.json as
///   they stand (its rules never copied here): a row's `per` × what was used, a Private row's from `private_rows`. A row
///   the shares don't know (added, moved or renamed since the count) is logged unvalued (amounts NULL), never dropped;
///   one the count read and found no supply in (`uncounted_rows`) is worth nothing to any. Its undo removes that row
///   (`.revertUse`). Rows before event mode came on, and any older than `keepDays`, go at the next write; out of event
///   mode, nothing is written and the table empties. The table's first shape (no amounts) reads as unreadable.
///   A phone's tap keeps that phone change's id (`edit`, added to an older table at its next write), so a "1 more"
///   straight after it from the same phone cancels it (`cancelWithin`; B2-08, beta run 2).
/// - When event mode came on: the hourly job's (dashboard/event.py event_start), written as `event-mode.json` in the
///   inventory folder (`EventModeFile`).
/// - The phones' copy carries the log since then (`PhoneUseLog`): each tap's time and its stored amounts, and how many
///   taps are unvalued and since when; never an item, row, name or place.
/// - The phone (`RunsOut`): the copy's taps plus its own Used 1 changes not yet sent (valued on the phone when tapped,
///   from its copy's shares: `PhoneOutbox.Entry.use`), over the time since event mode came on, give the rate; what's
///   left ÷ the rate, the day it runs out. Any unvalued tap, the Mac's or its own, shows `someNotCounted` instead: a
///   lower total would show more days than there are (the lists job's rule: never enough when it can't be counted).
public enum UseLog {
    public static let keepDays = 90.0
    /// A mistaken Used 1 put right (B2-08, beta run 2): a phone's "1 more" on an item, the item screen's (marked
    /// PhoneEdit.correction; a scan's or an older phone's is a restock), cancels that phone's Used 1 on it
    /// (its row leaves the log, so "runs out on" isn't thrown off) when it is the very next change that phone made to
    /// that item and was tapped within this long of it, by the phone's own tap times (judgment call: long enough to
    /// notice the slip, short enough that a real restock rarely lands inside it).
    public static let cancelWithin: TimeInterval = 10 * 60

    public struct Entry: Equatable, Sendable {
        public let id: Int64
        public let at: Date
        public let row: Int64
        public let used: Double
        /// What the tap was worth to each supply, by kind; empty for a row in no supply; nil when it couldn't be valued.
        public let amounts: [String: Double]?
    }

    /// What `used` of a row is worth to each supply, from `shares` as they stand: by kind; empty when the count read
    /// the row and found it in no supply; nil (unvalued) when the shares don't know the row at its position with that
    /// Item (added, moved or renamed since the count), or there are no shares. A Private row is found in
    /// `private_rows` (by its fingerprint too when the lists job gave one).
    public static func value(position: Int, item: String, isPrivate: Bool, used: Double,
                             shares: SupplyShares?) -> [String: Double]? {
        guard let shares else { return nil }
        let print = SupplyShares.fingerprint(item)
        var found: [String: Double] = [:]
        for kind in shares.supplies {
            let per = isPrivate ? kind.privateRows?.first { $0.row == position && ($0.item ?? print) == print }?.per
                : kind.rows.first { $0.row == position && $0.item == print }?.per
            if let per { found[kind.kind, default: 0] += used * per }
        }
        if !found.isEmpty { return found }
        let known = shares.uncountedRows?.contains { $0.row == position && $0.item == print && $0.private == isPrivate }
        return known == true ? [:] : nil
    }

    static func amountsText(_ amounts: [String: Double]?) -> String? {
        guard let amounts, let data = try? JSONEncoder().encode(amounts) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// What the Mac knows of event mode when a Used 1 is applied: not yet read (log, keep 90 days), off (no log), or
    /// on since a time (log, keep since then).
    public enum Start: Equatable, Sendable {
        case unknown
        case off
        case on(Date)
    }

    /// The earliest tap a write keeps: event mode's start, or 90 days back if that is later; nil out of event mode.
    public static func keepFrom(_ start: Start, now: Date) -> Date? {
        let oldest = now.addingTimeInterval(-keepDays * 86_400)
        switch start {
        case .unknown: return oldest
        case .off: return nil
        case .on(let since): return max(since, oldest)
        }
    }

    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
}

/// One step of the log with a Used 1 or its undo: a tap added, one removed by its id, or, out of event mode, the whole
/// log emptied (nothing put back by its undo).
public enum UseLogStep: Codable, Equatable, Sendable {
    case add(at: String, used: Double, amounts: [String: Double]?)
    case remove(Int64)
    case clear
}

extension InventoryFile {
    /// Not in _grist_Tables, so Grist's reader of tables never sees it; the lists job doesn't read it.
    public static let useLogTable = "PrepareMe_UseLog"

    /// The log, oldest first; none before the first Used 1. Throws for a table of another shape (its first shape, with
    /// no amounts, among them) or a row that isn't a time, a row id, an amount used and its amounts (a JSON object of
    /// numbers, or NULL for unvalued): the log is then unreadable, never fatal (no row is written to it, and the copy
    /// carries none).
    public func useLog() throws -> [UseLog.Entry] {
        guard try hasTable(Self.useLogTable) else { return [] }
        return try db.query("SELECT id, at, row, used, amounts FROM \"\(Self.useLogTable)\" ORDER BY at, id").map { row in
            guard let id = row[0].whole, let text = Self.text(row[1]), let at = UseLog.date(text),
                  let item = row[2].whole, let used = row[3].number, used.isFinite, used > 0 else {
                throw InventoryFileError.noTable(Self.useLogTable)
            }
            var amounts: [String: Double]?
            switch row[4] {
            case .null: amounts = nil
            case .text(let json):
                guard let found = try? JSONDecoder().decode([String: Double].self, from: Data(json.utf8)),
                      found.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                    throw InventoryFileError.noTable(Self.useLogTable)
                }
                amounts = found
            default: throw InventoryFileError.noTable(Self.useLogTable)
            }
            return UseLog.Entry(id: id, at: at, row: item, used: used, amounts: amounts)
        }
    }

    /// A tap kept with its amounts (nil: unvalued), and the rows before `keepFrom` dropped, in one save; its id.
    /// `edit`: the phone change's id that made it (nil for the Mac's own), for a "1 more" that cancels it.
    func addUse(row: Int64, at: String, used: Double, amounts: [String: Double]?, keepFrom: Date?,
                edit: String? = nil) throws -> Int64 {
        guard !readOnly else { throw InventoryFileError.readOnly }
        return try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS "\(Self.useLogTable)" (id INTEGER PRIMARY KEY, at TEXT NOT NULL, \
                row INTEGER NOT NULL, used REAL NOT NULL, amounts TEXT, edit TEXT)
                """)
            let columns = try db.query("PRAGMA table_info(\"\(Self.useLogTable)\")").compactMap { Self.text($0[1]) }
            if !columns.contains("edit") {  // a log kept before B2-08: its rows stay, from no phone change known
                try db.execute("ALTER TABLE \"\(Self.useLogTable)\" ADD COLUMN edit TEXT")
            }
            try db.execute("INSERT INTO \"\(Self.useLogTable)\" (at, row, used, amounts, edit) VALUES (?, ?, ?, ?, ?)",
                           [.text(at), .int(row), .real(used), UseLog.amountsText(amounts).map { .text($0) } ?? .null,
                            edit.map { .text($0) } ?? .null])
            let id = try db.query("SELECT last_insert_rowid()").first?[0].whole ?? 0
            if let keepFrom {
                let old = try useLog().filter { $0.at < keepFrom }.map(\.id)
                for gone in old { try db.execute("DELETE FROM \"\(Self.useLogTable)\" WHERE id = ?", [.int(gone)]) }
            }
            return id
        }
    }

    /// The tap a phone's change made, or nil when none did. Throws for a log kept before change ids (no `edit` column
    /// until its next write) or one unreadable; the editor's `try?` reads that as nothing to cancel.
    func use(byEdit edit: String) throws -> UseLog.Entry? {
        guard try hasTable(Self.useLogTable),
              let id = try db.query("SELECT id FROM \"\(Self.useLogTable)\" WHERE edit = ?", [.text(edit)]).first?[0]
                .whole else { return nil }
        return try useLog().first { $0.id == id }
    }

    /// A tap removed (a Used 1 undone); what it was, or nil when it's gone already.
    func removeUse(_ id: Int64) throws -> UseLog.Entry? {
        guard !readOnly else { throw InventoryFileError.readOnly }
        guard let found = try useLog().first(where: { $0.id == id }) else { return nil }
        try db.execute("DELETE FROM \"\(Self.useLogTable)\" WHERE id = ?", [.int(id)])
        return found
    }

    /// Out of event mode: the whole log goes.
    func clearUseLog() throws {
        guard !readOnly, try hasTable(Self.useLogTable) else { return }
        try db.execute("DELETE FROM \"\(Self.useLogTable)\"")
    }
}

/// When event mode came on, as the hourly job wrote it (dashboard/event.py event_mode_file): `event-mode.json` in the
/// inventory folder. Missing or of another shape: not known.
public struct EventModeFile: Codable, Equatable, Sendable {
    public let format: Int
    public let mode: String
    public let since: String?
    public let written: String

    public static let fileName = "event-mode.json"

    public static func read(in folder: URL) -> EventModeFile? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let found = try? JSONDecoder().decode(EventModeFile.self, from: data), found.format == 1,
              found.mode == "event" || found.mode == "preparing" else { return nil }
        return found
    }

    /// The editor's `UseLog.Start`: on since its time, off, or unknown (no file, or event mode with no readable time).
    public static func start(_ found: EventModeFile?) -> UseLog.Start {
        guard let found else { return .unknown }
        if found.mode == "preparing" { return .off }
        return found.since.flatMap(UseLog.date).map(UseLog.Start.on) ?? .unknown
    }
}

/// The use log as the phones' copy carries it (step 8c, section 4): when event mode came on, each valued tap since then
/// as its supply and amount, and how many couldn't be valued and the earliest one's time; never a row, item, name or
/// place. Nil out of event mode.
public struct PhoneUseLog: Codable, Equatable, Sendable {
    public struct Tap: Codable, Equatable, Sendable {
        public let at: String
        public let kind: String
        public let amount: Double

        public init(at: String, kind: String, amount: Double) {
            self.at = at
            self.kind = kind
            self.amount = amount
        }
    }

    public let since: String
    public let taps: [Tap]
    public let unvalued: Int
    public let unvaluedSince: String?

    public init(since: String, taps: [Tap], unvalued: Int = 0, unvaluedSince: String? = nil) {
        self.since = since
        self.taps = taps
        self.unvalued = unvalued
        self.unvaluedSince = unvaluedSince
    }

    /// The copy's log: the taps since `since`, each by the amounts stored when the Mac applied it (no row is looked up
    /// now, so a row deleted, moved or renamed since still counts), and the unvalued ones counted with the earliest's
    /// time.
    public static func make(_ entries: [UseLog.Entry], since: Date) -> PhoneUseLog {
        var taps: [Tap] = []
        var unvalued: [Date] = []
        for entry in entries where entry.at >= since {
            guard let amounts = entry.amounts else {
                unvalued.append(entry.at)
                continue
            }
            for (kind, amount) in amounts.sorted(by: { $0.key < $1.key }) {
                taps.append(Tap(at: UseLog.stamp(entry.at), kind: kind, amount: amount))
            }
        }
        return PhoneUseLog(since: UseLog.stamp(since), taps: taps, unvalued: unvalued.count,
                           unvaluedSince: unvalued.min().map(UseLog.stamp))
    }
}

/// The phone's line under a supply's days in event mode (step 8c, section 4), and the rule under the lines. The
/// words are fixed and pinned (UseLogTests).
public enum RunsOut {
    public static let tooEarly = "Too early to tell"
    public static func runsOut(_ day: String) -> String { "At the use so far: runs out \(day)" }
    public static func notCounted(_ time: String) -> String { "Other phones' use since \(time) isn't counted" }
    /// A tap that couldn't be valued (its row added, moved or renamed since the count): no day, which would read too
    /// late (the reviewer's words, 2026-10-20)
    public static func someNotCounted(_ time: String) -> String { "Some use since \(time) can't be counted" }
    public static let rule = "The day it runs out divides what's left by what Used 1 has taken since event mode came "
        + "on, on every phone. It's too early to tell in event mode's first 24 hours, or before a Used 1 on that supply."
    /// Before a day of event mode, a rate isn't worth showing.
    public static let earliest: TimeInterval = 24 * 3600
    /// A copy older than this hasn't seen other phones' taps since (the phone away from home): the Mac rewrites it at
    /// least every 10 minutes and a phone at home takes it every 2 (judgment call, step 8c).
    public static let copyStale: TimeInterval = 3 * 3600

    /// One tap this phone made and hasn't sent: its time, and what it was worth to each supply when tapped (nil:
    /// unvalued).
    public struct OwnTap: Equatable, Sendable {
        public let at: Date
        public let amounts: [String: Double]?

        public init(at: Date, amounts: [String: Double]?) {
            self.at = at
            self.amounts = amounts
        }
    }

    /// A Used 1 made on this phone, valued as it's made from `copy` (what this phone shows, its own waiting changes in)
    /// and the copy's shares: its use for the outbox (`PhoneOutbox.Entry.use`), or nil for any other change.
    public static func use(of change: InventoryChange, in copy: PhoneInventory) -> PhoneOutbox.Use? {
        guard case .adjust(let id, let by) = change, by < 0 else { return nil }
        guard let row = copy.items.first(where: { $0.id == id }), let item = copy.column(Inventory.Label.item) else {
            return PhoneOutbox.Use(amounts: nil)
        }
        let quantity = copy.column(Inventory.Label.quantity).flatMap {
            InventoryValues.parseNumber(InventoryValues.plain(row.values[$0.colId] ?? .null)
                .trimmingCharacters(in: .whitespaces))
        }
        let used = min(-by, max(0, quantity ?? -by))  // never below 0, as the Mac applies it
        guard used > 0 else { return nil }
        return PhoneOutbox.Use(amounts: UseLog.value(position: row.position,
                                                     item: InventoryValues.plain(row.values[item.colId] ?? .null),
                                                     isPrivate: false, used: used, shares: copy.supply))
    }

    /// The log the phone's Supplies counts from, only in event mode (else nil, and no line shows): the copy's, while
    /// the Mac says event mode is on and the switch isn't Off; or, when this phone switched it On and the Mac hasn't
    /// answered yet, none since that time. `localSwitch` and `localAt`: this phone's own switch and when it set it.
    public static func log(_ copy: PhoneInventory, localSwitch: String?, localAt: Date?) -> PhoneUseLog? {
        let switched = localSwitch ?? copy.lists?.eventMode ?? "Auto"
        if switched == "Off" { return nil }
        if let found = copy.useLog { return found }
        if switched == "On", let localAt { return PhoneUseLog(since: UseLog.stamp(localAt), taps: []) }
        return nil
    }

    /// This phone's Used 1 changes waiting for the Mac, with their tap time and the use they were valued at; one kept
    /// before that was stored (no `use`) is unvalued; an edit from before step 8c (no time) isn't counted, nor quick
    /// add's 1 less (a correction, never a use).
    public static func ownTaps(_ outbox: PhoneOutbox) -> [OwnTap] {
        outbox.pending.compactMap { entry in
            guard case .adjust(_, let by) = entry.edit.change, by < 0, entry.edit.correction != true,
                  let at = entry.edit.at.flatMap(UseLog.date) else { return nil }
            return OwnTap(at: at, amounts: entry.use?.amounts)
        }
    }

    /// The line for `kind`: too early (under a day of event mode, or no tap on it), other phones' use not counted (the
    /// copy is stale), some use not counted (a tap since event mode came on that couldn't be valued, the Mac's or this
    /// phone's), or the day it runs out. `copy` is the Mac's copy as it came; `have` what's left now, in the supply's
    /// unit (SupplyShares.have), nil when it can't be counted.
    public static func line(_ kind: SupplyShares.Kind, copy: PhoneInventory, log: PhoneUseLog, own: [OwnTap],
                            have: Double?, now: Date = Date()) -> String {
        guard let since = UseLog.date(log.since), now.timeIntervalSince(since) >= earliest else { return tooEarly }
        if let written = ISO8601DateFormatter().date(from: copy.writtenAt), now.timeIntervalSince(written) > copyStale {
            return notCounted(shortTime(written))
        }
        let mine = own.filter { $0.at >= since }
        var unvalued = mine.filter { $0.amounts == nil }.map(\.at)
        if log.unvalued > 0 { unvalued.append(log.unvaluedSince.flatMap(UseLog.date) ?? since) }
        if let first = unvalued.min() { return someNotCounted(shortTime(first)) }
        let used = log.taps.filter { $0.kind == kind.kind }.reduce(0) { $0 + $1.amount }
            + mine.reduce(0) { $0 + ($1.amounts?[kind.kind] ?? 0) }
        guard used > 0, let have else { return tooEarly }
        let perDay = used / (now.timeIntervalSince(since) / 86_400)
        let out = now.addingTimeInterval(max(0, have) / perDay * 86_400)
        return runsOut(day(out))
    }

    /// "Sat Oct 31" in the household's time.
    public static func day(_ date: Date) -> String { format("EEE MMM d").string(from: date) }

    /// "Oct 20, 2:37 PM" in the household's time.
    public static func shortTime(_ date: Date) -> String { format("MMM d, h:mm a").string(from: date) }

    static func format(_ pattern: String) -> DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "America/New_York")
        format.dateFormat = pattern
        return format
    }
}
