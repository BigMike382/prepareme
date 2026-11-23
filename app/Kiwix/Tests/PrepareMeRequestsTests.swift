// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household's Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import XCTest
@testable import Kiwix

/// PrepareMe: the two sidebar buttons touch their request files, and the status line reads the Mac's job's
/// status.json (dashboard/quick.py) in fixed words. Everything runs in a temporary home, never the real one.
final class PrepareMeRequestsTests: XCTestCase {
    private var home: URL!
    private var folder: URL { home.appending(path: "Library/Application Support/PrepareMe/requests") }

    /// Each test starts with a temporary home and no press, and puts both back after
    @MainActor
    private func useTemporaryHome() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        self.home = home
        PrepareMeRequests.homeOverride = home
        PrepareMeRequests.lastPress = nil
        addTeardownBlock { @MainActor in
            PrepareMeRequests.homeOverride = nil
            PrepareMeRequests.lastPress = nil
            try? FileManager.default.removeItem(at: home)
        }
    }

    /// The short time style in the local zone, made here independently of the app's own formatter
    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// An ISO 8601 time with its offset, as Python's isoformat(timespec="seconds") writes it
    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: -4 * 3600)
        return formatter.string(from: date)
    }

    private func writeStatus(_ text: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appending(path: "status.json"))
    }

    private func modified(_ name: String) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    // MARK: - Pressing

    @MainActor
    func testPressCreatesEachFileAndTouchesItAgain() throws {
        try useTemporaryHome()
        for (kind, name) in [(PrepareMeRequests.Kind.refresh, "refresh-conditions"), (.checkOnce, "check-once")] {
            try PrepareMeRequests.press(kind)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: name).path), name)
            let past = Date(timeIntervalSinceNow: -3600)
            try FileManager.default.setAttributes([.modificationDate: past],
                                                  ofItemAtPath: folder.appending(path: name).path)
            try PrepareMeRequests.press(kind)
            XCTAssertGreaterThan(try modified(name), past.addingTimeInterval(60), name)
            XCTAssertEqual(try Data(contentsOf: folder.appending(path: name)).count, 0, name)
        }
    }

    /// A link by the file's name is never followed: the press fails and counts as no press
    @MainActor
    func testALinkNamedCheckOnceMakesThePressFail() throws {
        try useTemporaryHome()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = home.appending(path: "elsewhere")
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "check-once"), withDestinationURL: target)
        let before = Date(timeIntervalSinceNow: -600)
        PrepareMeRequests.lastPress = before
        XCTAssertThrowsError(try PrepareMeRequests.press(.checkOnce))
        XCTAssertEqual(PrepareMeRequests.lastPress, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing made through the link")
    }

    // MARK: - The status line

    @MainActor
    func testEachStatusGivesItsWords() throws {
        try useTemporaryHome()
        let at = Date(timeIntervalSinceNow: -120).rounded()
        let until = Date(timeIntervalSinceNow: 3 * 3600).rounded()
        let cases: [(String, String)] = [
            (#"{"state": "refreshing", "at": "\#(iso(at))", "until": "\#(iso(until))"}"#,
             "Refreshing every 15 minutes until \(clock(until))"),
            (#"{"state": "checked", "at": "\#(iso(at))", "until": null}"#, "Checked at \(clock(at))"),
            (#"{"state": "offline", "at": "\#(iso(at))", "until": null}"#,
             "No internet at the last try (\(clock(at)))"),
            (#"{"state": "offline", "at": "\#(iso(at))", "until": "\#(iso(until))"}"#,
             "No internet at the last try (\(clock(at))); refreshing until \(clock(until))"),
            (#"{"state": "busy", "at": "\#(iso(at))", "until": null}"#,
             "Waiting: another PrepareMe job is running (\(clock(at)))"),
        ]
        for (json, words) in cases {
            try writeStatus(json)
            XCTAssertEqual(PrepareMeRequests.statusLine(now: .now), words, json)
        }
    }

    /// A cycle whose end has passed is no longer shown as refreshing
    @MainActor
    func testAnEndedCycleIsNotShownAsRefreshing() throws {
        try useTemporaryHome()
        let at = Date(timeIntervalSinceNow: -3 * 3600).rounded()
        let until = Date(timeIntervalSinceNow: -60).rounded()
        try writeStatus(#"{"state": "refreshing", "at": "\#(iso(at))", "until": "\#(iso(until))"}"#)
        XCTAssertEqual(PrepareMeRequests.statusLine(now: .now), "Checked at \(clock(at))")
        try writeStatus(#"{"state": "offline", "at": "\#(iso(at))", "until": "\#(iso(until))"}"#)
        XCTAssertEqual(PrepareMeRequests.statusLine(now: .now), "No internet at the last try (\(clock(at)))")
    }

    @MainActor
    func testAnUnknownKeyOrUnreadableFileShowsNothing() throws {
        try useTemporaryHome()
        XCTAssertNil(PrepareMeRequests.statusLine(now: .now), "no file")
        for json in [#"{"state": "sleeping", "at": "\#(iso(.now))", "until": null}"#, "[", "",
                     #"{"state": "checked", "at": "yesterday", "until": null}"#,
                     #"{"state": "refreshing", "at": "\#(iso(.now))", "until": null}"#] {
            try writeStatus(json)
            XCTAssertNil(PrepareMeRequests.statusLine(now: .now), json)
        }
    }

    @MainActor
    func testAPressNewerThanTheStatusWaitsThenSaysTheJobHasntAnswered() throws {
        try useTemporaryHome()
        try writeStatus(#"{"state": "checked", "at": "\#(iso(Date(timeIntervalSinceNow: -3600)))", "until": null}"#)
        try PrepareMeRequests.press(.refresh)
        let pressed = try XCTUnwrap(PrepareMeRequests.lastPress)
        XCTAssertEqual(PrepareMeRequests.statusLine(now: pressed.addingTimeInterval(60)),
                       "Asked at \(clock(pressed)); waiting for the Mac's job")
        XCTAssertEqual(PrepareMeRequests.statusLine(now: pressed.addingTimeInterval(17 * 60)),
                       "The Mac's job hasn't answered since \(clock(pressed))")
    }

    @MainActor
    func testAPressWithNoStatusYetWaits() throws {
        try useTemporaryHome()
        try PrepareMeRequests.press(.checkOnce)
        let pressed = try XCTUnwrap(PrepareMeRequests.lastPress)
        XCTAssertEqual(PrepareMeRequests.statusLine(now: pressed.addingTimeInterval(60)),
                       "Asked at \(clock(pressed)); waiting for the Mac's job")
    }

    /// The job writes its time in whole seconds, so an answer in the same second as the press still counts.
    @MainActor
    func testAnAnswerInThePressSecondCounts() throws {
        try useTemporaryHome()
        try PrepareMeRequests.press(.checkOnce)
        let pressed = try XCTUnwrap(PrepareMeRequests.lastPress)
        let answered = Date(timeIntervalSince1970: pressed.timeIntervalSince1970.rounded(.down))
        try writeStatus(#"{"state": "checked", "at": "\#(iso(answered))", "until": null}"#)
        XCTAssertEqual(PrepareMeRequests.statusLine(now: pressed.addingTimeInterval(60)),
                       "Checked at \(clock(answered))")
    }
}

private extension Date {
    /// To the whole second, as the job writes its times
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
#endif
