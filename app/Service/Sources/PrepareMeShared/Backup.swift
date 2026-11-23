import CryptoKit
import Foundation

/// The iCloud backup (concept-doc plan, phase A; docs/plans/2026-10-17-phase-a-icloud-backup.md): the Mac app copies
/// every file the phones can get into iCloud Drive › PrepareMe Backup, so a phone can get its library back if the Mac is
/// lost. Kept here, apart from the app, so `swift test` holds the rules.
///
/// - Only entries `forPhones` passes are copied or named: a `family: false` download never is, and one switched off
///   leaves the backup. A file the delivery no longer lists leaves it too.
/// - The copies come from the Mac app's own checked copies (`LibraryStore`'s held files), which are never replaced
///   under a reader, so the backup can't catch the packer mid-swap. A file the app hasn't got current yet waits, and the
///   backup keeps its older copy meanwhile.
/// - What changed is found from the manifests and a stat of each backup copy (its size), never by reading the backup's
///   copies: they may be in iCloud only, and reading would download them first. The backup's manifest is compared from
///   its local mirror (Application Support › PrepareMe › backup), never read back from iCloud unless the mirror is gone.
/// - Each copy is an APFS clone (a plain copy where cloning isn't possible) under a temporary name, read back (size and
///   SHA-256) and only then renamed into place. The backup's one manifest, in the `Manifest` format, never names a copy
///   it doesn't match: before anything is replaced or removed it is rewritten without those entries (mirror first),
///   and at the end it names every whole copy (iCloud's first, then the mirror). So a stop at any point, a power cut
///   included, leaves it true; the mirror may name less, never more, so the next round only copies again.
/// - The daily file's previous copy is kept in `Older copy` (owner, 2026-10-17: "Last daily file only"), so a household
///   page deleted by mistake can come back. No other kind keeps an older copy.
/// - A file in the folder that isn't the backup's own (not named by the backup or the delivery) is left alone.
/// - The phones' copy of the inventory goes too (beta run 2, B2-04, choice a; `InventorySource`): the very copy every
///   paired phone gets (no Private row, no Mac-only column), with the rally points, so a device set up from the backup
///   after the Mac is lost has both, read only. Its bytes are read once, checked and written whole, then read back;
///   the list names it in its own field (`Manifest.inventory`), never among the library files, and never one it
///   doesn't match. Without the Mac's copy the backup keeps its own.
public enum Backup {
    public static let folderName = "PrepareMe Backup"
    public static let manifestName = "manifest.json"
    public static let olderFolder = "Older copy"
    public static let readMeName = "Read me first.txt"
    /// The files whose previous copy is kept (owner, 2026-10-17)
    public static let olderKept: Set<String> = ["prepareme-daily.zim"]
    /// Free space kept beyond the files to copy (decimal GB, as Finder counts)
    public static let margin: Int64 = 10_000_000_000
    static let temporaryPrefix = ".backup-"

    public enum Problem: Error, Equatable, Sendable {
        case noFolder
    }

    public enum Access: Equatable, Sendable {
        case ok, noFolder
        /// macOS refused the app iCloud Drive (its privacy question answered Don't Allow)
        case refused
        /// There, but it couldn't be opened for another reason
        case unreadable
    }

    /// Whether the folder is there and the app may look in it: a stat, then the folder opened and read, since macOS's
    /// privacy check lets a stat through and stops the open (F-081; cloud review, 1). The first open of iCloud Drive
    /// waits for the owner's answer to macOS's question, so the app calls this off the main thread.
    public static func access(_ folder: URL) -> Access {
        var info = stat()
        guard stat(folder.path, &info) == 0 else { return refusal(errno) ?? .noFolder }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .noFolder }
        guard let dir = opendir(folder.path) else { return refusal(errno) ?? .unreadable }
        errno = 0
        let read = readdir(dir) != nil || errno == 0
        let code = errno
        closedir(dir)
        return read ? .ok : refusal(code) ?? .unreadable
    }

    public static func refusal(_ code: Int32) -> Access? { code == EPERM || code == EACCES ? .refused : nil }

    /// Each plain name in the folder that is a file, and its size, from a stat: never a read. Throws when the folder
    /// can't be listed, so a refusal is never taken for an empty folder (cloud review, 1).
    public static func listing(in folder: URL) throws -> [String: Int64] {
        var found: [String: Int64] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where FileName.isPlain(name) {
            var info = stat()
            guard lstat(folder.appendingPathComponent(name).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                continue
            }
            found[name] = Int64(info.st_size)
        }
        return found
    }

    public struct Copy: Equatable, Sendable {
        public var entry: Manifest.Entry
        /// The held copy's file name in the app's library folder
        public var source: String
        /// The backup's own entry for the copy being replaced, while that copy is whole: named again if this copy fails
        public var fallback: Manifest.Entry?
    }

    /// The Mac's phones' copy, read once: the exact bytes the backup writes, and its entry for the list
    public struct InventorySource: Equatable, Sendable {
        public var entry: Manifest.Inventory
        public var data: Data
    }

    /// The backup's copy is written again when what it holds changes, or once it is this much older than the Mac's
    public static let inventoryRefresh: TimeInterval = 86_400

    /// The phones' copy in `data` as the backup takes it, or nil: it must read whole as a phones' copy and carry no
    /// Mac-only column (`Inventory.macOnlyLabels`: a Mac app gone wrong, or a planted file), so nothing a phone
    /// doesn't get reaches the backup.
    /// The shared pins go with it, as the rally points do (owner, 2026-11-12, by click: "Include pins"; the rally
    /// points by the 2026-10-20 ruling), each with the owner's name for the phone that added it.
    public static func inventorySource(_ data: Data?) -> InventorySource? {
        guard let data, let copy = try? JSONDecoder().decode(PhoneInventory.self, from: data) else { return nil }
        guard !copy.columns.contains(where: { column in
                  Inventory.macOnlyLabels.contains { InventoryFile.same($0, column.label) }
              }),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["writtenAt"] = nil
        guard let unstamped = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return InventorySource(entry: Manifest.Inventory(name: PhoneInventory.fileName, size: Int64(data.count),
                                                         sha256: Hex.string(SHA256.hash(data: data)),
                                                         writtenAt: copy.writtenAt,
                                                         content: Hex.string(SHA256.hash(data: unstamped))),
                               data: data)
    }

    /// The Mac app's phones' copy in its inventory folder (`PhoneInventory.fileName`), or nil
    public static func inventorySource(in folder: URL) -> InventorySource? {
        inventorySource(try? Data(contentsOf: folder.appendingPathComponent(PhoneInventory.fileName)))
    }

    /// The phones' copy's source between looks (whole-plan review): read, decoded and hashed again only when its
    /// file's size or modification date changed since the last look; the Mac app's look runs every 30 seconds, and the
    /// copy is large with hundreds of items. Keep one across looks.
    public struct InventoryCache: Sendable {
        var stamp: Stamp?
        var source: InventorySource?

        struct Stamp: Equatable, Sendable {
            let size: Int64
            let modified: Date
        }

        public init() {}

        /// `inventorySource(in:)`, from the last look while the file's size and date are the same
        public mutating func source(in folder: URL) -> InventorySource? {
            let path = folder.appendingPathComponent(PhoneInventory.fileName).path
            guard let found = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (found[.size] as? NSNumber)?.int64Value, let modified = found[.modificationDate] as? Date
            else {
                (stamp, source) = (nil, nil)
                return nil
            }
            let now = Stamp(size: size, modified: modified)
            if now != stamp {  // the stamp read before the file: a change while reading is read again next time
                (stamp, source) = (now, Backup.inventorySource(in: folder))
            }
            return source
        }
    }

    public struct Plan: Equatable, Sendable {
        public var copies: [Copy] = []
        /// The phones' copy to write, when the backup's is missing, or what it holds changed, or a day older
        public var inventoryCopy: InventorySource?
        /// The backup's whole copy staying while the rest is copied (nil while it is being replaced)
        public var inventoryKept: Manifest.Inventory?
        /// The list's inventory once the copy has landed
        public var inventoryFinal: Manifest.Inventory?
        /// The backup's whole copy being replaced: named again if the new one fails
        public var inventoryFallback: Manifest.Inventory?
        /// Names to take out of the folder, the backup's own copies only
        public var removals: [String] = []
        /// Names whose current copy moves to `Older copy` before the new one lands
        public var keepOlder: [String] = []
        /// The entries already whole in the backup and staying, as the backup's manifest names them now
        public var kept: [Manifest.Entry] = []
        /// The backup's manifest once every copy has landed, in the delivery's order
        public var final: [Manifest.Entry] = []
        /// Whether the manifest must first be rewritten without the entries being replaced or removed
        public var interimNeeded = false
        /// Whether the final manifest differs from the backup's (or the folder has none)
        public var rewrite = false
        public var bytes: Int64 = 0
        /// The delivery's SHA-256 for each file the phones can get, to count which backup copies are current
        public var delivered: [String: String] = [:]

        public var isDue: Bool { !copies.isEmpty || !removals.isEmpty || rewrite || inventoryCopy != nil }
        /// The files the phones can get, and how many of them the backup will hold current
        public var wanted: Int { delivered.count }
        public var current: Int { final.filter { delivered[$0.name] == $0.sha256 }.count }
    }

    /// What to copy, keep and remove. `delivery` is the delivery folder's list the app last read, `held` the app's own
    /// checked copies, `backup` the backup's manifest (nil: none, or unreadable, so nothing in it is trusted), `present`
    /// each plain name in the backup folder and its size from a stat. `holdOff` names files not to copy this time (a
    /// copy that failed lately, review 2): each keeps the backup's older copy, as a file not current here does.
    /// `inventory` is the Mac's phones' copy (`inventorySource`), nil when it has none or it can't be read; held off by
    /// its name, it isn't written this time and the backup's whole copy stays named (checkpoint 1).
    public static func plan(delivery: Manifest?, held: [String: HeldFile], backup: Manifest?,
                            present: [String: Int64], holdOff: Set<String> = [],
                            inventory: InventorySource? = nil) -> Plan {
        var plan = Plan()
        // A name listed twice is never trusted (Manifest.read refuses such a list; this is for any other caller)
        let names = (delivery?.files ?? []).map(\.name)
        let twice = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        let wanted = (delivery?.files ?? []).filter { $0.forPhones && !twice.contains($0.name) }
        // No list, or one naming nothing the phones can get (a broken build, a list not read yet): nothing is done,
        // never the whole backup taken out (review, task 2)
        guard !wanted.isEmpty else { return plan }
        var before: [String: Manifest.Entry] = [:]
        for entry in backup?.files ?? [] where before[entry.name] == nil { before[entry.name] = entry }
        for entry in wanted {
            plan.delivered[entry.name] = entry.sha256
            let old = before[entry.name]
            let whole = old.map { present[$0.name] == $0.size } ?? false
            if let copy = held[entry.name], copy.entry.sha256 == entry.sha256, copy.entry.size == entry.size,
               !holdOff.contains(entry.name) || old?.sha256 == entry.sha256 {
                if let old, whole, old.sha256 == entry.sha256 {
                    plan.kept.append(old)
                } else {
                    plan.copies.append(Copy(entry: entry, source: copy.file, fallback: whole ? old : nil))
                    plan.bytes += entry.size
                    if whole && olderKept.contains(entry.name) { plan.keepOlder.append(entry.name) }
                }
                plan.final.append(entry)
            } else if let old, whole {  // not current on this Mac yet: the backup's older copy stays
                plan.kept.append(old)
                plan.final.append(old)
            }
        }
        let staying = Set(plan.final.map(\.name))
        let ours = Set(before.keys).union((delivery?.files ?? []).map(\.name))
        plan.removals = present.keys.filter { ours.contains($0) && !staying.contains($0) }.sorted()
        let keptNames = Set(plan.kept.map(\.name))
        // the phones' copy: the backup's whole one stays unless the Mac's holds something else, or is a day newer
        let old = backup?.inventory.flatMap { present[$0.name] == $0.size ? $0 : nil }
        if let inventory, !holdOff.contains(inventory.entry.name), inventoryDue(inventory.entry, over: old) {
            plan.inventoryCopy = inventory
            plan.inventoryFinal = inventory.entry
            plan.inventoryFallback = old
            plan.bytes += inventory.entry.size  // the space check counts it with the files (checkpoint 1)
        } else {
            plan.inventoryKept = old
            plan.inventoryFinal = old
        }
        // before any copy lands or any file goes, the manifest names only what stays: written even when the mirror
        // already names less, since the folder's own may still name more (review, task 2)
        plan.interimNeeded = !plan.copies.isEmpty || !plan.removals.isEmpty
            || before.keys.contains { !keptNames.contains($0) }
            || (backup?.inventory != nil && plan.inventoryKept == nil)
        plan.rewrite = plan.final != (backup?.files ?? []) || plan.inventoryFinal != backup?.inventory
            || (present[manifestName] == nil && !plan.final.isEmpty)
        return plan
    }

    /// What a failed copy's hold-off is keyed on (review 2): a library file's SHA-256, so a changed file is tried at once
    public static func failureKey(_ entry: Manifest.Entry) -> String { entry.sha256 }

    /// The phones' copy's: what it holds (`content`, its SHA-256 without the time), else its SHA-256. The Mac rewrites
    /// it every 10 minutes with only its time changed, which must not end the hold-off; a real change does (checkpoint 1)
    public static func failureKey(_ entry: Manifest.Inventory) -> String { entry.content ?? entry.sha256 }

    /// The copies not tried this time (review 2; the phones' copy too, checkpoint 1): each whose last try failed
    /// within the hour (`failed`: name to `failureKey` then, the app keeps only the last hour's) and is still the same;
    /// none on Back up now (`force`)
    public static func holdOff(delivery: Manifest, inventory: Manifest.Inventory?, failed: [String: String],
                               force: Bool) -> Set<String> {
        guard !force else { return [] }
        var names = Set(delivery.files.filter { failed[$0.name] == failureKey($0) }.map(\.name))
        if let inventory, failed[inventory.name] == failureKey(inventory) { names.insert(inventory.name) }
        return names
    }

    /// The held-off copies the backup still doesn't hold current: each still a failure, said as one until it lands
    public static func stuck(_ holdOff: Set<String>, plan: Plan, inventory: Manifest.Inventory?) -> Set<String> {
        holdOff.filter { name in
            if let inventory, name == inventory.name { return inventoryDue(inventory, over: plan.inventoryFinal) }
            return !plan.final.contains { $0.name == name && plan.delivered[name] == $0.sha256 }
        }
    }

    public struct Room: Equatable, Sendable {
        public var need: Int64
        public var free: Int64?

        public init(need: Int64, free: Int64?) {
            self.need = need
            self.free = free
        }
    }

    /// Nil when the Mac has room for `bytes` plus the margin; otherwise what it needs and has (free nil: unknown, so
    /// refused all the same).
    public static func room(bytes: Int64, free: Int64?) -> Room? {
        guard bytes > 0 else { return nil }
        let need = bytes + margin
        guard let free else { return Room(need: need, free: nil) }
        return free >= need ? nil : Room(need: need, free: free)
    }

    /// The free space macOS counts for important use (space it can clear included) on the folder's disk, or the plain
    /// free space where that figure isn't given
    public static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                       .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Each plain name in the folder that is a file, and its size, from a stat: never a read
    public static func present(in folder: URL) -> [String: Int64] {
        (try? listing(in: folder)) ?? [:]
    }

    /// The backup's manifest: its local mirror, or, only when that is missing or unreadable, the folder's own
    public static func readMirror(_ mirror: URL, folder: URL) -> Manifest? {
        if let data = try? Data(contentsOf: mirror), let manifest = try? Manifest.read(data) { return manifest }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)) else { return nil }
        return try? Manifest.read(data)
    }

    /// The tests' ways in: `beforeSwap` runs on each copy before its read-back, `afterCopy` after each lands (a throw
    /// there stops the run, as a power cut would), `progress` before each copy (done, total).
    public struct Hooks: Sendable {
        public var beforeSwap: (@Sendable (Manifest.Entry, URL) -> Void)?
        public var afterCopy: (@Sendable (Manifest.Entry) throws -> Void)?
        public var progress: (@Sendable (Int, Int) -> Void)?
        /// Runs on the phones' copy's temporary file before its read-back
        public var beforeInventorySwap: (@Sendable (URL) -> Void)?
        public init() {}
    }

    public struct Outcome: Equatable, Sendable {
        public var copied: [String] = []
        public var failed: [String] = []
        public var removed: [String] = []
        /// Files that should have left the folder and couldn't (a `family: false` download among them, maybe)
        public var unremoved: [String] = []
        /// Copies whose source the app's library let go of during the run (a newer copy swapped in): copied next time,
        /// never a failure (review 2)
        public var waiting: [String] = []
        /// Whether the Read me first page was written (a failure there never stops the backup)
        public var readMeWritten = false
        /// Whether the phones' copy was written this time (a failure is in `failed`, by its name)
        public var inventoryCopied = false
        public var manifest = Manifest(writtenAt: "", files: [])
        public var current = 0
        public var wanted = 0
    }

    /// Carries out `plan`: copies from `source` (the app's library folder) into `folder`, the manifest to both the
    /// folder and `mirror`. Throws `Problem.noFolder` without writing anything when the folder isn't there; any other
    /// throw leaves the manifest true to the folder (see the type's notes).
    @discardableResult
    public static func run(_ plan: Plan, source: URL, folder: URL, mirror: URL, writtenAt: String, readMe: Bool = false,
                           signer: (@Sendable (Manifest) throws -> Data)? = nil,
                           hooks: Hooks = Hooks()) throws -> Outcome {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw Problem.noFolder
        }
        clearLeftovers(in: folder)
        if plan.interimNeeded {
            try save(Manifest(writtenAt: writtenAt, files: plan.kept, inventory: plan.inventoryKept,
                              format: FileFormat.current), folder: folder,
                     mirror: mirror, mirrorFirst: true, signer: signer)
        }
        var outcome = Outcome()
        for name in plan.removals {
            if unlink(folder.appendingPathComponent(name).path) == 0 || errno == ENOENT {
                outcome.removed.append(name)
            } else {
                outcome.unremoved.append(name)
            }
        }
        var landed = Set<String>()
        var movedAway = Set<String>()
        for (done, copy) in plan.copies.enumerated() {
            hooks.progress?(done, plan.copies.count)
            let name = copy.entry.name
            let temporary = folder.appendingPathComponent("\(temporaryPrefix)\(name)-\(UUID().uuidString)")
            let from = source.appendingPathComponent(copy.source)
            guard make(temporary, from: from) else {
                unlink(temporary.path)  // a plain copy cut off part-way
                if FileManager.default.fileExists(atPath: from.path) {
                    outcome.failed.append(name)
                } else {
                    outcome.waiting.append(name)
                }
                continue
            }
            hooks.beforeSwap?(copy.entry, temporary)
            guard (try? FileCheck.verify(temporary, size: copy.entry.size, sha256: copy.entry.sha256)) == .ok else {
                unlink(temporary.path)
                outcome.failed.append(name)
                continue
            }
            let target = folder.appendingPathComponent(name)
            if plan.keepOlder.contains(name) {  // the older copy kept first; if it can't be, nothing is replaced
                let older = folder.appendingPathComponent(olderFolder)
                try? FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
                if rename(target.path, older.appendingPathComponent(name).path) == 0 {
                    movedAway.insert(name)
                } else if errno != ENOENT {
                    unlink(temporary.path)
                    outcome.failed.append(name)
                    continue
                }
            }
            guard rename(temporary.path, target.path) == 0 else {
                unlink(temporary.path)
                outcome.failed.append(name)
                continue
            }
            landed.insert(name)
            outcome.copied.append(name)
            try hooks.afterCopy?(copy.entry)
        }
        let copying = Dictionary(plan.copies.map { ($0.entry.name, $0) }, uniquingKeysWith: { first, _ in first })
        let final = plan.final.compactMap { entry -> Manifest.Entry? in
            guard let copy = copying[entry.name] else { return entry }
            if landed.contains(entry.name) { return entry }
            return movedAway.contains(entry.name) ? nil : copy.fallback
        }
        var inventory = plan.inventoryFinal
        if let copy = plan.inventoryCopy {
            if writeInventory(copy, folder: folder, hooks: hooks) {
                outcome.inventoryCopied = true
            } else {  // the backup's older copy, still whole, stays named
                outcome.failed.append(copy.entry.name)
                inventory = plan.inventoryFallback
            }
        }
        outcome.manifest = Manifest(writtenAt: writtenAt, files: final, inventory: inventory,
                                    format: FileFormat.current)  // audit P2h
        if plan.isDue || plan.interimNeeded {
            try save(outcome.manifest, folder: folder, mirror: mirror, mirrorFirst: false, signer: signer)
        }
        if readMe {
            outcome.readMeWritten = (try? DurableFile.write(Data(Self.readMe.utf8),
                                                            to: folder.appendingPathComponent(readMeName))) != nil
        }
        outcome.current = final.filter { plan.delivered[$0.name] == $0.sha256 }.count
        outcome.wanted = plan.wanted
        return outcome
    }

    /// Whether the Mac's phones' copy `mac` must replace the backup's whole one `backup` (nil: none whole there)
    static func inventoryDue(_ mac: Manifest.Inventory, over backup: Manifest.Inventory?) -> Bool {
        guard let backup else { return true }
        guard backup.sha256 != mac.sha256 else { return false }
        if backup.content == nil || backup.content != mac.content { return true }
        guard let then = FolderOffer.date(backup.writtenAt), let now = FolderOffer.date(mac.writtenAt) else { return true }
        return now.timeIntervalSince(then) >= inventoryRefresh
    }

    /// The phones' copy written whole under a temporary name, read back, then renamed in; false when it didn't land
    static func writeInventory(_ inventory: InventorySource, folder: URL, hooks: Hooks) -> Bool {
        let temporary = folder.appendingPathComponent("\(temporaryPrefix)\(inventory.entry.name)-\(UUID().uuidString)")
        guard (try? DurableFile.write(inventory.data, to: temporary)) != nil else {
            unlink(temporary.path)
            return false
        }
        hooks.beforeInventorySwap?(temporary)
        guard (try? FileCheck.verify(temporary, size: inventory.entry.size, sha256: inventory.entry.sha256)) == .ok,
              rename(temporary.path, folder.appendingPathComponent(inventory.entry.name).path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    /// A clone of `source` at `target`, or a plain copy where the disk can't clone
    static func make(_ target: URL, from source: URL) -> Bool {
        if clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 { return true }
        guard errno == ENOTSUP || errno == EXDEV else { return false }
        unlink(target.path)
        return copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
    }

    /// The temporary copies and saves a stopped run left: our own ".backup-" copies, and DurableFile's ".<name>.tmp-"
    /// saves of the manifest, the Read me and the phones' copy. That last one is DurableFile writing to our
    /// ".backup-phone-inventory.json-…", so its own temporary starts "..backup-", which `hasPrefix(temporaryPrefix)`
    /// doesn't match: the `".\(temporaryPrefix)"` entry is what clears it (pinned, BackupTests)
    static func clearLeftovers(in folder: URL) {
        let saves = [".\(manifestName).tmp-", ".\(readMeName).tmp-", ".\(temporaryPrefix)"]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix(temporaryPrefix) || saves.contains(where: name.hasPrefix) {
            unlink(folder.appendingPathComponent(name).path)
        }
    }

    /// Each list written whole to both places, signed by `signer` when one is given (phase B: BackupSignature.sign)
    static func save(_ manifest: Manifest, folder: URL, mirror: URL, mirrorFirst: Bool,
                     signer: (@Sendable (Manifest) throws -> Data)?) throws {
        let data = try signer?(manifest) ?? manifest.encoded()
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mirrorFirst { try DurableFile.write(data, to: mirror) }
        try DurableFile.write(data, to: folder.appendingPathComponent(manifestName))
        if !mirrorFirst { try DurableFile.write(data, to: mirror) }
    }

    // MARK: iCloud's upload state

    public struct Upload: Equatable, Sendable {
        public var pending: Int
        public var failed: Int
        /// False for a folder iCloud doesn't hold (a check build's test folder)
        public var inICloud: Bool
        /// How many files were looked at (0 outside iCloud)
        public var total: Int

        public init(pending: Int, failed: Int, inICloud: Bool, total: Int = 0) {
            self.pending = pending
            self.failed = failed
            self.inICloud = inICloud
            self.total = total
        }
    }

    /// How many of `names` iCloud hasn't uploaded yet, or can't, from each file's resource values: never its contents
    public static func upload(of names: [String], in folder: URL) -> Upload {
        let inICloud = (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        var upload = Upload(pending: 0, failed: 0, inICloud: inICloud)
        guard inICloud else { return upload }
        upload.total = names.count
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey]
        for name in names {
            var url = folder.appendingPathComponent(name)
            url.removeAllCachedResourceValues()
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.ubiquitousItemUploadingError != nil {
                upload.failed += 1
            } else if values.ubiquitousItemIsUploaded != true {
                upload.pending += 1
            }
        }
        return upload
    }

    // MARK: Read me first

    /// The Read me first page's SHA-256, kept in the status record so the page is written again only when it changes
    public static var readMeDigest: String { Hex.string(SHA256.hash(data: Data(readMe.utf8))) }

    /// The folder's Read me first page, written whole by the app when it changes (owner's look, phase A's gate)
    public static let readMe = """
        PrepareMe Backup: read me first

        This folder is a copy of the PrepareMe library: the guides, the map files and the street map, and the \
        phones' copy of the inventory with the meeting places, as the Mac at home holds them for the phones. The Mac \
        keeps it up to date by itself. Don't change, add or remove files here.

        IF THE MAC IS LOST OR BROKEN
        On a phone or iPad, open PrepareMe, then Downloads \u{203A} Away from the Mac \u{203A} Add from \
        Files, and pick this folder (or the USB-C drive's copy). A phone that isn't paired also gets the meeting \
        places and the inventory, read only until it is paired with a Mac; a paired phone keeps its own. A child's \
        phone takes only files missing or newer than its own, and only from a folder its Mac signed. A phone that \
        was never paired with the Mac, or was paired long ago, asks first before it takes the folder. A phone with a Lightning port needs an adapter between Lightning and the drive's USB-C \
        plug, and some drives need that adapter plugged into power.

        COPY IT TO A USB-C DRIVE (on the Mac, before you need it)
        The household's USB backup drive gets this copy by itself: each time PrepareMe backs up to it, the \
        PrepareMe Backup folder at the drive's top (beside the locked backup image) is brought up to date. For \
        another drive:
        1. The drive must be formatted exFAT or APFS. A FAT32 drive refuses files over 4 GB, and some map files are \
        bigger. Disk Utility shows the format, and can erase a drive as exFAT.
        2. In Finder, open iCloud Drive and drag the PrepareMe Backup folder onto the drive. It is tens of gigabytes, \
        so it takes a while. To bring the drive up to date later, drag it again and choose Replace.
        3. In a hurry: copy just prepareme-daily.zim, phone-inventory.json and manifest.json into the drive's \
        PrepareMe Backup folder (choose Replace). They hold today's guides, the inventory and the meeting places, and \
        change most days. A map file that changed since the drive was last filled can't be added from the drive until \
        it is filled again.

        ON A PHONE WITHOUT PREPAREME
        Install Kiwix from the App Store, then in Files open this folder (or the drive) and open each .zim file in \
        Kiwix. prepareme-daily.zim is the guides and today's page; the files named prepareme-maps are the maps. \
        Don't do this on a phone that has PrepareMe: Kiwix would hold a second copy of the library and can show old \
        pages.

        WHAT ISN'T HERE
        - The travel street maps for other states are kept apart in PrepareMe Travel Maps, and are not in this \
        folder or on a drive copied from it: the Mac makes them again when asked. A phone takes one from that folder \
        under Downloads, Add a travel map, with internet.
        - The folder Older copy holds the daily file from before its last change, so a household page deleted by \
        mistake can still be read. Open it only on a phone without PrepareMe, and never beside the current one.

        """
}

/// The backup's status record (Application Support › PrepareMe › backup › status.json), which the failure notice
/// reads (scheduler/notice.py, BACKUP_STATUS; owner, 2026-10-17: "Notice and sidebar"). Fixed codes, counts and dates
/// only. Its shape is pinned by Fixtures/backup-status.json, read by both the Swift and the Python tests.
public struct BackupStatus: Codable, Equatable, Sendable {
    /// When the app last looked
    public var checkedAt: String?
    /// When the backup was last current
    public var currentAt: String?
    /// The days (yyyy-MM-dd, the Mac's own) the app saw the backup behind since it was last current: days the Mac was
    /// asleep or off aren't counted (done-item 7's rule, as the plan words it)
    public var behindDays: [String] = []
    /// One of the codes below, or nil
    public var problem: String?
    public var current: Int?
    public var wanted: Int?
    public var failed: Int?
    public var need: Int64?
    public var free: Int64?
    /// With `uploadFailed`: how many files iCloud's upload state counted (`failed` is how many of them it can't take)
    public var uploads: Int?
    /// The SHA-256 of the Read me first page last written, so it is written again only when it changes
    public var readMe: String?
    /// Since when iCloud has had files of the backup still to upload, without a look that found none (offline fixes,
    /// phase 2); nil when none waits
    public var uploadingSince: String?

    public static let noFolder = "no-folder"
    public static let noRoom = "no-room"
    public static let copyFailed = "copy-failed"
    public static let notSaved = "not-saved"
    public static let notRemoved = "not-removed"
    public static let noAccess = "no-access"
    /// macOS's question about iCloud Drive is still waiting for an answer
    public static let asking = "asking"
    public static let unreadable = "unreadable"
    /// iCloud reports files of the backup it can't upload (full, or another upload error): copied on this Mac, but not
    /// backed up (phase K's drills, finding 1)
    public static let uploadFailed = "upload-failed"
    /// How often the record is written while nothing changes, so the notice knows the app is looking
    public static let heartbeat: TimeInterval = 3600

    enum CodingKeys: String, CodingKey {
        case problem, current, wanted, failed, need, free, uploads
        case checkedAt = "checked_at", currentAt = "current_at", behindDays = "behind_days", readMe = "read_me"
        case uploadingSince = "uploading_since"
    }

    public init() {}

    /// The record after a look at `date`: `behind` adds that day once; caught up clears them, and `currentAt` takes the
    /// look's time when a backup has just run (`ran`) or none was dated yet, so it says when the last one finished.
    public func updated(at date: Date, behind: Bool, ran: Bool = false, calendar: Calendar = .current) -> BackupStatus {
        var next = self
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = calendar.timeZone
        next.checkedAt = stamp.string(from: date)
        if behind {
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            let text = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
            if !next.behindDays.contains(text) { next.behindDays.append(text) }
        } else {
            next.behindDays = []
            if ran || next.currentAt == nil { next.currentAt = next.checkedAt }
        }
        return next
    }

    /// iCloud's upload state taken into the record (phase K's drills, finding 1): files iCloud reports it can't upload
    /// make a record with no other problem `uploadFailed`, with their count, and not current, so it gains behind days
    /// like any other failure and the notice speaks after `BackupWords.behindDays` of them. Files still uploading do
    /// only once iCloud has had some to upload at every look for `BackupWords.uploadStuckDays` (offline fixes, phase 2:
    /// iCloud stuck), never a folder iCloud doesn't hold. A fresh state replaces a standing `uploadFailed`; no state read
    /// this time (nil) leaves it, and `uploadingSince`, standing. Returns whether the record is behind for its uploads.
    public mutating func take(_ upload: Backup.Upload?, now: Date = Date()) -> Bool {
        guard let upload else { return problem == Self.uploadFailed || uploadStuck(now: now) }
        if !upload.inICloud || upload.pending == 0 {
            uploadingSince = nil
        } else if uploadingSince == nil {
            uploadingSince = ISO8601DateFormatter().string(from: now)
        }
        if problem == Self.uploadFailed { (problem, failed, uploads) = (nil, nil, nil) }
        guard problem == nil, upload.inICloud, upload.failed > 0 else { return uploadStuck(now: now) }
        (problem, failed, uploads) = (Self.uploadFailed, upload.failed, max(upload.total, upload.failed))
        return true
    }

    /// Whether files have waited to upload for `BackupWords.uploadStuckDays` or more
    public func uploadStuck(now: Date) -> Bool {
        guard let since = uploadingSince.flatMap(ISO8601DateFormatter().date(from:)) else { return false }
        return now.timeIntervalSince(since) >= TimeInterval(BackupWords.uploadStuckDays) * 86400
    }

    /// Whether this record is worth saving over `old`: on any change but the look's time, or once `heartbeat` has passed
    public func worthWriting(over old: BackupStatus?) -> Bool {
        guard let old else { return true }
        var same = self
        same.checkedAt = old.checkedAt
        if same != old { return true }
        let stamp = ISO8601DateFormatter()
        guard let now = checkedAt.flatMap(stamp.date(from:)), let then = old.checkedAt.flatMap(stamp.date(from:)) else {
            return checkedAt != old.checkedAt
        }
        return now.timeIntervalSince(then) >= Self.heartbeat
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func read(_ data: Data?) -> BackupStatus? {
        data.flatMap { try? JSONDecoder().decode(BackupStatus.self, from: $0) }
    }
}

/// The backup's lines in Settings' Backups tab and the sidebar's attention line (fixed words)
public enum BackupWords {
    /// Library status's backup line, or nil before the app has looked
    public static func line(_ status: BackupStatus?, upload: Backup.Upload?, now: Date) -> String? {
        guard let status, status.checkedAt != nil else { return nil }
        if let problem = problemLine(status) { return problem }
        guard let at = status.currentAt.flatMap(ISO8601DateFormatter().date(from:)) else {
            return "Not backed up yet; it starts after the next library check."
        }
        let files = "\(status.current ?? 0) of \(status.wanted ?? 0) files"
        guard let upload, upload.inICloud else {
            return upload == nil ? "Backed up to iCloud \(ago(at, now: now)): \(files)"
                : "Backed up \(ago(at, now: now)): \(files) (a test folder, not iCloud)"
        }
        var tail: [String] = []
        if upload.pending > 0, status.uploadStuck(now: now),
           let since = status.uploadingSince.flatMap(ISO8601DateFormatter().date(from:)) {
            tail.append("\(upload.pending) still uploading to iCloud since "
                + "\(since.formatted(date: .abbreviated, time: .omitted)): iCloud may be stuck; look at the PrepareMe "
                + "Backup folder in Finder")
        } else if upload.pending > 0 {
            tail.append("\(upload.pending) still uploading to iCloud")
        }
        if upload.failed > 0 { tail.append("\(upload.failed) can't upload") }
        let state = tail.isEmpty ? "all uploaded" : tail.joined(separator: ", ")
        return "Backed up to iCloud \(ago(at, now: now)): \(files), \(state)"
    }

    public static func problemLine(_ status: BackupStatus) -> String? {
        switch status.problem {
        case BackupStatus.noFolder:
            return "Not backed up: there's no PrepareMe Backup folder in iCloud Drive. Make one in Finder (iCloud Drive, "
                + "then File › New Folder), then press Back up to iCloud now."
        case BackupStatus.noRoom:
            guard let free = status.free else {
                return "Not backed up: this Mac needs \(StorageWords.size(status.need ?? 0)) free for it, and its free "
                    + "space couldn't be read."
            }
            let sizes = StorageWords.room(need: status.need ?? 0, free: free)
            return "Not backed up: this Mac needs \(sizes.need) free for it and has \(sizes.free)."
        case BackupStatus.copyFailed:
            let n = status.failed ?? 0
            return n == 1 ? "Not backed up: 1 file couldn't be copied; it is tried again at the next check."
                : "Not backed up: \(n) files couldn't be copied; they are tried again at the next check."
        case BackupStatus.noAccess:
            return "Not backed up: macOS hasn't let PrepareMe into iCloud Drive. Allow it in System Settings › Privacy & "
                + "Security › Files & Folders, under PrepareMe, then press Back up to iCloud now."
        case BackupStatus.asking:
            return "Not backed up yet: macOS is asking whether PrepareMe may use iCloud Drive. Choose Allow; the "
                + "question may be behind other windows."
        case BackupStatus.unreadable:
            return "Not backed up: the PrepareMe Backup folder couldn't be read; it is tried again at the next check."
        case BackupStatus.notRemoved:
            let n = status.failed ?? 0
            return "Not backed up: \(n) \(n == 1 ? "file" : "files") the phones no longer get couldn't be taken out of "
                + "the backup folder; tried again at the next check."
        case BackupStatus.notSaved:
            return "Not backed up: its list couldn't be saved in the backup folder; it is tried again at the next check."
        case BackupStatus.uploadFailed:
            let n = status.failed ?? 0, whole = (status.current ?? 0) >= (status.wanted ?? 0)  // review: never claimed
            return "Not backed up to iCloud: \(n) of \(max(status.uploads ?? 0, n)) files can't upload (iCloud may be "
                + "full)." + (whole ? " This Mac's copy is up to date." : "")
        default:
            return nil
        }
    }

    public static func copying(done: Int, total: Int) -> String {
        "Backing up to iCloud: \(done + 1) of \(total) changed files"
    }

    public static func uploadProblem(_ upload: Backup.Upload?) -> String? {
        guard let upload, upload.inICloud, upload.failed > 0 else { return nil }
        return "\(upload.failed) \(upload.failed == 1 ? "file" : "files") can't upload to iCloud: System Settings › "
            + "your name › iCloud says why."
    }

    /// The sidebar's attention line: only what needs the owner (no folder, no room, iCloud refusing a file), or a
    /// backup behind on as many awake days as the notice waits for; nil otherwise.
    public static func attention(_ status: BackupStatus?, upload: Backup.Upload?) -> String? {
        if let status {
            if [BackupStatus.noFolder, BackupStatus.noAccess, BackupStatus.asking, BackupStatus.noRoom,
                BackupStatus.notRemoved]
                .contains(status.problem) {
                return problemLine(status)
            }
            if status.behindDays.count >= behindDays {
                return problemLine(status) ?? "The iCloud backup is behind; Back up to iCloud now tries again."
            }
        }
        return uploadProblem(upload)
    }

    /// Library status's line while the Mac's backup-signing key can't be read (phase B)
    public static let unsigned = "The backup's list isn't signed: its key on this Mac couldn't be read, so a phone asks "
        + "an adult before adding files from it."

    /// Awake days behind before the notice and the sidebar speak up (scheduler/notice.py's BACKUP_DAYS)
    public static let behindDays = 3
    /// Days files may wait to upload before the backup counts as behind (offline fixes, phase 2)
    public static let uploadStuckDays = 2

    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        func count(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return count(seconds / 60, "minute")
        case ..<86400: return count(seconds / 3600, "hour")
        default: return count(seconds / 86400, "day")
        }
    }}
