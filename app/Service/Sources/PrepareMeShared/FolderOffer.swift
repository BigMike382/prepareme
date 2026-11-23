import CryptoKit
import Foundation

/// What a phone may take from a picked PrepareMe Backup folder (concept-doc plan, phase B; owner, 2026-10-18;
/// docs/plans/2026-10-18-phase-b-add-from-files.md). Kept here, apart from the app, so `swift test` holds the rules.
///
/// - Only what the folder's list names, that the phones may get (`forPhones`), and that is in the folder; never a file
///   the list doesn't name, and never a library whose ID this phone holds under another name (LibraryPlan.idTaken).
/// - Each file is missing here, newer, the same or older than the phone's copy: by the libraries' own dates when both
///   lists have one, and by the delivered dates where those are equal or missing (an hourly build keeps the library's
///   date); an older copy (a drive filled weeks ago) needs an adult's word, with both dates shown.
/// - The list must be signed by the key this phone learned from its Mac over the paired Wi-Fi channel; otherwise every
///   file needs an adult's word (owner: "Signed by the Mac"). A signature that doesn't hold is said as such, and needs
///   an adult too: refusing it outright would add nothing (anyone could strip the signature instead) and could stop a
///   real restore (review, tasks 1 to 3). A file this phone's Mac no longer sends it needs an adult as well.
/// - A child's device (owner, 2026-11-15, decision 6 of docs/plans/2026-11-15-family-downloads.md) takes only from a list
///   signed by its own Mac, only files missing or newer than its own, and never one its Mac doesn't send it; there is
///   no "add anyway". Anything else is one plain line and no button (`ChildRefusal`, `Item.addable`).
/// - The phones' inventory copy, with the rally points (beta run 2, B2-04, choice a; `Manifest.inventory`), is offered
///   to a device that isn't paired, when the folder's is newer than any it holds, and to a paired one only while it
///   holds none: a paired device keeps its own copy, which its Mac keeps current, unless that copy came from a backup
///   itself (a replacement Mac with none for it yet), when it is offered a newer one as an unpaired device is
///   (whole-plan review). Taken under the same adult's OK (on a child's device, only from its Mac's signed list), and
///   checked three ways before it is used (`readInventory`). A device that takes it reads it only (the app).
public enum FolderOffer {
    public enum Trust: Equatable, Sendable {
        case signedByThisMac, unsigned, otherKey, phoneKnowsNoKey, badSignature
    }

    public enum State: Equatable, Sendable {
        case missing, newer, same, older
        /// Another copy with the same date, or dates that can't be compared: an adult decides
        case different
    }

    public struct Item: Equatable, Sendable {
        public var entry: Manifest.Entry
        public var state: State
        /// The phone's copy's delivered date, for an older or newer file
        public var heldDeliveredAt: String?
        /// Whether an adult must confirm taking it: an older or different copy, a file this phone's Mac no longer sends
        /// it, or a list this phone can't vouch for
        public var needsAdult: Bool
        /// A file someone removed from this phone on purpose (Remove from this phone): offered one by one only, never in
        /// Add all (cloud review)
        public var declined = false
        /// The phone's own copy's entry, for its library date (beta run 2, B2-20)
        public var heldEntry: Manifest.Entry?
        /// False for an older copy on a child's device: shown with `childNewerHere` in place of its Add button
        public var addable = true
    }

    /// Why a child's device takes nothing from a folder (family downloads plan, phase 2)
    public enum ChildRefusal: Equatable, Sendable {
        /// unsigned, signed by another key, or changed after signing
        case notFromYourMac
        /// this device hasn't learned its Mac's key yet
        case noKeyYet
    }

    /// The phones' inventory copy as the folder's list names it, against the one this device holds
    public struct InventoryItem: Equatable, Sendable {
        public var entry: Manifest.Inventory
        /// `.missing` (none held) or `.newer`: nothing else is offered
        public var state: State
        public var heldWrittenAt: String?
        public var needsAdult: Bool
    }

    /// What one Add takes: the files and, when offered, the inventory copy, with the one count and size the button and
    /// the progress both show.
    public struct Batch: Equatable, Sendable {
        public var items: [Item]
        public var inventory: InventoryItem?

        public init(items: [Item], inventory: InventoryItem? = nil) {
            self.items = items
            self.inventory = inventory
        }

        /// The files, and the inventory copy as one more
        public var count: Int { items.count + (inventory == nil ? 0 : 1) }
        /// Their sizes together, the inventory copy's included
        public var size: Int64 { items.reduce(inventory?.entry.size ?? 0) { $0 + $1.entry.size } }
    }

    /// What the device holds of the inventory: whether it is paired, its copy's time (nil: none), and whether that
    /// copy came from a backup (the app's fromBackup) rather than its Mac
    public struct HeldInventory: Equatable, Sendable {
        public var paired: Bool
        public var writtenAt: String?
        public var fromBackup: Bool

        public init(paired: Bool, writtenAt: String?, fromBackup: Bool = false) {
            self.paired = paired
            self.writtenAt = writtenAt
            self.fromBackup = fromBackup
        }
    }

    public struct Offer: Equatable, Sendable {
        public var trust: Trust
        public var items: [Item] = []
        /// The folder's inventory copy, when this device may take it
        public var inventory: InventoryItem?
        /// A paired device keeping its own inventory copy from its Mac, said on the screen
        public var inventoryKept = false
        /// Names the list gives that aren't in the folder (a drive copied part-way)
        public var absent: [String] = []
        public var child = false
        /// A child's device refusing the whole folder: its one line, and no button
        public var childRefusal: ChildRefusal?
        public var needsAdult: Bool { trust != .signedByThisMac }
    }

    /// The offer from the folder's list (`list`, read and checked by BackupSignature.read), the plain names in the
    /// folder and their sizes (`present`, Backup.listing), and what this phone holds (`record`; its Mac's list carries
    /// the key the phone learned).
    public static func make(_ list: BackupSignature.Read, present: [String: Int64], record: LibraryRecord,
                            child: Bool, inventory held: HeldInventory = HeldInventory(paired: false, writtenAt: nil))
        -> Offer {
        let trust: Trust
        switch list.verdict {
        case .badSignature: trust = .badSignature
        case .unsigned: trust = .unsigned
        case let .signed(key):
            guard let known = record.backupKey ?? record.manifest?.backupKey else { trust = .phoneKnowsNoKey; break }
            trust = key == known ? .signedByThisMac : .otherKey
        }
        var offer = Offer(trust: trust, child: child)
        if child, trust != .signedByThisMac {  // decision 6: refused plainly, the inventory copy too
            offer.childRefusal = trust == .phoneKnowsNoKey ? .noKeyYet : .notFromYourMac
            return offer
        }
        // the Mac's own list, when this phone has one: a file it no longer sends this phone needs an adult's word (a
        // drive filled before a download was kept for the Mac alone, or a file the Mac dropped; review, tasks 1 to 3)
        let sent = record.manifest.map { Set($0.files.filter(\.forPhones).map(\.name)) }
        let dropped = Set(record.manifest?.drop ?? [])  // phase 3: the Mac's Never and un-ticked files, never offered
        for entry in list.manifest.files where entry.forPhones && !dropped.contains(entry.name) {
            // in the folder at its listed size; `inICloud` (-1, an iCloud placeholder whose size isn't known here) counts,
            // and a file of another size (a drive copied part-way) is said with the missing ones, never offered
            guard let size = present[entry.name], size == entry.size || size == inICloud else {
                offer.absent.append(entry.name)
                continue
            }
            guard !LibraryPlan.idTaken(entry, list.manifest, record) else { continue }
            let held = record.held[entry.name]?.entry
            let state: State
            if let held {
                if held.sha256 == entry.sha256 {
                    state = .same
                } else if let mine = madeAt(held), let theirs = madeAt(entry), theirs != mine {
                    // by the library's own date when both lists have one, to the instant (B2-20; checkpoint 1)
                    state = theirs > mine ? .newer : .older
                } else if let mine = date(held.deliveredAt), let theirs = date(entry.deliveredAt), theirs != mine {
                    // equal library dates (an hourly front-only build keeps the recorded one, packer/__main__.py) or
                    // either missing: by the delivered dates, so the daily file delivered later is newer
                    state = theirs > mine ? .newer : .older
                } else {
                    state = .different
                }
            } else {
                state = .missing
            }
            let unsent = sent.map { !$0.contains(entry.name) } ?? false
            // a child's device: only missing or newer files its Mac sends it; an older copy is shown, never added
            if child, unsent || state == .different { continue }
            offer.items.append(Item(entry: entry, state: state, heldDeliveredAt: held?.deliveredAt,
                                    needsAdult: state == .older || state == .different || unsent
                                        || trust != .signedByThisMac,
                                    declined: record.declined.contains(entry.name), heldEntry: held,
                                    addable: !(child && state == .older)))
        }
        if let entry = list.manifest.inventory {
            if let size = present[entry.name], size == entry.size || size == inICloud {
                if let state = inventoryState(paired: held.paired, held: held.writtenAt, backup: entry.writtenAt,
                                              fromBackup: held.fromBackup) {
                    offer.inventory = InventoryItem(entry: entry, state: state, heldWrittenAt: held.writtenAt,
                                                    needsAdult: trust != .signedByThisMac)
                } else {
                    offer.inventoryKept = held.paired && !held.fromBackup  // only a copy from the Mac is "its own"
                }
            } else {
                offer.absent.append(entry.name)
            }
        }
        return offer
    }

    /// Whether a device takes the folder's inventory copy (written at `backup`), against the one it holds (written at
    /// `held`, nil: none): `.missing` or `.newer`, or nil to keep its own. A paired device keeps a copy from its Mac
    /// (newer than a backup's, and its Mac's copy wins); one not paired, or paired holding a copy that came from a backup
    /// (`fromBackup`: a replacement Mac with none for it yet; whole-plan review), takes only a newer copy, so a drive
    /// filled weeks ago never replaces a later one.
    public static func inventoryState(paired: Bool, held: String?, backup: String, fromBackup: Bool = false) -> State? {
        guard let held else { return .missing }
        guard !paired || fromBackup, let mine = date(held), let theirs = date(backup), theirs > mine else { return nil }
        return .newer
    }

    /// The folder's inventory copy, read whole, after its three checks: its listed size, its SHA-256, and that it reads
    /// as the phones' copy the list names (its time); nil for a copy failing any, which is refused
    public static func readInventory(_ data: Data, entry: Manifest.Inventory) -> PhoneInventory? {
        guard Int64(data.count) == entry.size, Hex.string(SHA256.hash(data: data)) == entry.sha256,
              let copy = try? JSONDecoder().decode(PhoneInventory.self, from: data), copy.writtenAt == entry.writtenAt,
              !FileFormat.isNewer(copy.format)  // never one this build might read wrongly (audit P2h)
        else { return nil }
        return copy
    }

    /// The size `present` gives a file iCloud keeps off the phone, listed only as its placeholder
    public static let inICloud: Int64 = -1

    /// The real name behind an iCloud placeholder (".name.icloud", how iCloud Drive may list a file it keeps off the
    /// device), when that name is a plain one; nil for any other name
    public static func placeholderName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return FileName.isPlain(real) ? real : nil
    }

    /// The folder's plain files and their sizes, with each iCloud placeholder's real name at `inICloud`
    public static func present(names: [String], sizes: [String: Int64]) -> [String: Int64] {
        var found = sizes
        for name in names {
            if let real = placeholderName(name), found[real] == nil { found[real] = inICloud }
        }
        return found
    }

    /// What Add all takes: the newer and missing files, never one removed on purpose
    public static func takeAll(_ offer: Offer) -> [Item] {
        offer.items.filter { ($0.state == .newer || $0.state == .missing) && !$0.declined }
    }

    /// Free space needed to add `items`: each file's size, twice for one iCloud must first bring to the phone (its
    /// downloaded copy and the phone's own sit side by side while copying; cloud review), plus the 1 GB Get this file
    /// keeps, since the phone's copy stays until the new one passes
    public static func need(_ items: [Item], notLocal: Set<String>) -> Int64 {
        items.reduce(LibraryPlan.spareBytes) { $0 + $1.entry.size * (notLocal.contains($1.entry.name) ? 2 : 1) }
    }

    /// The library's own date (`libraryAsOf`), or nil when the entry has none or it can't be parsed (the caller then
    /// compares the delivered dates)
    static func madeAt(_ entry: Manifest.Entry) -> Date? {
        entry.libraryAsOf.flatMap { HomeMacWords.parse($0, timeZone: .current) }
    }

    /// The offered file's note on Add from Files, by when its library was made (`HomeMacWords.ageParts`: "Made Oct 12"),
    /// not when the backup's copy was written, which can be days after (beta run 2, B2-20). The street map says
    /// "OpenStreetMap as of"; a copy whose date can't be read says only how it compares.
    public static func fromLine(_ item: Item, device: String, now: Date = Date(),
                                timeZone: TimeZone = .current) -> String {
        let mine = HomeMacWords.ageParts(item.entry, now: now, timeZone: timeZone)
        let theirs = item.heldEntry.flatMap { HomeMacWords.ageParts($0, now: now, timeZone: timeZone) }
        let first = mine.map { "\($0.label) \($0.day)".prefix(1).uppercased() + "\($0.label) \($0.day)".dropFirst() }
            ?? "Date not known"
        let street = item.entry.isStreetMap
        // the same day shown on both (same library date, or the same day in `timeZone`): the day can't tell them
        // apart, so the line says which is later rather than one day twice (checkpoint 1)
        let sameDay = mine != nil && theirs?.day == mine?.day
        switch item.state {
        case .newer:
            if sameDay { return "\(first), later than this \(device)'s." }
            return "\(first); this \(device)'s " + (theirs.map { street ? "is as of \($0.day)" : "was made \($0.day)" }
                ?? "is from an unknown date") + "."
        case .older:
            if sameDay { return "\(first); this \(device)'s is newer." }
            return "\(first); this \(device)'s is newer, " + (theirs.map { street ? "as of \($0.day)" : "made \($0.day)" }
                ?? "from an unknown date") + "."
        case .missing: return "\(first)."
        case .same: return "The same as this \(device)'s."
        case .different:
            return sameDay
                ? "\(first), the same day as this \(device)'s, but not the same copy."
                : "\(first), as this \(device)'s is, but not the same copy."
        }
    }

    /// The confirmation over an older copy, with both dates in the same words (`ageParts`: "made Oct 6 against Oct 12",
    /// "OpenStreetMap as of Oct 6 against Oct 12"; one day for both: "both made Oct 12").
    public static func olderLine(_ item: Item, title: String, device: String, now: Date = Date(),
                                 timeZone: TimeZone = .current) -> String {
        let mine = HomeMacWords.ageParts(item.entry, now: now, timeZone: timeZone)
        let theirs = item.heldEntry.flatMap { HomeMacWords.ageParts($0, now: now, timeZone: timeZone) }
        let dates = mine.map { theirs?.day == $0.day ? "both \($0.label) \($0.day)"
            : "\($0.label) \($0.day) against \(theirs?.day ?? "an unknown date")" }
            ?? "an unknown date against \(theirs?.day ?? "an unknown date")"
        return "This copy of \(title) is older than the one on this \(device): \(dates). Add it only if the "
            + "\(device)'s copy is wrong."
    }

    public static func date(_ text: String) -> Date? {
        let stamp = ISO8601DateFormatter()
        if let found = stamp.date(from: text) { return found }
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return stamp.date(from: text)
    }

    // MARK: Words (owner's look at the gate)

    /// `device` is "iPad" on an iPad (ThisDevice), as in every line here.
    public static func trustLine(_ trust: Trust, device: String = "phone") -> String? {
        switch trust {
        case .signedByThisMac: return nil
        case .unsigned:
            return "This folder's list isn't signed by your Mac. Add from it only if it came from your own backup."
        case .otherKey:
            return "This folder's list was signed by a Mac this \(device) doesn't know. Add from it only if it came from "
                + "your own backup."
        case .phoneKnowsNoKey:
            return "This \(device) hasn't learned your Mac's signature yet (it does at home). Add from this folder only if "
                + "it came from your own backup."
        case .badSignature:
            return "This folder's list was changed after your Mac signed it. Add from it only if you know why, and "
                + "only from your own backup."
        }
    }

    /// The inventory's row in Add from Files
    public static let inventoryTitle = "Inventory and meeting places"
    /// `paired`: a paired device holding no copy, whose own Mac's copy replaces this one at its next look
    public static func inventoryNote(device: String = "phone", paired: Bool = false) -> String {
        paired ? "Read only on this \(device) until it reaches the Mac at home."
            : "Read only on this \(device) until it is paired with the Mac."
    }
    public static func inventoryKeptLine(device: String = "phone") -> String {
        "The inventory and meeting places: this \(device) keeps its own copy from the Mac."
    }
    /// Said when a copy offered is kept out after all: the Mac's words for a copy from the Mac, never for one that came
    /// from a backup (whole-plan review)
    public static func inventoryHeldLine(device: String = "phone", fromBackup: Bool) -> String {
        fromBackup ? "The inventory and meeting places: this \(device) already has a copy as new as this one."
            : inventoryKeptLine(device: device)
    }

    /// Add from Files' opening line (beta run 2, B2-17)
    public static let addIntro = "When the Mac can't be reached: pick the \(Backup.folderName) folder (iCloud Drive or a "
        + "USB-C drive). Each file is checked first."

    public static let noList = "This folder has no PrepareMe list (manifest.json). Pick the PrepareMe Backup folder itself."
    public static let damagedList = "This folder's list can't be read, so nothing is added from it."

    /// A child's device refusing a folder (decision 6), in place of the trust line and every button
    public static func childLine(_ refusal: ChildRefusal, device: String = "phone") -> String {
        switch refusal {
        case .notFromYourMac: return "This folder isn't from your Mac, so nothing is added from it."
        case .noKeyYet: return "This \(device) hasn't learned your Mac's signature yet. It does at home."
        }
    }
    /// A child's device, in place of an older copy's Add button
    public static func childNewerHere(device: String = "phone") -> String { "This \(device)'s copy is newer." }
}

/// The steps Add from Files and Add a travel map share to read a picked folder (phase K, finding 23): its list read
/// (downloaded first if iCloud holds it off the phone), parsed by the screen's own reader, and set against the folder's
/// files; refused three ways, each in the screen's own words. Each screen keeps its offer and its checks.
public enum FolderRead {
    /// Said when iOS won't open the picked folder's security scope
    public static let notLetIn = "PrepareMe wasn't let into that folder. Pick it again."
    /// Said while the list is read
    public static let reading = "Reading the folder's list…"
    /// Said under a file whose copy Stop ended (FileCopy's words)
    public static let stopped = FileCopy.words(.stopped)

    public enum Refusal: Error, Equatable, Sendable {
        /// `newer`: a list in a format this build doesn't read (audit P2h, `FileFormat`), nothing in it taken
        case noList, damaged, unreadable, newer

        public func words(noList: String, damaged: String, unreadable: String, device: String) -> String {
            switch self {
            case .noList: return noList
            case .damaged: return damaged
            case .unreadable: return unreadable
            case .newer: return FileFormat.newerFiles(device: device)
            }
        }
    }

    /// The list `named` in `folder`, through `read` then `parse`, and the folder's files (`FolderOffer.present`): no
    /// list is `noList`, one that can't be read `unreadable`, one that doesn't parse `damaged`, and a folder that can't
    /// be listed `unreadable` (never taken for an empty folder). Blocking: run off the main thread.
    public static func list<List>(in folder: URL, named: String, read: (URL) -> Data? = coordinatedRead,
                                  parse: (Data) throws -> List) -> Result<(List, [String: Int64]), Refusal> {
        let file = folder.appendingPathComponent(named)
        guard let data = read(file) else {
            return .failure(FileManager.default.fileExists(atPath: file.path) ? .unreadable : .noList)
        }
        let list: List
        do { list = try parse(data) } catch Manifest.Problem.newer { return .failure(.newer) } catch {
            return .failure(.damaged)
        }
        // the folder's files from a listing that must work (a refusal is never taken for an empty folder), with each
        // iCloud placeholder's real name counted as there (cloud review)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              let sizes = try? Backup.listing(in: folder) else { return .failure(.unreadable) }
        return .success((list, FolderOffer.present(names: names, sizes: sizes)))
    }

    /// A small file's bytes through NSFileCoordinator, which has iCloud bring it to the phone first
    public static func coordinatedRead(_ url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { data = try? Data(contentsOf: $0) }
        return data
    }
}
