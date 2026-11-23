// This file is part of PrepareMe, a local build of Kiwix for one household (beta run 2, B2-31).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import XCTest
@testable import Kiwix

/// PrepareMe (beta run 2, B2-31 and B2-18): guide search keeps the guide named for what's typed on top as each letter is
/// typed. Kiwix re-sorted every result by how many letters turn its whole title into what was typed, so at the stemmer's
/// "floodwat", when full-text results join the title matches, the Floodwater guide sank below short titles that only
/// mention the word. The made-up library is kiwix-mac/make_fixtures.py's app-search: SEARCH_GUIDES, whose bodies are
/// written so the library's own full-text order alone doesn't put the Floodwater guide first, and three water guides
/// made up in the real ones' shape: titles, bodies and search words (WATER_GUIDES).
final class PrepareMeSearchOrderTests: XCTestCase {
    private let searchID = UUID(uuidString: "0f1e2d3c-4b5a-4968-8776-6554433221a4")!
    private let floodwater = "Floodwater: turn around, don't drive in"
    private let medicines = "Medicines in an emergency: supplies, storage and floodwater"
    private let food = "Food that floodwater may have touched: what to throw out and what to keep"
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "prepareme-app-search", withExtension: "zim"),
                                    "run kiwix-mac/build.sh --test, which builds the test libraries")
        let library = folder.appending(path: "search.zim")
        try FileManager.default.copyItem(at: fixture, to: library)
        let service = ZimService.__sharedInstance()
        service.__store(library, with: searchID)
        XCTAssertNotNil(service.__open(searchID))
    }

    override func tearDownWithError() throws {
        ZimService.__sharedInstance().__close(searchID)
        try? FileManager.default.removeItem(at: folder)
    }

    private func search(_ text: String, spelling: URL? = nil) -> SearchOperation {
        let search = SearchOperation.prepareMe(typed: text, zimFileIDs: [searchID], spelling: spelling)  // as the app does
        search.main()
        return search
    }

    private func titles(_ text: String) -> [String] {
        (search(text).__results.array as? [SearchResult] ?? []).map(\.title)
    }

    /// The owner's case from the real iPhone: typing "floodwater" a letter at a time, the Floodwater guide is first from
    /// the fourth letter on, and from "floodw" the other guides naming floodwater follow it, above guides whose text
    /// only mentions it ("Rotating pantry stock")
    func testTheGuideNamedForAWordStaysFirstAsItIsTyped() {
        let word = "floodwater"
        for count in 4...word.count {
            let typed = String(word.prefix(count))
            let found = titles(typed)
            XCTAssertEqual(found.first, floodwater, "\(typed): \(found)")
            if count >= 6 {
                XCTAssertEqual(Set(found.prefix(3)), [floodwater, medicines, food], "\(typed): \(found)")
            }
        }
    }

    /// B2-18: "purify water" lists the bleach and boiling guides above Storing drinking water, whose text says water
    /// more often. No title holds "purify", so the title rule lifts nothing: this is the library's own order, helped by
    /// the guides' search words (WATER_GUIDES: both carry "purify water", as the real ones do), which Kiwix's re-sort threw away
    func testPurifyWaterListsTheBleachAndBoilingGuidesFirst() throws {
        try assertTreatingGuidesFirst(titles("purify water"))
    }

    /// A question, as someone in a hurry might type it (owner, 2026-10-21): its question words are left out, so it finds
    /// what its other words find, in the same order. libzim finds only pages holding every word, and no page here says
    /// "do" or "I": "how do I purify water" found nothing before
    func testAQuestionFindsTheSameGuidesInTheSameOrder() throws {
        for question in ["how to purify water", "How do I purify water?", "how should we purify the water",
                         "What's the best way to purify water"] {
            XCTAssertEqual(titles(question), titles("purify water"), question)
            try assertTreatingGuidesFirst(titles(question))
        }
        XCTAssertEqual(titles("what can I do about floodwater").first, floodwater)
        XCTAssertEqual(titles("can I run a generator outdoors?").first, "Running a generator safely")
    }

    /// A page typed by its own title is found, even when the title starts with a word a question leaves out (owner's
    /// iPhone, 2026-10-22): "The CO alarm is going off" showed at "the" and was gone from "the c" on, as "the c" was
    /// searched as "c" alone, which more titles hold than search keeps. Walk-throughs are found only by their titles
    /// (the packer keeps them out of full-text search), and the library holds a crowd of titles with c and co words.
    /// It leads from the letter after "The " on (the owner's re-check, 2026-10-22: it fell below map pages and "Cooking
    /// without power", which "co" finds by their text and whose titles start with co: the library's TITLE_RIVALS)
    func testAPageTypedByItsTitleLeadsAtEveryLetter() {
        let cooking = "Cooking without power: grills and camp stoves outdoors, and safe temperatures"
        let rivals = titles("The CO")
        for rival in [cooking, "Congress Heights topo map", "Columbia Road map"] {
            XCTAssertTrue(rivals.contains(rival), "the rival \(rival) isn't found: \(rivals)")
        }
        for title in ["The CO alarm is going off", "The smoke alarm is going off"] {
            for count in 3...title.count {
                let typed = String(title.prefix(count))
                let found = titles(typed)
                XCTAssertTrue(found.contains(title), "\(typed): \(found)")
                if count >= 5 {
                    XCTAssertEqual(found.first, title, "\(typed): \(found)")
                }
            }
        }
    }

    /// The words left out, without a library: question words and small words anywhere; "can" and its like only before
    /// a pronoun; nothing left out when nothing would be left
    func testTheQuestionWordsLeftOut() {
        let query = PrepareMeQuestionWords.query
        XCTAssertEqual(query("how do I purify water"), "purify water")
        XCTAssertEqual(query("How do I purify water?"), "purify water?")
        XCTAssertEqual(query("Don't drown: what should I do"), "drown:")
        XCTAssertEqual(query("can I drink rain water"), "drink rain water")
        XCTAssertEqual(query("can opener"), "can opener", "a can, not a question")
        XCTAssertEqual(query("how long can food stay out"), "long can food stay out")
        XCTAssertEqual(query("will we need a generator"), "need generator")
        XCTAssertEqual(query("making a will"), "making will")
        XCTAssertEqual(query("floodwater"), "floodwater")
        XCTAssertEqual(query("how to"), "how to", "only question words: searched as typed")
        XCTAssertEqual(query("what ?"), "what ?")
        XCTAssertEqual(query("  "), "  ")
        XCTAssertEqual(query("WHERE is the gas shut-off"), "gas shut-off")
        XCTAssertEqual(query("bleeding won't stop"), "bleeding stop", "no page says wont (the search test, 2026-10-28)")
        XCTAssertEqual(query("I can't sleep"), "sleep")
        XCTAssertEqual(query("i got burned"), "burned")
        XCTAssertEqual(query("the alarm keeps beeping"), "alarm beeping")
        XCTAssertEqual(query("can we bury him on our land"), "bury land", "no page says him (gap review 3, 2026-11-08)")
    }

    /// No page holds every word (owner, 2026-10-28, the search test): the pages holding the most of them come up, the
    /// one with two words first, marked as only the closest; one word nothing holds still finds nothing, and a search
    /// that finds pages isn't marked
    func testTheClosestPagesWhenNoPageHoldsEveryWord() {
        let closest = search("floodwater pantry bicycle")
        let found = (closest.__results.array as? [SearchResult] ?? []).map(\.title)
        XCTAssertEqual(closest.closestCount, found.count)
        XCTAssertEqual(found.first, "Rotating pantry stock", "\(found)")
        XCTAssertTrue(found.contains(floodwater), "\(found)")
        XCTAssertLessThanOrEqual(found.count, 25)
        let nothing = search("bicycle")
        XCTAssertEqual(nothing.__results.count, 0)
        XCTAssertEqual(nothing.closestCount, 0)
        XCTAssertEqual(search("pantry shelves").closestCount, 0)
    }

    /// Only another library's page holds every word (owner's iPhone, 2026-10-28: "my brother is choking" found only
    /// Wikipedia 100's Charlie Chaplin page, and no guide): the guides holding the most of the words come first, as the
    /// closest, then that page; a search a guide holds whole marks nothing. Here the search library is the guides
    /// (a library opens only under its own ID, so it stands in for the daily library), beside make_fixtures.py's
    /// app-encyclopedia
    func testTheClosestGuidesComeBeforeAnotherLibrarysPageHoldingEveryWord() throws {
        let other = folder.appending(path: "other.zim")
        let encyclopedia = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "prepareme-app-encyclopedia",
                                                                    withExtension: "zim"))
        try FileManager.default.copyItem(at: encyclopedia, to: other)
        let otherID = UUID(uuidString: "0f1e2d3c-4b5a-4968-8776-6554433221a5")!, dailyID = searchID
        let service = ZimService.__sharedInstance()
        service.__store(other, with: otherID)
        defer { service.__close(otherID) }
        XCTAssertNotNil(service.__open(otherID))

        func search(_ text: String) -> (closest: Int, found: [SearchResult]) {
            let search = SearchOperation.prepareMe(typed: text, zimFileIDs: [dailyID, otherID], spelling: nil,
                                                   guides: dailyID)
            search.main()
            return (search.closestCount, search.__results.array as? [SearchResult] ?? [])
        }
        let (closest, found) = search("floodwater pantry bicycle")
        let titles = found.map(\.title)
        XCTAssertGreaterThan(closest, 0, "\(titles)")
        XCTAssertEqual(titles.first, "Rotating pantry stock", "\(titles)")
        XCTAssertTrue(found.prefix(closest).allSatisfy { $0.zimFileID == dailyID }, "\(titles)")
        XCTAssertEqual(found.dropFirst(closest).map(\.title), ["A made-up silent film star"], "\(titles)")

        let whole = search("pantry")
        XCTAssertEqual(whole.closest, 0)
        XCTAssertEqual(whole.found.first?.title, "Rotating pantry stock")
        XCTAssertEqual(search("bicycle wheels").closest, 0, "no guide holds a word: nothing to put first")
    }

    private func assertTreatingGuidesFirst(_ found: [String], line: UInt = #line) throws {
        let storing = try XCTUnwrap(found.firstIndex(of: "Storing drinking water: how much, what containers, and keeping "
                                                     + "it clean"), "\(found)", line: line)
        for title in ["Disinfecting water with plain bleach", "Boiling water so it's safe to drink"] {
            let index = try XCTUnwrap(found.firstIndex(of: title), "\(title): \(found)", line: line)
            XCTAssertLessThan(index, storing, "\(found)", line: line)
        }
    }

    /// The order changes nothing else: a word nothing holds still finds nothing and offers "Did you mean" (the beta
    /// run's F05), and a word only the guides' text holds is still found
    func testSpellingHelpAndFullTextOnlyMatchesStillWork() throws {
        let spelling = folder.appending(path: "spelling")
        try FileManager.default.createDirectory(at: spelling, withIntermediateDirectories: true)
        let missed = search("floodwatr", spelling: spelling)
        XCTAssertEqual(missed.__results.count, 0)
        guard case let .suggestions(words) = missed.searchResultItems else {
            return XCTFail("no Did you mean for floodwatr")
        }
        XCTAssertTrue(words.contains("floodwater"), "\(words)")
        let asked = search("what should I do about floodwatr", spelling: spelling)  // a question's misspelling too
        guard case let .suggestions(askedWords) = asked.searchResultItems else {
            return XCTFail("no Did you mean for a question")
        }
        XCTAssertTrue(askedWords.contains("floodwater"), "\(askedWords)")
        // libraries searched but not open (a map, a stray ID) don't stop the rest: the set's order varies, and Kiwix
        // returned at the first one, so "Did you mean" came and went between launches (2026-10-28)
        let unopened = Set((0..<8).map { _ in UUID() })
        let beside = SearchOperation.prepareMe(typed: "floodwatr", zimFileIDs: unopened.union([searchID]),
                                               spelling: spelling)
        beside.main()
        guard case let .suggestions(besideWords) = beside.searchResultItems else {
            return XCTFail("no Did you mean beside libraries that aren't open")
        }
        XCTAssertTrue(besideWords.contains("floodwater"), "\(besideWords)")
        XCTAssertEqual(titles("generator").first, "Running a generator safely")
        XCTAssertTrue(titles("pantry shelves").contains("Rotating pantry stock"))
    }

    // MARK: the order itself (PrepareMeSearchOrder), without a library

    private func ordered(_ candidates: [(String, Double?)], _ typed: String) -> [String] {
        let list = candidates.map { PrepareMeSearchOrder.Candidate(title: $0.0, match: $0.1) }
        return PrepareMeSearchOrder.order(list, typed: typed).map { list[$0].title }
    }

    /// A title that begins with what's typed comes first, then titles with every typed word at a word's start, then the
    /// rest, each group in the library's order (full-text by its match, then title-only matches as found)
    func testTheOrderLiftsTitlesThatBeginWithOrHoldWhatIsTyped() {
        let found: [(String, Double?)] = [("Rotating pantry stock", 1.0), ("Food that floodwater may have touched", 0.9),
                                          ("Floodwater: turn around", 0.5), ("Paper maps", 0.95),
                                          ("Medicines and floodwater", nil), ("Waterfloods", nil)]
        XCTAssertEqual(ordered(found, "floodwat"), ["Floodwater: turn around", "Food that floodwater may have touched",
                                                     "Medicines and floodwater", "Rotating pantry stock", "Paper maps",
                                                     "Waterfloods"])
        XCTAssertEqual(ordered(found, "zebra"), ["Rotating pantry stock", "Paper maps",
                                                  "Food that floodwater may have touched", "Floodwater: turn around",
                                                  "Medicines and floodwater", "Waterfloods"], "nothing named: the library's order")
    }

    /// Several typed words: a title beginning with them in turn first ("purify water" → "Purifying water…"), then one
    /// holding each at a word's start in any order, never one holding only some
    func testSeveralTypedWords() {
        let found: [(String, Double?)] = [("Storing drinking water", 1.0), ("Water you can purify with bleach", 0.4),
                                          ("Purifying water by boiling", 0.6), ("Purifying water with bleach", nil)]
        XCTAssertEqual(ordered(found, "purify water"), ["Purifying water by boiling", "Purifying water with bleach",
                                                         "Water you can purify with bleach", "Storing drinking water"])
    }

    /// What was typed outranks the question rule's words: a title that begins with what was typed ("The CO") leads, and
    /// titles that only the searched words ("CO") name follow in the usual order, full-text matches first
    func testATitleBeginningWithWhatWasTypedLeads() {
        let found: [(String, Double?)] = [("Cooking without power", 1.0), ("Congress Heights topo map", 0.9),
                                          ("Road maps by county", 0.95), ("The CO alarm is going off", nil)]
        let list = found.map { PrepareMeSearchOrder.Candidate(title: $0.0, match: $0.1) }
        let order = PrepareMeSearchOrder.order(list, typed: "CO", asTyped: "The CO").map { list[$0].title }
        XCTAssertEqual(order, ["The CO alarm is going off", "Cooking without power", "Congress Heights topo map",
                               "Road maps by county"])
        XCTAssertEqual(PrepareMeSearchOrder.order(list, typed: "CO", asTyped: "CO"),
                       PrepareMeSearchOrder.order(list, typed: "CO"), "nothing left out: as before")
    }

    /// Case, accents, punctuation and spaces never matter; nothing typed that is a word leaves the library's order
    func testCaseAccentsAndPunctuation() {
        let found: [(String, Double?)] = [("Café menus", 1.0), ("Floodwater: turn around, don't drive in", nil)]
        XCTAssertEqual(ordered(found, "  FLOODWÁTER "), ["Floodwater: turn around, don't drive in", "Café menus"])
        XCTAssertEqual(ordered(found, "turn-around"), ["Floodwater: turn around, don't drive in", "Café menus"])
        XCTAssertEqual(ordered(found, "cafe"), ["Café menus", "Floodwater: turn around, don't drive in"])
        XCTAssertEqual(ordered(found, "!!"), ["Café menus", "Floodwater: turn around, don't drive in"])
        XCTAssertEqual(PrepareMeSearchOrder.words("Floodwater: turn around, don't drive in"),
                       ["floodwater", "turn", "around", "don", "t", "drive", "in"])
    }

    /// Two libraries' full-text results merge by their match, each library's own order kept; title-only matches after.
    /// A tie (every library's best match is 100%, as libzim's figure is each library's own) goes to the daily library,
    /// the guides and Today, then to the libraries' fixed order (their permanent IDs), never to the order the searches
    /// happened to run in (a set's: checkpoint 2)
    func testLibrariesMergeByTheirMatch() {
        let daily = PrepareMeSearchOrder.dailyID
        let maps = UUID(uuidString: "d2daf783-8bd9-435d-b966-eff4a4c4fe61")!
        let reference = UUID(uuidString: "2f8bf3cc-8a0a-40c3-8818-eecc14d3a185")!
        let dailyFound: [(String, Double?, UUID)] = [("Daily one", 1.0, daily), ("Daily two", 0.7, daily),
                                                     ("Daily title", nil, daily)]
        let mapsFound: [(String, Double?, UUID)] = [("Maps one", 1.0, maps), ("Maps two", 0.8, maps),
                                                    ("Maps title", nil, maps)]
        let expected = ["Daily one", "Maps one", "Maps two", "Daily two", "Daily title", "Maps title"]
        XCTAssertEqual(ordered(dailyFound + mapsFound, "zebra"), expected)
        XCTAssertEqual(ordered(mapsFound + dailyFound, "zebra"), expected, "whichever library was searched first")
        let referenceFound: [(String, Double?, UUID)] = [("Reference one", 1.0, reference), ("Reference title", nil, reference)]
        let three = ["Daily one", "Reference one", "Maps one", "Maps two", "Daily two", "Daily title", "Reference title",
                     "Maps title"]
        XCTAssertEqual(ordered(mapsFound + referenceFound + dailyFound, "zebra"), three,
                       "two other libraries tied: by their fixed IDs")
        XCTAssertEqual(ordered(referenceFound + dailyFound + mapsFound, "zebra"), three)
    }

    private func ordered(_ candidates: [(String, Double?, UUID)], _ typed: String) -> [String] {
        let list = candidates.map { PrepareMeSearchOrder.Candidate(title: $0.0, match: $0.1, library: $0.2) }
        return PrepareMeSearchOrder.order(list, typed: typed).map { list[$0].title }
    }
}
