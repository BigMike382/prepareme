import CryptoKit
import Foundation
import PrepareMeShared

/// The paired phones (`tokens.json` in the service's folder): each phone's label ("phone 1"), when it was paired, and
/// the SHA-256 of its token, never the token itself. Read at every request, so a phone paired or unpaired while the
/// service runs counts at once.
public struct TokenStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public struct Phone: Codable, Equatable, Sendable {
        public var label: String
        public var sha256: String
        public var added: String
        /// Plan phase 7: a phone that reads the inventory but sends no edits (a child's). Absent: an adult's phone,
        /// as every phone paired before it was.
        public var readOnly: Bool?
        /// Task 13.2 (F42): true from pairing until the phone's code first comes back; absent once it has, and for a
        /// phone paired before visits were kept.
        public var waiting: Bool?
    }

    struct File: Codable {
        var phones: [Phone]
    }

    public func phones() throws -> [Phone] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).phones
    }

    /// A new phone: the next free "phone N" and a fresh token, which is returned once and never stored.
    public func add(now: Date, readOnly: Bool = false) throws -> (label: String, token: String) {
        try exclusive { try addLocked(now: now, readOnly: readOnly) }
    }

    private func addLocked(now: Date, readOnly: Bool) throws -> (label: String, token: String) {
        var phones = try phones()
        let taken = Set(phones.map(\.label))
        let label = (1...).lazy.map { "phone \($0)" }.first { !taken.contains($0) }!
        let token = Token.make()
        phones.append(Phone(label: label, sha256: Self.digest(token), added: ISO.now(now),
                            readOnly: readOnly ? true : nil, waiting: true))
        try save(phones)
        return (label, token)
    }

    /// A phone's request came with its code: a first visit stops it waiting (written once, never again after).
    public func visited(_ phone: Phone) throws {
        guard phone.waiting == true else { return }
        try exclusive { try visitedLocked(phone) }
    }

    private func visitedLocked(_ phone: Phone) throws {
        var phones = try phones()
        guard let index = phones.firstIndex(where: { $0.label == phone.label && $0.sha256 == phone.sha256 }) else {
            return
        }
        phones[index].waiting = nil
        try save(phones)
    }

    public func remove(label: String) throws -> Bool {
        try exclusive { try removeLocked(label: label) }
    }

    /// One writer at a time (the phase 13 review): the request queue's visits, the pairing clerk's pairings and
    /// removals, and the CLI's pair and unpair in another process, each reading the whole list and writing it back, so
    /// a write between another's read and write would undo it. A lock in this process and an flock on a file beside
    /// the list for the others; a lock file that can't be opened leaves the in-process lock alone.
    private static let inProcess = NSLock()

    private func exclusive<T>(_ work: () throws -> T) throws -> T {
        Self.inProcess.lock()
        defer { Self.inProcess.unlock() }
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try work() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try work()
    }

    private func removeLocked(label: String) throws -> Bool {
        var phones = try phones()
        let before = phones.count
        phones.removeAll { $0.label == label }
        guard phones.count != before else { return false }
        try save(phones)
        return true
    }

    /// The label of the phone whose token this is; nil for a token no phone holds. A list that can't be read lets no
    /// one in.
    public func label(for token: String) -> String? {
        phone(for: token)?.label
    }

    /// The phone whose token this is; nil for a token no phone holds.
    public func phone(for token: String) -> Phone? {
        guard Token.isWellFormed(token), let phones = try? phones() else { return nil }
        let presented = Array(Self.digest(token).utf8)
        var found: Phone?
        for phone in phones where Self.same(Array(phone.sha256.utf8), presented) {
            found = phone
        }
        return found
    }

    func save(_ phones: [Phone]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableFile.write(encoder.encode(File(phones: phones)), to: url)
    }

    static func digest(_ token: String) -> String {
        Hex.string(SHA256.hash(data: Data(token.utf8)))
    }

    /// Equal without stopping at the first difference.
    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The phones' alert counts (`probe-counts.json` beside the dashboard's run records, plan section 9): per phone label,
/// each reading's time, whether it read, its three counts and when the Mac received it. A second post for the same
/// minute replaces the first; readings older than 30 days are dropped. Saved whole at every post.
public final class CountsStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    public static let keepDays = 30.0

    public init(url: URL) {
        self.url = url
    }

    public struct Reading: Codable, Equatable, Sendable {
        public var at: String
        public var read: Bool
        public var alerts: Int?
        public var events: Int?
        public var noVTEC: Int?
        public var received: String

        enum CodingKeys: String, CodingKey {
            case at, read, alerts, events, received
            case noVTEC = "no_vtec"
        }
    }

    struct File: Codable {
        var phones: [String: [Reading]]
    }

    public func add(_ report: CountsReport, from label: String, now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        var file = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url))) ?? File(phones: [:])
        let oldest = CountsReport.minute(now.addingTimeInterval(-Self.keepDays * 86400))
        var readings = (file.phones[label] ?? []).filter { $0.at != report.at && $0.at >= oldest }
        readings.append(Reading(at: report.at, read: report.read, alerts: report.alerts, events: report.events,
                                noVTEC: report.noVTEC, received: ISO.now(now)))
        readings.sort { $0.at < $1.at }
        file.phones[label] = readings
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFile.write(encoder.encode(file), to: url)
    }

    public func readings() -> [String: [Reading]] {
        lock.lock()
        defer { lock.unlock() }
        return ((try? JSONDecoder().decode(File.self, from: Data(contentsOf: url))) ?? File(phones: [:])).phones
    }
}

/// The phones' feed counts (`phone-feed-counts.json` beside the dashboard's run records, plan phase 5): per phone
/// label, each report as it came (its minute, its feeds' counts, the feeds it couldn't read) and when the Mac received
/// it. A second post for the same minute replaces the first; reports older than 30 days are dropped. Saved whole.
public final class FeedCountsStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public struct Reading: Codable, Equatable, Sendable {
        public var at: String
        public var feeds: [String: [String: Int]]
        public var unread: [String]
        public var received: String
    }

    struct File: Codable {
        var phones: [String: [Reading]]
    }

    public func add(_ report: FeedCountsReport, from label: String, now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        var file = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url))) ?? File(phones: [:])
        let oldest = CountsReport.minute(now.addingTimeInterval(-CountsStore.keepDays * 86400))
        var readings = (file.phones[label] ?? []).filter { $0.at != report.at && $0.at >= oldest }
        readings.append(Reading(at: report.at, feeds: report.feeds, unread: report.unread, received: ISO.now(now)))
        readings.sort { $0.at < $1.at }
        file.phones[label] = readings
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFile.write(encoder.encode(file), to: url)
    }

    public func readings() -> [String: [Reading]] {
        lock.lock()
        defer { lock.unlock() }
        return ((try? JSONDecoder().decode(File.self, from: Data(contentsOf: url))) ?? File(phones: [:])).phones
    }
}

public enum ISO {
    public static func now(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
