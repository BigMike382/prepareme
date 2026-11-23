import Foundation

/// A phone's room as it reports it to the Mac (concept-doc plan, phase M): its free space for important use, its
/// capacity, the files it holds, those waiting for room and the base files it can't update. Counts, sizes and file
/// names only, never a place or a typed name. The phones' service keeps the last report of each phone, by its label
/// and stamped with when that phone was paired (labels are reused: a new phone takes the lowest free one), in the
/// pairing folder (`fileName`), where the Mac app reads it for Settings › Phones.
public struct PhoneStorage: Codable, Equatable, Sendable {
    public var free: Int64
    public var capacity: Int64
    public var held: [String]
    public var waiting: [String]
    public var cantUpdate: [String]
    /// When the service took it, and when the phone that sent it was paired (both set by the service, never the phone)
    public var at: String?
    public var paired: String?
    /// When the phone's install stops opening (offline fixes, phase 2; ISO 8601, from its provisioning profile); nil
    /// from a simulator build or a phone installed before it was sent
    public var opensUntil: String?
    /// Whether Organic Maps is on the phone (hand-off plan, 3.2: canOpenURL at each check); nil from an older app
    public var organicMaps: Bool?
    /// The app's build number (CFBundleVersion: "2026.1114.1530" from TestFlight, "250" by cable) and its channel
    /// ("testflight", "appstore" from the Unlisted plan's phase 5, or nil for a cable install), over-the-air plan phase 2
    /// (layer 4's data; nil from an older app). A Mac older than phase 5 refuses an "appstore" report whole.
    public var build: String?
    public var channel: String?
    /// The update self-check's result for this build (UpdateCheck; numbers and fixed words only); nil before an update
    public var update: UpdateCheck.Result?
    /// The opening self-check's last result and tally (OpeningCheck; fixed kinds and numbers only); nil from an older
    /// app, or when the Mac can't read it
    public var opening: OpeningCheck.Report?

    enum CodingKeys: String, CodingKey {
        case free, capacity, held, waiting, at, paired, build, channel, update, opening
        case cantUpdate = "cant_update"
        case opensUntil = "opens_until"
        case organicMaps = "organic_maps"
    }

    public init(free: Int64, capacity: Int64, held: [String], waiting: [String], cantUpdate: [String], at: String? = nil,
                opensUntil: String? = nil, organicMaps: Bool? = nil, build: String? = nil, channel: String? = nil,
                update: UpdateCheck.Result? = nil, opening: OpeningCheck.Report? = nil) {
        self.free = free
        self.capacity = capacity
        self.held = held
        self.waiting = waiting
        self.cantUpdate = cantUpdate
        self.at = at
        self.opensUntil = opensUntil
        self.organicMaps = organicMaps
        self.build = build
        self.channel = channel
        self.update = update
        self.opening = opening
    }

    public init(from decoder: Decoder) throws {
        let found = try decoder.container(keyedBy: CodingKeys.self)
        free = try found.decode(Int64.self, forKey: .free)
        capacity = try found.decode(Int64.self, forKey: .capacity)
        held = try found.decode([String].self, forKey: .held)
        waiting = try found.decode([String].self, forKey: .waiting)
        cantUpdate = try found.decode([String].self, forKey: .cantUpdate)
        at = try found.decodeIfPresent(String.self, forKey: .at)
        paired = try found.decodeIfPresent(String.self, forKey: .paired)
        opensUntil = try found.decodeIfPresent(String.self, forKey: .opensUntil)
        organicMaps = try found.decodeIfPresent(Bool.self, forKey: .organicMaps)
        build = try found.decodeIfPresent(String.self, forKey: .build)
        channel = try found.decodeIfPresent(String.self, forKey: .channel)
        update = try found.decodeIfPresent(UpdateCheck.Result.self, forKey: .update)
        // dropped, never refused, unlike `update`: a phone can run a newer build than the Mac, with kinds it doesn't know
        opening = (try? found.decodeIfPresent(OpeningCheck.Report.self, forKey: .opening))?.flatMap { $0.isPlain ? $0 : nil }
    }

    public static let fileName = "phones-storage.json"
    public static let maxBytes = 64 << 10
    public static let maxNames = 500

    public enum Problem: Error { case unreadable }

    /// A report as a phone sent it, checked: sizes not negative, at most `maxNames` plain file names in each list
    public static func read(_ data: Data) throws -> PhoneStorage {
        guard data.count <= maxBytes, let report = try? JSONDecoder().decode(PhoneStorage.self, from: data),
              report.free >= 0, report.capacity >= 0,
              [report.held, report.waiting, report.cantUpdate].allSatisfy({ $0.count <= maxNames && $0.allSatisfy(FileName.isPlain) }),
              report.build.map({ (1...32).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } }) ?? true,
              report.channel.map({ [InstallExpiry.testflight, InstallExpiry.appstore].contains($0) }) ?? true,
              report.update.map(\.isPlain) ?? true
        else { throw Problem.unreadable }
        return report
    }

    /// The pairing folder's reports by phone label; empty when there are none or the file can't be read
    public static func readAll(_ data: Data?) -> [String: PhoneStorage] {
        data.flatMap { try? JSONDecoder().decode([String: PhoneStorage].self, from: $0) } ?? [:]
    }

    /// The report of the phone now holding `label` and paired at `paired`: never a removed phone's under its reused label
    public static func current(_ all: [String: PhoneStorage], label: String, paired: String) -> PhoneStorage? {
        all[label].flatMap { $0.paired == paired ? $0 : nil }
    }

    /// Whether the device shares its free space (Unlisted plan, phase 4, decision 6): one whose person hasn't said yes
    /// sends 0 for both, which a Mac one version older still reads; this Mac then shows `notSharedLine` in place of
    /// the bar, and never refuses a file by room it doesn't know.
    public var sharesRoom: Bool { capacity > 0 }
    public static let notSharedLine = "Doesn't share its free space with the Mac. Its Settings can turn that on."

    /// The sizes devices are sold in, 1000-based as the system's own figures: a capacity goes up to the next one.
    static let soldSizes: [Int64] = [16, 32, 64, 128, 256, 512, 1_000, 2_000, 4_000, 8_000].map { $0 * 1_000_000_000 }

    /// What a device sends the Mac (decision 6): its free space down to the whole gigabyte and its capacity up to the
    /// size it was sold as, so the Mac's 10 GB line still falls where it did; 0 and 0 unless its person said yes
    /// (Apple's reason 85F4.1 asks for that permission). Its own screens keep the exact figure.
    public static func shared(free: Int64, capacity: Int64, allowed: Bool) -> (free: Int64, capacity: Int64) {
        guard allowed, capacity > 0 else { return (0, 0) }
        let gb: Int64 = 1_000_000_000
        let sold = soldSizes.first { $0 >= capacity } ?? (capacity + gb - 1) / gb * gb
        return (min(max(free, 0), capacity) / gb * gb, sold)
    }

    public static let unseenDays = 7  // scheduler/notice.py's UNSEEN_DAYS (its test pins the two together)
    public static let warnDays = 60  // its INSTALL_WARN_DAYS
    /// Six months: a cable install (and the kept installer) is amber this early, so it is plugged in and installed
    /// again, which starts a new year (the cable clock, docs/plans/2026-11-22-cable-clock.md). Its CABLE_RENEW_DAYS.
    public static let cableRenewDays = 182
    public static let testflightWarnDays = 30  // its INSTALL_BANNER_DAYS: a TestFlight phone's only date warning
    /// A store phone's install (Unlisted plan, phase 5): in the Phones list, More details and the Dates rows
    public static let storeLine = "From the App Store: no end date."
    public static let noEndDate = "No end date"

    /// The Phones list's amber line for a phone that hasn't reported in `unseenDays` or more (offline fixes, phase 2);
    /// nil otherwise. It reports at each check at home.
    public func unseenLine(now: Date = Date()) -> String? {
        guard let at = at.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return nil }
        let days = Int(now.timeIntervalSince(at) / 86400)
        guard days >= Self.unseenDays else { return nil }
        return "Not heard from in \(days) days (last \(at.formatted(date: .abbreviated, time: .omitted)))."
    }

    /// The Phones list's amber line when the phone said Organic Maps isn't on it; nil when it is, or it didn't say
    public var organicMapsLine: String? { organicMaps == false ? "Organic Maps: not installed" : nil }

    /// The Phones list's line for the phone's install, amber (`caution`) within `cableRenewDays`, its 60-day words
    /// within `warnDays`; nil when it didn't say.
    /// A TestFlight phone's (phase 3, layer 4) names its build, amber when it is `staleDays` old or within
    /// `testflightWarnDays` of its end. A store phone's (Unlisted plan, phase 5) has no end and is never amber.
    public func installLine(now: Date = Date()) -> (text: String, caution: Bool)? {
        if channel == InstallExpiry.appstore { return (Self.storeLine, false) }
        guard let until = opensUntil.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return nil }
        let date = until.formatted(date: .long, time: .omitted)
        let days = InstallExpiry.daysLeft(until, now: now)
        if channel == InstallExpiry.testflight, let build {
            let named = "Build \(build), TestFlight"
            if let made = InstallExpiry.buildDate(build), InstallExpiry.daysOld(made, now: now) >= InstallExpiry.staleDays {
                let weeks = InstallExpiry.daysOld(made, now: now) / 7
                return ("\(named), opens until \(date): it hasn't updated itself for \(weeks) weeks.", true)
            }
            return days <= Self.testflightWarnDays
                ? ("\(named), stops opening on \(date) (\(days) days).", true)
                : ("\(named), opens until \(date).", false)
        }
        if days <= Self.warnDays {
            return ("Its install stops opening on \(date) (\(days) days): reinstall it from the Mac.", true)
        }
        return days <= Self.cableRenewDays
            ? ("Its install opens until \(date) (\(days) days): plug it into the Mac and install again to start a new "
               + "year.", true)
            : ("Its install opens until \(date).", false)
    }
}

/// The owner's Always or Never per file per phone (phase M; owner, 2026-10-18: "On the Mac, per phone"), which the Mac
/// app keeps in the pairing folder (`fileName`) by phone label, stamped with when that phone was paired, and the phones'
/// service adds to the list it serves that phone only (`Manifest.choices`). A removed phone's choices never reach a new
/// phone given its label.
public enum PhoneChoices {
    public static let fileName = "phone-files.json"
    /// "never" is today's "doesn't come by itself" (Offered, from the family downloads plan on); "hide" is the plan's
    /// Never (phase 3): the device isn't sent the file at all and lets go of its copy. Only "always" and "never" are
    /// ever served in `choices`; a hidden file is left out of the list and named in `drop` instead. "room" is By room
    /// picked over a map's default (phase 6): served as no choice, so the map comes by room.
    public static let always = "always", never = "never", hide = "hide", room = "room"
    /// Family downloads the owner un-ticked For the family on (phase 3, decision 3), by name: a sorted JSON list the
    /// Mac app keeps beside `fileName`.
    public static let withdrawnName = "phone-withdrawn.json"

    /// One phone's choices, and when that phone was paired
    public struct Entry: Codable, Equatable, Sendable {
        public var paired: String
        public var files: [String: String]
        public init(paired: String, files: [String: String]) {
            self.paired = paired
            self.files = files
        }
    }

    /// Every phone's choices; empty when there are none or the file can't be read
    public static func readAll(_ data: Data?) -> [String: Entry] {
        data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// One phone's choices for the list it is served: only that pairing's, only for files the list names, never for a
    /// base file (it would leave the phone without its library), only "always" or "never"; nil when none is left. A map
    /// with a default for the phone (`preset`) is served as that unless the Mac set it.
    public static func choices(_ all: [String: Entry], for label: String, paired: String, child: Bool = false,
                               in manifest: Manifest) -> [String: String]? {
        var kept: [String: String] = [:]
        for file in manifest.files { kept[file.name] = preset(file, child: child, in: manifest) }
        if let entry = all[label], entry.paired == paired {
            let names = Set(manifest.files.filter { $0.fetch != LibraryPlan.base }.map(\.name))
            for (name, value) in entry.files where names.contains(name) {
                if value == always || value == never { kept[name] = value } else if value == room { kept[name] = nil }
            }
        }
        return kept.isEmpty ? nil : kept
    }

    /// The files the Mac set to Never (`hide`) for this pairing: only that pairing's, never a base file (it would leave
    /// the device without its library), only names the list offers the phones.
    public static func hidden(_ all: [String: Entry], for label: String, paired: String, in manifest: Manifest)
        -> Set<String> {
        guard let entry = all[label], entry.paired == paired else { return [] }
        return Set(manifest.files.filter { $0.forPhones && $0.fetch != LibraryPlan.base && entry.files[$0.name] == hide }
            .map(\.name))
    }

    /// The withdrawn names (`withdrawnName`) the Mac's list still names and no longer offers the phones: sent in every
    /// device's `drop` until the file is ticked again or gone from the Mac. Only a name once offered is ever withdrawn,
    /// so a download kept for the Mac alone is never named to a phone.
    public static func withdrawn(_ data: Data?, in manifest: Manifest) -> Set<String> {
        let names = Set(readWithdrawn(data))
        return Set(manifest.files.filter { !$0.forPhones && names.contains($0.name) }.map(\.name))
    }

    static func readWithdrawn(_ data: Data?) -> [String] {
        data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    /// The Mac app's For the family tick: un-ticked (`withdrawn` true) keeps the name, ticked again or removed from the
    /// Mac lets it go. Saved whole in `folder` (the pairing folder) only when it changes.
    public static func withdraw(_ name: String, _ withdrawn: Bool, in folder: URL) throws {
        let url = folder.appendingPathComponent(withdrawnName)
        var names = Set(readWithdrawn(try? Data(contentsOf: url)))
        guard withdrawn ? names.insert(name).inserted : names.remove(name) != nil else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DurableFile.write(JSONEncoder().encode(names.sorted()), to: url)
    }

    static let overview = "prepareme-maps-topo-overview.zim"

    static let today = "prepareme-maps-topo-today-"

    /// A map's default on a phone when the Mac set none, to keep the family's phones smaller (owner, 2026-11-15, by
    /// click): Never on every phone for the older topo files; on a child's phone Never for every map after the topo
    /// overview in the order; on an adult's, Always for today's topo band nearest home (the first of them in the order)
    /// and Never for the other bands. Nil: by room.
    public static func preset(_ entry: Manifest.Entry, child: Bool, in manifest: Manifest) -> String? {
        guard entry.fetch == LibraryPlan.room else { return nil }
        if entry.name.hasPrefix("prepareme-maps-topo-older-") { return never }
        guard let order = entry.order else { return nil }
        if child {  // 4 is the overview's place in packer.fetch.FIXED, for a list that doesn't name it
            return order > (manifest.files.first { $0.name == overview }?.order ?? 4) ? never : nil
        }
        guard entry.name.hasPrefix(today) else { return nil }
        let nearest = manifest.files.filter { $0.fetch == LibraryPlan.room && $0.name.hasPrefix(today) }
            .compactMap(\.order).min()
        return order == nearest ? always : never
    }

    public static func encoded(_ all: [String: Entry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(all)
    }
}
