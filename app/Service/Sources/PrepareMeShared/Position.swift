import Foundation

/// Where the phone is, in words a person can read out (plan phase 9, items 2 and 3): latitude and longitude, and the
/// US National Grid (USNG), the grid search and rescue uses and the USGS topo maps print; and how far, and which way,
/// each rally point and route is. The position is shown on screen only: nothing here keeps or sends it.
public enum Position {
    // MARK: Latitude and longitude

    /// "35.77960° N, 78.63820° W": five decimals, about a meter.
    public static func latLon(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.5f° %@, %.5f° %@", abs(latitude), latitude < 0 ? "S" : "N", abs(longitude),
               longitude < 0 ? "W" : "E")
    }

    // MARK: USNG

    /// "17S QV 13473 62076": zone and band, the 100 km square, then easting and northing truncated (not rounded) to
    /// `digits` each (5: one meter; 4: ten meters), as the standard reads a grid square. Nil outside 80° S to 84° N,
    /// where the grid is polar. The UTM zone's Norway and Svalbard exceptions are left out: none touch North America.
    public static func usng(_ latitude: Double, _ longitude: Double, digits: Int = 5) -> String? {
        guard latitude.isFinite, longitude.isFinite, (-80.0..<84.0).contains(latitude),
              (-180.0...180.0).contains(longitude), (1...5).contains(digits) else { return nil }
        let utm = UTM(latitude, longitude)
        let bands = Array("CDEFGHJKLMNPQRSTUVWX")
        let band = bands[min(Int(((latitude + 80) / 8).rounded(.down)), bands.count - 1)]
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")  // no I, no O
        let set = (utm.zone - 1) % 3  // columns A–H, J–R, S–Z in turn
        let column = Int((utm.easting / 100_000).rounded(.down))  // 1 to 8
        guard (1...8).contains(column) else { return nil }
        let rows = Array("ABCDEFGHJKLMNPQRSTUV")
        let row = Int((utm.northing / 100_000).rounded(.down)) % 20
        let rowLetter = rows[(row + (utm.zone % 2 == 0 ? 5 : 0)) % 20]
        let scale = pow(10.0, Double(5 - digits))
        func part(_ meters: Double) -> String {
            let inSquare = meters.truncatingRemainder(dividingBy: 100_000)
            return String(format: "%0\(digits)d", Int((inSquare / scale).rounded(.down)))
        }
        return "\(utm.zone)\(band) \(letters[set * 8 + column - 1])\(rowLetter) \(part(utm.easting)) \(part(utm.northing))"
    }

    /// Universal Transverse Mercator on the WGS84 ellipsoid (Krüger's series to the sixth order, good to well under a
    /// millimeter inside a zone). Northern hemisphere northings run from the equator; southern from 10,000 km.
    struct UTM {
        let zone: Int
        let easting: Double
        let northing: Double

        init(_ latitude: Double, _ longitude: Double, zone fixed: Int? = nil) {
            let zone = fixed ?? min(Int(((longitude + 180) / 6).rounded(.down)) + 1, 60)
            let a = 6_378_137.0, f = 1 / 298.257223563, k0 = 0.9996
            let n = f / (2 - f)
            let big = a / (1 + n) * (1 + n * n / 4 + pow(n, 4) / 64 + pow(n, 6) / 256)
            let alpha = [n / 2 - 2 * n * n / 3 + 5 * pow(n, 3) / 16 + 41 * pow(n, 4) / 180 - 127 * pow(n, 5) / 288
                         + 7891 * pow(n, 6) / 37800,
                         13 * n * n / 48 - 3 * pow(n, 3) / 5 + 557 * pow(n, 4) / 1440 + 281 * pow(n, 5) / 630
                         - 1983433 * pow(n, 6) / 1935360,
                         61 * pow(n, 3) / 240 - 103 * pow(n, 4) / 140 + 15061 * pow(n, 5) / 26880
                         + 167603 * pow(n, 6) / 181440,
                         49561 * pow(n, 4) / 161280 - 179 * pow(n, 5) / 168 + 6601661 * pow(n, 6) / 7257600,
                         34729 * pow(n, 5) / 80640 - 3418889 * pow(n, 6) / 1995840,
                         212378941 * pow(n, 6) / 319334400]
            let phi = latitude * .pi / 180
            let lambda = (longitude - Double(zone * 6 - 183)) * .pi / 180
            let e = sqrt(f * (2 - f))
            let tau = tan(phi)
            let sigma = sinh(e * atanh(e * tau / sqrt(1 + tau * tau)))
            let tauPrime = tau * sqrt(1 + sigma * sigma) - sigma * sqrt(1 + tau * tau)
            let xiPrime = atan2(tauPrime, cos(lambda))
            let etaPrime = asinh(sin(lambda) / sqrt(tauPrime * tauPrime + cos(lambda) * cos(lambda)))
            var xi = xiPrime, eta = etaPrime
            for (j, aj) in alpha.enumerated() {
                let k = Double(2 * (j + 1))
                xi += aj * sin(k * xiPrime) * cosh(k * etaPrime)
                eta += aj * cos(k * xiPrime) * sinh(k * etaPrime)
            }
            self.zone = zone
            easting = 500_000 + k0 * big * eta
            northing = k0 * big * xi + (latitude < 0 ? 10_000_000 : 0)
        }
    }

    // MARK: The printed grid

    /// One line of the US National Grid across an area: `easting` (a line running north) or not (running east), its
    /// value in meters within the zone, the two digits a USNG map prints beside it (its kilometers within the 100 km
    /// square), and points along it as [longitude, latitude].
    public struct GridLine: Equatable, Sendable {
        public let easting: Bool
        public let meters: Int
        public let label: String
        public let points: [[Double]]
    }

    /// The grid's lines every `step` meters across the area (west, south, east, north), in the UTM zone of its middle
    /// (USNG maps print one zone's grid; a line near another zone is still that zone's): each found by halving, from the
    /// forward conversion `usng` uses, at `samples` places along the area, so it bends as the true grid does. The
    /// zone and band of the middle come back with them, for the map's note.
    public static func grid(west: Double, south: Double, east: Double, north: Double, step: Int,
                            samples: Int = 24) -> (zone: String, lines: [GridLine]) {
        let midLat = (south + north) / 2, midLon = (west + east) / 2
        let zone = UTM(midLat, midLon).zone
        let bands = Array("CDEFGHJKLMNPQRSTUVWX")
        let band = bands[max(0, min(Int(((midLat + 80) / 8).rounded(.down)), bands.count - 1))]
        func utm(_ lat: Double, _ lon: Double) -> UTM { UTM(lat, lon, zone: zone) }
        let corners = [utm(south, west), utm(south, east), utm(north, west), utm(north, east)]
        let e0 = Int(corners.map(\.easting).min()!), e1 = Int(corners.map(\.easting).max()!)
        let n0 = Int(corners.map(\.northing).min()!), n1 = Int(corners.map(\.northing).max()!)
        func label(_ meters: Int) -> String { String(format: "%02d", (meters % 100_000) / 1000) }
        func solve(_ lo: Double, _ hi: Double, _ value: (Double) -> Double, _ target: Double) -> Double? {
            var (a, b) = (lo, hi)
            let (fa, fb) = (value(a) - target, value(b) - target)
            guard fa * fb <= 0 else { return nil }
            let rising = fb > fa
            for _ in 0..<50 {
                let m = (a + b) / 2
                if (value(m) < target) == rising { a = m } else { b = m }
            }
            return (a + b) / 2
        }
        var lines: [GridLine] = []
        let along = (0...samples).map { Double($0) / Double(samples) }
        for e in stride(from: (e0 / step + 1) * step, through: e1, by: step) {
            let points = along.compactMap { t -> [Double]? in
                let lat = south + (north - south) * t
                return solve(west, east, { utm(lat, $0).easting }, Double(e)).map { [$0, lat] }
            }
            if points.count > 1 { lines.append(GridLine(easting: true, meters: e, label: label(e), points: points)) }
        }
        for n in stride(from: (n0 / step + 1) * step, through: n1, by: step) {
            let points = along.compactMap { t -> [Double]? in
                let lon = west + (east - west) * t
                return solve(south, north, { utm($0, lon).northing }, Double(n)).map { [lon, $0] }
            }
            if points.count > 1 { lines.append(GridLine(easting: false, meters: n, label: label(n), points: points)) }
        }
        return ("\(zone)\(band)", lines)
    }

    /// A scale bar's length: the longest of 0.1, 0.25, 0.5, 1, 2, 5, 10, 25 and 50 miles that fits in `meters`.
    public static func scaleMiles(fitting meters: Double) -> Double {
        [50, 25, 10, 5, 2, 1, 0.5, 0.25, 0.1].first { $0 * 1609.344 <= meters } ?? 0.1
    }

    // MARK: How far, and which way

    /// Meters between two points along the earth's surface (a sphere of the WGS84 mean radius: within half a percent,
    /// plenty for walking or driving to a rally point).
    public static func meters(from a: (Double, Double), to b: (Double, Double)) -> Double {
        let r = 6_371_008.8
        let (p1, p2) = (a.0 * .pi / 180, b.0 * .pi / 180)
        let dp = p2 - p1, dl = (b.1 - a.1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// The compass direction to set out in, 0 to 360 degrees clockwise from true north.
    public static func bearing(from a: (Double, Double), to b: (Double, Double)) -> Double {
        let (p1, p2) = (a.0 * .pi / 180, b.0 * .pi / 180)
        let dl = (b.1 - a.1) * .pi / 180
        let y = sin(dl) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// "northeast": the nearest of eight compass words.
    public static func compass(_ bearing: Double) -> String {
        let words = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return words[Int(((bearing + 22.5) / 45).rounded(.down)) % 8]
    }

    /// "2.3 miles", "0.4 miles", or "450 feet" under a tenth of a mile.
    public static func distance(_ meters: Double) -> String {
        let miles = meters / 1609.344
        if miles < 0.1 { return "\(Int((meters * 3.28084 / 10).rounded()) * 10) feet" }
        return String(format: miles < 10 ? "%.1f miles" : "%.0f miles", miles)
    }

    // MARK: How good the fix is

    /// A fix older than this when it arrives is iOS's saved one, maybe hours old and from somewhere else, and is never
    /// shown as where the phone is (an audit, 2026-10-14).
    public static let freshFix: TimeInterval = 120

    /// The Mac's line on its street map while it has no fix to show (Mac sidebar plan, task 12): none came (Wi-Fi
    /// finds a Mac, and may not with the internet down), or the last is older than `freshFix`. Nothing is guessed in
    /// its place. The phone keeps its own words (StreetMapModel.locationWords).
    public static let macNoFix = "This Mac can't tell where it is right now."

    /// The Mac's line instead while location is off for PrepareMe (denied, or restricted by the Mac's settings): where
    /// to turn it on (task 12, fix round 1; worded on its own since the part 3 review, as "it" had pointed at nothing).
    /// Not shown while macOS's question is on screen.
    public static let macLocationOff =
        "Location is off for PrepareMe: turn it on in System Settings › Privacy & Security › Location Services."

    /// Whether a fix may be shown: a real accuracy, and taken within `freshFix` of `now`.
    public static func usable(accuracy: Double, taken: Date, now: Date = Date()) -> Bool {
        accuracy >= 0 && now.timeIntervalSince(taken) <= freshFix
    }

    /// "Within 15 feet", "within 0.2 miles", and ", 6 minutes ago" once it is over a minute old: read out beside a
    /// grid number, so whoever is helping knows how far to trust it.
    public static func fix(accuracy: Double, taken: Date, now: Date = Date()) -> String {
        let within = accuracy < 160.9344 ? "Within \(max(10, Int((accuracy * 3.28084 / 5).rounded()) * 5)) feet"
            : "Within \(distance(accuracy))"
        let minutes = Int(now.timeIntervalSince(taken) / 60)
        switch minutes {
        case ..<1: return within
        case 1: return within + ", 1 minute ago"
        default: return within + ", \(minutes) minutes ago"
        }
    }

    /// How old the fix on screen is (the street map fixes plan, task 1.1): fresh; aging from `agingAfter`, when the
    /// phone's dot grays and its circle widens; stale from `staleAfter`, when a banner says GPS was lost. The numbers
    /// are the 2026-10-23 review's, not Apple's (Core Location names none): a phone outdoors gets a fix about every
    /// second, so half a minute without one means the sky is blocked, and two minutes is `freshFix`, the age past
    /// which an arriving fix is refused.
    public enum Freshness: Equatable, Sendable { case fresh, aging, stale }
    public static let agingAfter: TimeInterval = 30
    public static let staleAfter: TimeInterval = 120

    public static func freshness(taken: Date, now: Date = Date()) -> Freshness {
        let age = now.timeIntervalSince(taken)
        return age >= staleAfter ? .stale : age >= agingAfter ? .aging : .fresh
    }

    /// The banner over the strip once the fix is stale: "GPS lost 4 minutes ago. Distances are from where you were."
    public static func staleWords(taken: Date, now: Date = Date()) -> String {
        "GPS lost \(ago(Int(now.timeIntervalSince(taken) / 60), long: true)) ago. Distances are from where you were."
    }

    /// "4 min ago", after the distance in the folded strip, once the fix is a minute old; nil before.
    public static func ageBrief(taken: Date, now: Date = Date()) -> String? {
        let minutes = Int(now.timeIntervalSince(taken) / 60)
        return minutes < 1 ? nil : ago(minutes, long: false) + " ago"
    }

    /// "1 minute", "4 minutes" (or "4 min"), "1 h 1 min", "2 h".
    static func ago(_ minutes: Int, long: Bool) -> String {
        if minutes >= 60 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        return !long ? "\(minutes) min" : minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// Battery: the GPS asks for its best only until a fix within 25 m, then about 10 m; and after `easeAfter` of fixes
    /// it eases anyway, as under trees or between tall buildings none may ever get that good (the street map fixes
    /// plan, task 1.4; before it, such a walk ran at best accuracy throughout: the 2026-10-23 review).
    public static let easeAfter: TimeInterval = 60

    public static func shouldEase(bestAccuracy: Double, sinceFirstFix: TimeInterval) -> Bool {
        bestAccuracy <= 25 || sinceFirstFix >= easeAfter
    }

    /// One rally point's or route's way from here: its nearest point (a route's nearest spot along it), how far, and
    /// which way.
    public struct Way: Equatable, Sendable {
        public let mark: MapMark
        public let meters: Double
        public let bearing: Double
        public let nearest: [Double]  // [longitude, latitude]
        /// A route's length from `nearest` to its last point (its end, as drawn on the Mac); nil for a rally point.
        public var toEnd: Double? = nil

        /// "Meet at the big oak: 2.3 miles northeast"
        public var words: String { "\(mark.name): \(Position.distance(meters)) \(Position.compass(bearing))" }
    }

    /// Every rally point and route from `here` (latitude, longitude), nearest first, rally points before routes at
    /// the same distance.
    public static func ways(from here: (Double, Double), to marks: [MapMark]) -> [Way] {
        marks.compactMap { mark -> Way? in
            // The Start point is where the printed lists begin, never somewhere to go
            guard mark.kind != .start, let (spot, piece) = nearest(on: mark, to: here) else { return nil }
            let there = (spot[1], spot[0])
            var way = Way(mark: mark, meters: meters(from: here, to: there), bearing: bearing(from: here, to: there),
                          nearest: spot)
            if mark.kind == .route {
                let rest = [spot] + mark.points.filter { $0.count == 2 }.dropFirst(piece + 1)
                way.toEnd = zip(rest, rest.dropFirst()).reduce(0) { sum, pair in
                    sum + meters(from: (pair.0[1], pair.0[0]), to: (pair.1[1], pair.1[0]))
                }
            }
            return way
        }
        .sorted { ($0.meters, $0.mark.kind == .rally ? 0 : 1) < ($1.meters, $1.mark.kind == .rally ? 0 : 1) }
    }

    /// The mark's point nearest `here`: a rally point itself, or the closest spot on a route's line (each piece taken
    /// flat, which over a route's short pieces is exact enough).
    static func nearestPoint(on mark: MapMark, to here: (Double, Double)) -> [Double]? {
        nearest(on: mark, to: here)?.point
    }

    /// The nearest point, and the piece of the route it is on (0 for the first two points).
    static func nearest(on mark: MapMark, to here: (Double, Double)) -> (point: [Double], piece: Int)? {
        let points = mark.points.filter { $0.count == 2 }
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return (first, 0) }
        let scale = cos(here.0 * .pi / 180)  // a degree of longitude is this much of a degree of latitude here
        var best = first, bestDistance = Double.infinity, bestPiece = 0
        for (piece, (a, b)) in zip(points, points.dropFirst()).enumerated() {
            let (ax, ay, bx, by) = (a[0] * scale, a[1], b[0] * scale, b[1])
            let (px, py) = (here.1 * scale, here.0)
            let (dx, dy) = (bx - ax, by - ay)
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / length))
            let (cx, cy) = (ax + t * dx, ay + t * dy)
            let d = (px - cx) * (px - cx) + (py - cy) * (py - cy)
            if d < bestDistance {
                bestDistance = d
                best = [cx / scale, cy]
                bestPiece = piece
            }
        }
        return (best, bestPiece)
    }

    /// "Share this spot" (owner, 2026-10-14, by click: sent only when someone taps Share and picks where): the grid
    /// number first, as search and rescue reads it, then latitude/longitude, how good the fix is, and when.
    public static func shareText(latitude: Double, longitude: Double, accuracy: Double, taken: Date,
                                 now: Date = Date()) -> String {
        var lines = ["My location (from PrepareMe):"]
        if let grid = usng(latitude, longitude) { lines.append("USNG \(grid)") }
        lines.append(latLon(latitude, longitude))
        lines.append(fix(accuracy: accuracy, taken: taken, now: now) + "; taken "
                     + taken.formatted(date: .abbreviated, time: .shortened))
        return lines.joined(separator: "\n")
    }

    // MARK: On foot

    /// The Army's rates of march, rests included ("The average number of miles or kilometers to be traveled in a given
    /// period to include all ordered halts"): FM 21-18, Foot Marches, 1 June 1990, Glossary and p. 3-14, which plans
    /// at 4.0, 3.2, 2.4 and 1.6 kph. The quicker is a fit adult on a road by day; the slower allows for children, loads
    /// or rough going.
    public static let walkingKPH = (quick: 4.0, slow: 2.4)

    /// "about 20 to 35 min on foot", "about 1 h 10 min to 2 h on foot": the time at the two rates, rounded to 5
    /// minutes. A straight line is the least a walk can be, so the words say "at least" for one.
    public static func onFoot(_ meters: Double, straightLine: Bool) -> String {
        let quick = walkTime(meters, kph: walkingKPH.quick), slow = walkTime(meters, kph: walkingKPH.slow)
        let short = quick.hasSuffix(" min") && !quick.contains(" h") && slow.hasSuffix(" min") && !slow.contains(" h")
        let span = quick == slow ? quick : short ? "\(quick.dropLast(4)) to \(slow)" : "\(quick) to \(slow)"
        return (straightLine ? "at least " : "about ") + span + " on foot"
    }

    /// "35 min", "1 h", "2 h 15 min": the time at `kph`, rounded to 5 minutes, never under 5.
    public static func walkTime(_ meters: Double, kph: Double = walkingKPH.quick) -> String {
        let minutes = max(5, Int((meters / 1000 / kph * 60 / 5).rounded()) * 5)
        return minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h"
            : "\(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: Which rally point

    /// The Start point first; then rally points in their roles' order (Near home, Outside the neighborhood, Out of
    /// town, then any without a role), in the order they were made within each; then routes: main, alternate, then the
    /// rest.
    public static func ordered(_ marks: [MapMark]) -> [MapMark] {
        func rank(_ mark: MapMark) -> Int {
            switch mark.kind {
            case .start: -1
            case .route: 5 + (mark.routeRole.map { MapMark.RouteRole.allCases.firstIndex(of: $0)! } ?? 2)
            case .rally: mark.role.map { MapMark.Role.allCases.firstIndex(of: $0)! } ?? 3
            case .pin: 4  // in a shared file's picks: after the rally points, before the routes (GPX wants points first)
            }
        }
        return marks.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// The rally point the kids' arrow points to (owner, 2026-10-14, by click): Out of town while Event mode is On,
    /// else Near home; with no point of that role, the other of the two; nil when neither role is used (the arrow
    /// then points to the nearest).
    public static func planned(_ marks: [MapMark], eventOn: Bool) -> MapMark? {
        let rally = marks.filter { $0.kind == .rally }
        let first: MapMark.Role = eventOn ? .outOfTown : .nearHome, second: MapMark.Role = eventOn ? .nearHome : .outOfTown
        return rally.first { $0.role == first } ?? rally.first { $0.role == second }
    }

    /// The meeting place the kids' phones point to, by id (the map pins plan, 2026-11-14), so a card and a row say
    /// "The kids' phones point here"; nil when no meeting place has a role that plans it.
    public static func kidsTarget(_ marks: [MapMark], eventOn: Bool) -> Int64? {
        planned(marks, eventOn: eventOn)?.id
    }

    /// The Pins list's three groups (the map pins plan, 2026-11-14): meeting places and routes in `ordered`'s order;
    /// the other pins nearest first by straight line when the device knows where it is, else newest first (one with no
    /// date last). The Start point is in none.
    public static func pinGroups(marks: [MapMark], pins: [MapMark], here: (latitude: Double, longitude: Double)?)
        -> (meeting: [MapMark], pins: [MapMark], routes: [MapMark]) {
        let ordered = ordered(marks)
        let all = marks.filter { $0.kind == .pin } + pins
        let sorted: [MapMark]
        if let here {
            func away(_ pin: MapMark) -> Double {
                pin.points.first { $0.count == 2 }.map { meters(from: (here.latitude, here.longitude), to: ($0[1], $0[0])) }
                    ?? .infinity
            }
            sorted = all.enumerated().sorted { (away($0.element), $0.offset) < (away($1.element), $1.offset) }.map(\.element)
        } else {
            sorted = all.enumerated().sorted { a, b in
                switch (a.element.made, b.element.made) {
                case let (x?, y?) where x != y: x > y
                case (_?, nil): true
                case (nil, _?): false
                default: a.offset < b.offset
                }
            }.map(\.element)
        }
        return (ordered.filter { $0.kind == .rally }, sorted, ordered.filter { $0.kind == .route })
    }

    /// The rally point named before the phone knows where it is: the planned one, else the first in role order. The
    /// street map's simple view and strip and Today's rally line (beta run 2, R9.1) name the same one.
    public static func plannedOrFirst(_ marks: [MapMark], eventOn: Bool) -> MapMark? {
        planned(marks, eventOn: eventOn) ?? ordered(marks).first { $0.kind == .rally }
    }

    /// Each rally point's number on the printed map and in its legend, in the legend's order (`ordered`), from 1
    /// (remaining-findings plan, Task 11.6; F29; owner, 2026-10-18, by click: numbered markers). Routes have none.
    public static func rallyNumbers(_ marks: [MapMark]) -> [Int64: Int] {
        let rally = ordered(marks).filter { $0.kind == .rally }
        return Dictionary(rally.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
    }

    /// A new rally point's role on the Mac's sheet (remaining-findings plan, Task 11.5; F27; owner, 2026-10-18, by
    /// click): Near home while no rally point has it, so the first one reaches the kids' arrow; else none, to choose.
    public static func newRallyRole(_ marks: [MapMark]) -> MapMark.Role? {
        marks.contains { $0.kind == .rally && $0.role == .nearHome } ? nil : .nearHome
    }

    // MARK: Which route

    /// The route the strip names (the street map fixes plan, task 2.1): the alternate while `alternate` is on and one
    /// is marked, else the main route, else the nearest. Of two with the same role, the first made, so the strip never
    /// swaps routes by itself as another comes nearer (the review's silent swap).
    public static func chosenRoute(_ ways: [Way], alternate: Bool) -> Way? {
        let routes = ways.filter { $0.mark.kind == .route }
        func first(_ role: MapMark.RouteRole) -> Way? {
            routes.filter { $0.mark.routeRole == role }.min { $0.mark.id < $1.mark.id }
        }
        return (alternate ? first(.alternate) : nil) ?? first(.main) ?? routes.first
    }

    /// Use the alternate shows only when both a main and an alternate route are marked.
    public static func canSwitchRoutes(_ marks: [MapMark]) -> Bool {
        MapMark.RouteRole.allCases.allSatisfy { role in marks.contains { $0.kind == .route && $0.routeRole == role } }
    }

    /// Past this from the chosen route, the strip says so (task 2.2): about a block, more than a fix wanders.
    public static let offRouteAfter: Double = 90

    /// "Off route by 300 feet, head northeast", in caution amber; nil on the route or for a rally point. Only once the
    /// phone has been on the route (`joined`; before that the strip says where it joins: owner, 2026-10-25), and only
    /// when even the near edge of the fix's circle is past 300 feet, so a rough fix (Low Power Mode's 100 m) never
    /// warns someone who is on it (the W9 review).
    public static func offRoute(_ way: Way, accuracy: Double, joined: Bool) -> String? {
        guard way.mark.kind == .route, joined, way.meters - max(accuracy, 0) > offRouteAfter else { return nil }
        return "Off route by \(distance(way.meters)), head \(compass(way.bearing))"
    }

    /// On the route, for `offRoute`'s `joined`: even the far edge of the fix's circle within 300 feet of it, so a
    /// rough first fix at home never marks a route joined (the 2026-10-25 review).
    public static func onRoute(_ way: Way, accuracy: Double) -> Bool {
        way.mark.kind == .route && way.meters + max(accuracy, 0) <= offRouteAfter
    }

    /// Under the role on the Mac's rally point sheets: what the role does (F27).
    public static let kidsPointTo =
        "The kids' phones point to the Near home meeting place, or to Out of town while Event mode is On."
}
