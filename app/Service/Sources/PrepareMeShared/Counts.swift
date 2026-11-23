import Foundation

/// What a phone posts to the Mac (`POST /counts`, plan phase 1): counts only, never an alert's text, a zone code or
/// a place. `at` is when the phone read the alerts, in UTC to the minute ("2026-10-12T21:07Z"); `read` false means it
/// couldn't read them, and then no count is sent, so "couldn't read" can never be taken for "none".
/// `alerts` is the number of alerts in force, `events` the distinct VTEC events in force (office, phenomenon,
/// significance and number), `noVTEC` the alerts that carry no VTEC line. The Mac counts its own page the same two
/// ways (dashboard/counts.py), so the comparison is like with like.
public struct CountsReport: Codable, Equatable, Sendable {
    public var at: String
    public var read: Bool
    public var alerts: Int?
    public var events: Int?
    public var noVTEC: Int?

    enum CodingKeys: String, CodingKey {
        case at, read, alerts, events
        case noVTEC = "no_vtec"
    }

    public static let maxBytes = 1024
    public static let maxCount = 999

    public init(at: String, counts: AlertCounts?) {
        self.at = at
        self.read = counts != nil
        self.alerts = counts?.alerts
        self.events = counts?.events
        self.noVTEC = counts?.noVTEC
    }

    public enum Problem: Error, Equatable, Sendable {
        case tooBig, notAnObject, unknownKey, badTime, badCounts
    }

    /// A report from a phone, refused unless it is exactly this shape: at most 1 KB, no key but these five, a time of
    /// the form above, and either three counts from 0 to 999 with `read` true or none with `read` false.
    public static func read(_ data: Data) throws -> CountsReport {
        guard data.count <= maxBytes else { throw Problem.tooBig }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Problem.notAnObject
        }
        let allowed: Set<String> = ["at", "read", "alerts", "events", "no_vtec"]
        guard Set(object.keys).isSubset(of: allowed) else { throw Problem.unknownKey }
        guard let at = object["at"] as? String, isMinute(at) else { throw Problem.badTime }
        guard let read = object["read"] as? NSNumber, CFGetTypeID(read) == CFBooleanGetTypeID() else {
            throw Problem.badCounts
        }
        let counts = ["alerts", "events", "no_vtec"].map { object[$0] }
        if read.boolValue {
            let numbers = try counts.map { value -> Int in
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let whole = Int(exactly: number.doubleValue), (0...maxCount).contains(whole) else {
                    throw Problem.badCounts
                }
                return whole
            }
            return CountsReport(at: at, counts: AlertCounts(alerts: numbers[0], events: numbers[1],
                                                               noVTEC: numbers[2]))
        }
        guard counts.allSatisfy({ $0 == nil || $0 is NSNull }) else { throw Problem.badCounts }
        return CountsReport(at: at, counts: nil)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// "2026-10-12T21:07Z": a real UTC time to the minute.
    public static func isMinute(_ text: String) -> Bool {
        guard text.utf8.count == 17 else { return false }
        return minuteFormatter().date(from: text).map { minuteFormatter().string(from: $0) == text } ?? false
    }

    public static func minute(_ date: Date) -> String {
        minuteFormatter().string(from: date)
    }

    static func minuteFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return formatter
    }
}

public struct AlertCounts: Equatable, Sendable {
    public var alerts: Int
    public var events: Int
    public var noVTEC: Int

    public init(alerts: Int, events: Int, noVTEC: Int) {
        self.alerts = alerts
        self.events = events
        self.noVTEC = noVTEC
    }
}
