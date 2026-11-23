import PrepareMeShared
import XCTest

/// The phone's item form checks at Save what the Mac would refuse (the beta run's F20, F21; plan 2026-10-16, Task
/// 4.1), never more: a value the Mac takes is never refused here.
final class PhoneEditRulesTests: XCTestCase {
    let grab = ["10 min", "1 hour"]

    func testNegativeQuantityIsRefused() {
        XCTAssertEqual(PhoneEditRules.problem(columnLabel: "Quantity", kind: "numeric", typed: "-5"),
                       "Quantity: can't be below zero.")
        XCTAssertEqual(PhoneEditRules.problem(columnLabel: "Calories each", kind: "int", typed: " -1 "),
                       "Calories each: can't be below zero.")
    }

    func testDecimalQuantityIsFine() {
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Quantity", kind: "numeric", typed: "2.5"))
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Quantity", kind: "numeric", typed: "1,045"))
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Quantity", kind: "numeric", typed: "0"))
    }

    func testEmptyFieldsAreFine() {
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Quantity", kind: "numeric", typed: ""))
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Grab", kind: "choice", typed: "", choices: grab))
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Notes", kind: "text", typed: ""))
    }

    func testOtherColumnsTakeWhatTheMacTakes() {
        // only Quantity and Calories each refuse a number below zero (readiness/inventory.py); text is never checked
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Shelf temperature", kind: "numeric", typed: "-5"))
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Notes", kind: "text", typed: "-5"))
    }

    func testAChoiceColumnTakesAnyText() {
        // the inventory's Quantity, Brand, Unit and Year are choice columns the Mac takes any text in (phase 4 check)
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Quantity", kind: "choice", typed: "7", choices: ["1", "2"]))
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Brand", kind: "choice", typed: "Acme", choices: ["Other"]))
        XCTAssertEqual(PhoneEditRules.problem(columnLabel: "Quantity", kind: "choice", typed: "-5", choices: ["1"]),
                       "Quantity: can't be below zero.")
        XCTAssertTrue(PhoneEditRules.isPicked("Grab"))
        XCTAssertTrue(PhoneEditRules.isPicked(" grab "), "headers match as the Mac matches them")
        XCTAssertFalse(PhoneEditRules.isPicked("Quantity"))
    }

    func testAnAmountMustBeANumber() {
        // the lists job reads Quantity and Calories each as numbers (readiness/inventory.py), whatever the column's kind:
        // "-5Lamp" was saved on the phone, to be refused by the Mac later (simulator, phase 4)
        XCTAssertEqual(PhoneEditRules.problem(columnLabel: "Quantity", kind: "choice", typed: "-5Lamp"),
                       "Quantity: write a number, like 6 or 2.5.")
        XCTAssertEqual(PhoneEditRules.problem(columnLabel: "Calories each", kind: "text", typed: "lots"),
                       "Calories each: write a number, like 6 or 2.5.")
        XCTAssertNil(PhoneEditRules.problem(columnLabel: "Quantity", kind: "choice", typed: " 12 "))
    }

    func testNumbersAsTheMacReadsThem() {
        // readiness/sheets.py's _NUMBER: "1,045", "2.5", ".5", "+3"; never "2." or "10,45" (review of phase 4)
        for fine in ["1,045", "2.5", ".5", "+3", "12,345,678.25"] {
            XCTAssertNil(PhoneEditRules.problem(columnLabel: "Quantity", kind: "choice", typed: fine), fine)
        }
        for wrong in ["2.", "10,45", "1,0450", "1 045"] {
            XCTAssertEqual(PhoneEditRules.problem(columnLabel: "Quantity", kind: "choice", typed: wrong),
                           "Quantity: write a number, like 6 or 2.5.", wrong)
        }
    }

    func testAHeaderMatchesInAnyCase() {
        XCTAssertEqual(PhoneEditRules.problem(columnLabel: "quantity", kind: "numeric", typed: "-1"),
                       "quantity: can't be below zero.")
    }

    func testGrabIsNeverRefused() {
        // the Mac reads any case and only notes a stray Grab (inventory/columns.py grab_choice; review of phase 4)
        for typed in ["10 min", "1 hour", "10 MIN", " 1 Hour ", "soon", ""] {
            XCTAssertNil(PhoneEditRules.problem(columnLabel: "Grab", kind: "choice", typed: typed, choices: grab), typed)
        }
    }

    func testGrabShowsItsChoiceInAnyCase() {
        // the Mac takes any text in Grab (review of phase 4): a choice typed in another case shows as the choice, and
        // anything else shows as stored, so opening an item never changes its Grab
        XCTAssertEqual(PhoneEditRules.grabShown("10 MIN", choices: Inventory.grabChoices), "10 min")
        XCTAssertEqual(PhoneEditRules.grabShown(" 1 hour ", choices: Inventory.grabChoices), "1 hour")
        XCTAssertEqual(PhoneEditRules.grabShown("15 min", choices: Inventory.grabChoices), "15 min")
        XCTAssertEqual(PhoneEditRules.grabShown("", choices: Inventory.grabChoices), "")
    }

    func testGrabOffersAStoredValueThatIsNoChoice() {
        XCTAssertEqual(PhoneEditRules.grabOptions(Inventory.grabChoices, current: "15 min"), ["10 min", "1 hour", "15 min"])
        XCTAssertEqual(PhoneEditRules.grabOptions(Inventory.grabChoices, current: "1 hour"), ["10 min", "1 hour"])
        XCTAssertEqual(PhoneEditRules.grabOptions(Inventory.grabChoices, current: ""), ["10 min", "1 hour"])
    }

    func testAStoredDayAsTheMacReadsIt() {
        // a date Grist couldn't read stays as text, and the Mac reads it (readiness/sheets.day); the form shows it
        XCTAssertEqual(PhoneEditRules.storedDay(.int(1_792_108_800)), 1_792_108_800)
        XCTAssertEqual(PhoneEditRules.storedDay(.real(1_792_108_800)), 1_792_108_800)
        XCTAssertEqual(PhoneEditRules.storedDay(.text("2026-10-16")), 1_792_108_800)
        XCTAssertEqual(PhoneEditRules.storedDay(.text("10/16/2026")), 1_792_108_800)
        XCTAssertNil(PhoneEditRules.storedDay(.text("soon")))
        XCTAssertNil(PhoneEditRules.storedDay(.null))
    }

    func testPlainRefusalDropsFileAndRow() {
        XCTAssertEqual(PhoneEditRules.plainRefusal(
            "PrepareMe Inventory.grist: Inventory row 3006, Quantity: can't be below zero"),
            "Quantity: can't be below zero.")
        XCTAssertEqual(PhoneEditRules.plainRefusal("Inventory row 12, Expires: isn't a date"), "Expires: isn't a date.")
    }

    func testPlainRefusalReadsAsASentence() {
        // the Mac's other reasons (review of phase 4): never "Year Year must be…" or "Brand serial numbers aren't kept"
        XCTAssertEqual(PhoneEditRules.plainRefusal(
            "PrepareMe Inventory.grist: Inventory row 3, Year: Year must be a whole number from 1900 to 2100"),
            "Year: must be a whole number from 1900 to 2100.")
        XCTAssertEqual(PhoneEditRules.plainRefusal("Inventory row 3, Model: Model holds only the model number; put "
                                                   + "anything else in Notes"),
                       "Model: holds only the model number; put anything else in Notes.")
        XCTAssertEqual(PhoneEditRules.plainRefusal("Inventory row 3, Brand: a serial number goes in the item's own "
                                                   + "Serial number field, kept on the Mac only"),
                       "Brand: a serial number goes in the item's own Serial number field, kept on the Mac only.")
        XCTAssertEqual(PhoneEditRules.plainRefusal("Inventory row 3, Quantity: shows a formula error; fix the formula "
                                                   + "or clear the cell"),
                       "Quantity: shows a formula error; fix the formula or clear the cell.")
        XCTAssertEqual(PhoneEditRules.plainRefusal("Inventory row 3, across its cells: holds a cash amount"),
                       "This item: holds a cash amount.")
    }

    /// B2-11 (R4.3): every message under a field has one shape, "Field: message", the message in lower case.
    func testEveryProblemReadsFieldColonMessage() {
        for typed in ["-5", "abc"] {
            let why = PhoneEditRules.problem(columnLabel: "Quantity", kind: "numeric", typed: typed)
            XCTAssertTrue(why?.hasPrefix("Quantity: ") == true, why ?? "nil")
            XCTAssertTrue(why.map { $0.dropFirst("Quantity: ".count).first?.isLowercase } == true, why ?? "nil")
        }
        XCTAssertEqual(PhoneEditRules.plainRefusal("Inventory row 3, Year: Year must be a whole number"),
                       "Year: must be a whole number.")
    }

    /// B2-11 (R4.3): a one-line hint under Year, Manual and Unit, whatever the header's case; none elsewhere.
    func testHintsUnderYearManualAndUnit() {
        XCTAssertEqual(PhoneEditRules.hint(columnLabel: "Year"), "The year it was made (helps match recalls).")
        XCTAssertEqual(PhoneEditRules.hint(columnLabel: " manual "),
                       "Not needed: it needs no manual. None exists: the maker never made one. "
                + "A manual's PDF can only be added on the Mac.")
        XCTAssertEqual(PhoneEditRules.hint(columnLabel: "UNIT"),
                       "What one is counted in, like can, bottle or box. Use the same word each time.")
        XCTAssertNil(PhoneEditRules.hint(columnLabel: "Quantity"))
        XCTAssertNil(PhoneEditRules.hint(columnLabel: "Notes"))
    }

    /// B2-11 + R4.1's review (R4.3): the item form stops a nameless item up front, in the form's one style ("Field:
    /// message"; the Mac keeps its own words). Checkpoint 2: an item's name blanked is stopped too, as the Mac's editor
    /// refuses it; an item with no name yet (a barcode add named later) may stay so.
    func testANewItemNeedsAName() {
        XCTAssertEqual(PhoneEditRules.nameProblem(columnLabel: "Item", typed: "  ", was: nil), "Item: give the item a name.")
        XCTAssertEqual(PhoneEditRules.nameProblem(columnLabel: "item", typed: "", was: nil), "item: give the item a name.")
        XCTAssertNil(PhoneEditRules.nameProblem(columnLabel: "Item", typed: "Headlamp", was: nil))
        XCTAssertNil(PhoneEditRules.nameProblem(columnLabel: "Notes", typed: "", was: nil))
        XCTAssertEqual(PhoneEditRules.nameProblem(columnLabel: "Item", typed: " ", was: "Headlamp"),
                       "Item: give the item a name.", "a name blanked")
        XCTAssertNil(PhoneEditRules.nameProblem(columnLabel: "Item", typed: "", was: " "), "no name yet: none blanked")
        XCTAssertNil(PhoneEditRules.nameProblem(columnLabel: "Item", typed: "Head lamp", was: "Headlamp"))
        XCTAssertEqual(PhoneEditRules.noName, "Item: give the item a name.")
        XCTAssertEqual(InventoryWords.noName, "Give the item a name.", "the Mac's own words stay")
        XCTAssertEqual(PhoneEditRules.refusalLine(message: InventoryWords.noName, item: "Headlamp (Bin 29)",
                                                  what: "Headlamp: Item"),
                       "Item: give the item a name.", "the Mac's refusal, in the same style")
        // a place or category the Mac removed (2026-10-23): its words as they are, so Edit again picks another
        XCTAssertEqual(PhoneEditRules.refusalLine(message: InventoryWords.notThere, item: "Headlamp (Bin 29)",
                                                  what: "Headlamp: added"), InventoryWords.notThere)
    }

    /// B2-11 (R4.3): a change the Mac refused for an item that is gone names the item and its place, not a "row".
    func testARemovedItemsRefusalNamesItAndItsPlace() {
        XCTAssertEqual(PhoneEditRules.refusalLine(message: InventoryWords.noRow, item: "Headlamp (Bin 29)",
                                                  what: "Headlamp: used 1"),
                       "Someone removed this Headlamp (Bin 29) on the Mac; your change wasn't kept.")
        // an entry kept before the place was kept falls back on the name in "what"
        XCTAssertEqual(PhoneEditRules.refusalLine(message: InventoryWords.noRow, item: nil, what: "Headlamp: used 1"),
                       "Someone removed this Headlamp on the Mac; your change wasn't kept.")
        // checkpoint 2: a name holding ": " is kept whole (what is "<name>: <what was done>", and what was done never
        // holds one); a line of another shape is shown whole
        XCTAssertEqual(PhoneEditRules.refusalLine(message: InventoryWords.noRow, item: nil,
                                                  what: "Radio: NOAA weather: used 1"),
                       "Someone removed this Radio: NOAA weather on the Mac; your change wasn't kept.")
        XCTAssertEqual(PhoneEditRules.refusalLine(message: InventoryWords.noRow, item: nil,
                                                  what: "Lantern 2: Quantity"),
                       "Someone removed this Lantern 2 on the Mac; your change wasn't kept.")
        XCTAssertEqual(PhoneEditRules.refusalLine(message: InventoryWords.noRow, item: nil, what: "Headlamp"),
                       "Someone removed this Headlamp on the Mac; your change wasn't kept.")
        // any other reason is the Mac's, in plain words as before
        XCTAssertEqual(PhoneEditRules.refusalLine(message: "Inventory row 3, Quantity: can't be below zero",
                                                  item: "Headlamp (Bin 29)", what: "Headlamp: Quantity"),
                       "Quantity: can't be below zero.")
        XCTAssertEqual(InventoryWords.noRow, "That row is no longer there.", "the Mac's own words stay")
    }

    func testPlainRefusalKeepsUnknownReasons() {
        let other = "This column can't be changed here."
        XCTAssertEqual(PhoneEditRules.plainRefusal(other), other)
        XCTAssertEqual(PhoneEditRules.plainRefusal(""), "")
    }

    /// Task 1.4: Unit, Brand and Model are kept as typed on the phone (no capital letter added, no autocorrect), so
    /// "can" stays "can", as the Unit hint asks.
    func testUnitBrandAndModelAreTypedAsIs() {
        XCTAssertEqual(["Unit", "brand", "Model"].map(PhoneEditRules.typedAsIs), [true, true, true])
        XCTAssertEqual(["Item", "Notes"].map(PhoneEditRules.typedAsIs), [false, false])
    }
}
