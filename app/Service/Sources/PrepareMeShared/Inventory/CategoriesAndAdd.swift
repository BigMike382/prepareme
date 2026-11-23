import Foundation

/// The Mac sidebar's one Categories list (beta run 2, B2-29; mockup 4). A category shows "counts as <group>" under its
/// name only where the group differs from the name; the group's view is reached from that line, so no name appears in
/// two sections.
public enum CategoryList {
    public struct Entry: Equatable, Identifiable, Sendable {
        public let id: Int64
        public let name: String
        /// The group it counts as, only where that differs from `name` (any case or spacing); the line opens its view.
        public let countsAs: String?
    }

    public static func entries(_ categories: [(id: Int64, name: String, group: String?)]) -> [Entry] {
        categories.map { category in
            let group = category.group?.trimmingCharacters(in: .whitespaces) ?? ""
            let differs = !group.isEmpty && !InventoryFile.same(group, category.name)
            return Entry(id: category.id, name: category.name, countsAs: differs ? group : nil)
        }
    }

}

extension Inventory {
    /// The Mac sidebar's Categories, in the table's order.
    public var sidebarCategories: [CategoryList.Entry] {
        let nameColumn = categories.column(Label.name)
        return CategoryList.entries(categoryRows.map { row in
            let found = nameColumn.map { InventoryValues.plain(row[$0]) } ?? ""
            // its Counts as, or when blank the lists' own group for its name (group(ofCategory:))
            return (row.id, found.isEmpty ? "Row \(row.position)" : found, group(ofCategory: row.id))
        })
    }
}

extension Inventory {
    /// Every item's name, folded once, for "Already in the inventory" (kept per save: the Mac's KeyedCache).
    public var itemNames: ItemMatch.Names { ItemMatch.Names(itemRows.map { ($0.id, name(ofItem: $0)) }) }

    /// The Mac's Add: the item already named `typed`, with the line to show ("Already in the inventory: …"), or nil;
    /// looked up in `names` (itemNames, folded once per save rather than on every keystroke: checkpoint 2).
    public func alreadyThere(named typed: String, in names: ItemMatch.Names) -> (id: Int64, line: String)? {
        guard let id = names.existing(named: typed), let row = itemRows.first(where: { $0.id == id }) else { return nil }
        let amount = ["Quantity", "Unit"].compactMap { label in
            items.column(label).map { InventoryValues.plain(row[$0]) }
        }.filter { !$0.isEmpty }.joined(separator: " ")
        let place = items.column(Label.location).flatMap { row[$0].whole }.map(path(ofLocation:)) ?? ""
        return (id, ItemMatch.line(name: name(ofItem: row), amount: amount, place: place))
    }
}

/// B2-30 (mockup 5): one supply group with its calculators, whether or not anything is stocked.
public struct SupplyCalculators: Equatable, Sendable {
    public let group: String
    public let itemCount: Int
    public let line: CalculatorLinks.Line
    /// "none entered" says why a group's days are missing
    public var stocked: String {
        itemCount == 0 ? "none entered" : "\(itemCount) item\(itemCount == 1 ? "" : "s")"
    }
}

extension PhoneInventory {
    /// A row's cell as the phone shows it (a reference by its row's name, a date as a day).
    public func cell(_ row: Row, _ column: Column) -> String {
        InventoryValues.shown(row.values[column.colId] ?? .null, in: inventoryColumn(column), names: names(column))
    }

    /// The item's name as the phone shows it, in title case (InventoryLook; the file keeps it as typed), "Unnamed
    /// Item" when none.
    public func shownName(_ row: Row) -> String {
        let found = itemName(row)
        return found.isEmpty ? "Unnamed Item" : InventoryLook.title(found)
    }

    /// The item's name as its Item cell shows ("" when none): what Add matches on, so it matches the name it shows.
    public func itemName(_ row: Row) -> String {
        column("Item").map { cell(row, $0) } ?? ""
    }

    /// The item's Unit as its cell shows ("gallons"), "" when none.
    public func unitWord(of row: Row) -> String {
        column("Unit").map { cell(row, $0) } ?? ""
    }

    /// Every one of the lists' groups that has calculators, in the lists' order, with how many items it holds on this
    /// phone and its calculators' links; an empty group is listed all the same.
    public func supplyCalculators(links: CalculatorLinks, figures: CalculatorFigures?) -> [SupplyCalculators] {
        let categoryColumn = column("Category")
        // an older copy's categories carry no group: the lists' own group for the name, as the Mac reads it
        let groupOf = Dictionary(categories.map { ($0.id, $0.group ?? ToBuyList.group(ofName: $0.name) ?? "") },
                                 uniquingKeysWith: { first, _ in first })
        return ToBuyList.groups.dropLast().compactMap { group in
            let held = items.filter { row in
                guard let id = categoryColumn.flatMap({ row.values[$0.colId]?.whole }),
                      let found = groupOf[id] else { return false }
                return InventoryFile.same(found, group)
            }
            let line = links.line(group: group, itemNames: held.map(itemName), figures: figures)
            return line.links.isEmpty ? nil : SupplyCalculators(group: group, itemCount: held.count, line: line)
        }
    }
}

/// "Already in the inventory: Canned soup, 12 cans, Pantry. Add to that instead?" on Add (beta run 2, fresh eyes).
public enum ItemMatch {
    public static let goTo = "Go to that item"
    /// Quick add's, beside it (addition D, owner 2026-11-18): the repeat scan's 1 more, in its question's words
    public static let addOne = "Add 1 to it"

    /// The items' names folded once, so the add forms look a typed name up instead of folding every name again on
    /// each keystroke (checkpoint 2). A name matches as search does (case, accents and edge spaces folded); the first
    /// item of a name wins, and a blank name matches nothing.
    public final class Names {
        private let ids: [String: Int64]

        public init(_ items: [(id: Int64, name: String)]) {
            var found: [String: Int64] = [:]
            for item in items {
                let key = ItemMatch.key(item.name)
                if !key.isEmpty, found[key] == nil { found[key] = item.id }
            }
            ids = found
        }

        /// The id of the item named `typed`, or nil for a blank name or no match.
        public func existing(named typed: String) -> Int64? {
            let key = ItemMatch.key(typed)
            return key.isEmpty ? nil : ids[key]
        }
    }

    static func key(_ name: String) -> String { PhoneSearch.fold(name.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// The item named as `name` kept in `place` (quick add, entry fixes Task 2.7): a product scanned in a second place,
    /// where an item of its name is already, adds 1 to that one instead of asking. Nil with no place or no such item.
    public static func inPlace(named name: String, place: Int64,
                               _ items: [(id: Int64, name: String, place: Int64?)]) -> Int64? {
        let wanted = key(name)
        guard !wanted.isEmpty, place != 0 else { return nil }
        return items.first { $0.place == place && key($0.name) == wanted }?.id
    }

    /// The item exactly as stored, with its amount and place when it has them.
    public static func line(name: String, amount: String, place: String) -> String {
        let parts = [name, amount, place].filter { !$0.isEmpty }.joined(separator: ", ")
        return "Already in the inventory: \(parts). Add to that instead?"
    }
}

/// The unit on Used 1 (beta run 2, fresh eyes: jugs counted in gallons): "Used 1 gallon". A plural unit reads as one;
/// "each" or no unit reads as plain "Used 1".
public enum UnitWords {
    /// Known household plurals and their singular. A unit is changed only through this table.
    static let plurals: [String: String] = [
        "gallons": "gallon", "quarts": "quart", "pints": "pint", "liters": "liter", "litres": "litre",
        "ounces": "ounce", "pounds": "pound", "lbs": "lb", "cans": "can", "bottles": "bottle", "jars": "jar",
        "boxes": "box", "bags": "bag", "packs": "pack", "packets": "packet", "rolls": "roll", "pairs": "pair",
        "tubes": "tube", "loaves": "loaf", "batteries": "battery", "cases": "case", "pouches": "pouch",
        "tablets": "tablet", "pills": "pill", "doses": "dose", "cartons": "carton", "cartridges": "cartridge",
        "bars": "bar", "buckets": "bucket", "cylinders": "cylinder", "tanks": "tank", "sheets": "sheet",
        "cords": "cord", "cups": "cup", "packages": "package", "containers": "container", "bundles": "bundle",
        "sets": "set", "kits": "kit", "tins": "tin", "capsules": "capsule", "strips": "strip",
        "jugs": "jug", "pieces": "piece", "bulbs": "bulb",
        "candles": "candle", "filters": "filter", "masks": "mask", "gloves": "glove", "blankets": "blanket",
    ]
    /// Singulars and abbreviations shown as typed.
    static let singulars: Set<String> = Set(plurals.values).union([
        "ml", "l", "oz", "lb", "kwh", "wh", "gal", "qt", "pt", "g", "kg", "mg", "lt", "ft", "m", "kw", "w", "v", "ah",
    ])

    /// The unit for "Used 1 <unit>": a known plural as its singular (in the typed capitalization), a known singular or
    /// abbreviation as typed; nil for "each", blank or anything else, so the button says plain "Used 1".
    public static func singular(_ unit: String) -> String? {
        let typed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.lowercased()
        if let one = plurals[key] { return styled(one, like: typed) }
        return singulars.contains(key) ? typed : nil
    }

    static func styled(_ word: String, like typed: String) -> String {
        if typed.count > 1, typed == typed.uppercased() { return word.uppercased() }
        if let first = typed.first, first.isUppercase { return word.prefix(1).uppercased() + word.dropFirst() }
        return word
    }

    public static func used(_ unit: String) -> String { singular(unit).map { "Used 1 \($0)" } ?? "Used 1" }
    public static func more(_ unit: String) -> String { singular(unit).map { "1 more \($0)" } ?? "1 more" }
}
