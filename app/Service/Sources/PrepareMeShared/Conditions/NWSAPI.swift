import Foundation

/// The phone's own reading of api.weather.gov (plan phase 5; the owner chose the documented API for the phones,
/// 2026-10-12): active alerts for a zone and county, a zone's forecast, and the lookup that says which zone a spot is
/// in (D2, "here"). The Mac reads the alerts page and MapClick instead, so these readers have no Mac counterpart; the rules
/// they feed (which alerts are in force, which start event mode) are the Mac's, through VTEC (NWSVTEC).
///
/// Each fails loud, never toward "none": an answer that isn't the shape the API documents throws FeedFormatError in
/// fixed words, so the block shows "couldn't read" with its last good reading.
public enum NWSAPI {
    public static let host = "api.weather.gov"
    public static let alertsNone = "No active weather alerts for home"  // dashboard/weather.py ALERTS_NONE
    public static let hereAlertsNone = "No active weather alerts where the phone is"

    public static func alertsURL(_ codes: [String]) -> URL {
        URL(string: "https://\(host)/alerts/active?zone=\(codes.joined(separator: ","))")!
    }

    public static func forecastURL(zone: String) -> URL {
        URL(string: "https://\(host)/zones/forecast/\(zone)/forecast")!
    }

    /// The lookup for a spot, its coordinates to 2 decimals (about a kilometer), as the Mac rounds the laptop's.
    public static func pointsURL(latitude: Double, longitude: Double) -> URL {
        URL(string: String(format: "https://%@/points/%.2f,%.2f", host, latitude, longitude))!
    }

    /// Each alert in force or ended, one item per alert: its NWS headline (else its headline, else its event), its
    /// description and instruction as the detail, a warning. Alerts that aren't "Actual" and Cancel messages are left
    /// out, as the phase 1 counter does (NWSAlerts). `code`, `vtec` and `expires` follow the Mac's VTEC rules; an
    /// alert without VTEC takes the API's own `ends`, else `expires`. Alerts with the same headline and detail are one
    /// product the API split by hazard (a Freeze Warning and a Frost Advisory in one statement, F-062): they are shown
    /// once, as the Mac's page shows a product once, with every one of their VTEC lines, so the code is the warning's
    /// and never only the advisory's.
    public static func alerts(_ data: Data) throws -> [ConditionItem] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeedFormatError("the alerts answer isn't JSON")
        }
        guard top["type"] as? String == "FeatureCollection", let features = top["features"] as? [Any] else {
            throw FeedFormatError("the alerts answer isn't a FeatureCollection")
        }
        var items: [ConditionItem] = []
        var merged: [[NWSVTEC.Line]] = []
        var at: [String: Int] = [:]
        for feature in features {
            guard let properties = (feature as? [String: Any])?["properties"] as? [String: Any],
                  let status = properties["status"] as? String, let messageType = properties["messageType"] as? String
            else { throw FeedFormatError("an alert has no properties, status or message type") }
            let lines = try vtecLines(properties["parameters"])
            guard status == "Actual", messageType != "Cancel" else { continue }
            let parsed = try lines.map { line -> NWSVTEC.Line in
                guard let found = NWSVTEC.parse(line) else { throw FeedFormatError("an alert's VTEC line can't be read") }
                return found
            }
            let parameters = properties["parameters"] as? [String: Any]
            let nwsHeadline = (parameters?["NWSheadline"] as? [Any])?.first as? String
            let title = [nwsHeadline, properties["headline"] as? String, properties["event"] as? String]
                .compactMap { $0?.collapsed }.first { !$0.isEmpty }
            guard let title else { throw FeedFormatError("an alert has no headline or event") }
            let detail = [properties["description"] as? String, properties["instruction"] as? String]
                .compactMap { $0.map(machineLinesRemoved)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            let instruction = (properties["instruction"] as? String).map(machineLinesRemoved)?
                .trimmingCharacters(in: .whitespacesAndNewlines)  // the band's (R9.1), in its words when shown
            let expires = parsed.isEmpty
                ? (ConditionTime.moment(properties["ends"]) ?? ConditionTime.moment(properties["expires"]))
                    .map(ConditionTime.newYorkISO)
                : NWSVTEC.end(parsed)
            let key = title + "\u{0}" + detail
            if let n = at[key] {  // the same product's other hazard: its lines join the item's
                guard !parsed.isEmpty else { continue }
                merged[n] += parsed.filter { !merged[n].contains($0) }
                items[n].vtec = merged[n].map(\.saved)
                items[n].code = NWSVTEC.code(merged[n])
                items[n].expires = NWSVTEC.end(merged[n])
                continue
            }
            at[key] = items.count
            merged.append(parsed)
            items.append(ConditionItem(title, detail: detail, flag: ConditionItem.warn, expires: expires,
                                       code: NWSVTEC.code(parsed), vtec: parsed.map(\.saved),
                                       instruction: instruction?.isEmpty == false ? instruction : nil))
        }
        return items
    }

    static func vtecLines(_ parameters: Any?) throws -> [String] {
        guard let parameters else { return [] }
        guard let parameters = parameters as? [String: Any] else { throw FeedFormatError("an alert's parameters aren't an object") }
        guard let found = parameters["VTEC"] else { return [] }
        guard let list = found as? [Any] else { throw FeedFormatError("an alert's VTEC isn't a list") }
        return try list.map { item in
            guard let text = item as? String else { throw FeedFormatError("an alert's VTEC line isn't text") }
            return text
        }
    }

    static let machine = try! NSRegularExpression(pattern: "^\\s*(?:LAT\\.\\.\\.LON|TIME\\.\\.\\.MOT\\.\\.\\.LOC)\\b")
    static let groups = try! NSRegularExpression(pattern: "^\\s*[0-9]{4,5}(?:\\s+[0-9]{4,5})*\\s*$")

    /// Every line but each LAT...LON and TIME...MOT...LOC line and the digit-group lines continuing it, as the Mac
    /// drops them (dashboard/weather.py `_without_machine_lines`, gate 16 A).
    static func machineLinesRemoved(_ text: String) -> String {
        var kept: [String] = []
        var continuing = false
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if machine.firstMatch(in: line, range: range) != nil {
                continuing = true
                continue
            }
            if continuing && groups.firstMatch(in: line, range: range) != nil { continue }
            continuing = false
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// The zone forecast's periods, in order, each "Name: forecast" (the API gives no times or temperatures for a
    /// zone forecast). One with no periods, or a period without its name or text, throws.
    public static func zoneForecast(_ data: Data) throws -> [ConditionItem] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = top["properties"] as? [String: Any], let periods = properties["periods"] as? [Any] else {
            throw FeedFormatError("the zone forecast has no periods list")
        }
        let items = try periods.map { period -> ConditionItem in
            guard let period = period as? [String: Any], let name = (period["name"] as? String)?.collapsed,
                  let text = (period["detailedForecast"] as? String)?.collapsed, !name.isEmpty, !text.isEmpty else {
                throw FeedFormatError("a forecast period has no name or text")
            }
            return ConditionItem("\(name): \(text)")
        }
        guard !items.isEmpty else { throw FeedFormatError("the zone forecast has no periods") }
        return items
    }

    /// Where a spot is, by the lookup's codes: its forecast zone, county and fire zone, and the nearest town and state
    /// (never the distance or the spot), and its grid forecast's address (phase 3 of the forecast-detail plan; nil
    /// unless it is this host's /gridpoints/OFFICE/X,Y, so the hours are only ever read from here). Codes of another
    /// shape throw.
    public struct Place: Equatable, Sendable {
        public let zone: String, county: String, fireZone: String, area: String
        public let grid: URL?
        public var codes: [String] { [zone, county] + (fireZone == zone ? [] : [fireZone]) }
    }

    public static func points(_ data: Data) throws -> Place {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = top["properties"] as? [String: Any] else {
            throw FeedFormatError("the lookup has no properties")
        }
        func code(_ key: String, _ kind: String) throws -> String {
            guard let url = properties[key] as? String, let last = url.split(separator: "/").last,
                  last.count == 6, last.prefix(2).allSatisfy({ $0.isASCII && $0.isUppercase }),
                  last.dropFirst(2).first == Character(kind), last.suffix(3).allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw FeedFormatError("the lookup's \(key) isn't a zone code")
            }
            return String(last)
        }
        let place = (properties["relativeLocation"] as? [String: Any])?["properties"] as? [String: Any]
        let city = (place?["city"] as? String)?.collapsed ?? "", state = (place?["state"] as? String)?.collapsed ?? ""
        let area = [city, state].filter { !$0.isEmpty }.joined(separator: " ")
        guard area.count <= 60, area.allSatisfy({ !$0.isNewline }) else { throw FeedFormatError("the lookup's place can't be shown") }
        let grid = (properties["forecastGridData"] as? String).flatMap(URL.init(string:)).flatMap { url in
            url.scheme == "https" && url.host == host && url.query == nil
                && url.path.wholeMatch(of: /\/gridpoints\/[A-Z]{3}\/[0-9]{1,3},[0-9]{1,3}/) != nil ? url : nil
        }
        return Place(zone: try code("forecastZone", "Z"), county: try code("county", "C"),
                     fireZone: try code("fireWeatherZone", "Z"), area: area, grid: grid)
    }

    // MARK: The hours where the phone is (forecast-detail plan, phase 3)

    static let compass = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW",
                          "NNW"]  // dashboard/weather.py _COMPASS
    public static let stormUnsaid = "possible"  // dashboard/weather.py STORM_UNSAID

    /// One item per hour of the grid forecast (`forecastGridData`), as the Mac's `weather.hours` gives MapClick's:
    /// its start as `when` and its hour in words ("3 PM", in `zone`, where the phone is) as the text, with the hour's
    /// fields (ConditionHour) from whichever span of each series covers it, turned from the grid's metric units. The
    /// rain amount goes on the first hour of its span, with the span's length. The grid gives a gust every hour, so
    /// one shows only from 10 mph and above the wind (MapClick's are the Mac's as given). The temperatures (°C) and the rain
    /// chances must be there or it is refused; any other series that is missing, or in another unit, leaves its
    /// field empty.
    public static func hours(_ data: Data, zone: TimeZone) throws -> [ConditionItem] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = top["properties"] as? [String: Any] else {
            throw FeedFormatError("the grid forecast has no properties")
        }
        func series(_ key: String, _ unit: String?) -> [Span] {
            guard let layer = properties[key] as? [String: Any], unit == nil || layer["uom"] as? String == unit,
                  let values = layer["values"] as? [Any] else { return [] }
            return values.compactMap { Span($0) }
        }
        let temps = series("temperature", "wmoUnit:degC"), pops = series("probabilityOfPrecipitation", "wmoUnit:percent")
        guard !temps.isEmpty else { throw FeedFormatError("the grid forecast has no temperatures in °C") }
        guard !pops.isEmpty else { throw FeedFormatError("the grid forecast has no rain chances") }
        let feels = series("apparentTemperature", "wmoUnit:degC"), speeds = series("windSpeed", "wmoUnit:km_h-1")
        let gusts = series("windGust", "wmoUnit:km_h-1"), ways = series("windDirection", "wmoUnit:degree_(angle)")
        let amounts = series("quantitativePrecipitation", "wmoUnit:mm"), skies = series("weather", nil)
        func number(_ spans: [Span], _ at: Date) -> Double? { spans.first { $0.covers(at) }?.value as? Double }
        func whole(_ value: Double?) -> String { value.map { String(Int(($0).rounded())) } ?? "" }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = zone
        clock.dateFormat = "h a"
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = zone
        var starts: [Date] = []
        for span in temps {
            for n in 0..<span.hours { starts.append(span.start.addingTimeInterval(Double(n) * 3600)) }
        }
        return starts.map { at in
            let temp = number(temps, at).map { $0 * 9 / 5 + 32 }
            let felt = number(feels, at).map { $0 * 9 / 5 + 32 }
            let mph = number(speeds, at).map { ($0 / 1.609344).rounded() }
            let gust = number(gusts, at).map { ($0 / 1.609344).rounded() }
            var wind = ""
            if mph == 0 {
                wind = "0"
            } else if let mph, let way = number(ways, at), way >= 0, way <= 360 {
                wind = "\(compass[Int((way / 22.5).rounded()) % 16]) \(Int(mph))"
            }
            var rain = "", rainHours = 1
            if let span = amounts.first(where: { $0.start == at }), let mm = span.value as? Double, mm > 0 {
                (rain, rainHours) = (String(mm / 25.4), span.hours)
            }
            let storm = ((skies.first { $0.covers(at) }?.value as? [Any]) ?? []).lazy
                .compactMap { $0 as? [String: Any] }.first { $0["weather"] as? String == "thunderstorms" }
                .map { (($0["coverage"] as? String) ?? "").replacingOccurrences(of: "_", with: " ") }
                .map { $0.isEmpty ? stormUnsaid : $0 } ?? ""
            let pop = number(pops, at).map { min(max($0, 0), 100) }
            return ConditionItem(clock.string(from: at), when: stamp.string(from: at), hour: ConditionHour(
                pop: whole(pop), temp: whole(temp),
                feels: felt.map(whole) == temp.map(whole) ? "" : whole(felt), wind: wind,
                gust: gust.map { $0 >= 10 && $0 > (mph ?? 0) ? String(Int($0)) : "" } ?? "", rain: rain, rainHours: rainHours,
                storm: storm))
        }
    }

    /// One value of a grid series over its span ("2026-10-29T12:00:00+00:00/PT6H"), in whole hours.
    struct Span {
        let start: Date, hours: Int, value: Any

        init?(_ entry: Any) {
            guard let entry = entry as? [String: Any], let valid = entry["validTime"] as? String,
                  let slash = valid.firstIndex(of: "/"), let start = ConditionTime.moment(String(valid[..<slash])),
                  let match = valid[valid.index(after: slash)...].wholeMatch(of: /P(?:([0-9]+)D)?(?:T(?:([0-9]+)H)?)?/)
            else { return nil }
            let hours = (Int(match.1 ?? "0") ?? 0) * 24 + (Int(match.2 ?? "0") ?? 0)
            guard hours > 0 else { return nil }
            (self.start, self.hours, self.value) = (start, hours, entry["value"] ?? NSNull())
        }

        func covers(_ at: Date) -> Bool { at >= start && at < start.addingTimeInterval(Double(hours) * 3600) }
    }
}

/// VTEC lines as the Mac reads them (dashboard/weather.py): which are in force, the event code event mode acts on,
/// and the item's own end.
public enum NWSVTEC {
    public struct Line: Equatable, Sendable {
        public let action, office, phenomenon, significance, number, start, end: String
        var ended: Bool { NWSVTEC.ended.contains(action) }
        var saved: String { "\(action).\(office).\(phenomenon).\(significance).\(number)" }
    }

    static let ended: Set<String> = ["CAN", "EXP", "UPG"]
    static let inForce: Set<String> = ["NEW", "CON", "EXT", "EXA", "EXB"]
    static let untilFurtherNotice = "000000T0000Z"
    /// The warnings event mode acts on, in the order one alert's code is taken from them (weather.py EVENT_FIRST).
    public static let eventFirst = ["TO.W", "FF.W", "HU.W"]

    /// /O.NEW.KLWX.TO.W.0012.261004T2300Z-261004T2345Z/ read whole; nil for anything else.
    public static func parse(_ text: String) -> Line? {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("/"), line.hasSuffix("/") else { return nil }
        let parts = line.dropFirst().dropLast().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7, parts[0].count == 1, "OTEX".contains(parts[0]) else { return nil }
        let times = parts[6].split(separator: "-").map(String.init)
        func upper(_ s: String, _ n: Int) -> Bool { s.count == n && s.allSatisfy { $0.isASCII && $0.isUppercase } }
        func time(_ s: String) -> Bool {
            s.count == 12 && Array(s)[6] == "T" && s.hasSuffix("Z")
                && s.filter({ $0 != "T" && $0 != "Z" }).allSatisfy({ $0.isASCII && $0.isNumber })
        }
        guard upper(parts[1], 3), upper(parts[2], 4), upper(parts[3], 2), upper(parts[4], 1),
              parts[5].count == 4, parts[5].allSatisfy({ $0.isASCII && $0.isNumber }),
              times.count == 2, time(times[0]), time(times[1]) else { return nil }
        return Line(action: parts[1], office: parts[2], phenomenon: parts[3], significance: parts[4], number: parts[5],
                    start: times[0], end: times[1])
    }

    /// The phenomenon and significance of the first line in force, the first warning among them when there is one,
    /// event mode's warnings first in their order, else the first watch (it outranks an advisory); "" when
    /// none is in force (weather.py `_vtec_code`).
    public static func code(_ lines: [Line]) -> String {
        let live = lines.filter { !$0.ended }.map { "\($0.phenomenon).\($0.significance)" }
        let warnings = live.filter { $0.hasSuffix(".W") }
        if let first = eventFirst.first(where: warnings.contains) { return first }
        return (warnings.first ?? live.first { $0.hasSuffix(".A") } ?? live.first) ?? ""
    }

    /// The item's end (weather.py `_vtec_end`): the latest end among the lines in force, none when one runs until
    /// further notice; with none in force, the latest real end among all; nil when an end can't be read.
    public static func end(_ lines: [Line]) -> String? {
        let current = lines.filter { inForce.contains($0.action) }.map(\.end)
        if current.contains(untilFurtherNotice) { return nil }
        let ends = current.isEmpty ? lines.map(\.end).filter { $0 != untilFurtherNotice } : current
        let moments = ends.map(moment)
        guard !moments.isEmpty, !moments.contains(where: { $0 == nil }) else { return nil }
        return ConditionTime.newYorkISO(moments.compactMap { $0 }.max()!)
    }

    /// Whether every line is cancelled, expired or upgraded (render.py `_ended_product`); false with no line.
    public static func allEnded(_ saved: [String]) -> Bool {
        !saved.isEmpty && saved.allSatisfy { ended.contains(String($0.prefix(3))) }
    }

    static func moment(_ value: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMdd'T'HHmm'Z'"
        return f.date(from: value)
    }
}
