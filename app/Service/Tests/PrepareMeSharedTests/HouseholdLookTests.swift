import Foundation
@testable import PrepareMeShared
import XCTest

/// When a phone fetches the Mac's household copy by itself (beta run 2, B2-01): a rally point added on the Mac reached a
/// child's phone only once someone opened its Inventory, since the street map fetched the copy only when it held none.
/// The rule has no role in it, so a child's read-only phone looks the same as an adult's.
final class HouseholdLookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEveryLibraryCheckLooksWithACopyHeld() {
        XCTAssertTrue(HouseholdLook.due(.libraryCheck, hasCopy: true, lastLook: now.addingTimeInterval(-180), now: now),
                      "the check every 3 minutes while open, Check now, the background check: a new rally point comes")
        XCTAssertTrue(HouseholdLook.due(.libraryCheck, hasCopy: false, lastLook: nil, now: now))
    }

    func testOpeningTheStreetMapLooksWithACopyHeld() {
        XCTAssertTrue(HouseholdLook.due(.streetMapOpened, hasCopy: true, lastLook: now.addingTimeInterval(-600), now: now),
                      "a phone holds a copy from pairing on: the map must still fetch the latest")
        XCTAssertTrue(HouseholdLook.due(.streetMapOpened, hasCopy: false, lastLook: nil, now: now))
    }

    func testALookSecondsAgoIsntFetchedAgain() {
        for moment in [HouseholdLook.Moment.libraryCheck, .streetMapOpened] {
            XCTAssertFalse(HouseholdLook.due(moment, hasCopy: true, lastLook: now.addingTimeInterval(-10), now: now),
                           "Inventory's own look, or the check just before: no second fetch")
            XCTAssertTrue(HouseholdLook.due(moment, hasCopy: true, lastLook: now.addingTimeInterval(-HouseholdLook.fresh),
                                            now: now))
            XCTAssertTrue(HouseholdLook.due(moment, hasCopy: false, lastLook: now.addingTimeInterval(-10), now: now),
                          "no copy to show: always worth a try")
            XCTAssertTrue(HouseholdLook.due(moment, hasCopy: true, lastLook: now.addingTimeInterval(60), now: now),
                          "a clock set back: a last look in the future is no reason to wait")
        }
    }

    /// A tapped Check now fetches even seconds after a look (checkpoint 1): the person asked for the latest
    func testATappedCheckNowAlwaysLooks() {
        XCTAssertTrue(HouseholdLook.due(.checkNow, hasCopy: true, lastLook: now.addingTimeInterval(-5), now: now))
        XCTAssertTrue(HouseholdLook.due(.checkNow, hasCopy: true, lastLook: now, now: now))
        XCTAssertTrue(HouseholdLook.due(.checkNow, hasCopy: false, lastLook: nil, now: now))
        XCTAssertFalse(HouseholdLook.due(.libraryCheck, hasCopy: true, lastLook: now.addingTimeInterval(-5), now: now),
                       "the timed and background checks still leave a fresh look alone")
    }
}
