import Combine
import Foundation

/// What the PrepareMe app needs from its reader (Kiwix): registering a copy of a library by its path, which opens it in
/// place of the copy before it, and what to do once a swap is done. The app passes Kiwix's; the tests pass a fake.
@MainActor
public protocol LibraryReader: AnyObject {
    /// Points the reader at the copy at `file`; false when it couldn't open it (nothing changed then).
    func register(_ file: URL) async -> Bool
    /// The path the reader holds for library `id`, if any.
    func registeredPath(of id: String) async -> String?
    /// Whether the reader has a record of library `id` at all.
    func knows(_ id: String) -> Bool
    /// After a swap: front pages reloaded, a first copy's settings (left out of search, the daily's front page opened).
    func swapped(_ entry: Manifest.Entry, wasNew: Bool) async
    /// Closes library `id` and forgets it (its tabs and bookmarks too), before its copy is deleted (plan phase 8).
    func remove(_ id: String) async
}

/// The phone's copies of the Mac's library on disk, and its record of them (build plan phase 4). Everything here runs
/// one step at a time (`serially`): a check and a swap, the tidy-up at launch and coming forward, and adopting files
/// never overlap, so the tidy-up can't delete a copy a swap is putting in place (phase 4 review, C2).
///
/// - A downloaded copy waits in `incoming` as `<SHA-256>.zim`, named in the record's `checking`, until it is checked:
///   size and SHA-256, then the reader's own look (`zimProblem`: the library's ID and the ZIM file's checksum). A copy
///   that can't be read (gone, an I/O error) is dropped and fetched again; only a copy that is read and wrong counts as
///   a refusal (review, M1).
/// - A copy that passes is moved to `library` under a name of its own (LibraryPlan.fileName), registered with the
///   reader, recorded, and only once the record is saved is the old copy deleted. A record that can't be saved puts the
///   old copy back and keeps it (review, C1). A copy that passes its checks but can't be opened or recorded counts as a
///   refusal, so it isn't downloaded again forever (review, I5).
/// - The tidy-up deletes a file in `library` only when the record names another; a record that couldn't be read is put
///   aside and nothing is deleted until the Mac's manifest has been read and the files it names were adopted back by
///   their SHA-256 (review, I1).
@MainActor
public final class LibraryStore: ObservableObject {
    nonisolated public let root: URL
    nonisolated public let libraryFolder: URL
    nonisolated public let incomingFolder: URL
    nonisolated public let recordFile: URL
    @Published public private(set) var record: LibraryRecord
    @Published public private(set) var notes: [String: String] = [:]  // a manifest name (or "*") → in plain words
    @Published public private(set) var lastRefusal: String?
    /// The record on disk couldn't be read at launch: nothing is deleted until a manifest has been read.
    public private(set) var recordWasUnreadable = false
    /// The record is there but couldn't be read at all: nothing is saved over it, so nothing is swapped in or deleted,
    /// until a reconcile reads it (whole-branch review, 3; the phone's first start after a restart, 2026-10-25).
    public private(set) var recordLocked = false
    /// Every file of the manifest is wanted, optional maps included (the Mac app, plan phase 6; LibraryPlan.everyKind).
    public var everyKind = false
    /// Whether a refused copy came from a source caught changing (the Mac's folder mid-update, FolderSync): such a copy
    /// is dropped and made again at the next check, never counted as a refusal. Nil on the phone.
    public var midUpdate: ((Manifest.Entry) -> Bool)?
    /// The device and the source in the notes' words: the phone's by default, the Mac app's from FolderSync.
    public var wording = Wording.phone
    /// Where the held library shows in Files for the App Store Kiwix (FilesShelf; plan phase 10, after D7): the
    /// phone's Documents folder; nil on the Mac and in tests that don't ask for it.
    public var shelf: URL?

    public struct Wording: Sendable {
        public var here: String  // "this phone"
        public var source: String  // "The Mac's copy"
        public var received: String  // "The downloaded copy"
        public var again: String  // "fetched again"
        public var newCopy: String  // "once the Mac has a new copy"

        public static let phone = device("phone")
        /// The phone app's words on this device: `word` is "iPad" on an iPad (the app's ThisDevice).
        public static func device(_ word: String) -> Wording {
            Wording(here: "this \(word)", source: "The Mac's copy", received: "The downloaded copy",
                    again: "fetched again", newCopy: "once the Mac has a new copy")
        }
        public static let mac = Wording(here: "this Mac", source: "The library folder's copy",
                                        received: "The copy from the library folder", again: "copied again",
                                        newCopy: "once the packer delivers a new copy")
    }

    private let reader: LibraryReader
    private let zimProblem: @Sendable (URL, Manifest.Entry) -> String?
    private let write: (Data, URL) throws -> Void
    private var tail: Task<Void, Never>?

    public init(root: URL, reader: LibraryReader, zimProblem: @escaping @Sendable (URL, Manifest.Entry) -> String?,
                write: @escaping (Data, URL) throws -> Void = { try DurableFile.write($0, to: $1) },
                lastRefusal: String? = nil) {
        self.root = root
        libraryFolder = root.appendingPathComponent("library")
        incomingFolder = root.appendingPathComponent("incoming")
        recordFile = root.appendingPathComponent("library-state.json")
        self.reader = reader
        self.zimProblem = zimProblem
        self.write = write
        self.lastRefusal = lastRefusal
        record = LibraryRecord()
        readRecord()
    }

    private func readRecord() {
        do {
            let data = try Data(contentsOf: recordFile)
            if let found = try? JSONDecoder().decode(LibraryRecord.self, from: data) {
                record = found
                recordWasUnreadable = false
            } else {  // read but not understood: set aside, and nothing deleted until a manifest adopts the files
                recordWasUnreadable = true
                let stamp = Int(Date().timeIntervalSince1970)
                let aside = root.appendingPathComponent("library-state.unreadable-\(stamp).json")
                try? FileManager.default.moveItem(at: recordFile, to: aside)
            }
        } catch CocoaError.fileReadNoSuchFile {
            // no record yet: a first launch
        } catch {  // there but not readable now (locked before the first unlock, an I/O error): never written over
            recordWasUnreadable = true
            recordLocked = true
            return
        }
        recordLocked = false
    }

    // MARK: One step at a time

    /// Runs `work` after every step started before it has finished.
    public func serially(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }

    // MARK: The record

    func save() throws {
        if recordLocked { throw CocoaError(.fileReadNoPermission) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(record), recordFile)
        Self.excludeFromBackup(recordFile)  // it names library files a backup leaves out (audit D1)
    }

    private func saveOrNote() {
        do {
            try save()
            notes["*"] = nil
        } catch {
            notes["*"] = "The library record on \(wording.here) couldn't be saved (code \((error as NSError).code))."
        }
    }

    /// The Mac's manifest, just read.
    public func read(_ manifest: Manifest, at date: Date) {
        record.manifest = manifest
        if let key = manifest.backupKey { record.backupKey = key }  // phase B: never forgotten for a list without one
        record.checkedAt = ISO8601DateFormatter().string(from: date)
        record.declined = record.declined.filter { name in manifest.files.contains { $0.name == name } }
        LibraryPlan.forgetOldRefusals(manifest, &record)
        notes = notes.filter { key, _ in key == "*" || manifest.files.contains { $0.name == key } }
        saveOrNote()
    }

    public func note(_ name: String, _ words: String?) {
        notes[name] = words
    }

    /// "Get this file".
    public func request(_ entry: Manifest.Entry) {
        record.requested.insert(entry.name)
        record.declined.remove(entry.name)
        saveOrNote()
    }

    /// A file wanted again after a Remove (the Mac app: a download kept again), so it is fetched as before.
    public func undecline(_ name: String) {
        guard record.declined.remove(name) != nil else { return }
        saveOrNote()
    }

    /// "Remove from this phone" (plan phase 8): an optional map, a family download, or a file the Mac no longer sends.
    /// The reader lets go of it first, then its copy is deleted and it is no longer asked for, so it isn't fetched
    /// again. A library file or core map is never removed here: it would only come back. Whether it was removed.
    @discardableResult
    public func remove(_ name: String) async -> Bool {
        await letGo(name, decline: true)
    }

    /// The Mac's `drop` (family downloads plan, phase 3), at each answered check on every device: each held file the Mac
    /// set to Never for this device, or un-ticked For the family, is let go of, not marked removed, so the Mac can offer
    /// it again; a name in it this device asked for and doesn't hold is no longer asked for. A held file the list merely
    /// no longer names stays (`LibraryPlan.dropped`): a replacement Mac or a failed delivery never empties a phone. The
    /// names let go of.
    @discardableResult
    public func letGoDropped() async -> [String] {
        let drop = Set(record.manifest?.drop ?? [])
        let notHeld = drop.filter { record.held[$0] == nil }
        if !record.requested.isDisjoint(with: notHeld) {
            record.requested.subtract(notHeld)
            saveOrNote()
        }
        var gone: [String] = []
        for name in drop.filter({ record.held[$0] != nil }).sorted() {
            if await letGo(name, decline: false) { gone.append(name) }
        }
        return gone
    }

    private func letGo(_ name: String, decline: Bool) async -> Bool {
        var done = false
        await serially { [self] in
            guard LibraryPlan.removable(name, record), let held = record.held[name] else { return }
            if !held.entry.isStreetMap { await reader.remove(held.entry.id) }  // the reader never opened the map
            try? FileManager.default.removeItem(at: libraryFolder.appendingPathComponent(held.file))
            for waiting in record.checking where waiting.name == name {  // a newer copy waiting for its check: gone too
                try? FileManager.default.removeItem(at: incoming(waiting))
            }
            record.checking.removeAll { $0.name == name }
            record.held[name] = nil
            record.requested.remove(name)
            if decline { record.declined.insert(name) }
            notes[name] = nil
            saveOrNote()
            syncShelf()
            done = true
        }
        return done
    }

    /// "Try again" on a copy refused twice.
    public func forgetRefusal(_ entry: Manifest.Entry) {
        record.refusals[entry.sha256] = nil
        notes[entry.name] = nil
        saveOrNote()
    }

    // MARK: Folders

    /// Only the library and its downloads are kept out of the device's backups: the folder itself holds files that live
    /// only on this device (the waiting inventory changes, pins, game saves), so its mark from earlier builds is taken
    /// off (audit D1). Files kept out on purpose carry their own marks.
    public func prepareFolders() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.excludeFromBackup(root, false)
        for folder in [libraryFolder, incomingFolder] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.excludeFromBackup(folder)
        }
    }

    /// Marks `url` out of backups (or, with `false`, back in). Always written: a file in a folder marked out reads as
    /// marked without its own mark, which a link elsewhere (FilesShelf) wouldn't carry (review, 2026-10-15).
    public nonisolated static func excludeFromBackup(_ url: URL, _ excluded: Bool = true) {
        var marked = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? marked.setResourceValues(values)
    }

    public nonisolated func incoming(_ entry: Manifest.Entry) -> URL {
        incomingFolder.appendingPathComponent("\(entry.sha256).\(entry.fileExtension)")
    }

    public nonisolated func resumeFile(_ entry: Manifest.Entry) -> URL {
        incomingFolder.appendingPathComponent("\(entry.sha256).resume")
    }

    // MARK: A downloaded copy

    /// Where a copy handed over came from: the Mac (a download, or the Mac app's library folder), or a folder Add from
    /// Files picked (phase K's drills, finding 6), whose refusal is worded as the folder's and never counted against
    /// the Mac's copy
    public enum Source: Sendable { case mac, folder }

    /// The copies waiting for their check that came from a folder, by SHA-256 (until this run's check; one adopted at a
    /// launch is the Mac's)
    private var fromFolder = Set<String>()

    /// The downloader's hand-over: the finished copy is at `incoming(entry)`. The record names it before this returns.
    public func handOver(_ entry: Manifest.Entry, from source: Source = .mac) {
        guard !recordLocked else { return }  // the download stays in incoming and is adopted at the next launch
        if source == .folder { fromFolder.insert(entry.sha256) } else { fromFolder.remove(entry.sha256) }
        guard !record.checking.contains(where: { $0.sha256 == entry.sha256 }) else { return }
        record.checking.append(entry)
        saveOrNote()
    }

    /// Every waiting copy checked and, when it passes, swapped in.
    public func checkWaiting() async {
        guard !recordLocked else { return }
        await serially { [self] in
            for entry in record.checking {
                await checkAndInstall(entry)
            }
        }
    }

    enum Verdict: Sendable {
        case passes, unreadable(String), refused(String)
    }

    nonisolated static func verdict(_ file: URL, _ entry: Manifest.Entry,
                                    _ zimProblem: @Sendable (URL, Manifest.Entry) -> String?) -> Verdict {
        guard FileManager.default.fileExists(atPath: file.path) else { return .unreadable("it isn't there") }
        do {
            switch try FileCheck.verify(file, size: entry.size, sha256: entry.sha256) {
            case .ok: break
            case let .wrongSize(actual): return .refused("\(actual) bytes, not the \(entry.size) the Mac's list says")
            case .wrongHash: return .refused("the right size but not the right bytes")
            }
        } catch {
            return .unreadable("code \((error as NSError).code)")
        }
        let problem = entry.isStreetMap ? StreetMap.problem(file) : zimProblem(file, entry)  // plan phase 9: no ZIM checks
        return problem.map { .refused($0) } ?? .passes
    }

    /// Called one step at a time only (`serially`).
    private func checkAndInstall(_ entry: Manifest.Entry) async {
        let file = incoming(entry)
        // a copy that finished after its file was removed (plan phase 8, review 2), or for a name the Mac's list now
        // drops or, for the Mac's own copy, no longer names (family downloads plan, phase 3), is dropped, never
        // installed; a folder's copy of a file the Mac stopped sending is an adult's choice (FolderOffer)
        let unlisted = !fromFolder.contains(entry.sha256)
            && record.manifest.map { !$0.files.contains { $0.name == entry.name } } == true
        guard record.manifest?.drop?.contains(entry.name) != true, !unlisted,
              record.held[entry.name] != nil || LibraryPlan.wanted(entry, record, everyKind: everyKind) else {
            record.checking.removeAll { $0.sha256 == entry.sha256 }
            record.requested.remove(entry.name)
            fromFolder.remove(entry.sha256)
            try? FileManager.default.removeItem(at: file)
            saveOrNote()
            return
        }
        notes[entry.name] = "Checking the new copy…"
        let problem = zimProblem
        let verdict = await Task.detached(priority: .utility) { Self.verdict(file, entry, problem) }.value
        record.checking.removeAll { $0.sha256 == entry.sha256 }
        let source: Source = fromFolder.remove(entry.sha256) != nil ? .folder : .mac
        switch verdict {
        case let .unreadable(why):
            try? FileManager.default.removeItem(at: file)
            saveOrNote()
            notes[entry.name] = "\(wording.received) couldn't be read (\(why)); it is \(wording.again)."
        case .refused where midUpdate?(entry) == true:
            try? FileManager.default.removeItem(at: file)
            saveOrNote()
            notes[entry.name] = FolderSync.beingUpdated
        case let .refused(why):
            try? FileManager.default.removeItem(at: file)
            refuse(entry, why, from: source)
        case .passes:
            do {
                try await install(entry, from: file)
                notes[entry.name] = nil
            } catch {
                try? FileManager.default.removeItem(at: file)
                refuse(entry, "it passed its checks but couldn't be put in place", from: source)
            }
        }
    }

    /// A copy its checks refused, the held one kept: one of the Mac's counts toward `LibraryPlan.refuseAfter` and is
    /// tried once more; a folder's is said as the folder's, never counted and never retried (phase K's drills, 6)
    private func refuse(_ entry: Manifest.Entry, _ why: String, from source: Source) {
        lastRefusal = HomeMacWords.refusal(entry, why: why, at: Date())  // its plain name (Task 9.3, F40)
        guard source == .mac else {
            saveOrNote()  // the copy no longer waits for its check
            notes[entry.name] = "The folder's copy was refused (\(why)); keeping the copy \(wording.here) has."
            return
        }
        let forGood = LibraryPlan.refuse(entry, &record)
        saveOrNote()
        notes[entry.name] = forGood
            ? "\(wording.source) was refused twice (\(why)); keeping the copy \(wording.here) has. Try again "
              + "\(wording.newCopy)."
            : "\(wording.source) was refused (\(why)); keeping the copy \(wording.here) has and trying once more."
    }

    public enum InstallProblem: Error {
        case notOpened, notSaved
    }

    /// The checked copy put in place: moved to its own name, kept out of backups, registered with the reader (which
    /// opens it in place of the old copy), recorded, and only then the old copy deleted.
    private func install(_ entry: Manifest.Entry, from file: URL) async throws {
        let name = LibraryPlan.fileName(entry)
        let target = libraryFolder.appendingPathComponent(name)
        if record.held[entry.name]?.file == name {  // this very copy is already in place: never replace an open file
            try? FileManager.default.removeItem(at: file)
            return
        }
        prepareFolders()
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: file, to: target)
        Self.excludeFromBackup(target)
        let old = record.held[entry.name]
        let oldURL = old.map { libraryFolder.appendingPathComponent($0.file) }
        if entry.isStreetMap {  // plan phase 9: the reader never opens it; the map view reads the held copy
            record.held[entry.name] = HeldFile(entry: entry, file: name)
            record.refusals[entry.sha256] = nil
            do {
                try save()
            } catch {
                record.held[entry.name] = old
                try? FileManager.default.removeItem(at: target)
                throw InstallProblem.notSaved
            }
            if let oldURL, old?.file != name { try? FileManager.default.removeItem(at: oldURL) }
            return
        }
        let wasNew = !reader.knows(entry.id)
        guard await reader.register(target) else {
            try? FileManager.default.removeItem(at: target)
            if let oldURL { _ = await reader.register(oldURL) }
            throw InstallProblem.notOpened
        }
        record.held[entry.name] = HeldFile(entry: entry, file: name)
        record.refusals[entry.sha256] = nil
        do {
            try save()
        } catch {
            record.held[entry.name] = old  // the record on disk still names the old copy: the reader goes back to it
            if let oldURL { _ = await reader.register(oldURL) }
            try? FileManager.default.removeItem(at: target)
            throw InstallProblem.notSaved
        }
        await reader.swapped(entry, wasNew: wasNew)
        if let oldURL, old?.file != name { try? FileManager.default.removeItem(at: oldURL) }
        syncShelf()
    }

    /// Files shows what the record holds now (FilesShelf): links, renames and removals only. Never while the record
    /// couldn't be read: an empty record would take the whole library out of Files, for the App Store Kiwix too, just
    /// when the Mac may be out of reach (review, 2026-10-15); the held copies are kept then too (tidy). Each held copy
    /// is marked out of backups again first: its link carries that mark, and the Files folder itself is backed up.
    private func syncShelf() {
        guard let shelf, !recordLocked, !recordWasUnreadable else { return }
        for held in record.held.values { Self.excludeFromBackup(libraryFolder.appendingPathComponent(held.file)) }
        FilesShelf.sync(record.held, library: libraryFolder, folder: shelf)
    }

    // MARK: Launch and coming forward: the record and the folders agree

    /// One step at a time: copies the manifest names that sit in `library` unrecorded are adopted by their SHA-256;
    /// recorded copies are registered with the reader (one it can't open is dropped and fetched again); files in
    /// `library` the record doesn't name are deleted (not while a record that couldn't be read waits for a manifest);
    /// finished downloads the manifest still offers are adopted for checking, other leftovers deleted; then every
    /// waiting copy is checked.
    public func reconcile() async {
        // a launch before the first unlock after a restart, which runs on once the phone is unlocked (2026-10-25)
        if recordLocked { readRecord() }
        guard !recordLocked else { return }
        await serially { [self] in
            await tidy()
            for entry in record.checking {
                await checkAndInstall(entry)
            }
        }
    }

    private func tidy() async {
        prepareFolders()
        let manifest = record.manifest
        let fm = FileManager.default
        if let manifest { await adopt(manifest) }
        for (name, held) in record.held {
            let url = libraryFolder.appendingPathComponent(held.file)
            guard fm.fileExists(atPath: url.path) else {
                record.held[name] = nil
                continue
            }
            if held.entry.isStreetMap { continue }  // never the reader's (plan phase 9)
            let registered = await reader.registeredPath(of: held.entry.id)
            if registered.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) != url.standardizedFileURL.path
                || !reader.knows(held.entry.id) {
                if !(await reader.register(url)) {  // a held copy the reader can't open: fetched again (review, M5)
                    record.held[name] = nil
                    try? fm.removeItem(at: url)
                }
            }
        }
        saveOrNote()
        if !recordLocked, !recordWasUnreadable || manifest != nil {
            let keep = Set(record.held.values.map(\.file))
            for url in (try? fm.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: nil)) ?? []
            where !keep.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
            recordWasUnreadable = false
        }
        syncShelf()
        let offered = manifest.map { LibraryPlan.toFetch($0, record, everyKind: everyKind) } ?? []
        for url in (try? fm.contentsOfDirectory(at: incomingFolder, includingPropertiesForKeys: nil)) ?? [] {
            let sha = url.deletingPathExtension().lastPathComponent
            if url.pathExtension == "zim" || url.pathExtension == "pmtiles" {
                if record.checking.contains(where: { $0.sha256 == sha }) { continue }
                if let entry = offered.first(where: { $0.sha256 == sha }) {
                    record.checking.append(entry)  // a download that finished before its hand-over was saved
                    saveOrNote()
                } else {
                    try? fm.removeItem(at: url)
                }
            } else if url.pathExtension == "resume", manifest != nil, !offered.contains(where: { $0.sha256 == sha }) {
                try? fm.removeItem(at: url)  // a cut-off download of a copy no longer wanted (review, M3)
                try? fm.removeItem(at: url.appendingPathExtension("host"))
            } else if url.pathExtension == "host", !fm.fileExists(atPath: url.deletingPathExtension().path) {
                try? fm.removeItem(at: url)  // the address of resume data that is gone
            }
        }
    }

    /// Copies in `library` under a manifest entry's own name that the record doesn't hold (its record was lost), taken
    /// back when their SHA-256 is the entry's.
    private func adopt(_ manifest: Manifest) async {
        for entry in manifest.files where LibraryPlan.wanted(entry, record, everyKind: everyKind) && !LibraryPlan.isCurrent(entry, record) {
            let url = libraryFolder.appendingPathComponent(LibraryPlan.fileName(entry))
            guard FileManager.default.fileExists(atPath: url.path),
                  !LibraryPlan.idTaken(entry, manifest, record) else { continue }
            let same = await Task.detached(priority: .utility) {
                (try? FileCheck.verify(url, size: entry.size, sha256: entry.sha256)) == .ok
            }.value
            guard same else { continue }
            if !entry.isStreetMap, !(await reader.register(url)) { continue }  // the map is never the reader's
            record.held[entry.name] = HeldFile(entry: entry, file: url.lastPathComponent)
        }
    }
}
