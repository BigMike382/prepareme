import Foundation

/// The phone's Inventory home, calmer (beta run 2 fix plan, Task R9.2; the owner's pick, mockup 2): search first, the
/// supplies as numbers with their goal in words, one status line in place of the notes (the copy's source at the foot), Add as one labeled button.
/// What the screen says lives here so a test pins it.
public enum InventoryHome {
    public static let addLabel = "Add"
    public static let scanLabel = "Scan a barcode"
    public static let suppliesTitle = "Supplies"
    /// The way to every supply's calculators, stocked or not (B2-30); "none entered" says why a group has no days.
    public static let calculatorsLink = "Calculators for each supply"
    public static let remindersOff = "Reminders are off."

    /// Quick add's foot (entry fixes plan, Task 2.4): the changes the Mac refused, as the Inventory tab's badge counts
    /// them; tapping it goes back to the Inventory home, which lists them.
    public static func notSaved(_ count: Int) -> String { "\(count) not saved" }
    public static let notSavedHint = "Goes back to Inventory, which lists them."

    /// The line under the title (owner, 2026-10-21: the copy's source moved to the foot): only that reminders are off,
    /// when the phone could ask or point to Settings; its button and explanation follow it. The caller shows it only
    /// when no search has words (PhoneSearch.showsNotes). Empty when there is nothing to say.
    public static func statusLine(reminders: LocationAsk.Offer) -> String {
        reminders != .none ? remindersOff : ""
    }

    /// The quiet line at the foot of the list (owner, 2026-10-21; it began the list before): where the copy came from
    /// and when, and a child's or a backup copy's read-only words with it, as one paragraph. Not shown while a search
    /// has words. Empty when there is nothing to say.
    public static func footerLine(written: String?, fromBackup: Bool, canEdit: Bool, paired: Bool,
                                  device: String) -> String {
        var parts: [String] = []
        if let written {
            parts.append(fromBackup ? HomeMacWords.backupCopyWritten(written) : "From the Mac, \(written).")
        }
        if fromBackup {
            parts.append(HomeMacWords.backupCopyReadOnly(device: device, paired: paired))
        } else if !canEdit {
            parts.append(HomeMacWords.readOnlyInventory)
        }
        return parts.joined(separator: " ")
    }

    /// One supply as a number with what it counts: "7" and "days of water (goal 30)". `low` when short of the goal.
    public struct Chip: Equatable, Sendable {
        public let number: String
        public let label: String
        public let low: Bool
        /// What VoiceOver says: the number and its words, and "short of goal" for a low one (color is not alone)
        public var spoken: String { "\(number) \(label)" + (low ? ", short of goal" : "") }
    }

    public static func chip(kind: String, days: Double?, target: Double?) -> Chip {
        chip(what: "days of \(kind)", days: days, target: target)
    }

    /// A pet's half of the Pet food box, under the pet's name: "20" and "days (goal 90)", or "–" and "not counted".
    public static func half(days: Double?, target: Double?) -> Chip { chip(what: "days", days: days, target: target) }

    static func chip(what: String, days: Double?, target: Double?) -> Chip {
        let goal = target.map { " (goal \(InventoryValues.number($0)))" } ?? ""
        guard let days else {
            return Chip(number: "–", label: what == "days" ? "not counted\(goal)" : "\(what), not counted\(goal)",
                        low: false)
        }
        return Chip(number: InventoryValues.days(days), label: "\(what)\(goal)", low: target.map { days < $0 } ?? false)
    }

    /// The supplies as the Today page shows them (owner, 2026-11-14, by click): a Water box and a Food box side by
    /// side, each kept with a dash while not counted, then one Pet food box halved Cat | Dog.
    public static func mainKinds(_ supplies: [SupplyShares.Kind]) -> [SupplyShares.Kind] {
        ["water", "food"].compactMap { name in supplies.first { $0.kind == name } }
    }

    public static let petFoodTitle = "Pet food"

    /// The Pet food box's halves, cats first as on Today: a pet food the lists job counts, or one for a kind of pet
    /// the Settings' Pets list though its days aren't counted. Empty when neither, and then no box.
    public static func petKinds(_ supplies: [SupplyShares.Kind], pets: [HouseholdPet]?) -> [SupplyShares.Kind] {
        [("cat food", "Cat"), ("dog food", "Dog")].compactMap { name, pet in
            supplies.first { $0.kind == name && ($0.perDay != nil || (pets ?? []).contains { $0.kind == pet }) }
        }
    }

    public static func petName(_ kind: SupplyShares.Kind) -> String { kind.kind == "cat food" ? "Cat" : "Dog" }

    /// In the Water box under its days, for containers ticked Empty until needed: Today's words
    /// (dashboard/render.py FILL_SHORT, "+7 if filled"); nil for any other supply or without any.
    public static func fillShort(_ kind: SupplyShares.Kind) -> String? {
        guard kind.kind == "water" else { return nil }
        return kind.fillableDays.map { "+\(InventoryValues.days($0)) if filled" }
    }
}
