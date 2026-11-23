import Foundation
@testable import PrepareMeShared
import XCTest

/// The pets in the inventory's Settings (settings redesign; owner, 2026-10-19, by click): each dog or cat with its name,
/// kind and weight, kept in the file's own PrepareMe_Pets table through the editor, carried in the phones' copy, and
/// read back by the lists job for days of water. Made-up rehearsal copies only.
@MainActor
final class HouseholdPetsTests: XCTestCase {
    var base: URL!
    var editor: InventoryEditor!
    var checker: FakeCheck!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-pets-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        checker = FakeCheck()
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: checker)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    let three = [HouseholdPet(name: "Biscuit", kind: "Dog", weight: 52),
                 HouseholdPet(name: "Pepper", kind: "Dog", weight: 49.5),
                 HouseholdPet(name: "Mittens", kind: "Cat", weight: nil)]

    func testTheWords() {
        XCTAssertEqual(HouseholdPets.kinds, ["Dog", "Cat"])
        XCTAssertEqual(HouseholdPets.title, "Pets")
        XCTAssertEqual(HouseholdPets.add, "Add a pet")
        XCTAssertEqual(HouseholdPets.remove, "Remove")
        XCTAssertEqual(HouseholdPets.noName, "Give the pet a name.")
        XCTAssertEqual(HouseholdPets.longName, "Keep a pet's name to 40 characters.")
        XCTAssertEqual(HouseholdPets.notAKind, "A pet is a Dog or a Cat.")
        XCTAssertEqual(HouseholdPets.badWeight, "A pet's weight is blank, or from 0 to 300 lb.")
        XCTAssertEqual(HouseholdPets.tooMany, "Up to 30 pets can be listed.")
        XCTAssertEqual(HouseholdPets.unreadable, "The pets in the inventory file can't be read, so they can't be "
                       + "changed here, and days of water aren't counted until that's fixed.")
        XCTAssertEqual(InventoryFile.petsTable, "PrepareMe_Pets")
    }

    /// A name of 1 to 40 characters, Dog or Cat, and a weight blank or from 0 to 300 lb.
    func testAPetsChecks() {
        for good in three + [HouseholdPet(name: String(repeating: "a", count: 40), kind: "Cat", weight: 0),
                             HouseholdPet(name: "Rex", kind: "Dog", weight: 300)] {
            XCTAssertNil(HouseholdPets.problem(good), good.name)
        }
        XCTAssertEqual(HouseholdPets.problem(HouseholdPet(name: "  ", kind: "Dog", weight: 10)), HouseholdPets.noName)
        XCTAssertEqual(HouseholdPets.problem(HouseholdPet(name: String(repeating: "a", count: 41), kind: "Dog",
                                                          weight: 10)), HouseholdPets.longName)
        for kind in ["dog", "Hamster", ""] {
            XCTAssertEqual(HouseholdPets.problem(HouseholdPet(name: "Rex", kind: kind, weight: 10)),
                           HouseholdPets.notAKind)
        }
        for weight in [-1, 300.5, .infinity, .nan] {
            XCTAssertEqual(HouseholdPets.problem(HouseholdPet(name: "Rex", kind: "Dog", weight: weight)),
                           HouseholdPets.badWeight)
        }
        XCTAssertEqual(HouseholdPets.normalized(HouseholdPet(name: " Rex ", kind: "Dog", weight: 1)).name, "Rex")
        XCTAssertEqual(HouseholdPets.blank(after: []).name, "Pet 1")
        XCTAssertEqual(HouseholdPets.blank(after: [HouseholdPet(name: "Pet 2", kind: "Dog", weight: nil)]).name, "Pet 3")
        XCTAssertNil(HouseholdPets.problem(HouseholdPets.blank(after: three)))
    }

    func testPetsAreKeptInOrderAndUndone() async throws {
        XCTAssertEqual(editor.inventory.pets, [], "no table yet: no pets")
        XCTAssertEqual(try editor.file.pets(), [])
        guard case .done(let undo, _) = try await editor.apply(.setPets(three, expected: [])) else {
            return XCTFail("the pets weren't kept")
        }
        XCTAssertEqual(editor.inventory.pets, three)
        XCTAssertEqual(try editor.file.pets(), three, "the blank weight stays blank")
        XCTAssertEqual(checker.asked.flatMap(\.cells).map(\.text), ["Biscuit", "Pepper", "Mittens"],
                       "each name goes through the ID check, since the names reach the phones")
        let two = Array(three.prefix(2))
        guard case .done = try await editor.apply(.setPets(two, expected: three)) else { return XCTFail("not kept") }
        XCTAssertEqual(editor.inventory.pets, two)
        let stale = try await editor.apply(undo)  // the first change's undo: the list has changed since
        XCTAssertEqual(stale, .refused(InventoryWords.changedSince))
        guard case .done(let back, _) = try await editor.apply(.setPets([], expected: two)) else {
            return XCTFail("not kept")
        }
        XCTAssertEqual(editor.inventory.pets, [])
        guard case .done = try await editor.apply(back) else { return XCTFail("the undo wasn't kept") }
        XCTAssertEqual(editor.inventory.pets, two, "Edit › Undo puts the list back")
    }

    func testOnlyAPetThatPassesItsChecksIsKeptAndNeverFromAPhone() async throws {
        for (bad, why) in [(HouseholdPet(name: "", kind: "Dog", weight: 1), HouseholdPets.noName),
                           (HouseholdPet(name: "Rex", kind: "Ferret", weight: 1), HouseholdPets.notAKind),
                           (HouseholdPet(name: "Rex", kind: "Dog", weight: 301), HouseholdPets.badWeight)] {
            let refused = try await editor.apply(.setPets([three[0], bad], expected: []))
            XCTAssertEqual(refused, .refused(why))
        }
        let many = Array(repeating: three[0], count: HouseholdPets.most + 1)
        let full = try await editor.apply(.setPets(many, expected: []))
        XCTAssertEqual(full, .refused(HouseholdPets.tooMany))
        let flagged = try await editor.apply(.setPets([HouseholdPet(name: "REFUSE", kind: "Dog", weight: 1)],
                                                      expected: []))
        guard case .refused = flagged else { return XCTFail("the ID check's refusal wasn't kept") }
        XCTAssertNotNil(PhoneRules.refusal(.setPets(three, expected: []), editor.inventory), "the pets are the Mac's")
        XCTAssertEqual(editor.inventory.pets, [])
    }

    /// A pets table of another shape never stops the inventory (nor the phones' copy) from opening; the list shows as
    /// none, and can't be changed until it's fixed.
    func testATableOfAnotherShapeIsUnreadableNotFatal() async throws {
        try editor.file.db.execute("CREATE TABLE \"\(InventoryFile.petsTable)\" (id INTEGER PRIMARY KEY, name TEXT)")
        try editor.reload()
        XCTAssertEqual(editor.inventory.pets, [])
        XCTAssertTrue(editor.inventory.petsUnreadable)
        XCTAssertFalse(editor.inventory.itemRows.isEmpty, "the inventory still opens")
        let refused = try await editor.apply(.setPets(three, expected: []))
        XCTAssertEqual(refused, .refused(HouseholdPets.unreadable))
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertFalse(copy.items.isEmpty)
        XCTAssertNil(copy.pets, "no pets claimed when they can't be read")
    }

    func testAWeightThatIsntANumberIsUnreadable() throws {
        try editor.file.db.execute("""
            CREATE TABLE "\(InventoryFile.petsTable)" (id INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, \
            weight REAL)
            """)
        try editor.file.db.execute("INSERT INTO \"\(InventoryFile.petsTable)\" (name, kind, weight) VALUES "
                                   + "('Rex', 'Dog', 'heavy')")
        try editor.reload()
        XCTAssertTrue(editor.inventory.petsUnreadable)
    }

    /// A row the lists job wouldn't read (readiness/pets.py): a kind not exactly Dog or Cat, or a blank name (review,
    /// 2026-10-19).
    func testARowTheListsJobWouldntReadIsUnreadable() throws {
        for (name, kind) in [("Rex", "dog"), (" ", "Cat")] {
            try editor.file.db.execute("DROP TABLE IF EXISTS \"\(InventoryFile.petsTable)\"")
            try editor.file.db.execute("""
                CREATE TABLE "\(InventoryFile.petsTable)" (id INTEGER PRIMARY KEY, name TEXT NOT NULL, \
                kind TEXT NOT NULL, weight REAL)
                """)
            try editor.file.db.execute("INSERT INTO \"\(InventoryFile.petsTable)\" (name, kind, weight) VALUES (?, ?, 5)",
                                       [.text(name), .text(kind)])
            try editor.reload()
            XCTAssertTrue(editor.inventory.petsUnreadable, "\(name) \(kind)")
        }
    }

    /// The phones' copy carries each pet's name, kind and weight (for step 8b's calculators); nothing else is added,
    /// and an older copy without pets still reads.
    func testThePhonesCopyCarriesThePets() async throws {
        guard case .done = try await editor.apply(.setPets(three, expected: [])) else { return XCTFail("not kept") }
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertEqual(copy.pets, three)
        try copy.write(in: base)
        let read = try XCTUnwrap(PhoneInventory.read(in: base))
        XCTAssertEqual(read.pets, three)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: base.appendingPathComponent(PhoneInventory.fileName))) as? [String: Any])
        let pets = try XCTUnwrap(json["pets"] as? [[String: Any]])
        XCTAssertEqual(Set(pets[0].keys), ["name", "kind", "weight"])
        XCTAssertEqual(Set(pets[2].keys), ["name", "kind"], "a blank weight is left out, read back as blank")
        // a phone's own view of the copy, with its waiting changes, keeps them
        XCTAssertEqual(PhoneOutbox().view(read).pets, three)
        // an older copy, written before pets, still reads
        var older = json
        older.removeValue(forKey: "pets")
        let data = try JSONSerialization.data(withJSONObject: older)
        XCTAssertNil(try JSONDecoder().decode(PhoneInventory.self, from: data).pets)
    }

    /// The lists job reads what the Mac keeps (readiness.pets), pet for pet.
    func testTheListsJobReadsThePets() async throws {
        guard let python = PythonTextCheck.venvPython(), FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("no venv")
        }
        guard case .done = try await editor.apply(.setPets(three, expected: [])) else { return XCTFail("not kept") }
        let script = """
            import sqlite3, sys
            sys.path.insert(0, sys.argv[1])
            from readiness import pets
            found, bad = pets.read_pets(sqlite3.connect(sys.argv[2]))
            print(bad, "|".join(f"{p.name}/{p.kind}/{p.weight}" for p in found))
            """
        let (status, output) = try await PythonTextCheck.run(python, ["-I", "-B", "-c", script,
                                                                      InventoryTests.repo.path,
                                                                      editor.file.url.path], Data())
        XCTAssertEqual(status, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "0 Biscuit/Dog/52.0|Pepper/Dog/49.5|Mittens/Cat/None\n")
    }
}
