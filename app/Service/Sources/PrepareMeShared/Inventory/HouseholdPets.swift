import Foundation

/// One dog or cat in the household, as the inventory's Settings lists them (settings redesign; owner, 2026-10-19, by
/// click): its name, its kind and its weight in pounds. The names go to the phones (the owner's answer 2).
public struct HouseholdPet: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var kind: String  // one of HouseholdPets.kinds
    public var weight: Double?  // pounds; nil while blank

    public init(name: String, kind: String, weight: Double?) {
        self.name = name
        self.kind = kind
        self.weight = weight
    }
}

/// The words and rules of the Settings' Pets. The lists job counts water from the weights (readiness/pets.py and
/// supply.py): once any pet is listed, each kind's weights added up stand for the old Settings totals (Dogs: total
/// weight, Cats: total weight), and a listed pet with a blank weight stops the water count; with none listed the old
/// totals count as before. Pet food stays one figure a day per kind (the owner's answer 3).
public enum HouseholdPets {
    public static let kinds = ["Dog", "Cat"]
    /// More than any household lists: a cap so a mistake can't fill the file.
    public static let most = 30
    public static let nameLimit = 40
    public static let heaviest = 300.0  // pounds

    public static let title = "Pets"
    public static let add = "Add a pet", remove = "Remove"
    public static let name = "Name", kind = "Kind", pounds = "lb"
    public static let noName = "Give the pet a name."
    public static let longName = "Keep a pet's name to 40 characters."
    public static let notAKind = "A pet is a Dog or a Cat."
    public static let badWeight = "A pet's weight is blank, or from 0 to 300 lb."
    public static let tooMany = "Up to 30 pets can be listed."
    /// A pets table the file holds in another shape: the inventory still opens, the list shows as none and can't be
    /// changed, and the lists job counts no water days (readiness/pets.py).
    public static let unreadable = "The pets in the inventory file can't be read, so they can't be changed here, and "
        + "days of water aren't counted until that's fixed."

    /// Why a pet can't be kept, or nil: a name of 1 to 40 characters, Dog or Cat, a weight blank or 0 to 300 lb.
    public static func problem(_ pet: HouseholdPet) -> String? {
        let name = pet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return noName }
        if name.count > nameLimit { return longName }
        guard kinds.contains(pet.kind) else { return notAKind }
        if let weight = pet.weight, !(weight.isFinite && weight >= 0 && weight <= heaviest) { return badWeight }
        return nil
    }

    /// `pet` with its name's surrounding spaces trimmed.
    public static func normalized(_ pet: HouseholdPet) -> HouseholdPet {
        var found = pet
        found.name = found.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return found
    }

    /// A new pet's row: a dog with no weight yet, named so the row can be told apart until it's renamed.
    public static func blank(after pets: [HouseholdPet]) -> HouseholdPet {
        let taken = Set(pets.map(\.name))
        let n = (pets.count + 1...pets.count + most + 1).first { !taken.contains("Pet \($0)") } ?? pets.count + 1
        return HouseholdPet(name: "Pet \(n)", kind: "Dog", weight: nil)
    }
}

extension InventoryFile {
    /// Not in _grist_Tables, so Grist's reader of tables never sees it; readiness/pets.py reads it.
    public static let petsTable = "PrepareMe_Pets"

    /// The pets in the order they were entered; none when the table isn't there yet. Throws for a table of another
    /// shape, a weight that isn't a number, or a row readiness/pets.py wouldn't read (a blank name, a kind other than
    /// Dog or Cat), so the Mac never shows as kept a pet the lists job counts as unreadable (review, 2026-10-19).
    public func pets() throws -> [HouseholdPet] {
        guard try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                            [.text(Self.petsTable)]).isEmpty else { return [] }
        return try db.query("SELECT name, kind, weight FROM \"\(Self.petsTable)\" ORDER BY id").map { row in
            let weight: Double? = switch row[2] {
            case .null: nil
            case .int(let found): Double(found)
            case .real(let found): found
            default: throw InventoryFileError.noTable(Self.petsTable)
            }
            let pet = HouseholdPet(name: Self.text(row[0]) ?? "", kind: Self.text(row[1]) ?? "", weight: weight)
            guard !pet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  HouseholdPets.kinds.contains(pet.kind) else { throw InventoryFileError.noTable(Self.petsTable) }
            return pet
        }
    }

    /// The whole list put in place of the old one, in one save; the old list.
    @discardableResult
    public func setPets(_ pets: [HouseholdPet]) throws -> [HouseholdPet] {
        guard !readOnly else { throw InventoryFileError.readOnly }
        let old = try self.pets()
        try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS "\(Self.petsTable)" (id INTEGER PRIMARY KEY, name TEXT NOT NULL, \
                kind TEXT NOT NULL, weight REAL)
                """)
            try db.execute("DELETE FROM \"\(Self.petsTable)\"")
            for (n, pet) in pets.enumerated() {
                try db.execute("INSERT INTO \"\(Self.petsTable)\" (id, name, kind, weight) VALUES (?, ?, ?, ?)",
                               [.int(Int64(n + 1)), .text(pet.name), .text(pet.kind),
                                pet.weight.map { .real($0) } ?? .null])
            }
        }
        return old
    }
}
