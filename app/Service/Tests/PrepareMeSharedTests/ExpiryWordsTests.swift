import Foundation
import PrepareMeShared
import XCTest

/// Expiring soon says when (the beta run's F24; plan 2026-10-16, Task 4.2): expired first, each row's date in words.
final class ExpiryWordsTests: XCTestCase {
    let zone = TimeZone(identifier: "America/New_York")!
    let now = ISO8601DateFormatter().date(from: "2026-10-16T15:00:00-04:00")!

    /// A day as the inventory stores it: seconds at UTC midnight.
    func day(_ text: String) -> Double { InventoryValues.parseDay(text)! }

    func testExpiryWords() {
        XCTAssertEqual(ExpiryWords.line(day("2026-10-02"), now: now, timeZone: zone), .expired("Expired Oct 2"))
        XCTAssertEqual(ExpiryWords.line(day("2026-10-20"), now: now, timeZone: zone), .soon("Expires Oct 20"))
        XCTAssertEqual(ExpiryWords.line(day("2026-10-16"), now: now, timeZone: zone), .soon("Expires today"))
    }

    func testTodayIsTheStoredDayNotTheUTCDay() {
        // late in the evening in New York it is already the next day in UTC; the stored day is the calendar day
        let evening = ISO8601DateFormatter().date(from: "2026-10-16T22:30:00-04:00")!
        XCTAssertEqual(ExpiryWords.line(day("2026-10-16"), now: evening, timeZone: zone), .soon("Expires today"))
        XCTAssertEqual(ExpiryWords.line(day("2026-10-15"), now: evening, timeZone: zone), .expired("Expired Oct 15"))
    }

    func testAnotherYearShowsTheYear() {
        XCTAssertEqual(ExpiryWords.line(day("2025-12-30"), now: now, timeZone: zone), .expired("Expired Dec 30, 2025"))
        XCTAssertEqual(ExpiryWords.line(day("2027-01-05"), now: now, timeZone: zone), .soon("Expires Jan 5, 2027"))
    }

    func testEarliestFirst() {
        let days = [day("2026-10-20"), day("2026-10-02"), day("2026-11-01"), day("2026-10-16")]
        XCTAssertEqual(days.sorted(by: ExpiryWords.earlier), [day("2026-10-02"), day("2026-10-16"), day("2026-10-20"),
                                                               day("2026-11-01")])
    }
}
