import Foundation
import PrepareMeShared
import Testing

/// The item forms' what's-missing line (inventory fresh look, Task 2.2; spec 5.3), and the lists job's `units` it reads.
struct ItemNeedsTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let units = SupplyShares.Units(
        water: ["gallon", "gallons", "gal", "liter", "liters", "fl oz"], pounds: ["pound", "pounds", "lb", "lbs"],
        calories: ["calorie", "calories"])

    func line(_ group: String?, _ unit: String, quantity: Double? = 1, holds: Double? = nil, holdsUnit: String = "",
              calories: Double? = nil, pet: String = "", empty: Bool = false,
              units: SupplyShares.Units? = ItemNeedsTests.units) -> ItemNeeds.Line? {
        ItemNeeds.line(group: group, quantity: quantity, unit: unit, holds: holds, holdsUnit: holdsUnit,
                       calories: calories, petFoodFor: pet, emptyUntilNeeded: empty, units: units)
    }

    @Test func nothingWithoutUnitsGroupOrForAnEmptyContainer() {
        #expect(line("Water", "gallons", units: nil) == nil)
        #expect(line(nil, "gallons") == nil)
        #expect(line("Water", "gallons", empty: true) == nil)
        #expect(line("Tools and equipment", "each") == nil)
    }

    /// The count leaves out a row with no Quantity, so never green for it (fix wave, I3); amber naming the count, where
    /// a Quantity would count (owner, 2026-11-18, by click: Bought… on a water line in gallons opened with no line).
    @Test func amberWithABlankQuantity() {
        #expect(line("Water", "gallons", quantity: nil) == .missing("Won't count toward water yet: write how many."))
        #expect(line("Water", "bottles", quantity: nil) == .missing(ItemNeeds.noQuantity("water")), "Quantity first")
        #expect(line("Food", "cans", quantity: nil, calories: 200) == .missing(ItemNeeds.noQuantity("food")))
        #expect(line("Food", "cans", quantity: nil, pet: "Cat") == .missing(ItemNeeds.noQuantity("cat food")))
        #expect(line("Pets", "pounds", quantity: nil, pet: "Dog") == .missing(ItemNeeds.noQuantity("dog food")))
        #expect(line("Pets", "bags", quantity: nil) == .missing(ItemNeeds.noQuantity("pet food")))
        #expect(line("Pets", "each", quantity: nil) == nil, "a leash: no line, with or without a Quantity")
        #expect(line("Food", "pounds", quantity: nil) == nil, "a staple in pounds is left to the count")
        #expect(line("Water", "gallons", quantity: nil, empty: true) == nil)
        #expect(line("Tools and equipment", "each", quantity: nil) == nil)
        #expect(line("Water", "gallons", quantity: 0) == .complete("Nothing missing for the water count: 0 gallons."),
                "a 0 is counted, as none")
    }

    /// Pet food for as the lists job reads it: Dog or Cat in any case; anything else is blank (fix wave, I4).
    @Test func anOffListPetFoodForIsBlank() {
        #expect(ItemNeeds.petKind(" DOG ") == "dog")
        #expect(ItemNeeds.petKind("Dogs") == "")
        #expect(line("Pets", "pounds", pet: "Dogs") == .missing(ItemNeeds.petPick))
        #expect(line("Pets", "pounds", pet: "Cat") == .complete("Nothing missing for the cat food count: 1 pounds."))
        #expect(line("Food", "pounds", calories: 1500, pet: "Dogs")
                == .complete("Nothing missing for the food count: 1 × 1500 calories."),
                "a Food row with an off-list Pet food for is food, not pet food")
    }

    @Test func water() {
        #expect(line("Water", "gallons") == .complete("Nothing missing for the water count: 1 gallons."))
        #expect(line("Water", "bottles") == .missing("Won't count toward water yet: say what each one holds."))
        #expect(line("Water", "bottles", holds: 2, holdsUnit: "pounds") == .missing(ItemNeeds.waterUnit))
        #expect(line("Water", "ounces") == .missing("Won't count toward water in this unit: use fl oz, gallons or liters."))
    }

    @Test func food() {
        #expect(line("Food", "cans", calories: 200) == .complete("Nothing missing for the food count: 1 × 200 calories."))
        #expect(line("Food", "ounces", calories: 160) == .complete(ItemNeeds.complete("food", "1 × 160 calories")))
        #expect(line("Food", "calories") == .complete(ItemNeeds.complete("food", "1 calories")))
        #expect(line("Food", "pounds") == nil)
        #expect(line("Food", "pounds", calories: 1500, pet: "dog")
                == .complete("Nothing missing for the dog food count: 1 pounds."))
        #expect(line("Food", "ounces", calories: 1500, pet: "dog") == .missing("Won't count as dog food in this unit: use pounds."))
        #expect(line("Food", "cans") == .missing("Won't count toward food yet: add its calories, or count a dry staple in pounds."))
    }

    @Test func pets() {
        #expect(line("Pets", "pounds") == .missing("Pick Pet food for, so this counts as dog or cat food."))
        #expect(line("Pets", "pounds", pet: "dog") == .complete("Nothing missing for the dog food count: 1 pounds."))
        #expect(line("Pets", "ounces", pet: "cat") == .missing("Won't count as cat food in this unit: use pounds."))
        #expect(ItemNeeds.petPick == "Pick Pet food for, so this counts as dog or cat food.")
    }

    /// Pick Pet food for only on an item that could be food by its fields: its Unit or Holds unit in pounds, or counted
    /// in a package other than blank or each (phase 2 review, 3). A leash counted each gets no line.
    @Test func petPickOnlyForWhatCouldBeFood() {
        #expect(line("Pets", "each") == nil, "a leash")
        #expect(line("Pets", "") == nil)
        #expect(line("Pets", "ounces") == nil)
        #expect(line("Pets", "bags") == .missing(ItemNeeds.petPick))
        #expect(line("Pets", " Cans ") == .missing(ItemNeeds.petPick))
        #expect(line("Pets", "lb") == .missing(ItemNeeds.petPick))
        #expect(line("Pets", "each", holds: 20, holdsUnit: "pounds") == .missing(ItemNeeds.petPick))
        #expect(line("Pets", "each", pet: "dog") == .missing(ItemNeeds.petUnit("dog")), "Pet food for says it's food")
    }

    /// The green line restates what the count will read, with no conversion (owner, 2026-11-18, addition B): Quantity
    /// and its unit, or Quantity × what one holds; food by calories as Quantity × Calories each.
    @Test func theGreenLineSaysWhatItWillCount() {
        #expect(line("Water", "gallons", quantity: 6) == .complete("Nothing missing for the water count: 6 gallons."))
        #expect(line("Water", "bottles", quantity: 24, holds: 16.9, holdsUnit: "fl oz")
                == .complete("Nothing missing for the water count: 24 × 16.9 fl oz."))
        #expect(line("Water", "pack", quantity: 1, holds: 16.9, holdsUnit: "fl oz")
                == .complete("Nothing missing for the water count: 1 × 16.9 fl oz."), "a 24-pack entered as 1 shows")
        #expect(line("Food", "cans", quantity: 12, calories: 180)
                == .complete("Nothing missing for the food count: 12 × 180 calories."))
        #expect(line("Food", "", quantity: 2.5, calories: 1200.5)
                == .complete("Nothing missing for the food count: 2.5 × 1200.5 calories."))
        #expect(line("Pets", "bags", quantity: 2, holds: 20, holdsUnit: "pounds", pet: "Dog")
                == .complete("Nothing missing for the dog food count: 2 × 20 pounds."))
        #expect(line("Pets", "pounds", quantity: 30, pet: "cat") == .complete("Nothing missing for the cat food count: 30 pounds."))
        // phase 2 review, M9: a unit typed with an inner double space shows as the count reads it, its case kept
        #expect(line("Water", "bottles", quantity: 24, holds: 16.9, holdsUnit: "fl  oz")
                == .complete("Nothing missing for the water count: 24 × 16.9 fl oz."))
        #expect(line("Water", " Fl  oz ", quantity: 12) == .complete("Nothing missing for the water count: 12 Fl oz."))
    }

    /// Phase 2 review, M3: VoiceOver hears the line when it appears, turns amber or green, or amber names another field;
    /// not as its amount changes with each keystroke, nor when it goes.
    @Test func theLineIsAnnouncedAsItsStateChanges() {
        let amber = ItemNeeds.Line.missing(ItemNeeds.waterHolds)
        let green = ItemNeeds.Line.complete(ItemNeeds.complete("water", "12 gallons"))
        #expect(ItemNeeds.announcement(from: nil, to: amber) == ItemNeeds.waterHolds)
        #expect(ItemNeeds.announcement(from: nil, to: green) == ItemNeeds.complete("water", "12 gallons"))
        #expect(ItemNeeds.announcement(from: amber, to: green) == ItemNeeds.complete("water", "12 gallons"))
        #expect(ItemNeeds.announcement(from: green, to: amber) == ItemNeeds.waterHolds)
        #expect(ItemNeeds.announcement(from: amber, to: .missing(ItemNeeds.waterUnit)) == ItemNeeds.waterUnit)
        #expect(ItemNeeds.announcement(from: .complete(ItemNeeds.complete("water", "1 gallons")), to: green) == nil,
                "typing 12: the amount changed, the state didn't")
        #expect(ItemNeeds.announcement(from: amber, to: amber) == nil)
        #expect(ItemNeeds.announcement(from: amber, to: nil) == nil && ItemNeeds.announcement(from: nil, to: nil) == nil)
    }

    /// entry-cases.json is the lists job's own verdicts: `counted` names the kinds each case counts toward. Its kinds map
    /// as: "water" and "water once filled" are water, any starting "food" is food, "dog food" and "cat food" are pets.
    @Test func theListsJobsEntryCases() throws {
        struct Case: Decodable {
            let group, item, unit: String
            let quantity, holds, calories: Double?
            let holds_unit, pet_food_for: String
            let empty, by_name: Bool
            let counted: [String]
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("entry-cases.json")))
        let units = try #require(SupplyShares.read(in: Self.fixtures)?.units)
        func supplyOf(_ one: Case) -> String? {
            // counted as pet food whatever its category, when the count reads a kind there
            if one.group == "Food", !ItemNeeds.petKind(one.pet_food_for).isEmpty { return "pets" }
            return ["Water": "water", "Food": "food", "Pets": "pets"][one.group]
        }
        func line(_ one: Case, _ units: SupplyShares.Units?) -> ItemNeeds.Line? {
            ItemNeeds.line(group: one.group, quantity: one.quantity, unit: one.unit, holds: one.holds,
                           holdsUnit: one.holds_unit, calories: one.calories, petFoodFor: one.pet_food_for,
                           emptyUntilNeeded: one.empty, units: units)
        }
        for one in cases { #expect(line(one, nil) == nil, "\(one.item): no units, no line") }
        func counts(_ one: Case, _ kind: String) -> Bool {
            one.counted.contains { $0.hasPrefix(kind == "pets" ? ItemNeeds.petKind(one.pet_food_for) + " food" : kind) }
        }
        var seen: Set<String> = []
        var checked = 0
        var byName: [String] = []  // the cases whose verdict rests on the item's name, which the line never reads
        for item in cases {
            guard !item.by_name else { byName.append("\(item.item), \(item.unit)"); continue }
            let found = line(item, units)
            guard let supply = supplyOf(item) else { #expect(found == nil, "\(item.item)"); continue }
            if item.quantity == nil {  // the count leaves it out for no Quantity: never a green line
                if case .complete? = found { Issue.record("\(item.item) with no Quantity says complete") }
                #expect(item.counted.isEmpty, "\(item.item) with no Quantity")
                continue
            }
            guard !item.empty, let found else { continue }  // a staple in pounds is left to the count (nil)
            checked += 1
            switch found {
            case .complete:
                #expect(counts(item, supply), "\(item.item) \(item.unit) says complete")
                seen.insert(supply + ":complete")
            case .missing:
                #expect(!counts(item, supply), "\(item.item) \(item.unit) says missing")
                seen.insert(supply + ":missing")
            }
        }
        #expect(checked >= 8)
        #expect(byName == ["Flush water, gallons", "Rice, pounds", "Dog food, dry, pounds"], "skipped, by name")
        for supply in ["water", "food", "pets"] { #expect(seen.contains(supply + ":complete") && seen.contains(supply + ":missing"), "\(supply)") }
    }

    @Test func unitsDecodeAndAreOptional() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("supply.json"))
        let full = try JSONDecoder().decode(SupplyShares.self, from: data)
        #expect(full.units?.water.contains("gallons") == true)
        #expect(full.forPhones.units == full.units)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["units"] = nil
        let older = try JSONDecoder().decode(SupplyShares.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.units == nil)
        object["units"] = 3
        let bad = try JSONDecoder().decode(SupplyShares.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(bad.units == nil && bad.supplies == full.supplies && bad.leftOut == full.leftOut)
        object["units"] = nil
        #expect(older.supplies == full.supplies && older.today == full.today && older.countedToward == full.countedToward
                && older.leftOut == full.leftOut && older.notes == full.notes && older.calculators == full.calculators)
    }

    /// The Mac's forms (Task 2.6): a row's own values, with what's typed over them, and its category's Counts as.
    @Test func aMacRowWithWhatIsTyped() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-needs-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("PrepareMe Inventory.grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        let file = try InventoryFile(url: url)
        try file.ensureColumn("Inventory", colId: "Each_holds", label: Inventory.Label.eachHolds, type: "Numeric")
        try file.ensureColumn("Inventory", colId: "Holds_unit", label: Inventory.Label.holdsUnit, type: "Choice")
        try file.ensureColumn("Inventory", colId: "Empty_until_needed", label: Inventory.Label.emptyUntilNeeded,
                              type: "Bool")
        let inventory = try Inventory(file: file)
        let water = try #require(inventory.categoryRows.first { inventory.group(ofCategory: $0.id) == "Water" })
        let row = InventoryRow(id: 0, position: 1, values: ["Category": .int(water.id), "Quantity": .text("24"),
                                                            "Unit": .text("bottles")])

        #expect(inventory.needsLine(row, units: Self.units) == .missing(ItemNeeds.waterHolds))
        #expect(inventory.needsLine(row, typed: ["Each_holds": "16.9"], units: Self.units)
                == .missing(ItemNeeds.waterHolds), "Holds unit still blank")
        let held = InventoryRow(id: 0, position: 1, values: row.values.merging(["Holds_unit": .text("fl oz")]) { $1 })
        #expect(inventory.needsLine(held, typed: ["Each_holds": "16.9"], units: Self.units)
                == .complete("Nothing missing for the water count: 24 × 16.9 fl oz."))
        #expect(inventory.needsLine(held, units: nil) == nil, "no supply.json, or one without units")
        let empty = InventoryRow(id: 0, position: 1, values: row.values.merging(["Empty_until_needed": .int(1)]) { $1 })
        #expect(inventory.needsLine(empty, units: Self.units) == nil)
        let none = InventoryRow(id: 0, position: 1, values: ["Quantity": .text("24"), "Unit": .text("bottles")])
        #expect(inventory.needsLine(none, units: Self.units) == nil, "no category")
        #expect(inventory.needsLine(held, typed: ["Each_holds": "16.9", "Quantity": " "], units: Self.units)
                == .missing(ItemNeeds.noQuantity("water")), "Quantity cleared in its box")
    }
}
