import Foundation

/// Expiring soon's date words (the beta run's F24; plan 2026-10-16, Task 4.2): "Expired Oct 2" for a day gone by (the
/// red role), "Expires today" and "Expires Oct 20" for the rest (the amber caution role), the year only when it isn't
/// this year's. The inventory stores a day as seconds at UTC midnight (InventoryValues), so "today" is the phone's own
/// calendar day compared with that stored day, never with UTC's.
public enum ExpiryWords {
    public enum Line: Equatable, Sendable {
        case expired(String)
        case soon(String)
    }

    public static func line(_ seconds: Double, now: Date = Date(), timeZone: TimeZone = .current) -> Line {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let today = local.dateComponents([.year, .month, .day], from: now)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let stored = Date(timeIntervalSince1970: seconds)
        let day = utc.dateComponents([.year, .month, .day], from: stored)
        let order = [day.year ?? 0, day.month ?? 0, day.day ?? 0]
            .lexicographicallyPrecedes([today.year ?? 0, today.month ?? 0, today.day ?? 0])
        if day == today { return .soon("Expires today") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = utc.timeZone
        formatter.dateFormat = day.year == today.year ? "MMM d" : "MMM d, yyyy"
        let words = formatter.string(from: stored)
        return order ? .expired("Expired \(words)") : .soon("Expires \(words)")
    }

    /// Earliest first: expired items at the top.
    public static func earlier(_ a: Double, _ b: Double) -> Bool { a < b }
}
