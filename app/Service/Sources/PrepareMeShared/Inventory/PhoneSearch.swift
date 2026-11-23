import Foundation

/// The phone's inventory search and item details (remaining-findings plan, Task 12.2; F32: a search for "batteries"
/// mixed items whose category matched with those whose name did, and batteries showed "Calories each 0").
public enum PhoneSearch {
    /// The rows holding every word of `search` anywhere in `text` (any case, any accents), those whose name holds
    /// every word first; each group keeps its order. No words: every row, as given.
    public static func ranked<Row>(_ rows: [Row], search: String, name: (Row) -> String,
                                   text: (Row) -> String) -> [Row] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return rows }
        func holds(_ found: String) -> Bool {
            words.allSatisfy { found.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var named: [Row] = [], other: [Row] = []
        for row in rows where holds(text(row)) {  // one pass: each name checked once
            if holds(name(row)) { named.append(row) } else { other.append(row) }
        }
        return named + other
    }

    /// Whether an item's detail shows a value: not when empty, nor a 0 in any column but Quantity (a blank number is
    /// stored as 0; Quantity's 0 says none is left).
    public static func shows(_ text: String, label: String) -> Bool {
        if text.isEmpty { return false }
        return text != "0" || InventoryFile.same(label, Inventory.Label.quantity)
    }

    // MARK: Nothing found (beta run 2 fix plan, Task R3.2; B2-09)

    /// Whether the notes above the list (the home Mac's "wrote this" line, the reminders' invitation) show: not while
    /// a search has words, so the results sit under the box and not under the keyboard.
    public static func showsNotes(search: String) -> Bool {
        search.split(whereSeparator: \.isWhitespace).isEmpty
    }

    public static let nothingFound = "Nothing found."
    public static func didYouMean(_ words: String) -> String { "Did you mean: \(words)" }

    /// The search box takes what is typed as typed (autocorrect had changed "water" on the SE).
    public static let boxAutocorrects = false
    public static let boxCapitalizes = false

    /// What a near miss is looked up in: the words of the item names (as first written, with how many names hold
    /// each, and their letters) and the folded text the search matches (name, brand, place and the rest), so a typed
    /// word the search would find is never "mended". It keeps each row's name and search text as given too, for the
    /// search itself (`ranked`, by row). Built once per copy (a `KeyedCache`), not per keystroke.
    public final class Index {
        /// Each row's name and the text the search matches, as given, in the rows' order
        public let names: [String]
        public let searchTexts: [String]
        let texts: [String]
        let words: [String: (written: String, count: Int, order: Int, letters: [Character])]

        public init(names: [String], texts: [String]) {
            self.names = names
            searchTexts = texts
            self.texts = texts.map { PhoneSearch.fold($0) }
            var seen: [String: (written: String, count: Int, order: Int, letters: [Character])] = [:]
            for name in names {
                for word in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
                    let key = PhoneSearch.fold(word)
                    if let old = seen[key] {
                        seen[key] = (old.written, old.count + 1, old.order, old.letters)
                    } else {
                        seen[key] = (word, 1, seen.count, Array(key))
                    }
                }
            }
            words = seen
        }
    }

    /// Keeps one value while its key stays the same (the copy's date, item count and waiting changes on the phone; the
    /// file's saves and the view shown on the Mac), so a view's redraw on each keystroke never builds it again.
    public final class KeyedCache<Value> {
        private var key = ""
        private var kept: Value?
        public init() {}
        public func value(key: String, build: () -> Value) -> Value {
            if let kept, key == self.key { return kept }
            let made = build()
            self.key = key
            kept = made
            return made
        }
    }

    /// A near miss for a search that found nothing: each typed word that nothing in the items' text holds is swapped
    /// for the nearest word in the names (within 1 letter for a typed word of 4 to 7 letters, within 2 for 8 or
    /// more, nothing for 3 or fewer; a swapped neighbor pair counts as one). Ties go to the word more names hold,
    /// then the first written. The word comes back as written in the inventory (its capitals kept); nil when the
    /// search is empty, every word is held already, or any word has nothing near it. `index` is only built when the
    /// cheap checks leave something to look up.
    public static func nearMiss(search: String, index: () -> Index) -> String? {
        let typed = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !typed.isEmpty, typed.contains(where: { $0.count > 3 }) else { return nil }
        let index = index()
        var changed = false
        var out: [String] = []
        for word in typed {
            let key = fold(word)
            if index.texts.contains(where: { $0.contains(key) }) { out.append(word); continue }
            let letters = Array(key)
            let allowed = letters.count >= 8 ? 2 : letters.count >= 4 ? 1 : 0
            guard allowed > 0 else { return nil }
            var best: (written: String, distance: Int, count: Int, order: Int)?
            for info in index.words.values {
                guard abs(info.letters.count - letters.count) <= allowed else { continue }
                let distance = editDistance(letters, info.letters)
                guard distance <= allowed else { continue }
                if let b = best,
                   (b.distance, -b.count, b.order) <= (distance, -info.count, info.order) { continue }
                best = (info.written, distance, info.count, info.order)
            }
            guard let found = best else { return nil }
            out.append(found.written)
            changed = true
        }
        return changed ? out.joined(separator: " ") : nil
    }

    public static func fold(_ text: String) -> String {
        // the iPhone's keyboard types curly quotes where the Mac's text has straight ones (Task 1.4, 2026-10-23)
        let straight = text.replacingOccurrences(of: "[\u{2018}\u{2019}]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[\u{201C}\u{201D}]", with: "\"", options: .regularExpression)
        return straight.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Edits between two words; a swap of neighbors is one edit. Three rows at a time (the one before last for a
    /// swap), not the whole table.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var older = [Int](repeating: 0, count: b.count + 1)  // row i - 2
        var previous = Array(0...b.count)  // row i - 1
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], older[j - 2] + 1)
                }
            }
            (older, previous, current) = (previous, current, older)
        }
        return previous[b.count]
    }
}

/// The phone's caches' key for a shown copy (behavior check of the simplify pass): a count bumped each time the copy is
/// set or the waiting changes change, with the copy's date and size, so a changed copy that keeps its date (to the
/// second) and its item count never shows the last one's names or search text.
public struct CopyRevision: Sendable {
    private var count = 0
    public init() {}
    public mutating func bump() { count &+= 1 }
    public func key(_ copy: PhoneInventory) -> String { "\(count)|\(copy.writtenAt)|\(copy.items.count)" }
}
