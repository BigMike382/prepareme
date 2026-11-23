import Foundation

/// Why typed text can't go in a cell of its column's kind (plan phase 7): fixed words, never the text.
public enum InputProblem: Error, Equatable, CustomStringConvertible, Sendable {
    case notANumber, notAWholeNumber, notADate, notAName

    public var description: String {
        switch self {
        case .notANumber: "Write a number, like 6 or 2.5."
        case .notAWholeNumber: "Write a whole number."
        case .notADate: "Write a date like 2026-11-15."
        case .notAName: "Pick one from the list."
        }
    }
}

/// How the editor shows a stored cell and stores typed text, in Grist's own way (the lists job reads it back:
/// readiness/grist.py): text as typed; a blank number as 0, a number cell never holding text; a date as seconds since
/// 1970 at UTC midnight, blank as NULL; a tick as 0 or 1; a reference as the row id it points at, blank as 0.
public enum InventoryValues {
    /// A cell as plain text: a whole number without ".0", text as stored, "" for NULL or a blob.
    public static func plain(_ value: SQLValue) -> String {
        switch value {
        case .null, .blob: ""
        case .text(let found): found
        case .int(let found): String(found)
        case .real(let found): number(found)
        }
    }

    /// A number as the lists job writes one (sheets.number_text): a whole number without ".0", any other to 15
    /// significant digits (Python's format ".15g"), so the joined check reads the same text on both sides.
    public static func number(_ found: Double) -> String {
        if found.isFinite, found.rounded() == found, abs(found) < 9e18 { return String(Int64(found)) }
        return String(format: "%.15g", found)
    }

    /// Days of a supply as a person counts them, as the Mac's lists write them (dashboard/readiness_view.py `_days`;
    /// remaining-findings plan, Task 8.3, F13, and the phase 8 review): whole days rounded down, thousands with commas;
    /// under a day, a tenth of one rounded down but never 0 while some is left. A sum's 2.9999999 counts as 3.
    public static func days(_ found: Double) -> String {
        guard found.isFinite else { return number(found) }
        let days = (found * 1e6).rounded() / 1e6
        if days > 0 && days < 1 { return String(format: "%.1f", max(0.1, ((days * 10 * 1e6).rounded() / 1e6).rounded(.down) / 10)) }
        let whole = Int64(days.rounded(.down))
        let digits = String(whole.magnitude)
        var grouped = ""
        for (n, digit) in digits.enumerated() {
            if n > 0 && (digits.count - n) % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        return whole < 0 ? "-" + grouped : grouped
    }

    /// The cell as the editor shows it; `names` are the shown names of a reference's target rows.
    public static func shown(_ value: SQLValue, in column: InventoryColumn, names: [Int64: String] = [:]) -> String {
        switch column.kind {
        case .bool: return value.whole == 1 ? "Yes" : ""
        case .date:
            guard let seconds = value.number, seconds.isFinite else { return plain(value) }
            return day(seconds) ?? plain(value)
        case .reference:
            guard let id = value.whole else { return plain(value) }
            return id == 0 ? "" : names[id] ?? "(deleted row \(id))"
        default: return plain(value)
        }
    }

    /// Typed text as the cell stores it, or why it can't go in.
    public static func stored(_ typed: String, in column: InventoryColumn,
                              names: [Int64: String] = [:]) -> Result<SQLValue, InputProblem> {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        switch column.kind {
        case .text, .choice, .other: return .success(.text(column.kind == .other ? typed : text))
        case .numeric:
            if text.isEmpty { return .success(.real(0)) }
            guard let found = parseNumber(text) else { return .failure(.notANumber) }
            return .success(.real(found))
        case .int:
            if text.isEmpty { return .success(.int(0)) }
            guard let found = parseNumber(text), found.rounded() == found, abs(found) < 9e15 else {
                return .failure(.notAWholeNumber)
            }
            return .success(.int(Int64(found)))
        case .bool:
            return .success(.int(["yes", "true", "x", "✓", "1"].contains(text.lowercased()) ? 1 : 0))
        case .date:
            if text.isEmpty { return .success(.null) }
            guard let seconds = parseDay(text) else { return .failure(.notADate) }
            return .success(.int(Int64(seconds)))  // as Grist stores a day
        case .reference:
            if text.isEmpty { return .success(.int(0)) }
            let hits = names.filter { InventoryFile.same($0.value, text) }.map(\.key).sorted()
            guard let first = hits.first else { return .failure(.notAName) }
            return .success(.int(first))
        }
    }

    /// "2.5", "1,045", "6" as a number; nil for anything else.
    public static func parseNumber(_ text: String) -> Double? {
        let plain = text.replacingOccurrences(of: ",", with: "")
        guard plain.range(of: #"^[+-]?(\d+(\.\d*)?|\.\d+)$"#, options: .regularExpression) != nil,
              let found = Double(plain), found.isFinite else { return nil }
        return found
    }

    static let utc = TimeZone(identifier: "UTC")!

    /// "YYYY-MM-DD" for seconds at a UTC day; nil out of range.
    public static func day(_ seconds: Double) -> String? {
        guard abs(seconds) < 1e11 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: seconds))
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Seconds since 1970 at UTC midnight of "2026-11-15" or "11/15/2026"; nil for anything else or a day that
    /// doesn't exist.
    public static func parseDay(_ text: String) -> Double? {
        let parts: [Int]
        if text.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
            parts = text.split(separator: "-").compactMap { Int($0) }
        } else if text.range(of: #"^\d{1,2}/\d{1,2}/\d{4}$"#, options: .regularExpression) != nil {
            let found = text.split(separator: "/").compactMap { Int($0) }
            parts = [found[2], found[0], found[1]]
        } else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let wanted = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard (1900...2200).contains(parts[0]), let date = calendar.date(from: wanted),
              calendar.dateComponents([.year, .month, .day], from: date) == wanted else { return nil }
        return date.timeIntervalSince1970
    }
}
