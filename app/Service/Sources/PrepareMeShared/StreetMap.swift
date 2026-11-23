import Foundation

/// The street map's file (plan phase 9): one Protomaps file (OpenStreetMap, zoom 0 to 15) the Mac makes with
/// `python -m librarian.streetmap fetch` and the packer lists as kind "map" (packer/streetmap.py). It travels like an
/// optional map (a phone gets it only when asked; the Mac app takes it), and is checked like every file (size and
/// SHA-256), then by `problem` in place of the reader's ZIM checks: it has no libzim checksum and no library ID, and
/// Kiwix never opens it. The map view reads the held copy (`heldFile`).
public enum StreetMap {
    /// The one name the packer gives it, whatever the area.
    public static let fileName = "prepareme-street-map.pmtiles"
    static let headerSize = 127

    /// Why the file isn't a whole PMTiles version 3 file, or nil when it is: the header's directories and metadata fit
    /// inside it, and its tile data ends at the file's end (a cut copy never passes).
    public static func problem(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "it couldn't be opened" }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerSize), head.count == headerSize,
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
                  .uint64Value
        else { return "it is too short to be a map file" }
        guard head.prefix(7) == Data("PMTiles".utf8), head[7] == 3 else { return "it isn't a PMTiles map file" }
        func number(_ at: Int) -> UInt64 {
            head.subdata(in: at..<at + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }
        let sections = [(number(8), number(16)), (number(24), number(32)), (number(40), number(48))]
        let (dataOffset, dataLength) = (number(56), number(64))
        guard number(8) >= UInt64(headerSize),
              sections.allSatisfy({ $0.0 <= size && $0.1 <= size - $0.0 }),
              dataOffset <= size, dataLength == size - dataOffset
        else { return "its parts don't fit the file (a cut or damaged copy)" }
        return nil
    }

    /// Whether the map view is built (it comes with the engine pick): until then the front page's event-mode button to the
    /// street map isn't shown (prepareme-live.js), as it would open an unfinished screen. Set true with the map view.
    public static let viewReady = true

    /// The credit OpenStreetMap's licence asks for, shown on the map whichever engine draws it.
    public static let attribution = "© OpenStreetMap contributors"

    /// What a map file says of itself in its header: the area it covers, where to start, and its zooms.
    public struct Info: Equatable, Sendable {
        public let west: Double, south: Double, east: Double, north: Double
        public let centerLongitude: Double, centerLatitude: Double
        public let centerZoom: Int, minZoom: Int, maxZoom: Int
    }

    /// The file's header read as Info, or nil when it isn't a whole map file (`problem`).
    public static func info(_ file: URL) -> Info? {
        guard problem(file) == nil, let handle = try? FileHandle(forReadingFrom: file),
              let head = try? handle.read(upToCount: headerSize), head.count == headerSize else { return nil }
        try? handle.close()
        func degrees(_ at: Int) -> Double {
            let raw = head.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            return Double(raw.littleEndian) / 1e7
        }
        return Info(west: degrees(102), south: degrees(106), east: degrees(110), north: degrees(114),
                    centerLongitude: degrees(119), centerLatitude: degrees(123), centerZoom: Int(head[118]),
                    minZoom: Int(head[100]), maxZoom: Int(head[101]))
    }

    /// The area every file covers together, for the map's bounds and the view's hold (combined step 9: the home file
    /// and each travel map): the first file's start (the home file's), every file's corners, the widest zooms. Nil for
    /// no file.
    public static func covering(_ infos: [Info]) -> Info? {
        guard let first = infos.first else { return nil }
        return Info(west: infos.map(\.west).min()!, south: infos.map(\.south).min()!, east: infos.map(\.east).max()!,
                    north: infos.map(\.north).max()!, centerLongitude: first.centerLongitude,
                    centerLatitude: first.centerLatitude, centerZoom: first.centerZoom,
                    minZoom: infos.map(\.minZoom).min()!, maxZoom: infos.map(\.maxZoom).max()!)
    }

    /// The map files as the page reads them (combined step 9): the home file, then each travel map in the order given.
    /// The page takes each tile from the first file that holds it (app/StreetMapAssets/web/stack.js), so where the home
    /// file and a travel map overlap, the home file's tile is drawn and nothing is drawn twice.
    public static func pageFiles(travel count: Int) -> [String] {
        ["prepareme-map://tiles/street.pmtiles"] + (0..<count).map { "prepareme-map://tiles/travel/\($0).pmtiles" }
    }

    /// The file a page's tile request names (`pageFiles`), or nil for any other address.
    public static func served(_ url: URL, home: URL, travel: [URL]) -> URL? {
        guard url.host == "tiles" else { return nil }
        if url.path == "/street.pmtiles" { return home }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "travel", parts[2].hasSuffix(".pmtiles") else { return nil }
        let number = parts[2].dropLast(".pmtiles".count)
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), let index = Int(number),
              travel.indices.contains(index) else { return nil }
        return travel[index]
    }

    /// Where the map is looking: kept on each device between uses (`Memory`), so a map shut by the system (iOS ends
    /// a page's process when memory runs low; the trial lost its place that way) opens where it was.
    public struct Camera: Codable, Equatable, Sendable {
        public var longitude: Double, latitude: Double, zoom: Double, bearing: Double, pitch: Double

        public init(longitude: Double, latitude: Double, zoom: Double, bearing: Double = 0, pitch: Double = 0) {
            self.longitude = longitude
            self.latitude = latitude
            self.zoom = zoom
            self.bearing = bearing
            self.pitch = pitch
        }

        /// The file's own starting view.
        public static func start(_ info: Info) -> Camera {
            Camera(longitude: info.centerLongitude, latitude: info.centerLatitude, zoom: Double(info.centerZoom))
        }

        /// Held to the file's area and to zooms that draw (up to 3 past its deepest tiles, which the engines stretch);
        /// a view that isn't a number at all goes back to the start.
        public func held(to info: Info) -> Camera {
            guard [longitude, latitude, zoom, bearing, pitch].allSatisfy(\.isFinite) else { return .start(info) }
            return Camera(longitude: min(max(longitude, info.west), info.east),
                          latitude: min(max(latitude, info.south), info.north),
                          zoom: min(max(zoom, Double(info.minZoom)), Double(info.maxZoom) + 3),
                          bearing: bearing.truncatingRemainder(dividingBy: 360), pitch: min(max(pitch, 0), 60))
        }
    }

    /// Follow me on the phone (the street map fixes plan, task 1.2): Find me with a fix starts it, and each fix then
    /// keeps the map on the phone; Find me again, or the person moving the map, ends it, so the map never pulls back
    /// from under a finger. The Mac never follows: its fix is a one-off each minute.
    /// The strip's route row, when both a main and an alternate route are marked (task 2.2): this phone's own choice.
    public static let useAlternate = "Use the alternate"
    public static let backToMain = "Back to the main route"
    /// The phone's Save as PDF (task 4.2): said over the covered map while it's made, and if the map couldn't give its
    /// picture (the W9 review: fixed words get a test).
    public static let makingPDF = "Making the PDF…"
    public static let pdfNotReady = "Couldn't make the PDF: the map wasn't ready. Try again in a moment."
    /// Under the Start point's name, on the Mac and the phones (hand-off improvements plan, phase 3).
    public static let startPoint = "Where the printed turn lists begin. Put it around the corner, not at the house."

    /// Whether the map's tap sheet offers to add a pin here (the map pins plan, Task 2.5, and its review): an empty spot,
    /// or a held finger on anything but a pin, meeting place or the Start point, which shows its card alone. A storm
    /// warning, a road report or a route line is where a pin is wanted most.
    public static func offersAdding(layers: [String], longPress: Bool) -> Bool {
        layers.isEmpty || (longPress && !layers.contains { ["pm-pin", "pm-rally", "pm-start"].contains($0) })
    }
    /// Under a route's role on the Mac.
    public static let routeRoles = "Phones show the main route, and switch to the alternate when someone taps Use the alternate."

    public struct Follow: Equatable, Sendable {
        public private(set) var on = false

        public init() {}

        public mutating func tapFindMe(hasFix: Bool) { on = !on && hasFix }

        public mutating func dragged() { on = false }
    }

    /// The last view, kept in the app's own defaults.
    public struct Memory: Sendable {
        public static let key = "streetMapCamera"
        let defaults: @Sendable () -> UserDefaults

        public init(defaults: @escaping @Sendable () -> UserDefaults = { .standard }) {
            self.defaults = defaults
        }

        public func camera(for info: Info) -> Camera {
            let kept = defaults().data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Camera.self, from: $0) }
            return (kept ?? .start(info)).held(to: info)
        }

        public func keep(_ camera: Camera) {
            defaults().set(try? JSONEncoder().encode(camera), forKey: Self.key)
        }
    }

    /// When the map page should be reloaded (the web engine, owner 2026-10-14): iOS can end WebKit's helpers while the
    /// app is in the background, and the map then loads no more tiles though the page still answers (maplibre-gl-js
    /// #8461, #8780; reproduced on the simulator, where a reload brought the tiles back). The page reports every 5
    /// seconds whether its tiles are loaded; the app counts the tiles it serves. Reload once the tiles have been
    /// unloaded for `patience` with not one tile served meanwhile, or when the page hasn't reported for `silence`
    /// (its process ended without a word). A reload waits `settle` before the next can happen.
    public struct Watchdog: Equatable, Sendable {
        public static let patience: TimeInterval = 15
        public static let silence: TimeInterval = 20
        public static let settle: TimeInterval = 30
        /// Checks further apart than this mean the app was in the background or the map off screen: the page's
        /// silence then was WebKit pausing it, not a stall (an audit, 2026-10-14).
        public static let gap: TimeInterval = 12
        /// Reloads in a row that never brought the map up wait longer each time: 30 s, 1, 2, 4, then 8 minutes, so
        /// a page that dies at once (out of memory at a heavy view) doesn't reload over and over.
        public static let longestWait: TimeInterval = 8 * 60

        var waitingSince: Date?
        var servedThen = 0
        var heard: Date?
        var reloaded: Date?
        var checked: Date?
        var misses = 0

        public init() {}

        /// A report from the page: whether its tiles are all loaded, and how many tiles the app has served so far.
        /// True when the page should be reloaded now.
        public mutating func report(tilesLoaded: Bool, served: Int, now: Date = Date()) -> Bool {
            heard = now
            guard !tilesLoaded else {
                waitingSince = nil
                return false
            }
            guard let since = waitingSince, served == servedThen else {
                waitingSince = now  // waiting starts, or a tile came meanwhile: the map is loading, slowly or not
                servedThen = served
                return false
            }
            return due(now.timeIntervalSince(since) >= Self.patience, now: now)
        }

        /// Checked on a timer: true when the page has gone quiet while on screen, whether or not it ever came up.
        /// `watching` is false while the map is off screen or the app is in the background: nothing is judged then,
        /// and listening starts over when it is back.
        public mutating func quiet(watching: Bool = true, now: Date = Date()) -> Bool {
            defer { checked = watching ? now : nil }
            guard watching else { return false }
            guard let checked, now.timeIntervalSince(checked) <= Self.gap else {
                heard = now
                waitingSince = nil
                return false
            }
            guard let heard else { return false }
            return due(now.timeIntervalSince(heard) >= Self.silence, now: now)
        }

        /// The page's process ended: true when it may be reloaded now; else the quiet check reloads it later.
        public mutating func ended(now: Date = Date()) -> Bool {
            due(true, now: now)
        }

        /// The page was (re)loaded: start over.
        public mutating func started(now: Date = Date()) {
            waitingSince = nil
            heard = now
        }

        /// The map came up: reloads in a row start counting again.
        public mutating func up(now: Date = Date()) {
            started(now: now)
            misses = 0
        }

        /// How long after a reload the next may come.
        public var wait: TimeInterval {
            min(Self.settle * pow(2, Double(max(0, misses - 1))), Self.longestWait)
        }

        private mutating func due(_ stalled: Bool, now: Date) -> Bool {
            guard stalled, reloaded.map({ now.timeIntervalSince($0) >= wait }) ?? true else { return false }
            reloaded = now
            misses += 1
            waitingSince = nil
            heard = now
            return true
        }
    }

    /// An area named in a link (Find a map's "Show on street map": "west,south,east,north" in degrees), or nil when
    /// it isn't four numbers in order on the globe.
    public static func area(_ text: String?) -> [Double]? {
        guard let text else { return nil }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let box = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, box.count == 4, box.allSatisfy(\.isFinite), box[0] < box[2], box[1] < box[3],
              (-180...180).contains(box[0]), (-180...180).contains(box[2]),
              (-90...90).contains(box[1]), (-90...90).contains(box[3]) else { return nil }
        return box
    }

    /// The device's checked copy of the street map, if it holds one.
    public static func heldFile(_ record: LibraryRecord, in libraryFolder: URL) -> URL? {
        record.held[fileName].map { libraryFolder.appendingPathComponent($0.file) }
    }

    /// The held map's own date, for its age line on the map (the street map fixes plan, task 3.5), as Home Mac reads it.
    public static func built(_ record: LibraryRecord) -> String? {
        record.held[fileName].map { $0.entry.libraryAsOf ?? $0.entry.deliveredAt }
    }
}

extension Manifest.Entry {
    /// The street map (plan phase 9): kind "map" under its one name.
    public var isStreetMap: Bool { kind == "map" && name == StreetMap.fileName }

    /// The extension a copy is kept under: "pmtiles" for the street map, "zim" for every library file.
    public var fileExtension: String { isStreetMap ? "pmtiles" : "zim" }
}
