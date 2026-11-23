import Foundation

/// One person in the household, as the inventory's Settings lists them (step 8a; owner, 2026-10-19, by click: calories
/// by person): an age band, a sex and an activity level as the Dietary Guidelines' table names them, never a name.
public struct HouseholdMember: Codable, Equatable, Hashable, Sendable {
    public var age: String  // one of HouseholdMembers.ages
    public var sex: String  // one of HouseholdMembers.sexes
    public var activity: String  // one of HouseholdMembers.activities; "" (not read) for a toddler

    public init(age: String, sex: String, activity: String) {
        self.age = age
        self.sex = sex
        self.activity = activity
    }
}

/// The menus and words of the Settings' Household members. The lists job owns the needs table (readiness/needs.py, the
/// Dietary Guidelines for Americans, 2020-2025, Tables A2-1 and A2-2) and counts days of food from it; the Mac only
/// keeps each member's three choices, so no figure is copied here: the People line reads each member's calories from
/// Resources/household-needs.json, shipped with this package, which readiness/tests/test_needs.py writes and pins to
/// the table (phase L, choice 4). The menus are the lists job's own, pinned through the same file. Once any member is
/// entered, days of food
/// add up the members' needs and water counts one gallon a day for each; with none, People in household and Calories
/// per person per day count as before (readiness/supply.py).
public enum HouseholdMembers {
    public static let edition = "Dietary Guidelines for Americans, 2020-2025"
    /// Table A2-1's rows, by sex only (no activity level).
    public static let toddlerAges = ["12 months", "15 months", "18 months", "21 through 23 months"]
    /// Table A2-1's rows, then Table A2-2's: each year from 2 to 18, then the bands to 76 and up.
    public static let ages = toddlerAges + (2...18).map { "\($0) years" }
        + ["19-20 years", "21-25 years", "26-30 years", "31-35 years", "36-40 years", "41-45 years", "46-50 years",
           "51-55 years", "56-60 years", "61-65 years", "66-70 years", "71-75 years", "76 years and up"]
    public static let sexes = ["Male", "Female"]
    public static let activities = ["Sedentary", "Moderately active", "Active"]
    /// The fold over the three definitions in Mac Settings › Household (beta run 2, B2-17)
    public static let levelsFold = "What the levels mean"
    /// Table A2-2's footnotes a to c, in our words.
    public static let activityMeans = [
        "Sedentary": "Only the physical activity of independent living.",
        "Moderately active": "Also walking about 1.5 to 3 miles a day at 3 to 4 miles an hour, or the same.",
        "Active": "Also walking more than 3 miles a day at 3 to 4 miles an hour, or the same.",
    ]
    /// More than any household lists: a cap so a mistake can't fill the file.
    public static let most = 30

    // The words a person reads in the Mac's Settings.
    public static let title = "Household members"
    public static let source = "Calories a day from the Dietary Guidelines for Americans, 2020-2025 (Tables A2-1 and "
        + "A2-2). Babies under 12 months, pregnancy and breastfeeding aren't in those tables."
    public static let add = "Add a person", remove = "Remove"
    public static let age = "Age", sex = "Sex", activity = "Activity"
    public static let noActivity = "Not used under 2"
    public static let notAChoice = "That isn't one of the table's choices."
    public static let tooMany = "Up to 30 household members can be listed."
    /// A members table the file holds in another shape (step 8a review): the inventory still opens, the list shows as
    /// none and can't be changed, and the lists job counts no food or water days (readiness/members.py).
    public static let unreadable = "The household members in the inventory file can't be read, so they can't be "
        + "changed here, and days of food and water aren't counted until that's fixed."

    public static func isToddler(_ age: String) -> Bool { toddlerAges.contains(age) }

    /// The lists job's table as shipped (Resources/household-needs.json); nil only if the file isn't in the build.
    static let sampleURL = Bundle.module.url(forResource: "household-needs", withExtension: "json")

    struct Need: Decodable { let age, sex, activity: String; let calories: Int }
    struct Sample: Decodable { let calories: [Need] }

    /// Each row's calories, by age, sex and activity ("" for a toddler); empty if the file can't be read.
    static let needs: [String: Int] = {
        guard let url = sampleURL, let data = try? Data(contentsOf: url),
              let sample = try? JSONDecoder().decode(Sample.self, from: data) else { return [:] }
        return Dictionary(sample.calories.map { ("\($0.age)|\($0.sex)|\($0.activity)", $0.calories) },
                          uniquingKeysWith: { first, _ in first })
    }()

    /// The member's estimated calories a day from the lists job's table (readiness/needs.py `need`), or nil for
    /// anything not exactly one of the menus' words; a toddler's activity isn't read (Table A2-1 has none).
    public static func calories(_ member: HouseholdMember) -> Int? {
        needs["\(member.age)|\(member.sex)|\(isToddler(member.age) ? "" : member.activity)"]
    }

    /// Why a member can't be kept, or nil: each choice exactly one of the menus' (a toddler's activity isn't read).
    public static func problem(_ member: HouseholdMember) -> String? {
        guard ages.contains(member.age), sexes.contains(member.sex),
              isToddler(member.age) || activities.contains(member.activity) else { return notAChoice }
        return nil
    }

    /// `member` with its activity fitting its age: "" for a toddler (Table A2-1 has none), "Moderately active" for an
    /// older age that had none, else as chosen.
    public static func normalized(_ member: HouseholdMember) -> HouseholdMember {
        var found = member
        if isToddler(found.age) {
            found.activity = ""
        } else if !activities.contains(found.activity) {
            found.activity = "Moderately active"
        }
        return found
    }

    /// A new member's choices: an adult of the first sex, moderately active, to change in the menus.
    public static let blank = HouseholdMember(age: "36-40 years", sex: "Female", activity: "Moderately active")
}

extension InventoryFile {
    /// Not in _grist_Tables, so Grist's reader of tables never sees it; readiness/members.py reads it.
    public static let membersTable = "PrepareMe_Members"

    /// The members in the order they were entered; none when the table isn't there yet.
    public func members() throws -> [HouseholdMember] {
        guard try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                            [.text(Self.membersTable)]).isEmpty else { return [] }
        return try db.query("SELECT age, sex, activity FROM \"\(Self.membersTable)\" ORDER BY id").map { row in
            HouseholdMember(age: Self.text(row[0]) ?? "", sex: Self.text(row[1]) ?? "", activity: Self.text(row[2]) ?? "")
        }
    }

    /// The whole list put in place of the old one, in one save; the old list.
    @discardableResult
    public func setMembers(_ members: [HouseholdMember]) throws -> [HouseholdMember] {
        guard !readOnly else { throw InventoryFileError.readOnly }
        let old = try self.members()
        try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS "\(Self.membersTable)" (id INTEGER PRIMARY KEY, age TEXT NOT NULL, \
                sex TEXT NOT NULL, activity TEXT NOT NULL)
                """)
            try db.execute("DELETE FROM \"\(Self.membersTable)\"")
            for (n, member) in members.enumerated() {
                try db.execute("INSERT INTO \"\(Self.membersTable)\" (id, age, sex, activity) VALUES (?, ?, ?, ?)",
                               [.int(Int64(n + 1)), .text(member.age), .text(member.sex), .text(member.activity)])
            }
        }
        return old
    }
}
