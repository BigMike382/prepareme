import CryptoKit
import Foundation

/// The spare key (phase 4; owner, 2026-10-24: "Password in Passwords"): the household key sealed with a recovery
/// password PrepareMe makes once and the owner keeps in Apple's Passwords app (iCloud Keychain). `household.spare` sits
/// in the store's folder, so it rides in the iCloud copy and the drive's image; with the password it opens the store on
/// any Mac. The password is random (24 letters from 31, about 119 bits), never chosen, so HKDF needs no stretching.
public struct DocumentSpare: Codable, Equatable, Sendable {
    public var version = 1
    public let salt: Data
    public let sealed: Data  // the household key, AES-GCM
    public let keyID: String  // a one-way fingerprint of the household key: which key a copy belongs to

    public static let fileName = "household.spare"
    static let info = Data("PrepareMe Essential Documents spare 1".utf8)
    static let idInfo = Data("PrepareMe Essential Documents key id 1".utf8)
    /// No 0, o, 1, l or i: nothing that reads as another letter
    public static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    public static let length = 24

    public struct WrongPassword: Error, Equatable {}

    /// A new recovery password, in groups of six: "abcdef-ghjkmn-pqrstu-vwxyz2".
    public static func newPassword() -> String {
        var random = SystemRandomNumberGenerator()
        let letters = (0..<length).map { _ in alphabet.randomElement(using: &random)! }
        return stride(from: 0, to: length, by: 6).map { String(letters[$0..<$0 + 6]) }.joined(separator: "-")
    }

    /// What was typed or pasted, lowercased, with dashes, spaces and anything else not in the alphabet left out.
    public static func normalized(_ typed: String) -> String {
        String(typed.lowercased().filter { alphabet.contains($0) })
    }

    public static func keyID(_ key: SymmetricKey) -> String {
        Hex.string(Data(HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: idInfo, outputByteCount: 16)
            .withUnsafeBytes { Data($0) }))
    }

    static func wrapping(_ password: String, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(normalized(password).utf8)), salt: salt,
                               info: info, outputByteCount: 32)
    }

    public static func make(_ key: SymmetricKey, password: String) throws -> DocumentSpare {
        let salt = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let raw = key.withUnsafeBytes { Data($0) }
        guard let sealed = try AES.GCM.seal(raw, using: wrapping(password, salt: salt)).combined else {
            throw DocumentCipher.Failure.damaged
        }
        return DocumentSpare(salt: salt, sealed: sealed, keyID: keyID(key))
    }

    /// The household key, or WrongPassword (a wrong or mistyped password, or a changed file: GCM can't tell them apart).
    public func open(password: String) throws -> SymmetricKey {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let raw = try? AES.GCM.open(box, using: Self.wrapping(password, salt: salt)) else { throw WrongPassword() }
        let key = SymmetricKey(data: raw)
        guard Self.keyID(key) == keyID else { throw WrongPassword() }
        return key
    }

    public static func read(in root: URL) -> DocumentSpare? {
        (try? Data(contentsOf: root.appendingPathComponent(fileName))).flatMap {
            try? JSONDecoder().decode(DocumentSpare.self, from: $0)
        }
    }

    public func write(in root: URL) throws {
        try DocumentStore.prepare(root)
        try DurableFile.write(JSONEncoder().encode(self), to: root.appendingPathComponent(Self.fileName))
    }
}

extension DocumentStore {
    /// The open store's spare, sealed with the recovery password the owner has just saved and pasted back.
    public func writeSpare(password: String) throws {
        try DocumentSpare.make(key, password: password).write(in: root)
    }
}

/// The iCloud copy (phase 4): Household Private › Backups › Documents, the store as it is now, still encrypted. Made from
/// the store's list (DocumentList), so it needs no key: each file the copy lacks is copied and checked against the
/// list's fingerprint, the index last, then the spare, and only then are files the list no longer names removed (a
/// purge: deleted stays deleted, ruling C). It never removes a file the list neither names nor says was removed on
/// purpose (a Mac set up again from an older copy: audit G2), never writes over a copy that belongs to another
/// household key (a new Mac's empty store must never wipe the backup), and never copies without a spare (a copy no
/// other Mac could open).
public enum DocumentBackup {
    public enum Outcome: Equatable, Sendable {
        case copied(files: Int, documents: Int)  // files copied this time; the list's documents' files in all
        case noSpare
        case otherKey
        case older(files: Int)  // the copy holds stored files the list neither names nor removed on purpose (G2)
        case noStore
        case failed
    }

    public static let statusName = "backup.json"

    /// The last copy's result, kept beside the store for Settings › Backups: a date and counts only.
    public struct Status: Codable, Equatable, Sendable {
        public var at: Date
        public var files: Int?  // the documents' files in the copy, when it was made
        public var problem: String?  // "noSpare", "otherKey", "older", "noStore" or "failed"

        public init(at: Date, files: Int? = nil, problem: String? = nil) {
            self.at = at
            self.files = files
            self.problem = problem
        }
    }

    public static func copy(from root: URL, to copy: URL, list: DocumentList?) -> Outcome {
        guard let list else { return .noStore }
        guard let spare = DocumentSpare.read(in: root) else { return .noSpare }
        if let theirs = DocumentSpare.read(in: copy), theirs.keyID != spare.keyID { return .otherKey }
        let files = copy.appendingPathComponent("files", isDirectory: true)
        // audit G2: a Mac set up again from an older copy never takes the copy's newer documents with it
        let kept = Set(list.files.map(\.name)).union(list.removed ?? [])
        let lost = present(in: files).keys.filter { !kept.contains($0) }.count
        if lost > 0 { return .older(files: lost) }
        do {
            try DocumentStore.prepare(copy)
            let here = present(in: files)
            var copied = 0
            for entry in list.files where here[entry.name] != entry.size && here[entry.name] != FolderOffer.inICloud {
                try copyChecked(root.appendingPathComponent("files").appendingPathComponent(entry.name),
                                to: files.appendingPathComponent(entry.name), entry: entry)
                copied += 1
            }
            let index = copy.appendingPathComponent(DocumentList.indexName)
            if (try? FileCheck.sha256(of: index)) != list.index.sha256 {
                try copyChecked(root.appendingPathComponent(DocumentList.indexName), to: index, entry: list.index)
            }
            if DocumentSpare.read(in: copy) != spare { try spare.write(in: copy) }
            let named = Set(list.files.map(\.name))
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: files.path)) ?? []) {
                let real = FolderOffer.placeholderName(name) ?? name
                if DocumentList.isFileName(real), !named.contains(real) {
                    try? FileManager.default.removeItem(at: files.appendingPathComponent(name))
                }
            }
            return .copied(files: copied, documents: list.files.count)
        } catch {
            return .failed
        }
    }

    /// The copy's stored files and sizes; one iCloud keeps off the Mac counts as there (FolderOffer.inICloud), since
    /// a stored file is never rewritten in place.
    static func present(in files: URL) -> [String: Int64] {
        var found: [String: Int64] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: files.path)) ?? [] {
            if let real = FolderOffer.placeholderName(name), DocumentList.isFileName(real) {
                found[real] = found[real] ?? FolderOffer.inICloud
            } else if DocumentList.isFileName(name), let size = DocumentList.size(of: files.appendingPathComponent(name)) {
                found[name] = size
            }
        }
        return found
    }

    /// Copies `source` to `destination` whole (DurableStream), refusing a copy whose fingerprint isn't the list's.
    static func copyChecked(_ source: URL, to destination: URL, entry: DocumentList.Entry) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try DurableStream.write(to: destination) { output in
            var hasher = SHA256()
            while let piece = try input.read(upToCount: 4 << 20), !piece.isEmpty {
                hasher.update(data: piece)
                try output.write(contentsOf: piece)
            }
            guard Hex.string(Data(hasher.finalize())) == entry.sha256 else { throw DocumentCipher.Failure.damaged }
        }
    }

    public static func writeStatus(_ outcome: Outcome, in root: URL, now: Date = Date()) {
        let status: Status
        switch outcome {
        case .copied(_, let documents): status = Status(at: now, files: documents)
        case .noSpare: status = Status(at: now, problem: "noSpare")
        case .otherKey: status = Status(at: now, problem: "otherKey")
        case .older: status = Status(at: now, problem: "older")
        case .noStore: status = Status(at: now, problem: "noStore")
        case .failed: status = Status(at: now, problem: "failed")
        }
        var kept = status
        // a good copy's date stays until the next good copy: a failure after it says when the last one was
        if status.problem != nil, let previous = readStatus(in: root), previous.files != nil {
            kept = Status(at: previous.at, files: previous.files, problem: status.problem)
        }
        try? DurableFile.write(JSONEncoder().encode(kept), to: root.appendingPathComponent(statusName))
    }

    public static func readStatus(in root: URL) -> Status? {
        (try? Data(contentsOf: root.appendingPathComponent(statusName))).flatMap {
            try? JSONDecoder().decode(Status.self, from: $0)
        }
    }
}

/// Test a restore (phase 4): a copy of the store, opened with the recovery password alone, every document read back and
/// matched against its fingerprint, as a new Mac would. Nothing is changed in the copy; the result is counts only.
public enum DocumentRestoreTest {
    public enum Result: Equatable, Sendable {
        case passed(documents: Int)
        case mismatched(matching: Int, all: Int)
        case notDownloaded(Int)  // files iCloud keeps off the Mac, asked for: try again once they're down
        case wrongPassword
        case noSpare
        case noIndex
    }

    public static func run(copy: URL, password: String) -> Result {
        guard let spare = DocumentSpare.read(in: copy) else { return .noSpare }
        guard let key = try? spare.open(password: password) else { return .wrongPassword }
        let files = copy.appendingPathComponent("files", isDirectory: true)
        var away = ((try? FileManager.default.contentsOfDirectory(atPath: files.path)) ?? [])
            .compactMap(FolderOffer.placeholderName).filter(DocumentList.isFileName).map { files.appendingPathComponent($0) }
        let index = copy.appendingPathComponent(DocumentList.indexName)
        if FileManager.default.fileExists(atPath: copy.appendingPathComponent(".\(DocumentList.indexName).icloud").path),
           !FileManager.default.fileExists(atPath: index.path) {
            away.append(index)
        }
        if !away.isEmpty {
            for url in away { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
            return .notDownloaded(away.count)
        }
        let store = DocumentStore(root: copy, key: key)
        guard FileManager.default.fileExists(atPath: store.indexURL.path), let index = try? store.load() else {
            return .noIndex
        }
        let (matching, all) = store.verifyAll(index)
        return matching == all ? .passed(documents: all) : .mismatched(matching: matching, all: all)
    }

    public static let recordName = "restore-test.json"

    /// The last test's result, kept beside the store: when, where from, and counts.
    public struct Record: Codable, Equatable, Sendable {
        public var at: Date
        public var from: String  // "iCloud" or "folder"
        public var passed: Bool
        public var documents: Int

        public init(at: Date, from: String, passed: Bool, documents: Int) {
            self.at = at
            self.from = from
            self.passed = passed
            self.documents = documents
        }
    }

    public static func record(_ result: Result, from: String, in root: URL, now: Date = Date()) {
        let record: Record
        switch result {
        case .passed(let documents): record = Record(at: now, from: from, passed: true, documents: documents)
        case .mismatched(_, let all): record = Record(at: now, from: from, passed: false, documents: all)
        default: return  // a wrong password or a copy still downloading tested nothing
        }
        try? DocumentStore.prepare(root)
        try? DurableFile.write(JSONEncoder().encode(record), to: root.appendingPathComponent(recordName))
    }

    public static func read(in root: URL) -> Record? {
        (try? Data(contentsOf: root.appendingPathComponent(recordName))).flatMap {
            try? JSONDecoder().decode(Record.self, from: $0)
        }
    }
}
