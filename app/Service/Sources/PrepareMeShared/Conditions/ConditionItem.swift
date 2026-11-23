import Foundation

/// One line of a conditions panel, as the Mac's dashboard keeps it (`dashboard/model.py`'s Item), for the phone app's
/// own reading of the feeds (plan phase 5). Only the fields the phone's feeds and rules use.
///
/// - `when` and `expires` are ISO times with their offset, in New York time, as the Mac writes them
///   ("2026-10-06T10:15:00-04:00"), or a plain date ("2026-10-06").
/// - `flag` is "", "warn" or "unread" (a river gauge with no reading to show).
/// - `code` is an NWS phenomenon and significance ("TO.W"), a gauge's flood category word, or "EVAC.HOME".
/// - `vtec` holds each VTEC line as "action.office.phenomenon.significance.number" ("NEW.KLWX.WI.Y.0012").
public struct ConditionItem: Codable, Equatable, Sendable {
    public var text: String
    public var when: String?
    public var link: String?
    public var detail: String
    public var flag: String
    public var expires: String?
    public var code: String
    public var vtec: [String]
    /// An NWS alert's own instruction, as the API gives it (its `instruction` field), for the band (beta run 2, R9.1);
    /// nil when it gives none, and in a reading saved before it was kept.
    public var instruction: String?
    /// An hour of the grid forecast where the phone is (forecast-detail plan, phase 3), as the Mac's hours carry it;
    /// nil for every other line.
    public var hour: ConditionHour?

    public init(_ text: String, when: String? = nil, link: String? = nil, detail: String = "", flag: String = "",
                expires: String? = nil, code: String = "", vtec: [String] = [], instruction: String? = nil,
                hour: ConditionHour? = nil) {
        self.text = text
        self.when = when
        self.link = link
        self.detail = detail
        self.flag = flag
        self.expires = expires
        self.code = code
        self.vtec = vtec
        self.instruction = instruction
        self.hour = hour
    }

    public static let warn = "warn"
    public static let unread = "unread"  // dashboard/weather.py NO_READING_FLAG
}

/// An hour's fields as dashboard/model.py's Item keeps them for the Mac's hours, each "" when the forecast gives none:
/// rain chance (digits), temperature and feels-like (°F, feels only when it differs), wind ("NW 5", "0" when calm), its
/// gusts (mph), the rain amount in inches and over how many hours it falls (the grid gives it for spans; 1 for an
/// hour's own), and the coverage of any thunderstorms ("chance").
public struct ConditionHour: Codable, Equatable, Sendable {
    public var pop, temp, feels, wind, gust, rain, storm: String
    public var rainHours: Int

    public init(pop: String = "", temp: String = "", feels: String = "", wind: String = "", gust: String = "",
                rain: String = "", rainHours: Int = 1, storm: String = "") {
        (self.pop, self.temp, self.feels, self.wind, self.gust) = (pop, temp, feels, wind, gust)
        (self.rain, self.rainHours, self.storm) = (rain, rainHours, storm)
    }
}

/// A feed's answer in a shape its reader can't read. The message is fixed words and field names only, never bytes
/// from the answer (the Mac's FeedFormatError), so it can be shown as the reason a read failed.
public struct FeedFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Times as the Mac's dashboard reads and writes them.
public enum ConditionTime {
    public static let newYork = TimeZone(identifier: "America/New_York")!

    /// An ISO time with its offset (or Z), fractional seconds allowed; nil for anything else, NWPS's missing time
    /// ("0001-01-01…") included (dashboard/weather.py `iso_moment`).
    public static func moment(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.hasPrefix("0001-01-01") else { return nil }
        for formatter in [plainISO, fractionalISO] {
            if let found = formatter.date(from: text) { return found }
        }
        for formatter in isoIn {  // the other forms Python's fromisoformat reads (whole-branch review M2)
            if let found = formatter.date(from: text) { return found }
        }
        return nil
    }

    /// The moment in New York time with its offset, seconds always shown ("2026-10-06T10:15:00-04:00"), as Python's
    /// `datetime.isoformat()` writes a time with no fraction.
    public static func newYorkISO(_ moment: Date) -> String {
        isoOut.string(from: moment)
    }

    /// "Oct 6, 10:15 AM EDT": New York time as a reader writes it (dashboard/weather.py `_shown`).
    public static func shown(_ moment: Date) -> String {
        shownOut.string(from: moment)
    }

    /// A New York date ("2026-10-06") for the moment.
    public static func newYorkDay(_ moment: Date) -> String {
        dayOut.string(from: moment)
    }

    /// An RSS date (RFC 822) as New York time with its offset; one without a zone is UTC's; nil when unreadable
    /// (dashboard/weather.py `_rss_time`).
    public static func rss(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        for formatter in rssIn {
            if let found = formatter.date(from: value) { return newYorkISO(found) }
        }
        return nil
    }

    nonisolated(unsafe) static let plainISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoOut = formatter("yyyy-MM-dd'T'HH:mm:ssxxx")
    static let isoIn: [DateFormatter] = ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXX", "yyyy-MM-dd'T'HH:mmXX",
                                         "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd HH:mm:ssXXXXX"].map(formatter)
    static let shownOut = formatter("MMM d, h:mm a zzz")
    static let dayOut = formatter("yyyy-MM-dd")
    static let rssIn: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss",
    ].map { format in
        let f = formatter(format)
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = newYork
        f.dateFormat = format
        return f
    }
}

/// JSON helpers that read a value the way the Mac's parsers do: a number is never a Boolean.
enum JSONValue {
    static func object(_ data: Data, _ what: String) throws -> Any {
        guard let found = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw FeedFormatError("the \(what) answer isn't JSON")
        }
        return found
    }

    /// A finite number that isn't a Boolean, or nil.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let found = number.doubleValue
        return found.isFinite ? found : nil
    }

    /// Not a reading: not a number, or one of NWPS's missing values (-999, -9999) (dashboard/weather.py `_missing`).
    static func missing(_ value: Any?) -> Bool {
        guard let found = number(value) else { return true }
        return found <= -999
    }
}

extension String {
    /// The text's words joined by single spaces (Python's `" ".join(text.split())`).
    var collapsed: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `collapsed`, lowercased as Python's casefold does for the feeds' text.
    var folded: String { collapsed.lowercased() }
}

/// Python's `%g` and `,`-grouped integers, as the Mac's lines write numbers.
enum NumberText {
    static func g(_ value: Double) -> String { String(format: "%g", value) }
    static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }
    static func grouped(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }
}
