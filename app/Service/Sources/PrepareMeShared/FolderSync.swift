import Foundation

/// The Mac app's library (plan phase 6): the packer's local folder (Application Support › PrepareMe › delivery), read
/// through its `manifest.json`, the same list the phones get. The packer replaces a file there at its own path, which
/// Kiwix can't follow while it reads the file (FINDINGS F-064), so the app never opens a file in the folder: each file
/// the list names is cloned (an APFS clone, no extra disk until the packer replaces the file) into the store's `incoming`
/// and handed to LibraryStore, which checks it as it checks a phone's download (size, SHA-256, the reader's own look)
/// and keeps it under a name of its own. Every kind is taken, optional maps included (`LibraryStore.everyKind`).
///
/// - One file at a time: cloned, checked and swapped in before the next, so a large map never holds up the daily page
///   longer than its own check (library files go first, LibraryPlan.toFetch).
/// - The packer swaps a file in, then rewrites the list. A copy that doesn't match its entry while the file is newer than
///   the list (within `updateWindow`), or once the list no longer offers that entry, was made mid-update: dropped and
///   made again at the next check, never a refusal (pre-mortem 2; whole-branch review 1). A file that disagrees with a list written after it, or long before, is refused as on a phone.
/// - A list that can't be read keeps every copy the app holds and says so (`problem`).
@MainActor
public final class FolderSync: ObservableObject {
    public nonisolated static let listName = "manifest.json"
    /// How long after a file changes the folder counts as being updated, if the list is older than the file
    public nonisolated static let updateWindow: TimeInterval = 600
    public nonisolated static let listUnreadable = "The library folder's list can't be read; the copies this Mac has stay open."
    public nonisolated static let notInFolder = "Listed, but not in the library folder; waiting for it."
    public nonisolated static let beingUpdated = "The library folder was being updated while this copy was made; it is copied again."

    public let store: LibraryStore
    public let folder: URL
    @Published public private(set) var problem: String?
    /// While a check copies: how many of the files it needs are done, of how many
    @Published public private(set) var copying: (done: Int, total: Int)?
    @Published public private(set) var lookedAt: Date?
    /// Runs just before each copy is made: the tests' way to change the folder in the middle of a look
    public var beforeClone: ((Manifest.Entry) -> Void)?
    private let now: @Sendable () -> Date
    private var running = false
    private var again = false

    public init(store: LibraryStore, folder: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.folder = folder
        self.now = now
        store.everyKind = true
        store.wording = .mac
        let folder = folder
        store.midUpdate = { entry in Self.isMidUpdate(entry, in: folder, now: now()) }
    }

    /// Reads the list and copies, checks and swaps in what changed, one file at a time. A check asked for while one runs
    /// runs once more after it.
    public func check() async {
        guard !running else {
            again = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            again = false
            await once()
        } while again
    }

    private func once() async {
        lookedAt = now()
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.listName)),
              let manifest = try? Manifest.read(data) else {
            problem = Self.listUnreadable
            return
        }
        problem = nil
        if store.record.manifest != manifest { store.read(manifest, at: now()) }
        // a download the folder's list no longer names was removed on the Mac (plan phase 8): let go of it here too
        for name in store.record.held.keys.sorted()
            where store.record.held[name]?.entry.kind == "download" && !manifest.files.contains(where: { $0.name == name }) {
            await store.remove(name)
        }
        let todo = LibraryPlan.toFetch(manifest, store.record, everyKind: true)
        guard !todo.isEmpty else { return }
        copying = (0, todo.count)
        defer { copying = nil }
        for (done, entry) in todo.enumerated() {
            copying = (done, todo.count)
            beforeClone?(entry)
            guard clone(entry) else { continue }
            store.handOver(entry)
            await store.checkWaiting()
        }
    }

    /// The entry's file cloned to the store's `incoming`; false (with a note) when it isn't there or can't be cloned.
    private func clone(_ entry: Manifest.Entry) -> Bool {
        let source = folder.appendingPathComponent(entry.name)
        let target = store.incoming(entry)
        store.prepareFolders()
        try? FileManager.default.removeItem(at: target)  // a clone left by a check that stopped part-way
        guard clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            let code = errno
            store.note(entry.name, code == ENOENT ? Self.notInFolder
                       : "This copy couldn't be made from the library folder (code \(code)); tried again at the next check.")
            return false
        }
        return true
    }

    /// Whether the folder moved on from the entry being checked: the list on disk now gives that name another copy
    /// (it was rewritten during the look, whole-branch review 1), or the file now at the name changed after the list
    /// was written, within `updateWindow` of `now`.
    nonisolated static func isMidUpdate(_ entry: Manifest.Entry, in folder: URL, now: Date) -> Bool {
        if let data = try? Data(contentsOf: folder.appendingPathComponent(listName)),
           let current = try? Manifest.read(data),
           !current.files.contains(where: { $0.name == entry.name && $0.sha256 == entry.sha256 }) {
            return true
        }
        guard let changed = changeTime(folder.appendingPathComponent(entry.name)),
              let listed = modificationTime(folder.appendingPathComponent(listName)) else { return false }
        return changed > listed && now.timeIntervalSince(changed) < updateWindow
    }

    /// The inode's last change (a swap into place counts), from stat
    nonisolated static func changeTime(_ url: URL) -> Date? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec)
                    + TimeInterval(info.st_ctimespec.tv_nsec) / 1e9)
    }

    nonisolated static func modificationTime(_ url: URL) -> Date? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }
}
