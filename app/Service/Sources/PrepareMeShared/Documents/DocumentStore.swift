import CryptoKit
import Foundation

/// What Essential Documents keeps (docs/documents.md), all inside its encrypted index: the owner's folders, any depth,
/// and each document's name, folder, type, size, fingerprint, dates and where copies were sent. Nothing here is ever
/// logged; the index is only ever written encrypted.
public struct DocumentIndex: Codable, Equatable, Sendable {
    public var folders: [DocumentFolder] = []
    public var documents: [StoredDocument] = []
    /// Documents and folders removed for good from Recently Deleted: a restore never brings one back (ruling C).
    public var purged: [UUID] = []
    /// What the insurance move brought in (phase 2: InsuranceMove), each by its own key, kept after the document or
    /// folder goes so a deleted one is never brought back (ruling C). Absent from an index written before phase 2.
    public var brought: [String: UUID]?
    /// The adults' phones' changes the Mac has applied (phase 3: DocumentChange), each once, by its id. Absent from an
    /// index written before phase 3.
    public var applied: [UUID]?
    /// The stored files removed on purpose (a purge, a replaced insurance PDF), by their random names, for the list
    /// (DocumentList.removed: audit G2). Absent from an index written before 2026-11-22.
    public var removedFiles: [String]?

    public init() {}
}

public struct DocumentFolder: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var parent: UUID?
    public var created: Date
    public var deleted: Date?
}

public struct StoredDocument: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String  // as given, without its extension (kept as written: capitals and punctuation)
    public var folder: UUID?
    public let file: String  // its random name in files/
    public let type: String  // its extension, lowercased: "pdf", "heic", "docx"
    public let size: Int64
    public let sha256: String  // the original's, matched against the stored copy when it was added
    public let added: Date
    public var deleted: Date?
    public var sends: [DocumentSend] = []

    public var fileName: String { "\(name).\(type)" }
    public var kind: DocumentTypes.Kind { DocumentTypes.kind(forExtension: type) ?? .office }
}

/// One copy that left PrepareMe: when, from which device, and how (Print, AirDrop, Share, Locked PDF).
public struct DocumentSend: Codable, Equatable, Sendable {
    public let date: Date
    public let device: String
    public let how: String

    public init(date: Date, device: String, how: String) {
        self.date = date
        self.device = device
        self.how = how
    }
}

/// The types Essential Documents keeps, by extension, and how each opens: PDFs and photos in PrepareMe's own viewer,
/// Office, iWork and text files in Quick Look. Single files only: a package (a folder that looks like a file) is
/// refused.
public enum DocumentTypes {
    public enum Kind: Equatable, Sendable { case pdf, image, office }

    static let kinds: [String: Kind] = [
        "pdf": .pdf,
        "jpg": .image, "jpeg": .image, "png": .image, "heic": .image, "heif": .image, "tif": .image, "tiff": .image,
        "doc": .office, "docx": .office, "xls": .office, "xlsx": .office, "pages": .office, "numbers": .office,
        "txt": .office, "rtf": .office,
    ]

    public static func kind(forExtension ext: String) -> Kind? { kinds[ext.lowercased()] }

    /// The extensions the open panel offers.
    public static var extensions: [String] { kinds.keys.sorted() }
}

/// Why a file wasn't added; the import report counts these, never naming a file.
public enum DocumentRefusal: String, Error, Equatable, Sendable, CaseIterable {
    case notAType = "isn't a type PrepareMe keeps"
    case package = "is a package, not a single file"
    case unreadable = "couldn't be read"
    case mismatch = "didn't match its stored copy, so it wasn't kept"
}

/// What one Add Folder of Documents… did, in counts only (the import report prints counts and fingerprints, never names).
public struct DocumentImportReport: Equatable, Sendable {
    public var added = 0
    public var foldersMade = 0
    public var alreadyHere = 0
    public var refused: [DocumentRefusal: Int] = [:]

    public init() {}
}

extension DocumentIndex {
    public static let recentlyDeletedDays = 30

    public func folder(_ id: UUID?) -> DocumentFolder? { folders.first { $0.id == id } }

    /// Whether the folder, or one around it, is in Recently Deleted.
    public func isDeleted(folder id: UUID?) -> Bool {
        var current = id
        var seen = Set<UUID>()
        while let here = current, !seen.contains(here), let found = folder(here) {
            if found.deleted != nil { return true }
            seen.insert(here)
            current = found.parent
        }
        return false
    }

    public func isDeleted(_ document: StoredDocument) -> Bool {
        document.deleted != nil || isDeleted(folder: document.folder)
    }

    /// A folder's own folders and documents, in name order, Recently Deleted left out.
    public func folders(in parent: UUID?) -> [DocumentFolder] {
        folders.filter { $0.parent == parent && $0.deleted == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func documents(in folder: UUID?) -> [StoredDocument] {
        documents.filter { $0.folder == folder && $0.deleted == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every document not in Recently Deleted.
    public var live: [StoredDocument] { documents.filter { !isDeleted($0) } }

    /// The folder and every folder inside it.
    public func subtree(_ id: UUID) -> Set<UUID> {
        var found: Set<UUID> = [id]
        var added = true
        while added {
            added = false
            for folder in folders where folder.parent.map(found.contains) == true && !found.contains(folder.id) {
                found.insert(folder.id)
                added = true
            }
        }
        return found
    }

    /// The documents a folder holds, its subfolders' included, Recently Deleted left out: what deleting it would take.
    public func documentCount(inFolder id: UUID) -> Int {
        let ids = subtree(id)
        return documents.filter { $0.deleted == nil && $0.folder.map(ids.contains) == true }.count
    }

    @discardableResult
    public mutating func newFolder(_ name: String, in parent: UUID?, now: Date = Date()) -> UUID {
        if let same = folders(in: parent).first(where: { $0.name == name }) { return same.id }
        let folder = DocumentFolder(id: UUID(), name: name, parent: parent, created: now, deleted: nil)
        folders.append(folder)
        return folder.id
    }

    public mutating func rename(folder id: UUID, to name: String) {
        guard let at = folders.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        folders[at].name = name
    }

    public mutating func rename(document id: UUID, to name: String) {
        guard let at = documents.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        documents[at].name = name
    }

    public mutating func move(document id: UUID, to folder: UUID?) {
        guard let at = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[at].folder = folder
    }

    /// Moves a folder; never into itself or a folder inside it.
    @discardableResult
    public mutating func move(folder id: UUID, to parent: UUID?) -> Bool {
        guard let at = folders.firstIndex(where: { $0.id == id }) else { return false }
        if let parent, subtree(id).contains(parent) { return false }
        folders[at].parent = parent
        return true
    }

    /// Into Recently Deleted for 30 days.
    public mutating func delete(document id: UUID, now: Date = Date()) {
        guard let at = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[at].deleted = now
    }

    /// The folder and everything in it into Recently Deleted for 30 days.
    public mutating func delete(folder id: UUID, now: Date = Date()) {
        guard let at = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[at].deleted = now
    }

    /// Back out of Recently Deleted; a document or folder whose folder is still deleted comes back at the top level.
    public mutating func putBack(document id: UUID) {
        guard let at = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[at].deleted = nil
        if isDeleted(folder: documents[at].folder) { documents[at].folder = nil }
    }

    public mutating func putBack(folder id: UUID) {
        guard let at = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[at].deleted = nil
        if isDeleted(folder: folders[at].parent) { folders[at].parent = nil }
    }

    /// What Recently Deleted lists: each document and folder deleted on its own (a deleted folder's contents go with it).
    public var recentlyDeleted: (folders: [DocumentFolder], documents: [StoredDocument]) {
        (folders.filter { $0.deleted != nil && !isDeleted(folder: $0.parent) },
         documents.filter { $0.deleted != nil && !isDeleted(folder: $0.folder) })
    }

    public mutating func recordSend(_ send: DocumentSend, for id: UUID) {
        guard let at = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[at].sends.append(send)
    }

    /// Takes out what has been in Recently Deleted 30 days or more, remembering each for good (ruling C), and returns
    /// the stored files to remove.
    public mutating func purgeExpired(now: Date = Date()) -> [String] {
        let limit = TimeInterval(Self.recentlyDeletedDays * 86_400)
        func expired(_ date: Date?) -> Bool { date.map { now.timeIntervalSince($0) >= limit } ?? false }
        var goneFolders = Set<UUID>()
        for folder in folders where expired(folder.deleted) { goneFolders.formUnion(subtree(folder.id)) }
        let goneDocuments = documents.filter { expired($0.deleted) || $0.folder.map(goneFolders.contains) == true }
        purged += goneFolders.sorted { $0.uuidString < $1.uuidString } + goneDocuments.map(\.id)
        folders.removeAll { goneFolders.contains($0.id) }
        documents.removeAll { doc in goneDocuments.contains { $0.id == doc.id } }
        if !goneDocuments.isEmpty { removedFiles = (removedFiles ?? []) + goneDocuments.map(\.file) }
        return goneDocuments.map(\.file)
    }
}

/// The encrypted store in one folder: `index.pmdoc` (the encrypted index) and `files/` (each document encrypted under
/// a random name). Nothing in the folder names or hints at what it holds.
public struct DocumentStore: Sendable {
    public let root: URL
    let key: SymmetricKey

    public init(root: URL, key: SymmetricKey) {
        self.root = root
        self.key = key
    }

    /// The key's one-way fingerprint (DocumentSpare.keyID), for the phones' list.
    public var keyID: String { DocumentSpare.keyID(key) }

    var indexURL: URL { root.appendingPathComponent("index.pmdoc") }
    var filesURL: URL { root.appendingPathComponent("files", isDirectory: true) }

    func url(of document: StoredDocument) -> URL { filesURL.appendingPathComponent(document.file) }

    /// The store's folders, owner-only, with Spotlight told to keep out.
    public static func prepare(_ root: URL) throws {
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let never = root.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: never.path) {
            FileManager.default.createFile(atPath: never.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    public func load() throws -> DocumentIndex {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return DocumentIndex() }
        // dates as the plain seconds JSONEncoder writes by default, so they come back exactly (ISO 8601 drops fractions)
        return try JSONDecoder().decode(DocumentIndex.self, from: DocumentCipher.decrypt(indexURL, key: key))
    }

    public func save(_ index: DocumentIndex) throws {
        try Self.prepare(root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try DocumentCipher.encrypt(encoder.encode(index), to: indexURL, key: key)
    }

    /// Adds one file to `folder`: encrypted under a random name, then read back and its fingerprint matched against
    /// the original's. A file that doesn't match isn't kept. The index isn't saved here: the caller saves it once.
    @discardableResult
    public func add(_ source: URL, to folder: UUID?, in index: inout DocumentIndex, now: Date = Date()) throws
        -> StoredDocument {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else {
            throw DocumentRefusal.unreadable
        }
        let ext = source.pathExtension.lowercased()
        guard DocumentTypes.kind(forExtension: ext) != nil else { throw DocumentRefusal.notAType }
        guard !isFolder.boolValue else { throw DocumentRefusal.package }
        try Self.prepare(root)
        let file = UUID().uuidString.lowercased() + ".pmdoc"
        let stored = filesURL.appendingPathComponent(file)
        let original: (sha256: String, size: Int64)
        do {
            original = try DocumentCipher.encrypt(from: source, to: stored, key: key)
        } catch {
            try? FileManager.default.removeItem(at: stored)
            throw DocumentRefusal.unreadable
        }
        guard let back = try? DocumentCipher.plainFingerprint(of: stored, key: key), back == original else {
            try? FileManager.default.removeItem(at: stored)
            throw DocumentRefusal.mismatch
        }
        let document = StoredDocument(id: UUID(), name: source.deletingPathExtension().lastPathComponent, folder: folder,
                                      file: file, type: ext, size: original.size, sha256: original.sha256, added: now)
        index.documents.append(document)
        return document
    }

    /// Adds `data` as `name`.`type` (the insurance move's photos and PDF), checked as `add` checks a file.
    @discardableResult
    public func add(_ data: Data, named name: String, type: String, to folder: UUID?, in index: inout DocumentIndex,
                    now: Date = Date()) throws -> StoredDocument {
        let ext = type.lowercased()
        guard DocumentTypes.kind(forExtension: ext) != nil else { throw DocumentRefusal.notAType }
        let sealed = try seal(data)
        let document = StoredDocument(id: UUID(), name: name, folder: folder, file: sealed.file, type: ext,
                                      size: sealed.size, sha256: sealed.sha256, added: now)
        index.documents.append(document)
        return document
    }

    /// New contents for a document (the insurance PDF, rebuilt): its name, folder, dates and sends kept. Returns the
    /// old stored file, to remove once the index is saved.
    public func replace(_ id: UUID, with data: Data, in index: inout DocumentIndex) throws -> String? {
        guard let at = index.documents.firstIndex(where: { $0.id == id }) else { return nil }
        let old = index.documents[at], sealed = try seal(data)
        index.documents[at] = StoredDocument(id: old.id, name: old.name, folder: old.folder, file: sealed.file,
                                             type: old.type, size: sealed.size, sha256: sealed.sha256, added: old.added,
                                             deleted: old.deleted, sends: old.sends)
        index.removedFiles = (index.removedFiles ?? []) + [old.file]
        return old.file
    }

    /// `data` encrypted under a new random name, read back and matched, or nothing kept.
    private func seal(_ data: Data) throws -> (file: String, sha256: String, size: Int64) {
        try Self.prepare(root)
        let file = UUID().uuidString.lowercased() + ".pmdoc"
        let stored = filesURL.appendingPathComponent(file)
        let original = (sha256: Hex.string(SHA256.hash(data: data)), size: Int64(data.count))
        do {
            try DocumentCipher.encrypt(data, to: stored, key: key)
        } catch {
            try? FileManager.default.removeItem(at: stored)
            throw DocumentRefusal.unreadable
        }
        guard let back = try? DocumentCipher.plainFingerprint(of: stored, key: key), back == original else {
            try? FileManager.default.removeItem(at: stored)
            throw DocumentRefusal.mismatch
        }
        return (file, original.sha256, original.size)
    }

    /// Add Folder of Documents… (ruling A): everything in `source`, its folders and subfolders kept as they are, into `folder`. A
    /// folder of the same name there is used, not doubled, and a file already in its folder (same fingerprint) is
    /// skipped, so adding the same folder twice changes nothing. Hidden files are passed over.
    public func addFolder(_ source: URL, to folder: UUID?, in index: inout DocumentIndex, now: Date = Date())
        -> DocumentImportReport {
        var report = DocumentImportReport()
        walk(source, into: folder, index: &index, report: &report, now: now)
        return report
    }

    private func walk(_ source: URL, into folder: UUID?, index: inout DocumentIndex, report: inout DocumentImportReport,
                      now: Date) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else {
            report.refused[.unreadable, default: 0] += 1
            return
        }
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true && values?.isPackage != true {
                let before = index.folders.count
                let child = index.newFolder(item.lastPathComponent, in: folder, now: now)
                report.foldersMade += index.folders.count - before
                walk(item, into: child, index: &index, report: &report, now: now)
                continue
            }
            if values?.isPackage != true, DocumentTypes.kind(forExtension: item.pathExtension) != nil,
               let sha = try? FileCheck.sha256(of: item),
               index.documents(in: folder).contains(where: { $0.sha256 == sha }) {
                report.alreadyHere += 1
                continue
            }
            do {
                try add(item, to: folder, in: &index, now: now)
                report.added += 1
            } catch {
                report.refused[error as? DocumentRefusal ?? .unreadable, default: 0] += 1
            }
        }
    }

    /// The document's plain bytes, read back and matched against its fingerprint.
    public func data(of document: StoredDocument) throws -> Data {
        let data = try DocumentCipher.decrypt(url(of: document), key: key)
        guard Hex.string(SHA256.hash(data: data)) == document.sha256 else { throw DocumentCipher.Failure.damaged }
        return data
    }

    /// Whether each stored file still opens and matches its fingerprint: (matching, all).
    public func verifyAll(_ index: DocumentIndex) -> (matching: Int, all: Int) {
        let all = index.documents
        let matching = all.filter { doc in
            guard let back = try? DocumentCipher.plainFingerprint(of: url(of: doc), key: key) else { return false }
            return back == (doc.sha256, doc.size)
        }
        return (matching.count, all.count)
    }

    /// Removes stored files the index no longer names (after a purge).
    public func remove(files: [String]) {
        for file in files { try? FileManager.default.removeItem(at: filesURL.appendingPathComponent(file)) }
    }
}

/// The short-lived unlocked copies a send or Quick Look needs (design: "The unlocked copy lasts only as long as the
/// send"): one sealed folder in the app's own temporary folder, owner-only, wiped when the section locks, the send
/// ends and the app starts.
public enum DocumentScratch {
    public static func folder(in temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        temporary.appendingPathComponent("PrepareMe-open", isDirectory: true)
    }

    /// `data` written as `name` in a new folder of its own inside the scratch folder.
    public static func copy(_ data: Data, named name: String,
                            in temporary: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = folder(in: temporary).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    public static func wipe(in temporary: URL = FileManager.default.temporaryDirectory) {
        try? FileManager.default.removeItem(at: folder(in: temporary))
    }
}
