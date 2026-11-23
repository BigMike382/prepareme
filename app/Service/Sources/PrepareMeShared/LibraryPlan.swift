import Foundation

/// What the PrepareMe app holds of the Mac's library, and what it fetches next (plan phase 4). Kept by the app as one
/// file, written whole; nothing here reads the network or the disk, so the rules are tested on the Mac.
///
/// - The app fetches by itself every library file and core map (`automaticKinds`); an optional map only once someone
///   asked for it ("Get this file"), and any file it already holds is kept current (owner, 2026-10-13). The Mac app
///   (plan phase 6) takes every file (`everyKind`), optional maps included, as Kiwix (PrepareMe) opens them all.
/// - A file is fetched when the manifest's SHA-256 differs from the held copy's; library files go first, then the
///   smaller files, so the daily page never waits behind a 3 GB map.
/// - A copy refused by its checks is fetched once more (the Mac may have swapped the file between the manifest and the
///   download); refused twice, it waits until the Mac offers another copy or someone taps Try again.
/// - Each held copy lives under a name of its own (`fileName`), so a new copy never replaces a file the reader has
///   open (FINDINGS F-064).
/// - One library ID is one library: an entry whose ID is held under another name, or that an earlier entry already
///   carries, is never fetched (the Mac's first-read-wins rule; two copies with one ID confuse the reader, F-043).
/// - `checking` holds the copies downloaded but not yet checked: a check needs the app running, so one interrupted
///   by the system finishes at the next launch or coming forward.
public struct LibraryRecord: Codable, Equatable, Sendable {
    public var held: [String: HeldFile]
    public var requested: Set<String>
    public var refusals: [String: Int]  // a copy's SHA-256 → times its checks refused it
    public var manifest: Manifest?  // the last one read, for the get-file sheet while the Mac is out of reach
    public var checkedAt: String?  // when the Mac last answered
    public var checking: [Manifest.Entry]
    /// Files removed on purpose (plan phase 8): never fetched again, even by the Mac app that takes every kind, until
    /// someone asks for one again or the Mac's list stops naming it.
    public var declined: Set<String>
    /// The Mac's backup-signing key as last served (concept-doc plan, phase B): kept when a later list comes without
    /// one (the service's key file missing for a moment), replaced only by another key the Mac serves
    public var backupKey: String?

    public init(held: [String: HeldFile] = [:], requested: Set<String> = [], refusals: [String: Int] = [:],
                manifest: Manifest? = nil, checkedAt: String? = nil, checking: [Manifest.Entry] = [],
                declined: Set<String> = []) {
        self.held = held
        self.requested = requested
        self.refusals = refusals
        self.manifest = manifest
        self.checkedAt = checkedAt
        self.checking = checking
        self.declined = declined
    }

    enum CodingKeys: String, CodingKey {
        case held, requested, refusals, manifest, checking, declined
        case checkedAt = "checked_at", backupKey = "backup_key"
    }

    public init(from decoder: Decoder) throws {
        let found = try decoder.container(keyedBy: CodingKeys.self)
        held = try found.decodeIfPresent([String: HeldFile].self, forKey: .held) ?? [:]
        requested = try found.decodeIfPresent(Set<String>.self, forKey: .requested) ?? []
        refusals = try found.decodeIfPresent([String: Int].self, forKey: .refusals) ?? [:]
        manifest = try found.decodeIfPresent(Manifest.self, forKey: .manifest)
        checkedAt = try found.decodeIfPresent(String.self, forKey: .checkedAt)
        checking = try found.decodeIfPresent([Manifest.Entry].self, forKey: .checking) ?? []
        declined = try found.decodeIfPresent(Set<String>.self, forKey: .declined) ?? []
        backupKey = try found.decodeIfPresent(String.self, forKey: .backupKey)
    }
}

/// One copy on the phone: the manifest entry it was fetched for, and the name it is kept under.
public struct HeldFile: Codable, Equatable, Sendable {
    public var entry: Manifest.Entry
    public var file: String

    public init(entry: Manifest.Entry, file: String) {
        self.entry = entry
        self.file = file
    }
}

public enum LibraryPlan {
    public static let automaticKinds: Set<String> = ["library", "map-core"]
    public static let refuseAfter = 2
    /// Room kept free beyond the file being fetched: the old copy stays until the new one passes, and the phone itself
    /// needs space to run.
    public static let spareBytes: Int64 = 1 << 30

    /// Whether the app keeps this entry on the phone at all: a ZIM file (or the street map, plan phase 9) of an automatic
    /// kind, one asked for, or one it already holds. From phase M, a list's `fetch` says it instead: base always, a room
    /// file when room allows (toFetch decides when), and the Mac's Always or Never for this phone (never for a base file).
    public static func wanted(_ entry: Manifest.Entry, _ state: LibraryRecord, everyKind: Bool = false) -> Bool {
        guard entry.name.hasSuffix(".zim") || entry.isStreetMap else { return false }  // nothing else can be opened
        guard everyKind || entry.forPhones else { return false }  // the Mac's own downloads (plan phase 8)
        if entry.fetch == base { return true }  // every device's, whatever was removed before phase M (review)
        // the Mac's Always beats an earlier Remove: an Always file has no Remove (family downloads plan, phase 4)
        if choice(entry, state) == "always" { return true }
        guard !state.declined.contains(entry.name) else { return false }  // removed on purpose (plan phase 8)
        if everyKind || state.requested.contains(entry.name) || state.held[entry.name] != nil { return true }
        if choice(entry, state) == "never" { return false }
        if entry.fetch == room { return true }
        return entry.fetch == nil && automaticKinds.contains(entry.kind)
    }

    // MARK: Phase M: a base on every device, the rest by room (owner, 2026-10-18)

    public static let base = "base", room = "room"
    static let gigabyte: Int64 = 1_000_000_000

    /// A device's room: its free space for important use (what iOS can clear counted) and its capacity
    public struct Room: Equatable, Sendable {
        public var free: Int64
        public var capacity: Int64
        public init(free: Int64, capacity: Int64) {
            self.free = free
            self.capacity = capacity
        }
    }

    /// The free space a device always keeps for its own photos and apps: 10 GB whatever its size (owner, 2026-11-15, by
    /// click: "Flat 10 GB", so more maps fit; it was 10 GB or a fifth of the device, whichever was larger, from 2026-10-18)
    public static func reserve(capacity: Int64) -> Int64 {
        10 * gigabyte
    }

    /// Offline fixes, phase 5 (the report's fix 11): whether a phone fetches this file on its downloads that may wait
    /// for the charger and Wi-Fi (iOS decides), so a big optional map never runs down a battery the household may need.
    /// The base, the library files and a file someone asked for (Get this file) come at once.
    public static func waitsForPower(_ entry: Manifest.Entry, _ state: LibraryRecord) -> Bool {
        guard entry.kind != "library", entry.fetch != base, !state.requested.contains(entry.name) else { return false }
        return entry.fetch == room || entry.kind == "map-optional"
    }

    /// The Mac's Always or Never for this file on this phone, from the list it served; nil when it set neither
    static func choice(_ entry: Manifest.Entry, _ state: LibraryRecord) -> String? {
        guard entry.fetch != base else { return nil }  // a base file is never left out
        return state.manifest?.choices?[entry.name]
    }

    /// What a device takes now and what waits, from the same wanted list toFetch makes (so a copy being checked, a
    /// refused or an ID-clashing file is never counted): `sure` (library, base, updates, asked for, Always) always;
    /// then room files strictly in order while free space, less the new sure files and the reserve, still holds each.
    /// The first that doesn't fit stops the rest, so the owner's order holds (review of tasks 1 and 2).
    /// An Always file not yet held waits when, after the new sure files before it, it would leave less than `floor`
    /// (family downloads plan, phase 4: an Always never takes the room the library needs to update).
    static func split(_ all: [Manifest.Entry], _ state: LibraryRecord, room: Room, floor: Int64 = spareBytes)
        -> (sure: [Manifest.Entry], take: [Manifest.Entry], wait: [Manifest.Entry]) {
        var sure: [Manifest.Entry] = [], wait: [Manifest.Entry] = []
        var left = room.free
        for entry in all where entry.fetch != Self.room || state.held[entry.name] != nil
            || state.requested.contains(entry.name) || choice(entry, state) == "always" {
            let new = state.held[entry.name] == nil
            if new && choice(entry, state) == "always" && !state.requested.contains(entry.name)
                && left - entry.size < floor {
                wait.append(entry)
                continue
            }
            sure.append(entry)
            if new { left -= entry.size }
        }
        let skip = Set((sure + wait).map(\.name))
        var budget = left - reserve(capacity: room.capacity)
        var take: [Manifest.Entry] = []
        for entry in all.filter({ !skip.contains($0.name) })
            .sorted(by: { ($0.order ?? Int.max, $0.name) < ($1.order ?? Int.max, $1.name) }) {
            if wait.isEmpty && entry.size <= budget {
                take.append(entry)
                budget -= entry.size
            } else {
                wait.append(entry)
            }
        }
        return (sure, take, wait)
    }

    /// The room files waiting for space on this device, in order (Home Mac's "Waiting for room")
    public static func waitingForRoom(_ manifest: Manifest, _ state: LibraryRecord, room: Room) -> [Manifest.Entry] {
        split(eligible(manifest, state), state, room: room, floor: floor(manifest.files)).wait
    }

    /// Base files this device has no room to get or to update (its size plus the spare), whether it holds an older copy
    /// or none: Today's warning, and the Mac's Phones list (review: a base file never got was said nowhere)
    public static func cantUpdate(_ manifest: Manifest, _ state: LibraryRecord, free: Int64) -> [Manifest.Entry] {
        manifest.files.filter { entry in
            entry.fetch == base && wanted(entry, state) && !isCurrent(entry, state) && !isRefused(entry, state)
                && !hasRoom(for: entry.size, available: free)
        }
    }

    public static func isCurrent(_ entry: Manifest.Entry, _ state: LibraryRecord) -> Bool {
        state.held[entry.name]?.entry.sha256 == entry.sha256
    }

    public static func isRefused(_ entry: Manifest.Entry, _ state: LibraryRecord) -> Bool {
        (state.refusals[entry.sha256] ?? 0) >= refuseAfter
    }

    /// Whether another file already stands for this entry's library ID: one held under another name, or an earlier
    /// entry of the manifest.
    public static func idTaken(_ entry: Manifest.Entry, _ manifest: Manifest, _ state: LibraryRecord) -> Bool {
        let id = entry.id.lowercased()
        if state.held.contains(where: { $0.key != entry.name && $0.value.entry.id.lowercased() == id }) { return true }
        let first = manifest.files.first { $0.id.lowercased() == id && $0.name.hasSuffix(".zim") }
        return first != nil && first?.name != entry.name
    }

    /// The entries to fetch, in order: library files first, then the smaller ones, then by name. With a device's
    /// `room` (phase M), room files only as split allows, after the base, the updates and anything asked for or set
    /// Always; without one (the Mac app, the store's tidy-up), every wanted file, as before.
    public static func toFetch(_ manifest: Manifest, _ state: LibraryRecord, everyKind: Bool = false,
                               room: Room? = nil) -> [Manifest.Entry] {
        let all = eligible(manifest, state, everyKind: everyKind)
        guard let room, !everyKind else { return all.sorted(by: firstFirst) }
        func rank(_ entry: Manifest.Entry) -> Int {
            if entry.kind == "library" { return 0 }
            if entry.fetch == base { return 1 }
            if state.held[entry.name] != nil { return 2 }  // an update before any new file
            return 3  // asked for, or Always
        }
        let (sure, take, _) = split(all, state, room: room, floor: floor(manifest.files))
        return sure.sorted { (rank($0), $0.size, $0.name) < (rank($1), $1.size, $1.name) } + take
    }

    /// Every file wanted, not current, not refused, not an ID clash and not waiting for its check
    static func eligible(_ manifest: Manifest, _ state: LibraryRecord, everyKind: Bool = false) -> [Manifest.Entry] {
        manifest.files
            .filter { wanted($0, state, everyKind: everyKind) && !isCurrent($0, state) && !isRefused($0, state) }
            .filter { entry in
                !idTaken(entry, manifest, state) && !state.checking.contains { $0.sha256 == entry.sha256 }
            }
    }

    static func firstFirst(_ a: Manifest.Entry, _ b: Manifest.Entry) -> Bool {
        let (ka, kb) = (a.kind == "library" ? 0 : 1, b.kind == "library" ? 0 : 1)
        if ka != kb { return ka < kb }
        if a.size != b.size { return a.size < b.size }
        return a.name < b.name
    }

    /// Whether the phone may remove a file it holds (plan phase 8): an optional map, a download, or one the Mac's list
    /// no longer names. A library file or core map the list names would only be fetched again, and a file the Mac set to
    /// Always for this device stays (family downloads plan, phase 4, decision 8).
    public static func removable(_ name: String, _ state: LibraryRecord) -> Bool {
        guard let held = state.held[name] else { return false }
        guard let listed = state.manifest?.files.first(where: { $0.name == name }) else { return true }
        if keptByMac(listed, state) { return false }
        if let fetch = listed.fetch { return fetch != base || !listed.forPhones }  // phase M: all but the base
        return !automaticKinds.contains(listed.kind) || !listed.forPhones || held.entry.kind == "download"
    }

    /// A file the Mac set to Always for this device: "Kept on this phone (set on the Mac).", and no Remove
    public static func keptByMac(_ entry: Manifest.Entry, _ state: LibraryRecord) -> Bool {
        entry.forPhones && choice(entry, state) == "always"
    }

    /// The held file Today offers to remove when the library can't update for room (phase 4, decision 2): the largest
    /// one this device may remove, nil when there is none
    public static func largestRemovable(_ state: LibraryRecord) -> HeldFile? {
        state.held.values.filter { removable($0.entry.name, state) }
            .max { ($0.entry.size, $1.entry.name) < ($1.entry.size, $0.entry.name) }
    }

    // MARK: The floor and the 10 GB line (family downloads plan, phase 4, decision 1)

    /// The free space nothing a person adds, nor an Always, may go below: room for the largest base file's update (its
    /// new copy beside the old) and the spare. Files from a list with no base (a Mac before phase M) count the automatic
    /// kinds; no list, the spare alone.
    public static func floor(_ files: [Manifest.Entry]?) -> Int64 {
        ((files ?? []).filter { $0.forPhones && isBase($0) }.map(\.size).max() ?? 0) + spareBytes
    }

    public static func isBase(_ entry: Manifest.Entry) -> Bool {
        entry.fetch == base || entry.fetch == nil && automaticKinds.contains(entry.kind)
    }

    /// What adding `need` bytes by hand would leave: refused under the floor, asked first under the 10 GB line
    public enum Adding: Equatable, Sendable {
        case go
        case ask(left: Int64)
        case refused(floor: Int64)
    }

    public static func adding(_ need: Int64, free: Int64, floor: Int64) -> Adding {
        let left = free - need
        if left < floor { return .refused(floor: floor) }
        return left < reserve(capacity: 0) ? .ask(left: left) : .go
    }

    /// The free space a file needs before its download starts: its size and the spare for a base file or an update, its
    /// size and the floor for a new file (phase 4: a Download asked for while away still keeps the floor)
    public static func need(_ entry: Manifest.Entry, _ state: LibraryRecord, floor: Int64) -> Int64 {
        isBase(entry) || state.held[entry.name] != nil ? entry.size + spareBytes : entry.size + max(floor, spareBytes)
    }

    /// The files this phone holds that the Mac's list no longer names (or no longer offers the phones).
    public static func dropped(_ state: LibraryRecord) -> [HeldFile] {
        state.held.values.filter { held in
            !(state.manifest?.files.contains { $0.name == held.entry.name && $0.forPhones } ?? true)
        }.sorted { $0.entry.name < $1.entry.name }
    }

    /// Whether `available` bytes leave room to fetch a file of `size` bytes.
    public static func hasRoom(for size: Int64, available: Int64) -> Bool {
        available >= size + spareBytes
    }

    /// The name a copy is kept under: the manifest's name with the first 12 characters of its SHA-256 before ".zim"
    /// (".pmtiles" for the street map), so two copies of one file never share a name.
    public static func fileName(_ entry: Manifest.Entry) -> String {
        let ending = ".\(entry.fileExtension)"
        let stem = entry.name.hasSuffix(ending) ? String(entry.name.dropLast(ending.count)) : entry.name
        return "\(stem).\(entry.sha256.prefix(12))\(ending)"
    }

    /// The manifest entry for a library ID the phone doesn't hold, for "Get this file (N GB)"; nil when the phone holds
    /// it or the manifest has no file with that ID.
    public static func missing(id: String, _ state: LibraryRecord) -> Manifest.Entry? {
        let id = id.lowercased()
        guard !state.held.values.contains(where: { $0.entry.id.lowercased() == id }) else { return nil }
        return state.manifest?.files.first { $0.id.lowercased() == id && $0.name.hasSuffix(".zim") }
    }

    /// A refusal recorded: true when this copy is now refused for good (until the Mac offers another or Try again).
    @discardableResult
    public static func refuse(_ entry: Manifest.Entry, _ state: inout LibraryRecord) -> Bool {
        let times = (state.refusals[entry.sha256] ?? 0) + 1
        state.refusals[entry.sha256] = times
        return times >= refuseAfter
    }

    /// Refusals of copies the manifest no longer offers are dropped, so the record never grows without end.
    public static func forgetOldRefusals(_ manifest: Manifest, _ state: inout LibraryRecord) {
        let offered = Set(manifest.files.map(\.sha256))
        state.refusals = state.refusals.filter { offered.contains($0.key) }
    }
}

/// When this install stops opening: the expiry date in the provisioning profile Xcode embedded in the app
/// (`embedded.mobileprovision`, a signed property list). The app shows it, so a lapse is never a surprise.
public enum InstallExpiry {
    public static func date(fromProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let found = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
            return nil
        }
        return found["ExpirationDate"] as? Date
    }

    /// When the profile was made, beside its expiry: together they say how long the install lasts.
    public static func created(fromProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        let found = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        return found?["CreationDate"] as? Date
    }

    /// Days before the expiry to warn: 30 for an install that lasts a year, 2 for one that lasts a week (a personal
    /// team's), so a short install isn't warned about every day of its life.
    public static func warnDays(created: Date?, expiry: Date) -> Int {
        guard let created else { return 30 }
        return expiry.timeIntervalSince(created) > 60 * 86400 ? 30 : 2
    }

    /// Whole days from `now` to `expiry`, never below zero.
    public static func daysLeft(_ expiry: Date, now: Date) -> Int {
        max(0, Int(expiry.timeIntervalSince(now) / 86400))
    }

    // TestFlight builds (over-the-air plan, phase 2, layer 3): `kiwix-mac/build.sh --app-testflight` stamps the build's
    // time (Info.plist's PrepareMeBuilt) and this channel (PrepareMeChannel); a cable install has neither.
    public static let testflight = "testflight"
    /// A copy from the App Store (Unlisted plan, phase 5): `build.sh --app-store` stamps it, and a report carries it
    /// only when the app also finds it was installed by the store (`isStoreCopy`). It never stops opening.
    public static let appstore = "appstore"
    /// "Available to test for up to 90 days, starting from the day the developer uploads" (testflight.apple.com)
    public static let testflightDays = 90
    /// Two missed weekly rebuilds: the "hasn't updated itself" sentence and its Update button
    public static let staleDays = 21

    /// Whether this copy came from the App Store (Unlisted plan, phase 5), told by how it was installed, not only by its
    /// stamp: stamped `appstore` (only `build.sh --app-store` and its check write that), no provisioning profile (every
    /// cable build has one), and a receipt address ending in "receipt" (`Bundle.appStoreReceiptURL`: developers report
    /// "sandboxReceipt" from TestFlight and Xcode; a path, so no network is needed; Apple documents neither name).
    public static func isStoreCopy(stamp: String?, hasProfile: Bool, receipt: String?) -> Bool {
        stamp == appstore && !hasProfile && receipt == "receipt"
    }

    /// The channel an install lives by and reports: "appstore" only for a store copy; a store-stamped build that came
    /// any other way (TestFlight) is "testflight", with its 90 days and warnings, so the one way to be wrong is a false
    /// warning, never a hidden end; nil (cable) for an unstamped build.
    public static func channel(stamp: String?, hasProfile: Bool, receipt: String?) -> String? {
        if isStoreCopy(stamp: stamp, hasProfile: hasProfile, receipt: receipt) { return appstore }
        return stamp == testflight || stamp == appstore ? testflight : nil
    }

    /// When this install stops opening: never for a store copy; a TestFlight build's stamped time plus 90 days (an upload
    /// is never earlier than its build, so never later than Apple's end), and never later than a profile's end; else the
    /// profile's.
    public static func end(channel: String?, built: Date?, profile: Date?) -> Date? {
        if channel == appstore { return nil }
        guard channel == testflight, let built else { return profile }
        let ends = built.addingTimeInterval(Double(testflightDays) * 86400)
        return profile.map { min($0, ends) } ?? ends
    }

    /// The stamped build time (ISO 8601), nil when absent or empty (a cable or simulator build)
    public static func built(_ stamp: String?) -> Date? {
        stamp.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// When a build was made, from its number (`build.sh` writes the UTC time as YYYY.MDD.HMM, no leading zeros):
    /// the Mac's Phones list reads a phone's age this way (phase 3, layer 4). nil for any other shape.
    public static func buildDate(_ build: String?) -> Date? {
        let parts = (build ?? "").split(separator: ".").map { Int($0) }
        guard parts.count == 3, let year = parts[0], let md = parts[1], let hm = parts[2] else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let wanted = DateComponents(year: year, month: md / 100, day: md % 100, hour: hm / 100, minute: hm % 100)
        guard let date = calendar.date(from: wanted),
              calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date) == wanted else { return nil }
        return date
    }

    /// Whole days since the build was made, never below zero.
    public static func daysOld(_ built: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(built) / 86400))
    }

    /// Days left at which the phone's own notifications fire (layer 3): TestFlight's 90 days, or a cable install's year;
    /// none for a store copy.
    public static func noticeDays(channel: String?) -> [Int] {
        if channel == appstore { return [] }
        return channel == testflight ? [30, 14, 7, 3, 1] : [60, 30, 14, 7, 1]
    }
}
