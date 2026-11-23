import Foundation

/// Conditions on the street map (plan phase 9, item 5; owner 2026-10-14: public positions only), each with its time,
/// dimmed once it is old so nobody acts on a stale reading:
/// - road events and river gauges from the Mac, read out of the daily library (`path`, packer/map_conditions.py's
///   exact shape, refused whole otherwise), each with the position its feed published;
/// - storm warnings' outlines from the phone's own reading of the Weather Service (`NWSAPI.shapes`), only those it
///   draws a shape for (tornado, severe thunderstorm and flash flood warnings); a warning past its end isn't drawn.
public struct MapConditions: Equatable, Sendable {
    public static let path = "household/map-conditions.json"
    public static let format = 1
    public static let maxRoads = 500
    public static let maxGauges = 6
    /// A road event or gauge reading older than this is drawn dimmed, with its time: the Mac's packs reach the phones
    /// at least every 6 hours at home, a reading may be an hour old when packed, and the phone needs its turn to fetch
    /// it (review 2026-10-14: 6 hours dimmed good readings each cycle).
    public static let oldAfter: TimeInterval = 8 * 3600
    /// Past this a road event or gauge reading leaves the map unless old ones are asked for (owner, 2026-10-14, by
    /// click: weeks offline, a cleared closure must not stay drawn).
    public static let hideAfter: TimeInterval = 72 * 3600

    public struct Road: Equatable, Sendable {
        public let text: String
        public let detail: String
        public let closure: Bool
        public let when: String?
        public let place: [Double]  // longitude, latitude (and the event's end, the same way)
        public let asOf: String
        let taken: Date?  // asOf read once (a stress test, 2026-10-14: reading it at each draw was most of the cost)
    }

    public struct Gauge: Equatable, Sendable {
        public let text: String
        public let flag: String
        public let code: String
        public let place: [Double]  // longitude, latitude
        public let asOf: String
        let taken: Date?
    }

    public let roads: [Road]
    public let gauges: [Gauge]

    public init(roads: [Road] = [], gauges: [Gauge] = []) {
        self.roads = roads
        self.gauges = gauges
    }

    public struct Refused: Error, Equatable {}

    /// The file read as the packer checks it: exactly its keys and shapes, or Refused.
    public init(_ data: Data) throws {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(top.keys) == ["format", "roads", "gauges"], let format = top["format"] as? NSNumber,
              CFGetTypeID(format) != CFBooleanGetTypeID(), format.intValue == Self.format,
              let roads = top["roads"] as? [[String: Any]],
              let gauges = top["gauges"] as? [[String: Any]], roads.count <= Self.maxRoads,
              gauges.count <= Self.maxGauges else { throw Refused() }
        self.roads = try roads.map { found in
            guard Set(found.keys) == ["text", "detail", "closure", "when", "place", "as_of"],
                  let text = Self.text(found["text"]), let detail = found["detail"] as? String,
                  let flag = found["closure"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
                  found["when"] is NSNull || Self.text(found["when"]) != nil,
                  let place = Self.place(found["place"], sizes: [2, 4]), let asOf = Self.text(found["as_of"])
            else { throw Refused() }
            return Road(text: text, detail: detail, closure: flag.boolValue, when: found["when"] as? String,
                        place: place, asOf: asOf, taken: Self.moment(asOf))
        }
        self.gauges = try gauges.map { found in
            guard Set(found.keys) == ["text", "flag", "code", "place", "as_of"], let text = Self.text(found["text"]),
                  let flag = found["flag"] as? String, ["", "warn", "unread"].contains(flag),
                  let code = found["code"] as? String, let place = Self.place(found["place"], sizes: [2]),
                  let asOf = Self.text(found["as_of"]) else { throw Refused() }
            return Gauge(text: text, flag: flag, code: code, place: place, asOf: asOf, taken: Self.moment(asOf))
        }
    }

    static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }

    static func place(_ value: Any?, sizes: Set<Int>) -> [Double]? {
        guard let numbers = value as? [NSNumber], sizes.contains(numbers.count),
              numbers.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) else { return nil }
        let place = numbers.map(\.doubleValue)
        let onMap = stride(from: 0, to: place.count, by: 2).allSatisfy { i in
            (-180...180).contains(place[i]) && (-90...90).contains(place[i + 1])
        }
        return onMap ? place : nil
    }

    /// Whether a reading taken at `asOf` (ISO 8601) is old by `now`; one whose time can't be read counts as old.
    public static func isOld(_ asOf: String, now: Date, after: TimeInterval = oldAfter) -> Bool {
        isOld(moment(asOf), now: now, after: after)
    }

    static func isOld(_ taken: Date?, now: Date, after: TimeInterval = oldAfter) -> Bool {
        guard let taken else { return true }
        return now.timeIntervalSince(taken) > after
    }

    /// One reader for every time: making one per reading cost a tenth of a second for a full file, each minute (a
    /// stress test, 2026-10-14). Apple documents ISO8601DateFormatter as safe to share between threads.
    nonisolated(unsafe) static let reader = ISO8601DateFormatter()

    static func moment(_ iso: String) -> Date? { reader.date(from: iso) }

    /// Road events and gauges past `hideAfter` (or with a time that can't be read), which the map leaves out unless
    /// asked: the Layers menu says how many.
    public func hidden(now: Date = Date()) -> Int {
        roads.filter { Self.isOld($0.taken, now: now, after: Self.hideAfter) }.count
            + gauges.filter { Self.isOld($0.taken, now: now, after: Self.hideAfter) }.count
    }

    /// Everything to draw, as GeoJSON for whichever engine: road events (a point, or a line from start to end), gauges
    /// (points), and warnings' outlines in force at `now`; each with its `kind`, `text`, its time and `old`. Road
    /// events and gauges past `hideAfter` only with `showOld`.
    public func geoJSON(warnings: [WarningShape] = [], now: Date = Date(), showOld: Bool = false) -> Data {
        var features: [[String: Any]] = []
        func shown(_ taken: Date?) -> Bool { showOld || !Self.isOld(taken, now: now, after: Self.hideAfter) }
        for road in roads where shown(road.taken) {
            let geometry: [String: Any] = road.place.count == 4
                ? ["type": "LineString",
                   "coordinates": [[road.place[0], road.place[1]], [road.place[2], road.place[3]]]]
                : ["type": "Point", "coordinates": [road.place[0], road.place[1]]]
            features.append(["type": "Feature", "geometry": geometry, "properties": [
                "kind": road.closure ? "closure" : "road", "text": road.text, "detail": road.detail,
                "as_of": road.asOf, "old": Self.isOld(road.taken, now: now)]])
        }
        for gauge in gauges where shown(gauge.taken) {
            features.append(["type": "Feature", "geometry": ["type": "Point", "coordinates": gauge.place],
                             "properties": ["kind": gauge.flag == "warn" ? "gauge-flood" : "gauge", "text": gauge.text,
                                            "as_of": gauge.asOf, "old": Self.isOld(gauge.taken, now: now)]])
        }
        for warning in warnings where warning.inForce(at: now) {
            features.append(["type": "Feature",
                             "geometry": ["type": "MultiPolygon", "coordinates": warning.polygons],
                             "properties": ["kind": "warning", "text": warning.title, "code": warning.code,
                                            "as_of": warning.asOf, "old": Self.isOld(warning.asOf, now: now)]])
        }
        return (try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features],
                                            options: [.sortedKeys])) ?? Data()
    }
}

/// A storm warning's outline, as the Weather Service draws it.
public struct WarningShape: Equatable, Sendable {
    public let title: String
    public let code: String
    public let expires: String?
    public let asOf: String  // when the phone read it
    public let polygons: [[[[Double]]]]  // MultiPolygon: polygons of rings of [longitude, latitude]

    /// Before its end; one whose end can't be read stays only while the reading is under `MapConditions.oldAfter`
    /// old, so an outline never stays drawn for as long as the app runs offline (an audit, 2026-10-14).
    public func inForce(at now: Date) -> Bool {
        guard let expires, let end = MapConditions.moment(expires) else {
            return !MapConditions.isOld(asOf, now: now)
        }
        return end > now
    }
}

extension NWSAPI {
    /// The outlines of the alerts that have one (storm-based warnings; zone-based alerts come without): "Actual",
    /// not a Cancel, each with its headline, and its code and end read from its own VTEC lines (else the API's `ends`,
    /// else `expires`) by `alerts`' rules, never borrowed from another alert of the same headline. `asOf` is when the
    /// answer was read.
    public static func shapes(_ data: Data, asOf: String) throws -> [WarningShape] {
        _ = try alerts(data)  // the same reading, so a bad answer is refused the same way
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = top["features"] as? [[String: Any]] else { return [] }
        var shapes: [WarningShape] = []
        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  properties["status"] as? String == "Actual", properties["messageType"] as? String != "Cancel",
                  let geometry = feature["geometry"] as? [String: Any], let type = geometry["type"] as? String
            else { continue }
            let polygons: [[[[Double]]]]
            switch type {
            case "Polygon": polygons = [rings(geometry["coordinates"])].compactMap { $0 }
            case "MultiPolygon": polygons = ((geometry["coordinates"] as? [Any]) ?? []).compactMap(rings)
            default: continue
            }
            guard !polygons.isEmpty else { continue }
            let parameters = properties["parameters"] as? [String: Any]
            let nwsHeadline = (parameters?["NWSheadline"] as? [Any])?.first as? String
            let title = [nwsHeadline, properties["headline"] as? String, properties["event"] as? String]
                .compactMap { $0?.collapsed }.first { !$0.isEmpty } ?? ""
            let parsed = ((try? vtecLines(properties["parameters"])) ?? []).compactMap(NWSVTEC.parse)
            let expires = parsed.isEmpty
                ? (ConditionTime.moment(properties["ends"]) ?? ConditionTime.moment(properties["expires"]))
                    .map(ConditionTime.newYorkISO)
                : NWSVTEC.end(parsed)
            shapes.append(WarningShape(title: title, code: NWSVTEC.code(parsed), expires: expires, asOf: asOf,
                                       polygons: polygons))
        }
        return shapes
    }

    static func rings(_ value: Any?) -> [[[Double]]]? {
        guard let rings = value as? [[[NSNumber]]] else { return nil }
        let read = rings.map { ring in
            ring.compactMap { pair in pair.count >= 2 ? [pair[0].doubleValue, pair[1].doubleValue] : nil }
        }
        return read.allSatisfy({ $0.count >= 4 }) && !read.isEmpty ? read : nil
    }
}
