import Foundation

/// A phone's own pins on the street map (plan phase 9, item 8): "tree down here", "car parked here". Kept on that
/// phone, never sent to the Mac or another phone unless someone shares them by hand (Share my pins, task 4.1). In the
/// device's own backup since the audit's D1 (owner, 2026-11-22, by click): they exist nowhere else. A pin's words are one of `Label`'s fixed set, never typed: nothing typed on a phone passes the
/// Mac's ID check, and codes, account numbers and the like are never stored anywhere (CLAUDE.md), so there is no box to
/// type one in. Saved whole (DurableFile) in the app's own folder, at most `limit` pins.
public struct PersonalPins: Codable, Equatable, Sendable {
    public enum Label: String, Codable, CaseIterable, Sendable {
        case treeDown = "Tree down"
        case flooded = "Road flooded"
        case blocked = "Road blocked"
        case powerLine = "Power line down"
        case danger = "Danger"
        case water = "Water"
        case shelter = "Shelter"
        case meet = "Meet here"
        case car = "Car parked"
        case other = "Marked spot"
    }

    /// Remove this pin's question (the street map fixes plan, task 3.1): "Remove the Water pin?"
    public static func removeQuestion(_ label: Label) -> String { "Remove the \(label.rawValue) pin?" }
    /// The map's visible way to add a pin where the phone is (look 3, spec section 8, fix 6): a long press was the only one.
    public static let addWhereIAm = "Add a pin where I am"

    public struct Pin: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public var label: Label
        public let longitude: Double
        public let latitude: Double
        public let placed: Date
    }

    public static let fileName = "personal-pins.json"
    public static let limit = 200

    public private(set) var pins: [Pin] = []
    /// A file that read but made no sense was renamed to this (in the same folder), and the pins started empty (D3).
    public private(set) var setAside: String?
    /// The file was there but couldn't be read (still locked after a restart, say), or couldn't be renamed: these pins
    /// are never saved, so nothing is written over it.
    public private(set) var blocked = false

    enum CodingKeys: String, CodingKey { case pins }

    /// What the map says, once, when the file was set aside or saving is blocked.
    public static let setAsideWords = "Your pins file couldn't be read. It was kept aside; new pins start a fresh list."
    public static let blockedWords = "Your pins file couldn't be read, so new pins can't be saved right now."
    public var problem: String? { blocked ? Self.blockedWords : setAside == nil ? nil : Self.setAsideWords }

    /// At `limit`: the spot's sheet says so in place of the kinds (task 3.3).
    public var full: Bool { pins.count >= Self.limit }

    public static func fullWords(device: String) -> String {
        "This \(device) holds \(limit) pins, the most it keeps. Remove one to add another."
    }

    public init(pins: [Pin] = []) {
        self.pins = pins
    }

    /// Add a pin at a spot on the map; nil when the spot isn't on the map or there are already `limit`.
    @discardableResult
    public mutating func add(_ label: Label, longitude: Double, latitude: Double, at now: Date = Date()) -> Pin? {
        guard pins.count < Self.limit, longitude.isFinite, latitude.isFinite, (-180...180).contains(longitude),
              (-85.0511...85.0511).contains(latitude) else { return nil }
        let pin = Pin(id: UUID(), label: label, longitude: (longitude * 1e6).rounded() / 1e6,
                      latitude: (latitude * 1e6).rounded() / 1e6,
                      placed: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))  // as saved
        pins.append(pin)
        return pin
    }

    public mutating func relabel(_ id: UUID, _ label: Label) {
        if let i = pins.firstIndex(where: { $0.id == id }) { pins[i].label = label }
    }

    public mutating func remove(_ id: UUID) {
        pins.removeAll { $0.id == id }
    }

    /// Every pin removed (Delete the old pins), still never saved over a file that couldn't be read.
    public mutating func removeAll() {
        pins.removeAll()
    }

    /// The pins in `folder`, or none when there is no file. A file that can't be read now is left alone and the pins
    /// are `blocked`; one that reads but makes no sense is set aside with the date, as the game saves' (audit D3).
    public static func load(_ folder: URL, now: Date = Date()) -> PersonalPins {
        let url = folder.appendingPathComponent(fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var store = PersonalPins()
        switch GameSaves.read(url, as: PersonalPins.self, decoder: decoder) {
        case .none: break
        case .found(let found):
            LibraryStore.excludeFromBackup(url, false)  // an earlier build's mark taken off (D1)
            store.pins = Array(found.pins.prefix(limit))
        case .unreadable:
            store.blocked = true
        case .damaged:
            store.setAside = GameSaves.setAside(url, stem: "personal-pins", now: now)
            store.blocked = store.setAside == nil
        }
        return store
    }

    /// Saved whole (in the device's backup; never over a file that couldn't be read).
    public func save(_ folder: URL) throws {
        if blocked { throw CocoaError(.fileWriteNoPermission) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.fileName)
        try DurableFile.write(try encoder.encode(self), to: url)
    }

    // MARK: Sharing between phones (the street map fixes plan, task 4.1)

    /// The file Share my pins sends (AirDrop, Messages) and Add pins from a file reads: only each pin's kind, place,
    /// time and id, never typed words, under a mark that says what it is.
    public static let sharedFileName = "PrepareMe pins.json"
    public static let sharedType = "com.bigmike382.prepareme.pins"
    public static let readWrong = "That file isn't PrepareMe pins."
    /// Far more than 200 pins make; the app checks a picked file's size against it before reading it.
    public static let sharedMaxBytes = 1_000_000

    private struct Shared: Codable {
        let prepareme: String
        let version: Int
        let pins: [Pin]
    }

    public func shared() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Shared(prepareme: "pins", version: 1, pins: pins))
    }

    /// A shared file's pins, or nil for anything else: no mark, a kind not in the fixed set, a pin off the map, or a
    /// file far bigger than 200 pins make (it came from outside the app, so it is read with care).
    public static func read(shared data: Data) -> [Pin]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard data.count < sharedMaxBytes, let found = try? decoder.decode(Shared.self, from: data),
              found.prepareme == "pins", found.version == 1,
              found.pins.allSatisfy({ $0.longitude.isFinite && $0.latitude.isFinite
                  && (-180...180).contains($0.longitude) && (-85.0511...85.0511).contains($0.latitude) })
        else { return nil }
        return found.pins
    }

    /// Another phone's pins added to these: one of the same kind within 5 m (or the same pin) is the same spot, and the
    /// newer of the two is kept; the rest are added while there is room, never past `limit`.
    public func merged(with others: [Pin]) -> (pins: PersonalPins, added: Int, already: Int, leftOut: Int) {
        var kept = pins, added = 0, already = 0, leftOut = 0
        for pin in others {
            if let i = kept.firstIndex(where: { $0.id == pin.id || ($0.label == pin.label
                   && Position.meters(from: ($0.latitude, $0.longitude), to: (pin.latitude, pin.longitude)) <= 5) }) {
                already += 1
                if pin.placed > kept[i].placed { kept[i] = pin }
            } else if kept.count < Self.limit {
                kept.append(pin)
                added += 1
            } else {
                leftOut += 1
            }
        }
        var merged = self  // keeps `blocked`: a file that couldn't be read is never written over (D3)
        merged.pins = kept
        return (merged, added, already, leftOut)
    }

    /// What Add pins from a file says once it's done: "Added 3 pins. 1 was already here."
    public static func mergeWords(added: Int, already: Int, leftOut: Int, device: String) -> String {
        var words = "Added \(added) \(added == 1 ? "pin" : "pins")."
        if already > 0 { words += " \(already) \(already == 1 ? "was" : "were") already here." }
        if leftOut > 0 { words += " \(leftOut) left out: this \(device) holds \(limit) pins, the most it keeps." }
        return words
    }

    /// As GeoJSON points for the map, each with its label and its id as `pin`: MapLibre turns a string feature id into
    /// a number (`parseInt`), so a tapped pin's own id comes back only as a property (an audit, 2026-10-14).
    public var geoJSON: Data {
        (try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features],
                                     options: [.sortedKeys])) ?? Data()
    }

    var features: [[String: Any]] {
        pins.map { pin in
            ["type": "Feature",
             "geometry": ["type": "Point", "coordinates": [pin.longitude, pin.latitude]],
             "properties": ["kind": "pin", "label": pin.label.rawValue, "pin": pin.id.uuidString,
                            "color": pin.label.mapColor, "nightColor": pin.label.nightColor,
                            "nightIcon": pin.label.nightIcon]]
        }
    }
}

/// Each kind's look (the street map fixes plan, task 3.2): one of BASE's color roles and an SF Symbol, the same on the
/// map, in the spot's sheet and on the Mac. The symbol is a shape of its own, so red night keeps the kinds apart.
extension PersonalPins.Label {
    /// The BASE token: blue a key fact, green fine, red danger, amber caution.
    public var color: String {
        switch self {
        case .water: "info-mark"
        case .shelter: "ok-mark"
        case .danger, .powerLine: "red-mark"
        case .treeDown, .flooded, .blocked, .car, .meet, .other: "accent"
        }
    }

    public var symbol: String {
        switch self {
        case .treeDown: "tree.fill"
        case .flooded: "water.waves"
        case .blocked: "nosign"
        case .powerLine: "bolt.fill"
        case .danger: "exclamationmark.triangle.fill"
        case .water: "drop.fill"
        case .shelter: "house.fill"
        case .meet: "person.2.fill"
        case .car: "car.fill"
        case .other: "mappin"
        }
    }

    /// The map's fill: the token's light value on both map themes, dark enough under the white symbol.
    var mapColor: String { String(format: "#%06x", Palette.tokens[color]?.light ?? 0) }

    /// Red night keeps only red (the W9 review, owner 2026-10-25): a red or amber dot comes out mid red, where a white
    /// symbol is faint, so those kinds' symbols are drawn dark, and danger's dot white, so it stays the brightest
    /// (CLAUDE.md, red night). Blue and green dots come out near black and keep their white symbol.
    public var nightDark: Bool { color == "red-mark" || color == "accent" }
    public var nightColor: String { color == "red-mark" ? "#ffffff" : mapColor }
    public var nightIcon: String { (nightDark ? "pm-pin-dark-" : "pm-pin-") + rawValue }
}
