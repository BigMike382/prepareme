import Foundation

/// What a search result is, shown on it in place of Kiwix's library icon (owner, 2026-10-21): our pages show their
/// group's emoji, the guide list's (`MacLook.emoji`), and a kind word; a result from any other library shows that
/// library's plain name (`HomeMacWords.plainLibraryTitle`). The word always says it, so nothing rests on the emoji or
/// a color alone, and the red night screen, which turns every emoji red, loses nothing.
public struct SearchMark: Equatable, Sendable {
    /// The group's emoji, or the maps' (the front page's Maps button's, packer MAPS_EMOJI)
    public let emoji: String?
    /// A group without an emoji (Other, For adults): its symbol in the sidebar (`MacLook.symbol`)
    public let symbol: String?
    /// Guide, Walk-through, Household page, Map page, Map, or the library's plain name
    public let word: String
    /// The guide list's group, which VoiceOver says after the word, as the emoji isn't read
    public let group: String?

    public init(emoji: String? = nil, symbol: String? = nil, word: String, group: String? = nil) {
        self.emoji = emoji
        self.symbol = symbol
        self.word = word
        self.group = group
    }

    public static let guide = "Guide"
    public static let walkthrough = "Walk-through"
    public static let householdPage = "Our Home"  // "Household page" until Our Home phase 1 (2026-11-16)
    public static let mapPage = "Map page"
    public static let map = "Map"
    public static let mapsEmoji = "🗺️"
    /// packer.guide_topics' HOUSEHOLD_TOPIC: the household's own pages, never a library guide
    public static let household = "Our Home"

    /// The library a result was found in
    public enum Library: Equatable, Sendable {
        /// The daily library: its pages' groups (`groups(…)`) and its ZIM title
        case guides(groups: [String: String], title: String)
        /// A map file (prepareme-maps-…): its pages and its PDFs
        case maps
        /// Any other library (references, videos, manuals, a Wikipedia download), by its ZIM title
        case other(title: String)
    }

    /// The mark for a result at `path` in `library`. A walk-through takes `walkthroughGroup`, its guide's group
    /// (`walkthroughGroup(links:groups:)`). A page of the daily library no group lists (Today, the guide list) shows the
    /// library's plain name, as another library's result would.
    public static func mark(path: String, in library: Library, walkthroughGroup: String? = nil) -> SearchMark {
        switch library {
        case .maps:
            return SearchMark(emoji: mapsEmoji, word: path.lowercased().hasSuffix(".pdf") ? map : mapPage)
        case let .other(title):
            return SearchMark(word: plainName(title))
        case let .guides(groups, title):
            if isWalkthrough(path) {
                return SearchMark(emoji: walkthroughGroup.flatMap(MacLook.emoji),
                                  symbol: walkthroughGroup.flatMap { MacLook.emoji($0) == nil ? MacLook.symbol($0) : nil },
                                  word: walkthrough, group: walkthroughGroup)
            }
            guard let group = groups[path] else { return SearchMark(word: plainName(title)) }
            let emoji = MacLook.emoji(group)
            return SearchMark(emoji: emoji, symbol: emoji == nil ? MacLook.symbol(group) : nil,
                              word: MacLook.current(group).lowercased() == household.lowercased() ? householdPage : guide, group: group)
        }
    }

    /// A library's plain name, or "Library" for one without a title, so a mark never goes without a word
    static func plainName(_ title: String) -> String {
        let plain = HomeMacWords.plainLibraryTitle(title.trimmingCharacters(in: .whitespacesAndNewlines))
        return plain.isEmpty ? "Library" : plain
    }

    /// What VoiceOver reads after the title: the word, then the group for a guide or a walk-through
    public var spoken: String {
        guard let group, word == Self.guide || word == Self.walkthrough else { return word }
        return "\(word), \(group)"
    }

    /// packer.walkthroughs' PAGE and KIDS_PAGE: walkthrough-<id>.html and walkthrough-<id>-kids.html
    public static func isWalkthrough(_ path: String) -> Bool {
        path.range(of: "walkthrough-[a-z0-9-]+\\.html", options: .regularExpression)
            == path.startIndex..<path.endIndex
    }

    /// Each page's group from the daily library's category pages (GuideTopics' topic pages, packer build's
    /// _category_page), which list every page of the guide list exactly once, under its group; `page` reads one
    /// (nil when it can't). A page listed twice keeps its first group.
    public static func groups(_ topics: GuideTopics, page: @Sendable (String) async -> String?) async -> [String: String] {
        var found: [String: String] = [:]
        for topic in topics.topics {
            guard let html = await page(topic.page) else { continue }
            for listed in listed(html) where found[listed] == nil { found[listed] = topic.name }
        }
        return found
    }

    /// The pages a category page lists: its list items' links (`<li><a href="…">`, packer build's _guide_links), never
    /// its other links (back to the guide list)
    public static func listed(_ html: String) -> [String] {
        matches(html, "<li><a href=\"([^\"]+)\"")
    }

    /// A walk-through's group: the group of the first page it links that a group lists (its guide; the last step links
    /// the whole guide), nil when it links none
    public static func walkthroughGroup(links html: String, groups: [String: String]) -> String? {
        matches(html, "href=\"([^\"#?]+)").lazy.compactMap { groups[$0] }.first
    }

    static func matches(_ html: String, _ pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: whole).compactMap { match in
            Range(match.range(at: 1), in: html).map { HTMLText.unescaped(String(html[$0])) }
        }
    }
}
