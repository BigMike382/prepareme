import Foundation

/// The inventory's Settings as one form (settings redesign; owner, 2026-10-19, by click, after the mockup): titled
/// sections, each with a line saying what it's for, in place of the Settings table with the members under it, and the
/// Lists' settings moved in. Every figure stays where it was kept, the inventory's Settings rows or the lists' own
/// settings table, so the lists job reads them as before; only the screen changes.
public enum SettingsForm {
    public struct Part: Equatable, Sendable {
        public let title: String
        public let why: String
    }

    /// One figure in the form: its words, the setting it is kept under, its unit, whether it's whole (as the lists job
    /// reads it: readiness.inventory.SETTING_FIELDS), and whether the lists' own table keeps it.
    public struct Figure: Equatable, Hashable, Sendable {
        public let label: String
        public let setting: String
        public let unit: String
        public let whole: Bool
        public let lists: Bool

        init(_ label: String, _ setting: String, unit: String, whole: Bool = false, lists: Bool = false) {
            self.label = label
            self.setting = setting
            self.unit = unit
            self.whole = whole
            self.lists = lists
        }
    }

    public static let lede = "Who the household prepares for, and for how long. Today and the lists count from these."
    public static let people = Part(title: "People", why: "Each person, with no names, so food counts each one's "
                                    + "calories and water a gallon a day each.")
    public static let pets = Part(title: "Pets", why: "Each dog and cat with its weight. Their water counts from the "
                                  + "weights; their food from the daily amounts below.")
    public static let petFood = Part(title: "Pet food", why: "How much each kind eats in a day, from the bag's feeding "
                                     + "chart. Days of pet food count from these.")
    public static let howLong = Part(title: "How long to prepare for", why: "The days of supplies to keep on hand. The "
                                     + "lists count days of water, food and pet food against these.")
    public static let reminders = Part(title: "Reminders", why: "How early PrepareMe warns before something expires or "
                                       + "an upkeep task comes due.")
    public static let parts = [people, pets, petFood, howLong, reminders]

    /// With no one entered (or no pet listed), the old figures show and count, and say so.
    public static let peopleUntil = "People in household and Calories per person per day count until people are added."
    public static let petsUntil = "These total weights count until pets are added."
    /// The lists' own figures before the lists job has handed the lists over (as the Event mode switch says).
    public static let listsLater = "These show here once the lists job hands the lists over, within the hour."

    public static let peopleFallback = [Figure("People in household", "People in household", unit: "", whole: true),
                                        Figure("Calories per person per day", "Calories per person per day",
                                               unit: "calories", lists: true)]
    public static let petsFallback = [Figure("Dogs: total weight", "Dogs: total weight (lb)", unit: "lb"),
                                      Figure("Cats: total weight", "Cats: total weight (lb)", unit: "lb")]
    public static let petFoodRows = [Figure("All dogs, per day", "Dog food per day, all dogs (lb, from the bag)",
                                            unit: "lb"),
                                     Figure("All cats, per day", "Cat food per day, all cats (lb, from the bag)",
                                            unit: "lb")]
    public static let howLongRows = [Figure("Water", "Water target (days)", unit: "days", lists: true),
                                     Figure("Food", "Food target (days)", unit: "days", lists: true),
                                     Figure("Pet food", "Pet food target (days)", unit: "days", lists: true)]
    public static let reminderRows = [Figure("Before an expiry", Inventory.headsUpSetting, unit: "days", whole: true),
                                      Figure("Before an upkeep task", "Upkeep heads-up (days)", unit: "days",
                                             lists: true)]

    // MARK: The blue lines

    /// "4 people need about 9,000 calories and 4 gallons of water a day" (phase L, choice 4; the approved mockup's
    /// words): the members' calories from the lists job's own table (HouseholdMembers.calories, readiness/needs.py),
    /// added up and rounded to the nearest 100 as the lists job counts them, and a gallon a person
    /// (supply.water_per_day). Should a member's figure be missing (the table not in the build), the line gives the
    /// water alone, as before, rather than a wrong total.
    public static func peopleFact(_ members: [HouseholdMember]) -> String {
        let count = members.count, figures = members.compactMap(HouseholdMembers.calories)
        let water = "\(gallons(Double(count))) of water a day"
        guard figures.count == count, count > 0 else { return "\(count) \(count == 1 ? "person" : "people"): \(water)" }
        let calories = (Double(figures.reduce(0, +)) / 100).rounded() * 100
        let shown = calories.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        return "\(count) \(count == 1 ? "person needs" : "people need") about \(shown) calories and \(water)"
    }

    /// "2 dogs and 1 cat, 113 lb together: about 0.9 gallon of water a day": an ounce a pound (supply.water_per_day),
    /// rounded up to a tenth as the water calculator rounds. With a weight blank, the lists job counts no water, and
    /// the line says so (`counted` false: a caution, not a key fact).
    public static func petsFact(_ pets: [HouseholdPet]) -> (text: String, counted: Bool) {
        let dogs = pets.filter { $0.kind == "Dog" }.count, cats = pets.filter { $0.kind == "Cat" }.count
        let kinds = [dogs > 0 ? "\(dogs) dog\(dogs == 1 ? "" : "s")" : nil, cats > 0 ? "\(cats) cat\(cats == 1 ? "" : "s")"
                     : nil].compactMap { $0 }.joined(separator: " and ")
        guard pets.allSatisfy({ $0.weight != nil }) else {
            return ("\(kinds). Water isn't counted until each one's weight is filled in.", false)
        }
        let pounds = pets.reduce(0) { $0 + ($1.weight ?? 0) }
        let weight = "\(shown(pounds)) lb\(pets.count == 1 ? "" : " together")"
        let water = (pounds / 128 * 10 - 1e-9).rounded(.up) / 10
        return ("\(kinds), \(weight): about \(gallons(water)) of water a day", true)
    }

    /// "1 gallon", "0.9 gallon", "2.4 gallons".
    static func gallons(_ value: Double) -> String {
        "\(shown(value)) gallon\(value > 1 ? "s" : "")"
    }

    /// A figure as the form shows it: "52", "49.5", "" when blank.
    public static func shown(_ value: Double?) -> String {
        value.map(InventoryValues.number) ?? ""
    }

    // MARK: A typed figure

    /// Why a typed figure can't be kept, in fixed words, shown in red under its row.
    public enum Problem: Error, Equatable, CustomStringConvertible, Sendable {
        case notANumber, belowZero, notWhole, tooHeavy

        public var description: String {
            switch self {
            case .notANumber: InputProblem.notANumber.description
            case .belowZero: "Write 0 or more."
            case .notWhole: InputProblem.notAWholeNumber.description
            case .tooHeavy: HouseholdPets.badWeight
            }
        }
    }

    /// A typed figure: nil when blank, else a number of 0 or more (whole where `whole`).
    public static func figure(_ typed: String, whole: Bool) -> Result<Double?, Problem> {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .success(nil) }
        guard let found = InventoryValues.parseNumber(text) else { return .failure(.notANumber) }
        if found < 0 { return .failure(.belowZero) }
        if whole, found.rounded() != found { return .failure(.notWhole) }
        return .success(found)
    }

    /// A pet's typed weight: blank, or 0 to 300 lb.
    public static func weight(_ typed: String) -> Result<Double?, Problem> {
        switch figure(typed, whole: false) {
        case .success(let found?) where found > HouseholdPets.heaviest: .failure(.tooHeavy)
        case let other: other
        }
    }
}
