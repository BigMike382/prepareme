import Foundation

/// Links between a guide and the house's things (remaining-findings plan, phase 14; F57; the owner's choices,
/// 2026-10-19). The daily library's `household/guide-links.json`, written by packer/guide_links.py from
/// packer/guide_links.toml (pinned by the shared fixture guide-links.json), lists each guide with item words. An item
/// whose name holds one of a guide's words links to it ("How to use it"); a guide's "In the house" link
/// (prepareme://inventory?for=<title>&words=<words>) opens the items whose names hold one of its words. The reader is
/// as strict as the writer, so a list of any other shape is refused and items show no guide links.
public struct GuideLinks: Equatable, Sendable {
    public static let path = "household/guide-links.json"
    public static let format = 1
    /// The app's own words, pinned in GuideLinksTests (the guide page's link is packer.guide_links.HOUSE_LINK, pinned in
    /// packer's tests)
    public static let howToUse = "How to use it"
    public static let houseTitle = "In the House"
    public static let noneInTheHouse = "Nothing in the inventory matches this guide's things yet."

    public struct Guide: Equatable, Sendable {
        public let page, title: String
        public let words: [String]
        public init(page: String, title: String, words: [String]) {
            self.page = page
            self.title = title
            self.words = words
        }
    }

    public let guides: [Guide]

    public enum Problem: Error, Equatable, Sendable { case notTheShape }

    public init(guides: [Guide]) { self.guides = guides }

    public init(_ data: Data) throws {
        guard GuideTopics.keysAreOnceAndNumbersWhole(data),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(top.keys) == ["format", "guides"],
              GuideTopics.count(top["format"]) == Self.format,
              let rows = top["guides"] as? [Any]
        else { throw Problem.notTheShape }
        guides = try rows.map(Self.guide)
    }

    static func guide(_ row: Any) throws -> Guide {
        guard let object = row as? [String: Any], Set(object.keys) == ["page", "title", "words"],
              let page = object["page"] as? String, GuideTopics.matches(page, "[a-z0-9-]+\\.html"),
              let title = object["title"] as? String, GuideTopics.named(title),
              let words = object["words"] as? [String], !words.isEmpty, Set(words).count == words.count,
              words.allSatisfy(Self.isWord)
        else { throw Problem.notTheShape }
        return Guide(page: page, title: title, words: words)
    }

    /// packer.guide_links.WORD: lowercase letters and digits, words joined by single spaces, 3 characters or more.
    static func isWord(_ word: String) -> Bool {
        word.count >= 3 && GuideTopics.matches(word, "[a-z0-9]+( [a-z0-9]+)*")
    }

    /// The guides an item's name holds a word of, in the list's order.
    public func guides(forItem name: String) -> [Guide] {
        guides.filter { Self.matches(name, $0.words) }
    }

    /// Whether `name` holds one of `words`: each a run of whole words in the name, any case or accent, its last word
    /// also with a plural "s" or "es" ("map" finds "Road maps", never "Maple syrup").
    public static func matches(_ name: String, _ words: [String]) -> Bool {
        let held = tokens(name)
        return words.contains { word in
            let want = tokens(word)
            guard !want.isEmpty, want.count <= held.count else { return false }
            return (0...(held.count - want.count)).contains { start in
                zip(want.indices, want).allSatisfy { i, part in
                    let got = held[start + i]
                    return got == part || (i == want.count - 1 && (got == part + "s" || got == part + "es"))
                }
            }
        }
    }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// A guide's "In the house" link: its title and words, or nil for any other link. A word the reader would refuse
    /// is dropped; a link left with none is nil.
    public static func houseLink(_ url: URL) -> (title: String, words: [String])? {
        guard url.scheme == "prepareme", url.host == "inventory",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let title = items.first(where: { $0.name == "for" })?.value, GuideTopics.named(title),
              let joined = items.first(where: { $0.name == "words" })?.value
        else { return nil }
        let words = joined.split(separator: ",").map(String.init).filter(isWord)
        return words.isEmpty ? nil : (title, words)
    }
}
