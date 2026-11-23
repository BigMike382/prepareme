// This file is part of PrepareMe, a local build of Kiwix for one household.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
import Testing
@testable import Kiwix

/// Meaning search in the app (PrepareMeMeaning; docs/plans/2026-10-28-meaning-search.md, phase 3): the daily library's
/// numbers read as the packer writes them, meaning's best pages, and the top section's rule, the same cases as
/// packer/tests/test_meaning.py's WithMeaningTest (packer/searchcheck.py's with_meaning). Made-up numbers only.
struct PrepareMeMeaningTests {
    /// 384 numbers: `first`, then zeros (the packer test's vector())
    private func vector(_ first: Float...) -> [Float] {
        first + [Float](repeating: 0, count: PrepareMeMeaning.dimensions - first.count)
    }

    private func sample() throws -> Data {
        // the packer's meaning_json of its test's SAMPLE (test_the_apps_sample_is_this_files_shape pins the bytes)
        let url = try #require(Bundle(for: PrepareMeAppTests.self).url(forResource: "prepareme-meaning-sample",
                                                                        withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test func readsThePackersFile() throws {
        let pages = try PrepareMeMeaning.read(sample())
        #expect(pages.map(\.path) == ["water-boil.html", "steps/shutoffs.html"])
        #expect(pages.map(\.vectors) == [[vector(0.5, 0.25), vector(-1)], [vector(0.125)]])
    }

    @Test func refusesAnotherModelOrFormatOrAShortSet() throws {
        let held = try #require(JSONSerialization.jsonObject(with: sample()) as? [String: Any])
        let short = ["path": "a.html", "vectors": [Data(count: 12).base64EncodedString()]] as [String: Any]
        for changed in [["model": "another-model@1"], ["format": 2], ["pages": [short]]] as [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: held.merging(changed) { _, new in new })
            #expect(throws: (any Error).self) { try PrepareMeMeaning.read(data) }
        }
    }

    @Test func bestCountsAPagesCloserSetAndTiesGoByPath() {
        let pages = [("b.html", [vector(0.1), vector(0.9)]), ("a.html", [vector(0.5)]), ("c.html", [vector(0.5)]),
                     ("d.html", [vector(-1)])].map { PrepareMeMeaning.Page(path: $0, title: $0, vectors: $1) }
        #expect(PrepareMeMeaning.best(pages, search: vector(1)).map(\.path) == ["b.html", "a.html", "c.html"])
    }

    private let best = ["choking.html", "cpr.html", "fever.html"]

    @Test func wordSearchsFirstKeepsAPlaceInTheTop() throws {
        let merged = try #require(PrepareMeMeaning.merged(["burns.html", "cpr.html"], best: best, typed: "my kid",
                                                          firstTitle: "Burns"))
        #expect(merged.0 == ["choking.html", "cpr.html", "burns.html"])
        #expect(merged.top == 3)
    }

    @Test func meaningsThreeStandWhenWordSearchsFirstIsOneOfThem() throws {
        let merged = try #require(PrepareMeMeaning.merged(["fever.html", "burns.html"], best: best, typed: "my kid",
                                                          firstTitle: "Fever"))
        #expect(merged.0 == best + ["burns.html"])
        #expect(merged.top == 3)
    }

    @Test func noSectionWhenATitleBeginsWithWhatWasTyped() {
        #expect(PrepareMeMeaning.merged(["burns.html"], best: best, typed: "burns",
                                        firstTitle: "Burns and scalds") == nil)
        #expect(PrepareMeMeaning.merged(["burns.html"], best: [], typed: "my kid", firstTitle: "Burns") == nil)
    }

    @Test func withNothingFoundMeaningsThreeStand() throws {
        let merged = try #require(PrepareMeMeaning.merged([String](), best: best, typed: "mom wont wake up",
                                                          firstTitle: nil))
        #expect(merged.0 == best)
        #expect(merged.top == 3)
    }

    /// Made-up results and pages for placed(): word search found the shut-offs page and the alarms guide (the closest
    /// pages) and an encyclopedia article; meaning's best are first aid, shut-offs and burns
    private let daily = PrepareMeSearchOrder.dailyID
    private let other = UUID(uuidString: "0f1e2d3c-4b5a-4968-8776-6554433221a5")!

    private func result(_ library: UUID, _ path: String, _ title: String) throws -> SearchResult {
        try #require(SearchResult(zimFileID: library, path: path, title: title))
    }

    private func page(_ path: String, _ title: String) -> PrepareMeMeaning.Page {
        .init(path: path, title: title, vectors: [vector(1)])
    }

    @Test func placedKeepsAFoundPagesSnippetAndRecountsTheClosestPages() throws {
        let shutoffs = try result(daily, "shutoffs.html", "Shut-offs")
        shutoffs.snippet = NSAttributedString(string: "Turn the valve")
        let found = [shutoffs, try result(daily, "alarms.html", "Alarms"), try result(other, "a/Bleeding", "Bleeding")]
        let best = [page("first-aid.html", "First aid"), page("shutoffs.html", "Shut-offs"), page("burns.html", "Burns")]
        let placed = try #require(PrepareMeMeaning.placed(found, closest: 2, best: (daily, best),
                                                          typed: "bleeding wont stop"))
        #expect(placed.results.map(\.title) == ["First aid", "Shut-offs", "Burns", "Alarms", "Bleeding"])
        #expect(placed.results[1] === shutoffs)  // the same result, its snippet kept
        #expect(placed.top == 3)
        #expect(placed.closest == 1)  // the alarms guide; the shut-offs page moved into the section
    }

    @Test func placedWithNothingFoundIsMeaningsThreeAlone() throws {
        let best = [page("first-aid.html", "First aid"), page("shutoffs.html", "Shut-offs"), page("burns.html", "Burns")]
        let placed = try #require(PrepareMeMeaning.placed([], closest: 0, best: (daily, best), typed: "hypothermai"))
        #expect(placed.results.map(\.url.path) == ["/first-aid.html", "/shutoffs.html", "/burns.html"])
        #expect(placed.results.allSatisfy { $0.zimFileID == daily })
        #expect((placed.top, placed.closest) == (3, 0))
    }

    @Test @MainActor func linesOverTheSectionTheClosestPagesAndOtherLibraries() {
        typealias Lines = SearchResults
        #expect(Lines.lines(meaning: 3, closest: 1, count: 5)
                == [0: Lines.meaningLine, 3: Lines.closestGuidesLine, 4: Lines.otherLibrariesLine])
        #expect(Lines.lines(meaning: 3, closest: 2, count: 5) == [0: Lines.meaningLine, 3: Lines.closestLine])
        #expect(Lines.lines(meaning: 3, closest: 0, count: 6) == [0: Lines.meaningLine, 3: Lines.moreResultsLine])
        #expect(Lines.lines(meaning: 3, closest: 0, count: 3) == [0: Lines.meaningLine])
        #expect(Lines.lines(meaning: 0, closest: 2, count: 4) == [0: Lines.closestGuidesLine, 2: Lines.otherLibrariesLine])
        #expect(Lines.lines(meaning: 0, closest: 2, count: 2) == [0: Lines.closestLine])
        #expect(Lines.lines(meaning: 0, closest: 0, count: 4).isEmpty)
    }

    @Test func noSearchBeforeTheModelIsReady() {
        #expect(PrepareMeMeaning().best("my kid", in: [PrepareMeSearchOrder.dailyID]) == nil)
    }
}
