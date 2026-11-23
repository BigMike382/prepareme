import Foundation

/// The phone app's conditions settings (plan phase 5): home's codes, packed into the daily library as
/// `household/conditions-settings.json` by the Mac (packer/phone_settings.py, which writes this exact shape). The
/// reader is as strict as the writer: any other key, a value of another shape, a repeated key or a number with a
/// decimal point (where a coordinate would show) is refused, and the app then shows the Mac's conditions only. Codes
/// are checked by their shape, any state's (two capital letters, Z or C, three digits, the same letters on all three;
/// Unlisted plan, phase 4): the state itself, and its feeds, come from `ConditionsArea`'s file beside this one, which
/// this file never changes for (every installed app's strict reader would refuse it).
///
/// The test area (owner, 2026-10-21, by click): a session's simulator may also read Washington, DC, the street map's
/// test area, so live conditions can be tried with no hint of home. Only its exact codes and name, and only when the
/// caller allows it: LiveConditions allows it in a simulator build alone, so a phone's build never reads it, and the
/// Mac's packer (packer/phone_settings.py) never writes it.
public struct ConditionsSettings: Equatable, Sendable {
    public static let path = "household/conditions-settings.json"
    public static let format = 1
    public static let maxGauges = 6
    public static let testArea = (zone: "DCZ001", county: "DCC001", fireZone: "DCZ001", countyName: "District of Columbia")

    public let zone: String, county: String, fireZone: String, countyName: String
    public let gauges: [String]
    /// Whether the phone shows its own reading of the alerts (held off until the probe week's check f is ruled on).
    public let liveAlerts: Bool
    /// The DC test area's codes, read only where allowed (owner, 2026-10-21).
    public let isTestArea: Bool
    /// The state's details from the file beside this one; nil without it (an older library, the backup folder's copy),
    /// and then the phone reads no power outage or evacuation feed (Unlisted plan, phase 4).
    public let area: ConditionsArea?

    /// Home's alert codes, as the Mac's alerts page is asked for them: zone, county and fire zone (once when it is
    /// the zone).
    public var alertCodes: [String] { [zone, county] + (fireZone == zone ? [] : [fireZone]) }

    public enum Problem: Error, Equatable, Sendable { case notTheShape }

    /// `area`: the state's file beside it, as read from the library (a damaged one counts as none).
    /// `allowingTestArea`: also read the DC test area's exact codes (LiveConditions passes true on a simulator only).
    public init(_ data: Data, area: Data? = nil, allowingTestArea: Bool = false) throws {
        guard !Self.hasDecimal(data), !Self.hasRepeatedKey(data),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(top.keys) == ["format", "nws_zone", "nws_county", "nws_fire_zone", "county", "gauges", "live_alerts"],
              let format = top["format"] as? NSNumber, CFGetTypeID(format) != CFBooleanGetTypeID(),
              format == NSNumber(value: Self.format),
              let zone = top["nws_zone"] as? String, let county = top["nws_county"] as? String,
              let fireZone = top["nws_fire_zone"] as? String, let name = top["county"] as? String,
              let gauges = top["gauges"] as? [Any], gauges.count <= Self.maxGauges,
              let live = top["live_alerts"] as? NSNumber, CFGetTypeID(live) == CFBooleanGetTypeID()
        else { throw Problem.notTheShape }
        let letters = String(zone.prefix(2))
        let home = Self.matches(zone, "^[A-Z]{2}Z[0-9]{3}$") && Self.matches(county, "^[A-Z]{2}C[0-9]{3}$")
            && Self.matches(fireZone, "^[A-Z]{2}Z[0-9]{3}$") && county.hasPrefix(letters) && fireZone.hasPrefix(letters)
            && letters != "DC" && Self.matches(name, "^[A-Z][A-Za-z]+(?: [A-Z][A-Za-z]+)?$")
        let test = allowingTestArea && zone == Self.testArea.zone && county == Self.testArea.county
            && fireZone == Self.testArea.fireZone && name == Self.testArea.countyName
        guard home || test else { throw Problem.notTheShape }
        let ids = try gauges.map { gauge -> String in
            guard let id = gauge as? String, Self.matches(id, "^[A-Z0-9]{5}$") else { throw Problem.notTheShape }
            return id
        }
        self.zone = zone
        self.county = county
        self.fireZone = fireZone
        self.countyName = name
        self.gauges = ids
        self.liveAlerts = live.boolValue
        self.isTestArea = test
        self.area = area.flatMap { try? ConditionsArea($0) }
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil && !text.contains("\n")
    }

    static func hasDecimal(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        return bytes.indices.dropFirst().dropLast().contains { i in
            bytes[i] == UInt8(ascii: ".") && (48...57).contains(bytes[i - 1]) && (48...57).contains(bytes[i + 1])
        }
    }

    /// Whether the top object names a key twice (JSONSerialization keeps the last). The file is flat: its only
    /// nested value is the gauges' list of plain codes, so the keys are the quoted strings just before a colon.
    static func hasRepeatedKey(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        guard let pattern = try? NSRegularExpression(pattern: "\"([^\"\\\\]*)\"\\s*:") else { return true }
        let keys = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        return Set(keys).count != keys.count
    }
}
