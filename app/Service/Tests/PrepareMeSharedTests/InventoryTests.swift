import Foundation
@testable import PrepareMeShared
import XCTest

/// The inventory file the Mac app edits (plan phase 7), on copies of the made-up rehearsal document
/// (Fixtures/inventory/rehearsal.grist, a copy of readiness/tests/fixtures/rehearsal.grist that
/// readiness/tests/test_inventory_fixture.py pins byte for byte). Never the owner's file.
final class InventoryTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/inventory/rehearsal.grist")
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-inventory-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func copy(_ name: String = "inventory.sqlite") throws -> URL {
        let target = base.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Self.fixture, to: target)
        return target
    }

    func open() throws -> (InventoryFile, Inventory) {
        let file = try InventoryFile(url: try copy())
        return (file, try Inventory(file: file))
    }

    func item(_ inventory: Inventory, _ name: String) -> InventoryRow {
        inventory.itemRows.first { inventory.name(ofItem: $0) == name }!
    }

    func place(_ inventory: Inventory, _ name: String) -> Int64 {
        inventory.locationRows.first { inventory.name(ofLocation: $0.id) == name }!.id
    }

    // MARK: Reading

    func testTheTablesAndColumnsAreReadAsTheListsJobReadsThem() throws {
        let (_, inventory) = try open()
        XCTAssertEqual(inventory.items.columns.map(\.label),
                       ["Item", "Category", "Brand", "Model", "Quantity", "Unit", "Location", "Grab", "Expires", "Year",
                        "Manual", "Calories each", "Mac only", "Notes"])
        let category = try XCTUnwrap(inventory.items.column("category "))
        XCTAssertEqual(category.kind, .reference(table: "Categories"))
        XCTAssertEqual(category.shownColId, "Name")
        XCTAssertEqual(category.displayColId, "gristHelper_Display")
        XCTAssertTrue(category.editable)
        XCTAssertEqual(inventory.items.column("Quantity")?.kind, .choice)
        XCTAssertTrue(inventory.items.column("Quantity")!.choices.contains("2"))
        XCTAssertEqual(inventory.items.column("Mac only")?.kind, .bool)
        XCTAssertEqual(inventory.itemRows.map(\.position), [1, 2, 3, 4, 5])
        XCTAssertEqual(inventory.itemRows.map { inventory.name(ofItem: $0) },
                       ["Dual fuel generator", "Indoor propane heater", "Drinking water jugs", "Test pickup truck",
                        "Test flashlight"])
        XCTAssertEqual(inventory.settings.column("Value")?.kind, .numeric)
    }

    func testAFileOfAnotherLayoutIsRefused() throws {
        let other = base.appendingPathComponent("other.sqlite")
        XCTAssertTrue(FileManager.default.createFile(atPath: other.path, contents: Data()))  // an empty database
        try SQLite(path: other, readOnly: false).execute("CREATE TABLE t (x)")
        XCTAssertThrowsError(try InventoryFile(url: other)) { error in
            XCTAssertEqual(error as? InventoryFileError, .notAnInventory)
        }
    }

    /// The phase 8 review: the phone's supply days read as the Mac's (readiness_view's test_supply_days_round_down).
    func testSupplyDaysReadAsTheMacWritesThem() {
        for (days, shown) in [(24.3, "24"), (89.9, "89"), (1234.5, "1,234"), (0.5, "0.5"), (0.04, "0.1"), (0, "0"),
                              (2.9999999, "3"), (0.3, "0.3"), (0.29, "0.2"), (24.333333333333332, "24"),
                              (1_234_567, "1,234,567")] {
            XCTAssertEqual(InventoryValues.days(days), shown, "\(days)")
        }
    }

    func testValuesAreShownAndStoredInGristsOwnWay() throws {
        let (_, inventory) = try open()
        let water = item(inventory, "Drinking water jugs")
        let expires = try XCTUnwrap(inventory.items.column("Expires"))
        XCTAssertEqual(InventoryValues.shown(water[expires], in: expires), "2027-03-01")
        XCTAssertEqual(try InventoryValues.stored("2027-03-01", in: expires).get(), water[expires])
        XCTAssertEqual(try InventoryValues.stored("3/1/2027", in: expires).get(), water[expires])
        XCTAssertEqual(try InventoryValues.stored("", in: expires).get(), .null)
        XCTAssertEqual(InventoryValues.stored("2027-02-30", in: expires), .failure(.notADate))
        let calories = try XCTUnwrap(inventory.items.column("Calories each"))
        XCTAssertEqual(try InventoryValues.stored("", in: calories).get(), .real(0))
        XCTAssertEqual(try InventoryValues.stored("1,045", in: calories).get(), .real(1045))
        XCTAssertEqual(InventoryValues.stored("lots", in: calories), .failure(.notANumber))
        XCTAssertEqual(InventoryValues.plain(.real(6)), "6")
        XCTAssertEqual(InventoryValues.plain(.real(2.5)), "2.5")
        let location = try XCTUnwrap(inventory.items.column("Location"))
        let names = inventory.names(for: location)
        XCTAssertEqual(InventoryValues.shown(water[location], in: location, names: names), "Pantry")
        XCTAssertEqual(try InventoryValues.stored("garage", in: location, names: names).get(),
                       .int(place(inventory, "Garage")))
        XCTAssertEqual(try InventoryValues.stored("", in: location, names: names).get(), .int(0))
        XCTAssertEqual(InventoryValues.stored("Attic", in: location, names: names), .failure(.notAName))
    }

    // MARK: Writing

    func testASetKeepsTheReferenceHelperInStep() throws {
        let (file, inventory) = try open()
        let water = item(inventory, "Drinking water jugs")
        let location = try XCTUnwrap(inventory.items.column("Location"))
        let old = try file.set(inventory.items, row: water.id, column: location,
                               to: .int(place(inventory, "Garage")), shown: "Garage")
        XCTAssertEqual(old, water[location])
        let after = try Inventory(file: file)
        let moved = item(after, "Drinking water jugs")
        XCTAssertEqual(moved[location], .int(place(after, "Garage")))
        XCTAssertEqual(moved.values["gristHelper_Display2"], .text("Garage"))
    }

    func testAnAddedRowTakesGristsBlanksAndGoesLast() throws {
        let (file, inventory) = try open()
        let name = try XCTUnwrap(inventory.items.column("Item"))
        let id = try file.addRow(inventory.items, values: [name.colId: .text("Spare batteries")])
        XCTAssertEqual(id, 6)
        let after = try Inventory(file: file)
        let added = try XCTUnwrap(after.itemRows.last)
        XCTAssertEqual(added.id, 6)
        XCTAssertEqual(added.position, 6)
        XCTAssertEqual(added.manualSort, .int(6))  // NUMERIC keeps a whole number whole
        XCTAssertEqual(added[after.items.column("Calories each")!], .int(0))
        XCTAssertEqual(added[after.items.column("Location")!], .int(0))
        XCTAssertEqual(added[after.items.column("Expires")!], .null)
        XCTAssertEqual(added[after.items.column("Notes")!], .text(""))
    }

    func testADeletedRowComesBackWhole() throws {
        let (file, inventory) = try open()
        let water = item(inventory, "Drinking water jugs")
        let cells = try file.deleteRow(inventory.items, row: water.id)
        XCTAssertEqual(try Inventory(file: file).itemRows.count, 4)
        try file.restore(inventory.items, row: water.id, cells: cells)
        let after = try Inventory(file: file)
        XCTAssertEqual(after.itemRows, inventory.itemRows)
    }

    func testTheAppsColumnIsAddedOnceAndDescribedAsGristDescribesOne() throws {
        let (file, _) = try open()
        XCTAssertTrue(try file.ensureColumn("Locations", colId: "Kept_in", label: "Kept in", type: "Ref:Locations"))
        XCTAssertFalse(try file.ensureColumn("Locations", colId: "Kept_in2", label: "kept in", type: "Ref:Locations"))
        let column = try XCTUnwrap(try file.table("Locations").column("Kept in"))
        XCTAssertEqual(column.kind, .reference(table: "Locations"))
        XCTAssertEqual(column.shownColId, "Name")
        let inventory = try Inventory(file: file)
        XCTAssertTrue(inventory.locationRows.allSatisfy { $0[column] == .int(0) })
    }

    // MARK: Rules

    func testALocationOrCategoryInUseCantBeDeletedAndSaysWhoUsesIt() throws {
        let (file, inventory) = try open()
        XCTAssertEqual(inventory.users(of: "Locations", row: place(inventory, "Garage")), ["Dual fuel generator"])
        XCTAssertEqual(inventory.users(of: "Locations", row: place(inventory, "Basement")), [])
        let water = inventory.categoryRows.first { InventoryValues.plain($0.values["Name"] ?? .null) == "Water" }!
        XCTAssertEqual(inventory.users(of: "Categories", row: water.id), ["Drinking water jugs"])
        try file.ensureColumn("Locations", colId: "Kept_in", label: "Kept in", type: "Ref:Locations")
        let keptIn = try file.table("Locations").column("Kept in")!
        try file.set(try file.table("Locations"), row: place(inventory, "Bin 01"), column: keptIn,
                     to: .int(place(inventory, "Basement")))
        let after = try Inventory(file: file)
        XCTAssertEqual(after.users(of: "Locations", row: place(after, "Basement")), ["Bin 01"])
    }

    func testBinsSitInsidePlacesAndAPlaceShowsWhatIsInItsBins() throws {
        let (file, start) = try open()
        try file.ensureColumn("Locations", colId: "Kept_in", label: "Kept in", type: "Ref:Locations")
        let keptIn = try file.table("Locations").column("Kept in")!
        let bin = place(start, "Bin 01"), garage = place(start, "Garage")
        try file.set(try file.table("Locations"), row: bin, column: keptIn, to: .int(garage))
        let flashlight = item(start, "Test flashlight")
        try file.set(start.items, row: flashlight.id, column: start.items.column("Location")!, to: .int(bin))
        let inventory = try Inventory(file: file)
        XCTAssertEqual(inventory.keptIn(bin), garage)
        XCTAssertFalse(inventory.places.contains { $0.id == bin })
        XCTAssertEqual(inventory.bins(in: garage).map(\.id), [bin])
        XCTAssertEqual(inventory.items(in: .location(garage)).map { inventory.name(ofItem: $0) },
                       ["Dual fuel generator", "Test flashlight"])
        XCTAssertEqual(inventory.items(in: .location(bin)).map { inventory.name(ofItem: $0) }, ["Test flashlight"])
        XCTAssertTrue(inventory.wouldLoop(garage, keptIn: bin))
        XCTAssertTrue(inventory.wouldLoop(bin, keptIn: bin))
        XCTAssertFalse(inventory.wouldLoop(bin, keptIn: place(inventory, "Shed")))
        XCTAssertEqual(inventory.grabTier(of: item(inventory, "Test flashlight")), 1)  // Bin 01's own Grab
    }

    /// Step 8a (owner, 2026-10-19, by click; A1 and A3): Locations lists the top-level places, each opening to what is
    /// kept in it; Vehicles lists each location ticked Vehicle the same way, and a vehicle shows there only, never
    /// under Locations nor inside the place it is kept in. The data is unchanged: a vehicle is still a location.
    func testLocationsAndVehiclesInTheSidebar() throws {
        let (file, start) = try open()
        _ = try file.ensureColumn("Locations", colId: "Kept_in", label: Inventory.Label.keptIn, type: "Ref:Locations")
        _ = try file.ensureColumn("Locations", colId: "Vehicle", label: Inventory.Label.vehicle, type: "Bool")
        let locations = try file.table("Locations")
        let keptIn = try XCTUnwrap(locations.column(Inventory.Label.keptIn))
        let vehicle = try XCTUnwrap(locations.column(Inventory.Label.vehicle))
        let garage = place(start, "Garage"), shed = place(start, "Shed"), bin = place(start, "Bin 01")
        try file.set(locations, row: shed, column: vehicle, to: .int(1))  // a made-up truck, parked in the garage
        try file.set(locations, row: shed, column: keptIn, to: .int(garage))
        try file.set(locations, row: bin, column: keptIn, to: .int(shed))  // its drawer
        let inventory = try Inventory(file: file)
        XCTAssertFalse(inventory.shownLocations.contains { $0.id == shed }, "a vehicle isn't listed under Locations")
        XCTAssertFalse(inventory.shownLocations.contains { $0.id == bin }, "only the top-level places")
        XCTAssertTrue(inventory.shownLocations.contains { $0.id == garage })
        XCTAssertFalse(inventory.shownInside(garage).contains { $0.id == shed }, "nor inside the place it's kept in")
        XCTAssertEqual(inventory.vehicleRows.map(\.id), [shed])
        XCTAssertEqual(inventory.shownInside(shed).map(\.id), [bin], "a vehicle opens to what's in it")
        XCTAssertEqual(inventory.vehicle(holding: bin), shed, "the grab-and-go list's reading is unchanged")
        XCTAssertEqual(inventory.path(ofLocation: bin), "Garage › Shed › Bin 01")
        XCTAssertEqual(InventoryWords.locations, "Locations")
        XCTAssertEqual(InventoryWords.vehicles, "Vehicles")
    }

    /// Step 8a (A2): the form keeps Calories each; the Mac's table leaves it out (ItemsTableColumns.hiddenAtFirst).
    func testCaloriesEachStaysAnItemColumn() throws {
        let (_, inventory) = try open()
        XCTAssertTrue(inventory.items.columns.contains { $0.label == "Calories each" }, "the form keeps it")
        XCTAssertEqual(Inventory.Label.caloriesEach, "Calories each")
    }

    /// The Mac's Fill in the blanks (step 8a review): only cells blank now, each with the value it was seen holding,
    /// so the editor keeps it only while it still does (a phone's change since is never overwritten); a whole
    /// package's calories only on a row that counts packages.
    func testWhatALookupFillsIn() throws {
        let (file, start) = try open()
        let row = item(start, "Test flashlight")
        let items = start.items
        for (label, value) in [("Brand", SQLValue.null), ("Model", .text("")), ("Notes", .text("")),
                               ("Unit", .text("each")), ("Calories each", .int(0))] {
            try file.set(items, row: row.id, column: items.column(label)!, to: value)
        }
        let info = ProductInfo(name: "Made up oats", brand: "Made Up Farms", size: "400 g", source: "Open Food Facts",
                               figures: FoodFigures(package: Amount(400, "g"), packageWords: "400 g", per100: 460),
                               figuresFrom: "Open Food Facts")
        XCTAssertEqual(info.calories, 1840)
        var inventory = try Inventory(file: file)
        var fills = inventory.lookupFills(info, row: row.id)
        XCTAssertEqual(fills.map(\.column.label), ["Brand", "Notes", "Calories each"], "the item's own name stays")
        XCTAssertEqual(fills.map(\.value), [.text("Made Up Farms"), .text("400 g"), .real(1840)])
        XCTAssertEqual(fills.map(\.expected), [.null, .text(""), .int(0)])
        XCTAssertNil(inventory.caloriesWithheld(info, row: row.id))
        try file.set(items, row: row.id, column: items.column("Unit")!, to: .text("pounds"))
        inventory = try Inventory(file: file)
        fills = inventory.lookupFills(info, row: row.id)
        XCTAssertEqual(fills.map(\.column.label), ["Brand", "Notes"], "a row in pounds gets no package's calories")
        XCTAssertEqual(inventory.caloriesWithheld(info, row: row.id),
                       "About 1,840 calories for the whole package (from Open Food Facts). Unit is pounds, so "
                       + "Calories each wasn't filled in.")
        XCTAssertEqual(inventory.lookupFills(info, row: 999_999).count, 0, "a row that's gone fills nothing")
        // UPCitemdb's model goes in Model too, while blank (owner, 2026-10-23)
        let goods = ProductInfo(name: "Made up lantern", brand: "Zorvex", model: "ZX-2", source: "UPCitemdb")
        XCTAssertEqual(inventory.lookupFills(goods, row: row.id).first { $0.column.label == "Model" }?.value,
                       .text("ZX-2"))
        try file.set(items, row: row.id, column: items.column("Model")!, to: .text("Own model"))
        XCTAssertNil(try Inventory(file: file).lookupFills(goods, row: row.id).first { $0.column.label == "Model" },
                     "a Model typed already stays")
    }

    /// No package size (owner, 2026-10-22): the servings boxes' figure fills Calories each and their words fill Notes.
    func testWhatALookupFillsInFromTheServingsBoxes() throws {
        let (file, start) = try open()
        let row = item(start, "Test flashlight")
        let items = start.items
        for (label, value) in [("Brand", SQLValue.null), ("Notes", .text("")), ("Unit", .text("cans")),
                               ("Calories each", .int(0))] {
            try file.set(items, row: row.id, column: items.column(label)!, to: value)
        }
        let soup = ProductInfo(name: "Made up soup", brand: "Made Up Farms", source: "Open Food Facts",
                               figures: FoodFigures(servingWords: "120 ml", perServing: 24), figuresFrom: "Open Food Facts")
        let worked = (calories: 150, note: "2.5 servings of 60 calories")
        var inventory = try Inventory(file: file)
        var fills = inventory.lookupFills(soup, row: row.id, servings: worked)
        XCTAssertEqual(fills.map(\.column.label), ["Brand", "Notes", "Calories each"])
        XCTAssertEqual(fills.map(\.value), [.text("Made Up Farms"), .text("2.5 servings of 60 calories"), .real(150)])
        XCTAssertEqual(inventory.lookupFills(soup, row: row.id).map(\.column.label), ["Brand"],
                       "boxes not filled in: nothing for Notes or Calories each")
        XCTAssertNil(inventory.caloriesWithheld(soup, row: row.id, servings: worked))
        try file.set(items, row: row.id, column: items.column("Unit")!, to: .text("pounds"))
        inventory = try Inventory(file: file)
        fills = inventory.lookupFills(soup, row: row.id, servings: worked)
        XCTAssertEqual(fills.map(\.column.label), ["Brand", "Notes"])
        XCTAssertEqual(inventory.caloriesWithheld(soup, row: row.id, servings: worked),
                       "150 calories for the whole package. Unit is pounds, so Calories each wasn't filled in.")
    }

    /// Keep past date (docs/plans/2026-10-23-empty-containers-and-kept-food.md): a kept row leaves Expiring soon.
    func testKeepPastDateLeavesExpiringSoon() throws {
        let (file, _) = try open()
        XCTAssertTrue(try file.ensureColumn("Inventory", colId: "Keep_past_date", label: Inventory.Label.keepPastDate,
                                            type: "Bool"))
        var inventory = try Inventory(file: file)
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        let jugs = try XCTUnwrap(inventory.items(in: .expiringSoon, today: later).first)
        XCTAssertFalse(inventory.keptPastDate(jugs))
        try file.set(inventory.items, row: jugs.id, column: inventory.items.column(Inventory.Label.keepPastDate)!,
                     to: .int(1))
        inventory = try Inventory(file: file)
        XCTAssertEqual(inventory.items(in: .expiringSoon, today: later), [])
    }

    /// The Not counted notice's Show them (owner, 2026-11-14): the rows a supply left out, by number and fingerprint,
    /// so a row moved or renamed since the count isn't shown in its place.
    func testTheLeftOutViewMatchesNumberAndName() throws {
        let (file, _) = try open()
        let inventory = try Inventory(file: file)
        let first = try XCTUnwrap(inventory.itemRows.first)
        let name = inventory.name(ofItem: first)
        let left = SupplyShares.LeftOut(row: first.position, item: SupplyShares.fingerprint(name), private: false,
                                        kind: "water", why: "unit")
        XCTAssertEqual(inventory.items(in: .leftOut([left])), [first])
        let renamed = SupplyShares.LeftOut(row: first.position, item: SupplyShares.fingerprint(name + " old"),
                                           private: false, kind: "water", why: "unit")
        XCTAssertEqual(inventory.items(in: .leftOut([renamed])), [], "another name at that number since the count")
        XCTAssertEqual(inventory.items(in: .leftOut([])), [])
    }

    func testTheViews() throws {
        let (_, inventory) = try open()
        func names(_ view: Inventory.View, today: Date = Date(timeIntervalSince1970: 1_790_000_000),
                   search: String = "") -> [String] {
            inventory.items(in: view, today: today, search: search).map { inventory.name(ofItem: $0) }
        }
        XCTAssertEqual(names(.privateOnly), ["Indoor propane heater"])
        XCTAssertEqual(names(.grab(2)), ["Drinking water jugs"])
        XCTAssertEqual(names(.group("Tools and equipment")), ["Indoor propane heater", "Test flashlight"])
        // 2026-09-21 plus the fixture's 60 heads-up days is before the jugs' 2027-03-01; 2027-01-15 isn't
        XCTAssertEqual(names(.expiringSoon), [])
        XCTAssertEqual(names(.expiringSoon, today: Date(timeIntervalSince1970: 1_800_000_000)), ["Drinking water jugs"])
        XCTAssertEqual(names(.all, search: "zorvex"), ["Dual fuel generator", "Test pickup truck"])
        XCTAssertEqual(names(.all, search: "zorvex garage"), ["Dual fuel generator"])
        // a guide's "In the house" (phase 14, F57): whole words of the name, a plural allowed
        XCTAssertEqual(names(.guide(title: "SAMPLE", words: ["generator", "jug"])),
                       ["Dual fuel generator", "Drinking water jugs"])
        XCTAssertEqual(names(.guide(title: "SAMPLE", words: ["gen"])), [])
        XCTAssertEqual(inventory.headsUpDays, 60)
        XCTAssertTrue(inventory.groups.contains("Vehicles and RV"))
    }

    func testTheCheckReadsARowAsTheListsJobDoes() throws {
        let (_, inventory) = try open()
        let generator = item(inventory, "Dual fuel generator")
        let row = inventory.checkRow("Inventory", values: generator.values, position: generator.position)
        XCTAssertEqual(row.place, "Inventory row 1")
        XCTAssertEqual(row.cells.map(\.label),
                       ["Item", "Category", "Brand", "Model", "Quantity", "Unit", "Location", "Grab", "Year", "Manual",
                        "Calories each", "Notes"])
        XCTAssertEqual(row.cells[1].text, "Power and batteries")
        XCTAssertEqual(row.cells.filter(\.longNumbersOK).map(\.label), ["Model"])
    }

    func testEveryTableExportsAsCSVAsTheEditorShowsIt() throws {
        let (_, inventory) = try open()
        let files = InventoryCSV.export(inventory)
        XCTAssertEqual(files.map(\.name), ["Inventory.csv", "Locations.csv", "Categories.csv", "Settings.csv"])
        let lines = files[0].text.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Item,Category,Brand,Model,Quantity,Unit,Location,Grab,Expires,Year,Manual,Calories each,"
                       + "Mac only,Notes")
        XCTAssertEqual(lines[3], "Drinking water jugs,Water,,,6,gallons,Pantry,1 hour,2027-03-01,,,0,,Made-up test item.")
        XCTAssertEqual(lines[2].components(separatedBy: ",")[12], "Yes")  // the private heater
        XCTAssertEqual(InventoryCSV.field("a, \"b\""), "\"a, \"\"b\"\"\"")
    }

    // MARK: The Mac's own check and reader, on this repository's code (skipped without the venv)

    var python: URL? {
        let found = PythonTextCheck.venvPython()
        return found.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    func testThePythonCheckKeepsAndRefuses() async throws {
        let python = try XCTUnwrap(python, "no venv")
        let check = PythonTextCheck(python: python, code: Self.repo)
        let clean = CheckRow(place: "Inventory row 1", cells: [CheckCell(label: "Item", text: "Lantern")])
        let ssn = ["219", "09", "9999"].joined(separator: "-")  // made up, in pieces (guard/tests/samples.py)
        let refused = CheckRow(place: "Inventory row 2", cells: [CheckCell(label: "Item", text: "Spare"),
                                                                  CheckCell(label: "Notes", text: "SSN \(ssn)")])
        let found = try await check.check([clean, refused], file: nil).refused
        XCTAssertEqual(found.map(\.row), [1])
        XCTAssertEqual(found.first?.cell, 1)
        XCTAssertTrue(found.first?.message.hasPrefix("Inventory row 2, Notes: ") ?? false)
        XCTAssertFalse(found.first?.message.contains(ssn) ?? true)
        let missing = PythonTextCheck(python: base.appendingPathComponent("no-python"), code: Self.repo)
        do {
            _ = try await missing.check([clean], file: nil)
            XCTFail("a check that can't run must throw")
        } catch is CheckUnavailable {}
    }

    /// The whole-file check on a changed copy: a Year the lists job refuses comes back in its own words.
    func testThePythonCheckReadsAChangedCopyWhole() async throws {
        let python = try XCTUnwrap(python, "no venv")
        let check = PythonTextCheck(python: python, code: Self.repo)
        let url = try copy("PrepareMe Inventory.grist")
        let file = try InventoryFile(url: url)
        let inventory = try Inventory(file: file)
        let row = CheckRow(place: "Inventory row 1", cells: [CheckCell(label: "Item", text: "Lantern")])
        let clean = try await check.check([row], file: url)
        XCTAssertNil(clean.refusal)
        try file.set(inventory.items, row: item(inventory, "Test pickup truck").id,
                     column: inventory.items.column("Year")!, to: .text("1850"))
        let refused = try await check.check([row], file: url)
        XCTAssertTrue(refused.file?.hasPrefix("PrepareMe Inventory.grist: Inventory row 4, Year") ?? false,
                      refused.file ?? "nil")
    }

    /// The lists job's reader reads the app's file as it reads the Grist document it came from: the app's own column
    /// changes nothing it reads, and an edit is read as the edit.
    func testTheListsJobReadsTheAppsFileAsItReadsGrists() async throws {
        let python = try XCTUnwrap(python, "no venv")
        let file = try InventoryFile(url: try copy())
        try file.ensureColumn("Locations", colId: "Kept_in", label: "Kept in", type: "Ref:Locations")
        let original = try await readerDigest(python, Self.fixture)
        let opened = try await readerDigest(python, file.url)
        XCTAssertEqual(original, opened)
        let inventory = try Inventory(file: file)
        try file.set(inventory.items, row: item(inventory, "Test flashlight").id,
                     column: inventory.items.column("Notes")!, to: .text("Made-up note."))
        let edited = try await readerDigest(python, file.url)
        XCTAssertNotEqual(original, edited)
    }

    /// A digest of what readiness/grist.py reads (rows, headers, groups, places, notes), never the text itself.
    func readerDigest(_ python: URL, _ path: URL) async throws -> String {
        let script = """
            import hashlib, sys, tempfile
            sys.path.insert(0, sys.argv[1])
            from readiness import grist
            with tempfile.TemporaryDirectory() as into:
                book = grist.read_grist(sys.argv[2], into)
            found = repr((book.rows, book.headers, book.counts_as, book.locations, book.row_places, book.notes))
            print(hashlib.sha256(found.encode()).hexdigest())
            """
        let (status, output) = try await PythonTextCheck.run(python, ["-I", "-B", "-c", script, Self.repo.path, path.path],
                                                             Data())
        XCTAssertEqual(status, 0)
        return String(decoding: output, as: UTF8.self)
    }
}
