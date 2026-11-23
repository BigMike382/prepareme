import Foundation
import PrepareMeShared
import XCTest

/// The Mac app's status lines (plan phase 6) from the jobs' records, in fixed words only: the hourly job's skips
/// (phase 0.2's `skip_streak`, worded as scheduler/notice.py's SKIPPED_RUNS) and the phones' service's.
final class MacStatusTests: XCTestCase {
    func record(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testFourSkippedStartsInARowSayTheHourlyJobIsntRefreshingAndWhy() {
        let data = record(["skip_streak": 4, "extra": ["skipped": "uncommitted"]])
        XCTAssertEqual(MacStatus.skippedLine(dashboardRecord: data),
                       "Not refreshing: the hourly conditions job has skipped its last 4 starts (a change to "
                       + "PrepareMe's code on this Mac isn't finished).")
        let branch = record(["skip_streak": 9, "extra": ["skipped": "not main"]])
        XCTAssertEqual(MacStatus.skippedLine(dashboardRecord: branch),
                       "Not refreshing: the hourly conditions job has skipped its last 9 starts (PrepareMe's folder on "
                       + "this Mac is set to a test version).")
    }

    func testFewerSkipsNoRecordOrAnOddRecordSayNothing() {
        XCTAssertNil(MacStatus.skippedLine(dashboardRecord: record(["skip_streak": 3])))
        XCTAssertNil(MacStatus.skippedLine(dashboardRecord: nil))
        XCTAssertNil(MacStatus.skippedLine(dashboardRecord: Data("not json".utf8)))
        XCTAssertNil(MacStatus.skippedLine(dashboardRecord: record(["skip_streak": "4"])))
        XCTAssertNil(MacStatus.skippedLine(dashboardRecord: record(["skip_streak": true])))
        XCTAssertNil(MacStatus.skippedLine(dashboardRecord: record(["skip_streak": 4.5])))
    }

    func testAnUnknownReasonIsSaidInFixedWordsNeverAsWritten() {
        let data = record(["skip_streak": 5, "extra": ["skipped": "something else entirely"]])
        XCTAssertEqual(MacStatus.skippedLine(dashboardRecord: data),
                       "Not refreshing: the hourly conditions job has skipped its last 5 starts (it couldn't run).")
    }

    func testTheNoticeLinesAreReadInOrderAndAnOddFileSaysNothing() {
        let data = record(["seen": ["guide-error:x"], "lines": ["Library: 1 guide hit an error.", "", 3, "Second."],
                           "at": "2026-10-27T09:00:00-04:00"])
        XCTAssertEqual(MacStatus.noticeLines(data), ["Library: 1 guide hit an error.", "Second."])
        XCTAssertEqual(MacStatus.noticeLines(nil), [])
        XCTAssertEqual(MacStatus.noticeLines(Data("not json".utf8)), [])
        XCTAssertEqual(MacStatus.noticeLines(record(["lines": "one line"])), [])
    }

    func testTheServiceLineSaysWhatTheOwnerCanDo() {
        XCTAssertEqual(MacStatus.serviceLine(.running), "Devices' service: running")
        XCTAssertEqual(MacStatus.serviceLine(.needsApproval),
                       "Devices' service waits for your OK: System Settings › General › Login Items & Extensions")
        XCTAssertEqual(MacStatus.serviceLine(.notAnswering),
                       "Devices' service isn't answering; devices can't get new files. Quit and reopen PrepareMe; if it "
                       + "stays, restart the Mac.")
        XCTAssertEqual(MacStatus.serviceLine(.notStarted(code: 1)),
                       "Devices' service couldn't be started (macOS error 1); devices can't get new files")
        XCTAssertEqual(MacStatus.serviceLine(.otherOnPort),
                       "Devices' service: another program on this Mac is answering in its place; devices may not get "
                       + "new files")
        XCTAssertNil(MacStatus.serviceLine(.notChecked))
    }

    func testAHealthyServiceAsksForNoAttention() {
        XCTAssertNil(MacStatus.serviceProblem(.notChecked))
        XCTAssertNil(MacStatus.serviceProblem(.running))
        for state: MacStatus.Service in [.needsApproval, .notAnswering, .otherOnPort, .notStarted(code: 1)] {
            XCTAssertNotNil(MacStatus.serviceProblem(state))
            XCTAssertEqual(MacStatus.serviceProblem(state), MacStatus.serviceLine(state))
        }
        XCTAssertNil(MacStatus.attention(problem: nil, refusal: nil, service: MacStatus.serviceProblem(.running),
                                         skipped: nil, phones: nil))
    }

    func entry(_ name: String, _ sha: Character, id: String) -> Manifest.Entry {
        Manifest.Entry(name: name, id: id, kind: "library", size: 1, sha256: String(repeating: sha, count: 64),
                       deliveredAt: "2026-10-13T12:00:00-04:00")
    }

    func testUpToDateCountsOnlyTheListsCurrentCopies() {
        let daily = entry("prepareme-daily.zim", "a", id: "0f1e2d3c-4b5a-4968-8776-6554433221a1")
        let guides = entry("prepareme-guides.zim", "b", id: "0f1e2d3c-4b5a-4968-8776-6554433221a2")
        var record = LibraryRecord(manifest: Manifest(writtenAt: "x", files: [daily, guides]))
        record.held["prepareme-daily.zim"] = HeldFile(entry: daily, file: "d")
        record.held["prepareme-guides.zim"] = HeldFile(entry: guides, file: "g")
        XCTAssertEqual(MacStatus.libraryLine(record, checked: "6:30 PM"), "2 files the same as the devices' copies, checked 6:30 PM")
        let newer = entry("prepareme-guides.zim", "c", id: "0f1e2d3c-4b5a-4968-8776-6554433221a2")
        record.manifest = Manifest(writtenAt: "y", files: [daily, newer])  // its newer copy was refused: the old stays
        record.refusals[newer.sha256] = 2
        XCTAssertEqual(MacStatus.libraryLine(record, checked: "6:30 PM"), "1 of 2 files current, checked 6:30 PM")
    }

    func testTheAttentionLineIsTheFirstProblemInOrder() {
        XCTAssertEqual(MacStatus.attention(problem: "p", refusal: "r", service: "s", skipped: "k", phones: "i"), "p")
        XCTAssertEqual(MacStatus.attention(problem: nil, refusal: "r", service: "s", skipped: "k", phones: "i"), "r")
        XCTAssertEqual(MacStatus.attention(problem: nil, refusal: nil, service: "s", skipped: "k", phones: "i"), "s")
        XCTAssertEqual(MacStatus.attention(problem: nil, refusal: nil, service: nil, skipped: "k", phones: "i"), "k")
        XCTAssertEqual(MacStatus.attention(problem: nil, refusal: nil, service: nil, skipped: nil, phones: "i"), "i")
        XCTAssertEqual(MacStatus.attention(problem: nil, refusal: nil, service: nil, skipped: "k", backup: "b",
                                           phones: "i"), "k")
        XCTAssertEqual(MacStatus.attention(problem: nil, refusal: nil, service: nil, skipped: nil, backup: "b",
                                           phones: "i"), "b")  // the iCloud backup's, before the phones' inventory
    }

    func testSettingsTabsInOrder() {  // six tabs (owner, 2026-11-14); Players after Household (players plan, stage 2)
        XCTAssertEqual(MacStatus.Tab.allCases.map(\.rawValue),
                       ["general", "household", "players", "library", "phones", "backups", "about"])
    }

    func testOpenSettingsOpensTheTabItsLineIsOn() {  // the five tabs (owner, 2026-10-23)
        XCTAssertEqual(MacStatus.attentionLine(problem: "p", refusal: nil, service: "s", skipped: nil, phones: nil)?.tab,
                       .library)
        XCTAssertEqual(MacStatus.attentionLine(problem: "", refusal: nil, service: "s", skipped: nil, phones: nil)?.tab,
                       .phones)
        XCTAssertEqual(MacStatus.attentionLine(problem: nil, refusal: nil, service: nil, skipped: nil, backup: "b",
                                              phones: "i")?.tab, .backups)
        XCTAssertEqual(MacStatus.attentionLine(problem: nil, refusal: nil, service: nil, skipped: nil, drive: "d",
                                              phones: "i")?.tab, .backups)
        XCTAssertEqual(MacStatus.attentionLine(problem: nil, refusal: nil, service: nil, skipped: nil, phones: "i")?.tab,
                       .phones)
        XCTAssertNil(MacStatus.attentionLine(problem: nil, refusal: nil, service: nil, skipped: nil, phones: nil))
    }

    func testAnOldLibrarySaysWhenItsGuidesWereMadeNotThatItIsUpToDate() {  // beta run 2, B2-20
        func old(_ name: String, _ sha: Character, _ id: String, asOf: String?) -> Manifest.Entry {
            Manifest.Entry(name: name, id: id, kind: "library", size: 1, sha256: String(repeating: sha, count: 64),
                           deliveredAt: "2026-10-20T18:44:00-04:00", libraryAsOf: asOf)
        }
        let zone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-10-20T19:00:00-04:00")!
        // the guides live in prepareme-daily.zim (packer/volumes.toml)
        let daily = old("prepareme-daily.zim", "a", "0f1e2d3c-4b5a-4968-8776-6554433221a1", asOf: "2026-10-12T08:41-04:00")
        let guides = old("prepareme-reference.zim", "b", "0f1e2d3c-4b5a-4968-8776-6554433221a2", asOf: "2026-10-08T06:00-04:00")
        var record = LibraryRecord(manifest: Manifest(writtenAt: "x", files: [daily, guides]))
        record.held[daily.name] = HeldFile(entry: daily, file: "d")
        record.held[guides.name] = HeldFile(entry: guides, file: "g")
        XCTAssertEqual(MacStatus.libraryLine(record, checked: "6:30 PM", now: now, timeZone: zone),
                       "2 files the same as the devices' copies; the guides were made Oct 12, checked 6:30 PM")
        // no prepareme-daily.zim in the list: the oldest library is named instead
        var rest = LibraryRecord(manifest: Manifest(writtenAt: "x", files: [guides]))
        rest.held[guides.name] = HeldFile(entry: guides, file: "r")
        XCTAssertEqual(MacStatus.libraryLine(rest, checked: "6:30 PM", now: now, timeZone: zone),
                       "1 file the same as the devices' copies; the oldest library was made Oct 8, checked 6:30 PM")
        // no library date in the list (an older list): no date is made up
        let bare = old("prepareme-daily.zim", "a", "0f1e2d3c-4b5a-4968-8776-6554433221a1", asOf: nil)
        var plain = LibraryRecord(manifest: Manifest(writtenAt: "x", files: [bare]))
        plain.held[bare.name] = HeldFile(entry: bare, file: "d")
        XCTAssertEqual(MacStatus.libraryLine(plain, checked: "6:30 PM", now: now, timeZone: zone),
                       "1 file the same as the devices' copies, checked 6:30 PM")
    }

    func testARefusalAsksForAttentionOnlyWhileItStands() {
        let daily = entry("prepareme-daily.zim", "a", id: "0f1e2d3c-4b5a-4968-8776-6554433221a1")
        var record = LibraryRecord(manifest: Manifest(writtenAt: "x", files: [daily]))
        XCTAssertNil(MacStatus.standingRefusal("Oct 15, 2026, prepareme-daily.zim: why", record))
        record.refusals[daily.sha256] = 1
        XCTAssertEqual(MacStatus.standingRefusal("Oct 15, 2026, prepareme-daily.zim: why", record),
                       "Oct 15, 2026, prepareme-daily.zim: why")
        XCTAssertNil(MacStatus.standingRefusal(nil, record))
        LibraryPlan.forgetOldRefusals(Manifest(writtenAt: "y", files: []), &record)  // the folder no longer offers it
        XCTAssertNil(MacStatus.standingRefusal("Oct 15, 2026, prepareme-daily.zim: why", record))
        XCTAssertNil(MacStatus.attention(problem: nil, refusal: MacStatus.standingRefusal("r", record), service: nil,
                                         skipped: nil, phones: nil))
    }

    /// Remaining-findings plan, Task 9.3 (F43): Settings' line follows the sidebar's rule, so an old refusal for a
    /// file this Mac no longer offers isn't shown for days.
    func testOldRefusalForAFileNotOfferedIsNotShown() {
        let daily = entry("prepareme-daily.zim", "a", id: "0f1e2d3c-4b5a-4968-8776-6554433221a1")
        var record = LibraryRecord(manifest: Manifest(writtenAt: "x", files: [daily]))
        record.refusals[daily.sha256] = 1
        XCTAssertEqual(MacStatus.refusalLine("Oct 15, 2026, Guides and today's page: why", record),
                       "Last copy refused by its checks: Oct 15, 2026, Guides and today's page: why")
        LibraryPlan.forgetOldRefusals(Manifest(writtenAt: "y", files: []), &record)  // the folder no longer offers it
        XCTAssertNil(MacStatus.refusalLine("Oct 13, 2026, Guides and today's page: why", record))
    }

    func testTheAttentionLineSkipsBlankLinesAndSaysNothingWhenAllClear() {
        XCTAssertEqual(MacStatus.attention(problem: "", refusal: nil, service: "s", skipped: nil, phones: nil), "s")
        XCTAssertEqual(MacStatus.attention(problem: nil, refusal: nil, service: nil, skipped: "", phones: "i"), "i")
        XCTAssertNil(MacStatus.attention(problem: "", refusal: "", service: "", skipped: "", phones: ""))
        XCTAssertNil(MacStatus.attention(problem: nil, refusal: nil, service: nil, skipped: nil, phones: nil))
    }
}
