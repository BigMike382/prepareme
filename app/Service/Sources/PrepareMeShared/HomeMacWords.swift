import Foundation

/// The phone's Home Mac words (the beta run's F03 and F40; plan 2026-10-16, Task 2.1): what this phone knows about
/// each file, never "Up to date" when it couldn't check, and plain names, never a file name or a machine date.
public enum HomeMacWords {
    /// How the phone's last check with the Mac went, as Home Mac words it.
    public enum CheckResult: Equatable, Sendable {
        case answered(Date)  // the Mac answered at that time
        case notFound  // away from home, or the Mac asleep
        case removed  // the Mac no longer knows this phone (401)
        case failed(String)  // any other problem
        case never  // not checked since pairing
    }

    /// A file's status line, for a file this phone holds: the check's words, then how old the copy is (the library's
    /// own time, else when it was made; the street map's OpenStreetMap date). `device` is "iPad" on an iPad (ThisDevice).
    /// `lastReached`: when the Mac last answered (the library record's checkedAt), said when it isn't found (phase K's
    /// drills, finding 3); nil, never reached, keeps the line as before.
    public static func status(entry: Manifest.Entry, current: Bool, check: CheckResult, now: Date = Date(),
                              timeZone: TimeZone = .current, device: String = "phone",
                              lastReached: Date? = nil) -> String {
        // a date that can't be read leaves the age out rather than say "an unknown day" (phase 2 review)
        let age = age(entry, now: now, timeZone: timeZone)
        let copy = "This \(device)'s copy" + (age.map { ", \($0)" } ?? "") + "."
        switch check {
        case .answered(let at) where current:
            return "Same as the Mac's copy (checked \(when(at, now: now, timeZone: timeZone)))."
                + (age.map { " " + $0.prefix(1).uppercased() + $0.dropFirst() + "." } ?? "")
        case .answered:
            return copy + " The Mac has a newer one."
        case .notFound:
            guard let lastReached else { return copy + " Couldn't check with the Mac just now." }
            return copy + " Couldn't reach the Mac; " + reached(lastReached, now: now, timeZone: timeZone)
        case .failed:
            return copy + " Couldn't check with the Mac just now."
        case .removed:
            return copy + " The Mac no longer sends to this \(device)."
        case .never:
            return copy + " Not checked with the Mac yet."
        }
    }

    /// How old a file's copy is, in the words Home Mac and Add from Files share: "made Oct 12" (the library's own date,
    /// else when the copy was made), "OpenStreetMap as of Oct 6" for the street map; nil when the date can't be read.
    public static func age(_ entry: Manifest.Entry, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        ageParts(entry, now: now, timeZone: timeZone).map { "\($0.label) \($0.day)" }
    }

    /// `age` in two parts, so a screen can say the label once over two days ("made Oct 6 against Oct 12").
    public static func ageParts(_ entry: Manifest.Entry, now: Date = Date(),
                                timeZone: TimeZone = .current) -> (label: String, day: String)? {
        day(entry.libraryAsOf ?? entry.deliveredAt, now: now, timeZone: timeZone)
            .map { (entry.isStreetMap ? "OpenStreetMap as of" : "made", $0) }
    }

    /// The street map's age on the map itself (the street map fixes plan, task 3.5): "Map as of Mar 2026", and past
    /// `mapOldAfter` "Map as of Mar 2026: over 6 months old", which the map shows in caution amber; nil when the date
    /// can't be read. `built` is the map entry's own date, as `age` reads it.
    public static func mapAgeLine(built: String, now: Date = Date(),
                                  timeZone: TimeZone = .current) -> (words: String, old: Bool)? {
        guard let date = parse(built, timeZone: timeZone) else { return nil }
        let old = now.timeIntervalSince(date) > mapOldAfter
        let words = "Map as of " + formatted(date, "MMM yyyy", timeZone)
        return (old ? words + ": over 6 months old" : words, old)
    }

    public static let mapOldAfter: TimeInterval = 180 * 24 * 3600

    /// Home Mac's rows in one fixed order, whatever order the list or the arrivals come in (beta run 2, B2-20): the
    /// library first, then the maps by the packer's `order`, then the rest; ties by name.
    public static func ordered(_ entries: [Manifest.Entry]) -> [Manifest.Entry] {
        let ranks = ["library": 0, "map-core": 1, "map-optional": 2, "map": 3, "download": 4]
        return entries.sorted {
            let a = (ranks[$0.kind] ?? 5, $0.order ?? Int.max, $0.name)
            let b = (ranks[$1.kind] ?? 5, $1.order ?? Int.max, $1.name)
            return a < b
        }
    }

    /// The pairing line at the top of Home Mac; a phone the Mac has removed says so instead of "Paired with".
    public static func pairedLine(host: String, removed: Bool, device: String = "phone") -> String {
        let name = host.replacingOccurrences(of: ".local", with: "")
        return removed ? "Was paired with \(name); the Mac no longer knows this \(device). Pair it again at home."
                       : "Paired with \(name)."
    }

    /// A refused copy's line, by its library's plain name, never its file's (remaining-findings plan, Task 9.3; F40).
    public static func refusal(_ entry: Manifest.Entry, why: String, at date: Date) -> String {
        "\(date.formatted(date: .abbreviated, time: .shortened)), \(title(entry)): \(why)"
    }

    /// The Mac not found (Task 9.3; F44): what it means, then the next step, the same on a child's phone (family
    /// downloads plan, phase 2). Naming the Local Network setting, which turned off looks the same as away from home
    /// (offline fixes, task 3.4).
    public static let notFound = "The Mac wasn't found on this network (away from home, the Mac asleep, or this phone "
        + "not allowed on the local network: Settings › Privacy & Security › Local Network). At home, wake the Mac, "
        + "then tap Check now."

    /// The secure connection to the Mac failed partway (offline fixes, task 3.3: a Wi-Fi network's sign-in page, or a
    /// dropped link), where it had said "Something went wrong (code …)"
    public static let connectionCut = "The connection to the Mac was cut partway (a Wi-Fi network with a sign-in page, "
        + "or a dropped link). At home, tap Check now."

    /// Why the phone's Inventory has nothing to show yet (remaining-findings plan, Task 12.4; F35): not paired (its
    /// button is Pair with the Mac, as every other tab's), or paired before the Mac has written the phones' copy (the
    /// service's 404), or anything else (the Mac's own words for it).
    public enum InventoryWait: Equatable, Sendable { case notPaired, notWritten, other }

    public static func inventoryWait(paired: Bool, status: Int?) -> InventoryWait {
        !paired ? .notPaired : status == 404 ? .notWritten : .other
    }

    public static let inventoryNotWritten = "The Mac hasn't sent the inventory yet. Open PrepareMe on the Mac; once "
        + "its inventory is set up, it sends it within a minute."  // a Mac with none answers 404 too (review)

    public static func inventoryNotPaired(device: String = "phone") -> String {
        "Pair this \(device) with the Mac at home to get the inventory."
    }

    /// Beta run 2, B2-04 (choice a): under that line, the way to the inventory with the Mac gone, and the lines over a
    /// copy taken from the PrepareMe Backup (read only until the device is paired)
    public static let inventoryFromBackup = "Away from the Mac? Add the inventory and meeting places from "
        + "the PrepareMe Backup: Downloads \u{203A} Away from the Mac \u{203A} Add from Files."

    /// `paired`: a paired device that took the backup's copy while it held none; its changes open at its next look.
    /// Short, the backup named once (beta run 3, B3-07: the line had named it twice)
    public static func backupCopyReadOnly(device: String = "phone", paired: Bool = false) -> String {
        paired ? "Read only until this \(device) reaches the Mac at home."
            : "Read only until this \(device) is paired with the Mac."
    }

    /// `written`: when the home Mac wrote the copy, as the screen shows a date and time
    public static func backupCopyWritten(_ written: String) -> String {
        "From the PrepareMe Backup, written \(written)."
    }

    /// What "Throw these away" asks first (beta run 2, B2-11; R4.3): the waiting changes the Mac didn't keep go, not the
    /// items, and nothing brings them back.
    public static func throwAwayTitle(count: Int) -> String {
        "Throw away \(count) \(count == 1 ? "change" : "changes") the Mac didn't keep?"
    }
    public static let throwAwayMessage = "Only these waiting changes go. The items stay as the Mac has them, and nothing "
        + "brings the changes back."
    public static let throwAwayButton = "Throw these away"
    public static let throwAwayKeep = "Keep them"

    /// The Mac's steps for pairing, said where a phone pairs: before Pair with the Mac, and in Pair again's sheet (F44;
    /// beta run 2, B2-21: no longer under the button, where a Mac only asleep showed them). `button` is the phone's
    /// button the steps end on; nil in the sheet, where the camera already shows.
    public static func pairSteps(device: String = "phone", button: String? = "Pair with the Mac") -> String {
        "On the Mac: Settings › Devices, pick whose \(device). Then "
            + (button.map { "tap \($0) and scan" } ?? "scan") + " the code."
    }

    /// Mac Settings › Devices, under the names (beta run 2, B2-17: the app's name cut from inside the app)
    /// A phone's name shows on the pins it adds, on every device (owner, 2026-11-12); nowhere else off this Mac.
    public static let phoneNamesNote = "A name shows on the pins that device adds, on every device."

    /// The inventory's line on a phone that may only read it (B2-17), and the reason a refused change gives
    public static let readOnlyInventory = "Read only. An adult's phone or the Mac can change it."

    /// Pair with nothing in the paste box (beta run 2, B2-19): asks for the code rather than call it wrong.
    public static func pasteProblem(_ pasted: String) -> String? {
        pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Paste the code first." : nil
    }

    /// A pasted or scanned text that isn't a pairing code (beta run 2: no app name in it).
    public static let notAPairingCode = "That isn't a pairing code."

    /// Today's warning when a base file can't update for lack of room (phase M: a stale library is never quiet), the
    /// same words on a child's phone, which removes files too (family downloads plan, phase 2). `file` is the first
    /// such file's name, `more` how many others; the two sizes never read the same (StorageWords.room).
    /// With `canRemove` (family downloads plan, phase 4, decision 2) the row's button names the largest file the device
    /// may remove (`removeButton`), so the words point at it; without, today's words.
    public static func roomWarning(file: String, more: Int, need: Int64, free: Int64, device: String = "phone",
                                   canRemove: Bool = false) -> String {
        let sizes = StorageWords.room(need: need, free: free)
        let others = more > 0 ? " (and \(more) more)" : ""
        return "Not enough room for \(file)\(others): it needs \(sizes.need) free and this \(device) has "
            + "\(sizes.free). " + (canRemove ? "Free some space, or remove a file." : "Free some space, or remove a map under Downloads.")
    }

    /// The room warning's one tap (phase 4): the largest removable file and its size; it asks as Remove does
    public static func removeButton(title: String, size: Int64) -> String {
        "Remove \(title) (\(StorageWords.size(size)))…"
    }

    // MARK: The Library's Download cards (family downloads plan, phase 5)

    public static let notDownloaded = "Not downloaded"
    public static let readyBar = "Ready to download"
    public static let downloadAtHome = "Download at home"
    public static let openDownloads = "Open Downloads"
    /// A card's line while the Mac didn't answer the last check: its Download waits for home
    public static let waitingForMac = "Waiting for the Mac: it downloads at home, over Wi-Fi."
    public static let atHome = "It downloads from the Mac at home, over Wi-Fi."

    /// Download's place on a card when the file would pass the floor: what it needs free (`LibraryPlan.need`)
    public static func noRoom(need: Int64) -> String { "Not enough room (needs \(StorageWords.size(need)) free)" }

    /// A category's or folder's count with its files not downloaded: "3", or "3, 2 to download"
    public static func count(_ total: Int, toDownload: Int) -> String {
        toDownload > 0 ? "\(total), \(toDownload) to download" : "\(total)"
    }

    /// The not-downloaded sheet's size line: "It is 2 GB; this phone has 30 GB free."
    public static func sizeAndFree(size: Int64, free: Int64, device: String = "phone") -> String {
        "It is \(StorageWords.size(size)); this \(device) has \(StorageWords.size(free)) free."
    }

    /// A file the Mac set to Always for this device, in place of Remove (phase 4, decision 8)
    public static func keptByMac(device: String = "phone") -> String { "Kept on this \(device) (set on the Mac)." }

    /// Error codes that say the device is full whatever its free space reads after (phase 4's check, iOS 27.2 SDK
    /// headers): Foundation's NSFileWriteOutOfSpaceError (640) and POSIX ENOSPC (28), from moving a finished download.
    /// A download that stops mid-way gives NSURLErrorCannotWriteToFile (-3003), which names no cause, so that one and
    /// every other code read as full only under the spare (`LibraryPlan.spareBytes`).
    static let fullCodes: Set<Int> = [640, 28]

    static func ranOutOfRoom(code: Int, free: Int64) -> Bool {
        fullCodes.contains(code) || free < LibraryPlan.spareBytes
    }

    /// A download that stopped part-way: "This phone ran out of room." in place of the code when it did
    public static func downloadStopped(received: Int64, code: Int, free: Int64, device: String = "phone") -> String {
        if ranOutOfRoom(code: code, free: free) {
            return "This \(device) ran out of room. It carries on at the next check once there is space."
        }
        return "The download stopped after \(StorageWords.size(received)) (code \(code)); it carries on at the next check."
    }

    /// A finished download the device couldn't move into place, the same way
    public static func downloadNotKept(code: Int, free: Int64, device: String = "phone") -> String {
        if ranOutOfRoom(code: code, free: free) {
            return "This \(device) ran out of room. It is tried again at the next check once there is space."
        }
        return "The finished download couldn't be kept (code \(code)); tried again at the next check."
    }

    /// A child's phone beside Pair again (phase 9 review; the Mac's steps are in the adult's sheet).
    public static let pairStartsOnMac = "Pairing starts on the Mac at home."

    /// The install's yearly warning (Task 9.3; F47; owner, 2026-10-18, by click, nothing new stored; "the Mac at home"
    /// in place of "the adult who set up PrepareMe", owner, 2026-11-15, by click): how it's fixed, by when, and where
    /// the library still reads if it lapses. `until` is
    /// InstallInfo's line ("This install opens until …").
    public static func yearlyWarning(until line: String, device: String = "phone") -> String {
        let files = device == "iPad" ? "iPad" : "iPhone"
        return line + " Reinstall it from the Mac at home before then. If it won't open, "
            + "the library still reads in Kiwix: Files › On My \(files) › PrepareMe."
    }

    // TestFlight builds (over-the-air plan, phase 2, layer 3). Apple documents no address that opens an app's own page
    // in TestFlight, so Update opens TestFlight itself and the words say the two taps after it.
    static let updateSteps = "Tap Update, then PrepareMe, then Update."

    /// Home Mac's This install line for a TestFlight build. `until` is the date as shown.
    public static func testflightLine(until: String, days: Int) -> String {
        "This build opens until \(until) (\(days) days). It updates itself through TestFlight."
    }

    /// Home Mac's This install line on a copy from the App Store (Unlisted plan, phase 5): no date, no warning, no Update
    public static let storeLine = "From the App Store. It doesn't expire."

    /// Home Mac's and Today's sentence once a TestFlight build is `days` old (21 or more: two missed weekly rebuilds),
    /// beside one Update button; the same on a child's device. Never the word "build" (the plan's Requirement B).
    public static func notUpdated(days: Int) -> String {
        "PrepareMe hasn't updated itself for \(days / 7) weeks. " + updateSteps
    }

    /// The last-30-days alert of a TestFlight build, whose one button is Update. `line` is testflightLine's.
    public static func testflightWarning(until line: String, device: String = "phone") -> String {
        let files = device == "iPad" ? "iPad" : "iPhone"
        return line + " " + updateSteps + " If it won't open, the library still reads in Kiwix: Files › On My \(files) › "
            + "PrepareMe."
    }

    /// The phone's own notification `days` before the install stops opening (layer 3)
    public static let endNoticeTitle = "PrepareMe stops opening soon"
    public static func endNotice(days: Int, testflight: Bool) -> String {
        let more = days == 1 ? "1 more day" : "\(days) more days"
        return testflight ? "PrepareMe opens for \(more). Open it and tap Update."
            : "This install opens for \(more). Reinstall it from the Mac at home."
    }

    /// A file's name as Home Mac shows it: the entry's own title (a download's, the street map's), else the volume's
    /// title from packer/volumes.toml without "PrepareMe: " (the words Find a map uses for the topo files), else the
    /// file's name in words.
    public static func title(_ entry: Manifest.Entry) -> String {
        if let title = entry.title, !title.isEmpty { return title }
        var stem = entry.name
        for suffix in [".zim", ".pmtiles"] where stem.hasSuffix(suffix) { stem = String(stem.dropLast(suffix.count)) }
        if stem.hasPrefix("prepareme-") { stem = String(stem.dropFirst("prepareme-".count)) }
        if let known = names[stem] { return known }
        for (prefix, words) in [("maps-topo-today-", "Topo today %@ of 10"), ("maps-topo-older-", "Older topo %@ of 5"),
                                ("maps-border-", "Border topo, %@")] where stem.hasPrefix(prefix) {
            return String(format: words, String(stem.dropFirst(prefix.count)))
        }
        let spaced = stem.replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// A library's ZIM title ("PrepareMe: guides & household", still that for the App Store Kiwix's list) as the app
    /// shows it everywhere (beta run 2, B2-17): its plain name, the one `title` gives its file, so a library has one
    /// name wherever a reader sees it. A title without the app's name (a catalog download's) is left as it is.
    /// packer.config.SHOWN_NAMES is the same table (test_config pins them equal).
    public static func plainLibraryTitle(_ zimTitle: String) -> String {
        let prefix = "PrepareMe: "
        guard zimTitle.hasPrefix(prefix) else { return zimTitle }
        let plain = String(zimTitle.dropFirst(prefix.count))
        if let known = shownTitles[plain.lowercased()] { return known }
        return plain.prefix(1).uppercased() + plain.dropFirst()
    }

    static let shownTitles = [
        "guides & household": "Guides and today's page", "guides and household": "Guides and today's page",
        "reference": "Medical references and manuals", "video": "Videos", "vehicles": "Vehicle manuals",
    ]

    static let names = [
        "daily": "Guides and today's page", "reference": "Medical references and manuals", "media": "Videos",
        "vehicles": "Vehicle manuals", "item-manuals": "Equipment manuals", "maps-roads": "Road maps",
        "maps-updates": "Map updates", "maps-reading": "Map reading", "maps-home-topo": "Home-area topo", "maps-home": "Home-area maps",
        "maps-routes": "Routes out", "maps-topo-overview": "Topo overview", "street-map": "Street map",
    ]

    /// "11:12 AM" today, else "Oct 14 at 9:05 AM", with the year when it isn't this year's.
    static func when(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = formatted(date, "h:mm a", timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return "\(formatted(date, sameYear ? "MMM d" : "MMM d, yyyy", timeZone)) at \(time)"
    }

    /// "last reached today.", or "last reached Sep 21 (30 days ago).", by the days on the calendar where the phone is
    static func reached(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        guard days > 0 else { return "last reached today." }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = formatted(date, sameYear ? "MMM d" : "MMM d, yyyy", timeZone)
        return "last reached \(day) (\(days) \(days == 1 ? "day" : "days") ago)."
    }

    /// "Oct 6", or "Dec 30, 2025" in another year; nil when the text isn't a date.
    static func day(_ text: String, now: Date, timeZone: TimeZone) -> String? {
        guard let date = parse(text, timeZone: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatted(date, sameYear ? "MMM d" : "MMM d, yyyy", timeZone)
    }

    /// ISO 8601 with seconds; minutes only, as the packer writes the library's own time; or a bare day, as it writes
    /// the street map's data date, read as that day where the phone is (so it's shown as the same day).
    static func parse(_ text: String, timeZone: TimeZone) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        if let date = reader.date(from: text) { return date }
        reader.timeZone = timeZone
        reader.dateFormat = "yyyy-MM-dd"
        return reader.date(from: text)
    }

    static func formatted(_ date: Date, _ format: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
