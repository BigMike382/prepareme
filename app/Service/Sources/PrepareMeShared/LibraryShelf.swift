import Foundation

/// The Library's shelf (owner, 2026-11-12: docs/superpowers/specs/2026-11-12-library-section-design.md): the
/// categories the files besides the daily library are sorted into, each with a name and an emoji, and the category
/// each file was placed in, by `key` (its name without the date, so a newer edition keeps its place). The Mac app keeps
/// it in its pairing folder (`fileName`) and is the only one that edits it; the Mac's service adds it to the manifest
/// each phone reads (`Manifest.shelf`). A file nobody placed falls to the starting table by its key's prefix, else
/// it needs a category (`unsorted`): never lost.
public struct LibraryShelf: Codable, Equatable, Sendable {
    public struct Category: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public var name: String
        /// A subcategory's own emoji is empty: it shows its category's (`emoji(of:)`).
        public var emoji: String
        /// The category a subcategory sits under (library redesign plan 4.1: one level); nil for a category, and in
        /// every shelf written before subcategories.
        public var parent: String?

        public init(id: String, name: String, emoji: String, parent: String? = nil) {
            self.id = id
            self.name = name
            self.emoji = emoji
            self.parent = parent
        }
    }

    /// One file on the shelf, as the screens show it.
    public struct Item: Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let key: String
        /// From Kiwix's catalog (the manifest's kind `download`): what Remove… keys off (its "not checked" label went in
        /// library redesign plan 3.1).
        public let notChecked: Bool
        /// When its first edition reached this device; nil when unknown (never New).
        public let arrived: Date?
        /// The card's facts from the manifest (library redesign plan 2.3): the file's own Description, what's inside,
        /// where it came from; nil when the packer had none.
        public let about: String?
        public let inside: String?
        public let source: String?
        /// Whether the phones get it: every one of our own volumes, a download only when it's For the family.
        public let family: Bool
        /// A file the Mac offers this device that it doesn't hold (family downloads plan, phase 5): the Mac's entry,
        /// for its Not downloaded card and Download; nil for a held file.
        public let offer: Manifest.Entry?

        public init(id: UUID, title: String, key: String, notChecked: Bool, arrived: Date?, about: String? = nil,
                    inside: String? = nil, source: String? = nil, family: Bool = true, offer: Manifest.Entry? = nil) {
            self.id = id
            self.title = title
            self.key = key
            self.notChecked = notChecked
            self.arrived = arrived
            self.about = about
            self.inside = inside
            self.source = source
            self.family = family
            self.offer = offer
        }
    }

    /// In the order they show.
    public var categories: [Category]
    /// File key → category id.
    public var placed: [String: String]
    /// File key → the owner's own description (library redesign plan 2.4), in place of the file's on every device.
    public var descriptions: [String: String]

    public init(categories: [Category], placed: [String: String] = [:], descriptions: [String: String] = [:]) {
        self.categories = categories
        self.placed = placed
        self.descriptions = descriptions
    }

    enum CodingKeys: String, CodingKey { case categories, placed, descriptions }

    /// A shelf written before descriptions has none (and reads as before otherwise).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = try c.decode([Category].self, forKey: .categories)
        placed = try c.decode([String: String].self, forKey: .placed)
        descriptions = try c.decodeIfPresent([String: String].self, forKey: .descriptions) ?? [:]
    }

    public static let fileName = "library-shelf.json"
    /// Where Later on the Mac's Which category? places a file: no category's id, so it shows under Needs a category
    /// even when the starting set would place it, until it's moved.
    public static let needsCategory = ""

    /// A file's name without `.zim` and a trailing `_YYYY-MM` or `_YYYY-MM-DD` (Kiwix's edition date).
    public static func key(fileName: String) -> String {
        var stem = fileName.hasSuffix(".zim") ? String(fileName.dropLast(4)) : fileName
        if let range = stem.range(of: #"_\d{4}-\d{2}(-\d{2})?$"#, options: .regularExpression) {
            stem.removeSubrange(range)
        }
        return stem
    }

    public static let starting = LibraryShelf(categories: [
        Category(id: "medical", name: "Medical", emoji: "⛑️"),  // Guides' Medical (dashboard.emoji.GROUP_EMOJI): 🩺 drew faint
        Category(id: "vehicles", name: "Vehicles and Repair", emoji: "🔧"),
        Category(id: "food", name: "Food and Garden", emoji: "🥫"),
        Category(id: "water", name: "Water and Shelter", emoji: "💧"),
        Category(id: "skills", name: "Skills", emoji: "🪢"),
        Category(id: "animals", name: "Animals", emoji: "🐾"),
        Category(id: "reference", name: "Reference", emoji: "📚"),
    ])

    /// The starting placement, by key prefix (a collection's flavor, such as `_maxi`, varies): our own volumes and the
    /// 2026-11-08 sources evaluation's collections.
    static let startingPrefixes: [(prefix: String, category: String)] = [
        ("prepareme-reference", "medical"), ("prepareme-vehicles", "vehicles"), ("prepareme-item-manuals", "vehicles"),
        ("prepareme-media", "skills"), ("mechanics.stackexchange.com", "vehicles"), ("medlineplus.gov", "medical"),
        ("irp.fas.org_en_military-medicine", "medical"), ("usda-2015", "food"), ("cooking.stackexchange.com", "food"),
        ("gardening.stackexchange.com", "food"), ("zimgit-water", "water"), ("appropedia", "water"),
        ("zimgit-knots", "skills"), ("phet", "skills"), ("wikivet", "animals"), ("wikipedia", "reference"),
    ]

    /// A new category's icon is one of these (owner, 2026-11-12: an emoji, as Guides' categories have).
    public static let emojiGrid = ["⛑️", "💊", "🚑", "🔧", "🚗", "🛠️", "🥫", "🌱", "🍳", "💧", "🏕️", "🔥",
                                   "🪢", "⚡", "📻", "🐾", "🐔", "📚", "🗺️", "🧭", "🌦️", "👶", "🛡️", "📖"]

    /// The shelf in a file; nil when missing or unreadable.
    public static func read(_ data: Data?) -> LibraryShelf? {
        data.flatMap { try? JSONDecoder().decode(LibraryShelf.self, from: $0) }
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(self)) ?? Data()
    }

    // MARK: Grouping

    /// The category a file sits in: where it was placed, else the starting table's, as long as that category still
    /// exists; nil when it needs one.
    public func category(for key: String) -> String? {
        // a subcategory whose category is gone (a hand-edited file) holds nothing: its collections are unsorted
        let tops = Set(categories.filter { $0.parent == nil }.map(\.id))
        let exists = Set(categories.filter { $0.parent.map(tops.contains) ?? true }.map(\.id))
        if let id = placed[key] { return exists.contains(id) ? id : nil }
        return Self.startingPrefixes.first { key.hasPrefix($0.prefix) }.map(\.category).flatMap {
            exists.contains($0) ? $0 : nil
        }
    }

    /// The top-level categories in order, only those holding an item themselves or in a subcategory, each with its
    /// own items by title (its subcategories' are `subGroups`).
    public func grouped(_ items: [Item]) -> [(category: Category, items: [Item])] {
        let byCategory = holding(items)
        return categories.filter { $0.parent == nil }.compactMap { category in
            let own = byCategory[category.id] ?? []
            guard !own.isEmpty || children(of: category.id).contains(where: { byCategory[$0.id] != nil }) else {
                return nil
            }
            return (category, own)
        }
    }

    /// A category's subcategories in order, only those holding an item, each one's items by title.
    public func subGroups(_ items: [Item], in id: String) -> [(category: Category, items: [Item])] {
        let byCategory = holding(items)
        return children(of: id).compactMap { sub in byCategory[sub.id].map { (sub, $0) } }
    }

    /// The items a category or subcategory holds itself, by title (a category page's loose cards, a folder's cards).
    public func own(_ items: [Item], in id: String) -> [Item] {
        holding(items)[id] ?? []
    }

    /// How many items a category holds, its subcategories' included (its tile's count).
    public func total(_ items: [Item], in id: String) -> Int {
        let ids = Set([id] + children(of: id).map(\.id))
        return items.filter { category(for: $0.key).map(ids.contains) ?? false }.count
    }

    /// Category id → the items it holds itself, by title.
    private func holding(_ items: [Item]) -> [String: [Item]] {
        Dictionary(grouping: items.compactMap { item in category(for: item.key).map { ($0, item) } }, by: \.0)
            .mapValues { $0.map(\.1).sorted(by: Self.byTitle) }
    }

    // MARK: Subcategories (library redesign plan 4.1: one level)

    /// A category's subcategories, in order.
    public func children(of id: String) -> [Category] {
        categories.filter { $0.parent == id }
    }

    /// The top-level category whose page shows this one: a subcategory's parent, else itself.
    public func top(of id: String) -> String {
        categories.first { $0.id == id }?.parent ?? id
    }

    /// The emoji a category or subcategory shows: a subcategory's is its category's.
    public func emoji(of id: String) -> String {
        guard let category = categories.first(where: { $0.id == id }) else { return "" }
        return category.parent.flatMap { parent in categories.first { $0.id == parent }?.emoji } ?? category.emoji
    }

    /// Where a category sits, in words: "📖 Books", or "📖 Books › Homesteading" for a subcategory; empty if unknown.
    public func path(of id: String) -> String {
        guard let category = categories.first(where: { $0.id == id }) else { return "" }
        guard let parent = category.parent.flatMap({ parent in categories.first { $0.id == parent } }) else {
            return "\(category.emoji) \(category.name)"
        }
        return "\(parent.emoji) \(parent.name) › \(category.name)"
    }

    /// A new subcategory at the end of its category's, and its id; nil for an unusable name, a name one of its
    /// siblings has, or a parent that's missing or itself a subcategory.
    public func addingSub(name: String, to parent: String) -> (LibraryShelf, String)? {
        guard categories.contains(where: { $0.id == parent && $0.parent == nil }),
              let name = usableName(name, parent: parent) else { return nil }
        var shelf = self
        let id = uniqueID(parent + "-" + Self.slug(name))
        let at = (categories.lastIndex { $0.id == parent || $0.parent == parent } ?? categories.count - 1) + 1
        shelf.categories.insert(Category(id: id, name: name, emoji: "", parent: parent), at: at)
        return (shelf, id)
    }

    /// The items no category holds: they show under Needs a category.
    public func unsorted(_ items: [Item]) -> [Item] {
        items.filter { category(for: $0.key) == nil }.sorted(by: Self.byTitle)
    }

    /// New: first arrived within the last 30 days, newest first.
    public static func newItems(_ items: [Item], now: Date) -> [Item] {
        let since = now.addingTimeInterval(-30 * 86_400)
        return items.filter { ($0.arrived ?? .distantPast) >= since }
            .sorted { ($0.arrived ?? .distantPast) > ($1.arrived ?? .distantPast) }
    }

    /// The device's files besides the daily one (`MacLibraries.others`), as shelf items.
    public static func items(_ held: [String: HeldFile], dailyFile: String, arrived: (HeldFile) -> Date?,
                             named: (UUID) -> String?) -> [Item] {
        let byID = Dictionary(held.values.map { ($0.entry.id.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return MacLibraries.others(held, dailyFile: dailyFile, named: named).compactMap { other in
            guard let file = byID[other.id.uuidString] else { return nil }
            let entry = file.entry
            return Item(id: other.id, title: other.title, key: key(fileName: entry.name),
                        notChecked: entry.kind == "download", arrived: arrived(file), about: entry.about,
                        inside: entry.inside, source: entry.source, family: entry.forPhones)
        }
    }

    /// The family downloads the Mac offers this device and it doesn't hold, as shelf items with their entry (family
    /// downloads plan, phase 5); a file downloading is still one, until it is held.
    public static func offered(_ state: LibraryRecord, dailyFile: String) -> [Item] {
        let heldIDs = Set(state.held.values.map { $0.entry.id.uppercased() })
        return (state.manifest?.files ?? []).compactMap { entry in
            guard entry.kind == "download", entry.forPhones, entry.name.hasSuffix(".zim"),
                  ![dailyFile, MacLibraries.gamesFile].contains(entry.name), state.held[entry.name] == nil,
                  !heldIDs.contains(entry.id.uppercased()), let id = UUID(uuidString: entry.id) else { return nil }
            return Item(id: id, title: HomeMacWords.title(entry), key: key(fileName: entry.name), notChecked: true,
                        arrived: nil, about: entry.about, inside: entry.inside, source: entry.source, offer: entry)
        }
        .sorted(by: byTitle)
    }

    // MARK: Descriptions (library redesign plan 2.4)

    /// The most an owner's description keeps.
    public static let descriptionLimit = 160

    /// The owner's description for a file, trimmed and cut to the limit; nil or blank goes back to the file's own.
    public func describing(key: String, as text: String?) -> LibraryShelf {
        var new = self
        // one line on every card: new lines and runs of spaces become one space
        let trimmed = (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        new.descriptions[key] = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.descriptionLimit))
        return new
    }

    /// What a card says about a file: the owner's description, else the file's own (`original`). The one fallback the
    /// card, the picker and the editor share (phase 2 review).
    public func description(for item: Item, recorded: String? = nil) -> String? {
        descriptions[item.key] ?? Self.original(item, recorded: recorded)
    }

    /// The file's own line: the manifest's, else Kiwix's record of it (`recorded`) until the packer's next run gives
    /// the manifest one; an empty line is none.
    public static func original(_ item: Item, recorded: String?) -> String? {
        (item.about ?? recorded).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: The owner's edits (Mac only; Library plan, phase 3)

    /// A category's name: 1 to 20 characters once trimmed (as a guide category's, `packer/topics.toml`).
    public static let nameLimit = 20

    /// The trimmed name when it's usable and none of its siblings has it (ignoring case): the other top-level
    /// categories, or the other subcategories of `parent`; nil otherwise.
    private func usableName(_ name: String, besides id: String? = nil, parent: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.nameLimit).contains(trimmed.count),
              !categories.contains(where: {
                  $0.id != id && $0.parent == parent && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
              })
        else { return nil }
        return trimmed
    }

    private static func slug(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// `base`, or `base-2`, `base-3`… if a category already has it.
    private func uniqueID(_ base: String) -> String {
        var id = base
        var number = 2
        while categories.contains(where: { $0.id == id }) {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }

    /// A new category at the end, and its id (its name in lower case, spaces as hyphens, made unique with a number);
    /// nil for an unusable name or an emoji off the grid.
    public func adding(name: String, emoji: String) -> (LibraryShelf, String)? {
        guard let name = usableName(name), Self.emojiGrid.contains(emoji) else { return nil }
        let id = uniqueID(Self.slug(name))
        var shelf = self
        shelf.categories.append(Category(id: id, name: name, emoji: emoji))
        return (shelf, id)
    }

    /// The file placed in another category.
    public func moving(key: String, to id: String) -> LibraryShelf {
        var shelf = self
        shelf.placed[key] = id
        return shelf
    }

    /// A category's new name and emoji, its id and files unchanged; nil for an unusable name, an emoji off the grid,
    /// or a category it doesn't have. A subcategory takes the name only: it keeps showing its category's emoji.
    public func renaming(id: String, to name: String, emoji: String) -> LibraryShelf? {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return nil }
        let parent = categories[index].parent
        guard let name = usableName(name, besides: id, parent: parent),
              parent != nil || Self.emojiGrid.contains(emoji) else { return nil }
        var shelf = self
        shelf.categories[index].name = name
        if parent == nil { shelf.categories[index].emoji = emoji }
        return shelf
    }

    /// The category gone, with its subcategories, every file they held (`keys`, the device's files) placed in
    /// `target` first, so none is left without one; nil when either is missing, the target is among those going, or
    /// it is the last top-level category.
    public func removing(id: String, movingFilesTo target: String, keys: [String]) -> LibraryShelf? {
        guard let gone = categories.first(where: { $0.id == id }) else { return nil }
        let going = Set([id] + children(of: id).map(\.id))
        guard !going.contains(target), categories.contains(where: { $0.id == target }),
              gone.parent != nil || categories.filter({ $0.parent == nil }).count > 1 else { return nil }
        var shelf = self
        for key in keys where category(for: key).map(going.contains) ?? false { shelf.placed[key] = target }
        shelf.placed = shelf.placed.filter { !going.contains($0.value) }
        shelf.categories.removeAll { going.contains($0.id) }
        return shelf
    }

    /// By title, the held files before those not downloaded (family downloads plan, phase 5: offers come after the
    /// held ones in their category).
    private static func byTitle(_ a: Item, _ b: Item) -> Bool {
        if (a.offer == nil) != (b.offer == nil) { return a.offer == nil }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}
