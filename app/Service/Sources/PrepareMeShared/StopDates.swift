import Foundation

/// Dates that can stop PrepareMe (over-the-air plan, phase 3, layer 5): the rows of that section in the Mac's
/// Settings › Updates. The hourly check (scheduler/notice.py) reads the certificates' ends from the Keychain and the kept
/// installer's, and writes them to the jobs folder's `fileName`; the membership renewal is the date the owner types in
/// that section, kept in the pairing folder's `fileName`, which the hourly check reads to warn. Each row is amber
/// within `warnDays`, as the check's line (a test pins the two together).
public enum StopDates {
    public static let fileName = "dates.json"
    public static let warnDays = 60  // notice.py's DATE_WARN_DAYS
    public static let cloudSigning = "Cloud signing: no certificate, no date"
    /// The renewal's row, the one whose date box is in the Mac's table
    public static let renewalWhat = "Apple Developer Program renewal"

    public struct Row: Equatable, Sendable {
        public let what: String
        public let when: String
        public let caution: Bool
        /// The date and its days left, for the Mac's table (nil when the row has no date yet)
        public var on: Date? = nil
        public var days: Int? = nil
    }

    /// The Mac's table order (owner, 2026-11-14, by click): soonest first, then the rows with no date as listed
    public static func soonestFirst(_ rows: [Row]) -> [Row] {
        rows.enumerated().sorted { a, b in
            (a.element.days ?? Int.max, a.offset) < (b.element.days ?? Int.max, b.offset)
        }.map(\.element)
    }

    /// The jobs folder's record: its ISO dates by notice.py's DATE_ENDING keys
    public static func checked(_ data: Data?) -> [String: Date] {
        guard let data, let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return all.compactMapValues { ($0 as? String).flatMap { ISO8601DateFormatter().date(from: $0) } }
    }

    /// The renewal the owner typed (YYYY-MM-DD, the Mac's own day), nil when none or unreadable
    public static func renewal(_ data: Data?) -> Date? {
        guard let data, let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let day = all["renewal"] as? String else { return nil }
        return dayFormat.date(from: day)
    }

    /// The pairing folder's file for `date`
    public static func renewalData(_ date: Date) -> Data {
        Data(#"{"renewal": "\#(dayFormat.string(from: date))"}"#.utf8)
    }

    private static var dayFormat: DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }

    /// Every row, devices first (each name with its report, nil when it hasn't sent one), then each date. `jobs` is
    /// the jobs folder's record, nil when the hourly check hasn't written one.
    public static func rows(devices: [(name: String, report: PhoneStorage?)], renewal: Date?, jobs: Data?,
                            now: Date = Date()) -> [Row] {
        func dated(_ what: String, _ date: Date?, missing: String, warn: Int = warnDays) -> Row {
            guard let date else { return Row(what: what, when: missing, caution: true) }
            let days = InstallExpiry.daysLeft(date, now: now)
            return Row(what: what, when: "\(date.formatted(date: .long, time: .omitted)) (\(days) days)",
                       caution: days <= warn, on: date, days: days)
        }
        var rows = devices.map { device -> Row in
            if device.report?.channel == InstallExpiry.appstore {  // Unlisted plan, phase 5: no end, never amber
                return Row(what: "\(device.name) (App Store)", when: PhoneStorage.noEndDate, caution: false)
            }
            guard let report = device.report, let line = report.installLine(now: now),
                  let until = report.opensUntil.flatMap({ ISO8601DateFormatter().date(from: $0) }) else {
                return Row(what: device.name, when: "Not reported yet", caution: false)
            }
            let clock = report.channel == InstallExpiry.testflight ? "TestFlight" : "cable"
            let days = InstallExpiry.daysLeft(until, now: now)
            return Row(what: "\(device.name) (\(clock))",
                       when: "\(until.formatted(date: .long, time: .omitted)) (\(days) days)", caution: line.caution,
                       on: until, days: days)
        }
        let found = checked(jobs)
        let unread = jobs == nil ? "Not read yet: the hourly check reads it" : "Not found in the Keychain"
        rows.append(dated(renewalWhat, renewal, missing: "Not typed yet"))
        rows.append(dated("Developer ID certificate (the Mac install)", found["developer_id"], missing: unread))
        rows.append(dated("Apple Development certificate (cable installs)", found["apple_development"], missing: unread))
        // GitHub's uploads sign in Xcode's cloud with the API key (phase 4, decision 4 (a)): no certificate to end
        rows.append(Row(what: "Upload signing", when: Self.cloudSigning, caution: false))
        rows.append(Row(what: "App Store Connect API key", when: "No end date published", caution: false))
        let kept = jobs == nil ? "Not read yet: the hourly check reads it" : "None kept yet: the monthly installer job makes it"
        // amber at six months, as a cable device: the monthly job renews it, so amber means it has stopped working
        rows.append(dated("The kept cable installer", found["installer"], missing: kept, warn: PhoneStorage.cableRenewDays))
        return rows
    }
}
