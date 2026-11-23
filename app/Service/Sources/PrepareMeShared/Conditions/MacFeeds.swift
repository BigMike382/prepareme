import Foundation

/// The feeds the phone reads exactly as the Mac does, ported line for line from `dashboard/weather.py` (river gauges,
/// the Atlantic outlook and storms) and `dashboard/local.py` (the state's power outages and evacuations),
/// with their fixed words. A reader that can't read an answer throws FeedFormatError in fixed words, so a read that
/// failed shows as "couldn't read", never as "none".
///
/// The shared cases (dashboard/tests/fixtures/phone-cases.json, Mac-side) are the Mac's own readers' output on
/// the recorded samples and on made-up answers; the tests hold these ports to them item for item.
public enum MacFeeds {
    // dashboard/weather.py's fixed copy.
    public static let stormsNone = "No Atlantic storms"
    public static let gaugeLabel = "NWS river gauges"
    public static let noForecast = "No forecast is issued for this gauge."
    public static let noReading = "no current reading"
    public static let impactsHeading = "The National Weather Service's flood impact statements for this gauge:"
    public static let atThisLevel = "At this level: {statement}"
    public static let atForecastLevel = "At the level forecast for {time} ({stage} ft): {statement}"
    public static let crestLine = "Forecast crest: {stage} ft"
    public static let stormKinds = ["TD": "Tropical Depression", "STD": "Subtropical Depression", "TS": "Tropical Storm",
                                    "HU": "Hurricane", "STS": "Subtropical Storm", "PTC": "Post-tropical Cyclone",
                                    "TY": "Typhoon", "PC": "Potential Tropical Cyclone"]
    public static let floodCategories = ["action", "minor", "moderate", "major"]
    public static let categoryWords = ["no_flooding": "no flooding", "action": "action stage",
                                       "minor": "minor flooding", "moderate": "moderate flooding",
                                       "major": "major flooding"]
    static let oldReading: TimeInterval = 3 * 3600
    static let notCurrent = "fcst_not_current"

    // dashboard/local.py's fixed copy.
    public static let evacNotHome = "Doesn't name {county} County."
    public static let evacNamesHome = "Names {county} County."
    public static let evacNone = "No evacuations are ordered"
    public static let outagesHome = "{n} outages reported in {county} County"
    public static let outagesNone = "No outages reported in {county} County"
    public static let outagesStatewide = "Statewide: {n}"
    public static let evacHomeCode = "EVAC.HOME"
    static let noOrders = "No Evacuations are ordered"

    // MARK: Rivers

    /// The gauge's reading (weather.py `gauge`): its stage and flood category, its flood stage, and the impact
    /// statements for its stage and for a current forecast still ahead; a warning at action stage and above.
    public static func gauge(_ data: Data, now: Date) throws -> [ConditionItem] {
        try wrapped("gauge record") {
            guard let record = try JSONValue.object(data, "gauge") as? [String: Any],
                  let rawName = record["name"] as? String, !rawName.collapsed.isEmpty else {
                throw FeedFormatError("the gauge record has no name")
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let service = record["inService"] as? [String: Any], let enabled = service["enabled"] as? NSNumber,
               CFGetTypeID(enabled) == CFBooleanGetTypeID(), !enabled.boolValue {
                let message = (service["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return [ConditionItem(message.isEmpty ? "\(name): out of service" : "\(name): out of service: \(message)",
                                      flag: ConditionItem.unread)]
            }
            let status = record["status"] as? [String: Any]
            guard let observed = status?["observed"] as? [String: Any] else {
                throw FeedFormatError("the gauge record has no status.observed object")
            }
            try inFeet(observed["primaryUnit"])
            let moment = ConditionTime.moment(observed["validTime"])
            guard !JSONValue.missing(observed["primary"]), let stage = JSONValue.number(observed["primary"]),
                  let moment else {
                return [ConditionItem("\(name): \(noReading).", flag: ConditionItem.unread)]
            }
            let category = Self.category(observed, record, stage)
            let words = categoryWords[category]
                ?? nonEmpty(category.replacingOccurrences(of: "_", with: " ").collapsed) ?? "flood category not given"
            var text = "\(name): \(NumberText.oneDecimal(stage)) ft, \(words)."
            if let minor = categoryStages(record)["minor"] {
                text += " Flood stage \(NumberText.g(minor)) ft."
            }
            let old = now.timeIntervalSince(moment) > oldReading
            if old { text += " (no report since \(ConditionTime.shown(moment)))" }
            let flagged = floodCategories.contains(category)
            // A stale reading is no all-clear, but one at flood stage keeps its warning.
            let flag = flagged ? ConditionItem.warn : old ? ConditionItem.unread : ""
            return [ConditionItem(text, when: ConditionTime.newYorkISO(moment),
                                  detail: try impacts(record, stage, status ?? [:], now), flag: flag,
                                  code: flagged ? category : "")]
        }
    }

    /// The highest forecast stage still ahead of `now` and its time (weather.py `crest`).
    public static func crest(_ data: Data, now: Date) throws -> [ConditionItem] {
        try wrapped("gauge forecast") {
            let answer = try JSONValue.object(data, "gauge forecast") as? [String: Any]
            guard let points = answer?["data"] as? [Any] else {
                throw FeedFormatError("the gauge forecast has no data list")
            }
            try inFeet(answer?["primaryUnits"])
            var best: (Double, Date)?
            for case let point as [String: Any] in points {
                guard !JSONValue.missing(point["primary"]), let stage = JSONValue.number(point["primary"]),
                      let moment = ConditionTime.moment(point["validTime"]), moment >= now else { continue }
                if best == nil || stage > best!.0 { best = (stage, moment) }
            }
            guard let best else { return [ConditionItem(noForecast)] }
            return [ConditionItem(crestLine.replacingOccurrences(of: "{stage}", with: NumberText.oneDecimal(best.0)),
                                  when: ConditionTime.newYorkISO(best.1))]
        }
    }

    static func categoryStages(_ record: [String: Any]) -> [String: Double] {
        let categories = (record["flood"] as? [String: Any])?["categories"] as? [String: Any]
        var stages: [String: Double] = [:]
        for name in floodCategories {
            let stage = (categories?[name] as? [String: Any])?["stage"]
            if !JSONValue.missing(stage), let found = JSONValue.number(stage) { stages[name] = found }
        }
        return stages
    }

    static func category(_ observed: [String: Any], _ record: [String: Any], _ stage: Double) -> String {
        if let given = observed["floodCategory"] as? String,
           !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return given.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let stages = categoryStages(record)
        let reached = floodCategories.filter { stages[$0].map { stage >= $0 } ?? false }
        return reached.last ?? (stages.isEmpty ? "" : "no_flooding")
    }

    static func inFeet(_ unit: Any?) throws {
        if unit == nil || unit is NSNull || (unit as? String) == "" { return }
        guard let text = unit as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ft" else {
            throw FeedFormatError("the gauge's stage isn't stated in feet")
        }
    }

    static func impacts(_ record: [String: Any], _ stage: Double, _ status: [String: Any], _ now: Date) throws -> String {
        let listed: [(Double, String)] = ((record["flood"] as? [String: Any])?["impacts"] as? [Any] ?? []).compactMap {
            guard let impact = $0 as? [String: Any], !JSONValue.missing(impact["stage"]),
                  let level = JSONValue.number(impact["stage"]), let statement = impact["statement"] as? String,
                  !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (level, statement.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var lines: [String] = []
        if let found = statement(listed, stage) {
            lines.append(atThisLevel.replacingOccurrences(of: "{statement}", with: found))
        }
        if let ahead = status["forecast"] as? [String: Any], ahead["floodCategory"] as? String != notCurrent {
            if !JSONValue.missing(ahead["primary"]), let level = JSONValue.number(ahead["primary"]),
               let at = ConditionTime.moment(ahead["validTime"]), at >= now {
                try inFeet(ahead["primaryUnit"])
                if let found = statement(listed, level) {
                    lines.append(atForecastLevel.replacingOccurrences(of: "{time}", with: ConditionTime.shown(at))
                        .replacingOccurrences(of: "{stage}", with: NumberText.oneDecimal(level))
                        .replacingOccurrences(of: "{statement}", with: found))
                }
            }
        }
        return lines.isEmpty ? "" : ([impactsHeading] + lines).joined(separator: "\n")
    }

    static func statement(_ listed: [(Double, String)], _ stage: Double) -> String? {
        // Python's max keeps the first of equal levels.
        var best: (Double, String)?
        for pair in listed where pair.0 <= stage {
            if best == nil || pair.0 > best!.0 { best = pair }
        }
        return best?.1
    }

    // MARK: Hurricanes

    static let chance = try! NSRegularExpression(pattern: "Formation chance through 7 days\\.\\.\\.(?:medium|high)")
    static let br = try! NSRegularExpression(pattern: "<br\\s*/?>", options: [.caseInsensitive])

    /// Each outlook in NHC's RSS (weather.py `tropical_outlook`): its text with <br /> as line breaks, its issue
    /// time, and a warning when a system's 7-day formation chance is medium or high. A document that declares a
    /// document type or an entity is refused.
    public static func tropicalOutlook(_ data: Data) throws -> [ConditionItem] {
        let reader = RSSReader()
        guard reader.read(data) else {
            throw FeedFormatError(reader.declared ? "the tropical outlook declares a document type, which the feed never does"
                                                  : "the tropical outlook isn't readable XML")
        }
        guard reader.root == "rss" else { throw FeedFormatError("the tropical outlook isn't RSS") }
        var items: [ConditionItem] = []
        for entry in reader.items {
            let description = entry.description
            guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let broken = br.stringByReplacingMatches(in: description, range: NSRange(description.startIndex..., in: description),
                                                     withTemplate: "\n")
            let text = broken.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
                .joined(separator: "\n")
            let flagged = chance.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            items.append(ConditionItem(text, when: ConditionTime.rss(entry.pubDate), flag: flagged ? ConditionItem.warn : ""))
        }
        guard !items.isEmpty else { throw FeedFormatError("the tropical outlook holds no item with a description") }
        return items
    }

    /// Each Atlantic storm (an id starting "al") as a warning: its kind and name, linked to its public advisory
    /// (weather.py `storms`).
    public static func storms(_ data: Data) throws -> [ConditionItem] {
        try wrapped("storms answer") {
            guard let active = (try JSONValue.object(data, "storms") as? [String: Any])?["activeStorms"] as? [Any] else {
                throw FeedFormatError("the storms answer has no activeStorms list")
            }
            var items: [ConditionItem] = []
            for storm in active {
                guard let storm = storm as? [String: Any] else {
                    throw FeedFormatError("an activeStorms entry isn't an object")
                }
                guard let sid = storm["id"] as? String, sid.lowercased().hasPrefix("al") else { continue }
                let code = storm["classification"] as? String ?? ""
                let name = storm["name"] as? String ?? ""
                let url = (storm["publicAdvisory"] as? [String: Any])?["url"] as? String
                let link = url.flatMap { $0.hasPrefix("https://") || $0.hasPrefix("http://") ? $0 : nil }
                items.append(ConditionItem("\(stormKinds[code] ?? code) \(name)".collapsed, link: link,
                                           flag: ConditionItem.warn))
            }
            return items
        }
    }

    // MARK: The state's outages and evacuations (their addresses and counties from ConditionsArea)

    static let count = try! NSRegularExpression(pattern: "^(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)$")
    static let noOrdersPattern = try! NSRegularExpression(
        pattern: "^(there are )?no evacuations? (orders? )?(are |have been )?(currently )?(ordered|in effect|issued)( at this time)?[.!]?$")

    /// Home county's outages, or a line saying none are reported; then the statewide total (local.py `outages`). Only
    /// the table it knows is read: its County and # Outages header, and every other row Statewide Outages or one of
    /// the state's counties (`area`'s list); anything else throws.
    public static func outages(_ data: Data, county: String, area: ConditionsArea) throws -> [ConditionItem] {
        try wrapped("outage page") {
            guard let rows = HTMLTable.rows(String(decoding: data, as: UTF8.self), id: "countyTable") else {
                throw FeedFormatError("the outage page has no county table")
            }
            var home: Int?, statewide: Int?
            var header = false, unknown = false
            for cells in rows {
                let name = cells.first?.folded ?? ""
                if name == "county" {
                    guard cells.count >= 2, cells[1].folded == "# outages" else {
                        throw FeedFormatError("the outage table's columns aren't County and # Outages")
                    }
                    header = true
                } else if name == "statewide outages" && statewide == nil {
                    statewide = try outageCount(cells)
                } else if !area.folded.contains(name) {
                    unknown = true
                } else if name == county.folded && home == nil {
                    home = try outageCount(cells)
                }
            }
            guard let statewide else { throw FeedFormatError("the outage table has no Statewide Outages row") }
            guard header else { throw FeedFormatError("the outage table has no County and # Outages header") }
            guard !unknown else { throw FeedFormatError("the outage table holds a row that isn't one of the state's counties") }
            let first = (home ?? 0) > 0
                ? outagesHome.replacingOccurrences(of: "{n}", with: NumberText.grouped(home!))
                    .replacingOccurrences(of: "{county}", with: county)
                : outagesNone.replacingOccurrences(of: "{county}", with: county)
            return [ConditionItem(first),
                    ConditionItem(outagesStatewide.replacingOccurrences(of: "{n}", with: NumberText.grouped(statewide)))]
        }
    }

    static func outageCount(_ cells: [String]) throws -> Int {
        let text = cells.count > 1 ? cells[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard count.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
              let found = Int(text.replacingOccurrences(of: ",", with: "")) else {
            throw FeedFormatError("the outage table holds a count that isn't a whole number")
        }
        return found
    }

    /// Whether outages() found any in home county (local.py `home_outage`): none versus some, never the count.
    public static func homeOutage(_ items: [ConditionItem]) -> Bool {
        guard let first = items.first else { return false }
        return !first.text.hasPrefix(outagesNone.components(separatedBy: "{county}")[0])
    }

    /// No items when the order table says no evacuations are ordered; otherwise the table's text as one warning,
    /// titled by its first other line, then a line saying whether it names home's county as a capitalized word, the
    /// warning carrying EVAC.HOME when it does (local.py `evacuations`).
    public static func evacuations(_ data: Data, county: String) throws -> [ConditionItem] {
        try wrapped("evacuation answer") {
            guard let answer = try JSONValue.object(data, "evacuation") as? String else {
                throw FeedFormatError("the evacuation answer isn't a JSON string")
            }
            guard let rows = HTMLTable.rows(answer, id: "countyTable") else {
                throw FeedFormatError("the evacuation answer has no county table")
            }
            let lines = rows.flatMap { $0 }.flatMap { $0.components(separatedBy: "\n") }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { throw FeedFormatError("the evacuation answer's county table is empty") }
            let text = lines.joined(separator: "\n")
            let orders = lines.filter { !noOrdersLine($0) }
            if orders.isEmpty || noOrdersLine(text) { return [] }
            let home = namesCounty(text, county)
            return [ConditionItem(orders[0], detail: text, flag: ConditionItem.warn, code: home ? evacHomeCode : ""),
                    ConditionItem((home ? evacNamesHome : evacNotHome).replacingOccurrences(of: "{county}", with: county))]
        }
    }

    static func noOrdersLine(_ text: String) -> Bool {
        let folded = text.folded
        return folded == noOrders.folded
            || noOrdersPattern.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) != nil
    }

    /// Whether `text` holds the county's name as a whole word (words, for a two-word name) starting with a capital
    /// (local.py `names_county`).
    public static func namesCounty(_ text: String, _ county: String) -> Bool {
        let words = county.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty, let pattern = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])" + words.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive]) else { return false }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
            guard let range = Range(match.range, in: text) else { return false }
            return text[range].first?.isUppercase == true
        }
    }

    // MARK: Shared

    static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// Runs a reader, turning any error but FeedFormatError into fixed words, as the Mac's `as_format_errors` does.
    static func wrapped<T>(_ what: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as FeedFormatError {
            throw error
        } catch {
            throw FeedFormatError("the \(what) holds a value that can't be read")
        }
    }
}

/// An RSS document's root element and each <item>'s description and pubDate (its direct children), read with
/// Foundation's XMLParser, which never fetches anything. A document type or entity declaration is refused.
final class RSSReader: NSObject, XMLParserDelegate {
    struct Entry { var description = ""; var pubDate: String? }
    var root: String?
    var items: [Entry] = []
    var declared = false
    private var path: [String] = []
    private var current: Entry?
    private var field: String?
    private var text = ""

    func read(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(4096), as: UTF8.self).uppercased()
        if head.contains("<!DOCTYPE") || head.contains("<!ENTITY") {
            declared = true
            return false
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        return parser.parse() && !declared
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if root == nil { root = name }
        if name == "item" { current = Entry() }
        if current != nil, path.last == "item", name == "description" || name == "pubDate" {
            field = name
            text = ""
        }
        path.append(name)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        path.removeLast()
        if name == field, path.last == "item" {
            if name == "description" { current?.description = text } else { current?.pubDate = text }
            field = nil
        }
        if name == "item", let found = current {
            items.append(found)
            current = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil, path.last == field { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if field != nil, path.last == field { text += String(decoding: block, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        declared = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
                systemID: String?) {
        declared = true
        parser.abortParsing()
    }
}
