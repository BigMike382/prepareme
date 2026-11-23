import Foundation

/// The searches behind Edit Our Home's pickers (docs/plans/2026-11-20-our-home-editor.md, Task 4; boards 3, 5, 6 and
/// 8): plain functions over the phones' copy of the inventory and the daily library's guide list, so a Private row
/// never reaches a picker (the copy never holds one) and the editor's views stay thin.
public enum HomePick {
    /// A place a picker offers: its id, its full path and how many items are kept in it or in the places inside it.
    public struct Place: Equatable, Sendable {
        public let id: Int64
        public let path: String
        public let count: Int
    }

    /// An item a picker offers: its id, its name as typed and where it's kept (its place's full path).
    public struct Item: Equatable, Sendable {
        public let id: Int64
        public let name: String
        public let place: String
    }

    /// Every place whose full path holds `query` (capitals aside), in the Lists' order; none for an empty query.
    public static func places(_ query: String, in copy: PhoneInventory) -> [Place] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let held = copy.items.compactMap { row in copy.column("Location").flatMap { row.values[$0.colId]?.whole } }
        return copy.places.compactMap { place in
            let path = copy.path(place.id)
            guard holds(path, query) else { return nil }
            return Place(id: place.id, path: path, count: held.filter { copy.chain($0).contains(place.id) }.count)
        }
    }

    /// Every item whose name holds `query`, in the Lists' order; `withManual`: only those with a manual attached, all
    /// of them for an empty query (the manual picker); none for an empty query otherwise.
    public static func items(_ query: String, in copy: PhoneInventory, withManual: Bool) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard withManual || !query.isEmpty else { return [] }
        return copy.items.compactMap { row in
            guard !withManual || row.manual != nil else { return nil }
            let kept = HomeSlots.kept(row, in: copy)
            guard query.isEmpty || holds(kept.name, query) else { return nil }
            return Item(id: row.id, name: kept.name, place: kept.place)
        }
    }

    /// The guide picker's lists: for an empty query every topic with all its guides; for a query the topics holding a
    /// title that matches, each with its matches and its topic's total. Topics A to Z, "Other" last; a format 1 list
    /// (no topics) is one list under "".
    public static func guides(_ query: String, in guides: [GuideList.Guide])
        -> [(topic: String, total: Int, guides: [GuideList.Guide])] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let byTopic: [String: [GuideList.Guide]] = Dictionary(grouping: guides, by: \.topic)
        let order = byTopic.keys.sorted { (a: String, b: String) -> Bool in
            a == other || b == other ? b == other && a != other : a.lowercased() < b.lowercased()
        }
        var out: [(topic: String, total: Int, guides: [GuideList.Guide])] = []
        for topic in order {
            let all = byTopic[topic] ?? []
            let found = query.isEmpty ? all : all.filter { holds($0.title, query) }
            if !found.isEmpty { out.append((topic, all.count, found)) }
        }
        return out
    }

    /// packer.guide_topics.OTHER_TOPIC, the Guides list's section for a guide in no topic
    static let other = "Other"

    /// Whether a picked place or item is one the copy no longer has: the editor marks its row to be picked again.
    /// Renamed or moved isn't stale (owner, 2026-11-20, by click: InventoryFile.numberedForGood never reuses an id).
    /// Typed words are never stale.
    public static func stale(_ picked: HouseholdPage.Picked, place: Bool, in copy: PhoneInventory) -> Bool {
        guard let id = picked.id else { return false }
        return place ? HomeSlots.place(id: id, in: copy) == nil : HomeSlots.item(id: id, in: copy) == nil
    }

    /// A picked place or item as the copy names it now, its current path or name, which the editor shows and Save
    /// writes; unchanged when typed, gone, or with no copy. Never a ";" (a thing's line splits on it).
    public static func current(_ picked: HouseholdPage.Picked, place: Bool, in copy: PhoneInventory?) -> HouseholdPage.Picked {
        guard let id = picked.id, let copy,
              let now = place ? HomeSlots.place(id: id, in: copy) : HomeSlots.item(id: id, in: copy)?.name else { return picked }
        return HouseholdPage.Picked(id: id, words: words(now))
    }

    /// The page with every picked place, manual and thing as the copy names it now (`current`), as Save writes it.
    public static func followed(_ page: HouseholdPage, in copy: PhoneInventory?) -> HouseholdPage {
        var page = page
        page.things = page.things.map { current($0, place: false, in: copy) }
        for i in page.steps.indices {
            page.steps[i].place = page.steps[i].place.map { current($0, place: true, in: copy) }
            page.steps[i].manual = page.steps[i].manual.map { current($0, place: false, in: copy) }
        }
        return page
    }

    /// A picked name or path as a page line holds it: a ";" becomes "," (a thing's line splits on ";").
    public static func words(_ name: String) -> String { name.replacingOccurrences(of: ";", with: ",") }

    static func holds(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
