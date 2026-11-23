import Foundation
@testable import PrepareMeShared
import Testing

/// What the Mac's Inventory home page lists (the inventory fresh look, phase 3, Task 3.2; spec 5.1), on copies of the
/// made-up rehearsal file, as `InventoryTests` opens it. Never the owner's file.
struct InventoryHomeTilesTests {
    /// A copy of the rehearsal file with Bin 01 kept in `binIn` and the flashlight in the bin; `vehicle` ticked Vehicle,
    /// then each of `vehicles` too, and each place in `keptIn` kept in the place named.
    func inventory(binIn: String, vehicle: String? = nil, vehicles: [String] = [],
                   keptIn: [String: String] = [:]) throws -> Inventory {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-tiles-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        let file = try InventoryFile(url: url)
        try file.ensureColumn("Locations", colId: "Kept_in", label: Inventory.Label.keptIn, type: "Ref:Locations")
        try file.ensureColumn("Locations", colId: "Vehicle", label: Inventory.Label.vehicle, type: "Bool")
        let start = try Inventory(file: file)
        let locations = try file.table("Locations")
        func place(_ name: String) -> Int64 {
            start.locationRows.first { start.name(ofLocation: $0.id) == name }!.id
        }
        try file.set(locations, row: place("Bin 01"), column: locations.column(Inventory.Label.keptIn)!,
                     to: .int(place(binIn)))
        for vehicle in [vehicle].compactMap({ $0 }) + vehicles {
            try file.set(locations, row: place(vehicle), column: locations.column(Inventory.Label.vehicle)!, to: .int(1))
        }
        for (inside, holder) in keptIn {
            try file.set(locations, row: place(inside), column: locations.column(Inventory.Label.keptIn)!,
                         to: .int(place(holder)))
        }
        let flashlight = start.itemRows.first { start.name(ofItem: $0) == "Test flashlight" }!
        try file.set(start.items, row: flashlight.id, column: start.items.column("Location")!, to: .int(place("Bin 01")))
        return try Inventory(file: file)
    }

    @Test func categoriesInTheTablesOrderWithTheirEmojiAndCounts() throws {
        let tiles = InventoryHomeTiles.categories(try inventory(binIn: "Garage"))
        #expect(tiles.count == 15)
        #expect(tiles.prefix(3).map(\.name) == ["Water", "Food", "Medicine"])
        #expect(tiles[0] == InventoryTile(id: 1, emoji: InventoryLook.emoji(category: "Water", group: "Water"),
                                          name: "Water", detail: "1 item"))
        #expect(tiles[1].detail == "0 items", "an empty category still shows")
        #expect(tiles.first { $0.name == "Power and Batteries" }?.detail == "1 item", "title case, as the sidebar was")
    }

    @Test func placesByNameAPlaceCountsWhatItsBinsHold() throws {
        let tiles = InventoryHomeTiles.locations(try inventory(binIn: "Garage"))
        #expect(tiles.map(\.name) == ["Basement", "Car", "Closet", "Garage", "Go-Bag", "Other", "Outbuilding", "Pantry",
                                      "Shed"], "top-level places only, by name; Bin 01 is inside the Garage")
        #expect(tiles.allSatisfy { $0.emoji == "📍" })
        #expect(tiles.first { $0.name == "Garage" }?.detail == "2 items, 1 bin", "the generator and the bin's flashlight")
        #expect(tiles.first { $0.name == "Basement" }?.detail == "0 items")
        #expect(tiles.first { $0.name == "Pantry" }?.detail == "1 item", "the water jugs")
        #expect(tiles.first { $0.name == "Closet" }?.detail == "1 item")
    }

    @Test func vehiclesWithTheirEmojiAndWhatsInside() throws {
        let made = try inventory(binIn: "Car", vehicle: "Car")
        #expect(InventoryHomeTiles.vehicles(made).map(\.name) == ["Car"])
        #expect(InventoryHomeTiles.vehicles(made).first?.emoji == InventoryLook.vehicleEmoji("Car"))
        #expect(InventoryHomeTiles.vehicles(made).first?.detail == "1 item, 1 inside")
        #expect(!InventoryHomeTiles.locations(made).contains { $0.name == "Car" }, "a vehicle is listed under Vehicles only")
        #expect(InventoryHomeTiles.vehicles(try inventory(binIn: "Garage")).isEmpty, "none, and then no heading")
    }

    @Test func moreListsWithNoListsRead() throws {
        let made = try inventory(binIn: "Garage")
        #expect(made.lists == nil)
        let more = InventoryHomeTiles.more(made)
        #expect(more == [.toDo, .upkeep, .grab(1), .grab(2), .privateOnly] + (made.hasInsuranceRecord ? [.insured] : []))
        #expect(more.prefix(5).map(\.title) == ["To Do", "Upkeep", "Grab in 10 Minutes", "Grab in an Hour", "Private"],
                "To Do and Upkeep always, as their sidebar rows (the owner's choice B, 2026-11-18)")
    }

    /// Each of the less-used lists shows only when the old list column showed it.
    @Test func moreListsAsTheListsHoldThem() {
        func row(_ cells: [String: ListCell]) -> ListRow { ListRow(pos: 1, cells: cells) }
        let empty = Lists.none
        #expect(InventoryHomeTiles.more(insured: false, lists: empty) == [.toDo, .upkeep, .grab(1), .grab(2), .targets,
                                                                          .privateOnly])
        let full = Lists(sheets: [ListsLayout.proposed: [row([:]), row([:])],
                                  ListsLayout.recalls: [row(["Status": .null]), row(["Status": .text("Not ours")])],
                                  ListsLayout.bought: [row([:])]], stamp: nil, revision: 1)
        let more = InventoryHomeTiles.more(insured: true, lists: full)
        #expect(more == [.toDo, .upkeep, .grab(1), .grab(2), .targets, .proposed(2), .recalls(1), .privateOnly, .insured,
                         .bought])
        #expect(more.map(\.title) == ["To Do", "Upkeep", "Grab in 10 Minutes", "Grab in an Hour", "Targets",
                                      "Proposed (2)", "Recalls (1)", "Private", "Insurance Record", "Bought, to Move"])
    }

    @Test func theBandsLine() {
        #expect(InventoryHomeTiles.bandLine(items: 212, places: 28) == "212 items in 28 places.")
        #expect(InventoryHomeTiles.bandLine(items: 1, places: 1) == "1 item in 1 place.")
        #expect(InventoryHomeTiles.bandLine(items: 0, places: 0) == "0 items in 0 places.")
    }

    /// The band's second line, from supply.json's `today` (the lists job's day); nothing for a date it can't read.
    @Test func whenTheCountWasMade() {
        #expect(InventoryHomeTiles.countedLine("2026-10-07") == "Counted Oct 7.")
        #expect(InventoryHomeTiles.countedLine("") == nil)
        #expect(InventoryHomeTiles.countedLine("October") == nil)
    }

    /// The slim band over a tile's table: the tile's own emoji, name and detail; a bin's too; nothing over any other
    /// table.
    @Test func theSlimBandOverATable() throws {
        let made = try inventory(binIn: "Garage")
        let garage = InventoryHomeTiles.locations(made).first { $0.name == "Garage" }!
        #expect(InventoryHomeTiles.band(made, view: .location(garage.id)) == garage)
        let water = InventoryHomeTiles.categories(made)[0]
        #expect(InventoryHomeTiles.band(made, view: .category(water.id)) == water)
        let bin = made.locationRows.first { made.name(ofLocation: $0.id) == "Bin 01" }!.id
        #expect(InventoryHomeTiles.band(made, view: .location(bin))
                == InventoryTile(id: bin, emoji: "📍", name: "Bin 01", detail: "1 item"))
        let car = try inventory(binIn: "Car", vehicle: "Car")
        let truck = InventoryHomeTiles.vehicles(car)[0]
        #expect(InventoryHomeTiles.band(car, view: .location(truck.id)) == truck, "a vehicle keeps its emoji")
        for view: Inventory.View in [.all, .expiringSoon, .grab(1), .privateOnly, .insured, .leftOut([])] {
            #expect(InventoryHomeTiles.band(made, view: view) == nil)
        }
    }

    /// The row of bins over a place's table: the place first (to see it whole again), then its bins by name; on a bin
    /// with none of its own, its place's row, so its neighbours stay one click away; nothing on a place with no bins.
    @Test func theBinsRow() throws {
        let made = try inventory(binIn: "Garage")
        func id(_ name: String) -> Int64 { made.locationRows.first { made.name(ofLocation: $0.id) == name }!.id }
        let row = InventoryHomeTiles.binsRow(made, location: id("Garage"))
        #expect(row?.owner == id("Garage"))
        #expect(row?.bins.map(\.name) == ["Bin 01"])
        #expect(row?.bins.first?.detail == "1 item")
        #expect(InventoryHomeTiles.binsRow(made, location: id("Bin 01"))?.owner == id("Garage"), "a bin: its place's row")
        #expect(InventoryHomeTiles.binsRow(made, location: id("Pantry")) == nil)
        #expect(InventoryHomeTiles.allOf("Garage") == "All of Garage")
    }

    /// A vehicle with no bins of its own shows no bins row, never the bins of the place it is parked in (fix round 1,
    /// finding 5).
    @Test func aVehicleWithNoBinsHasNoBinsRow() throws {
        let made = try inventory(binIn: "Garage", vehicle: "Car", keptIn: ["Car": "Garage"])
        func id(_ name: String) -> Int64 { made.locationRows.first { made.name(ofLocation: $0.id) == name }!.id }
        #expect(made.isVehicle(id("Car")) && made.keptIn(id("Car")) == id("Garage"))
        #expect(InventoryHomeTiles.binsRow(made, location: id("Car")) == nil, "the Garage's bins aren't the car's")
        #expect(InventoryHomeTiles.binsRow(made, location: id("Garage"))?.bins.map(\.name) == ["Bin 01"],
                "and the car isn't one of the Garage's bins")
    }

    /// A vehicle's "N inside" counts what its bins row shows: a vehicle kept in it (a trailer in the truck) is listed
    /// under Vehicles, so neither counts it (fix round 1, finding 5).
    @Test func aVehiclesInsideCountMatchesItsBinsRow() throws {
        let made = try inventory(binIn: "Car", vehicle: "Car", vehicles: ["Shed"], keptIn: ["Shed": "Car"])
        func id(_ name: String) -> Int64 { made.locationRows.first { made.name(ofLocation: $0.id) == name }!.id }
        #expect(made.bins(in: id("Car")).count == 2, "Bin 01 and the Shed, ticked Vehicle")
        let row = InventoryHomeTiles.binsRow(made, location: id("Car"))
        #expect(row?.bins.map(\.name) == ["Bin 01"])
        let tile = InventoryHomeTiles.vehicles(made).first { $0.name == "Car" }
        #expect(tile?.detail == "1 item, \(row?.bins.count ?? -1) inside")
    }
}
