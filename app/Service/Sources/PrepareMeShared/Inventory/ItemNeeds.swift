import Foundation

/// What an item form says, as you type, about whether a supply's count will miss a field (inventory fresh look, spec
/// 5.3). Judged by the category's Counts as and the unit words the lists job counts in (`SupplyShares.units`), never by
/// the item's name; nil for an item no supply counts, or with no `units` from the lists job to judge by. A blank
/// Quantity on an item a Quantity would count is amber (owner, 2026-11-18, by click, after Bought… on a water line in
/// gallons opened with no line): the count leaves that row out. The green line restates what the count
/// will read, as typed, with no conversion (owner, 2026-11-18, after the review): "… water count: 24 × 16.9 fl oz."
public enum ItemNeeds {
    public enum Line: Equatable, Sendable { case missing(String), complete(String) }

    public static let waterHolds = "Won't count toward water yet: say what each one holds."
    public static let waterUnit = "Won't count toward water in this unit: use fl oz, gallons or liters."
    public static let foodMissing = "Won't count toward food yet: add its calories, or count a dry staple in pounds."
    public static let petPick = "Pick Pet food for, so this counts as dog or cat food."
    /// `count` is "water", "food", "dog food" or "cat food"; `amount` what it will read ("6 gallons", "12 × 180 calories").
    public static func complete(_ count: String, _ amount: String) -> String {
        "Nothing missing for the \(count) count: \(amount)."
    }
    public static func petUnit(_ kind: String) -> String { "Won't count as \(kind) food in this unit: use pounds." }
    /// `count` as in `complete`, or "pet food" before Pet food for is picked.
    public static func noQuantity(_ count: String) -> String { "Won't count toward \(count) yet: write how many." }

    public static func line(group: String?, quantity: Double?, unit: String, holds: Double?, holdsUnit: String,
                            calories: Double?, petFoodFor: String, emptyUntilNeeded: Bool,
                            units: SupplyShares.Units?) -> Line? {
        guard let units, let group, !emptyUntilNeeded else { return nil }
        let kind = petKind(petFoodFor)
        guard let quantity else {  // amber wherever a Quantity of 1 would get a line, naming the count it misses
            guard line(group: group, quantity: 1, unit: unit, holds: holds, holdsUnit: holdsUnit, calories: calories,
                       petFoodFor: petFoodFor, emptyUntilNeeded: false, units: units) != nil else { return nil }
            let water = InventoryFile.same(group, "Water")
            let pets = InventoryFile.same(group, "Pets") || !kind.isEmpty
            return .missing(noQuantity(water ? "water" : !pets ? "food" : kind.isEmpty ? "pet food" : "\(kind) food"))
        }
        let m = SupplyShares.measured(unit: unit, holds: holds, holdsUnit: holdsUnit)
        // a unit shown as typed but for its spaces (phase 2 review, M9): "fl  oz" reads "fl oz", as the count reads it
        func spaced(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func normal(_ text: String) -> String { spaced(text).lowercased() }
        let own = normal(unit)
        let count = InventoryValues.number(quantity)
        // measured by its Each holds (a package unit and a measure never share a word): Quantity × what one holds
        let amount = m.unit != own
            ? "\(count) × \(InventoryValues.number(m.each)) \(spaced(holdsUnit))"
            : "\(count) \(spaced(unit))"
        func pet() -> Line? {
            if kind.isEmpty {
                // only what could be food by its fields: in pounds, or counted in a package other than blank or each
                let food = units.pounds.contains(own) || units.pounds.contains(normal(holdsUnit))
                    || (ProductLookup.packageUnits.contains(own) && own != "" && own != "each")
                return food ? .missing(petPick) : nil
            }
            return units.pounds.contains(m.unit) ? .complete(complete("\(kind) food", amount)) : .missing(petUnit(kind))
        }
        if InventoryFile.same(group, "Water") {
            if units.water.contains(m.unit) { return .complete(complete("water", amount)) }
            // a package whose Each holds is filled in another unit isn't missing the Each holds
            let package = ProductLookup.isPackageUnit(unit) && !(holds ?? 0 > 0 && !holdsUnit.isEmpty)
            return .missing(package ? waterHolds : waterUnit)
        }
        if InventoryFile.same(group, "Food") {
            // a filled Pet food for counts it as pet food whatever its category (readiness/supply.py food_share)
            if !kind.isEmpty { return pet() }
            // calories count in any unit; a dry staple in pounds is the count's call, not ours
            // a calorie unit counts its Quantity as calories before any Calories each (readiness/supply.py food_share)
            if units.calories.contains(own) { return .complete(complete("food", amount)) }
            if let calories, calories > 0 {
                return .complete(complete("food", "\(count) × \(InventoryValues.number(calories)) calories"))
            }
            return units.pounds.contains(m.unit) ? nil : .missing(foodMissing)
        }
        return InventoryFile.same(group, "Pets") ? pet() : nil
    }

    /// What VoiceOver hears as the line changes (phase 2 review, M3): its words when it appears, turns amber or green,
    /// or amber names another field; nothing as its amount changes with each keystroke, nor when it goes.
    public static func announcement(from old: Line?, to new: Line?) -> String? {
        guard let new else { return nil }
        switch (old, new) {
        case (.complete?, .complete): return nil
        case (.missing(let was)?, .missing(let now)): return was == now ? nil : now
        case (_, .missing(let words)), (_, .complete(let words)): return words
        }
    }

    /// Pet food for as the lists job reads it (readiness/inventory.py): one of its choices in any case, lowercased, or
    /// blank for anything else ("Dogs" counts as no kind there, so it does here).
    public static func petKind(_ typed: String) -> String {
        Inventory.Label.petFoodChoices.first { InventoryFile.same($0, typed) }?.lowercased() ?? ""
    }
}

extension Inventory {
    /// The Mac forms' line (Task 2.6): an item's row, with what is being typed in its boxes (`typed`, by column id)
    /// read over the row's own values, and its category's Counts as.
    public func needsLine(_ row: InventoryRow, typed: [String: String] = [:],
                          units: SupplyShares.Units?) -> ItemNeeds.Line? {
        func text(_ label: String) -> String {
            items.column(label).map { typed[$0.colId] ?? InventoryValues.plain(row[$0]) } ?? ""
        }
        return ItemNeeds.line(group: group(of: row), quantity: InventoryValues.parseNumber(
                                  text(Label.quantity).trimmingCharacters(in: .whitespaces)),
                              unit: text("Unit"),
                              holds: InventoryValues.parseNumber(text(Label.eachHolds)),
                              holdsUnit: text(Label.holdsUnit),
                              calories: InventoryValues.parseNumber(text(Label.caloriesEach)),
                              petFoodFor: text(Label.petFoodFor),
                              emptyUntilNeeded: items.column(Label.emptyUntilNeeded).map { row[$0].whole == 1 }
                                  ?? false,
                              units: units)
    }
}
