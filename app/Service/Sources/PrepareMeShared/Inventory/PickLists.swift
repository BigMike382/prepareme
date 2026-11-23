import Foundation

/// One choice in a place or category pick: a place by its path ("Truck › Drawer 1"), a category by its name.
public struct PickChoice: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let title: String

    public init(id: Int64, title: String) {
        self.id = id
        self.title = title
    }
}

/// The searchable lists behind a place or category pick, on the Mac and the phone alike (entry fixes plan, Task 1.6;
/// owner, 2026-10-23, by click: a searchable list of full paths, with New Place… or New Category… at its foot), and the
/// new place's or category's name checked as the Mac's editor checks it (Task 1.3).
public enum PickLists {
    public static let newPlaceTitle = "New Place…", newCategoryTitle = "New Category…"

    /// Places by their paths, A to Z; a search keeps those holding every typed word, folded as search folds (so a curly
    /// quote finds a straight one).
    public static func places(_ rows: [(id: Int64, path: String)], search: String) -> [PickChoice] {
        filtered(rows.map { PickChoice(id: $0.id, title: $0.path) }, search: search)
    }

    /// Categories by their names, as `places`.
    public static func categories(_ rows: [(id: Int64, name: String)], search: String) -> [PickChoice] {
        filtered(rows.map { PickChoice(id: $0.id, title: $0.name) }, search: search)
    }

    /// `all`, A to Z, keeping those holding every word of `search`.
    public static func filtered(_ all: [PickChoice], search: String) -> [PickChoice] {
        let words = PhoneSearch.fold(search).split(whereSeparator: \.isWhitespace).map(String.init)
        return all.filter { choice in
            let title = PhoneSearch.fold(choice.title)
            return words.allSatisfy(title.contains)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Why a place can't be called `name` in `keptIn` (0 for none), or nil: a blank name, or a place kept in the same
    /// spot already called that, in any case or spacing.
    public static func placeProblem(name: String, keptIn: Int64, among places: [(id: Int64, name: String, keptIn: Int64?)])
        -> String? {
        let typed = key(name)
        guard !typed.isEmpty else { return InventoryWords.noPlaceName }
        return places.first { ($0.keptIn ?? 0) == keptIn && key($0.name) == typed }
            .map { String(format: InventoryWords.samePlace, $0.name.trimmingCharacters(in: .whitespaces)) }
    }

    /// Why a category can't be called `name`, or nil: a blank name, or another category already called that.
    public static func categoryProblem(name: String, among names: [String]) -> String? {
        let typed = key(name)
        guard !typed.isEmpty else { return InventoryWords.noPlaceName }
        return names.first { key($0) == typed }
            .map { String(format: InventoryWords.sameCategory, $0.trimmingCharacters(in: .whitespaces)) }
    }

    static func key(_ name: String) -> String {
        PhoneSearch.fold(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
