@testable import PrepareMeShared
import XCTest

/// Library redesign plan, Task 1.1 (owner, 2026-11-13): the Download button's place shows what the download is doing.
final class DownloadRowTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let src = "https://download.kiwix.org/zim/a.zim.meta4"

    func row(running: [String: (done: Int64, total: Int64, started: Date, from: Int64)] = [:], queued: [String] = [],
             runningTitle: String? = nil, kept: Set<String> = [], place: String? = nil) -> DownloadRow {
        DownloadRow.state(source: src, running: running, queued: queued, runningTitle: runningTitle,
                          keptSources: kept, place: place, now: now)
    }

    /// Phase 1 review, a deferred minor: after Pause the row said "Download" with no sign a part was kept.
    func testStoppedPartWaySaysResume() {
        let r = DownloadRow.state(source: src, running: [:], queued: [], runningTitle: nil, keptSources: [],
                                  place: nil, now: now, pausedSources: [src])
        XCTAssertEqual(r, .paused)
        XCTAssertEqual(r.words, "Resume")
        let running = DownloadRow.state(source: src, running: [src: (1, 10, now, 0)], queued: [], runningTitle: nil,
                                        keptSources: [], place: nil, now: now, pausedSources: [src])
        guard case .running = running else { return XCTFail("running wins: \(running)") }
        XCTAssertEqual(row(), .ready, "no part: Download")
    }

    func testReadyWhenUnknown() {
        XCTAssertEqual(row(), .ready)
    }

    func testRunningShowsBytesAndMinutes() {
        let r = row(running: [src: (18_000_000, 43_000_000, now.addingTimeInterval(-60), 0)])
        guard case .running(18_000_000, 43_000_000, let left?) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(left, 84, "25 MB left at 300 KB a second")
        XCTAssertEqual(r.words, "Downloading · 18 MB of 43 MB · about 1 minute left")
        let slow = row(running: [src: (6_000_000, 43_000_000, now.addingTimeInterval(-60), 0)])
        XCTAssertEqual(slow.words, "Downloading · 6 MB of 43 MB · about 6 minutes left")
    }

    func testNoMinutesInFirstFiveSeconds() {
        let r = row(running: [src: (1_000_000, 43_000_000, now.addingTimeInterval(-3), 0)])
        XCTAssertEqual(r, .running(done: 1_000_000, total: 43_000_000, secondsLeft: nil))
        XCTAssertEqual(r.words, "Downloading · 1 MB of 43 MB")
        let none = row(running: [src: (0, 43_000_000, now.addingTimeInterval(-60), 0)])
        XCTAssertEqual(none, .running(done: 0, total: 43_000_000, secondsLeft: nil), "nothing yet: no guess")
    }

    func testBeforeTheFirstReportOnlyDownloading() {
        XCTAssertEqual(row(running: [src: (0, 0, now, 0)]).words, "Downloading", "never \"0 KB of 0 KB\"")
    }

    func testResumeCountsOnlyTheNewBytes() {
        // resumed at 4 GB of 5 GB: 6 MB in 6 s is 1 MB a second, so about 17 minutes, never "about 1 minute"
        let r = row(running: [src: (4_006_000_000, 5_000_000_000, now.addingTimeInterval(-6), 4_000_000_000)])
        XCTAssertEqual(r.words, "Downloading · 4.0 GB of 5.0 GB · about 17 minutes left")
    }

    func testThrottlePassesTwiceASecondAndTheEnd() {
        let gate = ProgressThrottle(every: 0.5)
        XCTAssertTrue(gate.pass(done: 1, total: 10, now: now))
        XCTAssertFalse(gate.pass(done: 2, total: 10, now: now.addingTimeInterval(0.1)), "a chunk a moment later waits")
        XCTAssertTrue(gate.pass(done: 3, total: 10, now: now.addingTimeInterval(0.6)))
        XCTAssertTrue(gate.pass(done: 10, total: 10, now: now.addingTimeInterval(0.61)), "the last chunk always shows")
    }

    func testWaitingNamesTheOneAhead() {
        let r = row(queued: [src], runningTitle: "FEMA handbook")
        XCTAssertEqual(r, .waiting(behind: "FEMA handbook"))
        XCTAssertEqual(r.words, "Waiting · starts when FEMA handbook finishes")
    }

    func testKeptWithPlace() {
        let r = row(kept: [src], place: "📖 Books › Homesteading")
        XCTAssertEqual(r.words, "✓ On this Mac · in 📖 Books › Homesteading")
    }

    func testKeptWithoutPlace() {
        XCTAssertEqual(row(kept: [src]).words, "✓ On this Mac")
    }

    func testSecondClickWhileRunningStaysRunning() {
        let r = row(running: [src: (5, 10, now, 0)], queued: [src], runningTitle: "Other")
        guard case .running = r else { return XCTFail("\(r)") }
    }
}
