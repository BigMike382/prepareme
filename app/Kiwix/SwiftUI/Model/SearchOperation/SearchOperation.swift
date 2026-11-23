// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

import Defaults

extension SearchOperation {
    private var searchResults: [SearchResult] { __results.array as? [SearchResult] ?? [] }
    private var corrections: [String] { __corrections.array as? [String] ?? [] }
    var searchResultItems: SearchResultItems {
        if !corrections.isEmpty {
            .suggestions(corrections)
        } else {
            .results(searchResults)
        }
    }
    /// PrepareMe: meaning search's best pages when "Did you mean" is shown in place of results (addMeaning), else none
    var meaningAboveSuggestions: [SearchResult] {
        corrections.isEmpty ? [] : Array(searchResults.prefix(meaningCount))
    }

    open override func main() {
        __results.removeAllObjects()
        __corrections.removeAllObjects()
        // perform index and title search
        guard !searchText.isEmpty else { return }
        performSearch()

        // reduce to unique results by URL
        // PrepareMe (both builds, Kiwix (PrepareMe) too, on purpose: docs/kiwix-mac.md): in the order found (full-text,
        // then title matches), which the order below keeps; Kiwix's dictionary here lost it (beta run 2, B2-31)
        var seenURLs = Set<URL>()
        __results = NSMutableOrderedSet(array: searchResults.filter { seenURLs.insert($0.url).inserted })

        addSnippets(searchResults)

        // PrepareMe (both builds, as above): the library's own order, with a result whose title begins with or holds
        // what was typed first (PrepareMeSearchOrder; beta run 2, B2-31 and B2-18), in place of Kiwix's re-sort of
        // every result by how many letters turn its whole title into what was typed (WagnerFischer), which buried the
        // guide named for the word
        guard !isCancelled else { return }
        let found = searchResults
        __results = NSMutableOrderedSet(array: ordered(found, typed: searchText, asTyped: typedText))

        performSuggestions()
        // PrepareMe (both builds, as above; owner, 2026-10-28, after the search test): when no page holds every word
        // and there's no "Did you mean", the closest pages, marked as such, in place of a blank screen
        if searchResults.isEmpty, corrections.isEmpty {
            addClosest(in: zimFileIDs)
        } else if corrections.isEmpty, let guides = guidesID, zimFileIDs.contains(where: { $0 as? UUID == guides }),
                  !searchResults.contains(where: { $0.zimFileID == guides }) {
            // and when only other libraries' pages hold every word, the guides holding the most of them, above those
            // pages (owner's choice, 2026-10-28: "my brother is choking" found only Wikipedia 100's Charlie Chaplin)
            addClosest(in: [guides])
        }
        addMeaning()
    }

    /// PrepareMe (owner, 2026-10-28; docs/plans/2026-10-28-meaning-search.md, phase 3): meaning search's section on
    /// top (PrepareMeMeaning's rule), when it has one for this search. A page word search found too keeps its snippet;
    /// the closest pages that aren't in the section follow it, still counted. With "Did you mean" (no results), the
    /// section is meaning's best three alone, shown above the spelling words (meaningAboveSuggestions)
    private func addMeaning() {
        let libraries = Set(zimFileIDs.compactMap { $0 as? UUID })
        guard !isCancelled, let best = PrepareMeMeaning.shared.best(typedText, in: libraries),
              let placed = PrepareMeMeaning.placed(searchResults, closest: closestCount, best: best, typed: typedText)
        else { return }
        __results = NSMutableOrderedSet(array: placed.results)
        (meaningCount, closestCount) = (placed.top, placed.closest)
    }

    private func ordered(_ found: [SearchResult], typed: String, asTyped: String? = nil) -> [SearchResult] {
        PrepareMeSearchOrder.order(
            found.map { PrepareMeSearchOrder.Candidate(title: $0.title, match: $0.probability?.doubleValue,
                                                       library: $0.zimFileID) },
            typed: typed, asTyped: asTyped
        ).map { found[$0] }
    }

    /// The pages in `libraries` holding the most of the words searched, each word searched alone and put in the order
    /// above; a tie goes to the page placed higher in its words' lists, then to the earlier word. At most 25, so the list
    /// stays short. They go before the results already found (none, or other libraries' pages holding every word)
    private func addClosest(in libraries: Set<AnyHashable>) {
        let words = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { !PrepareMeQuestionWords.key($0).isEmpty }
        guard words.count > 1 else { return }
        var found: [URL: (result: SearchResult, words: Int, place: Int, first: Int)] = [:]
        for word in words {
            guard !isCancelled else { return }
            let one = SearchOperation(searchText: word, zimFileIDs: libraries, withSpellingCacheDir: nil)
            one.extractMatchingSnippet = extractMatchingSnippet
            one.performSearch()
            for (place, result) in ordered(one.searchResults, typed: word).enumerated() {
                if let held = found[result.url] {
                    found[result.url] = (held.result, held.words + 1, min(held.place, place), held.first)
                } else {
                    found[result.url] = (result, 1, place, found.count)
                }
            }
        }
        let closest = found.values.sorted { lhs, rhs in
            (-lhs.words, lhs.place, lhs.first) < (-rhs.words, rhs.place, rhs.first)
        }.prefix(25).map(\.result)
        guard !isCancelled, !closest.isEmpty else { return }
        addSnippets(closest)
        __results = NSMutableOrderedSet(array: closest + searchResults)
        closestCount = closest.count
    }

    /// Parse and extract each search result's snippet
    private func addSnippets(_ results: [SearchResult]) {
        if case .matches = Defaults[.searchResultSnippetMode] {
            for result in results {
                guard let html = result.htmlSnippet,
                      let data = html.data(using: .utf8) else { continue }
                result.snippet = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html,
                              .characterEncoding: String.Encoding.utf8.rawValue],
                    documentAttributes: nil
                )
            }
        }

    }
    
    private func performSuggestions() {
        guard !isCancelled,
              !zimFileIDs.isEmpty,
              searchText.count > 2,
              searchResults.isEmpty,
              spellCacheDir != nil else {
            __corrections = []
            return
        }
        Log.LibraryOperations.debug("perfoming search suggestsion")
        __addSpellingCorrections()
        let count: Int = __corrections.count
        Log.LibraryOperations.debug("found search suggestsion: \(count, privacy: .public)")
    }
}
