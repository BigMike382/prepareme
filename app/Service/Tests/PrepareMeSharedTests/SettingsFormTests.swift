import Foundation
@testable import PrepareMeShared
import XCTest

/// The inventory's Settings as one form (settings redesign; owner, 2026-10-19, by click): its sections' words, the blue
/// lines adding up the people and pets (water by the lists job's own rule, supply.water_per_day: a gallon a person,
/// an ounce a pound for pets), where each figure is kept, and the checks a typed figure passes before it's saved.
final class SettingsFormTests: XCTestCase {
    func testTheSectionsAndTheirWords() {
        XCTAssertEqual(SettingsForm.lede, "Who the household prepares for, and for how long. Today and the lists "
                       + "count from these.")
        XCTAssertEqual(SettingsForm.parts.map(\.title), ["People", "Pets", "Pet food", "How long to prepare for",
                                                         "Reminders"])  // Event mode: the sidebar's (look 3, change 9)
        XCTAssertEqual(SettingsForm.people.why, "Each person, with no names, so food counts each one's calories and "
                       + "water a gallon a day each.")
        XCTAssertEqual(SettingsForm.pets.why, "Each dog and cat with its weight. Their water counts from the weights; "
                       + "their food from the daily amounts below.")
        XCTAssertEqual(SettingsForm.petFood.why, "How much each kind eats in a day, from the bag's feeding chart. Days "
                       + "of pet food count from these.")
        XCTAssertEqual(SettingsForm.howLong.why, "The days of supplies to keep on hand. The lists count days of "
                       + "water, food and pet food against these.")
        XCTAssertEqual(SettingsForm.reminders.why, "How early PrepareMe warns before something expires or an upkeep "
                       + "task comes due.")
        XCTAssertEqual(SettingsForm.peopleUntil, "People in household and Calories per person per day count until "
                       + "people are added.")
        XCTAssertEqual(SettingsForm.petsUntil, "These total weights count until pets are added.")
        XCTAssertEqual(SettingsForm.listsLater, "These show here once the lists job hands the lists over, within the "
                       + "hour.")
    }

    /// Every figure stays where it was kept (the plan's "Where it's kept"): the inventory's Settings rows, or the
    /// lists' own settings table; only the screen changes.
    func testEachFigureIsKeptWhereItWas() {
        let rows = SettingsForm.peopleFallback + SettingsForm.petsFallback + SettingsForm.petFoodRows
            + SettingsForm.howLongRows + SettingsForm.reminderRows
        XCTAssertEqual(rows.map(\.label), ["People in household", "Calories per person per day", "Dogs: total weight",
                                           "Cats: total weight", "All dogs, per day", "All cats, per day", "Water",
                                           "Food", "Pet food", "Before an expiry", "Before an upkeep task"])
        XCTAssertEqual(rows.filter { !$0.lists }.map(\.setting),
                       ["People in household", "Dogs: total weight (lb)", "Cats: total weight (lb)",
                        "Dog food per day, all dogs (lb, from the bag)", "Cat food per day, all cats (lb, from the bag)",
                        Inventory.headsUpSetting])
        XCTAssertEqual(rows.filter(\.lists).map(\.setting),
                       ["Calories per person per day", "Water target (days)", "Food target (days)",
                        "Pet food target (days)", "Upkeep heads-up (days)"])
        XCTAssertEqual(Set(rows.filter(\.lists).map(\.setting)),
                       Set(ListsLayout.settingsRows.filter { $0 != ListsLayout.eventMode }), "every lists setting moves in")
        XCTAssertEqual(rows.map(\.unit), ["", "calories", "lb", "lb", "lb", "lb", "days", "days", "days", "days", "days"])
        XCTAssertEqual(rows.filter(\.whole).map(\.setting), ["People in household", Inventory.headsUpSetting],
                       "whole as the lists job reads them (readiness.inventory.SETTING_FIELDS)")
    }

    /// The plan's words (phase L, choice 4): the members' calories added up from the lists job's table, rounded to
    /// the nearest 100, and a gallon of water a person.
    func testThePeoplesLine() {
        let four = [HouseholdMember(age: "36-40 years", sex: "Female", activity: "Moderately active"),  // 2,000
                    HouseholdMember(age: "41-45 years", sex: "Male", activity: "Moderately active"),  // 2,600
                    HouseholdMember(age: "15 years", sex: "Male", activity: "Moderately active"),  // 2,600
                    HouseholdMember(age: "8 years", sex: "Female", activity: "Active")]  // 1,800
        XCTAssertEqual(SettingsForm.peopleFact(four), "4 people need about 9,000 calories and 4 gallons of water a day")
        XCTAssertEqual(SettingsForm.peopleFact([four[0]]),
                       "1 person needs about 2,000 calories and 1 gallon of water a day")
        XCTAssertEqual(SettingsForm.peopleFact([HouseholdMember(age: "18 months", sex: "Female", activity: "")]),
                       "1 person needs about 900 calories and 1 gallon of water a day")
    }

    /// The pets' line, as the mockup drew it: 113 lb ÷ 128 is 0.88 gallon, shown rounded up to a tenth, as the water
    /// calculator rounds; a blank weight says it stops the count, as the lists job does.
    func testThePetsLine() {
        let three = [HouseholdPet(name: "Biscuit", kind: "Dog", weight: 52),
                     HouseholdPet(name: "Pepper", kind: "Dog", weight: 49),
                     HouseholdPet(name: "Mittens", kind: "Cat", weight: 12)]
        XCTAssertEqual(SettingsForm.petsFact(three).text,
                       "2 dogs and 1 cat, 113 lb together: about 0.9 gallon of water a day")
        XCTAssertTrue(SettingsForm.petsFact(three).counted)
        XCTAssertEqual(SettingsForm.petsFact([three[0]]).text, "1 dog, 52 lb: about 0.5 gallon of water a day")
        XCTAssertEqual(SettingsForm.petsFact([three[2], three[2]]).text,
                       "2 cats, 24 lb together: about 0.2 gallon of water a day")
        let heavy = Array(repeating: HouseholdPet(name: "Big", kind: "Dog", weight: 150), count: 2)
        XCTAssertEqual(SettingsForm.petsFact(heavy).text, "2 dogs, 300 lb together: about 2.4 gallons of water a day")
        let blank = [three[0], HouseholdPet(name: "Mittens", kind: "Cat", weight: nil)]
        XCTAssertEqual(SettingsForm.petsFact(blank).text, "1 dog and 1 cat. Water isn't counted until each one's "
                       + "weight is filled in.")
        XCTAssertFalse(SettingsForm.petsFact(blank).counted)
    }

    /// A figure is a number of 0 or more (whole where the lists job reads it whole), or blank; a pet's weight 0 to
    /// 300 lb. A refusal is in fixed words, under its row.
    func testATypedFigure() {
        XCTAssertEqual(SettingsForm.figure(" 2.5 ", whole: false), .success(2.5))
        XCTAssertEqual(SettingsForm.figure("1,045", whole: true), .success(1045))
        XCTAssertEqual(SettingsForm.figure("", whole: true), .success(nil))
        XCTAssertEqual(SettingsForm.figure("two", whole: false), .failure(.notANumber))
        XCTAssertEqual(SettingsForm.figure("-1", whole: false), .failure(.belowZero))
        XCTAssertEqual(SettingsForm.figure("2.5", whole: true), .failure(.notWhole))
        XCTAssertEqual(SettingsForm.Problem.notANumber.description, "Write a number, like 6 or 2.5.")
        XCTAssertEqual(SettingsForm.Problem.belowZero.description, "Write 0 or more.")
        XCTAssertEqual(SettingsForm.Problem.notWhole.description, "Write a whole number.")
        XCTAssertEqual(SettingsForm.weight("52"), .success(52))
        XCTAssertEqual(SettingsForm.weight(""), .success(nil))
        XCTAssertEqual(SettingsForm.weight("301"), .failure(.tooHeavy))
        XCTAssertEqual(SettingsForm.weight("-3"), .failure(.belowZero))
        XCTAssertEqual(SettingsForm.Problem.tooHeavy.description, HouseholdPets.badWeight)
        XCTAssertEqual(SettingsForm.shown(52), "52")
        XCTAssertEqual(SettingsForm.shown(49.5), "49.5")
        XCTAssertEqual(SettingsForm.shown(nil), "")
    }
}
