@testable import PrepareMeShared
import XCTest

/// The item entry screens' groups (docs/plans/2026-10-22-item-entry-redesign.md).
final class ItemFieldGroupsTests: XCTestCase {
    func testEachColumnInItsGroupInOrder() {
        // the inventory's own column order (the made-up fixture's), with two the Mac adds
        let labels = ["Item", "Category", "Brand", "Model", "Quantity", "Unit", "Location", "Grab", "Expires", "Year",
                      "Manual", "Calories each", "Notes", "Serial number", "Mac only"]
        let grouped = ItemFieldGroup.grouped(labels)
        XCTAssertEqual(grouped.map(\.group), [.what, .howMany, .kept, .food, .dates, .more])
        XCTAssertEqual(grouped.map(\.labels), [["Item", "Brand", "Category"], ["Quantity", "Unit"], ["Location", "Grab"],
                                               ["Calories each"], ["Expires", "Year"],
                                               ["Model", "Manual", "Notes", "Serial number", "Mac only"]])
        XCTAssertEqual(ItemFieldGroup.of("calories EACH"), .food, "as the file names it, any case")
        XCTAssertEqual(ItemFieldGroup.of("Price"), .more)
    }

    /// The 2026-10-23 plan: each tick beside what it changes.
    func testTheTicksSitBesideWhatTheyChange() {
        let grouped = ItemFieldGroup.grouped(["Item", "Quantity", "Unit", "Expires", "Year", "Keep past date",
                                              "Empty until needed"])
        XCTAssertEqual(grouped.map(\.labels), [["Item"], ["Quantity", "Unit", "Empty until needed"],
                                               ["Expires", "Keep past date", "Year"]])
    }

    func testAnEmptyGroupIsLeftOut() {
        XCTAssertEqual(ItemFieldGroup.grouped(["Notes", "Item"]).map(\.group), [.what, .more])
        XCTAssertTrue(ItemFieldGroup.grouped([]).isEmpty)
    }

    /// Task 1.2 (2026-10-23): a category the owner made that counts as Food ("Canned goods") shows the Food section,
    /// so Calories each gets filled in; the group decides, never the category's name.
    func testFoodShowsByGroupNotName() throws {
        XCTAssertTrue(ItemFieldGroup.showsFood(group: "Food", calories: ""))
        XCTAssertFalse(ItemFieldGroup.showsFood(group: nil, calories: ""))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-food-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try InventoryFile(url: url)
        let categories = try file.table("Categories")
        let canned = try file.addRow(categories, values: [categories.column("Name")!.colId: .text("Canned goods"),
                                                         categories.column("Counts as")!.colId: .text("Food")])
        let inventory = try Inventory(file: file)
        XCTAssertEqual(inventory.group(ofCategory: canned), "Food")
        XCTAssertTrue(ItemFieldGroup.showsFood(group: inventory.group(ofCategory: canned), calories: ""))
    }

    func testTheGroupsWords() {
        XCTAssertEqual(ItemFieldGroup.allCases.map(\.title), ["What it is", "How many", "Where it's kept", "Food",
                                                              "Dates", "More details"])
        XCTAssertEqual(ItemFieldGroup.kept.symbol, "house")
    }

    func testFoodOnlyForFoodAndMoreOpensWhenFilled() {
        XCTAssertTrue(ItemFieldGroup.showsFood(group: "food", calories: ""))
        XCTAssertTrue(ItemFieldGroup.showsFood(group: nil, calories: "144"))
        XCTAssertTrue(ItemFieldGroup.showsFood(group: "Tools and equipment", calories: "", scannedFood: true))
        XCTAssertFalse(ItemFieldGroup.showsFood(group: "Tools and equipment", calories: " "))
        XCTAssertFalse(ItemFieldGroup.opensMore(["", " "]))
        XCTAssertTrue(ItemFieldGroup.opensMore(["", "a note"]))
    }

    /// Entry fixes plan, phase 3: Each holds for a package counted each in a supply that counts it; Pet food for in
    /// Pets; a generator's watts by its name; every other field always.
    func testHoldsShowsForPackageUnitsInSupplyGroups() {
        for group in ["Water", "Pets", "Power and fuel", "Heat and shelter"] {
            XCTAssertTrue(ItemFieldGroup.showsHolds(group: group, unit: "each"), group)
            XCTAssertTrue(ItemFieldGroup.shows("Each holds", group: group, unit: "bags", item: ""), group)
            XCTAssertTrue(ItemFieldGroup.shows("Holds unit", group: group, unit: "", item: ""), group)
        }
        XCTAssertFalse(ItemFieldGroup.showsHolds(group: "Water", unit: "gallons"), "measured already")
        XCTAssertFalse(ItemFieldGroup.showsHolds(group: "Food", unit: "cans"), "a can's calories, not what it holds")
        // owner, 2026-10-28: a bag of rice counted each holds its pounds (readiness/staples.py)
        for unit in ["bags", "Bag", "each", "", "boxes", "pouch"] {
            XCTAssertTrue(ItemFieldGroup.showsHolds(group: "Food", unit: unit), unit)
        }
        for unit in ["can", "jars", "bottle", "Cartons"] {
            XCTAssertFalse(ItemFieldGroup.showsHolds(group: "Food", unit: unit), "a container's own calories: \(unit)")
        }
        XCTAssertFalse(ItemFieldGroup.showsHolds(group: "Food", unit: "pounds"), "measured already")
        XCTAssertFalse(ItemFieldGroup.showsHolds(group: nil, unit: "each"))
        XCTAssertTrue(ItemFieldGroup.shows("Pet food for", group: "Pets", unit: "pounds", item: "Kibble"))
        XCTAssertFalse(ItemFieldGroup.shows("Pet food for", group: "Food", unit: "pounds", item: "Kibble"))
        XCTAssertTrue(ItemFieldGroup.shows("Running watts", group: nil, unit: "each", item: "Zorvex Generator 3500"))
        XCTAssertFalse(ItemFieldGroup.shows("Starting watts", group: "Power and fuel", unit: "each", item: "Lantern"))
        XCTAssertFalse(ItemFieldGroup.shows("Running watts", group: nil, unit: "each", item: "Zorvex Solar Generator"))
        XCTAssertTrue(ItemFieldGroup.shows("Pet food for", group: "Food", unit: "pounds", item: "Kibble", filled: true),
                      "a value already there shows, so it can be cleared")
        XCTAssertTrue(ItemFieldGroup.shows("Notes", group: nil, unit: "", item: ""))
        XCTAssertEqual(ItemFieldGroup.of("Each holds"), .howMany)
        XCTAssertEqual(ItemFieldGroup.of("Pet food for"), .what)
        XCTAssertEqual(PhoneEditRules.hint(columnLabel: "Each holds"),
                       "Each holds (when full): what one holds, like 5 for a 5-gallon jug, in the Holds unit.")
    }

    /// Return moves through the typed fields in order, and the last says Done (entry fixes, Task 2.2).
    func testFocusOrderFollowsTheGroups() {
        let order = ["name", "quantity", "unit", "notes"]
        XCTAssertEqual(ItemFieldGroup.next(after: "name", in: order), "quantity")
        XCTAssertEqual(ItemFieldGroup.next(after: "unit", in: order), "notes")
        XCTAssertNil(ItemFieldGroup.next(after: "notes", in: order))
        XCTAssertNil(ItemFieldGroup.next(after: "a hidden field", in: order))
        XCTAssertEqual(InventoryWords.addAnother, "Add Another")
        XCTAssertEqual(InventoryWords.doneAdding, "Done")
        XCTAssertEqual(InventoryWords.addAndNext, "Add and Next")
        XCTAssertEqual(InventoryWords.addedTypeNext("Rice"), "Added Rice. Type the next.")
    }
}
