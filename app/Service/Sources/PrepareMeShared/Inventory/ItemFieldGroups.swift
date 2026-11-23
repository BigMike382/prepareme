import Foundation

/// The item entry screens' groups (owner, 2026-10-22, by click: docs/plans/2026-10-22-item-entry-redesign.md), one
/// order shared by the phone's Add/Edit item and Quick add card and the Mac's New item, Add by barcode and item form,
/// so they can't drift apart: each column to its group by its label, the groups in order, More details folded.
public enum ItemFieldGroup: String, CaseIterable, Sendable {
    case what, howMany, kept, food, dates, more

    public var title: String {
        switch self {
        case .what: "What it is"
        case .howMany: "How many"
        case .kept: "Where it's kept"
        case .food: "Food"
        case .dates: "Dates"
        case .more: "More details"
        }
    }

    /// Its SF Symbol, beside the title.
    public var symbol: String {
        switch self {
        case .what: "shippingbox"
        case .howMany: "number"
        case .kept: "house"
        case .food: "fork.knife"
        case .dates: "calendar"
        case .more: "ellipsis.circle"
        }
    }

    /// Each named column's group, in its order there; any other column (Serial number, Price, the insurance record's)
    /// goes last in More details.
    static let placed: [(String, ItemFieldGroup)] = [
        (Inventory.Label.item, .what), ("Brand", .what), (Inventory.Label.category, .what),
        (Inventory.Label.petFoodFor, .what), (Inventory.Label.runningWatts, .what),
        (Inventory.Label.startingWatts, .what),
        (Inventory.Label.quantity, .howMany), ("Unit", .howMany), (Inventory.Label.eachHolds, .howMany),
        (Inventory.Label.holdsUnit, .howMany), (Inventory.Label.emptyUntilNeeded, .howMany),
        (Inventory.Label.location, .kept), (Inventory.Label.grab, .kept),
        (Inventory.Label.caloriesEach, .food),
        (Inventory.Label.expires, .dates), (Inventory.Label.keepPastDate, .dates), ("Year", .dates),
        (Inventory.Label.model, .more), ("Manual", .more), ("Notes", .more),
    ]

    public static func of(_ label: String) -> ItemFieldGroup {
        placed.first { InventoryFile.same($0.0, label) }?.1 ?? .more
    }

    /// The labels in their groups, groups in order, each group's labels in the order above, then the rest as given;
    /// an empty group is left out.
    public static func grouped(_ labels: [String]) -> [(group: ItemFieldGroup, labels: [String])] {
        func rank(_ label: String) -> Int { placed.firstIndex { InventoryFile.same($0.0, label) } ?? placed.count }
        let sorted = labels.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        return allCases.compactMap { group in
            let found = sorted.filter { of($0) == group }
            return found.isEmpty ? nil : (group, found)
        }
    }

    /// Columns of any kind in their groups, by their labels.
    public static func grouped<Column>(_ columns: [Column], label: (Column) -> String)
        -> [(group: ItemFieldGroup, columns: [Column])] {
        grouped(columns.map(label)).map { entry in
            (entry.group, entry.labels.compactMap { name in columns.first { label($0) == name } })
        }
    }

    /// Whether the Food group shows (owner, 2026-10-22: the food rows only for food): the category's group (its
    /// Counts as) is Food, Calories each already holds a figure, or a scan found a food. By group, never the name, so
    /// the owner's "Canned goods" counting as Food shows it too (entry fixes plan, Task 1.2, 2026-10-23).
    public static func showsFood(group: String?, calories: String, scannedFood: Bool = false) -> Bool {
        group.map { InventoryFile.same($0, "Food") } == true || !calories.trimmingCharacters(in: .whitespaces).isEmpty
            || scannedFood
    }

    /// The field Return moves to after `id`, in `order` (the form's typed fields in their groups' order), or nil after
    /// the last one, where the keyboard says Done (entry fixes plan, Task 2.2, 2026-10-23).
    public static func next(after id: String, in order: [String]) -> String? {
        guard let at = order.firstIndex(of: id), at + 1 < order.count else { return nil }
        return order[at + 1]
    }

    /// Whether a field shows for an item (entry fixes plan, phase 3, 2026-10-23): Each holds and its Holds unit for a
    /// package counted each in Water, Pets, Power and fuel or Heat and shelter (showsHolds); Pet food for in Pets; the
    /// Running and Starting watts when the item's name says generator (never a "solar generator", a power station).
    /// Every other field always, and any field that already holds something (`filled`), so it can be seen and cleared
    /// (phase 3's review: a hidden Pet food for still counted after a category change).
    public static func shows(_ label: String, group: String?, unit: String, item: String, filled: Bool = false) -> Bool {
        if filled { return true }
        if [Inventory.Label.eachHolds, Inventory.Label.holdsUnit].contains(where: { InventoryFile.same($0, label) }) {
            return showsHolds(group: group, unit: unit)
        }
        if InventoryFile.same(label, Inventory.Label.petFoodFor) {
            return group.map { InventoryFile.same($0, "Pets") } ?? false
        }
        if [Inventory.Label.runningWatts, Inventory.Label.startingWatts].contains(where: { InventoryFile.same($0, label) }) {
            return item.range(of: "generator", options: [.caseInsensitive, .diacriticInsensitive]) != nil
                && item.range(of: "solar", options: [.caseInsensitive, .diacriticInsensitive]) == nil
        }
        return true
    }

    /// Each holds shows for a package counted each (ProductLookup.isPackageUnit) in a supply that counts what one holds.
    /// Food too (owner, 2026-10-28: a dry staple's pounds count by readiness/staples.py), but only for a bag, box or
    /// pack: a can, jar, bottle or carton's label gives calories per container, which go in Calories each.
    public static func showsHolds(group: String?, unit: String) -> Bool {
        guard ProductLookup.isPackageUnit(unit), let group else { return false }
        if InventoryFile.same(group, "Food") {
            return !foodContainers.contains { InventoryFile.same($0, unit) }
        }
        return ["Water", "Pets", "Power and fuel", "Heat and shelter"].contains { InventoryFile.same($0, group) }
    }

    /// Food units whose label counts calories per container, so Each holds stays hidden on them.
    static let foodContainers = ["can", "cans", "jar", "jars", "bottle", "bottles", "carton", "cartons"]

    /// The line under Each holds, in the forms' words (pinned).
    public static let holdsHint = "Each holds (when full): what one holds, like 5 for a 5-gallon jug, in the Holds unit."

    /// Whether More details starts open: when any of its fields already holds something.
    public static func opensMore(_ filled: [String]) -> Bool {
        filled.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
