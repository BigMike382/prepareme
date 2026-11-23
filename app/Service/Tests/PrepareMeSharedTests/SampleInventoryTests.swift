import Foundation
@testable import PrepareMeShared
import XCTest

/// The sample library's made-up inventory (Unlisted plan, phase 4; docs/plans/2026-11-22-unlisted-phase-4-sample.md):
/// a made-up household in Washington, DC, written here in the phones' own format, so the file the sample carries is
/// one the phones' own decoder reads. packer/sample/sample-inventory.json must be what `sample` gives now; rewrite it
/// with PREPAREME_WRITE_FIXTURE=1 swift test --filter SampleInventoryTests after a deliberate change (the owner reads
/// it again before it ships: its fingerprint changes).
final class SampleInventoryTests: XCTestCase {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../packer/sample/sample-inventory.json").standardizedFileURL

    /// A day as the Mac's copy keeps a date: seconds since 1970 at midnight UTC.
    static func day(_ text: String) -> SQLValue {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
        return .int(Int64(date.timeIntervalSince1970))
    }

    static var sample: PhoneInventory {
        let columns = [
            PhoneInventory.Column(colId: "Item", label: "Item", kind: "text", target: nil, choices: [], editable: true),
            PhoneInventory.Column(colId: "Category", label: "Category", kind: "reference", target: "Categories",
                                  choices: [], editable: true),
            PhoneInventory.Column(colId: "Quantity", label: "Quantity", kind: "choice", target: nil,
                                  choices: ["1", "2", "3", "4", "6", "8", "10", "12", "24"], editable: true),
            PhoneInventory.Column(colId: "Unit", label: "Unit", kind: "choice", target: nil,
                                  choices: ["each", "gallons", "cans", "packs", "boxes", "rolls"], editable: true),
            PhoneInventory.Column(colId: "Location", label: "Location", kind: "reference", target: "Locations",
                                  choices: [], editable: true),
            PhoneInventory.Column(colId: "Expires", label: "Expires", kind: "date", target: nil, choices: [],
                                  editable: true),
            PhoneInventory.Column(colId: "Notes", label: "Notes", kind: "text", target: nil, choices: [], editable: true),
        ]
        let places = [
            PhoneInventory.Place(id: 1, name: "Hall closet", label: "", grab: "", keptIn: nil),
            PhoneInventory.Place(id: 2, name: "Pantry", label: "", grab: "", keptIn: nil),
            PhoneInventory.Place(id: 3, name: "Garage shelf", label: "", grab: "", keptIn: nil),
            PhoneInventory.Place(id: 4, name: "Car trunk", label: "", grab: "1 hour", keptIn: nil),
            PhoneInventory.Place(id: 5, name: "Go-bag", label: "", grab: "10 min", keptIn: 1),
        ]
        let categories = [("Water", 1), ("Food", 2), ("Power and batteries", 3), ("Tools", 4), ("Gear", 5),
                          ("Communications", 6), ("Hygiene and sanitation", 7)]
            .map { PhoneInventory.Category(id: Int64($0.1), name: $0.0, group: $0.0) }
        // (item, category, quantity, unit, place, expires or nil, notes)
        let rows: [(String, Int, String, String, Int, String?, String)] = [
            ("Drinking water jugs", 1, "6", "gallons", 2, "2027-09-30", ""),
            ("Bottled water", 1, "24", "each", 2, "2027-03-31", ""),
            ("Water purification tablets", 1, "1", "packs", 5, "2029-01-31", ""),
            ("Canned beans", 2, "12", "cans", 2, "2028-05-31", ""),
            ("Canned soup", 2, "8", "cans", 2, "2027-11-30", ""),
            ("Peanut butter", 2, "2", "each", 2, "2027-02-28", ""),
            ("Crackers", 2, "4", "boxes", 2, "2027-01-31", ""),
            ("Rice", 2, "2", "packs", 2, "2028-10-31", ""),
            ("Energy bars", 2, "12", "each", 5, "2027-06-30", ""),
            ("Manual can opener", 4, "1", "each", 2, nil, ""),
            ("Flashlight", 3, "2", "each", 1, nil, ""),
            ("Headlamp", 3, "1", "each", 5, nil, ""),
            ("AA batteries", 3, "24", "each", 1, "2032-12-31", ""),
            ("AAA batteries", 3, "12", "each", 1, "2032-12-31", ""),
            ("Battery lantern", 3, "1", "each", 3, nil, ""),
            ("Power bank", 3, "2", "each", 5, nil, "Charged once a month"),
            ("Hand-crank radio", 6, "1", "each", 1, nil, ""),
            ("Whistle", 5, "2", "each", 5, nil, ""),
            ("Emergency blankets", 5, "4", "each", 5, nil, ""),
            ("Rain ponchos", 5, "4", "each", 4, nil, ""),
            ("Work gloves", 4, "2", "each", 3, nil, ""),
            ("Duct tape", 4, "1", "rolls", 3, nil, ""),
            ("Multi-tool", 4, "1", "each", 5, nil, ""),
            ("Fire extinguisher", 4, "1", "each", 1, "2031-04-30", "Checked each spring"),
            ("Toilet paper", 7, "12", "rolls", 1, nil, ""),
            ("Hand sanitizer", 7, "2", "each", 5, "2027-08-31", ""),
            ("Garbage bags", 7, "1", "boxes", 3, nil, ""),
            ("Paper maps of the area", 6, "1", "each", 4, nil, ""),
            ("Jumper cables", 4, "1", "each", 4, nil, ""),
            ("Spare water for the car", 1, "2", "gallons", 4, "2027-05-31", ""),
        ]
        let items = rows.enumerated().map { index, row in
            var values: [String: SQLValue] = ["Item": .text(row.0), "Category": .int(Int64(row.1)), "Quantity": .text(row.2),
                                              "Unit": .text(row.3), "Location": .int(Int64(row.4)),
                                              "Notes": .text(row.6)]
            values["Expires"] = row.5.map(day) ?? .null
            return PhoneInventory.Row(id: Int64(index + 1), position: index + 1, values: values)
        }
        // two meeting places, at public places in the District, never a home
        let marks = [
            MapMark(id: 1, kind: .rally, name: "Lincoln Park", note: "By the statue, at the park's middle",
                    points: [[-76.990345, 38.889905]], role: .nearHome),
            MapMark(id: 2, kind: .rally, name: "Union Station", note: "Front entrance, under the arches",
                    points: [[-77.006317, 38.897462]], role: .neighborhood),
        ]
        return PhoneInventory(writtenAt: "2026-11-22T12:00:00Z", columns: columns, items: items, places: places,
                              categories: categories, headsUpDays: 60, toBuy: [], results: [:], marks: marks, pins: [],
                              format: FileFormat.current)
    }

    func testTheCommittedSampleIsWhatThisGives() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(Self.sample) + Data("\n".utf8)
        if ProcessInfo.processInfo.environment["PREPAREME_WRITE_FIXTURE"] == "1" {
            try data.write(to: Self.file)
        }
        XCTAssertEqual(try Data(contentsOf: Self.file), data,
                       "rewrite with PREPAREME_WRITE_FIXTURE=1 swift test --filter SampleInventoryTests")
    }

    func testThePhonesReadItAndItHoldsNothingPrivate() throws {
        let copy = try JSONDecoder().decode(PhoneInventory.self, from: Data(contentsOf: Self.file))
        XCTAssertEqual(copy, Self.sample)
        XCTAssertEqual(copy.items.count, 30)
        XCTAssertEqual(copy.places.count, 5)
        XCTAssertEqual(copy.mapMarks.count, 2)
        XCTAssertTrue(copy.barcodes?.isEmpty ?? true, "no barcodes")
        XCTAssertNil(copy.lists)
        XCTAssertNil(copy.pets)
        let held = Set(copy.columns.map(\.colId))
        for column in ["Brand", "Model", "Serial_number", "Price", "Purchased", "Photo", "Mac_only"] {
            XCTAssertFalse(held.contains(column), column)
        }
        for mark in copy.mapMarks {  // inside the District, so on the sample's map
            XCTAssertTrue((-77.12 ... -76.90).contains(mark.points[0][0]) && (38.79 ... 39.0).contains(mark.points[0][1]))
        }
    }
}
