import Compression
import Foundation

/// "Find a place" on the street map (plan phase 9, item 7): the name list the Mac reads out of the map's own tiles
/// (librarian/streetmap_places.py) and keeps inside the map file, after its last tile, pointed to from the file's own
/// description (its metadata's "prepareme_places": offset into the tile data, length). Towns and neighborhoods, the
/// points of interest that matter in a disaster, and every named road; most house-number addresses aren't there.
public struct PlaceIndex: Equatable, Sendable {
    public struct Place: Equatable, Sendable {
        public let name: String
        public let kind: String  // "town", "hospital", "road", …
        public let longitude: Double
        public let latitude: Double

        public init(name: String, kind: String, longitude: Double, latitude: Double) {
            (self.name, self.kind, self.longitude, self.latitude) = (name, kind, longitude, latitude)
        }

        /// What to call it: its name, or for an unnamed one (drinking water, a spring) what it is.
        public var title: String { name.isEmpty ? PlaceIndex.kindWords(kind) : name }
    }

    /// Words for a kind: "Drinking water", "Fire station".
    public static func kindWords(_ kind: String) -> String {
        switch kind {
        case "road": "Road"
        case "city", "town", "village", "hamlet": "Town"
        case "suburb", "neighbourhood", "quarter", "locality": "Neighborhood"
        case "fuel": "Gas station"
        case "toilets": "Restroom"
        case "doityourself": "Hardware store"
        case "community_centre": "Community center"
        case "doctors": "Doctor"
        default:
            kind.prefix(1).uppercased() + kind.dropFirst().replacingOccurrences(of: "_", with: " ")
        }
    }

    /// What each kind can be searched for by, besides its name (owner, 2026-10-14, by click: "pharmacy", "water",
    /// "gas"); a search of three letters or more that starts one of these finds every place of that kind, nearest
    /// first.
    public static let kindSearch: [String: [String]] = [
        "drinking_water": ["water", "drinking water"], "spring": ["water", "spring"], "water_point": ["water"],
        "water_well": ["water", "well"], "shelter": ["shelter"], "animal_shelter": ["animal shelter"],
        "fuel": ["gas", "gas station", "fuel"], "charging_station": ["charging", "ev charging"],
        "toilets": ["restroom", "toilet", "bathroom"], "hospital": ["hospital", "emergency room"],
        "clinic": ["clinic", "urgent care", "doctor"], "doctors": ["doctor"],
        "pharmacy": ["pharmacy", "drugstore", "medicine"], "fire_station": ["fire station"],
        "police": ["police", "sheriff"], "ambulance_station": ["ambulance", "ems"],
        "emergency_service": ["emergency"], "supermarket": ["grocery", "supermarket", "food"],
        "convenience": ["convenience store", "food"], "hardware": ["hardware"], "doityourself": ["hardware"],
        "veterinary": ["vet", "veterinary"], "camp_site": ["campground", "camping"],
        "community_centre": ["community center"], "townhall": ["town hall"], "post_office": ["post office"],
        "library": ["library"], "school": ["school"], "place_of_worship": ["church", "place of worship"],
    ]

    /// The kinds a search finds by what they are.
    static func kinds(for wanted: String) -> Set<String> {
        guard wanted.count >= 3 else { return [] }
        return Set(kindSearch.filter { $0.value.contains { $0.hasPrefix(wanted) } }.keys)
    }

    /// The places packed (a stress test, 2026-10-14: 1.4 million names as separate strings and byte arrays kept 613 MB
    /// on the Mac, more than an older phone spares beside the map): every name's UTF-8 in one buffer, every folded name
    /// in another, each with its start (and a last end), a kind's index, and each position to about a meter.
    let kinds: [String]
    let names: [UInt8]
    let nameStarts: [UInt32]
    /// Each name folded for matching (any case or accent), made once: folding them all on every keystroke left the
    /// search box unusable on a phone (2026-10-14).
    let keys: [UInt8]
    let keyStarts: [UInt32]
    let kindOf: [UInt16]
    let longitudes: [Float]
    let latitudes: [Float]

    public var count: Int { kindOf.count }

    public subscript(_ i: Int) -> Place {
        Place(name: String(decoding: names[Int(nameStarts[i])..<Int(nameStarts[i + 1])], as: UTF8.self),
              kind: kinds[Int(kindOf[i])], longitude: Double(longitudes[i]), latitude: Double(latitudes[i]))
    }

    /// Every place (for tests and small lists: a whole map's list is better read one at a time).
    public var places: [Place] { (0..<count).map { self[$0] } }

    public init(places: [Place]) {
        var builder = Builder()
        for place in places { builder.add(name: Array(place.name.utf8), kind: place.kind, place.longitude, place.latitude) }
        self.init(builder)
    }

    init(_ b: Builder) {
        (kinds, names, nameStarts, keys, keyStarts, kindOf, longitudes, latitudes) =
            (b.kinds, b.names, b.nameStarts, b.keys, b.keyStarts, b.kindOf, b.longitudes, b.latitudes)
    }

    struct Builder {
        var kinds: [String] = []
        var kindAt: [String: UInt16] = [:]
        var names: [UInt8] = [], nameStarts: [UInt32] = [0]
        var keys: [UInt8] = [], keyStarts: [UInt32] = [0]
        var kindOf: [UInt16] = [], longitudes: [Float] = [], latitudes: [Float] = []

        mutating func add(name: [UInt8], kind: String, _ longitude: Double, _ latitude: Double) {
            let k: UInt16
            if let known = kindAt[kind] {
                k = known
            } else {
                k = UInt16(kinds.count)
                kindAt[kind] = k
                kinds.append(kind)
            }
            add(name: name, kind: k, longitude, latitude)
        }

        mutating func add(name: [UInt8], kind k: UInt16, _ longitude: Double, _ latitude: Double) {
            names += name
            nameStarts.append(UInt32(names.count))
            let ascii = !name.contains { $0 >= 0x80 || $0 == 0x27 || $0 == 0x22 }
            keys += ascii ? name.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
                : Array(PlaceIndex.fold(String(decoding: name, as: UTF8.self)).utf8)
            keyStarts.append(UInt32(keys.count))
            kindOf.append(k)
            longitudes.append(Float(longitude))
            latitudes.append(Float(latitude))
        }
    }

    static func fold(_ text: String) -> String {
        var straight = ""
        straight.unicodeScalars.append(contentsOf: text.unicodeScalars.map { scalar in
            switch scalar {
            case "\u{2018}", "\u{2019}", "\u{201B}", "\u{2032}", "\u{02BC}": "'"
            case "\u{201C}", "\u{201D}", "\u{201F}", "\u{2033}": "\""
            default: scalar
            }
        })
        return straight.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The list in a map file, or nil when the file has none (a map made before the list, or one that can't be read).
    public init?(mapFile url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 127), head.count == 127 else { return nil }
        func number(_ at: Int) -> UInt64 {
            head.subdata(in: at..<at + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }
        let (metaOffset, metaLength, dataOffset) = (number(24), number(32), number(56))
        guard metaLength > 0, metaLength < 1 << 24, (try? handle.seek(toOffset: metaOffset)) != nil,
              let metaRaw = try? handle.read(upToCount: Int(metaLength)), let meta = Gzip.inflate(metaRaw),
              let found = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
              let pointer = found["prepareme_places"] as? [String: Any],
              let offset = (pointer["offset"] as? NSNumber)?.uint64Value,
              let length = (pointer["length"] as? NSNumber)?.intValue, length > 0, length < 1 << 30,
              (try? handle.seek(toOffset: dataOffset + offset)) != nil,
              let raw = try? handle.read(upToCount: length), raw.count == length,
              let list = Gzip.inflate(raw) else { return nil }
        self.init(list: list)
    }

    /// The list's own JSON: {"format": 1, "kinds": [...], "places": [[name, kind index, lon, lat], ...]}, read by
    /// its own small reader straight into the packed store (JSONSerialization made an object of every name first).
    /// Anything else is refused whole.
    public init?(list: Data) {
        var reader = ListReader(Array(list))
        guard let built = reader.read() else { return nil }
        self.init(built)
    }

    /// Places whose name holds `text` (any case or accent), or whose kind it names ("pharmacy", "water"): names
    /// starting with it and places of that kind first, then the nearest to `near` (latitude, longitude) when the phone
    /// knows where it is, else towns before other places before roads.
    public func search(_ text: String, near: (Double, Double)? = nil, limit: Int = 25) -> [Place] {
        let folded = Self.fold(text).trimmingCharacters(in: .whitespaces)
        let wanted = Array(folded.utf8)
        guard !wanted.isEmpty else { return [] }
        let byKind = Set(Self.kinds(for: folded).compactMap { kind in kinds.firstIndex(of: kind).map(UInt16.init) })
        var found: [(Int, Int, Double)] = []  // index, 0 when the name starts with it or it is of the kind, the order
        keys.withUnsafeBufferPointer { all in
            wanted.withUnsafeBufferPointer { needle in
                for i in 0..<count {
                    let at = byKind.contains(kindOf[i]) ? 0
                        : Self.find(needle, in: all, from: Int(keyStarts[i]), to: Int(keyStarts[i + 1]))
                    guard let at else { continue }
                    let order = near.map {
                        Position.meters(from: $0, to: (Double(latitudes[i]), Double(longitudes[i])))
                    } ?? Double(Self.rank(kinds[Int(kindOf[i])]))
                    found.append((i, at == 0 ? 0 : 1, order))
                }
            }
        }
        let best = found.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.prefix(max(limit * 8, 200)).map { ($0, self[$0.0]) }
        var kept: [Place] = []
        for (_, place) in best.sorted(by: { ($0.0.1, $0.0.2, $0.1.name) < ($1.0.1, $1.0.2, $1.1.name) }) {
            // one long road is kept once per map square; a name and kind within about half a mile is shown once
            // (a stress test, 2026-10-14). Unnamed places are each their own.
            if !place.name.isEmpty, kept.contains(where: { $0.name == place.name && $0.kind == place.kind
                && Position.meters(from: ($0.latitude, $0.longitude), to: (place.latitude, place.longitude)) < 800 }) {
                continue
            }
            kept.append(place)
            if kept.count == limit { break }
        }
        return kept
    }

    /// Where `needle` first appears in `hay[from..<to]`, counted from `from`, by bytes (both folded the same way).
    static func find(_ needle: UnsafeBufferPointer<UInt8>, in hay: UnsafeBufferPointer<UInt8>, from: Int,
                     to: Int) -> Int? {
        guard needle.count <= to - from, let first = needle.first else { return nil }
        var i = from
        let last = to - needle.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i - from }
            }
            i += 1
        }
        return nil
    }

    static func rank(_ kind: String) -> Int {
        switch kind {
        case "city", "town", "village", "hamlet", "locality", "suburb", "neighbourhood", "quarter": 0
        case "road": 2
        default: 1
        }
    }
}

/// The place list's JSON read byte by byte into the packed store: exactly {"format": 1, "kinds": [strings], "places":
/// [[string, whole number, number, number], ...]} with any whitespace between, keys in any order; nil on anything else.
struct ListReader {
    let b: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) { b = bytes }

    mutating func read() -> PlaceIndex.Builder? {
        var format: Double?, kinds: [String]?, builder = PlaceIndex.Builder()
        var rows: [(name: [UInt8], kind: Int, lon: Double, lat: Double)] = []
        guard take(UInt8(ascii: "{")) else { return nil }
        repeat {
            guard let key = string() else { return nil }
            guard take(UInt8(ascii: ":")) else { return nil }
            switch String(decoding: key, as: UTF8.self) {
            case "format": format = number()
            case "kinds":
                guard take(UInt8(ascii: "[")) else { return nil }
                var found: [String] = []
                if !take(UInt8(ascii: "]")) {
                    repeat {
                        guard let kind = string() else { return nil }
                        found.append(String(decoding: kind, as: UTF8.self))
                    } while take(UInt8(ascii: ","))
                    guard take(UInt8(ascii: "]")) else { return nil }
                }
                guard kinds == nil else { return nil }  // twice is refused
                kinds = found
                builder.kinds = found
                for (n, kind) in found.enumerated() { builder.kindAt[kind] = UInt16(n) }
            case "places":
                guard take(UInt8(ascii: "[")) else { return nil }
                if !take(UInt8(ascii: "]")) {
                    repeat {
                        guard take(UInt8(ascii: "[")), let name = string(), take(UInt8(ascii: ",")),
                              let k = number(), k == k.rounded(), k >= 0, k < 65536, take(UInt8(ascii: ",")),
                              let lon = number(), take(UInt8(ascii: ",")), let lat = number(),
                              take(UInt8(ascii: "]")) else { return nil }
                        if let kinds {  // the list's own order puts kinds first: straight into the store
                            guard Int(k) < kinds.count else { return nil }
                            builder.add(name: name, kind: UInt16(k), lon, lat)
                        } else {
                            rows.append((name, Int(k), lon, lat))
                        }
                    } while take(UInt8(ascii: ","))
                    guard take(UInt8(ascii: "]")) else { return nil }
                }
            default:
                return nil
            }
        } while take(UInt8(ascii: ","))
        guard take(UInt8(ascii: "}")), skip() == b.count, format == 1, let kinds else { return nil }
        for row in rows {  // places that came before the kinds
            guard row.kind < kinds.count else { return nil }
            builder.add(name: row.name, kind: UInt16(row.kind), row.lon, row.lat)
        }
        return builder
    }

    /// Past any whitespace; where that leaves the reader.
    @discardableResult
    mutating func skip() -> Int {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        return i
    }

    mutating func take(_ byte: UInt8) -> Bool {
        skip()
        guard i < b.count, b[i] == byte else { return false }
        i += 1
        return true
    }

    /// A JSON string's UTF-8, its escapes undone.
    mutating func string() -> [UInt8]? {
        guard take(UInt8(ascii: "\"")) else { return nil }
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            i += 1
            switch c {
            case UInt8(ascii: "\""): return out
            case UInt8(ascii: "\\"):
                guard i < b.count else { return nil }
                let e = b[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard var unit = hex4() else { return nil }
                    if (0xD800..<0xDC00).contains(unit), i + 1 < b.count, b[i] == UInt8(ascii: "\\"),
                       b[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        guard let low = hex4(), (0xDC00..<0xE000).contains(low) else { return nil }
                        unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(unit) else { return nil }
                    out += Array(String(Character(scalar)).utf8)
                default: return nil
                }
            default:
                guard c >= 0x20 else { return nil }
                out.append(c)
            }
        }
        return nil
    }

    mutating func hex4() -> UInt32? {
        guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else {
            return nil
        }
        i += 4
        return v
    }

    mutating func number() -> Double? {
        skip()
        let start = i
        while i < b.count, (0x30...0x39).contains(b[i]) || [0x2D, 0x2B, 0x2E, 0x65, 0x45].contains(b[i]) { i += 1 }
        guard i > start else { return nil }
        return Double(String(decoding: b[start..<i], as: UTF8.self)).flatMap { $0.isFinite ? $0 : nil }
    }
}

/// gzip, unpacked with Apple's Compression (raw DEFLATE after gzip's header; its trailer gives the size).
enum Gzip {
    static func inflate(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var at = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard at + 2 <= bytes.count else { return nil }
            at += 2 + Int(bytes[at]) + Int(bytes[at + 1]) << 8
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT: zero-ended
            while at < bytes.count, bytes[at] != 0 { at += 1 }
            at += 1
        }
        if flags & 0x02 != 0 { at += 2 }  // FHCRC
        let end = bytes.count - 8
        guard at < end else { return nil }
        let size = Int(bytes[end + 4]) | Int(bytes[end + 5]) << 8 | Int(bytes[end + 6]) << 16 | Int(bytes[end + 7]) << 24
        guard size > 0, size < 1 << 31 else { return size == 0 ? Data() : nil }
        var out = [UInt8](repeating: 0, count: size)
        let written = bytes[at..<end].withUnsafeBufferPointer { source in
            compression_decode_buffer(&out, size, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
        }
        return written == size ? Data(out) : nil
    }
}
