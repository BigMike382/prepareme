import Foundation
@testable import PrepareMeShared
import XCTest

/// Beta run 2, R4.4: one categories list on the Mac (B2-29, mockup 4), every supply's calculators on the phone even
/// with nothing stocked (B2-30, mockup 5), "Already in the inventory" on Add, and the unit on Used 1.
final class CategoriesAndAddTests: XCTestCase {
    /// The groups that no category's name and no "counts as" line leads to, as the sidebar shows them.
    func unreachable(groups: [String], in entries: [CategoryList.Entry]) -> [String] {
        groups.filter { group in
            !entries.contains { InventoryFile.same($0.name, group) || $0.countsAs.map { InventoryFile.same($0, group) } == true }
        }
    }

    // MARK: B2-29, the Mac's one Categories list

    /// Mockup 4's list: a "counts as" line only where the group differs from the name.
    let mockup: [(id: Int64, name: String, group: String?)] = [
        (1, "Water", "Water"), (2, "Food", "Food"), (3, "Medicine", "Medical"), (4, "First aid", "Medical"),
        (5, "Power and batteries", "Power and fuel"), (6, "Hygiene and sanitation", "Water"), (7, "Other", nil),
        (8, "water", " WATER "),
    ]

    func testACategoryShowsWhatItCountsAsOnlyWhereItDiffers() {
        let entries = CategoryList.entries(mockup)
        XCTAssertEqual(entries.map(\.name), ["Water", "Food", "Medicine", "First aid", "Power and batteries",
                                             "Hygiene and sanitation", "Other", "water"])
        XCTAssertEqual(entries.map(\.countsAs), [nil, nil, "Medical", "Medical", "Power and fuel", "Water", nil, nil],
                       "Water and Food say nothing, in any case or spacing")
    }

    func testNoNameAppearsInTwoSidebarSections() {
        // the sidebar's rows are the entries' names, and a group appears only as a line under a category it differs from
        let entries = CategoryList.entries(mockup)
        for entry in entries {
            if let group = entry.countsAs { XCTAssertFalse(InventoryFile.same(group, entry.name)) }
        }
        // every group the categories name is still reachable: by a category of its name, or from a "counts as" line
        let groups = ["Water", "Food", "Medical", "Power and fuel"]
        XCTAssertEqual(unreachable(groups: groups, in: entries), [])
        XCTAssertEqual(unreachable(groups: ["Pets"], in: entries), ["Pets"])
        XCTAssertEqual(CategoryList.entries(mockup).count, mockup.count, "one row each: no second list of groups")
    }

    func testTheMacSidebarListsEachFileCategoryOnce() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/inventory/rehearsal.grist")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("r44-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let inventory = try Inventory(file: try InventoryFile(url: copy))
        let entries = inventory.sidebarCategories
        XCTAssertEqual(entries.count, inventory.categoryRows.count)
        XCTAssertEqual(unreachable(groups: inventory.groups, in: entries), [])
    }

    func testTheMacsAddFindsAnItemAlreadyThere() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/inventory/rehearsal.grist")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("r44b-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let inventory = try Inventory(file: try InventoryFile(url: copy))
        let names = inventory.itemNames
        let found = try XCTUnwrap(inventory.alreadyThere(named: " drinking WATER jugs", in: names))
        XCTAssertTrue(found.line.hasPrefix("Already in the inventory: Drinking water jugs"), found.line)
        XCTAssertTrue(found.line.hasSuffix(". Add to that instead?"))
        XCTAssertNil(inventory.alreadyThere(named: "Drinking", in: names))
        XCTAssertNil(inventory.alreadyThere(named: "", in: names))
    }

    func rehearsal() throws -> (Inventory, URL) {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/inventory/rehearsal.grist")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("cp2-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: fixture, to: copy)
        return (try Inventory(file: try InventoryFile(url: copy)), copy)
    }

    /// Checkpoint 2: Go to that item, and the new item after Add, are shown where the table shows them; an item the
    /// view or the search leaves out is shown in All items with no search.
    func testAnItemOutsideTheViewOrSearchIsShownInAllItems() throws {
        let (inventory, copy) = try rehearsal()
        defer { try? FileManager.default.removeItem(at: copy) }
        let jugs = try XCTUnwrap(inventory.itemRows.first { inventory.name(ofItem: $0) == "Drinking water jugs" }).id
        let pantry = inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Pantry" }!.id
        let garage = inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Garage" }!.id
        XCTAssertTrue(inventory.shows(item: jugs, in: .location(pantry), search: ""))
        XCTAssertFalse(inventory.shows(item: jugs, in: .location(garage), search: ""), "kept in the Pantry")
        XCTAssertFalse(inventory.shows(item: jugs, in: .all, search: "generator"), "a search that leaves it out")
        XCTAssertTrue(inventory.shows(item: jugs, in: .all, search: ""), "All items with no search shows every item")
    }

    /// Checkpoint 2: the Mac's Did you mean draws on the items in the view shown, the same rows Nothing found is about,
    /// so it never offers a word that finds nothing there.
    func testTheMacsDidYouMeanLooksOnlyInTheViewShown() throws {
        let (inventory, copy) = try rehearsal()
        defer { try? FileManager.default.removeItem(at: copy) }
        let pantry = inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Pantry" }!.id
        let garage = inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Garage" }!.id
        XCTAssertEqual(PhoneSearch.nearMiss(search: "jugz") { inventory.nearIndex(in: .all) }, "jugs")
        XCTAssertEqual(PhoneSearch.nearMiss(search: "jugz") { inventory.nearIndex(in: .location(pantry)) }, "jugs")
        XCTAssertNil(PhoneSearch.nearMiss(search: "jugz") { inventory.nearIndex(in: .location(garage)) },
                     "no jugs in the Garage: nothing to offer there")
        XCTAssertEqual(PhoneSearch.nearMiss(search: "generatr") { inventory.nearIndex(in: .location(garage)) },
                       "generator")
    }

    /// Checkpoint 2: "Already in the inventory" looks the typed name up in the names folded once per copy, not every
    /// name folded again on each keystroke; the first item of a name winning.
    func testAlreadyThereLooksUpNamesFoldedOnce() throws {
        let names: [(id: Int64, name: String)] = [(1, "Canned soup"), (2, "Rice"), (3, "canned SOUP "), (4, "Café")]
        let folded = ItemMatch.Names(names)
        let expected: [String: Int64?] = ["canned soup": 1, " RICE": 2, "cafe": 4, "Canned": nil, "": nil, "  ": nil,
                                          "Beans": nil]
        for (typed, id) in expected {
            XCTAssertEqual(folded.existing(named: typed), id, typed)
        }
        XCTAssertEqual(folded.existing(named: "CANNED SOUP"), 1, "the first item of that name")
        let cache = PhoneSearch.KeyedCache<ItemMatch.Names>()
        var builds = 0
        _ = cache.value(key: "a") { builds += 1; return folded }
        _ = cache.value(key: "a") { builds += 1; return folded }
        _ = cache.value(key: "b") { builds += 1; return folded }
        XCTAssertEqual(builds, 2, "built once per copy")
        let (inventory, copy) = try rehearsal()
        defer { try? FileManager.default.removeItem(at: copy) }
        let once = inventory.itemNames
        XCTAssertTrue(inventory.alreadyThere(named: " drinking WATER jugs", in: once)?.line
                          .hasPrefix("Already in the inventory: Drinking water jugs") ?? false)
        XCTAssertNil(inventory.alreadyThere(named: "Drinking", in: once))
    }

    /// Re-review of checkpoint 2: the Mac reads the file again every 10 seconds; its near-miss and add-form words are
    /// built again only when the rows they come from changed (a rename keeping the count included), not on each read.
    @MainActor
    func testTheRowsCompareSoAReadThatChangedNothingKeepsTheWords() async throws {
        let (inventory, copy) = try rehearsal()
        defer { try? FileManager.default.removeItem(at: copy) }
        let again = try Inventory(file: try InventoryFile(url: copy))
        XCTAssertTrue(inventory.sameRows(as: again), "read again, nothing changed")
        let editor = try InventoryEditor(file: try InventoryFile(url: copy), checker: FakeCheck())
        let jugs = try XCTUnwrap(inventory.itemRows.first { inventory.name(ofItem: $0) == "Drinking water jugs" })
        let name = try XCTUnwrap(inventory.items.column(Inventory.Label.item)).colId
        _ = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: name, value: .text("Water jugs")))
        let renamed = try Inventory(file: try InventoryFile(url: copy))
        XCTAssertEqual(renamed.itemRows.count, inventory.itemRows.count)
        XCTAssertFalse(inventory.sameRows(as: renamed), "a rename keeping the count is a change")
        let pantry = try XCTUnwrap(inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Pantry" })
        let placeName = try XCTUnwrap(inventory.locations.column(Inventory.Label.name)).colId
        _ = try await editor.apply(.set(table: "Locations", row: pantry.id, colId: placeName, value: .text("Larder")))
        XCTAssertFalse(renamed.sameRows(as: try Inventory(file: try InventoryFile(url: copy))),
                       "a place renamed changes the items' search text")
    }

    // MARK: B2-30, every supply's calculators on the phone

    var links: CalculatorLinks {
        get throws {
            try CalculatorLinks(try Data(contentsOf: CalculatorLinksTests.fixtures.appendingPathComponent("calculator-links.json")))
        }
    }

    func phone(items: [(name: String, category: Int64)]) -> PhoneInventory {
        let columns = [
            PhoneInventory.Column(colId: "Item", label: "Item", kind: "text", target: nil, choices: [], editable: true),
            PhoneInventory.Column(colId: "Category", label: "Category", kind: "reference", target: "Categories",
                                  choices: [], editable: true),
            PhoneInventory.Column(colId: "Quantity", label: "Quantity", kind: "numeric", target: nil, choices: [], editable: true),
            PhoneInventory.Column(colId: "Unit", label: "Unit", kind: "text", target: nil, choices: [], editable: true),
        ]
        let rows = items.enumerated().map { n, item in
            PhoneInventory.Row(id: Int64(n + 1), position: n + 1,
                               values: ["Item": .text(item.name), "Category": .int(item.category)])
        }
        return PhoneInventory(writtenAt: "", columns: columns, items: rows, places: [],
                              categories: [.init(id: 1, name: "Water", group: "Water"),
                                           .init(id: 2, name: "Food", group: "Food"),
                                           .init(id: 3, name: "Medicine", group: "Medical")],
                              headsUpDays: 60, toBuy: [], results: [:])
    }

    func testAnEmptyWaterGroupStillListsItsCalculators() throws {
        let copy = phone(items: [("Rice", 2)])  // nothing in Water
        let supplies = copy.supplyCalculators(links: try links, figures: nil)
        let water = try XCTUnwrap(supplies.first { $0.group == "Water" })
        XCTAssertEqual(water.itemCount, 0)
        XCTAssertEqual(water.stocked, "none entered")
        XCTAssertEqual(water.line.links.map(\.calculator.name), ["Water for People and Pets", "Chlorine for Drinking Water", "Well Shock"])
        let food = try XCTUnwrap(supplies.first { $0.group == "Food" })
        XCTAssertEqual(food.stocked, "1 item")
        XCTAssertEqual(food.line.links.map(\.calculator.name), ["Fridge and Freezer Outage Timer"])
    }

    func testEveryGroupWithCalculatorsIsListedInTheListsOrder() throws {
        let supplies = phone(items: []).supplyCalculators(links: try links, figures: nil)
        XCTAssertEqual(supplies.map(\.group), ["Water", "Food", "Medical", "Power and fuel", "Pets"])
        XCTAssertTrue(supplies.allSatisfy { $0.stocked == "none entered" })
        XCTAssertFalse(supplies.contains { $0.group == "Other" })
    }

    func testAGroupsItemsCountAndChooseItsConditionalCalculators() throws {
        let copy = phone(items: [("Rain barrels, 55 gal", 1), ("Jugs", 1), ("Aspirin", 3)])
        let supplies = copy.supplyCalculators(links: try links, figures: nil)
        let water = try XCTUnwrap(supplies.first { $0.group == "Water" })
        XCTAssertEqual(water.stocked, "2 items")
        XCTAssertTrue(water.line.links.map(\.calculator.name).contains("Rain Catchment"))
        XCTAssertEqual(try XCTUnwrap(supplies.first { $0.group == "Medical" }).stocked, "1 item")
    }

    // MARK: Already in the inventory

    func testAnExistingItemMatchesWithoutCaseOrSpacing() {
        let names: [(id: Int64, name: String)] = [(1, "Canned soup"), (2, "Rice")]
        XCTAssertEqual(ItemMatch.Names(names).existing(named: "canned SOUP "), 1)
        XCTAssertEqual(ItemMatch.Names([(5, "cafe")]).existing(named: "Café"), 5, "accents fold, as search does")
        XCTAssertNil(ItemMatch.Names(names).existing(named: "Canned"), "the whole name, not part of one")
        XCTAssertNil(ItemMatch.Names([(9, "")]).existing(named: "   "), "a blank name matches nothing")
        XCTAssertNil(ItemMatch.Names([]).existing(named: "Soup"))
    }

    /// Quick add (Task 2.7): the product's code is linked to its item in the pantry; scanned in the garage, where an
    /// item of the same name is, 1 goes to the garage's.
    func testTheSameProductInAnotherPlaceGoesToThatPlacesItem() {
        let items: [(id: Int64, name: String, place: Int64?)] = [(1, "Canned soup", 10), (2, "canned soup ", 20),
                                                                  (3, "Rice", 20), (4, "Canned soup", nil)]
        XCTAssertEqual(ItemMatch.inPlace(named: "Canned soup", place: 20, items), 2)
        XCTAssertEqual(ItemMatch.inPlace(named: "Canned soup", place: 10, items), 1)
        XCTAssertNil(ItemMatch.inPlace(named: "Canned soup", place: 30, items), "none there: it asks")
        XCTAssertNil(ItemMatch.inPlace(named: "Canned soup", place: 0, items), "no place chosen: it asks")
        XCTAssertNil(ItemMatch.inPlace(named: " ", place: 20, items))
    }

    func testTheAlreadyThereLineShowsTheItemAsStored() {
        XCTAssertEqual(ItemMatch.line(name: "Canned soup", amount: "12 cans", place: "Pantry"),
                       "Already in the inventory: Canned soup, 12 cans, Pantry. Add to that instead?")
        XCTAssertEqual(ItemMatch.line(name: "Canned soup", amount: "", place: "Pantry"),
                       "Already in the inventory: Canned soup, Pantry. Add to that instead?")
        XCTAssertEqual(ItemMatch.line(name: "Rice", amount: "", place: ""),
                       "Already in the inventory: Rice. Add to that instead?")
        XCTAssertEqual(ItemMatch.goTo, "Go to that item")
        XCTAssertEqual(ItemMatch.addOne, "Add 1 to it", "Quick add's, beside it (addition D), as its question words it")
    }

    // MARK: The unit on Used 1

    func testTheUnitOnUsed1() {
        XCTAssertEqual(UnitWords.used("gallons"), "Used 1 gallon")
        XCTAssertEqual(UnitWords.more("gallons"), "1 more gallon")
        XCTAssertEqual(UnitWords.used("Cans"), "Used 1 Can")
        XCTAssertEqual(UnitWords.used("gallon"), "Used 1 gallon")
        XCTAssertEqual(UnitWords.used("batteries"), "Used 1 battery")
        XCTAssertEqual(UnitWords.used("boxes"), "Used 1 box")
        XCTAssertEqual(UnitWords.used("lb"), "Used 1 lb")
        XCTAssertEqual(UnitWords.used("glass"), "Used 1")
        XCTAssertEqual(UnitWords.used("each"), "Used 1")
        XCTAssertEqual(UnitWords.used("Each"), "Used 1")
        XCTAssertEqual(UnitWords.used(""), "Used 1")
        XCTAssertEqual(UnitWords.used("  "), "Used 1")
        XCTAssertEqual(UnitWords.more(""), "1 more")
    }

    func testOnlyKnownPluralsChangeAndCaseIsKept() {
        XCTAssertEqual(UnitWords.used("loaves"), "Used 1 loaf")
        XCTAssertEqual(UnitWords.used("Loaves"), "Used 1 Loaf")
        XCTAssertEqual(UnitWords.used("CANS"), "Used 1 CAN")
        XCTAssertEqual(UnitWords.used("lbs"), "Used 1 lb")
        XCTAssertEqual(UnitWords.used("Liters"), "Used 1 Liter")
        for odd in ["sizes", "gas", "lens", "cookies", "headaches", "cans of soup", "dozen"] {
            XCTAssertEqual(UnitWords.used(odd), "Used 1", odd)
            XCTAssertEqual(UnitWords.more(odd), "1 more", odd)
        }
        XCTAssertEqual(UnitWords.used("mL"), "Used 1 mL")
        XCTAssertEqual(UnitWords.used("L"), "Used 1 L")
        XCTAssertEqual(UnitWords.used("kWh"), "Used 1 kWh")
        XCTAssertEqual(UnitWords.used("oz"), "Used 1 oz")
        XCTAssertEqual(UnitWords.more("Gallon"), "1 more Gallon")
    }

    func testUndoCarriesTheUnitToo() {
        var outbox = PhoneOutbox()
        outbox.add(.adjust(row: 1, by: -1), what: "x")
        outbox.add(.adjust(row: 1, by: 1), what: "y")
        XCTAssertEqual(PhoneOutbox.undoLabel(outbox.pending[0], unit: "gallons"), "Undo Used 1 gallon")
        XCTAssertEqual(PhoneOutbox.undoLabel(outbox.pending[1], unit: "gallons"), "Undo 1 more gallon")
        XCTAssertEqual(PhoneOutbox.undoLabel(outbox.pending[0], unit: ""), "Undo Used 1")
        XCTAssertEqual(PhoneOutbox.undoLabel(outbox.pending[1], unit: "each"), "Undo 1 more")
    }

    func testAnItemsUnitIsReadFromItsRow() {
        var copy = phone(items: [("Water jugs", 1)])
        copy = PhoneInventory(writtenAt: "", columns: copy.columns,
                              items: [.init(id: 1, position: 1, values: ["Item": .text("Water jugs"), "Unit": .text("gallons")])],
                              places: [], categories: copy.categories, headsUpDays: 60, toBuy: [], results: [:])
        XCTAssertEqual(copy.unitWord(of: copy.items[0]), "gallons")
    }
}
