import Foundation

/// The list of files the Mac serves, in the format the packer writes from phase 2 (plan section 9, "Phase 2 and the
/// manifest"): `{"written_at", "files": [{"name", "id", "kind", "size", "sha256", "delivered_at", "library_as_of",
/// "sources_checked"}]}`. Phase 1's service writes it by hand for its one made-up file. A phone downloads a file only
/// when its entry passes `checked()`: a plain name, a known kind, a size and a SHA-256 of the right shape.
public struct Manifest: Codable, Equatable, Sendable {
    public var writtenAt: String
    public var files: [Entry]
    /// The public half of the Mac app's backup-signing key (concept-doc plan, phase B), added by the phones' service to
    /// the list it serves over the paired channel, never by the packer; base64 of the raw P-256 key. A phone keeps it
    /// with the list and trusts a backup folder's list only when that key signed it (BackupSignature).
    public var backupKey: String?
    /// Phase M: this phone's Always or Never per file name ("always" or "never"), set on the Mac and added by the phones'
    /// service to the list it serves that phone only; nil for any other list.
    public var choices: [String: String]?
    /// The backup's copy of the phones' inventory (beta run 2, B2-04, choice a), written only by the Mac app's backup
    /// into PrepareMe Backup's list, never by the packer or the phones' service; nil for any other list and for a backup
    /// list from before it. Kept apart from `files`, so a phone from before it, which refuses a list with a kind it
    /// doesn't know, reads the list as before (its decoder skips this key, and the signed bytes it checks are the same).
    public var inventory: Inventory?
    /// The Library's categories and placement (`LibraryShelf`, Library plan task 1.3), added by the phones' service from
    /// the Mac app's pairing folder to the list it serves, never by the packer; nil without one (the phone then uses
    /// `LibraryShelf.starting`). A phone from before it skips the key.
    public var shelf: LibraryShelf?
    /// Family downloads plan, phase 3: the names this device lets go of at its check, added by the phones' service to the
    /// list it serves that device only: the files the Mac set to Never for it, and the family downloads un-ticked on the
    /// Mac. Names only, never a title; nil for any other list. A phone from before it skips the key.
    public var drop: [String]?
    /// Audit P2h (`FileFormat`): set by the phones' service on the list it serves and by the Mac app's backup on its
    /// list, never by the packer; nil (format 1) from either before it. A phone from before it skips the key.
    public var format: Int?

    /// The phones' copy in the backup (`PhoneInventory.fileName`): its size and SHA-256, checked on the phone as a
    /// library file's are; its own time, so a phone compares copies without opening one; and `content`, the SHA-256 of
    /// the copy less its time, so the Mac copies it again only when what it holds changes (it rewrites the copy every
    /// 10 minutes with only its time changed).
    public struct Inventory: Codable, Equatable, Sendable {
        public var name: String
        public var size: Int64
        public var sha256: String
        public var writtenAt: String
        public var content: String?

        enum CodingKeys: String, CodingKey {
            case name, size, sha256, content
            case writtenAt = "written_at"
        }

        public init(name: String, size: Int64, sha256: String, writtenAt: String, content: String? = nil) {
            self.name = name
            self.size = size
            self.sha256 = sha256
            self.writtenAt = writtenAt
            self.content = content
        }

        /// Only the phones' copy's own name, a size and a SHA-256 of the right shape
        public func checked() throws {
            guard name == PhoneInventory.fileName else { throw Problem.badName(name) }
            guard size >= 0 else { throw Problem.badSize }
            guard Hex.isSHA256(sha256) else { throw Problem.badHash }
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var id: String
        public var kind: String
        public var size: Int64
        public var sha256: String
        public var deliveredAt: String
        public var libraryAsOf: String?
        public var sourcesChecked: String?
        /// A download from Kiwix's library (plan phase 8): whether the phones are offered it ("For the family"); nil
        /// or false, the Mac's alone. Its catalog title, to show in its name's place.
        public var family: Bool?
        public var title: String?
        /// Phase M (packer.fetch): "base" (every device takes it) or "room" (taken in `order` while a device keeps its
        /// reserve of free space); nil for a file taken only when asked for, and for a list from before phase M.
        public var fetch: String?
        public var order: Int?
        /// The Library card's facts, read from the file by the packer (library redesign plan 2.3): its own Description,
        /// what is inside, and where it came from; and, for an outside item (Phase 5), `origin` "outside". Each nil in a
        /// list from before them.
        public var about: String?
        public var inside: String?
        public var source: String?
        public var origin: String?

        enum CodingKeys: String, CodingKey {
            case name, id, kind, size, sha256, family, title, fetch, order, about, inside, source, origin
            case deliveredAt = "delivered_at", libraryAsOf = "library_as_of", sourcesChecked = "sources_checked"
        }

        public init(name: String, id: String, kind: String, size: Int64, sha256: String, deliveredAt: String,
                    libraryAsOf: String? = nil, sourcesChecked: String? = nil, family: Bool? = nil,
                    title: String? = nil, fetch: String? = nil, order: Int? = nil, about: String? = nil,
                    inside: String? = nil, source: String? = nil, origin: String? = nil) {
            self.name = name
            self.id = id
            self.kind = kind
            self.size = size
            self.sha256 = sha256
            self.deliveredAt = deliveredAt
            self.libraryAsOf = libraryAsOf
            self.sourcesChecked = sourcesChecked
            self.family = family
            self.title = title
            self.fetch = fetch
            self.order = order
            self.about = about
            self.inside = inside
            self.source = source
            self.origin = origin
        }

        /// Whether a phone is offered this file at all: everything but a download the Mac keeps for itself.
        public var forPhones: Bool { kind != "download" || family == true }
    }

    enum CodingKeys: String, CodingKey {
        case writtenAt = "written_at", files, backupKey = "backup_key", choices, inventory, shelf, drop, format
    }

    public init(writtenAt: String, files: [Entry], backupKey: String? = nil, choices: [String: String]? = nil,
                inventory: Inventory? = nil, format: Int? = nil) {
        self.format = format
        self.choices = choices
        self.inventory = inventory
        self.writtenAt = writtenAt
        self.files = files
        self.backupKey = backupKey
    }

    /// The kinds phase 2's manifest names.
    public static let kinds: Set<String> = ["library", "map-core", "map-optional", "download", "map"]

    public enum Problem: Error, Equatable, Sendable {
        case badName(String), badKind, badSize, badHash, twoWithOneName
        /// A list in a format newer than this build reads (`FileFormat`): nothing in it is taken.
        case newer
    }

    /// The manifest read from `data`, every entry checked; a manifest with one bad entry is refused whole, since a
    /// phone that skipped it would think the file was gone.
    public static func read(_ data: Data) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard !FileFormat.isNewer(manifest.format) else { throw Problem.newer }
        var names = Set<String>()
        for entry in manifest.files {
            try entry.checked()
            guard names.insert(entry.name).inserted else { throw Problem.twoWithOneName }
        }
        if let inventory = manifest.inventory {
            try inventory.checked()
            guard !names.contains(inventory.name) else { throw Problem.twoWithOneName }
        }
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension Manifest.Entry {
    public func checked() throws {
        guard FileName.isPlain(name) else { throw Manifest.Problem.badName(name) }
        guard Manifest.kinds.contains(kind) else { throw Manifest.Problem.badKind }
        guard size >= 0 else { throw Manifest.Problem.badSize }
        guard Hex.isSHA256(sha256) else { throw Manifest.Problem.badHash }
    }
}

/// A served file's name: letters, digits, dot, dash and underscore, not starting with a dot, at most 200 characters.
/// No slash can get through, so a name never reaches outside the served folder.
public enum FileName {
    public static func isPlain(_ name: String) -> Bool {
        guard (1...200).contains(name.utf8.count), !name.hasPrefix(".") else { return false }
        return name.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x2D || byte == 0x5F
        }
    }
}

public enum Hex {
    public static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    public static func string(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
