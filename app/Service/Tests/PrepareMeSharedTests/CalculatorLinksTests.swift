import Foundation
import PrepareMeShared
import XCTest

/// The calculators on the inventory's categories (household/calculator-links.json; step 8b): read exactly as
/// packer/calculator_links.py writes the committed table (pinned by Fixtures/calculator-links.json, which packer's
/// tests also check), refused for any other shape, and each link's `#` part made from the lists job's own figures
/// (Fixtures/supply.json, made by readiness/tests/test_appsupply.py) as packer's inventory.html makes it.
final class CalculatorLinksTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    var fixture: CalculatorLinks {
        get throws {
            try CalculatorLinks(try Data(contentsOf: Self.fixtures.appendingPathComponent("calculator-links.json")))
        }
    }

    var figures: CalculatorFigures {
        get throws { try XCTUnwrap(SupplyShares.read(in: Self.fixtures)?.calculators) }
    }

    func testWordsPinned() {
        XCTAssertEqual(CalculatorLinks.path, "household/calculator-links.json")
        XCTAssertEqual(CalculatorLinks.line, "Calculators")
        XCTAssertEqual(CalculatorLinks.filled("Oct 20, 2:37 AM"),
                       "Filled in from the inventory's count of Oct 20, 2:37 AM.")
        XCTAssertEqual(CalculatorLinks.propanePoundsOnly, "Only propane counted in pounds is included.")
        XCTAssertEqual(CalculatorLinks.gasolineGallonsOnly, "Only gasoline counted in gallons is included.")
        XCTAssertEqual(CalculatorLinks.generatorPage, "calc-generator.html")
        XCTAssertEqual(CalculatorLinks.firewoodCordsOnly, "Only firewood counted in cords is included.")
        XCTAssertEqual(CalculatorLinks.firewoodPage, "calc-firewood.html")
    }

    func testReadsTheOwnersTable() throws {
        let rows = try fixture.rows
        XCTAssertEqual(rows.map(\.category),
                       ["Water", "Water", "Food", "Food", "Pets", "Power and fuel", "Power and fuel", "Power and fuel",
                        "Medical", "Heat and shelter", "Food", "Food", "Water",
                        "Food"])
        XCTAssertEqual(rows[10].calculators, [CalculatorLinks.Calculator(page: "calc-formula.html", name: "Baby Formula")])
        XCTAssertEqual(rows[10].when, ["infant formula", "baby formula"], "gap calculators plan, section 1")
        XCTAssertEqual(rows[11].calculators, [CalculatorLinks.Calculator(page: "calc-ferment-salt.html",
                                                                         name: "Salt for Fermenting")])
        XCTAssertEqual(rows[11].when, ["pickling salt", "canning salt", "crock"], "gap calculators plan, section 2")
        XCTAssertEqual(rows[12].calculators, [CalculatorLinks.Calculator(page: "calc-water-days.html",
                                                                         name: "Days of Stored Water")])
        XCTAssertEqual(rows[12].when, ["tote", "barrel", "cistern", "tank"], "gap calculators plan, section 3")
        XCTAssertEqual(rows[13].calculators, [CalculatorLinks.Calculator(page: "calc-oxygen-absorbers.html",
                                                                         name: "Oxygen Absorbers")])
        XCTAssertEqual(rows[13].when, ["oxygen absorber", "mylar"], "gap calculators plan, section 6")
        XCTAssertEqual(rows[9].calculators, [CalculatorLinks.Calculator(page: "calc-firewood.html",
                                                                        name: "Firewood for a Winter")])
        XCTAssertEqual(rows[9].when, ["firewood", "wood stove", "cord"], "step 8c, section 6")
        XCTAssertEqual(rows[1].calculators, [CalculatorLinks.Calculator(page: "calc-rain.html", name: "Rain Catchment")])
        XCTAssertEqual(rows[1].when, ["rain barrel", "cistern"], "step 8c, section 5")
        XCTAssertEqual(rows[6].calculators, [CalculatorLinks.Calculator(page: "calc-generator.html",
                                                                        name: "Generator Load and Fuel")])
        XCTAssertEqual(rows[6].when, ["generator"], "step 8c, section 2")
        XCTAssertEqual(rows[0].calculators.map(\.name), ["Water for People and Pets", "Chlorine for Drinking Water", "Well Shock"])
        XCTAssertEqual(rows[2].when, ["home canned", "home-canned", "canning jar"])
        XCTAssertEqual(rows[3].calculators, [CalculatorLinks.Calculator(page: "calc-fridge-timer.html",
                                                                        name: "Fridge and Freezer Outage Timer")])
        XCTAssertEqual(rows[3].when, [], "step 8c: always shown")
        XCTAssertEqual(rows[8].calculators, [CalculatorLinks.Calculator(page: "calc-dose-volume.html",
                                                                        name: "mL of a Liquid Medicine")])
    }

    func testRefusesAnyOtherShape() {
        let good = #"{"category":"Water","calculators":[{"page":"calc-a.html","name":"A"}],"when":[]}"#
        for text in [
            #"{"format":2,"rows":[]}"#,
            #"{"format":1,"rows":[],"extra":1}"#,
            #"{"format":1.0,"rows":[]}"#,
            #"{"format":1,"format":1,"rows":[]}"#,
            #"{"format":1,"rows":[{"category":"Kitchen","calculators":[{"page":"calc-a.html","name":"A"}],"when":[]}]}"#,
            #"{"format":1,"rows":[{"category":"Other","calculators":[{"page":"calc-a.html","name":"A"}],"when":[]}]}"#,
            #"{"format":1,"rows":[{"category":"Water","calculators":[],"when":[]}]}"#,
            #"{"format":1,"rows":[{"category":"Water","calculators":[{"page":"a.html","name":"A"}],"when":[]}]}"#,
            #"{"format":1,"rows":[{"category":"Water","calculators":[{"page":"calc-a.html","name":" "}],"when":[]}]}"#,
            #"{"format":1,"rows":[{"category":"Water","calculators":[{"page":"calc-a.html","name":"A"},{"page":"calc-a.html","name":"B"}],"when":[]}]}"#,
            #"{"format":1,"rows":[{"category":"Water","calculators":[{"page":"calc-a.html","name":"A"}],"when":["Jar"]}]}"#,
            #"{"format":1,"rows":[{"category":"Water","calculators":[{"page":"calc-a.html","name":"A"}],"when":["jar","jar"]}]}"#,
            #"{"format":1,"rows":[{"category":"Water","calculators":[{"page":"calc-a.html","name":"A"}]}]}"#,
        ] {
            XCTAssertThrowsError(try CalculatorLinks(Data(text.utf8)), text) { error in
                XCTAssertEqual(error as? CalculatorLinks.Problem, .notTheShape)
            }
        }
        XCTAssertNoThrow(try CalculatorLinks(Data(#"{"format":1,"rows":[\#(good)]}"#.utf8)))
    }

    func testWhichCalculatorsAGroupShows() throws {
        let links = try fixture
        let names = { (group: String, items: [String]) in links.shown(group: group, itemNames: items).map(\.name) }
        XCTAssertEqual(names("Water", []), ["Water for People and Pets", "Chlorine for Drinking Water", "Well Shock"])
        XCTAssertEqual(names(" water ", []), names("Water", []), "a Counts as in any case")
        XCTAssertEqual(names("Water", ["Rain barrels, 55 gal"]),
                       ["Water for People and Pets", "Chlorine for Drinking Water", "Well Shock", "Rain Catchment",
                        "Days of Stored Water"])
        XCTAssertEqual(names("Water", ["IBC totes, 275 gal"]),
                       ["Water for People and Pets", "Chlorine for Drinking Water", "Well Shock", "Days of Stored Water"],
                       "gap calculators plan, section 3")
        XCTAssertEqual(names("Food", ["Zorvex rice"]), ["Fridge and Freezer Outage Timer"],
                       "no home-canned item: the timer alone, always shown")
        XCTAssertEqual(names("Food", ["Home-canned peaches"]),
                       ["Boiling Home-Canned Food", "Fridge and Freezer Outage Timer"])
        XCTAssertEqual(names("Food", ["HOME CANNED beans"]),
                       ["Boiling Home-Canned Food", "Fridge and Freezer Outage Timer"])
        XCTAssertEqual(names("Food", ["Pickling salt, 4 lb", "Stoneware crocks"]),
                       ["Fridge and Freezer Outage Timer", "Salt for Fermenting"], "gap calculators plan, section 2")
        XCTAssertEqual(names("Food", ["Oxygen absorbers, 300cc"]),
                       ["Fridge and Freezer Outage Timer", "Oxygen Absorbers"], "gap calculators plan, section 6")
        XCTAssertEqual(names("Pets", []), ["Pet Food Days", "Water for People and Pets"])
        XCTAssertEqual(names("Power and fuel", ["Quillmark power station"]),
                       ["Outage Loads", "Panel Fit", "Monthly Solar", "Cable Loss"])
        XCTAssertEqual(names("Power and fuel", ["Propane cylinders"]),
                       ["Propane Runtime", "Outage Loads", "Panel Fit", "Monthly Solar", "Cable Loss"])
        XCTAssertEqual(names("Power and fuel", ["Quillmark dual-fuel generator", "Propane cylinders"]),
                       ["Propane Runtime", "Generator Load and Fuel", "Outage Loads", "Panel Fit", "Monthly Solar",
                        "Cable Loss"])
        XCTAssertEqual(names("Medical", []), ["mL of a Liquid Medicine"])
        XCTAssertEqual(names("Heat and shelter", ["Propane heater"]), [])
    }

    /// The same `#` parts packer/tests/test_calculator_links.py and test_inventory_page.py pin for inventory.html.
    func testLinksCarryTheListsJobsFigures() throws {
        let links = try fixture, figures = try figures
        XCTAssertEqual(figures.counted, "2026-10-07T02:37:00-04:00")
        XCTAssertEqual(figures.countedWords, "Oct 7, 2:37 AM")
        let water = links.line(group: "Water", itemNames: [], figures: figures)
        XCTAssertEqual(water.links.map(\.fragment), ["days=30&dog=50&people=4", "", ""])
        XCTAssertEqual(water.notes, ["Filled in from the inventory's count of Oct 7, 2:37 AM."])
        let pets = links.line(group: "Pets", itemNames: [], figures: figures)
        XCTAssertEqual(pets.links.map(\.fragment), ["dday=1.5&dlb=30", "days=30&dog=50&people=4"])
        let medical = links.line(group: "Medical", itemNames: [], figures: figures)
        XCTAssertEqual(medical.links.map(\.fragment), [""], "never filled in")
        XCTAssertEqual(medical.notes, [], "nothing filled, so no count line")
        XCTAssertEqual(links.line(group: "Water", itemNames: [], figures: nil).notes, [], "no figures yet: blank")
        XCTAssertEqual(links.line(group: "Other", itemNames: [], figures: figures).links, [])
    }

    func testThePropaneLine() throws {
        let links = try fixture
        let weigh = CalculatorFigures(counted: "2026-10-20T15:05:00-04:00", pages: [:], propaneWeigh: true)
        let power = links.line(group: "Power and fuel", itemNames: ["Propane cylinders"], figures: weigh)
        XCTAssertEqual(power.links.first?.fragment, "")
        XCTAssertEqual(power.notes, [CalculatorLinks.propanePoundsOnly])
        XCTAssertEqual(links.line(group: "Power and fuel", itemNames: ["Zorvex lantern"], figures: weigh).notes, [],
                       "no Propane Runtime shown, no propane line")
        let pounds = CalculatorFigures(counted: "2026-10-20T15:05:00-04:00", pages: ["calc-propane.html": ["lb": 40]],
                                       propaneWeigh: false)
        let filled = links.line(group: "Power and fuel", itemNames: ["Propane, 20 lb"], figures: pounds)
        XCTAssertEqual(filled.links.first?.fragment, "lb=40")
        XCTAssertEqual(filled.notes, ["Filled in from the inventory's count of Oct 20, 3:05 PM."])
        // The owner's rule (2026-10-20): the pounds fill, and the line shows when a row was left out for its unit
        let both = CalculatorFigures(counted: "2026-10-20T15:05:00-04:00", pages: ["calc-propane.html": ["lb": 40]],
                                     propaneWeigh: true)
        let line = links.line(group: "Power and fuel", itemNames: ["Propane, 20 lb", "Propane generator"], figures: both)
        XCTAssertEqual(line.links.first?.fragment, "lb=40")
        XCTAssertEqual(line.notes, ["Filled in from the inventory's count of Oct 20, 3:05 PM.", CalculatorLinks.propanePoundsOnly])
    }

    /// Step 8c, section 2: the generator's propane and gasoline, and the lines when either couldn't be counted.
    func testTheGeneratorLine() throws {
        let links = try fixture
        let counted = CalculatorFigures(counted: "2026-10-20T15:05:00-04:00",
                                        pages: ["calc-generator.html": ["lb": 40, "gal": 10]], propaneWeigh: false)
        let filled = links.line(group: "Power and fuel", itemNames: ["Quillmark generator"], figures: counted)
        XCTAssertEqual(filled.links.first { $0.calculator.page == "calc-generator.html" }?.fragment, "gal=10&lb=40")
        XCTAssertEqual(filled.notes, ["Filled in from the inventory's count of Oct 20, 3:05 PM."])
        let unread = CalculatorFigures(counted: "2026-10-20T15:05:00-04:00", pages: [:], propaneWeigh: true,
                                       gasolineWeigh: true)
        XCTAssertEqual(links.line(group: "Power and fuel", itemNames: ["Quillmark generator"], figures: unread).notes,
                       [CalculatorLinks.propanePoundsOnly, CalculatorLinks.gasolineGallonsOnly])
        XCTAssertEqual(links.line(group: "Power and fuel", itemNames: ["Zorvex lantern"], figures: unread).notes, [],
                       "no generator or propane shown, no lines")
        let gallons = CalculatorFigures(counted: "2026-10-20T15:05:00-04:00", pages: ["calc-generator.html": ["gal": 10]],
                                        propaneWeigh: false, gasolineWeigh: true)
        let both = links.line(group: "Power and fuel", itemNames: ["Quillmark generator"], figures: gallons)
        XCTAssertEqual(both.links.first { $0.calculator.page == "calc-generator.html" }?.fragment, "gal=10",
                       "the gallons fill though a row was left out")
        XCTAssertEqual(both.notes, ["Filled in from the inventory's count of Oct 20, 3:05 PM.",
                                    CalculatorLinks.gasolineGallonsOnly])
        let before = Data(#"{"counted":"2026-10-20T15:05:00-04:00","pages":{},"propane_weigh":false}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(CalculatorFigures.self, from: before).gasolineWeigh,
                       "a count from before step 8c")
        XCTAssertFalse(try figures.gasolineWeigh, "the shared sample's count, every gas can in gallons")
    }

    /// Step 8c, section 6: Firewood for a Winter under Heat and shelter, filled with the cords on hand, and the line
    /// when a firewood row couldn't be counted.
    func testTheFirewoodLine() throws {
        let links = try fixture
        XCTAssertEqual(links.shown(group: "Heat and shelter", itemNames: ["Quillmark blanket"]), [])
        let counted = CalculatorFigures(counted: "2026-10-20T15:05:00-04:00",
                                        pages: ["calc-firewood.html": ["cords": 2.5]], propaneWeigh: false)
        let filled = links.line(group: "Heat and shelter", itemNames: ["Firewood, oak"], figures: counted)
        XCTAssertEqual(filled.links.map(\.calculator.name), ["Firewood for a Winter"])
        XCTAssertEqual(filled.links.first?.fragment, "cords=2.5")
        XCTAssertEqual(filled.notes, ["Filled in from the inventory's count of Oct 20, 3:05 PM."])
        let left = CalculatorFigures(counted: "2026-10-20T15:05:00-04:00", pages: [:], propaneWeigh: true,
                                     gasolineWeigh: true, firewoodWeigh: true)
        XCTAssertEqual(links.line(group: "Heat and shelter", itemNames: ["Quillmark wood stove"], figures: left).notes,
                       [CalculatorLinks.firewoodCordsOnly], "only the firewood line under Heat and shelter")
        XCTAssertEqual(links.line(group: "Power and fuel", itemNames: ["Quillmark generator"], figures: left).notes,
                       [CalculatorLinks.propanePoundsOnly, CalculatorLinks.gasolineGallonsOnly], "no firewood line there")
        let before = Data(#"{"counted":"2026-10-20T15:05:00-04:00","pages":{},"propane_weigh":false,"gasoline_weigh":true}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(CalculatorFigures.self, from: before).firewoodWeigh,
                       "a count from before section 6")
        XCTAssertFalse(try figures.firewoodWeigh, "the shared sample's count, no firewood")
    }

    func testOnlyNumbersThePagesCouldRead() {
        XCTAssertEqual(CalculatorLinks.fragment(["people": 4, "dog": -1, "cat": .nan, "days": .infinity, "Bad": 1,
                                                 "x_y": 2, "tiny": 1e-7, "lb": 12.5]), "lb=12.5&people=4")
        XCTAssertEqual(CalculatorLinks.numberText(0.1 + 0.2), "0.30000000000000004", "as Python's repr")
        XCTAssertEqual(CalculatorLinks.numberText(1234567.5), "1234567.5")
        XCTAssertEqual(CalculatorLinks.fragment(nil), "")
    }

    func testFiguresOfAnotherShapeNeverCostTheDays() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.fixtures.appendingPathComponent("supply.json"))) as? [String: Any])
        json["calculators"] = ["counted": 3, "pages": "none"]
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent(SupplyShares.fileName))
        let read = try XCTUnwrap(SupplyShares.read(in: folder))
        XCTAssertNil(read.calculators)
        XCTAssertEqual(read.supplies.count, 4)
        json.removeValue(forKey: "calculators")  // a lists job from before step 8b
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent(SupplyShares.fileName))
        XCTAssertNil(try XCTUnwrap(SupplyShares.read(in: folder)).calculators)
        let shares = try XCTUnwrap(SupplyShares.read(in: Self.fixtures))
        XCTAssertEqual(try JSONDecoder().decode(SupplyShares.self, from: JSONEncoder().encode(shares)), shares,
                       "it travels in the phones' copy whole")
    }
}
