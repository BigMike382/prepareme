import Foundation
@testable import PrepareMeShared
import XCTest

/// Changes waiting on the phone for the Mac (remaining-findings plan, Task 12.3; F34).
final class WaitingChangesTests: XCTestCase {
    func testWaitingChangesRetryWhileOpen() {
        XCTAssertEqual(WaitingChanges.next(waiting: 2), 30, "anywhere in the app, Inventory included")
        XCTAssertNil(WaitingChanges.next(waiting: 0), "nothing to send: no tries")
        XCTAssertEqual(WaitingChanges.lookEvery, 120, "Inventory's own look, apart from the tries")
        XCTAssertEqual(WaitingChanges.line(1, device: "phone"),
                       "1 change waiting for the Mac. It goes once you're home and the Mac is on.")  // B2-17
        XCTAssertEqual(WaitingChanges.line(3, device: "iPad"),
                       "3 changes waiting for the Mac. They go once you're home and the Mac is on.")
    }

    /// The whole-plan review: the line and Send now count only the changes Send now sends, never a Used 1 or 1 more
    /// still held for its Undo (nor one made after it, which waits with it); held alone, no line shows.
    func testTheLineCountsOnlyWhatSendNowSends() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var outbox = PhoneOutbox()
        outbox.add(.adjust(row: 1, by: 1), what: "Water: 1 more", now: now)
        XCTAssertEqual(WaitingChanges.waiting(outbox, now: now), 1)
        outbox.add(.adjust(row: 2, by: -1), what: "Rice: used 1", now: now, withUndo: true)
        outbox.add(.adjust(row: 3, by: 1), what: "Beans: 1 more", now: now)
        XCTAssertEqual(WaitingChanges.waiting(outbox, now: now), 1, "the held one and the one after it go in a moment")
        XCTAssertEqual(WaitingChanges.waiting(outbox, now: now), outbox.ready(now: now).count, "what Send now sends")
        XCTAssertEqual(WaitingChanges.waiting(outbox, now: now.addingTimeInterval(PhoneOutbox.undoFor + 1)), 3,
                       "its Undo over: all three wait")
        var held = PhoneOutbox()
        held.add(.adjust(row: 2, by: -1), what: "Rice: used 1", now: now, withUndo: true)
        XCTAssertEqual(WaitingChanges.waiting(held, now: now), 0, "no line while the Undo shows")
    }

    /// Offline fixes, task 1.1: a waiting-changes file that can't be read, and a save that fails, are said.
    func testTheMacHasTheChangeLine() {
        XCTAssertEqual(WaitingChanges.line(1, taken: 1, device: "phone"),
                       "The Mac has 1 change from this phone; PrepareMe on the Mac needs to be open to keep it.")
        XCTAssertEqual(WaitingChanges.line(2, taken: 2, device: "iPad"),
                       "The Mac has 2 changes from this iPad; PrepareMe on the Mac needs to be open to keep them.")
        XCTAssertEqual(WaitingChanges.line(2, taken: 1, device: "phone"), WaitingChanges.line(2, device: "phone"))
        XCTAssertEqual(WaitingChanges.line(1, device: "phone"),
                       "1 change waiting for the Mac. It goes once you're home and the Mac is on.")
    }

    func testTheUnreadableAndNotSavedLines() {
        XCTAssertEqual(WaitingChanges.unreadable(device: "phone"),
                       "The changes waiting on this phone couldn't be read, so they're kept as they are; tell the adult "
                           + "who set up PrepareMe.")
        XCTAssertEqual(WaitingChanges.notSaved(device: "phone"),
                       "A change couldn't be saved on this phone (is it full?). It stays until the app is closed.")
        XCTAssertEqual(WaitingChanges.notSaved(device: "iPad"),
                       "A change couldn't be saved on this iPad (is it full?). It stays until the app is closed.")
    }
}
