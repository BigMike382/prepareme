import Foundation

/// How the inventory's names are shown (owner, 2026-10-25, by click): in title case on screen only, every name kept in
/// the file exactly as typed; each category with an emoji, the owner's approved table (the Mac's line symbols went
/// with phase 3 of the fresh look, 2026-11-18: its tiles show the emoji too). A category is matched by its name, then
/// by its Counts as group, so one added later still gets a picture.
public enum InventoryLook {
    /// Lower case unless first, as the guide list's groups ("After a Disaster", "Water and Food").
    public static let smallWords: Set<String> = ["a", "an", "and", "at", "but", "by", "for", "in", "nor", "of", "on",
                                                 "or", "the", "to", "with"]

    /// `name` in title case: each word's first letter capitalized, a small word lower case unless first, and a word
    /// typed with a capital after its first letter ("iPhone", "AA"), or a one-letter word typed as a capital ("Shelf A":
    /// the owner's choice C, 2026-11-18), left as typed. Spacing and punctuation unchanged;
    /// a hyphen splits words ("Grab-and-Go"), an apostrophe doesn't ("Kid's").
    public static func title(_ name: String) -> String {
        var out = ""
        var word = ""
        var first = true
        func flush() {
            guard !word.isEmpty else { return }
            if word.dropFirst().contains(where: \.isUppercase) || (word.count == 1 && word.first!.isUppercase) {
                out += word  // "iPhone", "AA", and a shelf's letter typed as a capital, "Shelf A" (owner's choice C)
            } else if !first, smallWords.contains(word.lowercased()) {
                out += word.lowercased()
            } else {
                out += word.prefix(1).uppercased() + word.dropFirst()
            }
            first = false
            word = ""
        }
        for character in name {
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                word.append(character)
            } else {
                flush()
                out.append(character)
            }
        }
        flush()
        return out
    }

    /// The inventory's own category names (readiness/model.py's CATEGORY_MAP, the inventory's fourteen), folded.
    public static let nameEmoji: [String: String] = [
        "water": "💧", "food": "🥫", "medicine": "💊", "first aid": "🩹", "power and batteries": "🔋", "fuel": "⛽",
        "hygiene and sanitation": "🧼", "tools": "🔧", "gear": "🏕️", "materials": "🧱", "communications": "📻",
        "pet supplies": "🐕", "firearms and ammunition": "🎯", "vehicles": "🚙",
    ]
    /// The lists' twelve groups and Other (readiness/model.py's CATEGORIES), folded: a category's Counts as.
    public static let groupEmoji: [String: String] = [
        "water": "💧", "food": "🥫", "medical": "⛑️", "power and fuel": "⚡", "heat and shelter": "⛺",
        "tools and equipment": "🧰", "communications": "📻", "pets": "🐕", "documents and plans": "📄",
        "security": "🛡️", "vehicles and rv": "🚐", "skills and training": "🎓", "other": "🏷️",
    ]
    public static let otherEmoji = "🏷️"

    public static func emoji(category name: String, group: String?) -> String {
        pick(name, group, nameEmoji, groupEmoji) ?? otherEmoji
    }

    private static func pick(_ name: String, _ group: String?, _ byName: [String: String],
                             _ byGroup: [String: String]) -> String? {
        let fold = { (text: String) in text.trimmingCharacters(in: .whitespaces).lowercased() }
        return byName[fold(name)] ?? group.flatMap { byGroup[fold($0)] }
    }

    /// A vehicle has no type field, so a whole word (or its plural) in its name picks its emoji (owner, 2026-10-26, by
    /// click: the approved table); the first row that matches wins, so two-word phrases come before their last word.
    static let vehicleWords: [(words: [String], emoji: String)] = [
        (["box truck", "trailer"], "🚚"), (["dirt bike", "motorcycle"], "🏍️"), (["truck", "pickup"], "🛻"),
        (["suv", "crossover"], "🚙"), (["van", "minivan", "camper", "rv", "motorhome"], "🚐"), (["bus"], "🚌"),
        (["scooter", "moped"], "🛵"), (["bicycle", "bike"], "🚲"), (["tractor", "atv", "utv"], "🚜"),
        (["boat"], "🚤"), (["canoe", "kayak"], "🛶"), (["car", "sedan", "coupe", "wagon"], "🚗"),
    ]

    public static func vehicleEmoji(_ name: String) -> String {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let padded = " " + words.joined(separator: " ") + " "
        return vehicleWords.first { row in
            row.words.contains { padded.contains(" \($0) ") || padded.contains(" \($0)s ") }
        }?.emoji ?? Row.vehicle
    }

    /// The phone's Inventory home rows (the approved mockup): each row's emoji before its words.
    public enum Row {
        public static let quickAdd = "📷"
        public static let toBuy = "🛒"
        public static let expiring = "⏰"
        public static let grab = "🎒"
        public static let allItems = "📦"
        public static let eventMode = "🚨"
        public static let todo = "✅"
        public static let upkeep = "🛠️"
        public static let recalls = "⚠️"
        public static let place = "📍"
        public static let vehicle = "🚗"
    }
}
