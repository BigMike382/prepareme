import Foundation

/// Reading a package's best-by date from the lines of text the camera read (plan 2026-10-28, "The rules"). It prefers
/// refusing to guessing: a labeled line wins, a packed or lot line is never the expiry, bare digit runs aren't read,
/// day and month that could be either way round ask, and a date too far back or ahead is refused as a misread. It
/// never fills a date: the screen shows what it returns and keeps the date only when the person taps to use it.
public enum PackageDate {
    public static let nothingFound = "Couldn't find a date. Move closer, or type it."
    public static let misread = "That date can't be a best-by date, so it may be misread. Move closer, or type it."
    public static let tooMany = "More than two dates here. Point at just the best-by date."
    public static let noLabel = "No 'best by' printed next to it: check it's the right date."
    public static let firstOfTheMonth = "Only the month is printed, so this is the 1st of it."
    public static let eitherWayRound = "The day and month could be either way round. Which is it?"
    public static let twoDates = "Two dates are printed. Which is the best-by date?"
    public static let useThisDate = "Use this date"
    public static let tryAgain = "Try again"

    public struct Day: Hashable, Comparable, Sendable {
        public let year: Int
        public let month: Int
        public let day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        /// "March 15, 2027".
        public var words: String { "\(monthNames[month - 1]) \(day), \(year)" }

        public static func < (a: Day, b: Day) -> Bool {
            (a.year, a.month, a.day) < (b.year, b.month, b.day)
        }
    }

    public struct Found: Equatable, Sendable {
        public let day: Day
        /// A "best by" (or another of rule 1's words) was printed on its line or the line above.
        public let labeled: Bool
        /// Only a month and year were printed: the day is the 1st (phase 0, ruling 2).
        public let monthOnly: Bool

        public init(day: Day, labeled: Bool, monthOnly: Bool) {
            self.day = day
            self.labeled = labeled
            self.monthOnly = monthOnly
        }

        /// The confirm card's line: "Best by March 15, 2027".
        public var headline: String { "Best by \(day.words)" }

        public var notes: [String] {
            (labeled ? [] : [noLabel]) + (monthOnly ? [firstOfTheMonth] : [])
        }
    }

    public enum Reading: Equatable, Sendable {
        case found(Found)
        /// Two buttons naming each date in words, earlier first, under the question.
        case choice(Day, Day, question: String)
        case refused(String)
    }

    /// `today` is passed in so the range check (rule 6) doesn't depend on the day the tests run.
    public static func read(_ lines: [String], today: Date = Date(), timeZone: TimeZone = .current) -> Reading {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let now = cal.dateComponents([.year, .month, .day], from: today)
        let (ty, tm, td) = (now.year ?? 0, now.month ?? 1, now.day ?? 1)
        let earliest = Day(year: ty - 2, month: tm, day: td)
        let latest = Day(year: ty + 30, month: tm, day: td)

        var readings: [Printed] = []
        var labelAbove = false
        for line in lines {
            let upper = line.uppercased()
            let parts = words(upper)
            if parts.contains(where: neverExpiry.contains) {
                labelAbove = false
                continue
            }
            let labeled = hasLabel(parts)
            let found = dates(upper)
            readings += found.map { Printed(days: $0.days, monthOnly: $0.monthOnly, labeled: labeled || labelAbove) }
            labelAbove = labeled && found.isEmpty
        }

        let inRange = readings.filter { $0.days.allSatisfy { $0 >= earliest && $0 <= latest } }
        let pool = inRange.contains(where: \.labeled) ? inRange.filter(\.labeled) : inRange
        if pool.isEmpty { return .refused(readings.isEmpty ? nothingFound : misread) }
        let days = Set(pool.flatMap(\.days)).sorted()
        switch days.count {
        case 1:
            let monthOnly = pool.allSatisfy(\.monthOnly)
            return .found(Found(day: days[0], labeled: pool[0].labeled, monthOnly: monthOnly))
        case 2:
            return .choice(days[0], days[1], question: pool.contains { $0.days.count == 2 } ? eitherWayRound : twoDates)
        default:
            return .refused(tooMany)
        }
    }

    // MARK: - Rule 1: the words on a line

    private struct Printed {
        /// One day, or two when day and month could be either way round (rule 4).
        let days: [Day]
        let monthOnly: Bool
        let labeled: Bool
    }

    private static let labels: [[String]] = [
        ["BEST", "BY"], ["BEST", "BEFORE"], ["BEST", "IF", "USED", "BY"], ["USE", "BY"],
        ["BB"], ["BBD"], ["EXP"], ["EXPIRES"], ["EXPIRY"],
    ]
    private static let neverExpiry: Set<String> = ["PACKED", "PACK", "MFG", "MFD", "PROD", "MADE", "LOT"]

    /// The line's words: dots dropped ("B.B." is BB), other punctuation a space, and letters split from digits
    /// ("EXP03/2027", "BB15MAR27").
    private static func words(_ upper: String) -> [String] {
        var out: [String] = []
        var word = ""
        var lastIsDigit: Bool?
        for ch in upper where ch != "." {
            let isLetter = ch.isLetter, isDigit = ch.isNumber
            if isLetter || isDigit {
                if let last = lastIsDigit, last != isDigit, !word.isEmpty { out.append(word); word = "" }
                word.append(ch)
                lastIsDigit = isDigit
            } else {
                if !word.isEmpty { out.append(word); word = "" }
                lastIsDigit = nil
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    /// One of the labels, its words side by side and in order.
    private static func hasLabel(_ words: [String]) -> Bool {
        labels.contains { label in
            words.indices.contains { i in Array(words[i...].prefix(label.count)) == label }
        }
    }

    // MARK: - Rules 2, 3 and 5: the formats read

    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August",
                                     "September", "October", "November", "December"]
    private static let month =
        "(?<![A-Z])(JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUNE?|JULY?|AUG(?:UST)?|SEPT?(?:EMBER)?"
        + "|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?)(?![A-Z])"
    private static let year = "(\\d{4}|\\d{2})(?!\\d)"
    private static let gap = "[ ./,-]"

    private enum Shape { case ymd, eitherWay, monthDayYear, dayMonthYear, monthNameYear, monthYear }

    /// Most specific first: each match is blanked out before the next shape looks, so "03-15-27" is never also read
    /// as March 2015. Dots only separate a whole date, never a month and year ("$10.25" isn't October 2025). A run
    /// of digits with no separator ("031527") matches no shape: it's too often a maker's code.
    private static let shapes: [(Shape, NSRegularExpression)] = {
        let ymd = "(?<!\\d)(\\d{4})([/. -])(\\d{1,2})\\2(\\d{1,2})(?!\\d)"
        let eitherWay = "(?<!\\d)(\\d{1,2})([/. -])(\\d{1,2})\\2" + year
        let monthDayYear = month + gap + "*(\\d{1,2})" + gap + "+" + year
        let dayMonthYear = "(?<!\\d)(\\d{1,2})" + gap + "*" + month + gap + "*" + year
        let monthNameYear = month + gap + "*" + year
        let monthYear = "(?<!\\d)(\\d{1,2})[/ -]" + year
        let patterns: [(Shape, String)] = [(.ymd, ymd), (.eitherWay, eitherWay), (.monthDayYear, monthDayYear),
                                           (.dayMonthYear, dayMonthYear), (.monthNameYear, monthNameYear),
                                           (.monthYear, monthYear)]
        return patterns.map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }
    }()

    private static func dates(_ upper: String) -> [(days: [Day], monthOnly: Bool)] {
        let text = NSMutableString(string: upper)
        var out: [(days: [Day], monthOnly: Bool)] = []
        for (shape, regex) in shapes {
            for match in regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let part = { (i: Int) in text.substring(with: match.range(at: i)) }
                let number = { (i: Int) in Int(part(i)) ?? 0 }
                let days: [Day?]
                switch shape {
                case .ymd: days = [day(number(1), number(3), number(4))]
                case .eitherWay:
                    let (a, b, y) = (number(1), number(3), fullYear(part(4)))
                    days = a == b ? [day(y, a, b)] : [day(y, a, b), day(y, b, a)]
                case .monthDayYear: days = [day(fullYear(part(3)), monthNumber(part(1)), number(2))]
                case .dayMonthYear: days = [day(fullYear(part(3)), monthNumber(part(2)), number(1))]
                case .monthNameYear: days = [day(fullYear(part(2)), monthNumber(part(1)), 1)]
                case .monthYear: days = [day(fullYear(part(2)), number(1), 1)]
                }
                text.replaceCharacters(in: match.range, with: String(repeating: "#", count: match.range.length))
                // a match that names no real day reads as nothing, but stays blanked
                let real = days.compactMap { $0 }
                if !real.isEmpty { out.append((real, shape == .monthNameYear || shape == .monthYear)) }
            }
        }
        return out
    }

    /// Rule 3: a two-digit year is 20xx.
    private static func fullYear(_ digits: String) -> Int {
        let n = Int(digits) ?? 0
        return digits.count == 2 ? 2000 + n : n
    }

    private static func monthNumber(_ name: String) -> Int {
        (monthNames.firstIndex { $0.uppercased().hasPrefix(String(name.prefix(3))) } ?? -1) + 1
    }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Day? {
        guard (1...12).contains(m), d >= 1 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let first = cal.date(from: DateComponents(year: y, month: m, day: 1)),
              let length = cal.range(of: .day, in: .month, for: first)?.count, d <= length else { return nil }
        return Day(year: y, month: m, day: d)
    }
}
