import XCTest
@testable import PrepareMeShared

/// The inventory's look (owner, 2026-10-25): names shown in title case, each category's emoji and the Mac's symbol.
final class InventoryLookTests: XCTestCase {
    func testTitleCaseCapitalizesEveryWordButTheSmallOnes() {
        XCTAssertEqual(InventoryLook.title("hygiene and sanitation"), "Hygiene and Sanitation")
        XCTAssertEqual(InventoryLook.title("pet supplies"), "Pet Supplies")
        XCTAssertEqual(InventoryLook.title("Tuna in water"), "Tuna in Water")
        XCTAssertEqual(InventoryLook.title("bags for the car"), "Bags for the Car")
        XCTAssertEqual(InventoryLook.title("Grab in an hour"), "Grab in an Hour")
    }

    func testTheFirstWordIsAlwaysCapitalized() {
        XCTAssertEqual(InventoryLook.title("the big tent"), "The Big Tent")
        XCTAssertEqual(InventoryLook.title("  and more"), "  And More")  // spacing kept as typed
    }

    func testASmallWordTypedWithACapitalIsShownLowerCase() {
        XCTAssertEqual(InventoryLook.title("Water And Food"), "Water and Food")
    }

    /// A one-letter word typed as a capital keeps it, as a shelf's or a bin's letter (the owner's choice C, 2026-11-18:
    /// "Shelf A", not "Shelf a"); typed lower case, the small word "a" stays lower case.
    func testAOneLetterWordTypedAsACapitalKeepsIt() {
        XCTAssertEqual(InventoryLook.title("Shelf A"), "Shelf A")
        XCTAssertEqual(InventoryLook.title("bin A"), "Bin A")
        XCTAssertEqual(InventoryLook.title("Row A, shelf B"), "Row A, Shelf B")
        XCTAssertEqual(InventoryLook.title("grab in a minute"), "Grab in a Minute")
        XCTAssertEqual(InventoryLook.title("shelf b"), "Shelf B", "not a small word: capitalized as before")
        XCTAssertEqual(InventoryLook.title("a tent"), "A Tent")
    }

    func testWordsTypedWithCapitalsInsideAreLeftAsTyped() {
        XCTAssertEqual(InventoryLook.title("iPhone charger"), "iPhone Charger")
        XCTAssertEqual(InventoryLook.title("AA batteries"), "AA Batteries")
        XCTAssertEqual(InventoryLook.title("spare OR kit"), "Spare OR Kit")  // all capitals: not the small word
        XCTAssertEqual(InventoryLook.title("McDonald's coupons"), "McDonald's Coupons")
    }

    func testHyphensPathsNumbersAndApostrophes() {
        XCTAssertEqual(InventoryLook.title("Grab-and-go checklist"), "Grab-and-Go Checklist")
        XCTAssertEqual(InventoryLook.title("garage › shelf 2"), "Garage › Shelf 2")
        XCTAssertEqual(InventoryLook.title("kid's 2nd bag (spare)"), "Kid's 2nd Bag (Spare)")
        XCTAssertEqual(InventoryLook.title("To do (4)"), "To Do (4)")
        XCTAssertEqual(InventoryLook.title("café crème"), "Café Crème")
        XCTAssertEqual(InventoryLook.title(""), "")
    }

    func testEachCategoryHasItsEmojiByNameIgnoringCaseAndSpaces() {
        XCTAssertEqual(InventoryLook.emoji(category: "Water", group: "Water"), "💧")
        XCTAssertEqual(InventoryLook.emoji(category: " first AID ", group: "Medical"), "🩹")
        XCTAssertEqual(InventoryLook.emoji(category: "Pet supplies", group: "Pets"), "🐕")
        XCTAssertEqual(InventoryLook.emoji(category: "Firearms and ammunition", group: "Security"), "🎯")
    }

    func testANewCategoryTakesItsGroupsEmojiElseTheTag() {
        XCTAssertEqual(InventoryLook.emoji(category: "Bandages", group: "Medical"), "⛑️")
        XCTAssertEqual(InventoryLook.emoji(category: "Tarps", group: "heat and shelter"), "⛺")
        XCTAssertEqual(InventoryLook.emoji(category: "Odds", group: nil), "🏷️")
        XCTAssertEqual(InventoryLook.emoji(category: "Odds", group: "Not a group"), "🏷️")
    }

    func testEveryNameAndGroupHasAnEmoji() {
        // the inventory's fourteen names and the lists' twelve groups (readiness/model.py), and Other
        let names = ["Water", "Food", "Medicine", "First aid", "Power and batteries", "Fuel", "Hygiene and sanitation",
                     "Tools", "Gear", "Materials", "Communications", "Pet supplies", "Firearms and ammunition",
                     "Vehicles"]
        let groups = ["Water", "Food", "Medical", "Power and fuel", "Heat and shelter", "Tools and equipment",
                      "Communications", "Pets", "Documents and plans", "Security", "Vehicles and RV",
                      "Skills and training", "Other"]
        for name in names {
            XCTAssertNotNil(InventoryLook.nameEmoji[name.lowercased()], name)
        }
        for group in groups {
            XCTAssertNotNil(InventoryLook.groupEmoji[group.lowercased()], group)
        }
    }

    func testAVehiclesEmojiComesFromAWordInItsName() {  // owner, 2026-10-26, by click
        XCTAssertEqual(InventoryLook.vehicleEmoji("Mike's Truck"), "🛻")
        XCTAssertEqual(InventoryLook.vehicleEmoji("the PICKUP"), "🛻")
        XCTAssertEqual(InventoryLook.vehicleEmoji("Box truck"), "🚚")  // the longer phrase wins
        XCTAssertEqual(InventoryLook.vehicleEmoji("Camper"), "🚐")
        XCTAssertEqual(InventoryLook.vehicleEmoji("RV"), "🚐")
        XCTAssertEqual(InventoryLook.vehicleEmoji("Minivan"), "🚐")
        XCTAssertEqual(InventoryLook.vehicleEmoji("Family SUV"), "🚙")
        XCTAssertEqual(InventoryLook.vehicleEmoji("Dirt bike"), "🏍️")
        XCTAssertEqual(InventoryLook.vehicleEmoji("Bikes"), "🚲")  // a plural matches
        XCTAssertEqual(InventoryLook.vehicleEmoji("e-bike"), "🚲")
        XCTAssertEqual(InventoryLook.vehicleEmoji("Moped"), "🛵")
        XCTAssertEqual(InventoryLook.vehicleEmoji("ATV"), "🚜")
        XCTAssertEqual(InventoryLook.vehicleEmoji("Bass boat"), "🚤")
        XCTAssertEqual(InventoryLook.vehicleEmoji("Kayaks"), "🛶")
        XCTAssertEqual(InventoryLook.vehicleEmoji("School bus"), "🚌")
        XCTAssertEqual(InventoryLook.vehicleEmoji("Wagon"), "🚗")
    }

    func testAVehicleWithNoTypeWordKeepsTheCar() {
        XCTAssertEqual(InventoryLook.vehicleEmoji("Old Blue"), "🚗")
        XCTAssertEqual(InventoryLook.vehicleEmoji(""), "🚗")
        XCTAssertEqual(InventoryLook.vehicleEmoji("Trucker hat"), "🚗")  // whole words only
        XCTAssertEqual(InventoryLook.vehicleEmoji("Carport"), "🚗")
    }
}
