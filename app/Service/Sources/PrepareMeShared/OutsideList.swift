import Foundation

/// The Other Sites list (library redesign, phase 5): single PDFs from trusted sites, each with the size and SHA-256 it
/// had when a session vetted it. The daily library carries it as `household/outside-list.json` (written by
/// librarian/outside.py's `list_json`); the Mac's Add to Library › Other Sites reads it and downloads against it.
/// A list in another format, or with one entry that isn't the expected shape, is refused whole.
public struct OutsideList: Codable, Equatable, Sendable {
    public static let path = "household/outside-list.json"
    public static let format = 1

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var key: String
        public var title: String
        public var description: String
        public var page: String
        public var url: String
        public var host: String
        public var license: String
        public var size: Int64
        public var sha256: String
        public var kind: String
        public var category: String
        public var vetted: String

        public var id: String { key }

        public init(key: String, title: String, description: String, page: String, url: String, host: String,
                    license: String, size: Int64, sha256: String, kind: String, category: String, vetted: String) {
            self.key = key
            self.title = title
            self.description = description
            self.page = page
            self.url = url
            self.host = host
            self.license = license
            self.size = size
            self.sha256 = sha256
            self.kind = kind
            self.category = category
            self.vetted = vetted
        }

        /// The packer's own checks, again on this side: the key names a file, so it must be plain. `loopback` lets the
        /// Mac check build's made-up item come over http from 127.0.0.1 (plan 5.4's check), and nothing else.
        func isWhole(loopback: Bool = false) -> Bool {
            let keyChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
            guard let file = URL(string: url) else { return false }
            let local = loopback && file.scheme == "http" && file.host == "127.0.0.1"
            guard (1...60).contains(key.count), key.unicodeScalars.allSatisfy(keyChars.contains),
                  file.scheme == "https" || local, file.host?.lowercased() == host,
                  size > 0, kind == "pdf", sha256.count == 64,
                  sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
            return true
        }
    }

    public struct Refused: Error {}

    public var format: Int
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.format = Self.format
        self.entries = entries
    }

    /// The entry for a kept file or a stopped download: the same key and the same vetted file (phase 5 review).
    public func entry(key: String, sha256: String) -> Entry? {
        entries.first { $0.key == key && $0.sha256 == sha256 }
    }

    /// A kept file the list no longer vets (dropped, or re-checked since), so the packer leaves it off the phones. A
    /// list that couldn't be read (nil) drops nothing, as the packer then changes nothing.
    public static func dropped(key: String, sha256: String, from list: OutsideList?) -> Bool {
        guard let list else { return false }
        return list.entry(key: key, sha256: sha256) == nil
    }

    /// What Resume does with a stopped Other Sites download (phase 6 review).
    public enum Resume: Equatable, Sendable {
        case entry(Entry)  // still vetted as it was: resume with the current entry
        case notListed  // dropped, or re-checked since
        case listUnread  // the list couldn't be read: try later, never "discard"
    }

    public static func resume(key: String, sha256: String, list: OutsideList?) -> Resume {
        guard let list else { return .listUnread }
        return list.entry(key: key, sha256: sha256).map { .entry($0) } ?? .notListed
    }

    public static func decode(_ data: Data, loopback: Bool = false) throws -> OutsideList {
        let list = try JSONDecoder().decode(OutsideList.self, from: data)
        guard list.format == format, list.entries.allSatisfy({ $0.isWhole(loopback: loopback) }),
              Set(list.entries.map(\.key)).count == list.entries.count else { throw Refused() }
        return list
    }
}
