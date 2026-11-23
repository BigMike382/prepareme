import Foundation

/// The Other Sites files kept on the Mac (library redesign, Task 5.2): `outside.json` in the downloads folder, beside
/// Kiwix's `downloads.json`, and each PDF at `outside/<key>.pdf`. The Mac app alone writes it; the packer reads it and
/// packs each into a collection of its own, `outside-<key>.zim`, listed as a download.
public struct OutsideRecord: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var key: String
        public var title: String
        public var size: Int64
        public var sha256: String
        public var family: Bool
        public var keptAt: String  // ISO 8601

        enum CodingKeys: String, CodingKey {
            case key, title, size, sha256, family, keptAt = "kept_at"
        }

        public init(key: String, title: String, size: Int64, sha256: String, family: Bool, keptAt: String) {
            self.key = key
            self.title = title
            self.size = size
            self.sha256 = sha256
            self.family = family
            self.keptAt = keptAt
        }
    }

    public var files: [File]

    public init(files: [File] = []) {
        self.files = files
    }

    public static let fileName = "outside.json"
    public static let folderName = "outside"

    /// The packed collection's file name, as the manifest and the Library know it.
    public static func packedName(_ key: String) -> String { "outside-\(key).zim" }

    /// The key a packed collection's name carries, or nil for any other name.
    public static func key(packedName name: String) -> String? {
        guard name.hasPrefix("outside-"), name.hasSuffix(".zim") else { return nil }
        let key = String(name.dropFirst("outside-".count).dropLast(".zim".count))
        return key.isEmpty ? nil : key
    }

    /// For showing: an empty record when it's missing or can't be read.
    public static func read(_ folder: URL) -> OutsideRecord {
        (try? load(folder)) ?? OutsideRecord()
    }

    /// For changing: empty only when there is none yet; one that can't be read throws, so nothing writes over it.
    public static func load(_ folder: URL) throws -> OutsideRecord {
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return OutsideRecord() }
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(OutsideRecord.self, from: data) else {
            throw DownloadsRecord.Unreadable()
        }
        return record
    }

    public func write(_ folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableFile.write(try encoder.encode(self), to: folder.appendingPathComponent(Self.fileName))
    }
}
