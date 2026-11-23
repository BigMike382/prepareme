import Foundation

/// The phone's readings of the conditions feeds as counts (plan phase 5's 14-day check: "hourly counts, feed by feed,
/// phone against the Mac's records"). Counts only, never a feed's text, a code or a place; the Mac counts its own
/// readings the same way (dashboard/feed_counts.py), and the shared cases hold the two rules to each other.
///
/// - home-alerts: `alerts` in force (none of its VTEC lines cancelled, expired or upgraded, or none at all),
///   `events` (distinct VTEC events in force), `no_vtec` (alerts with no VTEC line): phase 1's rule.
/// - evacuations: `orders` (the order warnings) and `names_home` (1 when one names home's county).
/// - outages: `home` (1 when home's county has outages; never the count, as the phones' digest).
/// - gauges: `flood` (gauges at minor, moderate or major flooding) and `unread` (gauges with no reading to show),
///   over every gauge; read only when every gauge was.
/// - storms: `storms` (Atlantic storms); tropical-outlook: `chance` (outlooks with a medium or high chance).
public enum FeedCounts {
    public static let keys: [String: [String]] = [
        "home-alerts": ["alerts", "events", "no_vtec"], "evacuations": ["orders", "names_home"],
        "outages": ["home"], "gauges": ["flood", "unread"], "storms": ["storms"], "tropical-outlook": ["chance"],
    ]
    static let flood: Set<String> = ["minor", "moderate", "major"]

    /// The counts of one feed's items (for "gauges", every gauge's items together).
    public static func counts(_ feed: String, _ items: [ConditionItem]) -> [String: Int] {
        switch feed {
        case "home-alerts":
            var alerts = 0, noVTEC = 0
            var events = Set<String>()
            for item in items {
                let live = item.vtec.filter { !NWSVTEC.ended.contains(String($0.prefix(3))) }
                    .map { String($0.dropFirst(4)) }
                if item.vtec.isEmpty {
                    noVTEC += 1
                } else if live.isEmpty {
                    continue
                }
                alerts += 1
                events.formUnion(live)
            }
            return ["alerts": alerts, "events": events.count, "no_vtec": noVTEC]
        case "evacuations":
            return ["orders": items.filter { $0.flag == ConditionItem.warn }.count,
                    "names_home": items.contains { $0.code == MacFeeds.evacHomeCode } ? 1 : 0]
        case "outages":
            return ["home": MacFeeds.homeOutage(items) ? 1 : 0]
        case "gauges":
            return ["flood": items.filter { flood.contains($0.code) }.count,
                    "unread": items.filter { $0.flag == ConditionItem.unread }.count]
        case "storms":
            return ["storms": items.count]
        default:
            return ["chance": items.filter { $0.flag == ConditionItem.warn }.count]
        }
    }
}

/// What the phone posts to the Mac's library service (`POST /counts`, plan phase 5): when it read (UTC, to the
/// minute), each feed it read with its counts, and each feed it tried and couldn't read. A feed it didn't try this
/// time is in neither.
public struct FeedCountsReport: Codable, Equatable, Sendable {
    public var at: String
    public var feeds: [String: [String: Int]]
    public var unread: [String]

    public static let maxBytes = 2048
    public static let maxCount = 999

    public init(at: String, feeds: [String: [String: Int]], unread: [String]) {
        self.at = at
        self.feeds = feeds
        self.unread = unread.sorted()
    }

    public enum Problem: Error, Equatable, Sendable { case notTheShape }

    /// A report from a phone, refused unless it is exactly this shape: at most 2 KB, a minute like CountsReport's,
    /// only known feeds each with exactly its own count keys, counts 0 to 999, and `unread` known feeds read in no
    /// other place.
    public static func read(_ data: Data) throws -> FeedCountsReport {
        guard data.count <= maxBytes,
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(top.keys) == ["at", "feeds", "unread"],
              let at = top["at"] as? String, CountsReport.isMinute(at),
              let feeds = top["feeds"] as? [String: Any], let unread = top["unread"] as? [Any]
        else { throw Problem.notTheShape }
        var read: [String: [String: Int]] = [:]
        for (feed, value) in feeds {
            guard let keys = FeedCounts.keys[feed], let counts = value as? [String: Any],
                  Set(counts.keys) == Set(keys) else { throw Problem.notTheShape }
            read[feed] = try counts.mapValues { value -> Int in
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let whole = Int(exactly: number.doubleValue), (0...maxCount).contains(whole) else {
                    throw Problem.notTheShape
                }
                return whole
            }
        }
        let missed = try unread.map { value -> String in
            guard let feed = value as? String, FeedCounts.keys[feed] != nil, read[feed] == nil else {
                throw Problem.notTheShape
            }
            return feed
        }
        guard Set(missed).count == missed.count else { throw Problem.notTheShape }
        return FeedCountsReport(at: at, feeds: read, unread: missed)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
