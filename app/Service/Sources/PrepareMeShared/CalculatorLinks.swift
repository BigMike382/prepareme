import Foundation

/// The calculators on the inventory's categories (step 8b; docs/plans/2026-10-20-step-8b-calculator-links.md; the
/// owner's table, 2026-10-20). The daily library's `household/calculator-links.json`, written by
/// packer/calculator_links.py from packer/calculator_links.toml (pinned by the shared fixture calculator-links.json),
/// lists for each of the lists' twelve categories the calculators shown at the top of it, some only when an item's
/// name holds one of a row's words. The reader is as strict as the writer, so a list of any other shape is refused and
/// the categories show no Calculators line.
///
/// The figures a link opens with are never here: they are the lists job's (`CalculatorFigures`, in supply.json), by
/// each calculator's own box ids, and travel in the link's `#` part (`fragment`), which never leaves the device. Each
/// calculator's own script fills a box only with a number in that box's range.
public struct CalculatorLinks: Equatable, Sendable {
    public static let path = "household/calculator-links.json"
    public static let format = 1
    /// The line's words (packer.calculator_links, pinned in both test suites)
    public static let line = "Calculators"
    /// Under a calculator the lists' fuel fills, when a matching row was left out for its unit (the owner's words,
    /// 2026-10-20)
    public static let propanePoundsOnly = "Only propane counted in pounds is included."
    public static let propanePage = "calc-propane.html"
    /// Step 8c, section 2: the generator's page takes the propane figure too, and the gasoline gallons
    public static let gasolineGallonsOnly = "Only gasoline counted in gallons is included."
    public static let generatorPage = "calc-generator.html"
    /// Step 8c, section 6: the firewood page's cords, when a firewood row was left out for its unit
    public static let firewoodCordsOnly = "Only firewood counted in cords is included."
    public static let firewoodPage = "calc-firewood.html"
    public static func filled(_ when: String) -> String { "Filled in from the inventory's count of \(when)." }

    public struct Calculator: Equatable, Hashable, Sendable {
        public let page, name: String
        public init(page: String, name: String) {
            self.page = page
            self.name = name
        }
    }

    public struct Row: Equatable, Sendable {
        public let category: String
        public let calculators: [Calculator]
        public let when: [String]
        public init(category: String, calculators: [Calculator], when: [String]) {
            self.category = category
            self.calculators = calculators
            self.when = when
        }
    }

    public let rows: [Row]

    public enum Problem: Error, Equatable, Sendable { case notTheShape }

    public init(rows: [Row]) { self.rows = rows }

    public init(_ data: Data) throws {
        guard GuideTopics.keysAreOnceAndNumbersWhole(data),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(top.keys) == ["format", "rows"],
              GuideTopics.count(top["format"]) == Self.format,
              let rows = top["rows"] as? [Any]
        else { throw Problem.notTheShape }
        self.rows = try rows.map(Self.row)
    }

    static func row(_ row: Any) throws -> Row {
        guard let object = row as? [String: Any], Set(object.keys) == ["category", "calculators", "when"],
              let category = object["category"] as? String, ToBuyList.groups.dropLast().contains(category),
              let list = object["calculators"] as? [Any], !list.isEmpty,
              let words = object["when"] as? [String], Set(words).count == words.count, words.allSatisfy(Self.isWord)
        else { throw Problem.notTheShape }
        let calculators = try list.map { item -> Calculator in
            guard let found = item as? [String: Any], Set(found.keys) == ["page", "name"],
                  let page = found["page"] as? String, GuideTopics.matches(page, "calc-[a-z0-9]+(-[a-z0-9]+)*\\.html"),
                  let name = found["name"] as? String, GuideTopics.named(name)
            else { throw Problem.notTheShape }
            return Calculator(page: page, name: name)
        }
        guard Set(calculators.map(\.page)).count == calculators.count else { throw Problem.notTheShape }
        return Row(category: category, calculators: calculators, when: words)
    }

    /// packer.calculator_links.WORD: lowercase letters and digits, words joined by one space or hyphen, 3 or more.
    static func isWord(_ word: String) -> Bool {
        word.count >= 3 && GuideTopics.matches(word, "[a-z0-9]+([ -][a-z0-9]+)*")
    }

    /// The calculators listed at the top of `group` (a category's Counts as, one of the twelve in any case), in the
    /// table's order, each once; a row with words only when one of `itemNames` holds one (GuideLinks.matches).
    public func shown(group: String, itemNames: [String]) -> [Calculator] {
        let wanted = group.trimmingCharacters(in: .whitespaces)
        var found: [Calculator] = []
        for row in rows where row.category.caseInsensitiveCompare(wanted) == .orderedSame {
            if !row.when.isEmpty, !itemNames.contains(where: { GuideLinks.matches($0, row.when) }) { continue }
            for calculator in row.calculators where !found.contains(where: { $0.page == calculator.page }) {
                found.append(calculator)
            }
        }
        return found
    }

    /// One group's line: each calculator with the `#` part it opens with ("" for none), and the notes under it: when
    /// the count was made (when any link carries figures), the propane line (when Propane Runtime or the generator is
    /// shown and a propane row was left out for its unit), the gasoline line (the generator, a gasoline row left
    /// out) and the firewood line (Firewood for a Winter, a firewood row left out). Empty links: no line.
    public struct Line: Equatable, Sendable {
        public struct Link: Equatable, Sendable {
            public let calculator: Calculator
            public let fragment: String
        }

        public let links: [Link]
        public let notes: [String]
    }

    public func line(group: String, itemNames: [String], figures: CalculatorFigures?) -> Line {
        let shown = shown(group: group, itemNames: itemNames)
        let links = shown.map { Line.Link(calculator: $0, fragment: Self.fragment(figures?.pages[$0.page])) }
        var notes: [String] = []
        if let figures, links.contains(where: { !$0.fragment.isEmpty }), let when = figures.countedWords {
            notes.append(Self.filled(when))
        }
        if figures?.propaneWeigh == true,
           shown.contains(where: { $0.page == Self.propanePage || $0.page == Self.generatorPage }) {
            notes.append(Self.propanePoundsOnly)
        }
        if figures?.gasolineWeigh == true, shown.contains(where: { $0.page == Self.generatorPage }) {
            notes.append(Self.gasolineGallonsOnly)
        }
        if figures?.firewoodWeigh == true, shown.contains(where: { $0.page == Self.firewoodPage }) {
            notes.append(Self.firewoodCordsOnly)
        }
        return Line(links: links, notes: notes)
    }

    /// The link's `#` part for one calculator's figures, its boxes in name order ("days=30&dog=50&people=4"); only
    /// box ids of lowercase letters and numbers the pages could read; "" for none (packer.calculator_links.fragment).
    public static func fragment(_ figures: [String: Double]?) -> String {
        guard let figures else { return "" }
        return figures.keys.sorted().compactMap { box -> String? in
            guard GuideTopics.matches(box, "[a-z]{1,20}"), let value = figures[box], let text = numberText(value)
            else { return nil }
            return "\(box)=\(text)"
        }.joined(separator: "&")
    }

    /// A whole number without ".0", else the shortest form that reads back (Python's repr gives the same); nil for
    /// anything below zero, not finite, or only writable with an exponent.
    public static func numberText(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        if value == value.rounded(.towardZero), value < 1e15 { return String(Int64(value)) }
        let text = "\(value)"
        return GuideTopics.matches(text, "[0-9]+\\.[0-9]+") ? text : nil
    }
}

/// The lists job's figures for the calculators (readiness/appsupply.py `calculator_figures`, in supply.json beside the
/// shares): when it counted them, each filled calculator's figures by its box ids, and whether a fuel's figure left
/// rows out: `propaneWeigh`, `gasolineWeigh` and `firewoodWeigh` keep the keys' pattern and mean "a matching row was
/// left out for its unit" (the owner's rule, 2026-10-20; a count from before step 8c, without `gasoline_weigh` or
/// `firewood_weigh`, reads false).
public struct CalculatorFigures: Codable, Equatable, Sendable {
    public let counted: String
    public let pages: [String: [String: Double]]
    public let propaneWeigh: Bool
    public let gasolineWeigh: Bool
    public let firewoodWeigh: Bool

    enum CodingKeys: String, CodingKey {
        case counted, pages
        case propaneWeigh = "propane_weigh"
        case gasolineWeigh = "gasoline_weigh"
        case firewoodWeigh = "firewood_weigh"
    }

    public init(counted: String, pages: [String: [String: Double]], propaneWeigh: Bool, gasolineWeigh: Bool = false,
                firewoodWeigh: Bool = false) {
        self.counted = counted
        self.pages = pages
        self.propaneWeigh = propaneWeigh
        self.gasolineWeigh = gasolineWeigh
        self.firewoodWeigh = firewoodWeigh
    }

    public init(from decoder: Decoder) throws {
        let found = try decoder.container(keyedBy: CodingKeys.self)
        counted = try found.decode(String.self, forKey: .counted)
        pages = try found.decode([String: [String: Double]].self, forKey: .pages)
        propaneWeigh = try found.decode(Bool.self, forKey: .propaneWeigh)
        gasolineWeigh = try found.decodeIfPresent(Bool.self, forKey: .gasolineWeigh) ?? false
        firewoodWeigh = try found.decodeIfPresent(Bool.self, forKey: .firewoodWeigh) ?? false
    }

    /// When the count was made, as the line says it in the household's time ("Oct 20, 2:37 AM"); nil when unreadable.
    public var countedWords: String? {
        guard let date = ISO8601DateFormatter().date(from: counted) else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "America/New_York")
        format.dateFormat = "MMM d, h:mm a"
        return format.string(from: date)
    }
}
