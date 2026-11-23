@testable import PrepareMeShared
import XCTest

/// Quick add's Undo list (whole-plan review): an Undo that timed out while its scan was still being sent puts the scan
/// back where it was, by when it was made, so the next Undo still takes back the latest scan.
final class UndoListTests: XCTestCase {
    struct Scan: Equatable {
        let name: String
        let at: Double
    }

    func put(_ scan: Scan, _ log: [Scan]) -> [String] {
        var log = log
        UndoList.putBack(scan, into: &log, madeAt: \.at)
        return log.map(\.name)
    }

    func testATimedOutUndoGoesBackBeforeAScanMadeDuringItsWait() {
        let a = Scan(name: "A", at: 10), b = Scan(name: "B", at: 20), x = Scan(name: "X", at: 5)
        XCTAssertEqual(put(a, [x, b]), ["X", "A", "B"], "B, scanned during the wait, stays the next Undo")
        XCTAssertEqual(put(a, [b]), ["A", "B"], "X undone during the wait: A is still older than B")
        XCTAssertEqual(put(a, [x]), ["X", "A"], "nothing newer: at the end, as before")
        XCTAssertEqual(put(a, []), ["A"])
        XCTAssertEqual(put(b, [x, a, Scan(name: "C", at: 30)]), ["X", "A", "B", "C"])
    }
}
