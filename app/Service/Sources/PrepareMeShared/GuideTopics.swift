import Foundation

/// The Mac app's guide groups (Mac sidebar plan, part 1): the daily library's `household/guide-topics.json`, written
/// by packer/guide_topics.py, which pins this exact shape (`checked`) and shares its fixture with the tests. The
/// reader is as strict as the writer: any other key, a repeated key, a format other than 1, a page or anchor of
/// another shape, a blank name, or a count that isn't a whole number of 0 or more is refused, and the sidebar then
/// shows Guides and New only, never an empty list.
public struct GuideTopics: Equatable, Sendable {
    public static let path = "household/guide-topics.json"
    public static let format = 1
    public static let newPage = "new-guides.html"

    public struct Sub: Equatable, Sendable {
        public let name, anchor: String
        public let count: Int
        public init(name: String, anchor: String, count: Int) {
            self.name = name
            self.anchor = anchor
            self.count = count
        }
    }

    public struct Topic: Equatable, Sendable {
        public let name, page: String
        public let count: Int
        public let subs: [Sub]
        public init(name: String, page: String, count: Int, subs: [Sub]) {
            self.name = name
            self.page = page
            self.count = count
            self.subs = subs
        }
    }

    public let newPage: String
    public let newCount: Int
    public let topics: [Topic]

    public enum Problem: Error, Equatable, Sendable { case notTheShape }

    public init(_ data: Data) throws {
        guard Self.keysAreOnceAndNumbersWhole(data),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(top.keys) == ["format", "new", "topics"],
              Self.count(top["format"]) == Self.format,
              let new = top["new"] as? [String: Any], Set(new.keys) == ["page", "count"],
              let page = new["page"] as? String, page == Self.newPage,
              let newCount = Self.count(new["count"]),
              let rows = top["topics"] as? [Any]
        else { throw Problem.notTheShape }
        self.newPage = page
        self.newCount = newCount
        self.topics = try rows.map(Self.topic)
    }

    static func topic(_ row: Any) throws -> Topic {
        guard let object = row as? [String: Any], Set(object.keys) == ["name", "page", "count", "subs"],
              let name = object["name"] as? String, Self.named(name),
              let page = object["page"] as? String, Self.matches(page, "topic-[a-z0-9-]+\\.html"),
              let count = Self.count(object["count"]),
              let subs = object["subs"] as? [Any]
        else { throw Problem.notTheShape }
        return Topic(name: name, page: page, count: count, subs: try subs.map(Self.sub))
    }

    static func sub(_ row: Any) throws -> Sub {
        guard let object = row as? [String: Any], Set(object.keys) == ["name", "anchor", "count"],
              let name = object["name"] as? String, Self.named(name),
              let anchor = object["anchor"] as? String, Self.matches(anchor, "[a-z0-9-]+"),
              let count = Self.count(object["count"])
        else { throw Problem.notTheShape }
        return Sub(name: name, anchor: anchor, count: count)
    }

    static func named(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A JSON whole number of 0 or more (not a boolean, which JSONSerialization also hands back as an NSNumber).
    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue), number.intValue >= 0
        else { return nil }
        return number.intValue
    }

    /// The whole text must match, as Python's fullmatch does (a trailing newline is no match).
    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) == text.startIndex..<text.endIndex
    }

    /// Whether no object names a key twice (JSONSerialization keeps the last) and every number is a plain integer
    /// (a 1.0 or 1e2 is a float to the writer's reader, so it is refused here too). A scan of the text, outside
    /// the strings: it tracks each object's keys apart, since "name" legitimately repeats between objects.
    static func keysAreOnceAndNumbersWhole(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        // One entry per open container: the keys an object has named so far, or nil for a list.
        var open: [Set<String>?] = []
        var expectKey = false
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            switch byte {
            case UInt8(ascii: "{"):
                open.append([])
                expectKey = true
            case UInt8(ascii: "["):
                open.append(nil)
                expectKey = false
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if !open.isEmpty { open.removeLast() }
                expectKey = false
            case UInt8(ascii: ","):
                expectKey = open.last.map { $0 != nil } ?? false
            case UInt8(ascii: "\""):
                var j = i + 1
                while j < bytes.count, bytes[j] != UInt8(ascii: "\"") {
                    j += bytes[j] == UInt8(ascii: "\\") ? 2 : 1
                }
                guard j < bytes.count else { return true }  // unterminated: JSONSerialization refuses it
                if expectKey, var keys = open.last.flatMap({ $0 }) {
                    let key = String(decoding: bytes[(i + 1)..<j], as: UTF8.self)
                    if !keys.insert(key).inserted { return false }
                    open[open.count - 1] = keys
                    expectKey = false
                }
                i = j
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: ":"):
                break
            default:
                // A bare word: a number, true, false or null. A number with a point or an exponent is no integer.
                var j = i
                while j < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                                        UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\t"),
                                        UInt8(ascii: "\r")].contains(bytes[j]) { j += 1 }
                let word = bytes[i..<j]
                if let first = word.first, first == UInt8(ascii: "-") || (48...57).contains(first),
                   word.contains(where: { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }) {
                    return false
                }
                i = j - 1
            }
            i += 1
        }
        return true
    }
}
