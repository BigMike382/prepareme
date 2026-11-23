import Foundation

/// When a phone fetches the Mac's household copy (the inventory and its lists, which carry the rally points) by itself
/// (beta run 2, B2-01). The street map had fetched it only when the phone held none, and a phone holds one from pairing
/// on, so a new or moved rally point reached a phone only through its Inventory tab: a child who never opened Inventory
/// never got it. Now every library check (launch and coming forward, every few minutes while open, the background
/// check, Check now) and every opening of the street map looks too, on any phone, a child's read-only one included,
/// unless a look a few seconds ago already has it; a tapped Check now always fetches (checkpoint 1). The library check
/// starts the look and doesn't wait for it. Inventory's own look (every 2 minutes while it shows, pull-down, Look now)
/// is apart from this and always fetches.
public enum HouseholdLook {
    public enum Moment {
        case libraryCheck  // after the Mac answered the check: the phone is home and the Mac is on
        case streetMapOpened
        case checkNow  // Home Mac's Check now, tapped, and the Mac answered: always fetched
    }

    /// A look this recent is fresh enough: another isn't fetched for it (Inventory's own look, or the check just before,
    /// one a few seconds after the other at launch).
    public static let fresh: TimeInterval = 30

    public static func due(_ moment: Moment, hasCopy: Bool, lastLook: Date?, now: Date = Date()) -> Bool {
        guard moment != .checkNow else { return true }  // the person asked for the latest
        guard hasCopy, let lastLook else { return true }  // nothing to show yet: always worth a try
        let age = now.timeIntervalSince(lastLook)
        return age >= fresh || age < 0  // a clock set back is no reason to wait
    }
}
