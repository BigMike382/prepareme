import CryptoKit
import Foundation

// Essential Documents on the adults' phones and iPads (phase 3; docs/documents.md, "The phones"). The Mac's store goes
// to each adult phone the owner has given the key, over the paired home Wi-Fi link, exactly as it is: the encrypted
// index and the encrypted files. The phones' service never holds the key, so it never sees a name or a page; a phone's
// own changes come back encrypted the same way, for the Mac to apply the next time it is unlocked.

/// What the Mac leaves beside its store for the phones' service (`list.json`): the encrypted index and every encrypted
/// file, each by its size and the SHA-256 of its encrypted bytes. Nothing in it names a document. The service serves
/// only what it names, so the key file and a half-written copy are never a phone's.
public struct DocumentList: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let name: String
        public let size: Int64
        public let sha256: String

        public init(name: String, size: Int64, sha256: String) {
            self.name = name
            self.size = size
            self.sha256 = sha256
        }
    }

    public var version = 1
    public var index: Entry
    public var files: [Entry]
    /// Audit G2 (2026-11-22): the household key's one-way fingerprint (DocumentSpare.keyID) and the stored files the
    /// Mac removed on purpose (DocumentIndex.removedFiles), so a phone or the iCloud copy never takes "not listed" for
    /// "deleted". Written while the store is unlocked, kept by a keyless relist only for the same index; absent from an
    /// older Mac's list. An older phone ignores both (the version stays 1).
    public var keyID: String?
    public var removed: [String]?

    public static let fileName = "list.json"
    public static let indexName = "index.pmdoc"
    public static let maxBytes = 4 << 20

    /// A stored file's name: a lowercased UUID and ".pmdoc", as DocumentStore makes them.
    public static func isFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".pmdoc"), let id = UUID(uuidString: String(name.dropLast(".pmdoc".count))) else {
            return false
        }
        return name == id.uuidString.lowercased() + ".pmdoc"
    }

    /// What only the unlocked store knows: its key's fingerprint and the files it removed on purpose.
    public typealias Stamp = (keyID: String, removed: [String])

    /// The list of the store at `root` as it is now; nil when it has no index yet. A file `previous` lists with the
    /// same name and size isn't read again: a stored file is never rewritten in place (a new copy gets a new name).
    /// `stamp` comes from the unlocked store; without it, `previous`'s carries over only while the index is the same
    /// one it described (a store swapped in while PrepareMe was closed goes without until the next unlock).
    public static func make(root: URL, previous: DocumentList? = nil, stamp: Stamp? = nil) throws -> DocumentList? {
        let index = root.appendingPathComponent(indexName)
        guard Self.isRegularFile(index) else { return nil }
        let known = Dictionary((previous?.files ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let folder = root.appendingPathComponent("files", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var files: [Entry] = []
        for name in names.sorted() where isFileName(name) {
            let url = folder.appendingPathComponent(name)
            guard Self.isRegularFile(url), let size = Self.size(of: url) else { continue }
            if let entry = known[name], entry.size == size {
                files.append(entry)
            } else {
                files.append(Entry(name: name, size: size, sha256: try FileCheck.sha256(of: url)))
            }
        }
        guard let size = Self.size(of: index) else { return nil }
        var list = DocumentList(index: Entry(name: indexName, size: size, sha256: try FileCheck.sha256(of: index)),
                                files: files)
        if let stamp {
            (list.keyID, list.removed) = (stamp.keyID, stamp.removed)
        } else if let previous, previous.index == list.index {
            (list.keyID, list.removed) = (previous.keyID, previous.removed)
        }
        return list
    }

    /// Writes the store's list again, whole, when it changed. The Mac app calls it after every save and removal.
    @discardableResult
    public static func refresh(root: URL, stamp: Stamp? = nil) throws -> DocumentList? {
        let url = root.appendingPathComponent(fileName)
        let previous = (try? Data(contentsOf: url)).flatMap { try? read($0) }
        guard let list = try make(root: root, previous: previous, stamp: stamp) else { return nil }
        if list != previous { try DurableFile.write(encoded(list), to: url) }
        return list
    }

    public static func encoded(_ list: DocumentList) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(list)
    }

    public enum Problem: Error { case unreadable }

    /// A list as served, checked: plain stored names, SHA-256s, no size below zero.
    public static func read(_ data: Data) throws -> DocumentList {
        guard data.count <= maxBytes, let list = try? JSONDecoder().decode(DocumentList.self, from: data),
              list.version == 1, list.index.name == indexName, Hex.isSHA256(list.index.sha256), list.index.size >= 0,
              list.files.allSatisfy({ isFileName($0.name) && Hex.isSHA256($0.sha256) && $0.size >= 0 }),
              Set(list.files.map(\.name)).count == list.files.count,
              list.keyID.map({ $0.count == 32 && $0.allSatisfy(\.isHexDigit) }) ?? true,
              (list.removed ?? []).allSatisfy(isFileName) else { throw Problem.unreadable }
        return list
    }

    public func entry(named name: String) -> Entry? {
        name == index.name ? index : files.first { $0.name == name }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    public static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

/// A phone's copy of the Mac's store (phase 3): it mirrors the list it was served, file for file, each checked against
/// the list's fingerprint before it is kept; the index goes in last, once every file it may name is here, and only
/// then are files the list no longer names removed (never one of the phone's own changes still on its way to the Mac).
/// `held.json` records the list mirrored and each file's checked fingerprint.
public enum DocumentMirror {
    public struct Held: Codable, Equatable, Sendable {
        public var list: DocumentList?
        public var checked: [String: String] = [:]  // a file's name → its fingerprint, checked when it came
        /// G2: the key fingerprint of the last list taken that had one. Once set, the phone never goes back to taking
        /// lists as before G2, even after a list without one.
        public var keyID: String?
        /// G2: why the last list served was refused (nothing taken, nothing sent); nil once a list is taken.
        public var refused: Refusal?

        public init(list: DocumentList? = nil, checked: [String: String] = [:]) {
            self.list = list
            self.checked = checked
        }
    }

    /// Why a phone kept its own copy instead of a list (audit G2). `files`: the stored files it holds that the list
    /// neither names nor says were removed on purpose; `keyID`: the list's, for the unlocked phone to compare with
    /// its own key.
    public struct Refusal: Codable, Equatable, Sendable {
        public enum Reason: String, Codable, Sendable {
            case otherKey  // the list's key isn't the one this phone's earlier lists had
            case missing  // the Mac lacks files this phone has (set up again from an older copy, or under a new key)
            case unstamped  // as `missing`, from a Mac whose store hasn't been unlocked since it was swapped in
        }

        public var reason: Reason
        public var files: Int
        public var keyID: String?

        public init(_ reason: Reason, files: Int, keyID: String?) {
            self.reason = reason
            self.files = files
            self.keyID = keyID
        }
    }

    public static let heldName = "held.json"

    public static func held(in root: URL) -> Held {
        (try? Data(contentsOf: root.appendingPathComponent(heldName)))
            .flatMap { try? JSONDecoder().decode(Held.self, from: $0) } ?? Held()
    }

    static func keep(_ held: Held, in root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFile.write(encoder.encode(held), to: root.appendingPathComponent(heldName))
    }

    /// What to fetch for `list`: each file not here with its listed fingerprint, then the index if it differs.
    public static func toFetch(_ list: DocumentList, held: Held, root: URL) -> [DocumentList.Entry] {
        let files = list.files.filter { entry in
            held.checked[entry.name] != entry.sha256
                || !DocumentList.isRegularFile(root.appendingPathComponent("files").appendingPathComponent(entry.name))
        }
        let indexHere = DocumentList.isRegularFile(root.appendingPathComponent(DocumentList.indexName))
        return files + (held.list?.index == list.index && indexHere ? [] : [list.index])
    }

    public enum Problem: Error, Equatable { case mismatch, notListed, refused }

    /// Audit G2: whether this phone may take `list`; nil when it may. A phone never removes a stored file it holds
    /// unless the list still names it or says the Mac removed it on purpose, and never takes a list made under
    /// another key. Until the phone has taken a list with a key fingerprint, an older Mac's lists (none) are taken as
    /// before. `yield`: the key fingerprint the owner chose "Use the Mac's Copy…" for, which lets a `missing` through.
    public static func judge(_ list: DocumentList, held: Held, yield: String? = nil) -> Refusal? {
        guard let had = held.list else { return nil }  // nothing here yet: nothing to lose
        if let mine = held.keyID, let theirs = list.keyID, mine != theirs {
            return Refusal(.otherKey, files: had.files.count, keyID: theirs)
        }
        guard held.keyID != nil || list.keyID != nil else { return nil }  // an older Mac and phone: as before G2
        let kept = Set(list.files.map(\.name)).union(list.removed ?? [])
        let lost = had.files.filter { !kept.contains($0.name) }.count
        guard lost > 0 else { return nil }
        if let theirs = list.keyID, theirs == yield { return nil }
        return Refusal(list.keyID == nil ? .unstamped : .missing, files: lost, keyID: list.keyID)
    }

    /// Whether this phone may send its adds and changes home: with a list served, only one it would take; with none (a
    /// Mac with no documents yet, or no answer), only while it has never mirrored one, as before G2.
    public static func maySend(_ list: DocumentList?, held: Held, yield: String? = nil) -> Bool {
        guard let list else { return held.list == nil }
        return judge(list, held: held, yield: yield) == nil
    }

    /// Records the judgment of the list served (`judge`), for the phone's Documents to say so or stop saying so.
    public static func record(_ refusal: Refusal?, root: URL, held: inout Held) throws {
        guard held.refused != refusal else { return }
        held.refused = refusal
        try keep(held, in: root)
    }

    /// The owner's "Use the Mac's Copy…" on the phone, for the Mac's key `keyID` only; cleared once a list is taken.
    public static let yieldName = "use-macs-copy.txt"

    public static func yielded(in root: URL) -> String? {
        (try? String(contentsOf: root.appendingPathComponent(yieldName), encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public static func yield(to keyID: String, root: URL) throws {
        try DurableFile.write(Data(keyID.utf8), to: root.appendingPathComponent(yieldName))
    }

    /// One fetched file (at `fetched`, anywhere) into its place, if its fingerprint is the list's; the index waits in
    /// `index.incoming` until `finish`. Refused, it is removed and nothing changes.
    public static func take(_ fetched: URL, as entry: DocumentList.Entry, root: URL, held: inout Held) throws {
        guard (try? FileCheck.sha256(of: fetched)) == entry.sha256 else {
            try? FileManager.default.removeItem(at: fetched)
            throw Problem.mismatch
        }
        try DocumentStore.prepare(root)
        let place = entry.name == DocumentList.indexName ? root.appendingPathComponent(incomingIndex)
            : root.appendingPathComponent("files").appendingPathComponent(entry.name)
        try? FileManager.default.removeItem(at: place)
        try FileManager.default.moveItem(at: fetched, to: place)
        if entry.name != DocumentList.indexName {
            held.checked[entry.name] = entry.sha256
            try keep(held, in: root)
        }
    }

    static let incomingIndex = "index.incoming"

    /// Every file of `list` is here: the index swapped in, the list kept as mirrored, and files neither the list nor
    /// `keep` (the phone's own adds not yet on the Mac) names removed.
    /// Refused (`judge`), nothing changes.
    public static func finish(_ list: DocumentList, root: URL, held: inout Held, keep kept: Set<String>) throws {
        guard judge(list, held: held, yield: yielded(in: root)) == nil else { throw Problem.refused }
        for entry in list.files where held.checked[entry.name] != entry.sha256 { throw Problem.notListed }
        let incoming = root.appendingPathComponent(incomingIndex)
        if FileManager.default.fileExists(atPath: incoming.path) {
            guard (try? FileCheck.sha256(of: incoming)) == list.index.sha256 else {
                try? FileManager.default.removeItem(at: incoming)
                throw Problem.mismatch
            }
            guard rename(incoming.path, root.appendingPathComponent(DocumentList.indexName).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        held.list = list
        held.keyID = list.keyID ?? held.keyID
        held.refused = nil
        try? FileManager.default.removeItem(at: root.appendingPathComponent(yieldName))
        let listed = Set(list.files.map(\.name))
        let folder = root.appendingPathComponent("files")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where DocumentList.isFileName(name) && !listed.contains(name) && !kept.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        held.checked = held.checked.filter { listed.contains($0.key) }
        try keep(held, in: root)
    }

    /// The phone's own adds that the Mac took in and now lists, counted as checked when this phone's copy is the listed
    /// one, so they aren't fetched back.
    public static func adopt(_ list: DocumentList, own: Set<String>, root: URL, held: inout Held) throws {
        var changed = false
        for entry in list.files where own.contains(entry.name) && held.checked[entry.name] != entry.sha256 {
            let url = root.appendingPathComponent("files").appendingPathComponent(entry.name)
            guard (try? FileCheck.sha256(of: url)) == entry.sha256 else { continue }
            held.checked[entry.name] = entry.sha256
            changed = true
        }
        if changed { try keep(held, in: root) }
    }

    /// How this phone stands against `list`: files held with the listed fingerprint and still in `root`, of all
    /// listed, and whether its index is the list's. A file gone from the disk isn't counted, so the phone never says
    /// "all on this phone" for one it no longer has.
    public static func standing(_ list: DocumentList, held: Held, root: URL) -> (matching: Int, all: Int, index: Bool) {
        let files = root.appendingPathComponent("files")
        return (list.files.filter {
            held.checked[$0.name] == $0.sha256 && DocumentList.isRegularFile(files.appendingPathComponent($0.name))
        }.count, list.files.count, held.list?.index == list.index)
    }
}

/// One change made on an adult's phone (phase 3: adds, folders, rename, move, delete, put back and sends), applied on
/// the Mac once, by its id, the next time Essential Documents is unlocked there; until then the phone shows it on top
/// of the Mac's index. Travels and waits encrypted with the household key, never in the clear.
public struct DocumentChange: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        case add(document: StoredDocument)
        case newFolder(folder: DocumentFolder)
        case renameDocument(id: UUID, name: String)
        case renameFolder(id: UUID, name: String)
        case moveDocument(id: UUID, folder: UUID?)
        case moveFolder(id: UUID, parent: UUID?)
        case deleteDocument(id: UUID)
        case deleteFolder(id: UUID)
        case putBackDocument(id: UUID)
        case putBackFolder(id: UUID)
        case send(id: UUID, send: DocumentSend)
    }

    public let id: UUID
    public let at: Date
    public let kind: Kind

    public init(_ kind: Kind, at: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.at = at
        self.kind = kind
    }

    /// The stored file a phone's add brings, which the Mac takes from its inbox.
    public var file: String? {
        if case let .add(document) = kind { return document.file }
        return nil
    }
}

extension DocumentIndex {
    /// Applies a phone's change once; false when it was applied already. One for something gone (deleted for good, or
    /// never here) changes nothing but still counts as applied, so it isn't tried again. A deleted-for-good id is
    /// never brought back (ruling C); a folder or document whose folder is gone lands at the top level.
    @discardableResult
    public mutating func apply(_ change: DocumentChange) -> Bool {
        guard applied?.contains(change.id) != true else { return false }
        applied = (applied ?? []) + [change.id]
        let gone = Set(purged)
        func live(_ folder: UUID?) -> UUID? { folder.flatMap { self.folder($0) == nil ? nil : $0 } }
        switch change.kind {
        case var .add(document):
            guard !gone.contains(document.id), !documents.contains(where: { $0.id == document.id }) else { break }
            document.folder = live(document.folder)
            documents.append(document)
        case var .newFolder(folder):
            guard !gone.contains(folder.id), self.folder(folder.id) == nil else { break }
            folder.parent = live(folder.parent)
            folders.append(folder)
        case let .renameDocument(id, name): rename(document: id, to: name)
        case let .renameFolder(id, name): rename(folder: id, to: name)
        case let .moveDocument(id, folder): move(document: id, to: live(folder))
        case let .moveFolder(id, parent): move(folder: id, to: live(parent))
        case let .deleteDocument(id): delete(document: id, now: change.at)
        case let .deleteFolder(id): delete(folder: id, now: change.at)
        case let .putBackDocument(id): putBack(document: id)
        case let .putBackFolder(id): putBack(folder: id)
        case let .send(id, send): recordSend(send, for: id)
        }
        return true
    }

    /// What a phone shows: the Mac's index with the phone's own changes not yet applied there on top.
    public func overlaid(_ waiting: [DocumentChange]) -> DocumentIndex {
        var shown = self
        for change in waiting { shown.apply(change) }
        shown.applied = applied
        return shown
    }
}

/// A phone's changes waiting for the Mac (`outbox.pmdoc`, encrypted): dropped one by one as the Mac's index shows
/// each applied.
public enum DocumentOutbox {
    public static let fileName = "outbox.pmdoc"
    public static let maxBytes = 256 << 10

    public static func read(in root: URL, key: SymmetricKey) -> [DocumentChange] {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? DocumentCipher.decrypt(url, key: key) else { return [] }
        return (try? JSONDecoder().decode([DocumentChange].self, from: data)) ?? []
    }

    public static func write(_ changes: [DocumentChange], in root: URL, key: SymmetricKey) throws {
        let url = root.appendingPathComponent(fileName)
        if changes.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(changes)
        // the service takes no bigger an outbox: refused here, the change isn't made, so nothing waits that can't go
        guard data.count + 64 <= maxBytes else { throw Full() }
        try DocumentStore.prepare(root)
        try DocumentCipher.encrypt(data, to: url, key: key)
    }

    public struct Full: Error {}

    /// What waits on this phone in plain sight, so a check at home can send it without the key: the waiting changes'
    /// ids and the stored names of the files they add (random names, never a document's), and the fingerprint of the
    /// outbox last taken by the Mac, so an unchanged one isn't sent again.
    public struct Ledger: Codable, Equatable, Sendable {
        public var changes: [UUID] = []
        public var files: [String] = []
        public var posted: String?

        public static let fileName = "waiting.json"

        public init() {}

        public static func read(in root: URL) -> Ledger {
            (try? Data(contentsOf: root.appendingPathComponent(fileName)))
                .flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()
        }

        public func write(in root: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try DurableFile.write(encoder.encode(self), to: root.appendingPathComponent(Self.fileName))
        }

        /// Kept only the changes still waiting (DocumentOutbox.waiting); the files of applied adds are the Mac's now.
        public func settled(_ waiting: [DocumentChange]) -> Ledger {
            var next = self
            next.changes = waiting.map(\.id)
            next.files = waiting.compactMap(\.file)
            if next.changes.isEmpty { next.posted = nil }
            return next
        }
    }

    /// The changes the Mac's index doesn't show applied yet.
    public static func waiting(_ changes: [DocumentChange], against index: DocumentIndex) -> [DocumentChange] {
        let done = Set(index.applied ?? [])
        return changes.filter { !done.contains($0.id) }
    }
}

/// The Mac's side of the phones' changes (phase 3): the phones' service keeps each phone's encrypted outbox and its
/// added files, whole or in part, in `documents/inbox` (`changes-*.pmdoc` and the stored names). With the key, the
/// Mac opens each outbox, takes in each added file whose fingerprint matches, and applies the changes in the order they
/// were made; a change after an add whose file hasn't all come yet waits with it.
public enum DocumentInbox {
    public static let folderName = "inbox"
    public static let changesPrefix = "changes-"
    public static let maxFiles = 2000
    public static let maxBytes: Int64 = 4 << 30
    /// An upload's piece (the service's one body over 1 KB on that path) and an outbox's most
    public static let maxPiece = 512 << 10

    public struct Result: Equatable, Sendable {
        public var applied = 0
        public var waiting = 0
        public var refused = 0  // an outbox that doesn't open with this key, or an add whose file doesn't match
        public var changed: Bool { applied > 0 }

        public init() {}
    }

    /// Applies what has come; the caller saves the index, then calls `tidy` with `done`.
    public static func apply(store: DocumentStore, index: inout DocumentIndex)
        -> (result: Result, done: [URL]) {
        let inbox = store.root.appendingPathComponent(folderName)
        var result = Result(), done: [URL] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).sorted()
        var changes: [DocumentChange] = [], outboxes: [URL] = []
        for name in names where name.hasPrefix(changesPrefix) {
            let url = inbox.appendingPathComponent(name)
            guard let data = try? DocumentCipher.decrypt(url, key: store.key),
                  let read = try? JSONDecoder().decode([DocumentChange].self, from: data) else {
                result.refused += 1
                done.append(url)  // not this household's, or damaged: never applied
                continue
            }
            changes += read
            outboxes.append(url)
        }
        var seen = Set<UUID>()
        changes = changes.sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }.filter { seen.insert($0.id).inserted }
        var held = false
        for change in changes where index.applied?.contains(change.id) != true {
            if held {
                result.waiting += 1
                continue
            }
            if case let .add(document) = change.kind, !(index.purged.contains(document.id)),
               !index.documents.contains(where: { $0.id == document.id }) {
                switch store.takeIn(inbox.appendingPathComponent(document.file), as: document) {
                case .taken: break
                case .notYet:
                    held = true
                    result.waiting += 1
                    continue
                case .refused:
                    result.refused += 1
                    index.applied = (index.applied ?? []) + [change.id]  // never applied, never asked again
                    continue
                }
            }
            if index.apply(change) { result.applied += 1 }
        }
        if !held { done += outboxes }
        return (result, done)
    }

    /// After the index is saved: the outboxes all applied, and any file left over a month (an upload never finished).
    public static func tidy(_ done: [URL], inbox: URL, now: Date = Date()) {
        for url in done { try? FileManager.default.removeItem(at: url) }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? [] {
            let url = inbox.appendingPathComponent(name)
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if let date, now.timeIntervalSince(date) > 30 * 86_400 { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// How many outboxes wait in the inbox (no key needed: counted, never opened).
    public static func waitingOutboxes(root: URL) -> Int {
        let inbox = root.appendingPathComponent(folderName)
        return ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).filter {
            $0.hasPrefix(changesPrefix)
        }.count
    }
}

extension DocumentStore {
    public enum TakeIn: Equatable, Sendable { case taken, notYet, refused }

    /// A phone's added file from the inbox, into the store if it opens and matches the document's fingerprint: whole
    /// and right, it is moved in; cut short (still uploading), it waits; anything else is removed.
    public func takeIn(_ file: URL, as document: StoredDocument) -> TakeIn {
        let place = filesURL.appendingPathComponent(document.file)
        if FileManager.default.fileExists(atPath: place.path) {  // taken in before the index was saved last time
            guard let back = try? DocumentCipher.plainFingerprint(of: place, key: key) else { return .refused }
            return back == (document.sha256, document.size) ? .taken : .refused
        }
        guard DocumentList.isFileName(document.file), FileManager.default.fileExists(atPath: file.path) else {
            return .notYet
        }
        do {
            guard try DocumentCipher.plainFingerprint(of: file, key: key) == (document.sha256, document.size) else {
                try? FileManager.default.removeItem(at: file)
                return .refused
            }
        } catch DocumentCipher.Failure.cutShort {
            return .notYet
        } catch {
            try? FileManager.default.removeItem(at: file)
            return .refused
        }
        do {
            try Self.prepare(root)
            try FileManager.default.moveItem(at: file, to: place)
            return .taken
        } catch {
            return .notYet
        }
    }
}

/// The key's way to a phone (phase 3; owner, 2026-10-24: the owner approves each phone). An adult's phone makes its
/// own lock (a Secure Enclave key that needs Face ID, Touch ID or its passcode) and asks with its public half; the
/// owner, in Settings › Phones on the Mac, gives that phone Essential Documents after Touch ID, and the Mac app seals
/// the household key to that public half. Only that phone's Secure Enclave can open the gift. Both files are in the
/// pairing folder, each with one writer: the service keeps the asks (`requestsName`), the app the gifts (`giftsName`),
/// each stamped with when that phone was paired, so a removed phone's never reaches the next phone given its label.
public enum DocumentHandoff {
    public static let requestsName = "documents-key-requests.json"
    public static let giftsName = "documents-keys.json"
    public static let statusName = "documents-phones.json"

    public struct Request: Codable, Equatable, Sendable {
        public var key: Data  // the phone's lock's public half, raw P-256 (64 bytes)
        public var paired: String?
        public var at: String?

        public init(key: Data, paired: String? = nil, at: String? = nil) {
            self.key = key
            self.paired = paired
            self.at = at
        }

        public static func read(_ body: Data) throws -> Request {
            guard body.count <= 1024, let request = try? JSONDecoder().decode(Request.self, from: body),
                  (try? P256.KeyAgreement.PublicKey(rawRepresentation: request.key)) != nil else {
                throw DocumentList.Problem.unreadable
            }
            return Request(key: request.key)  // the service stamps the rest
        }
    }

    public struct Gift: Codable, Equatable, Sendable {
        public var key: Data  // the public half it was sealed to
        public var paired: String
        public var ephemeral: Data
        public var sealed: Data
        public var at: String
    }

    public static func readRequests(_ data: Data?) -> [String: Request] {
        data.flatMap { try? JSONDecoder().decode([String: Request].self, from: $0) } ?? [:]
    }

    public static func readGifts(_ data: Data?) -> [String: Gift] {
        data.flatMap { try? JSONDecoder().decode([String: Gift].self, from: $0) } ?? [:]
    }

    public static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    /// The phone's ask now holding `label` and paired at `paired`.
    public static func request(_ all: [String: Request], label: String, paired: String) -> Request? {
        all[label].flatMap { $0.paired == paired ? $0 : nil }
    }

    /// The gift for the phone now holding `label`, paired at `paired`: none for a removed phone's reused label.
    public static func gift(_ all: [String: Gift], label: String, paired: String) -> Gift? {
        all[label].flatMap { $0.paired == paired ? $0 : nil }
    }

    /// Whether the phone has been given the key: a gift sealed to the lock it asks with now. A phone that set a broken
    /// key aside asks again with a new lock, so its old gift no longer counts and the owner gives it again.
    public static func given(_ gift: Gift?, ask: Request?) -> Bool {
        guard let gift else { return false }
        return ask.map { $0.key == gift.key } ?? true
    }

    /// A phone's step after `GET key`: keep a gift sealed to the lock it asks with; ask (`POST key-request`) when
    /// there's none yet or the one served is for a lock it set aside; stop on 403 (a child's phone) or with no lock.
    /// `lock` (DocumentKey.lockToAsk) is made only when it's needed, never for a 403.
    public enum KeyStep: Equatable, Sendable { case keep, ask, stop }

    public static func keyStep(status: Int, served: Data, lock: () -> Data?) -> KeyStep {
        guard status == 200 || status == 404, let lock = lock() else { return .stop }
        guard status == 200, (try? JSONDecoder().decode(Served.self, from: served))?.key == lock else { return .ask }
        return .keep
    }

    /// The household key sealed to the phone's lock (the Mac app's side, after Touch ID).
    public static func seal(_ key: SymmetricKey, for request: Request, label: String, paired: String,
                            now: Date = Date()) throws -> Gift {
        let lock = try P256.KeyAgreement.PublicKey(rawRepresentation: request.key)
        let file = try DocumentKeyFile.seal(key, to: lock, lockData: Data())
        let stamp = ISO8601DateFormatter().string(from: now)
        return Gift(key: request.key, paired: paired, ephemeral: file.ephemeral, sealed: file.sealed, at: stamp)
    }

    /// What the phone's service hands the phone: the sealed key, never the pairing stamps.
    public struct Served: Codable, Equatable, Sendable {
        public var key: Data
        public var ephemeral: Data
        public var sealed: Data

        public init(_ gift: Gift) {
            key = gift.key
            ephemeral = gift.ephemeral
            sealed = gift.sealed
        }
    }
}

/// An adult's phone's standing as it tells the Mac (phase 3), counts only: the files it holds with the Mac's
/// fingerprints, of all the Mac lists, whether its index is the Mac's, and its own changes not yet on the Mac. The
/// service keeps the last of each phone by label, stamped like the room report (`DocumentHandoff.statusName`).
public struct DocumentsPhoneReport: Codable, Equatable, Sendable {
    public var matching: Int
    public var all: Int
    public var index: Bool
    public var waiting: Int
    public var at: String?
    public var paired: String?

    public init(matching: Int, all: Int, index: Bool, waiting: Int) {
        self.matching = matching
        self.all = all
        self.index = index
        self.waiting = waiting
    }

    public static func read(_ body: Data) throws -> DocumentsPhoneReport {
        guard body.count <= 1024, var report = try? JSONDecoder().decode(DocumentsPhoneReport.self, from: body),
              report.matching >= 0, report.all >= 0, report.matching <= report.all, report.waiting >= 0 else {
            throw DocumentList.Problem.unreadable
        }
        report.at = nil  // the service's
        report.paired = nil
        return report
    }

    public static func readAll(_ data: Data?) -> [String: DocumentsPhoneReport] {
        data.flatMap { try? JSONDecoder().decode([String: DocumentsPhoneReport].self, from: $0) } ?? [:]
    }

    /// In step: every file and the index are the Mac's.
    public var inStep: Bool { matching == all && index }
}
