import Foundation

/// Downloads from Kiwix's online library (build plan phase 8; the Mac's only, owner 2026-10-14).
///
/// - Each catalog entry links a Metalink file (`.meta4`, RFC 5854) holding the file's exact size, its SHA-256 and its
///   mirrors. The catalog's own size is rounded, so the size checked is the Metalink's (2026-10-14: 333,430,784 in the
///   catalog, 333,429,922 in the Metalink, for `wikipedia_en_100`).
/// - A download is kept only once its size and SHA-256 are the Metalink's (FileCheck.verify); the reader's own look
///   (the ZIM file's checksum and ID) follows when the copy reaches `LibraryStore`, as every file's does.
/// - The kept files and their record live in Application Support › PrepareMe › downloads (`DownloadsRecord`), which
///   the Mac app alone writes and the packer reads, listing each in the manifest as kind `download`.
public struct Metalink: Equatable, Sendable {
    public let name: String
    public let size: Int64
    public let sha256: String
    /// The mirrors, best first (lowest priority number), https only.
    public let urls: [URL]

    public enum Problem: Error, Equatable {
        case unreadable, noFile, noSize, noHash, noMirror, badName
    }

    /// The first file the Metalink describes. Hashes inside `<pieces>` (per-piece SHA-1s) are not the file's and are
    /// passed over; a mirror that isn't https is left out.
    public static func parse(_ data: Data) throws -> Metalink {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { throw Problem.unreadable }
        guard let name = reader.name else { throw Problem.noFile }
        guard FileName.isPlain(name), name.hasSuffix(".zim") else { throw Problem.badName }
        guard let size = reader.size, size > 0 else { throw Problem.noSize }
        guard let sha = reader.sha256, sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw Problem.noHash }
        let urls = reader.urls.sorted { $0.0 < $1.0 }.map(\.1).filter { $0.scheme == "https" }
        guard !urls.isEmpty else { throw Problem.noMirror }
        return Metalink(name: name, size: size, sha256: sha.lowercased(), urls: urls)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var name: String?
        var size: Int64?
        var sha256: String?
        var urls: [(Int, URL)] = []
        private var files = 0
        private var inPieces = false
        private var element = ""
        private var hashType = ""
        private var priority = Int.max
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            element = name
            switch name {
            case "file":
                files += 1
                if files == 1 { self.name = attributes["name"] }
            case "pieces": inPieces = true
            case "hash": hashType = attributes["type"]?.lowercased() ?? ""
            case "url": priority = attributes["priority"].flatMap(Int.init) ?? Int.max
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard files == 1 else { return }  // the first file only
            switch name {
            case "pieces": inPieces = false
            case "size": size = Int64(value)
            case "hash" where !inPieces && hashType == "sha-256": sha256 = value
            case "url": if let url = URL(string: value) { urls.append((priority, url)) }
            default: break
            }
        }
    }
}

/// The downloads the Mac keeps (Application Support › PrepareMe › downloads › downloads.json): each file's name, its
/// catalog title, the Metalink's size and SHA-256, where it came from, whether the phones are offered it ("For the
/// family"), and when it was kept. The Mac app writes it whole (DurableFile) after a file passes its checks; the packer
/// reads it, and a file it lists that isn't there whole (the size and SHA-256 again) is left out.
public struct DownloadsRecord: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var name: String
        public var title: String
        public var size: Int64
        public var sha256: String
        public var source: String  // the Metalink's address
        public var family: Bool
        public var keptAt: String  // ISO 8601

        enum CodingKeys: String, CodingKey {
            case name, title, size, sha256, source, family, keptAt = "kept_at"
        }

        public init(name: String, title: String, size: Int64, sha256: String, source: String, family: Bool,
                    keptAt: String) {
            self.name = name
            self.title = title
            self.size = size
            self.sha256 = sha256
            self.source = source
            self.family = family
            self.keptAt = keptAt
        }
    }

    public var files: [File]

    public init(files: [File] = []) {
        self.files = files
    }

    public static let fileName = "downloads.json"

    public struct Unreadable: Error {}

    /// The record for showing; an empty one when it is missing or can't be read.
    public static func read(_ folder: URL) -> DownloadsRecord {
        (try? load(folder)) ?? DownloadsRecord()
    }

    /// The record for changing: an empty one only when there is none yet; one that can't be read throws, so a change
    /// never writes an empty record over it (phase 8 review, 5).
    public static func load(_ folder: URL) throws -> DownloadsRecord {
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return DownloadsRecord() }
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(DownloadsRecord.self, from: data) else { throw Unreadable() }
        return record
    }

    public func write(_ folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableFile.write(try encoder.encode(self), to: folder.appendingPathComponent(Self.fileName))
    }
}
