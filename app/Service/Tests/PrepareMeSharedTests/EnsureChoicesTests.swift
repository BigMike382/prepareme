import Foundation
import PrepareMeShared
import Testing

/// A file whose Holds unit was made before fl oz (2026-10-30): opening it adds fl oz to the list, once, keeping the rest.
struct EnsureChoicesTests {
    @Test func aMissingChoiceJoinsTheList() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-choices-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("PrepareMe Inventory.grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        let file = try InventoryFile(url: url)
        _ = try file.ensureColumn("Inventory", colId: "Holds_unit", label: Inventory.Label.holdsUnit, type: "Choice",
                                  widgetOptions: #"{"choices":["gallons","liters","Barrels"],"alignment":"left"}"#)

        #expect(try file.ensureChoices("Inventory", label: Inventory.Label.holdsUnit, Inventory.Label.holdsUnits))
        let column = try #require(try file.table("Inventory").column(Inventory.Label.holdsUnit))
        #expect(column.choices == ["gallons", "liters", "Barrels", "fl oz", "pounds", "cords", "watt-hours"])
        #expect(try !file.ensureChoices("Inventory", label: Inventory.Label.holdsUnit, Inventory.Label.holdsUnits),
                "nothing left to add")
        #expect(try !file.ensureChoices("Inventory", label: "Item", ["fl oz"]), "never a column that isn't a Choice")
    }

    /// Unit gains bottles, bags, jars and fl oz at open (spec 5.4), after the file's own, once; nothing taken out.
    @Test func unitGainsItsFourAfterItsOwn() throws {
        let (file, base) = try Self.copy()
        defer { try? FileManager.default.removeItem(at: base) }
        let own = try #require(try file.table("Inventory").column("Unit")).choices
        #expect(!own.isEmpty && !own.contains("bottles"))

        #expect(try file.ensureChoices("Inventory", label: "Unit", Inventory.Label.unitAdds))
        #expect(try file.table("Inventory").column("Unit")?.choices == own + ["bottles", "bags", "jars", "fl oz"])
        #expect(try !file.ensureChoices("Inventory", label: "Unit", Inventory.Label.unitAdds), "once")
    }

    @Test func aUnitListWithBottlesGainsThree() throws {
        let (file, base) = try Self.copy()
        defer { try? FileManager.default.removeItem(at: base) }
        let own = try #require(try file.table("Inventory").column("Unit")).choices
        _ = try file.ensureChoices("Inventory", label: "Unit", ["Bottles"])  // the owner's own spelling, kept

        #expect(try file.ensureChoices("Inventory", label: "Unit", Inventory.Label.unitAdds))
        #expect(try file.table("Inventory").column("Unit")?.choices == own + ["Bottles", "bags", "jars", "fl oz"])
    }

    private static func copy() throws -> (InventoryFile, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-choices-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("PrepareMe Inventory.grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        return (try InventoryFile(url: url), base)
    }
}
