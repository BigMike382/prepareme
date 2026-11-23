import Foundation

/// Which columns the Mac's items' table shows and in what order (the inventory fresh look, phase 1, spec 5.2). The app
/// keeps the hidden labels and the sort in its own settings, never in the file; this decides what they mean.
public enum ItemsTableColumns {
    /// Off until ticked (owner, 2026-10-31: fewer cells to draw on each save): each stays in the item's form, and
    /// search still reads them. `ManualRow.label` is the app's, so Manual is the literal "Manual" here.
    public static let hiddenAtFirst = [Inventory.Label.model, "Year", "Manual", "Notes",
                                       Inventory.Label.caloriesEach, Inventory.Label.eachHolds, Inventory.Label.holdsUnit,
                                       Inventory.Label.petFoodFor, Inventory.Label.runningWatts,
                                       Inventory.Label.startingWatts, Inventory.Label.emptyUntilNeeded,
                                       Inventory.Label.keepPastDate, Inventory.Label.privateRow, Insurance.purchased,
                                       Insurance.price, Insurance.serial]

    public static let firstOrder = ["Item", "Quantity", "Unit", "Location", "Category", "Expires", "Grab", "Brand"]

    /// `labels` (the file's order) with `firstOrder`'s first, then the rest as the file has them.
    public static func ordered(_ labels: [String]) -> [String] { orderedIndices(labels).map { labels[$0] } }

    /// `ordered` by position, so two columns with one label (or "Item" and "item ") are each kept once (phase 1 fixes,
    /// finding 7: matched by label, one was dropped or listed twice, and the widths' dictionary trapped).
    public static func orderedIndices(_ labels: [String]) -> [Int] {
        var first: [Int] = []
        for want in firstOrder {
            if let at = labels.indices.first(where: { !first.contains($0) && InventoryFile.same(labels[$0], want) }) {
                first.append(at)
            }
        }
        return first + labels.indices.filter { !first.contains($0) }
    }

    /// Every column the Columns menu lists: the items' in `ordered` order less what the view leaves out whatever is
    /// ticked (`leftOut`); another table's in the file's order.
    public static func tickable(_ all: [InventoryColumn], items: Bool, leftOut: [String]) -> [InventoryColumn] {
        guard items else { return all }
        return orderedIndices(all.map(\.label)).map { all[$0] }
            .filter { column in !leftOut.contains { InventoryFile.same($0, column.label) } }
    }

    /// The columns shown, of `tickable`: less the hidden labels, but `first` always shows (`shown`).
    public static func shownColumns(_ tickable: [InventoryColumn], hidden: [String], first: String) -> [InventoryColumn] {
        tickable.filter { !shown([$0.label], hidden: hidden, leftOut: [], first: first).isEmpty }
    }

    /// Whether hiding `label` takes away the column the table is sorted by, so the sort goes too (phase 1 fixes,
    /// finding 5: the rows stayed sorted with no arrow). "#" can't be hidden.
    public static func dropsSort(hiding label: String, sortedBy: String?) -> Bool {
        guard let sortedBy, sortedBy != "#" else { return false }
        return InventoryFile.same(label, sortedBy)
    }

    /// What a view leaves out whatever is ticked, since every row would say the same: Category in a category's;
    /// Location in a place's with no bins (a place with bins keeps it, which tells the bins apart).
    public static func leftOut(_ view: Inventory.View, binsInside: Int) -> [String] {
        switch view {
        case .category: [Inventory.Label.category]
        case .location where binsInside == 0: [Inventory.Label.location]
        default: []
        }
    }

    /// The labels shown, of `labels` (already `ordered`): less the hidden and the left out, but `first` always
    /// shows. A saved label the file no longer has is simply never matched.
    public static func shown(_ labels: [String], hidden: [String], leftOut: [String], first: String) -> [String] {
        labels.filter { label in
            InventoryFile.same(label, first) || !(hidden + leftOut).contains { InventoryFile.same($0, label) }
        }
    }

    /// The hidden labels after a tick: `label` taken out or added once. The others stay as they were, those the file
    /// doesn't have yet included, so a column the insurance record adds later still starts hidden.
    public static func hiding(_ label: String, _ hide: Bool, in hidden: [String]) -> [String] {
        hidden.filter { !InventoryFile.same($0, label) } + (hide ? [label] : [])
    }

    /// A saved sort that still names a column: nil when `labels` no longer has it.
    public static func sort(_ saved: SavedSort?, among labels: [String]) -> SavedSort? {
        guard let saved, labels.contains(where: { InventoryFile.same($0, saved.label) }) else { return nil }
        return saved
    }
}

/// The items' table's sort as the Mac remembers it between launches.
public struct SavedSort: Codable, Equatable, Sendable {
    public let label: String
    public let ascending: Bool

    public init(label: String, ascending: Bool) { (self.label, self.ascending) = (label, ascending) }
}

/// The starting widths, fitted to the window at every opening (phase 0: the Mac's own column memory squeezed the
/// columns as the table opened, `docs/design/inventory-fresh-look/proving.md`).
extension ItemsTableColumns {
    /// The one width the widest columns are capped at so `wants` (each shown column's fitted width) fits `room`;
    /// never below `least`. `.infinity` when they fit as they are.
    public static func cap(_ wants: [Double], room: Double, least: Double = 100) -> Double {
        guard wants.reduce(0, +) > room else { return .infinity }
        var left = room
        var count = Double(wants.count)
        for want in wants.sorted() {
            if want * count > left { return max(left / count, least) }  // this one and every wider one share it
            left -= want  // narrow enough to stay whole
            count -= 1
        }
        return least  // not reached: the sum was over `room`
    }

    /// Each shown column's starting width. The column at `first` (Item; Name on Locations and Categories) is the
    /// last one trimmed (owner, 2026-11-17, by click): the others are capped by `cap` in the room it leaves; only
    /// when they are all down to `least` does it give way, never below `least` itself. `first` nil: one cap for all.
    public static func widths(_ wants: [Double], first: Int?, room: Double, least: Double = 100) -> [Double] {
        guard let first, wants.indices.contains(first) else {
            let cap = cap(wants, room: room, least: least)
            return wants.map { min($0, cap) }
        }
        var others = wants
        let item = others.remove(at: first)
        let cap = cap(others, room: room - item, least: least)
        var result = others.map { min($0, cap) }
        let rest = result.reduce(0, +)
        result.insert(min(item, max(least, room - rest)), at: first)
        return result
    }

    /// The room for the shown columns: the table less the "#" column, a 17-point gap beside each column, the scroller
    /// (17 points measured, phase 1) and 1 point to spare: at 16 the row ran 1 point past and took a sideways scroller.
    public static func room(tableWidth: Double, shown: Int) -> Double { tableWidth - 48 - 17 * Double(shown + 1) - 18 }

    /// Each shown column's starting width, by colId: `fitted` (120 for one not measured), the widest capped by
    /// `widths` so they fit `tableWidth`, the `first` column the last trimmed. A column listed twice is kept once.
    public static func starts(_ shown: [InventoryColumn], fitted: [String: Double], first: String,
                              tableWidth: Double) -> [String: Double] {
        let found = widths(shown.map { fitted[$0.colId] ?? 120 },
                           first: shown.firstIndex { InventoryFile.same($0.label, first) },
                           room: room(tableWidth: tableWidth, shown: shown.count))
        return Dictionary(zip(shown.map(\.colId), found), uniquingKeysWith: { a, _ in a })
    }

    /// The width a table's columns are fitted to: the one it was built at while it stays the same table (`key`: its
    /// table, shown columns and Reset Columns' count), so a resize leaves the widths to the table; a fresh table takes
    /// the live width (phase 1 fixes, finding 3: it was measured once per inventory screen).
    public static func fitWidth(key: String, fittedKey: String?, fittedWidth: Double?, live: Double?) -> Double? {
        key == fittedKey ? (fittedWidth ?? live) : live
    }
}

/// What the Mac remembers of the inventory's tables between launches (the inventory fresh look, spec 5.2): the hidden
/// columns and the sort, never their widths (fitted again at every opening: phase 0), in the Mac's own settings, never
/// the inventory file. Keyed by the app's `InventoryDetail.columnsKey`: "items" for every items' table, else the table.
public struct InventoryTableMemory {
    public static let columnsPrefix = "prepareme.mac.inventoryColumns.", sortPrefix = "prepareme.mac.inventorySort."
    let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The hidden labels: saved, else the items' hidden-at-first list, none on Locations and Categories. A value
    /// that doesn't read counts as none saved.
    public func hidden(_ key: String) -> [String] {
        read([String].self, Self.columnsPrefix + key) ?? (key == "items" ? ItemsTableColumns.hiddenAtFirst : [])
    }

    public func setHidden(_ labels: [String], _ key: String) { write(labels, Self.columnsPrefix + key) }

    public func sort(_ key: String) -> SavedSort? { read(SavedSort.self, Self.sortPrefix + key) }

    /// The sort saved; nil forgets it (its column was hidden).
    public func setSort(_ sort: SavedSort?, _ key: String) {
        guard let sort else { return defaults.removeObject(forKey: Self.sortPrefix + key) }
        write(sort, Self.sortPrefix + key)
    }

    /// Reset Columns: the hidden labels forgotten, so the first opening's list applies again.
    public func forget(_ key: String) { defaults.removeObject(forKey: Self.columnsPrefix + key) }

    /// Every table's hidden columns and sort forgotten, as at the first launch (the check build's COLUMNS_FRESH).
    public func forgetAll() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.columnsPrefix) || key.hasPrefix(Self.sortPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        defaults.string(forKey: name).flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }

    func write(_ value: some Encodable, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: name)
    }
}
