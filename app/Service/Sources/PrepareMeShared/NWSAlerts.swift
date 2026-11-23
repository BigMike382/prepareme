import Foundation

/// The phone's reading of api.weather.gov's active alerts (`GET /alerts/active?zone=…`, a GeoJSON FeatureCollection),
/// reduced to counts. It fails loud, never toward "none": an answer that isn't a FeatureCollection, a feature without
/// properties or a status, or a VTEC entry that isn't a P-VTEC line throws, and the probe records "couldn't read".
///
/// - An alert counts when its status is "Actual", it isn't a Cancel message, and it has no VTEC line or at least one
///   in force (not CAN, EXP or UPG), as the Mac's page shows only what is in force.
/// - An event is a VTEC line's office, phenomenon, significance and event number ("KLWX.WI.Y.0012"), counted once
///   however many alerts carry it, as the Mac shows one product once under each of its hazards.
public enum NWSAlerts {
    public static let userAgent = "PrepareMe-app/1 (household offline library; not a crawler)"

    public enum Problem: Error, Equatable, Sendable {
        case notJSON, notAFeatureCollection, badFeature, badVTEC
    }

    public static func count(_ data: Data) throws -> AlertCounts {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Problem.notJSON }
        guard top["type"] as? String == "FeatureCollection", let features = top["features"] as? [Any] else {
            throw Problem.notAFeatureCollection
        }
        var alerts = 0, noVTEC = 0
        var events = Set<String>()
        for case let feature in features {
            guard let feature = feature as? [String: Any], let properties = feature["properties"] as? [String: Any],
                  let status = properties["status"] as? String, let messageType = properties["messageType"] as? String
            else { throw Problem.badFeature }
            let lines = try vtecLines(properties["parameters"])
            guard status == "Actual", messageType != "Cancel" else { continue }
            let live = try lines.compactMap { line -> String? in
                guard let found = parse(line) else { throw Problem.badVTEC }  // never read as ended (review 7)
                return found.ended ? nil : found.event
            }
            if lines.isEmpty {
                noVTEC += 1
            } else if live.isEmpty {
                continue
            }
            alerts += 1
            events.formUnion(live)
        }
        return AlertCounts(alerts: alerts, events: events.count, noVTEC: noVTEC)
    }

    /// The VTEC strings in a feature's parameters (none when it has no VTEC key); anything but a list of text throws.
    static func vtecLines(_ parameters: Any?) throws -> [String] {
        guard let parameters else { return [] }
        guard let parameters = parameters as? [String: Any] else { throw Problem.badFeature }
        guard let found = parameters["VTEC"] else { return [] }
        guard let list = found as? [Any] else { throw Problem.badVTEC }
        return try list.map { item in
            guard let text = item as? String else { throw Problem.badVTEC }
            return text
        }
    }

    /// "KLWX.WI.Y.0012" for a VTEC line in force; nil for one cancelled, expired or upgraded, or not a P-VTEC line.
    /// The shape is the Mac's (dashboard/weather.py `_VTEC`): /k.aaa.cccc.pp.s.####.yymmddThhnnZ-yymmddThhnnZ/.
    public static func event(inForce line: String) -> String? {
        parse(line).flatMap { $0.ended ? nil : $0.event }
    }

    /// The line's event and whether it is cancelled, expired or upgraded; nil for a line that isn't P-VTEC. Read by
    /// the app's own reader (NWSVTEC.parse), so a count and the app's feeds take the same lines, times included (the
    /// audit, 2026-10-22: this one had passed a line with malformed times).
    static func parse(_ line: String) -> (event: String, ended: Bool)? {
        NWSVTEC.parse(line).map { ("\($0.office).\($0.phenomenon).\($0.significance).\($0.number)", $0.ended) }
    }

    /// The address the phone reads: the home zone, county and fire weather zone codes, typed on the phone, checked
    /// to be codes (two letters, Z or C, three digits) so nothing else can ride in the query.
    public static func url(zones: [String]) -> URL? {
        guard !zones.isEmpty, zones.allSatisfy(isZoneCode) else { return nil }
        var parts = URLComponents(string: "https://api.weather.gov/alerts/active")!
        parts.queryItems = [URLQueryItem(name: "zone", value: zones.joined(separator: ","))]
        return parts.url
    }

    public static func isZoneCode(_ code: String) -> Bool {
        let chars = Array(code)
        return chars.count == 6 && chars[0...1].allSatisfy { $0.isASCII && $0.isUppercase }
            && (chars[2] == "Z" || chars[2] == "C") && chars[3...].allSatisfy { $0.isASCII && $0.isNumber }
    }
}
