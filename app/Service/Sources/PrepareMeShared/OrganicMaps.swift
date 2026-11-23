import Foundation

/// Directions by hand-off to Organic Maps (owner, 2026-10-14, by click: driving and walking): PrepareMe has no
/// router, so a rally point, a found place or a pin opens Organic Maps on the same phone with the route already asked
/// for; it routes offline on its own maps. The links follow its own parser (organicmaps/organicmaps,
/// libs/map/mwm_url.cpp, read 2026-10-14): `om://route` takes sll, saddr, dll, daddr and type, all five and in that
/// order, or it refuses the link; `om://map` shows a point (ll, then its name n). Nothing leaves the phone.
public enum OrganicMaps {
    public static let scheme = "om"

    /// The alert when Organic Maps isn't on this device (task 2.3: never a dead end): the way first, when the device
    /// knows where it is ("Head north, 0.4 miles, 10 min+ on foot."), then how to get the app. The alert's Show on map
    /// flies to the spot.
    /// `lostSince`: when the fix is stale, the time it was taken, so the way is said to be from where the phone was
    /// (the W9 review).
    public static func missingWords(device: String, from here: (Double, Double)?, to spot: (Double, Double),
                                    lostSince: Date? = nil, now: Date = Date()) -> (title: String, message: String) {
        let title = "Organic Maps isn't on this \(device)"
        guard let here else { return (title, installLine) }
        let meters = Position.meters(from: here, to: spot)
        let way = "Head \(Position.compass(Position.bearing(from: here, to: spot))), \(Position.distance(meters)), "
            + "\(Position.walkTime(meters))+ on foot. "
        let lost = lostSince.map { Position.staleWords(taken: $0, now: now) + " " } ?? ""
        return (title, lost + way + installLine)
    }

    public static let installLine = "Directions open in Organic Maps, free in the App Store. Install it at home on "
        + "Wi-Fi and download its maps for your state and the states around it; it then routes with no signal."
    public static let here = "My location"

    /// Home Mac › Street map's line (hand-off plan, 3.2), read with canOpenURL at each check; amber when it's missing.
    public static func installedWords(_ installed: Bool, device: String) -> String {
        installed ? "Directions: Organic Maps is on this \(device)."
                  : "Directions: Organic Maps isn't on this \(device). " + installLine
    }

    public enum Travel: String, Sendable {
        case drive = "vehicle", walk = "pedestrian"
    }

    /// A route from `from` (latitude, longitude) to `to`, or, when the position isn't known, the destination shown
    /// as a point (Organic Maps then routes from where it finds the phone); nil for a place off the globe.
    public static func url(from: (Double, Double)?, to: (Double, Double), name: String, travel: Travel) -> URL? {
        guard on(to) else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        if let from, on(from) {
            parts.host = "route"
            parts.queryItems = [URLQueryItem(name: "sll", value: point(from)),
                                URLQueryItem(name: "saddr", value: here),
                                URLQueryItem(name: "dll", value: point(to)),
                                URLQueryItem(name: "daddr", value: name),
                                URLQueryItem(name: "type", value: travel.rawValue)]
        } else {
            parts.host = "map"
            parts.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "ll", value: point(to)),
                                URLQueryItem(name: "n", value: name)]
        }
        // a "+" or "&" in a name must not split it: escape what the query's own form leaves alone
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }

    static func point(_ p: (Double, Double)) -> String {
        String(format: "%.6f,%.6f", p.0, p.1)
    }

    static func on(_ p: (Double, Double)) -> Bool {
        p.0.isFinite && p.1.isFinite && (-90...90).contains(p.0) && (-180...180).contains(p.1)
    }

    // MARK: The marks as a file (step 6, part 3)

    /// The shared file's name: Organic Maps imports it ("Import with Organic Maps" in the share sheet) as bookmarks and
    /// tracks it keeps offline (its help page: KML, KMZ, KMB, GPX or GeoJSON).
    public static let fileName = "PrepareMe pins and routes.kml"

    /// The file's type as Organic Maps declares it, and PrepareMe's Info.plists import it: a share offers Organic Maps
    /// only for this type (the owner's report, 2026-10-19: a .kml sent as plain XML wasn't offered it).
    public static let kmlType = "com.google.earth.kml"

    /// The ticked marks of a Select (the owner's choice, 2026-10-19: "Pick several, then share"), in the list's order
    /// (Position.ordered); a tick for a mark no longer there is left out.
    public static func picked(_ marks: [MapMark], _ ids: Set<Int64>) -> [MapMark] {
        Position.ordered(marks).filter { ids.contains($0.id) && $0.kind != .start }
    }

    /// "Share to Organic Maps" for every mark; "Share 2 to Organic Maps" for those picked.
    public static func shareWords(count: Int?, gpx: Bool = false) -> String {
        let to = gpx ? "as GPX" : "to Organic Maps"
        return count.map { "Share \($0) \(to)" } ?? "Share \(to)"
    }

    /// Every rally point (a pin, its role and note as the description) and route (a line), in the list's order
    /// (Position.ordered: the roles first), as one KML document. Names and notes are escaped; nothing else of the
    /// household is in it. Exact positions leave PrepareMe only when someone shares this file and picks where.
    public static func kml(_ marks: [MapMark]) -> String {
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<kml xmlns=\"http://www.opengis.net/kml/2.2\">",
                     "<Document>", "<name>PrepareMe pins and routes</name>"]
        for mark in Position.ordered(marks) where mark.kind != .start {
            let about = about(mark)
            lines.append("<Placemark>")
            lines.append("<name>\(escaped(mark.name))</name>")
            if !about.isEmpty { lines.append("<description>\(escaped(about))</description>") }
            let coordinates = mark.points.map { "\(number($0[0])),\(number($0[1]))" }.joined(separator: " ")
            lines.append(mark.kind != .route ? "<Point><coordinates>\(coordinates)</coordinates></Point>"
                                             : "<LineString><coordinates>\(coordinates)</coordinates></LineString>")
            lines.append("</Placemark>")
        }
        lines += ["</Document>", "</kml>"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// A mark's description in a shared file: its role (a rally point's or a route's), then its note.
    static func about(_ mark: MapMark) -> String {
        [mark.role?.words ?? mark.routeRole?.words ?? "", mark.note.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }

    public static let gpxFileName = "PrepareMe pins and routes.gpx"
    public static let gpxType = "com.topografix.gpx"

    /// The same marks as GPX (the street map fixes plan, task 3.5), which more map apps import than KML: each rally
    /// point a waypoint, each route a track, in the list's order (rally points first, as GPX wants its waypoints).
    public static func gpx(_ marks: [MapMark]) -> String {
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                     "<gpx version=\"1.1\" creator=\"PrepareMe\" xmlns=\"http://www.topografix.com/GPX/1/1\">",
                     "<metadata><name>PrepareMe pins and routes</name></metadata>"]
        func point(_ p: [Double]) -> String { "lat=\"\(number(p[1]))\" lon=\"\(number(p[0]))\"" }
        for mark in Position.ordered(marks) {
            let about = about(mark)
            let named = "<name>\(escaped(mark.name))</name>" + (about.isEmpty ? "" : "<desc>\(escaped(about))</desc>")
            if mark.kind == .rally || mark.kind == .pin, let p = mark.points.first, p.count == 2 {  // a pin too (2026-11-12)
                lines.append("<wpt \(point(p))>\(named)</wpt>")
            } else if mark.kind == .route {
                lines.append("<trk>\(named)<trkseg>")
                lines += mark.points.filter { $0.count == 2 }.map { "<trkpt \(point($0))/>" }
                lines.append("</trkseg></trk>")
            }
        }
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The KML file written for sharing, in this device's temporary folder; nil when it can't be written.
    public static func file(_ marks: [MapMark]) -> URL? { write(kml(marks), name: fileName) }

    /// The GPX file, the same way.
    public static func gpxFile(_ marks: [MapMark]) -> URL? { write(gpx(marks), name: gpxFileName) }

    /// Any file an earlier share left there is removed first, so no older copy of the places lingers (the review).
    private static func write(_ text: String, name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrepareMe share", isDirectory: true)
        let url = folder.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A coordinate to its 6 kept decimals, trailing zeros left off ("-77.0364").
    static func number(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// `text` escaped for XML, with the characters XML 1.0 forbids dropped (a control character a pasted name might
    /// hold would make Organic Maps refuse the whole file: the review).
    static func escaped(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\t" || scalar == "\n" || scalar == "\r"
                || (scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF)
        })).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

