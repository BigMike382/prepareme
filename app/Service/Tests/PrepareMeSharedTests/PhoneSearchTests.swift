import Foundation
@testable import PrepareMeShared
import XCTest

/// The phone's inventory search and item details (remaining-findings plan, Task 12.2; F32).
final class PhoneSearchTests: XCTestCase {
    struct Row: Equatable { let name: String, category: String }

    /// A near miss among `names` alone, through the index the phone and the Mac build (names as their own text).
    func near(_ search: String, _ names: [String]) -> String? {
        PhoneSearch.nearMiss(search: search) { PhoneSearch.Index(names: names, texts: names) }
    }

    func testSearchRanksNameMatchesFirst() {
        let rows = [Row(name: "Flashlight", category: "Batteries and power"),
                    Row(name: "AA batteries", category: "Batteries and power"),
                    Row(name: "Can opener", category: "Kitchen"),
                    Row(name: "D batteries", category: "Power")]
        let found = PhoneSearch.ranked(rows, search: "batteries", name: \.name) { "\($0.name) \($0.category)" }
        XCTAssertEqual(found.map(\.name), ["AA batteries", "D batteries", "Flashlight"], "names first, then the rest")
        XCTAssertEqual(PhoneSearch.ranked(rows, search: "  aa  BATT ", name: \.name) { $0.name }.map(\.name),
                       ["AA batteries"], "every word, any case")
        XCTAssertEqual(PhoneSearch.ranked(rows, search: "", name: \.name) { $0.name }, rows, "no words: all, as listed")
    }

    func testZeroCaloriesIsHidden() {
        XCTAssertFalse(PhoneSearch.shows("0", label: "Calories each"), "a blank number is stored as 0")
        XCTAssertFalse(PhoneSearch.shows("", label: "Brand"))
        XCTAssertTrue(PhoneSearch.shows("0", label: "Quantity"), "none left is worth saying")
        XCTAssertTrue(PhoneSearch.shows("250", label: "Calories each"))
    }

    // MARK: The near miss (beta run 2 fix plan, Task R3.2; B2-09)

    let names = ["AA Batteries", "D batteries", "Flashlight", "Water filter", "Rice", "Zorvex lantern"]

    func testNearMissOffersTheWordAsStored() {
        XCTAssertEqual(near("batteris", names), "Batteries", "one letter off: the word as first written")
        XCTAssertEqual(near("BATTERIS", names), "Batteries", "any case typed")
        XCTAssertEqual(near("flashligt", names), "Flashlight", "stored capitals kept")
        XCTAssertEqual(near("flshlght", names), "Flashlight", "two letters off, 8 letters typed")
    }

    func testNearMissAllowsTwoLettersOnLongWordsOnly() {
        XCTAssertEqual(near("zorvxe lantern", names), "Zorvex lantern", "every word mended")
        XCTAssertEqual(near("flashlgt", names), "Flashlight", "two letters off, 8+ letters long")
        XCTAssertEqual(near("ricd", ["Rice", "Rod"]), "Rice", "short word, one off, offered")
        XCTAssertNil(near("rxxe", names), "short word, two off: nothing")
        XCTAssertNil(near("ab", ["Ax"]), "tiny words never")
    }

    func testNearMissIsSilentWhenNothingIsNear() {
        XCTAssertNil(near("kayak", names))
        XCTAssertNil(near("", names))
        XCTAssertNil(near("batteries", names), "an exact word is no miss")
    }

    func testNearMissPrefersTheCommonerWord() {
        let many = ["Batteries", "Batteries", "Batteries", "Battery case", "Batteres"]
        XCTAssertEqual(near("batteris", many), "Batteries")
    }

    func testNotesAndRemindersHideWhileSearching() {
        XCTAssertTrue(PhoneSearch.showsNotes(search: ""))
        XCTAssertTrue(PhoneSearch.showsNotes(search: "   "), "only spaces is not a search")
        XCTAssertFalse(PhoneSearch.showsNotes(search: "b"))
    }

    func testWordsForNothingFound() {
        XCTAssertEqual(PhoneSearch.nothingFound, "Nothing found.")
        XCTAssertEqual(PhoneSearch.didYouMean("batteries"), "Did you mean: batteries")
    }

    func testSearchBoxHasNoAutocorrect() {
        XCTAssertFalse(PhoneSearch.boxAutocorrects)
        XCTAssertFalse(PhoneSearch.boxCapitalizes)
    }

    func testHeldWordsIncludeTheOtherColumnsAndCheapChecksSkipTheIndex() {
        let index = PhoneSearch.Index(names: ["Lantern"], texts: ["Lantern Zorvex garage"])
        XCTAssertEqual(PhoneSearch.nearMiss(search: "lantrn garage") { index }, "Lantern garage",
                       "garage is held by the place, so it stays as typed")
        var built = false
        XCTAssertNil(PhoneSearch.nearMiss(search: "ab c") { built = true; return index })
        XCTAssertNil(PhoneSearch.nearMiss(search: "  ") { built = true; return index })
        XCTAssertFalse(built, "an empty search or only tiny words never builds the index")
        let cache = PhoneSearch.KeyedCache<PhoneSearch.Index>()
        var builds = 0
        _ = cache.value(key: "a") { builds += 1; return index }
        _ = cache.value(key: "a") { builds += 1; return index }
        _ = cache.value(key: "b") { builds += 1; return index }
        XCTAssertEqual(builds, 2, "built once per key")
    }

    /// The simplify pass: the distance kept three rows at a time gives what the whole table gave
    func testTheEditDistanceCountsASwapAsOne() {
        func d(_ a: String, _ b: String) -> Int { PhoneSearch.editDistance(Array(a), Array(b)) }
        XCTAssertEqual(d("", "abc"), 3)
        XCTAssertEqual(d("abc", ""), 3)
        XCTAssertEqual(d("lantern", "lantern"), 0)
        XCTAssertEqual(d("lantrn", "lantern"), 1)
        XCTAssertEqual(d("lnatern", "lantern"), 1, "a swapped neighbor pair")
        XCTAssertEqual(d("kitten", "sitting"), 3)
        XCTAssertEqual(d("ca", "abc"), 3, "a swap is never edited again")
        XCTAssertEqual(d("generatr", "generator"), 1)
        XCTAssertEqual(d("abcdef", "badcfe"), 3)
    }

    /// The simplify pass: the index keeps each row's name and search text as given, in order, for the search itself
    func testTheIndexKeepsEachRowsNameAndTextAsGiven() {
        let index = PhoneSearch.Index(names: ["Lantern", "Café kit"], texts: ["Lantern Garage", "Café kit Kitchen"])
        XCTAssertEqual(index.names, ["Lantern", "Café kit"])
        XCTAssertEqual(index.searchTexts, ["Lantern Garage", "Café kit Kitchen"])
        let rows = PhoneSearch.ranked(Array(index.names.indices), search: "kit", name: { index.names[$0] }) {
            index.searchTexts[$0]
        }
        XCTAssertEqual(rows, [1])
    }

    /// Behavior check of the simplify pass: a changed copy with the same date (to the second) and item count is a new
    /// key once the copy is set again, so the search and Did you mean read its own names, never the last copy's
    func testACopyWithTheSameDateAndCountGetsFreshNames() {
        let columns = [PhoneInventory.Column(colId: "Item", label: "Item", kind: "text", target: nil, choices: [],
                                             editable: true)]
        func copy(_ name: String) -> PhoneInventory {
            PhoneInventory(writtenAt: "2026-10-21T10:00:00Z", columns: columns,
                           items: [PhoneInventory.Row(id: 1, position: 1, values: ["Item": .text(name)])], places: [],
                           categories: [], headsUpDays: 60, toBuy: [], results: [:])
        }
        let first = copy("Lantern"), renamed = copy("Headlamp")
        var revision = CopyRevision()
        let cache = PhoneSearch.KeyedCache<PhoneSearch.Index>()
        func index(_ shown: PhoneInventory) -> PhoneSearch.Index {
            cache.value(key: revision.key(shown)) {
                PhoneSearch.Index(names: shown.items.map(shown.shownName), texts: shown.items.map(shown.shownName))
            }
        }
        XCTAssertEqual(index(first).names, ["Lantern"])
        XCTAssertEqual(revision.key(first), revision.key(renamed), "the old key: same date and count")
        revision.bump()  // the model sets the renamed copy
        XCTAssertEqual(index(renamed).names, ["Headlamp"], "fresh, not the last copy's")
        XCTAssertEqual(PhoneSearch.nearMiss(search: "headlmp") { index(renamed) }, "Headlamp")
        XCTAssertNil(PhoneSearch.nearMiss(search: "lantrn") { index(renamed) }, "the old name is gone")
    }

    /// Task 1.4 (2026-10-23): the iPhone's keyboard types curly quotes; search, Did you mean, the duplicate check and
    /// the look-alike rule treat them as the Mac's straight ones.
    func testCurlyQuotesFoldToStraight() {
        XCTAssertEqual(PhoneSearch.fold("Men\u{2019}s gloves"), PhoneSearch.fold("men's GLOVES"))
        XCTAssertEqual(PhoneSearch.fold("\u{201C}Big\u{201D} \u{2018}one\u{2019}"), PhoneSearch.fold("\"big\" 'one'"))
        XCTAssertEqual(ItemMatch.Names([(1, "Men's gloves")]).existing(named: "Men\u{2019}s gloves"), 1)
    }
}
