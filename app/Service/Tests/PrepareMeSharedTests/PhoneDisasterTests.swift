import Foundation
@testable import PrepareMeShared
import XCTest

/// The phone's grab-and-go checklist and expiry reminders (plan phase 7, part 2), on a made-up copy for the phones.
final class PhoneDisasterTests: XCTestCase {
    func column(_ id: String, _ label: String, _ kind: String, target: String? = nil) -> PhoneInventory.Column {
        PhoneInventory.Column(colId: id, label: label, kind: kind, target: target, choices: [], editable: true)
    }

    func copy(items: [(Int64, String, Int64?, String, Double?)], places: [PhoneInventory.Place],
              headsUp: Int = 30) -> PhoneInventory {
        let columns = [column("Item", "Item", "text"), column("Location", "Location", "reference", target: "Locations"),
                       column("Grab", "Grab", "choice"), column("Expires", "Expires", "date")]
        let rows = items.enumerated().map { n, item in
            PhoneInventory.Row(id: item.0, position: n + 1, values: [
                "Item": .text(item.1), "Location": item.2.map { .int($0) } ?? .int(0), "Grab": .text(item.3),
                "Expires": item.4.map { .real($0) } ?? .null])
        }
        return PhoneInventory(writtenAt: "", columns: columns, items: rows, places: places, categories: [],
                              headsUpDays: headsUp, toBuy: [], results: [:])
    }

    let places = [
        PhoneInventory.Place(id: 1, name: "Garage", label: "", grab: "", keptIn: nil),
        PhoneInventory.Place(id: 2, name: "Bin 07", label: "Go-bag", grab: "10 min", keptIn: 1),
        PhoneInventory.Place(id: 3, name: "Bin 09", label: "", grab: "1 hour", keptIn: 1),
    ]

    func testABinIsOneTickAndAnItemGetsItsOwnOnlyWhenItGoesSooner() {
        let found = GrabChecklist(copy(items: [
            (10, "Water jugs", 2, "", nil),  // in the 10-minute bin: goes with it
            (11, "Lantern", 3, "10 min", nil),  // sooner than its 1-hour bin: its own tick
            (12, "Radio", 3, "1 hour", nil),  // its bin goes as soon: no tick of its own
            (13, "Medicine", 1, "10 min", nil),  // in a place with no Grab: its own tick
            (14, "Tent", nil, "1 hour", nil),
            (15, "Shovel", 1, "", nil),  // not marked anywhere
        ], places: places))
        XCTAssertEqual(found.tenMinutes.map(\.id), ["bin-2", "item-11", "item-13"])
        XCTAssertEqual(found.tenMinutes[0].name, "Bin 07 (Go-bag)")
        XCTAssertEqual(found.tenMinutes[0].whereKept, "Garage")
        XCTAssertEqual(found.tenMinutes[0].contents, ["Water jugs"])
        XCTAssertEqual(found.tenMinutes[1].whereKept, "Garage › Bin 09")
        XCTAssertEqual(found.anHour.map(\.id), ["bin-3", "item-14"])
        XCTAssertEqual(found.anHour[0].contents, ["Lantern", "Radio"])
        XCTAssertEqual(found.anHour[1].whereKept, "")
    }

    /// A Grab bin is one line with its count, its names a tap away; a loose item shows its quantity
    /// (remaining-findings plan, Task 12.1; F31; owner, 2026-10-18, by click).
    func testABinIsOneLineWithItsCount() {
        let found = GrabChecklist(copy(items: [
            (10, "Water jugs", 2, "", nil), (11, "Rope", 2, "", nil), (12, "Tarp", 2, "", nil),
        ], places: places))
        let bin = found.tenMinutes[0]
        XCTAssertEqual(bin.count, 3)
        XCTAssertEqual(bin.detail, "3 items")
        XCTAssertEqual(bin.contents, ["Rope", "Tarp", "Water jugs"], "a tap away")
        let one = GrabChecklist(copy(items: [(10, "Water jugs", 2, "", nil)], places: places)).tenMinutes[0]
        XCTAssertEqual(one.detail, "1 item")
        let empty = GrabChecklist(copy(items: [], places: places)).tenMinutes[0]
        XCTAssertEqual(empty.detail, "Nothing listed in it")
    }

    func testEntriesCarryQuantities() {
        var copy = copy(items: [(10, "AA batteries", 1, "10 min", nil), (11, "Lantern", 1, "10 min", nil),
                                (12, "Matches", 1, "10 min", nil)], places: places)
        copy = PhoneInventory(writtenAt: "", columns: copy.columns + [column("Quantity", "Quantity", "choice"),
                                                                      column("Unit", "Unit", "choice")],
                              items: copy.items.map { row in
                                  var values = row.values
                                  switch row.id {
                                  case 10: values["Quantity"] = .text("8"); values["Unit"] = .text("pack")
                                  case 11: values["Quantity"] = .real(2)
                                  default: values["Quantity"] = .text("0")
                                  }
                                  return PhoneInventory.Row(id: row.id, position: row.position, values: values)
                              }, places: copy.places, categories: [], headsUpDays: 30, toBuy: [], results: [:])
        let found = GrabChecklist(copy).tenMinutes.filter { $0.id.hasPrefix("item-") }
        XCTAssertEqual(found.map(\.detail), ["Quantity 8 pack", "Quantity 2", ""], "a 0 says nothing")
        XCTAssertEqual(found.map(\.count), [0, 0, 0])
    }

    /// A copy written before quantities were shown, with no Quantity column, still reads.
    func testAnOlderCopyStillReads() {
        let found = GrabChecklist(copy(items: [(13, "Medicine", 1, "10 min", nil)], places: places))
        XCTAssertEqual(found.tenMinutes.map(\.name), ["Bin 07 (Go-bag)", "Medicine"])
        XCTAssertEqual(found.tenMinutes[1].quantity, "")
        XCTAssertEqual(found.tenMinutes[1].detail, "")
    }

    /// The owner's case (2026-10-14): a go-bag in a drawer in the truck, gear in the RV's cabinets.
    /// Step 8a (owner, 2026-10-19; A1 and A3): the phone's Locations lists the top-level places that aren't vehicles,
    /// Vehicles the places ticked Vehicle, and each opens to what's kept in it, never a vehicle; the grab-and-go
    /// checklist reads the same copy unchanged.
    func testLocationsAndVehiclesOnThePhone() {
        let places = [
            PhoneInventory.Place(id: 1, name: "Garage", label: "", grab: "", keptIn: nil, vehicle: false),
            PhoneInventory.Place(id: 2, name: "Truck", label: "", grab: "", keptIn: 1, vehicle: true),
            PhoneInventory.Place(id: 3, name: "Truck drawer", label: "", grab: "", keptIn: 2, vehicle: false),
            PhoneInventory.Place(id: 4, name: "Bin 07", label: "", grab: "10 min", keptIn: 1, vehicle: false),
            PhoneInventory.Place(id: 5, name: "RV", label: "", grab: "", keptIn: nil, vehicle: true),
            PhoneInventory.Place(id: 6, name: "Shed", label: "", grab: "", keptIn: nil),  // an older Mac's: no tick
        ]
        let copy = copy(items: [(10, "Flares", 3, "", nil), (11, "Water jugs", 4, "", nil)], places: places)
        XCTAssertEqual(copy.shownLocations.map(\.id), [1, 6])
        XCTAssertEqual(copy.vehicles.map(\.id), [2, 5])
        XCTAssertEqual(copy.shownInside(1).map(\.id), [4], "the truck parked in the garage shows under Vehicles only")
        XCTAssertEqual(copy.shownInside(2).map(\.id), [3])
        let found = GrabChecklist(copy)
        XCTAssertEqual(found.vehicles.map(\.name), ["RV", "Truck"])
        XCTAssertEqual(found.tenMinutes.map(\.id), ["bin-4"])
    }

    func testWhatsInAVehicleGoingIsLoadedAndABagInOneStayingMovesOver() {
        let places = [
            PhoneInventory.Place(id: 1, name: "Truck", label: "", grab: "", keptIn: nil, vehicle: true),
            PhoneInventory.Place(id: 2, name: "Truck drawer", label: "", grab: "", keptIn: 1, vehicle: false),
            PhoneInventory.Place(id: 3, name: "Truck go-bag", label: "", grab: "10 min", keptIn: 2, vehicle: false),
            PhoneInventory.Place(id: 4, name: "RV", label: "", grab: "", keptIn: nil, vehicle: true),
            PhoneInventory.Place(id: 5, name: "RV cabinet", label: "", grab: "", keptIn: 4, vehicle: false),
            PhoneInventory.Place(id: 6, name: "Hall closet", label: "", grab: "10 min", keptIn: nil, vehicle: false),
            PhoneInventory.Place(id: 7, name: "First aid pouch", label: "", grab: "10 min", keptIn: 6, vehicle: false),
        ]
        let copy = copy(items: [
            (10, "Water bottles", 3, "", nil), (11, "Flashlight", 3, "", nil),  // in the truck's go-bag
            (12, "Tow strap", 2, "", nil),  // in the truck's drawer
            (13, "Canned soup", 5, "1 hour", nil),  // in the RV, marked on its own
            (14, "Gauze", 7, "", nil),  // in a pouch inside a grab closet: goes with the closet
        ], places: places)
        XCTAssertEqual(copy.path(3), "Truck › Truck drawer › Truck go-bag")
        XCTAssertEqual(copy.vehicle(holding: 3), 1)
        let staying = GrabChecklist(copy)
        XCTAssertEqual(staying.vehicles.map(\.name), ["RV", "Truck"])
        XCTAssertEqual(staying.vehicles.map(\.items), [1, 3])
        XCTAssertEqual(staying.tenMinutes.map(\.id), ["bin-6", "bin-3"], "Hall closet, then Truck go-bag")
        let bag = staying.tenMinutes.first { $0.id == "bin-3" }
        XCTAssertEqual(bag?.whereKept, "Truck › Truck drawer")
        XCTAssertEqual(bag?.vehicle, 1)
        XCTAssertEqual(bag?.contents, ["Flashlight", "Water bottles"])
        XCTAssertEqual(staying.tenMinutes.first { $0.id == "bin-6" }?.contents, ["Gauze"], "the pouch goes with it")
        XCTAssertEqual(staying.anHour.map(\.name), ["Canned soup"])
        XCTAssertEqual(staying.anHour.first?.whereKept, "RV › RV cabinet")
        let truck = GrabChecklist(copy, going: [1])
        XCTAssertEqual(truck.tenMinutes.map(\.id), ["bin-6"], "the truck's go-bag is loaded already")
        XCTAssertEqual(truck.loaded, 3)
        let both = GrabChecklist(copy, going: [1, 4])
        XCTAssertEqual(both.anHour, [])
        XCTAssertEqual(both.loaded, 4)
    }

    /// A reminder's tap opens Expiring soon; the ask comes after the app's own line, on any paired phone, a child's too,
    /// and a refusal offers Settings (remaining-findings plan, Task 12.6; F38; owner, 2026-10-18, by click).
    func testReminderTapOpensExpiringSoon() {
        XCTAssertTrue(ExpiryReminders.isReminder("prepareme-expiry-2026-10-21"))
        XCTAssertFalse(ExpiryReminders.isReminder("1C2D3E4F-0000-4000-8000-000000000000"), "a download's")
        XCTAssertEqual(ReminderAsk.offer(.notAsked, hasReminders: true), .ask)
        XCTAssertEqual(ReminderAsk.offer(.refused, hasReminders: true), .settings)
        XCTAssertEqual(ReminderAsk.offer(.allowed, hasReminders: true), .none)
        XCTAssertEqual(ReminderAsk.offer(.notAsked, hasReminders: false), .none, "nothing to remind of: no ask")
        XCTAssertTrue(ReminderAsk.why.contains("expire"), ReminderAsk.why)
        XCTAssertEqual(ReminderAsk.why, "Get a reminder when food or medicine is about to expire (it shows a count, "
                       + "never what).", "B2-17")
        XCTAssertTrue(ReminderAsk.refused.contains("Settings"), ReminderAsk.refused)
    }

    func testRemindersCountTheItemsReachingTheirHeadsUpEachDayAndNameNone() throws {
        // 2026-10-14 15:00 UTC is 11:00 in New York
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-14T15:00:00Z"))
        func midnight(_ day: String) -> Double {
            ISO8601DateFormatter().date(from: day + "T00:00:00Z")!.timeIntervalSince1970  // Grist's dates
        }
        let reminders = ExpiryReminders.make(copy(items: [
            (1, "Rice", nil, "", midnight("2026-11-20")),  // heads-up 2026-10-21
            (2, "Beans", nil, "", midnight("2026-11-20")),
            (3, "Batteries", nil, "", midnight("2026-11-13")),  // heads-up today: already in Expiring soon
            (4, "Old flour", nil, "", midnight("2026-09-01")),
            (5, "Honey", nil, "", midnight("2027-06-01")),  // beyond 60 days
        ], places: []), now: now)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders[0].day, DateComponents(year: 2026, month: 10, day: 21, hour: 9))
        XCTAssertEqual(reminders[0].count, 2)
        XCTAssertEqual(reminders[0].identifier, "prepareme-expiry-2026-10-21")
        XCTAssertFalse(reminders[0].body.contains("Rice"))
        XCTAssertEqual(reminders[0].body,
                       "2 items in the inventory reach their heads-up date today. Open Expiring soon to see them.")
    }

    /// Keep past date (the 2026-10-23 plan): a kept row raises no reminder.
    func testAKeptRowRaisesNoReminder() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-14T15:00:00Z"))
        let soon = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")).timeIntervalSince1970
        let plain = copy(items: [(1, "Rice", nil, "", soon), (2, "Beans", nil, "", soon)], places: [], headsUp: 30)
        let keep = PhoneInventory.Column(colId: "Keep_past_date", label: "Keep past date", kind: "bool", target: nil,
                                         choices: [], editable: true)
        var rows = plain.items
        rows[1] = PhoneInventory.Row(id: rows[1].id, position: rows[1].position,
                                     values: rows[1].values.merging(["Keep_past_date": .int(1)]) { $1 }, manual: nil)
        let kept = PhoneInventory(writtenAt: "", columns: plain.columns + [keep], items: rows, places: [],
                                  categories: [], headsUpDays: 30, toBuy: [], results: [:])
        XCTAssertEqual([kept.keptPastDate(kept.items[0]), kept.keptPastDate(kept.items[1])], [false, true])
        XCTAssertEqual(ExpiryReminders.make(kept, now: now).map(\.count), [1])
        XCTAssertEqual(ExpiryReminders.make(plain, now: now).map(\.count), [2])
    }
}

/// The phone's own count of days (plan phase 7, part 2) from the lists job's own shares (Fixtures/supply.json, made by
/// readiness/tests/test_appsupply.py from its made-up rows, whose days the Mac counted).
final class SupplySharesTests: XCTestCase {
    static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    func copy(_ rows: [(Int, String, Double)]) -> PhoneInventory {
        let columns = [PhoneInventory.Column(colId: "Item", label: "Item", kind: "text", target: nil, choices: [],
                                             editable: true),
                       PhoneInventory.Column(colId: "Quantity", label: "Quantity", kind: "numeric", target: nil,
                                             choices: [], editable: true)]
        return PhoneInventory(writtenAt: "", columns: columns, items: rows.map {
            PhoneInventory.Row(id: Int64($0.0 + 100), position: $0.0, values: ["Item": .text($0.1), "Quantity": .real($0.2)])
        }, places: [], categories: [], headsUpDays: 30, toBuy: [], results: [:])
    }

    func testThePhoneCountsTheMacsOwnDaysThenItsOwnUse() throws {
        let shares = try XCTUnwrap(SupplyShares.read(in: Self.sample))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-07T16:00:00Z"))  // the sample's today
        let rows = [(2, "Water jugs", 20.0), (3, "Bottled water", 12.0), (4, "Old water", 5.0), (6, "Rice", 10.0),
                    (8, "Dog food", 30.0), (10, "Kept water", 3.0), (11, "Empty jug", 5.0)]
        for kind in shares.supplies {
            let found = SupplyShares.days(kind, in: copy(rows), now: now)
            XCTAssertEqual(found.days, kind.days, kind.kind)
            XCTAssertEqual(found.here, kind.perDay != nil, kind.kind)
        }
        let water = shares.supplies[0]
        let less = SupplyShares.days(water, in: copy([(2, "Water jugs", 10), (3, "Bottled water", 12), (4, "Old water", 5),
                                                      (10, "Kept water", 3)]), now: now)
        XCTAssertLessThan(try XCTUnwrap(less.days), try XCTUnwrap(water.days))
        XCTAssertEqual(SupplyShares.days(water, in: copy([(2, "Tent", 20)]), now: now).here, false,
                       "another row at that number: the Mac's days")
        XCTAssertEqual(SupplyShares.fingerprint("  Water   jugs "), SupplyShares.fingerprint("water jugs"))
    }

    /// Entry fixes plan, Task 3.4: the item forms' line, from the lists job's own sample (its made-up rows).
    func testCountedTowardLine() throws {
        let shares = try XCTUnwrap(SupplyShares.read(in: Self.sample))
        XCTAssertEqual(SupplyShares.countedLine(shares, row: 2, item: "Water jugs"), "Counts toward: water.")
        XCTAssertEqual(SupplyShares.countedLine(shares, row: 6, item: "Rice"), "Counts toward: food.")
        XCTAssertEqual(SupplyShares.countedLine(shares, row: 8, item: "dog  food"), "Counts toward: dog food.")
        XCTAssertEqual(SupplyShares.countedLine(shares, row: 7, item: "Mystery cans"), "Not counted toward any supply.")
        XCTAssertEqual(SupplyShares.countedLine(shares, row: 2, item: "Tent"), "Counted after tonight's count.",
                       "another item at that number since the count")
        XCTAssertEqual(SupplyShares.countedLine(nil, row: 2, item: "Water jugs"), "Counted after tonight's count.")
        XCTAssertEqual(SupplyShares.countedLine(shares, row: 9, item: "Spare water"), "Counts toward: water.",
                       "the Mac's own: a Private row")
        XCTAssertEqual(SupplyShares.countedLine(shares.forPhones, row: 9, item: "Spare water"),
                       "Counted after tonight's count.", "never on a phone")
        let two = SupplyShares(format: 1, today: "", supplies: [], countedToward: [
            .init(row: 4, item: SupplyShares.fingerprint("Power station"), private: false,
                  kinds: ["water once filled", "stored power"])])
        XCTAssertEqual(SupplyShares.countedLine(two, row: 4, item: "Power station"),
                       "Counts toward: water once filled, stored power.")
        let left = SupplyShares(format: 1, today: "", supplies: [], countedToward: [
            .init(row: 4, item: SupplyShares.fingerprint("Old water"), private: false, kinds: [], why: "expired"),
            .init(row: 5, item: SupplyShares.fingerprint("Spare jug"), private: false, kinds: [], why: "quantity")])
        XCTAssertEqual(SupplyShares.countedLine(left, row: 4, item: "Old water"),
                       "Not counted now: it's past its Expires date.")
        XCTAssertEqual(SupplyShares.countedLine(left, row: 5, item: "Spare jug"), "Not counted now: it has no Quantity.")
    }

    /// The Inventory's Not counted notice (owner, 2026-11-14, by click): the lists job's left-out rows (its own sample)
    /// and notes, one line under the heading; a phone's copy keeps the shared rows only, and every note.
    func testTheNotCountedNotice() throws {
        let sample = try XCTUnwrap(SupplyShares.read(in: Self.sample))
        XCTAssertEqual(sample.leftOut?.map(\.row), [4, 7], "the expired water and the cans with no calories")
        XCTAssertTrue(sample.leftOut(row: 4, item: "old  WATER"))
        XCTAssertFalse(sample.leftOut(row: 4, item: "Tent"), "another item at that number since the count")
        XCTAssertNil(sample.notCountedLine, "no notes from the shares alone: the engine adds them")
        let shares = SupplyShares(format: 1, today: "", supplies: [], leftOut: [
            .init(row: 3, item: SupplyShares.fingerprint("Canned water"), private: false, kind: "water", why: "unit"),
            .init(row: 9, item: SupplyShares.fingerprint("Spare water"), private: true, kind: "water", why: "unit")],
            notes: ["2 water rows aren't in gallons, liters or fl oz, so they aren't counted",
                    "People in household isn't filled in."])
        XCTAssertEqual(shares.notCountedLine, "Not counted in the supplies' days: 2 water rows aren't in gallons, "
                       + "liters or fl oz, so they aren't counted. People in household isn't filled in.")
        XCTAssertEqual(shares.forPhones.leftOut?.map(\.row), [3], "never a Private row on a phone")
        XCTAssertEqual(shares.forPhones.notes, shares.notes, "counts only: the same on every phone")
        let coded = try JSONDecoder().decode(SupplyShares.self, from: JSONEncoder().encode(shares))
        XCTAssertEqual(coded, shares, "the phones' copy carries both")
        XCTAssertEqual(SupplyShares.showThem(2), "Show Them (2)")
    }

    /// Phase 3's review: a jug counted each with Each holds 5 gallons, changed on the phone to 30 gallons (or Each
    /// holds 2.5), never counts 30 × 5: the phone shows the Mac's days until the next count.
    func testARowMeasuredOtherwiseSinceTheCountShowsTheMacsDays() {
        let columns = ["Item", "Quantity", "Unit", "Each holds", "Holds unit"].map {
            PhoneInventory.Column(colId: $0, label: $0, kind: $0 == "Quantity" || $0 == "Each holds" ? "numeric" : "text",
                                  target: nil, choices: [], editable: true)
        }
        func copy(_ quantity: Double, _ unit: String, _ holds: Double, _ holdsUnit: String) -> PhoneInventory {
            PhoneInventory(writtenAt: "", columns: columns, items: [PhoneInventory.Row(id: 2, position: 2, values: [
                "Item": .text("Water jug"), "Quantity": .real(quantity), "Unit": .text(unit), "Each holds": .real(holds),
                "Holds unit": .text(holdsUnit)])], places: [], categories: [], headsUpDays: 30, toBuy: [], results: [:])
        }
        let kind = SupplyShares.Kind(kind: "water", unit: "gallons", perDay: 1, days: 30, target: 30, rows: [
            SupplyShares.Row(row: 2, per: 5, expires: nil, item: SupplyShares.fingerprint("Water jug"), unit: "gallons",
                             each: 5)], other: [], privateRows: nil)
        XCTAssertEqual(SupplyShares.have(kind, in: copy(6, "each", 5, "gallons")), 30)
        XCTAssertEqual(SupplyShares.have(kind, in: copy(4, "Each", 5, "Gallons")), 20, "one used: counted here")
        XCTAssertNil(SupplyShares.have(kind, in: copy(30, "gallons", 5, "gallons")), "never 30 × 5")
        XCTAssertNil(SupplyShares.have(kind, in: copy(6, "each", 2.5, "gallons")))
        XCTAssertEqual(SupplyShares.measured(unit: " Bags ", holds: 20, holdsUnit: "pounds").each, 20)
        XCTAssertEqual(SupplyShares.measured(unit: "gallons", holds: 5, holdsUnit: "gallons").each, 1, "measured already")
        // a water bottle off its label (2026-10-30), as readiness/supply.py measures it
        XCTAssertTrue(SupplyShares.measured(unit: "bottles", holds: 16.9, holdsUnit: "fl oz") == ("fl oz", 16.9))
    }
}
