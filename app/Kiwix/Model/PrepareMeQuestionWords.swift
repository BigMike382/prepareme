// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

/// PrepareMe (owner, 2026-10-21): a question finds its guide. libzim finds only pages holding every typed word, so
/// "how do I purify water" found nothing while "purify water" found the bleach and boiling guides. Search leaves out the
/// question words and the small words around them ("how", "do", "I", "what", "should", "the", "to"…) and searches the
/// rest; the search box keeps what was typed. "can", "will", "may", "must" and "might" go only before a word like "I" or
/// "you" ("can I drink…"), so "can opener" stays as typed. "won't", "can't" and a few everyday verbs ("got", "went",
/// "keeps") go wherever they stand (owner, 2026-10-28, the search test: "bleeding won't stop" found nothing, as no
/// page says "wont"). "him" and "her" go too (owner, 2026-11-08, gap review 3: "can we bury him on our land" missed only
/// for "him"). When every word is one of these ("how to"), what was typed is
/// searched as it is. The order (PrepareMeSearchOrder) and "Did you mean" then work on the words searched. Title search
/// looks for what was typed first, as typed, then for these words, and the order lifts a title by either (2026-10-22).
enum PrepareMeQuestionWords {
    /// Left out wherever they stand: question words, the verbs a question is built from, pronouns and small words
    static let dropped: Set<String> = [
        "how", "hows", "what", "whats", "when", "whens", "where", "wheres", "why", "which", "who", "whos", "whom", "whose",
        "do", "does", "did", "doing", "dont", "doesnt", "didnt", "should", "shouldnt", "would", "could", "shall",
        "is", "isnt", "are", "arent", "am", "was", "were", "be", "been", "has", "have", "had",
        "i", "im", "ive", "id", "me", "my", "myself", "we", "us", "our", "you", "your", "it", "its", "they", "them",
        "their", "a", "an", "the", "to", "of", "for", "in", "on", "at", "with", "about", "from", "into", "by", "if", "or",
        "and", "there", "theres", "this", "that", "these", "those", "any", "some", "please", "way", "ways", "best",
        "wont", "cant", "got", "went", "keeps", "him", "her",
    ]

    /// Left out only before a pronoun ("can I", "will we"), as each is also a word of its own (a can, a will)
    static let beforePronoun: Set<String> = ["can", "will", "may", "might", "must"]

    static let pronouns: Set<String> = ["i", "im", "we", "you", "it", "they", "my", "our", "your"]

    /// What search looks for when `typed` is typed
    static func query(_ typed: String) -> String {
        let pieces = typed.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = pieces.map(key)
        let kept = pieces.indices.filter { place in
            let word = keys[place]
            if dropped.contains(word) { return false }
            if beforePronoun.contains(word), place + 1 < keys.count, pronouns.contains(keys[place + 1]) { return false }
            return true
        }
        // nothing left that names a thing (only question words, or only punctuation): search what was typed
        guard kept.contains(where: { !keys[$0].isEmpty }) else { return typed }
        return kept.map { pieces[$0] }.joined(separator: " ")
    }

    /// A typed word without case, accents, apostrophes or punctuation ("Don't?" → "dont")
    static func key(_ piece: String) -> String {
        piece.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }
}

extension SearchOperation {
    /// The search for what was typed: PrepareMeQuestionWords' words, for the view model and the tests alike. Title search
    /// also looks for what was typed, as typed, so a title that starts with a word left out ("The CO alarm is going
    /// off") is found by its own name (2026-10-22). `guides` is the guides library (a test passes its own)
    static func prepareMe(typed: String, zimFileIDs: Set<UUID>, spelling: URL?,
                          guides: UUID = PrepareMeSearchOrder.dailyID) -> SearchOperation {
        let search = SearchOperation(searchText: PrepareMeQuestionWords.query(typed), zimFileIDs: zimFileIDs,
                                     withSpellingCacheDir: spelling)
        search.typedText = typed
        search.guidesID = guides
        return search
    }
}
