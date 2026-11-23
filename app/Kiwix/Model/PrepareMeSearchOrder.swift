// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

/// PrepareMe (beta run 2, B2-31 and B2-18; the owner's choice (a), 2026-10-20): the order search results are shown in,
/// in place of Kiwix's re-sort by how many letters turn a whole title into what was typed (WagnerFischer), which let a
/// short title that barely matched beat the guide named for the word, and sank every title match once full-text results
/// joined them (at "floodwat", where the stemmer cuts "floodwater").
///
/// The library's own order stands, with one rule on top. First come results whose title begins with what was typed,
/// word by word ("floodw" finds "Floodwater: turn around…", "disinfect water" finds "Disinfecting water with
/// plain bleach"); next, results whose title has every typed word at the start of one of its words, in any order ("floodw"
/// finds "Food that floodwater may have touched…"); then the rest. Each group keeps the library's order: full-text results as libzim
/// ranks them, merged across libraries by their match (each library's own order kept, as its matches only fall), then
/// title-only matches in the order the title search gave them. A tie between libraries (libzim's figure is relative to
/// each library's own best match, so every library's first hit is 100%) goes to the daily library, the guides and
/// Today, then to the libraries' fixed order, their permanent IDs (packer/volumes.toml: never changed), never to the order
/// the searches ran in, which follows a set's (checkpoint 2). Case and accents never matter, and a word is a run of
/// letters and digits, so punctuation never does either.
enum PrepareMeSearchOrder {
    struct Candidate {
        let title: String
        /// The full-text match, 0 to 1 (libzim's percentage), or nil for a match found only by its title
        let match: Double?
        /// The library it was found in, for a tie between libraries (nil: one library only)
        var library: UUID? = nil
    }

    /// The daily library, the guides and Today (its permanent ID, packer/volumes.toml); the one copy of it, which
    /// PrepareMeRefresh opens too
    static let dailyID = UUID(uuidString: "f1483d14-de87-4912-8462-13ab105deae3")!

    /// A library's place in a tie: the daily library first, then the others by their permanent IDs
    static func libraryPlace(_ id: UUID?) -> (Int, String) {
        (id == dailyID ? 0 : 1, id?.uuidString.lowercased() ?? "")
    }

    /// The candidates' places in the order they're shown: `candidates` come in the order the searches found them.
    /// `typed` is what was searched; `asTyped`, what was typed when that differs (PrepareMeQuestionWords). A title's
    /// group for what was typed comes first, then its group for the words searched: "The CO" puts "The CO alarm is going
    /// off" above "Cooking without power" and map pages, which "CO" alone finds by their text (owner, 2026-10-22). A
    /// question's typed words name no title, so its order is the searched words' as before
    static func order(_ candidates: [Candidate], typed: String, asTyped: String? = nil) -> [Int] {
        let words = words(typed)
        let typedWords = asTyped.map(Self.words) ?? words
        let keyed = candidates.enumerated().map { place, candidate in
            (place: place, group: (group(candidate.title, typed: typedWords), group(candidate.title, typed: words)),
             match: candidate.match,
             library: libraryPlace(candidate.library))
        }
        return keyed.sorted { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            switch (lhs.match, rhs.match) {
            case let (left?, right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if lhs.library != rhs.library { return lhs.library < rhs.library }  // one library's run stays in order
                return lhs.place < rhs.place
            }
        }.map(\.place)
    }

    /// 0 when the title begins with the typed words, each the start of a word in turn; 1 when every typed word starts a
    /// word somewhere in the title; 2 otherwise (and when nothing typed is a word)
    static func group(_ title: String, typed: [String]) -> Int {
        guard !typed.isEmpty else { return 2 }
        let held = words(title)
        if held.count >= typed.count, zip(typed, held).allSatisfy({ word, titleWord in titleWord.hasPrefix(word) }) {
            return 0
        }
        if typed.allSatisfy({ word in held.contains { $0.hasPrefix(word) } }) {
            return 1
        }
        return 2
    }

    /// The words of a title or of what was typed, without case or accents
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
