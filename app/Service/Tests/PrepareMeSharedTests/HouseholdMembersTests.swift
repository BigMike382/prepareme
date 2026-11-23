import Foundation
@testable import PrepareMeShared
import XCTest

/// The household members in the inventory's Settings (step 8a; owner, 2026-10-19, by click): the menus the lists job's
/// needs table reads (Resources/household-needs.json, shipped in PrepareMeShared and written by
/// readiness/tests/test_needs.py), kept in the file's own PrepareMe_Members table through the editor, and read back by
/// the lists job. Made-up rehearsal copies only.
@MainActor
final class HouseholdMembersTests: XCTestCase {
    var base: URL!
    var editor: InventoryEditor!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-members-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: FakeCheck())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    let three = [HouseholdMember(age: "36-40 years", sex: "Female", activity: "Moderately active"),
                 HouseholdMember(age: "41-45 years", sex: "Male", activity: "Sedentary"),
                 HouseholdMember(age: "18 months", sex: "Male", activity: "")]

    /// Beta run 2, B2-17: the three level definitions sit in a fold, not under People every time.
    func testTheLevelsAreInAFold() {
        XCTAssertEqual(HouseholdMembers.levelsFold, "What the levels mean")
    }

    func testTheMenusAreTheListsJobsOwn() throws {
        let url = try XCTUnwrap(HouseholdMembers.sampleURL, "shipped in PrepareMeShared, read at run time")
        let sample = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(sample["ages"] as? [String], HouseholdMembers.ages)
        XCTAssertEqual(sample["toddler_ages"] as? [String], HouseholdMembers.toddlerAges)
        XCTAssertEqual(sample["sexes"] as? [String], HouseholdMembers.sexes)
        XCTAssertEqual(sample["activities"] as? [String], HouseholdMembers.activities)
        XCTAssertEqual(sample["activity_means"] as? [String: String], HouseholdMembers.activityMeans)
        XCTAssertEqual(sample["table"] as? String, InventoryFile.membersTable)
        XCTAssertEqual(sample["edition"] as? String, HouseholdMembers.edition)
    }

    /// The People line's calories (phase L, choice 4): each member's figure is the lists job's own, read from the
    /// shipped sample at run time (readiness/tests/test_needs.py pins it to readiness/needs.py), never a copy here.
    func testEachMembersCaloriesAreTheListsJobs() {
        XCTAssertEqual(HouseholdMembers.calories(three[0]), 2000)
        XCTAssertEqual(HouseholdMembers.calories(three[1]), 2200)
        XCTAssertEqual(HouseholdMembers.calories(three[2]), 1000, "a toddler's by sex alone")
        XCTAssertEqual(HouseholdMembers.calories(HouseholdMember(age: "18 months", sex: "Female", activity: "Active")),
                       900, "a toddler's activity isn't read")
        XCTAssertEqual(HouseholdMembers.calories(HouseholdMember(age: "76 years and up", sex: "Male",
                                                                 activity: "Active")), 2400)
        XCTAssertNil(HouseholdMembers.calories(HouseholdMember(age: "40 years", sex: "Female", activity: "Active")))
        XCTAssertNil(HouseholdMembers.calories(HouseholdMember(age: "36-40 years", sex: "Female", activity: "")))
        XCTAssertEqual(4 * 2 + 30 * 2 * 3,
                       HouseholdMembers.ages.flatMap { age in HouseholdMembers.sexes.flatMap { sex in
                           (HouseholdMembers.isToddler(age) ? [""] : HouseholdMembers.activities).map {
                               HouseholdMembers.calories(HouseholdMember(age: age, sex: sex, activity: $0))
                           } } }.compactMap { $0 }.count, "every row of both tables has its figure")
    }

    func testTheWords() {
        XCTAssertEqual(HouseholdMembers.title, "Household members")
        XCTAssertEqual(HouseholdMembers.source, "Calories a day from the Dietary Guidelines for Americans, 2020-2025 "
                       + "(Tables A2-1 and A2-2). Babies under 12 months, pregnancy and breastfeeding aren't in "
                       + "those tables.")
        XCTAssertEqual(HouseholdMembers.add, "Add a person")
        XCTAssertEqual(HouseholdMembers.remove, "Remove")
        XCTAssertEqual(HouseholdMembers.noActivity, "Not used under 2")
        XCTAssertEqual([HouseholdMembers.age, HouseholdMembers.sex, HouseholdMembers.activity],
                       ["Age", "Sex", "Activity"])
        XCTAssertEqual(HouseholdMembers.notAChoice, "That isn't one of the table's choices.")
        XCTAssertEqual(HouseholdMembers.tooMany, "Up to 30 household members can be listed.")
    }

    func testAMemberIsOneOfTheTablesRows() {
        XCTAssertNil(HouseholdMembers.problem(three[0]))
        XCTAssertNil(HouseholdMembers.problem(three[2]), "a toddler needs no activity level")
        XCTAssertNil(HouseholdMembers.problem(HouseholdMember(age: "12 months", sex: "Female", activity: "Active")))
        for bad in [HouseholdMember(age: "40 years", sex: "Female", activity: "Active"),
                    HouseholdMember(age: "2 years", sex: "female", activity: "Active"),
                    HouseholdMember(age: "2 years", sex: "Female", activity: "")] {
            XCTAssertEqual(HouseholdMembers.problem(bad), HouseholdMembers.notAChoice)
        }
        XCTAssertTrue(HouseholdMembers.isToddler("21 through 23 months"))
        XCTAssertFalse(HouseholdMembers.isToddler("2 years"))
    }

    /// A menu change keeps the other two sensible: a toddler's activity is cleared, an older age gets one back.
    func testAChangedAgeKeepsTheActivitySensible() {
        let toddler = HouseholdMembers.normalized(HouseholdMember(age: "15 months", sex: "Male", activity: "Active"))
        XCTAssertEqual(toddler.activity, "")
        let grown = HouseholdMembers.normalized(HouseholdMember(age: "3 years", sex: "Male", activity: ""))
        XCTAssertEqual(grown.activity, "Moderately active")
        XCTAssertEqual(HouseholdMembers.normalized(three[1]), three[1])
        XCTAssertNil(HouseholdMembers.problem(HouseholdMembers.blank))
    }

    func testMembersAreKeptInOrderAndUndone() async throws {
        XCTAssertEqual(editor.inventory.members, [], "no table yet: no members")
        guard case .done(let undo, _) = try await editor.apply(.setMembers(three, expected: [])) else {
            return XCTFail("the members weren't kept")
        }
        XCTAssertEqual(editor.inventory.members, three)
        XCTAssertEqual(try editor.file.members(), three)
        let two = Array(three.prefix(2))
        guard case .done = try await editor.apply(.setMembers(two, expected: three)) else { return XCTFail("not kept") }
        XCTAssertEqual(editor.inventory.members, two)
        let stale = try await editor.apply(undo)  // the first change's undo: the list has changed since
        XCTAssertEqual(stale, .refused(InventoryWords.changedSince))
        guard case .done = try await editor.apply(.setMembers([], expected: two)) else { return XCTFail("not kept") }
        XCTAssertEqual(editor.inventory.members, [])
    }

    func testOnlyTheTablesChoicesAndNoPhoneAreKept() async throws {
        let bad = [HouseholdMember(age: "2 years", sex: "Female", activity: "")]
        let refused = try await editor.apply(.setMembers(bad, expected: []))
        XCTAssertEqual(refused, .refused(HouseholdMembers.notAChoice))
        let many = Array(repeating: three[0], count: HouseholdMembers.most + 1)
        let full = try await editor.apply(.setMembers(many, expected: []))
        XCTAssertEqual(full, .refused(HouseholdMembers.tooMany))
        XCTAssertNotNil(PhoneRules.refusal(.setMembers(three, expected: []), editor.inventory),
                        "the members are the Mac's")
        XCTAssertEqual(editor.inventory.members, [])
    }

    /// Step 8a review: a members table of another shape never stops the inventory (nor the phones' copy) from
    /// opening; the panel says so, and the list can't be changed until it's fixed.
    func testATableOfAnotherShapeIsUnreadableNotFatal() async throws {
        try editor.file.db.execute("CREATE TABLE \"\(InventoryFile.membersTable)\" (id INTEGER PRIMARY KEY, age TEXT)")
        try editor.reload()
        XCTAssertEqual(editor.inventory.members, [])
        XCTAssertTrue(editor.inventory.membersUnreadable)
        XCTAssertFalse(editor.inventory.itemRows.isEmpty, "the inventory still opens")
        let refused = try await editor.apply(.setMembers(three, expected: []))
        XCTAssertEqual(refused, .refused(HouseholdMembers.unreadable))
        XCTAssertEqual(HouseholdMembers.unreadable, "The household members in the inventory file can't be read, so "
                       + "they can't be changed here, and days of food and water aren't counted until that's fixed.")
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertFalse(copy.items.isEmpty)
    }

    /// The lists job reads what the Mac keeps (readiness.members), member for member.
    func testTheListsJobReadsTheMembers() async throws {
        guard let python = PythonTextCheck.venvPython(), FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("no venv")
        }
        guard case .done = try await editor.apply(.setMembers(three, expected: [])) else { return XCTFail("not kept") }
        let script = """
            import sqlite3, sys
            sys.path.insert(0, sys.argv[1])
            from readiness import members
            found, bad = members.read_members(sqlite3.connect(sys.argv[2]))
            print(bad, sum(member.need for member in found), "|".join(m.age + "/" + m.sex for m in found))
            """
        let (status, output) = try await PythonTextCheck.run(python, ["-I", "-B", "-c", script,
                                                                      InventoryTests.repo.path,
                                                                      editor.file.url.path], Data())
        XCTAssertEqual(status, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self),
                       "0 5200 36-40 years/Female|41-45 years/Male|18 months/Male\n")
    }
}
