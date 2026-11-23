@testable import PrepareMeShared
import XCTest

/// The searchable pick lists for a place or a category (entry fixes plan, Task 1.6, 2026-10-23), on the Mac and the
/// phone alike.
final class PickListsTests: XCTestCase {
    let places: [(id: Int64, path: String)] = [(3, "Truck › Drawer 1"), (1, "Garage"), (2, "Kitchen › Drawer 1"),
                                               (4, "Men's closet")]

    func testChoicesSortedAndSearchedByEveryWord() {
        XCTAssertEqual(PickLists.places(places, search: "").map(\.title),
                       ["Garage", "Kitchen › Drawer 1", "Men's closet", "Truck › Drawer 1"])
        XCTAssertEqual(PickLists.places(places, search: " dr 1 ").map(\.id), [2, 3], "every word, in any order")
        XCTAssertEqual(PickLists.places(places, search: "drawer truck").map(\.id), [3])
        XCTAssertEqual(PickLists.places(places, search: "MEN\u{2019}S").map(\.id), [4], "a curly quote finds a straight one")
        XCTAssertEqual(PickLists.categories([(1, "Water"), (2, "Canned goods")], search: "can").map(\.title),
                       ["Canned goods"])
        XCTAssertEqual(PickLists.newPlaceTitle, "New Place…")
        XCTAssertEqual(PickLists.newCategoryTitle, "New Category…")
    }

    /// The phone checks a new place's name at once, as the Mac will (Task 1.3's rule): blank, or a place kept in the
    /// same spot with that name, in any case.
    func testANewPlacesNameIsCheckedOnThePhoneToo() {
        let kept: [(id: Int64, name: String, keptIn: Int64?)] = [(1, "Garage", nil), (2, "Drawer 1", 1)]
        XCTAssertEqual(PickLists.placeProblem(name: "  ", keptIn: 0, among: kept), InventoryWords.noPlaceName)
        XCTAssertEqual(PickLists.placeProblem(name: "garage", keptIn: 0, among: kept),
                       String(format: InventoryWords.samePlace, "Garage"))
        XCTAssertNil(PickLists.placeProblem(name: "Drawer 1", keptIn: 0, among: kept), "another spot's Drawer 1")
        XCTAssertEqual(PickLists.categoryProblem(name: "WATER", among: ["Water"]),
                       String(format: InventoryWords.sameCategory, "Water"))
        XCTAssertNil(PickLists.categoryProblem(name: "Heating", among: ["Water"]))
    }
}
