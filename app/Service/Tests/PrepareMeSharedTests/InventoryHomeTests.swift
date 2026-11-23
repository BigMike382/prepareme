import XCTest
@testable import PrepareMeShared

/// The calmer Inventory home (beta run 2 fix plan, Task R9.2; mockup 2): one status line (the copy's source at the foot), the supplies as numbers with
/// their goal in words, Add as one labeled button.
final class InventoryHomeTests: XCTestCase {
    func testTheFootLineSaysWhereTheCopyCameFromAndWhen() {
        let line = InventoryHome.footerLine(written: "Oct 21, 2026 at 6:39 PM", fromBackup: false, canEdit: true,
                                            paired: true, device: "phone")
        XCTAssertEqual(line, "From the Mac, Oct 21, 2026 at 6:39 PM.")
        XCTAssertFalse(line.contains("\n"))
    }

    /// The owner, 2026-10-21: "From the home Mac" belongs at the bottom; the top keeps only the reminders' words, over
    /// their button.
    func testRemindersStayAtTheTopAndTheSourceLeavesIt() {
        for offer in [LocationAsk.Offer.ask, .settings] {
            XCTAssertEqual(InventoryHome.statusLine(reminders: offer), "Reminders are off.")
        }
        XCTAssertEqual(InventoryHome.statusLine(reminders: .none), "")
        XCTAssertFalse(InventoryHome.statusLine(reminders: .ask).contains("Mac"))
        XCTAssertFalse(InventoryHome.footerLine(written: "6:39 PM", fromBackup: false, canEdit: true, paired: true,
                                                device: "phone").contains("Reminders"))
    }

    func testQuickAddSaysHowManyWereNotSaved() {
        XCTAssertEqual(InventoryHome.notSaved(1), "1 not saved")
        XCTAssertEqual(InventoryHome.notSaved(3), "3 not saved")
        XCTAssertEqual(InventoryHome.notSavedHint, "Goes back to Inventory, which lists them.")
    }

    func testAChildsPhoneFoldsItsReadOnlyLineIntoTheFoot() {
        let line = InventoryHome.footerLine(written: "6:39 PM", fromBackup: false, canEdit: false, paired: true,
                                            device: "phone")
        XCTAssertEqual(line, "From the Mac, 6:39 PM. " + HomeMacWords.readOnlyInventory)
    }

    func testABackupCopyKeepsItsWordsAndItsReadOnlyLine() {
        let line = InventoryHome.footerLine(written: "6:39 PM", fromBackup: true, canEdit: false, paired: false,
                                            device: "iPad")
        XCTAssertEqual(line, HomeMacWords.backupCopyWritten("6:39 PM") + " "
                       + HomeMacWords.backupCopyReadOnly(device: "iPad", paired: false))
        XCTAssertFalse(line.contains(HomeMacWords.readOnlyInventory), "one read-only sentence, not two")
    }

    func testNoDateNoMacSentence() {
        XCTAssertEqual(InventoryHome.footerLine(written: nil, fromBackup: false, canEdit: true, paired: true,
                                                device: "phone"), "")
        XCTAssertEqual(InventoryHome.footerLine(written: nil, fromBackup: false, canEdit: false, paired: true,
                                                device: "phone"), HomeMacWords.readOnlyInventory)
    }

    func testSupplyNumbersWithTheGoalInWords() {
        XCTAssertEqual(InventoryHome.chip(kind: "water", days: 7, target: 30),
                       InventoryHome.Chip(number: "7", label: "days of water (goal 30)", low: true))
        XCTAssertEqual(InventoryHome.chip(kind: "dog food", days: 20, target: nil),
                       InventoryHome.Chip(number: "20", label: "days of dog food", low: false))
        XCTAssertEqual(InventoryHome.chip(kind: "food", days: 90, target: 90).low, false, "at the goal is not short")
        XCTAssertEqual(InventoryHome.chip(kind: "food", days: nil, target: 90),
                       InventoryHome.Chip(number: "–", label: "days of food, not counted (goal 90)", low: false))
    }

    func testALowChipSpeaksShortOfGoal() {
        XCTAssertEqual(InventoryHome.chip(kind: "water", days: 7, target: 30).spoken,
                       "7 days of water (goal 30), short of goal")
        XCTAssertEqual(InventoryHome.chip(kind: "dog food", days: 20, target: nil).spoken, "20 days of dog food")
    }

    /// Today's boxes on the phone (owner, 2026-11-14, by click): Water and Food each kept with a dash while not
    /// counted, "+N if filled" in the Water box only, and a pet's half for a counted pet food or a kind Settings lists.
    func testTheSuppliesAsTodayShowsThem() throws {
        let json = #"""
            [{"kind": "water", "unit": "gallons", "per_day": 2, "days": 12.4, "target": 30, "rows": [], "other": [],
              "fillable": 13.8, "fillable_days": 6.9},
             {"kind": "food", "unit": "calories", "per_day": null, "days": null, "target": 90, "rows": [], "other": []},
             {"kind": "dog food", "unit": "pounds", "per_day": 1.5, "days": 20, "target": 90, "rows": [], "other": []},
             {"kind": "cat food", "unit": "pounds", "per_day": null, "days": null, "target": null, "rows": [],
              "other": []}]
            """#
        let kinds = try JSONDecoder().decode([SupplyShares.Kind].self, from: Data(json.utf8))
        XCTAssertEqual(InventoryHome.mainKinds(kinds).map(\.kind), ["water", "food"])
        XCTAssertEqual(InventoryHome.mainKinds(Array(kinds.reversed())).map(\.kind), ["water", "food"])
        XCTAssertEqual(InventoryHome.fillShort(kinds[0]), "+6 if filled")
        XCTAssertNil(InventoryHome.fillShort(kinds[1]))
        XCTAssertEqual(InventoryHome.petKinds(kinds, pets: nil).map(\.kind), ["dog food"])
        let cat = HouseholdPet(name: "Made-up", kind: "Cat", weight: nil)
        XCTAssertEqual(InventoryHome.petKinds(kinds, pets: [cat]).map(\.kind), ["cat food", "dog food"], "cats first")
        XCTAssertEqual(InventoryHome.petKinds(kinds, pets: [cat]).map(InventoryHome.petName), ["Cat", "Dog"])
        XCTAssertEqual(InventoryHome.petKinds([kinds[0]], pets: [cat]), [], "no pet food supply, no box")
        XCTAssertEqual(InventoryHome.half(days: 20, target: 90),
                       InventoryHome.Chip(number: "20", label: "days (goal 90)", low: true))
        XCTAssertEqual(InventoryHome.half(days: nil, target: nil),
                       InventoryHome.Chip(number: "–", label: "not counted", low: false))
    }

    func testTheButtonsAndTheCalculatorsWay() {
        XCTAssertEqual(InventoryHome.addLabel, "Add")
        XCTAssertEqual(InventoryHome.calculatorsLink, "Calculators for each supply")
    }
}
