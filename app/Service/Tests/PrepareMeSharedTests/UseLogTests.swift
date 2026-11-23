import Foundation
@testable import PrepareMeShared
import XCTest

/// "Runs out on" during an event (step 8c plan, section 4): the Mac's use log, when event mode came on, the phones'
/// copy of the log, and the phone's run-out line. Made-up rehearsal copies and made-up events only.
@MainActor
final class UseLogTests: XCTestCase {
    var base: URL!
    var check: FakeCheck!
    var editor: InventoryEditor!
    let iso = ISO8601DateFormatter()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-uselog-\(UUID())")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        let url = base.appendingPathComponent("PrepareMe Inventory.grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        check = FakeCheck()
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: check)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    var inventory: Inventory { editor.inventory }
    func item(_ name: String) -> InventoryRow { inventory.itemRows.first { inventory.name(ofItem: $0) == name }! }
    func quantity(_ name: String) -> SQLValue { item(name)[inventory.items.column("Quantity")!] }
    var jugs: InventoryRow { item("Drinking water jugs") }
    var flashlight: InventoryRow { item("Test flashlight") }  // read by the count, in no supply
    var heater: InventoryRow { item("Indoor propane heater") }  // a Private ("Mac only") row
    func near(_ a: Date, _ b: Date, _ seconds: TimeInterval = 5) -> Bool { abs(a.timeIntervalSince(b)) < seconds }

    /// Made-up shares: the jugs' gallons by their row and Item, the Private heater's by its row number and Item, and
    /// the flashlight read by the count in no supply.
    var shares: SupplyShares {
        SupplyShares(format: 1, today: "2026-10-20", supplies: [
            .init(kind: "water", unit: "gallons", perDay: 2, days: 3, target: 30,
                  rows: [.init(row: jugs.position, per: 1, expires: nil, item: SupplyShares.fingerprint("Drinking water jugs"))],
                  other: [], privateRows: [.init(row: heater.position, per: 5,
                                                 item: SupplyShares.fingerprint("Indoor propane heater"))]),
            .init(kind: "food", unit: "calories", perDay: 8000, days: nil, target: 90, rows: [], other: [],
                  privateRows: []),
        ], uncountedRows: [.init(row: flashlight.position, item: SupplyShares.fingerprint("Test flashlight"),
                                 private: false)])
    }

    // MARK: The words

    func testTheWordsArePinned() {
        XCTAssertEqual(RunsOut.tooEarly, "Too early to tell")
        XCTAssertEqual(RunsOut.runsOut("Sat Oct 31"), "At the use so far: runs out Sat Oct 31")
        XCTAssertEqual(RunsOut.notCounted("Oct 20, 2:37 PM"), "Other phones' use since Oct 20, 2:37 PM isn't counted")
        XCTAssertEqual(RunsOut.someNotCounted("Oct 20, 2:37 PM"), "Some use since Oct 20, 2:37 PM can't be counted")
        XCTAssertEqual(RunsOut.rule, "The day it runs out divides what's left by what Used 1 has taken since event "
                       + "mode came on, on every phone. It's too early to tell in event mode's first 24 hours, or "
                       + "before a Used 1 on that supply.")
        XCTAssertEqual(RunsOut.earliest, 24 * 3600)
        XCTAssertEqual(RunsOut.copyStale, 3 * 3600)
        XCTAssertEqual(UseLog.keepDays, 90)
        XCTAssertEqual(InventoryFile.useLogTable, "PrepareMe_UseLog")
        XCTAssertEqual(EventModeFile.fileName, "event-mode.json")
    }

    // MARK: The Mac's log

    func testAUsedOneIsLoggedAndItsUndoRemovesItsRow() async throws {
        editor.useLogStart = .on(Date().addingTimeInterval(-3600))
        editor.useLogShares = shares
        let outcome = try await editor.apply(.adjust(row: jugs.id, by: -1))
        guard case .done(let undo, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"))
        let logged = try editor.file.useLog()
        XCTAssertEqual(logged.map(\.row), [jugs.id])
        XCTAssertEqual(logged.map(\.used), [1])
        XCTAssertEqual(logged.map(\.amounts), [["water": 1]], "valued as it's applied, from the shares as they stand")
        XCTAssertTrue(near(logged[0].at, Date()), "the Mac's own Used 1: now")
        guard case .revertUse(_, _, _, _, .remove(logged[0].id)) = undo else { return XCTFail("\(undo)") }
        guard case .done(let redo, _) = try await editor.apply(undo) else { return XCTFail("undo") }
        XCTAssertEqual(quantity("Drinking water jugs"), .text("6"))
        XCTAssertEqual(try editor.file.useLog(), [], "the undo removes its row")
        guard case .done = try await editor.apply(redo) else { return XCTFail("redo") }
        XCTAssertEqual(try editor.file.useLog().map(\.at), logged.map(\.at), "its redo keeps it again, at its time")
        XCTAssertEqual(try editor.file.useLog().map(\.amounts), [["water": 1]], "and at its value")
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"))
        XCTAssertNotNil(PhoneRules.refusal(undo, inventory), "the Mac's alone")
    }

    func testAPhonesTapIsLoggedAtItsOwnTimeOnce() async throws {
        editor.useLogStart = .on(Date().addingTimeInterval(-86_400))
        let tapped = Date().addingTimeInterval(-7200)
        let edit = PhoneEdit(change: .adjust(row: jugs.id, by: -1), at: iso.string(from: tapped))
        try JSONEncoder().encode(PhoneEdits(edits: [edit, edit]))
            .write(to: base.appendingPathComponent("inbox").appendingPathComponent("1-phone1-a.json"))
        try await PhoneInbox.process(folder: base, editor: editor)
        let logged = try editor.file.useLog()
        XCTAssertEqual(logged.count, 1, "a resend is never logged twice")
        XCTAssertTrue(near(logged[0].at, tapped, 1), "the phone's own tap time")
        let ahead = PhoneEdit(change: .adjust(row: jugs.id, by: -1), at: iso.string(from: Date().addingTimeInterval(9999)))
        try JSONEncoder().encode(PhoneEdits(edits: [ahead]))
            .write(to: base.appendingPathComponent("inbox").appendingPathComponent("2-phone1-b.json"))
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertTrue(near(try editor.file.useLog().last!.at, Date()), "a phone's clock ahead of the Mac's: now")
        var outbox = PhoneOutbox()
        let id = outbox.add(.adjust(row: jugs.id, by: -1), what: "Water jugs: used 1", now: tapped)
        XCTAssertEqual(outbox.pending.first { $0.id == id }?.edit.at, iso.string(from: tapped), "the phone keeps it")
    }

    func testKeptOnlySinceEventModeCameOnAndNoOlderThan90Days() async throws {
        let now = Date()
        func tap(_ ago: TimeInterval, _ id: String) async throws {
            _ = try await editor.apply(.adjust(row: jugs.id, by: -0.1),
                                       phone: .init(id: id, phone: "phone1", at: now.addingTimeInterval(-ago)))
        }
        editor.useLogStart = .unknown
        try await tap(100 * 86_400, "a")  // older than 90 days: gone at once
        try await tap(10 * 86_400, "b")
        XCTAssertEqual(try editor.file.useLog().count, 1)
        editor.useLogStart = .on(now.addingTimeInterval(-2 * 86_400))
        try await tap(3600, "c")
        let kept = try editor.file.useLog()
        XCTAssertEqual(kept.count, 1, "the tap from before event mode came on goes")
        XCTAssertTrue(near(kept[0].at, now.addingTimeInterval(-3600)))
        editor.useLogStart = .off
        try await tap(60, "d")
        XCTAssertEqual(try editor.file.useLog(), [], "out of event mode nothing is logged, and the log empties")
        XCTAssertEqual(UseLog.keepFrom(.on(now.addingTimeInterval(-200 * 86_400)), now: now),
                       now.addingTimeInterval(-90 * 86_400), "never older than 90 days")
    }

    func testTheFirstTableShapeIsUnreadableNeverFatal() async throws {
        try editor.file.db.execute("""
            CREATE TABLE "PrepareMe_UseLog" (id INTEGER PRIMARY KEY, at TEXT NOT NULL, row INTEGER NOT NULL, \
            used REAL NOT NULL)
            """)
        try editor.file.db.execute("INSERT INTO \"PrepareMe_UseLog\" (at, row, used) VALUES (?, ?, 1)",
                                   [.text(iso.string(from: Date())), .int(jugs.id)])
        editor.useLogStart = .on(Date().addingTimeInterval(-3600))
        editor.useLogShares = shares
        XCTAssertThrowsError(try editor.file.useLog(), "no amounts column: unreadable")
        guard case .done = try await editor.apply(.adjust(row: jugs.id, by: -1)) else { return XCTFail("not kept") }
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"), "the Used 1 itself is kept")
        XCTAssertEqual(try editor.file.db.query("SELECT count(*) FROM \"PrepareMe_UseLog\"").first?[0].whole, 1,
                       "nothing added to a table it can't read")
    }

    func testAnUnreadableLogIsNeverFatal() async throws {
        try editor.file.db.execute("CREATE TABLE \"PrepareMe_UseLog\" (what TEXT)")
        editor.useLogStart = .on(Date().addingTimeInterval(-3600))
        XCTAssertThrowsError(try editor.file.useLog())
        guard case .done = try await editor.apply(.adjust(row: jugs.id, by: -1)) else { return XCTFail("not kept") }
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"), "the Used 1 itself is kept")
    }

    func testAGoingUpIsNeverAUse() async throws {
        editor.useLogStart = .on(Date().addingTimeInterval(-3600))
        _ = try await editor.apply(.adjust(row: jugs.id, by: 1))
        _ = try await editor.apply(.adjust(row: jugs.id, by: -100))  // floored at 0: 7 used, not 100
        XCTAssertEqual(try editor.file.useLog().map(\.used), [7])
    }

    // MARK: When event mode came on

    func testTheEventModeFileFromTheHourlyJob() throws {
        func write(_ text: String) throws { try Data(text.utf8).write(to: base.appendingPathComponent("event-mode.json")) }
        XCTAssertEqual(EventModeFile.start(EventModeFile.read(in: base)), .unknown, "no file yet")
        try write(#"{"format": 1, "mode": "event", "since": "2026-10-20T08:00:00-04:00", "written": "2026-10-20T14:07:00-04:00"}"#)
        XCTAssertEqual(EventModeFile.start(EventModeFile.read(in: base)), .on(iso.date(from: "2026-10-20T12:00:00Z")!))
        try write(#"{"format": 1, "mode": "preparing", "since": null, "written": "2026-10-20T14:07:00-04:00"}"#)
        XCTAssertEqual(EventModeFile.start(EventModeFile.read(in: base)), .off)
        for bad in [#"{"format": 2, "mode": "event", "since": null, "written": ""}"#,
                    #"{"format": 1, "mode": "storm", "since": null, "written": ""}"#, "not json"] {
            try write(bad)
            XCTAssertEqual(EventModeFile.start(EventModeFile.read(in: base)), .unknown, bad)
        }
    }

    // MARK: The phones' copy

    func testTheCopysLogIsAmountsOnlyAndSinceEventModeCameOn() throws {
        let since = Date().addingTimeInterval(-86_400)
        let entries = [UseLog.Entry(id: 1, at: since.addingTimeInterval(-60), row: jugs.id, used: 1, amounts: ["water": 1]),
                       UseLog.Entry(id: 2, at: since.addingTimeInterval(60), row: jugs.id, used: 2, amounts: ["water": 2]),
                       UseLog.Entry(id: 3, at: since.addingTimeInterval(120), row: heater.id, used: 1,
                                    amounts: ["water": 5]),
                       UseLog.Entry(id: 4, at: since.addingTimeInterval(180), row: flashlight.id, used: 1, amounts: [:]),
                       UseLog.Entry(id: 5, at: since.addingTimeInterval(240), row: 99_999, used: 1, amounts: nil),
                       UseLog.Entry(id: 6, at: since.addingTimeInterval(300), row: 99_998, used: 1, amounts: nil)]
        let log = PhoneUseLog.make(entries, since: since)
        XCTAssertEqual(log.taps.map(\.kind), ["water", "water"])
        XCTAssertEqual(log.taps.map(\.amount), [2, 5], "the stored amounts; a row in no supply adds none")
        XCTAssertEqual(log.unvalued, 2)
        XCTAssertEqual(log.unvaluedSince, iso.string(from: since.addingTimeInterval(240)), "the earliest")
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:], supply: shares, useLog: log)
        let json = String(decoding: try JSONEncoder().encode(copy.useLog), as: UTF8.self)
        for never in ["Drinking", "heater", "\"row\"", "\"item\""] {
            XCTAssertFalse(json.contains(never), never)
        }
        XCTAssertNil(copy.supply?.supplies[0].privateRows, "the Private rows' numbers never reach a phone")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(copy), as: UTF8.self).contains("private_rows"))
        let back = try JSONDecoder().decode(PhoneInventory.self, from: try JSONEncoder().encode(copy))
        XCTAssertEqual(back.useLog, log)
    }

    // MARK: The phone's line

    let now = ISO8601DateFormatter().date(from: "2026-10-22T16:00:00Z")!  // Thu Oct 22, 12:00 PM in New York

    func copy(written: Date, log: PhoneUseLog?) -> PhoneInventory {
        PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:], supply: shares, useLog: log, now: written)
    }

    var water: SupplyShares.Kind { shares.supplies[0] }

    func testTheRunOutDayAcrossDays() {
        let since = now.addingTimeInterval(-2 * 86_400)
        let log = PhoneUseLog(since: iso.string(from: since), taps: [
            .init(at: iso.string(from: since.addingTimeInterval(3600)), kind: "water", amount: 1),
            .init(at: iso.string(from: since.addingTimeInterval(30 * 3600)), kind: "water", amount: 1),
            .init(at: iso.string(from: since.addingTimeInterval(3600)), kind: "food", amount: 9000)])
        let found = copy(written: now.addingTimeInterval(-600), log: log)
        let have = SupplyShares.have(water, in: found, now: now)
        XCTAssertEqual(have, 6, "6 jugs of a gallon each")
        // 2 gallons in 2 days: 1 a day; 6 left: Wed Oct 28
        XCTAssertEqual(RunsOut.line(water, copy: found, log: log, own: [], have: have, now: now),
                       "At the use so far: runs out Wed Oct 28")
        XCTAssertEqual(RunsOut.line(water, copy: found, log: log, own: [], have: 0, now: now),
                       "At the use so far: runs out Thu Oct 22", "none left: today")
    }

    func testTooEarlyInTheFirstDayOrWithNoTaps() {
        let early = PhoneUseLog(since: iso.string(from: now.addingTimeInterval(-23 * 3600)),
                                taps: [.init(at: iso.string(from: now.addingTimeInterval(-3600)), kind: "water", amount: 5)])
        let found = copy(written: now, log: early)
        XCTAssertEqual(RunsOut.line(water, copy: found, log: early, own: [], have: 6, now: now), RunsOut.tooEarly)
        let none = PhoneUseLog(since: iso.string(from: now.addingTimeInterval(-3 * 86_400)), taps: [])
        XCTAssertEqual(RunsOut.line(water, copy: copy(written: now, log: none), log: none, own: [], have: 6, now: now),
                       RunsOut.tooEarly, "no Used 1 on it yet")
        XCTAssertEqual(RunsOut.line(water, copy: copy(written: now, log: none), log: none, own: [], have: nil, now: now),
                       RunsOut.tooEarly)
    }

    func testThisPhonesUnsentTapsCount() {
        let since = now.addingTimeInterval(-3 * 86_400)
        let log = PhoneUseLog(since: iso.string(from: since), taps: [])
        let found = copy(written: now.addingTimeInterval(-60), log: log)
        var outbox = PhoneOutbox()
        func tap(_ by: Double, _ at: Date) {
            let change = InventoryChange.adjust(row: jugs.id, by: by)
            outbox.add(change, what: "used", now: at, use: RunsOut.use(of: change, in: outbox.view(found)))
        }
        tap(-1, now.addingTimeInterval(-7200))
        tap(-2, now.addingTimeInterval(-3600))
        tap(1, now.addingTimeInterval(-1800))  // never a use
        tap(-1, since.addingTimeInterval(-60))  // before the event
        let own = RunsOut.ownTaps(outbox)
        XCTAssertEqual(own.map(\.amounts), [["water": 1], ["water": 2], ["water": 1]], "valued on the phone when tapped")
        XCTAssertNil(RunsOut.use(of: .adjust(row: jugs.id, by: 1), in: found), "going up is no use")
        // 3 gallons in 3 days, 6 left: 6 days on
        XCTAssertEqual(RunsOut.line(water, copy: found, log: log, own: own, have: 6, now: now),
                       "At the use so far: runs out Wed Oct 28")
    }

    func testOtherPhonesUseIsntCountedWhenTheCopyIsOld() {
        let log = PhoneUseLog(since: iso.string(from: now.addingTimeInterval(-3 * 86_400)),
                              taps: [.init(at: iso.string(from: now.addingTimeInterval(-86_400)), kind: "water", amount: 3)])
        let written = now.addingTimeInterval(-(3 * 3600 + 60))
        XCTAssertEqual(RunsOut.line(water, copy: copy(written: written, log: log), log: log, own: [], have: 6, now: now),
                       "Other phones' use since Oct 22, 8:59 AM isn't counted")
        let fresh = now.addingTimeInterval(-3 * 3600 + 60)
        XCTAssertEqual(RunsOut.line(water, copy: copy(written: fresh, log: log), log: log, own: [], have: 6, now: now),
                       "At the use so far: runs out Wed Oct 28", "under 3 hours old: counted")
    }

    func testNothingShowsOutsideEventMode() {
        let log = PhoneUseLog(since: iso.string(from: now.addingTimeInterval(-86_400)), taps: [])
        let on = copy(written: now, log: log), off = copy(written: now, log: nil)
        XCTAssertEqual(RunsOut.log(on, localSwitch: nil, localAt: nil), log, "the Mac says event mode is on")
        XCTAssertNil(RunsOut.log(off, localSwitch: nil, localAt: nil), "the Mac says it's off: no line")
        XCTAssertNil(RunsOut.log(on, localSwitch: "Off", localAt: now), "switched Off on this phone")
        XCTAssertNil(RunsOut.log(off, localSwitch: "Auto", localAt: now))
        XCTAssertEqual(RunsOut.log(off, localSwitch: "On", localAt: now),
                       PhoneUseLog(since: iso.string(from: now), taps: []), "switched On here, the Mac not told yet")
    }

    // MARK: The review's findings (2026-10-20): a tap is valued when it's applied, never dropped later

    func applied(_ shares: SupplyShares?) async throws -> PhoneUseLog {
        editor.useLogStart = .on(Date().addingTimeInterval(-2 * 86_400))
        editor.useLogShares = shares
        guard case .done = try await editor.apply(.adjust(row: jugs.id, by: -1)) else { throw CheckUnavailable(why: "x") }
        return PhoneUseLog.make(try editor.file.useLog(), since: Date().addingTimeInterval(-2 * 86_400))
    }

    func testATapOnARowDeletedSinceStillCounts() async throws {
        let id = jugs.id
        _ = try await applied(shares)
        guard case .done = try await editor.apply(.delete(table: "Inventory", row: id)) else { return XCTFail("delete") }
        let log = PhoneUseLog.make(try editor.file.useLog(), since: Date().addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(log.taps.map(\.amount), [1], "the last jug used up, then removed: still counted")
        XCTAssertEqual(log.unvalued, 0)
    }

    func testATapOnARowRenamedSinceStillCounts() async throws {
        _ = try await applied(shares)
        let name = inventory.items.column("Item")!.colId
        guard case .done = try await editor.apply(.set(table: "Inventory", row: jugs.id, colId: name,
                                                       value: .text("Big water jugs"))) else { return XCTFail("rename") }
        let log = PhoneUseLog.make(try editor.file.useLog(), since: Date().addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(log.taps.map(\.amount), [1], "valued under its old name, as the shares knew it")
    }

    func testARowAddedSinceTheCountCantBeCounted() async throws {
        let name = inventory.items.column("Item")!.colId, amount = inventory.items.column("Quantity")!.colId
        guard case .done(_, let added) = try await editor.apply(.add(table: "Inventory", values: [
            name: .text("Made-up water drum"), amount: .text("10")])) else { return XCTFail("add") }
        editor.useLogStart = .on(Date().addingTimeInterval(-2 * 86_400))
        editor.useLogShares = shares
        _ = try await editor.apply(.adjust(row: added, by: -1))
        let log = PhoneUseLog.make(try editor.file.useLog(), since: Date().addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(log.taps, [], "logged, unvalued, never dropped")
        XCTAssertEqual(log.unvalued, 1)
        let found = copy(written: Date(), log: log)
        let line = RunsOut.line(water, copy: found, log: log, own: [], have: 6, now: Date())
        XCTAssertTrue(line.hasPrefix("Some use since ") && line.hasSuffix(" can't be counted"), line)
        _ = try await editor.apply(.adjust(row: flashlight.id, by: 1))
        _ = try await editor.apply(.adjust(row: flashlight.id, by: -1))
        XCTAssertEqual(try editor.file.useLog().last?.amounts, [:], "a row the count read in no supply: worth nothing")
    }

    func testAnOwnUnsentTapOnAnUnsharedRowCantBeCounted() {
        let since = now.addingTimeInterval(-3 * 86_400)
        let log = PhoneUseLog(since: iso.string(from: since), taps: [
            .init(at: iso.string(from: since.addingTimeInterval(3600)), kind: "water", amount: 3)])
        let found = copy(written: now.addingTimeInterval(-60), log: log)
        var outbox = PhoneOutbox()
        let added = InventoryChange.add(table: "Inventory", values: [inventory.items.column("Item")!.colId:
                                                                         .text("Made-up water drum")])
        let id = outbox.add(added, what: "added")
        let drum = PhoneOutbox.temporaryID(id)
        let tap = InventoryChange.adjust(row: drum, by: -1)
        outbox.add(tap, what: "used 1", now: now.addingTimeInterval(-3600), use: RunsOut.use(of: tap, in: outbox.view(found)))
        XCTAssertEqual(RunsOut.ownTaps(outbox).map(\.amounts), [nil])
        XCTAssertEqual(RunsOut.line(water, copy: found, log: log, own: RunsOut.ownTaps(outbox), have: 6, now: now),
                       "Some use since Oct 22, 11:00 AM can't be counted")
        let unvalued = PhoneUseLog(since: log.since, taps: log.taps, unvalued: 1,
                                   unvaluedSince: iso.string(from: now.addingTimeInterval(-7200)))
        XCTAssertEqual(RunsOut.line(water, copy: found, log: unvalued, own: [], have: 6, now: now),
                       "Some use since Oct 22, 10:00 AM can't be counted", "the Mac's unvalued taps the same")
    }

    // MARK: A mistaken Used 1 put right (B2-08, beta run 2)

    func send(_ edits: [PhoneEdit], _ name: String) async throws {
        try JSONEncoder().encode(PhoneEdits(edits: edits))
            .write(to: base.appendingPathComponent("inbox").appendingPathComponent(name))
        try await PhoneInbox.process(folder: base, editor: editor)
    }

    /// A phone's Used 1 or, marked as the item screen's, its 1 more (`correction`: what a +1 may put right).
    func tap(_ by: Double, ago: TimeInterval, on row: Int64? = nil, correction: Bool? = nil) -> PhoneEdit {
        PhoneEdit(change: .adjust(row: row ?? jugs.id, by: by), at: iso.string(from: Date().addingTimeInterval(-ago)),
                  correction: correction ?? (by > 0))
    }

    /// The water line a phone would show from the Mac's log as it stands, with the jugs as they are.
    func waterLine(since: Date) throws -> String {
        let log = PhoneUseLog.make(try editor.file.useLog(), since: since)
        let found = copy(written: Date(), log: log)
        return RunsOut.line(water, copy: found, log: log, own: [], have: SupplyShares.have(water, in: found, now: Date()),
                            now: Date())
    }

    func testAOneMoreStraightAfterAUsedOneFromThatPhoneCancelsItInTheLog() async throws {
        let since = Date().addingTimeInterval(-2 * 86_400)
        editor.useLogStart = .on(since)
        editor.useLogShares = shares
        try await send([tap(-1, ago: 86_400)], "1-phone2-a.json")  // a real use, on another phone, a day ago
        let before = try waterLine(since: since)
        let logged = try editor.file.useLog()
        XCTAssertTrue(before.hasPrefix("At the use so far: runs out "), before)
        try await send([tap(-1, ago: 120)], "2-phone1-b.json")  // the mistaken Used 1
        XCTAssertNotEqual(try waterLine(since: since), before, "a Used 1 moves the day")
        try await send([tap(1, ago: 60)], "3-phone1-c.json")  // and its 1 more, a minute later
        XCTAssertEqual(try editor.file.useLog(), logged, "no use left in the log from the mistake")
        XCTAssertEqual(try waterLine(since: since), before, "runs out on unchanged")
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"), "the jugs back where they were")
    }

    func testOnlyTheNextChangeOnThatItemFromThatPhoneWithinTenMinutesCancels() async throws {
        let since = Date().addingTimeInterval(-2 * 86_400)
        editor.useLogStart = .on(since)
        editor.useLogShares = shares
        XCTAssertEqual(UseLog.cancelWithin, 10 * 60)
        try await send([tap(-1, ago: 3000)], "1-phone1-a.json")
        try await send([tap(1, ago: 2990)], "2-phone2-b.json")  // inside the window
        XCTAssertEqual(try editor.file.useLog().count, 1, "another phone's 1 more is its own, never a correction")
        try await send([tap(1, ago: 3000 - 620)], "3-phone1-c.json")
        XCTAssertEqual(try editor.file.useLog().count, 1, "over 10 minutes later: a 1 more, not a correction")
        try await send([tap(-1, ago: 900)], "4-phone1-d.json")
        try await send([PhoneEdit(change: .set(table: "Inventory", row: jugs.id, colId: inventory.items.column("Notes")!.colId,
                                               value: .text("Made-up note")), at: iso.string(from: Date()))],
                       "5-phone1-e.json")
        try await send([tap(1, ago: 800)], "6-phone1-f.json")
        XCTAssertEqual(try editor.file.useLog().count, 2, "another change on the item between: not straight after")
        try await send([tap(-1, ago: 300), tap(-1, ago: 290)], "7-phone1-g.json")
        try await send([tap(1, ago: 280), tap(1, ago: 270)], "8-phone1-h.json")
        XCTAssertEqual(try editor.file.useLog().count, 3, "a 1 more cancels the one Used 1 just before it, once")
        try await send([tap(1, ago: 210, on: flashlight.id), tap(-1, ago: 200, on: flashlight.id)], "9-phone1-i.json")
        try await send([tap(1, ago: 190)], "10-phone1-j.json")
        XCTAssertEqual(try editor.file.useLog().count, 4, "a Used 1 on another item stays")
        editor.useLogStart = .off
        try await send([tap(-1, ago: 100), tap(1, ago: 90)], "11-phone1-k.json")
        XCTAssertEqual(try editor.file.useLog(), [], "out of event mode nothing is logged and nothing is cancelled")
    }

    /// The log as the last build kept it (no phone change's id on its rows) still reads, and is added to; a Used 1 from
    /// before this build is never cancelled, since nothing says which phone's it was.
    func testALogFromBeforeThisBuildStillReadsAndIsAddedTo() async throws {
        try editor.file.db.execute("""
            CREATE TABLE "PrepareMe_UseLog" (id INTEGER PRIMARY KEY, at TEXT NOT NULL, row INTEGER NOT NULL, \
            used REAL NOT NULL, amounts TEXT)
            """)
        try editor.file.db.execute("INSERT INTO \"PrepareMe_UseLog\" (at, row, used, amounts) VALUES (?, ?, 1, ?)",
                                   [.text(iso.string(from: Date().addingTimeInterval(-60))), .int(jugs.id),
                                    .text("{\"water\":1}")])
        editor.useLogStart = .on(Date().addingTimeInterval(-86_400))
        editor.useLogShares = shares
        XCTAssertEqual(try editor.file.useLog().count, 1)
        try await send([tap(1, ago: 30)], "1-phone1-a.json")
        let older = try editor.file.useLog()
        XCTAssertEqual(older.count, 1, "the older row is kept")
        try await send([tap(-1, ago: 20)], "2-phone1-b.json")
        XCTAssertEqual(try editor.file.useLog().count, 2, "added to")
        try await send([tap(1, ago: 10)], "3-phone1-c.json")
        XCTAssertEqual(try editor.file.useLog(), older, "and the new row cancels as any, leaving the older one")
    }

    /// Fix round 1: only the item screen's 1 more (marked) puts a Used 1 right. A quick-add scan's 1 more, a held
    /// one's, and one from a phone before the mark are restocks: the use stays (never a day that reads too late).
    /// Quick add's "1 less" (its Undo last after the scan went) is marked too, and is never logged as a use.
    func testOnlyTheItemScreensOneMoreCancelsAndQuickAddsOneLessIsNoUse() async throws {
        editor.useLogStart = .on(Date().addingTimeInterval(-86_400))
        editor.useLogShares = shares
        try await send([tap(-1, ago: 120)], "1-phone1-a.json")
        try await send([tap(1, ago: 60, correction: false)], "2-phone1-b.json")  // a scan, or a held one's count of 1
        XCTAssertEqual(try editor.file.useLog().count, 1, "an unmarked 1 more is a restock: the use stays")
        try await send([PhoneEdit(change: .adjust(row: jugs.id, by: 1), at: iso.string(from: Date()))], "3-phone1-c.json")
        try await send([tap(-1, ago: 0), PhoneEdit(change: .adjust(row: jugs.id, by: 1))], "4-phone1-d.json")
        XCTAssertEqual(try editor.file.useLog().count, 2, "a phone before the mark: no cancel")
        try await send([tap(-1, ago: 0, correction: true)], "5-phone1-e.json")
        XCTAssertEqual(try editor.file.useLog().count, 2, "quick add's 1 less puts a scan right: never a use")
        XCTAssertEqual(quantity("Drinking water jugs"), .text("6"), "6 - 1 + 1 + 1 - 1 + 1 - 1, each applied")
    }

    /// Finding 3: a phone's tap leaves its outbox only with the Mac's answer, and the copy that carries the answer
    /// carries the tap too (both kept in one save, then written together), so it's never counted by neither.
    func testATapTheMacTookIsInTheSameCopyAsItsAnswer() async throws {
        editor.useLogStart = .on(Date().addingTimeInterval(-86_400))
        editor.useLogShares = shares
        var outbox = PhoneOutbox()
        let id = outbox.add(.adjust(row: jugs.id, by: -1), what: "used 1", now: Date().addingTimeInterval(-60),
                            use: .init(amounts: ["water": 1]))
        try JSONEncoder().encode(PhoneEdits(edits: outbox.pending.map(\.edit)))
            .write(to: base.appendingPathComponent("inbox").appendingPathComponent("1-phone1-c.json"))
        try await PhoneInbox.process(folder: base, editor: editor)
        let since = Date().addingTimeInterval(-86_400)
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [],
                                       results: try editor.file.phoneEditResults(since: since), supply: shares,
                                       useLog: PhoneUseLog.make(try editor.file.useLog(), since: since))
        outbox.settle(with: copy)
        XCTAssertNil(outbox.pending.first { $0.id == id }, "answered: out of the outbox")
        XCTAssertEqual(copy.useLog?.taps.map(\.amount), [1], "and in the same copy's log")
    }
}
