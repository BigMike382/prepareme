import Combine
import Foundation

/// The travel street maps (combined step 9; concept-doc plan, phase I; docs/plans/2026-10-20-step-9-travel-maps.md):
/// one map file per state, made on the Mac on the owner's word (`python -m librarian.streetmap travel`) straight into
/// iCloud Drive › PrepareMe Travel Maps, with that folder's `manifest.json` (librarian/streetmap.py, TRAVEL_FIELDS; the
/// shape both sides read is pinned by Fixtures/travel-maps-manifest.json). A phone takes a state from that folder
/// (Home Mac › Add a travel map), checked three ways against the list, as phase B's Add from Files checks a file
/// (the list names it, its size, its SHA-256), then as a whole map file (`StreetMap.problem`), and keeps it in its own
/// storage (`TravelStore`). The street map draws it with the home file (`StreetMap.pageFiles`).
///
/// - Never in the delivery folder, the iCloud backup or a USB-C drive copied from it: they can be made again (owner,
///   2026-10-20, by click). The folder's list isn't signed (phase B's is): a travel file is only map tiles, read by the
///   map's page, never by the reader.
/// - The phone never re-syncs a copy it keeps: the app's own folder, out of the phone's backups.
public enum TravelMaps {
    public static let folderName = "PrepareMe Travel Maps"
    public static let manifestName = "manifest.json"
    public static let format = 1

    /// One state's file, as the folder's list gives it
    public struct Entry: Codable, Equatable, Sendable {
        public var state: String
        public var name: String
        /// The Protomaps build (YYYYMMDD): the OpenStreetMap data's date
        public var build: String
        public var size: Int64
        public var sha256: String
        /// When the Mac made it
        public var made: String

        public init(state: String, name: String, build: String, size: Int64, sha256: String, made: String) {
            self.state = state
            self.name = name
            self.build = build
            self.size = size
            self.sha256 = sha256
            self.made = made
        }
    }

    public struct List: Codable, Equatable, Sendable {
        public var format: Int
        public var files: [Entry]

        public init(format: Int, files: [Entry]) {
            self.format = format
            self.files = files
        }
    }

    public enum ListProblem: Error, Equatable {
        case unreadable, wrongFormat, badEntry(String)
    }

    /// The folder's list, refused unless every entry is a state's own file, once, with a whole SHA-256 and a size
    public static func read(_ data: Data) throws -> List {
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw ListProblem.unreadable }
        guard list.format == format else { throw ListProblem.wrongFormat }
        var seen = Set<String>()
        for entry in list.files {
            guard stateNames[entry.state] != nil, entry.name == fileName(entry.state), Hex.isSHA256(entry.sha256),
                  entry.size > 0, entry.build.count == 8, entry.build.allSatisfy(\.isASCII), Int(entry.build) != nil,
                  seen.insert(entry.state).inserted
            else { throw ListProblem.badEntry(entry.name) }
        }
        return list
    }

    /// A state's file's one name, as librarian/streetmap.py's `travel_name` gives it
    public static func fileName(_ state: String) -> String { "prepareme-travel-map-\(state.lowercased()).pmtiles" }

    public static func isFileName(_ name: String) -> Bool {
        stateNames.keys.contains { fileName($0) == name }
    }

    /// The OpenStreetMap data's date (YYYY-MM-DD) from a build's YYYYMMDD
    public static func built(_ build: String) -> String? {
        guard build.count == 8, Int(build) != nil else { return nil }
        let digits = Array(build)
        return "\(String(digits[0..<4]))-\(String(digits[4..<6]))-\(String(digits[6..<8]))"
    }

    // MARK: What the folder offers

    public enum Standing: Equatable, Sendable {
        case missing, newer, same
        /// This phone's copy is newer: never taken back to the folder's
        case older
        /// Listed, but not in the folder at its listed size: iCloud is still bringing it (or a newer copy) from the Mac
        case notWhole
    }

    public struct Item: Equatable, Sendable {
        public var entry: Entry
        public var standing: Standing
        /// This phone's copy of the state, if it holds one
        public var held: Entry?
        public var canAdd: Bool { standing == .missing || standing == .newer }
    }

    /// Each state the list names, against what the phone holds. `present`: the folder's plain names and sizes, with
    /// an iCloud placeholder's real name at `FolderOffer.inICloud` (FolderOffer.present), which counts as there: the
    /// copy has iCloud bring it down.
    public static func offer(_ list: List, present: [String: Int64], held: [TravelHeld]) -> [Item] {
        list.files.sorted { $0.state < $1.state }.map { entry in
            let mine = held.first { $0.entry.state == entry.state }?.entry
            let standing: Standing
            if let size = present[entry.name], size == entry.size || size == FolderOffer.inICloud {
                if let mine {
                    standing = mine.sha256 == entry.sha256 ? .same
                        : (entry.build, entry.made) > (mine.build, mine.made) ? .newer : .older
                } else {
                    standing = .missing
                }
            } else {
                standing = .notWhole
            }
            return Item(entry: entry, standing: standing, held: mine)
        }
    }

    // MARK: The three checks

    public enum Verdict: Equatable, Sendable {
        case ok
        /// The folder's list doesn't name this file
        case notNamed
        case wrongSize(Int64)
        case wrongHash
        /// Named, whole and the listed bytes, but not a whole map file
        case notAMap(String)
    }

    /// A copy taken from the folder, checked against the folder's list: the list names it, its size, its SHA-256 (phase
    /// B's three), then as a whole map file. Blocking: run off the main thread.
    public static func check(_ copy: URL, as name: String, against list: List) throws -> Verdict {
        guard let entry = list.files.first(where: { $0.name == name }) else { return .notNamed }
        switch try FileCheck.verify(copy, size: entry.size, sha256: entry.sha256) {
        case .ok: break
        case let .wrongSize(actual): return .wrongSize(actual)
        case .wrongHash: return .wrongHash
        }
        if let problem = StreetMap.problem(copy) { return .notAMap(problem) }
        return .ok
    }

    // MARK: Room (phase M's rule, as Get this file and Add from Files have it)

    /// The free space a state needs: its size and the 1 GB spare, twice its size while iCloud first brings it to the
    /// phone (its downloaded copy and the phone's own sit side by side while copying)
    public static func need(_ entry: Entry, inICloudOnly: Bool) -> Int64 {
        entry.size * (inICloudOnly ? 2 : 1) + LibraryPlan.spareBytes
    }

    /// Nil when there's room; else the words to say why not
    public static func noRoom(_ entry: Entry, inICloudOnly: Bool, free: Int64, device: String = "phone") -> String? {
        let need = need(entry, inICloudOnly: inICloudOnly)
        guard free < need else { return nil }
        let sizes = StorageWords.room(need: need, free: free)
        return "\(title(entry))'s map needs \(sizes.need) free to copy and check; this \(device) has "
            + "\(sizes.free). Remove something under Downloads first."
    }

    // MARK: Words (the owner's look at the gate)

    /// The plan's three limits, said on Add a travel map
    public static let limits = [
        "Taking a map from iCloud needs internet: do it before you leave.",
        "Turn-by-turn directions come from Organic Maps: download the same states there too.",
        "A map is as old as the day the Mac made it. Its date shows under it.",
    ]

    public static func intro(device: String = "phone") -> String {
        "Street maps of other states, for travel, from the \(folderName) folder in iCloud Drive. Each is checked before "
            + "this \(device) keeps it, and the street map shows it with the home map."
    }

    public static let waitForICloud = "Not in the folder whole yet: iCloud is still bringing it from the Mac. Wait a "
        + "while with internet on, then try again."
    public static let noList = "This folder has no travel maps list (manifest.json). Pick the \(folderName) folder "
        + "itself."
    public static let damagedList = "This folder's travel maps list can't be read, so nothing is added from it."
    public static let added = "Added and checked."

    /// A Remove that failed (phase K, finding 9): the state stays listed under this line
    public static func removeFailed(_ entry: Entry, reason: String, device: String = "phone") -> String {
        "Couldn't remove \(title(entry)): \(reason). It's still on this \(device)."
    }

    /// This phone's own record can't be read (phase K, finding 10; `TravelStore.locked`), said on Home Mac › Street
    /// map and on Add a travel map, with Start over (the owner's choice 2, 2026-10-20) behind its question
    public static func damagedRecord(device: String = "phone") -> String {
        "This \(device)'s list of travel maps is damaged, so they can't be shown or removed."
    }

    public static let startOver = "Start over"

    public static func startOverQuestion(device: String = "phone") -> String {
        "Remove every travel map from this \(device)? You can add them again from Files."
    }

    /// Why a copy wasn't kept
    public static func refusal(_ verdict: Verdict) -> String {
        switch verdict {
        case .ok: return added
        case .notNamed: return "The folder's list doesn't name this file, so it wasn't kept."
        case .wrongSize, .wrongHash:
            return "This copy isn't whole or isn't the one the folder's list names, so it wasn't kept. iCloud may "
                + "still be bringing it from the Mac: wait a while with internet on, then try again."
        case let .notAMap(why): return "It isn't a whole map file (\(why)), so it wasn't kept."
        }
    }

    /// The state's own name, for a file
    public static func title(_ entry: Entry) -> String { stateNames[entry.state] ?? entry.state }

    /// Under each state the folder offers
    public static func takes(_ entry: Entry, device: String = "phone") -> String {
        "Takes \(StorageWords.size(entry.size)) on this \(device)."
    }

    /// Under each state the phone holds: the map age line's words
    public static func heldLine(_ held: TravelHeld) -> String {
        "OpenStreetMap as of \(built(held.entry.build) ?? held.entry.build), \(StorageWords.size(held.entry.size))."
    }

    public static func standingLine(_ item: Item, device: String = "phone") -> String {
        switch item.standing {
        case .missing: return "OpenStreetMap as of \(built(item.entry.build) ?? item.entry.build)."
        case .newer:
            return "OpenStreetMap as of \(built(item.entry.build) ?? item.entry.build); this \(device)'s is from "
                + "\(item.held.flatMap { built($0.build) } ?? "earlier")."
        case .same: return "The same as this \(device)'s."
        case .older: return "This \(device)'s copy is newer, so it stays."
        case .notWhole: return waitForICloud
        }
    }

    /// The 50 states and DC, as the outlines name them (librarian/streetmap.py's US_STATES)
    public static let stateNames: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "DC": "Washington, DC", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts",
        "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri", "MT": "Montana",
        "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico",
        "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
        "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
        "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington",
        "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
    ]
}

/// A travel map this phone keeps: the list's entry it passed against, and its file's name in the travel folder
public struct TravelHeld: Codable, Equatable, Sendable {
    public var entry: TravelMaps.Entry
    public var file: String

    public init(entry: TravelMaps.Entry, file: String) {
        self.entry = entry
        self.file = file
    }
}

/// The phone's travel maps on disk: Application Support › PrepareMe › travel (`maps`, each under a name of its own;
/// `incoming`, a copy waiting for its checks), out of the phone's backups, and its record, `travel-maps.json`, saved
/// whole (DurableFile). A new copy of a state is recorded before the old one is deleted. A record there but unreadable
/// is never written over: nothing is kept or removed, and Add refuses before copying, until Start over deletes it and
/// every travel map (phase K, the owner's choice 2). What a stopped add or a failed delete leaves is cleared when Add a
/// travel map opens (`clearLeftovers`).
@MainActor
public final class TravelStore: ObservableObject {
    public static let recordName = "travel-maps.json"
    nonisolated public let root: URL
    nonisolated public let folder: URL
    nonisolated public let incomingFolder: URL
    nonisolated public let recordFile: URL
    @Published public private(set) var held: [TravelHeld] = []
    @Published public private(set) var locked = false

    public enum Problem: Error, Equatable { case recordUnreadable }

    public init(root: URL) {
        self.root = root
        folder = root.appendingPathComponent("maps")
        incomingFolder = root.appendingPathComponent("incoming")
        recordFile = root.appendingPathComponent(Self.recordName)
        do {
            held = try JSONDecoder().decode([TravelHeld].self, from: Data(contentsOf: recordFile))
        } catch CocoaError.fileReadNoSuchFile {
            // none yet
        } catch {
            locked = true
        }
    }

    public func prepareFolders() {
        for dir in [root, folder, incomingFolder] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            LibraryStore.excludeFromBackup(dir)
        }
    }

    /// Where a copy from the folder waits for its checks
    public nonisolated func incoming(_ entry: TravelMaps.Entry) -> URL {
        incomingFolder.appendingPathComponent("\(entry.sha256).pmtiles")
    }

    /// The kept files, by state, as the street map reads them after the home file
    public var files: [URL] { held.map { folder.appendingPathComponent($0.file) } }

    /// A copy that passed `TravelMaps.check`, moved in under a name of its own and recorded; the state's older copy is
    /// deleted only once the record names the new one. The copy is deleted when it can't be kept.
    public func keep(_ copy: URL, entry: TravelMaps.Entry) throws {
        guard !locked else {
            try? FileManager.default.removeItem(at: copy)
            throw Problem.recordUnreadable
        }
        let name = "\(entry.name.dropLast(".pmtiles".count)).\(entry.sha256.prefix(12)).pmtiles"
        let target = folder.appendingPathComponent(name)
        let old = held.first { $0.entry.state == entry.state }
        do {
            if old?.file != name {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: copy, to: target)
            } else {
                try? FileManager.default.removeItem(at: copy)
            }
            LibraryStore.excludeFromBackup(target)
            var next = held.filter { $0.entry.state != entry.state } + [TravelHeld(entry: entry, file: name)]
            next.sort { $0.entry.state < $1.entry.state }
            try save(next)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            if old?.file != name { try? FileManager.default.removeItem(at: target) }
            throw error
        }
        if let old, old.file != name { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.file)) }
    }

    /// A state taken off this phone: recorded first, then its file deleted. Throws when the record can't be saved, and
    /// the state stays; a file that can't be deleted after is no longer named, so `clearLeftovers` takes it.
    public func remove(_ state: String) throws {
        guard !locked else { throw Problem.recordUnreadable }
        guard let gone = held.first(where: { $0.entry.state == state }) else { return }
        try save(held.filter { $0.entry.state != state })
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(gone.file))
    }

    /// Start over (phase K, the owner's choice 2), only while the record can't be read: the record deleted, then every
    /// file in `maps` and `incoming`, leaving an empty store that works. Throws, and stays locked with every file kept,
    /// when the record can't be deleted; a file that can't be deleted is taken by a later `clearLeftovers`.
    public func startOver() throws {
        guard locked else { return }
        do {
            try FileManager.default.removeItem(at: recordFile)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // gone already
        }
        held = []
        locked = false
        clearLeftovers()
    }

    /// Leftovers (phase K, finding 11), when Add a travel map opens with nothing being added: everything in `incoming`
    /// (a stopped add's copy, up to a state's size), and, only while the record can be read, each file in `maps` it
    /// doesn't name.
    public func clearLeftovers() {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: incomingFolder.path)) ?? [] {
            try? manager.removeItem(at: incomingFolder.appendingPathComponent(name))
        }
        guard !locked else { return }
        let named = Set(held.map(\.file))
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where !named.contains(name) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func save(_ next: [TravelHeld]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableFile.write(encoder.encode(next), to: recordFile)
        held = next
    }
}
