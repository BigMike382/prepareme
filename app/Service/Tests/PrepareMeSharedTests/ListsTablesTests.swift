import Foundation
@testable import PrepareMeShared
import XCTest

/// The lists in the app (plan phase 7, part 2): the lists job's rewrite taken in only while the tables are as its read
/// saw them, and the owner's changes through the editor, each raising the revision. The rewrite is the lists job's own
/// (Fixtures/lists.json, pinned by readiness/tests/test_applists.py, whose `take_in` is this side's counterpart). Made-up
/// rehearsal document copies only.
@MainActor
final class ListsTablesTests: XCTestCase {
    var base: URL!
    var check: FakeCheck!
    var editor: InventoryEditor!

    static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/lists.json")

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-lists-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        check = FakeCheck()
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: check)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    func payload(base: Int?, stamp: String? = nil) throws -> ListsPayload {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.sample)) as? [String: Any])
        raw["base"] = base.map { $0 as Any } ?? NSNull()
        if let stamp { raw["stamp"] = stamp }
        return try JSONDecoder().decode(ListsPayload.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func handedOver() async throws {
        XCTAssertTrue(try editor.file.takeIn(payload(base: nil)))
        try editor.reload()
    }

    func row(_ sheet: String, _ test: (ListRow) -> Bool) throws -> ListRow {
        try XCTUnwrap(editor.inventory.lists?.rows(sheet).first(where: test))
    }

    func testTheFirstRewriteMakesTheListsAndOnlyThen() async throws {
        XCTAssertNil(editor.inventory.lists)
        try await handedOver()
        let lists = try XCTUnwrap(editor.inventory.lists)
        XCTAssertEqual(lists.revision, 0)
        XCTAssertEqual(lists.stamp, try payload(base: nil).stamp)
        XCTAssertEqual(lists.rows(ListsLayout.todo).count, 5)
        XCTAssertEqual(lists.rows(ListsLayout.todo).first?["Done"], .bool(false))
        XCTAssertEqual(lists.setting(ListsLayout.eventMode), .text("Auto"))
        XCTAssertEqual(lists.setting("Water target (days)"), .number(30))
        XCTAssertFalse(try editor.file.takeIn(payload(base: nil)), "never over lists already there")
    }

    /// Top-ten plan phase 6, Task 6.3: the Mac-only recalls' titles and links are kept beside the rows taken in, and a
    /// rewrite from before them (no key) reads as none
    func testTheMacOnlyRecallsAreKeptWithTheRowsTakenIn() throws {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.sample)) as? [String: Any])
        raw["base"] = NSNull()
        raw["mac_only_recalls"] = ["R-6": ["title": "Made-up private recall", "link": "https://example.test/p"]]
        let made = try JSONDecoder().decode(ListsPayload.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertTrue(try editor.file.takeIn(made))
        XCTAssertEqual(try editor.file.lists()?.macOnlyRecalls,
                       ["R-6": MacOnlyRecall(title: "Made-up private recall", link: "https://example.test/p")])
        raw.removeValue(forKey: "mac_only_recalls")
        XCTAssertNil(try JSONDecoder().decode(ListsPayload.self, from: JSONSerialization.data(withJSONObject: raw))
            .macOnlyRecalls)
    }

    func testARewriteIsTakenInOnlyAtTheRevisionItsReadSaw() async throws {
        try await handedOver()
        let first = try row(ListsLayout.todo) { !$0.id.isEmpty }
        let outcome = try await editor.apply(.listSet(sheet: ListsLayout.todo, row: ListRowRef(first), column: "Done",
                                                      value: .bool(true), expected: .bool(false)))
        guard case .done = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(editor.inventory.lists?.revision, 1)
        let stale = try payload(base: 0, stamp: "2026-10-07T16:07:00-04:00")
        XCTAssertFalse(try editor.file.takeIn(stale), "read before the tick: never written over it")
        try editor.reload()
        XCTAssertEqual(try row(ListsLayout.todo) { $0.id == first.id }["Done"], .bool(true))
        let next = try payload(base: 1, stamp: "2026-10-07T16:22:00-04:00")
        XCTAssertTrue(try editor.file.takeIn(next))
        XCTAssertFalse(try editor.file.takeIn(next), "never the same stamp twice")
        try editor.reload()
        XCTAssertEqual(editor.inventory.lists?.revision, 1, "taking one in leaves the revision as it was")
        XCTAssertEqual(editor.inventory.lists?.stamp, "2026-10-07T16:22:00-04:00")
    }

    func testOnlyTheOwnersColumnsChangeAndEachUndoes() async throws {
        try await handedOver()
        let script = try row(ListsLayout.todo) { !$0.id.isEmpty }
        let why = try await editor.apply(.listSet(sheet: ListsLayout.todo, row: ListRowRef(script), column: "Why",
                                                  value: .text("x"), expected: script["Why"]))
        XCTAssertEqual(why, .refused(ListsWords.notEditable), "the lists job writes Why on its own rows")
        let notes = try await editor.apply(.listSet(sheet: ListsLayout.todo, row: ListRowRef(script), column: "Notes",
                                                    value: .text("Ask the neighbor"), expected: script["Notes"]))
        guard case .done(let undo, _) = notes else { return XCTFail("\(notes)") }
        XCTAssertNotNil(check.files.last, "the whole copy is read, the lists' reader included")
        XCTAssertEqual(try row(ListsLayout.todo) { $0.id == script.id }["Notes"], .text("Ask the neighbor"))
        _ = try await editor.apply(undo)
        XCTAssertEqual(try row(ListsLayout.todo) { $0.id == script.id }["Notes"], script["Notes"])
        let horizon = try await editor.apply(.listSet(sheet: ListsLayout.todo, row: ListRowRef(script),
                                                      column: "Horizon", value: .text("soon"),
                                                      expected: script["Horizon"]))
        XCTAssertEqual(horizon, .refused(ListsWords.notAChoice))
        let changed = try await editor.apply(.listSet(sheet: ListsLayout.todo, row: ListRowRef(script), column: "Done",
                                                      value: .bool(true), expected: .bool(true)))
        XCTAssertEqual(changed, .refused(InventoryWords.changedSince), "only while it is still as seen")
    }

    func testTheEventModeSwitch() async throws {
        try await handedOver()
        let row = try row(ListsLayout.settings) { $0["Setting"].text == ListsLayout.eventMode }
        let wrong = try await editor.apply(.listSet(sheet: ListsLayout.settings, row: ListRowRef(row), column: "Value",
                                                    value: .text("Maybe"), expected: .text("Auto")))
        XCTAssertEqual(wrong, .refused(ListsWords.notAChoice))
        guard case .done = try await editor.apply(.listSet(sheet: ListsLayout.settings, row: ListRowRef(row),
                                                           column: "Value", value: .text("On"),
                                                           expected: .text("Auto"))) else { return XCTFail() }
        XCTAssertEqual(editor.inventory.lists?.setting(ListsLayout.eventMode), .text("On"))
        let name = try await editor.apply(.listSet(sheet: ListsLayout.settings, row: ListRowRef(row), column: "Setting",
                                                   value: .text("x"), expected: row["Setting"]))
        XCTAssertEqual(name, .refused(ListsWords.notEditable))
    }

    func testAnOwnRowIsAddedRemovedAndPutBack() async throws {
        try await handedOver()
        let added = try await editor.apply(.listAdd(sheet: ListsLayout.todo,
                                                    cells: ["Task": .text("Check the generator's oil"),
                                                            "Category": .text("Power and fuel")]))
        guard case .done(let undo, _) = added else { return XCTFail("\(added)") }
        let own = try row(ListsLayout.todo) { $0["Task"].text == "Check the generator's oil" }
        XCTAssertEqual(own.id, "")
        XCTAssertEqual(own.pos, 5, "after the sheet's last row")
        guard case .done(let back, _) = try await editor.apply(undo) else { return XCTFail() }
        XCTAssertNil(editor.inventory.lists?.rows(ListsLayout.todo).first { $0.id.isEmpty })
        _ = try await editor.apply(back)
        XCTAssertEqual(try row(ListsLayout.todo) { $0.id.isEmpty }["Task"], .text("Check the generator's oil"))
        let script = try row(ListsLayout.todo) { !$0.id.isEmpty }
        let gone = try await editor.apply(.listRemove(sheet: ListsLayout.todo, row: ListRowRef(script)))
        XCTAssertEqual(gone, .refused(InventoryWords.notAddable), "the lists job's own To do rows aren't removed")
        let bought = try await editor.apply(.listAdd(sheet: ListsLayout.toBuy, cells: ["Item": .text("x")]))
        XCTAssertEqual(bought, .refused(InventoryWords.notAddable), "To buy's own window adds those")
        XCTAssertEqual(editor.inventory.lists?.revision, 3)
    }

    func testAChangeForAnUnreadRowNeverLandsOnAnotherAfterARewrite() async throws {
        try await handedOver()
        _ = try await editor.apply(.listAdd(sheet: ListsLayout.todo, cells: ["Task": .text("Wind the crank radio")]))
        let own = try row(ListsLayout.todo) { $0.id.isEmpty }
        XCTAssertTrue(try editor.file.takeIn(payload(base: 1, stamp: "2026-10-07T16:22:00-04:00")))  // the row gone
        try editor.reload()
        let outcome = try await editor.apply(.listSet(sheet: ListsLayout.todo, row: ListRowRef(own), column: "Done",
                                                      value: .bool(true), expected: .bool(false)))
        XCTAssertEqual(outcome, .refused(InventoryWords.noRow))
    }

    func testTheListsJobsRefusalKeepsNothing() async throws {
        try await handedOver()
        check.fileRefusal = "the lists in PrepareMe: Upkeep row 3, Every: Every can't be below 1"
        let outcome = try await editor.apply(.listAdd(sheet: ListsLayout.upkeep, cells: ["Task": .text("Test the pump"),
                                                                                     "Every": .number(0)]))
        XCTAssertEqual(outcome, .refused("the lists in PrepareMe: Upkeep row 3, Every: Every can't be below 1"))
        XCTAssertEqual(editor.inventory.lists?.rows(ListsLayout.upkeep).count, 1)
        XCTAssertEqual(editor.inventory.lists?.revision, 0)
    }

    func testAPhoneTicksAndSwitchesOnlyThat() async throws {
        try await handedOver()
        let todo = try row(ListsLayout.todo) { !$0.id.isEmpty }
        let mode = try row(ListsLayout.settings) { $0["Setting"].text == ListsLayout.eventMode }
        let water = try row(ListsLayout.settings) { $0["Setting"].text == "Water target (days)" }
        let inventory = editor.inventory
        XCTAssertNil(PhoneRules.refusal(.listSet(sheet: ListsLayout.todo, row: ListRowRef(todo), column: "Done",
                                                 value: .bool(true), expected: .bool(false)), inventory))
        XCTAssertNil(PhoneRules.refusal(.listSet(sheet: ListsLayout.settings, row: ListRowRef(mode), column: "Value",
                                                 value: .text("On"), expected: .text("Auto")), inventory))
        XCTAssertEqual(PhoneRules.refusal(.listSet(sheet: ListsLayout.settings, row: ListRowRef(water),
                                                   column: "Value", value: .number(3), expected: .number(30)),
                                          inventory), PhoneRules.notFromAPhone)
        XCTAssertNil(PhoneRules.refusal(.listSet(sheet: ListsLayout.todo, row: ListRowRef(todo), column: "Notes",
                                                 value: .text("x"), expected: .text("")), inventory),
                     "an adult's phone edits a to-do as the Mac does (owner, 2026-10-30)")
        XCTAssertNil(PhoneRules.refusal(.listAdd(sheet: ListsLayout.todo, cells: ["Task": .text("x")]), inventory))
        XCTAssertEqual(PhoneRules.refusal(.listAdd(sheet: ListsLayout.upkeep, cells: ["Task": .text("x")]), inventory),
                       PhoneRules.notFromAPhone)
        XCTAssertEqual(PhoneRules.refusal(.listRemove(sheet: ListsLayout.todo, row: ListRowRef(todo)), inventory),
                       PhoneRules.notFromAPhone, "no delete from a phone")
        XCTAssertEqual(PhoneRules.refusal(.listSet(sheet: ListsLayout.upkeep, row: ListRowRef(todo), column: "Task",
                                                   value: .text("x"), expected: .text("")), inventory),
                       PhoneRules.notFromAPhone)
    }

    /// A phone's to-do goes through the Mac's own checks after PhoneRules (owner, 2026-10-30): the lists job's Why
    /// stays its own, and an added one is the Mac's own kind of row.
    func testAPhonesToDoEditsMeetTheMacsChecks() async throws {
        try await handedOver()
        let script = try row(ListsLayout.todo) { !$0.id.isEmpty }
        let why = InventoryChange.listSet(sheet: ListsLayout.todo, row: ListRowRef(script), column: "Why",
                                          value: .text("x"), expected: script["Why"])
        XCTAssertNil(PhoneRules.refusal(why, editor.inventory))
        let refused = try await editor.apply(why)
        XCTAssertEqual(refused, .refused(ListsWords.notEditable))
        let add = InventoryChange.listAdd(sheet: ListsLayout.todo, cells: ["Task": .text("Fill the propane tank"),
                                                                           "Horizon": .text("two weeks")])
        XCTAssertNil(PhoneRules.refusal(add, editor.inventory))
        guard case .done = try await editor.apply(add) else { return XCTFail() }
        let own = try row(ListsLayout.todo) { $0["Task"].text == "Fill the propane tank" }
        XCTAssertEqual(own.id, "")
        let task = InventoryChange.listSet(sheet: ListsLayout.todo, row: ListRowRef(own), column: "Task",
                                           value: .text("Fill both propane tanks"), expected: own["Task"])
        XCTAssertNil(PhoneRules.refusal(task, editor.inventory))
        guard case .done = try await editor.apply(task) else { return XCTFail() }
        // the phone's form sends a second field's change naming the row as the first left it (PhoneToDoForm.save)
        var predicted = own
        predicted.cells["Task"] = .text("Fill both propane tanks")
        let notes = try await editor.apply(.listSet(sheet: ListsLayout.todo, row: ListRowRef(predicted),
                                                    column: "Notes", value: .text("The grill's too"),
                                                    expected: predicted["Notes"]))
        guard case .done = notes else { return XCTFail("\(notes)") }
        let both = try row(ListsLayout.todo) { $0["Task"].text == "Fill both propane tanks" }
        XCTAssertEqual(both["Notes"], .text("The grill's too"), "both fields kept, none refused as gone")
    }

    func testThePhonesGetToDoUpkeepAndTheSwitchAndSeeTheirOwnChangesAtOnce() async throws {
        try await handedOver()
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        let lists = try XCTUnwrap(copy.lists)
        XCTAssertEqual(lists.todo.count, 5)
        XCTAssertEqual(lists.upkeep.map { $0["Task"] }, [.text("Rotate stored water")])
        XCTAssertEqual(lists.eventMode, "Auto")
        let decoded = try JSONDecoder().decode(PhoneInventory.self, from: JSONEncoder().encode(copy))
        XCTAssertEqual(decoded.lists, lists, "it travels whole")
        var outbox = PhoneOutbox()
        let task = lists.todo[0]
        outbox.add(.listSet(sheet: ListsLayout.todo, row: ListRowRef(task), column: "Done", value: .bool(true),
                            expected: .bool(false)), what: "done")
        outbox.add(lists.eventModeChange("On"), what: "event mode")
        let shown = try XCTUnwrap(outbox.view(copy).lists)
        XCTAssertEqual(shown.todo[0]["Done"], .bool(true))
        XCTAssertEqual(shown.eventMode, "On")
        XCTAssertEqual(outbox.waitingEventMode, "On")
        outbox.add(.listAdd(sheet: ListsLayout.todo, cells: ["Task": .text("Fill the propane tank")]), what: "added")
        let added = try XCTUnwrap(outbox.view(copy).lists?.todo.last)
        XCTAssertEqual(added["Task"], .text("Fill the propane tank"), "a phone's own to-do shows at once")
        XCTAssertTrue(added.waiting)
        XCTAssertFalse(lists.todo.contains { $0.waiting })
        XCTAssertNil(PhoneRules.refusal(lists.eventModeChange("Off"), editor.inventory))
        guard case .done = try await editor.apply(lists.eventModeChange("On")) else { return XCTFail() }
        XCTAssertEqual(editor.inventory.lists?.setting(ListsLayout.eventMode), .text("On"), "the Mac finds its row")
    }

    func testBeforeTheListsMoveThePhonesGetNone() {
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertNil(copy.lists)
    }

    func testAChangeTravelsAsJSON() throws {
        let change = InventoryChange.listSet(sheet: "To do", row: ListRowRef(ListRow(pos: 2, cells: ["ID": .text("X-1")])),
                                             column: "Done on", value: .text("2026-10-14"), expected: .null)
        let data = try JSONEncoder().encode(change)
        XCTAssertEqual(try JSONDecoder().decode(InventoryChange.self, from: data), change)
    }

    /// Vehicles (owner 2026-10-14): the app's Vehicle tick on Locations is a column the lists job's real reader
    /// reads past, and a vehicle's drawers and bags nest under it, reaching the phones with it.
    func testAVehicleTickIsKeptAndReadPastByTheListsJob() async throws {
        guard let python = PythonTextCheck.venvPython(),
              FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("no venv") }
        XCTAssertTrue(try editor.file.ensureColumn("Locations", colId: "Kept_in", label: Inventory.Label.keptIn,
                                                   type: "Ref:Locations"))
        XCTAssertTrue(try editor.file.ensureColumn("Locations", colId: "Vehicle", label: Inventory.Label.vehicle,
                                                   type: "Bool"))
        let real = try InventoryEditor(file: editor.file, checker: PythonTextCheck(python: python,
                                                                                   code: InventoryTests.repo))
        let name = try XCTUnwrap(real.inventory.locations.column(Inventory.Label.name)).colId
        guard case .done(_, let truck) = try await real.apply(.add(table: "Locations", values: [
            name: .text("Truck"), "Vehicle": .int(1)])) else { return XCTFail("the truck wasn't kept") }
        guard case .done(_, let drawer) = try await real.apply(.add(table: "Locations", values: [
            name: .text("Truck drawer"), "Kept_in": .int(truck)])) else { return XCTFail("the drawer wasn't kept") }
        XCTAssertTrue(real.inventory.isVehicle(truck))
        XCTAssertEqual(real.inventory.vehicle(holding: drawer), truck)
        XCTAssertEqual(real.inventory.path(ofLocation: drawer), "Truck › Truck drawer")
        let copy = PhoneInventory.make(real.inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertEqual(copy.places.first { $0.id == truck }?.vehicle, true)
        XCTAssertEqual(copy.path(drawer), "Truck › Truck drawer")
    }

    /// A proposal as the lists job writes it (readiness.state.proposed_cells) is accepted and declined through the
    /// real check: the Proposed list's own buttons
    func testAProposalIsAcceptedOrDeclinedThroughTheRealCheck() async throws {
        guard let python = PythonTextCheck.venvPython(),
              FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("no venv") }
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.sample)) as? [String: Any])
        raw["base"] = NSNull()
        var sheets = try XCTUnwrap(raw["sheets"] as? [String: Any])
        func proposal(_ id: String, _ list: String) -> [String: Any] {
            ["Accept": false, "Decline": false, "List": list, "Text": "Practice the Quillmark radio check-in",
             "Why": "The household plan names a weekly check-in.", "Source": "Gap analysis",
             "Category": "Communications", "Horizon": "two weeks", "Life-safety": false, "Proposed on": "2026-10-05",
             "ID": id]
        }
        sheets["Proposed"] = [proposal("P-1", "To do"), proposal("P-2", "To buy")]
        raw["sheets"] = sheets
        XCTAssertTrue(try editor.file.takeIn(try JSONDecoder().decode(ListsPayload.self,
                                                                      from: JSONSerialization.data(withJSONObject: raw))))
        try editor.reload()
        let real = try InventoryEditor(file: editor.file, checker: PythonTextCheck(python: python,
                                                                                   code: InventoryTests.repo))
        let first = try row(ListsLayout.proposed) { $0.id == "P-1" }
        let accept = try await real.apply(.listSet(sheet: ListsLayout.proposed, row: ListRowRef(first), column: "Accept",
                                                   value: .bool(true), expected: first["Accept"]))
        guard case .done = accept else { return XCTFail("refused: \(accept)") }
        let second = try row(ListsLayout.proposed) { $0.id == "P-2" }
        let decline = try await real.apply(.listSet(sheet: ListsLayout.proposed, row: ListRowRef(second),
                                                    column: "Decline", value: .bool(true), expected: second["Decline"]))
        guard case .done = decline else { return XCTFail("refused: \(decline)") }
        func proposed(_ id: String) throws -> ListRow {
            try XCTUnwrap(real.inventory.lists?.rows(ListsLayout.proposed).first { $0.id == id })
        }
        let picked = try proposed("P-1")
        XCTAssertEqual(picked["Accept"], .bool(true))
        let undo = try await real.apply(.listSet(sheet: ListsLayout.proposed, row: ListRowRef(picked), column: "Accept",
                                                 value: .bool(false), expected: .bool(true)))
        guard case .done = undo else { return XCTFail("refused: \(undo)") }
        XCTAssertEqual(try proposed("P-1")["Accept"], .bool(false), "the row's Undo")
    }

    /// The real check: the lists' reader on the throwaway copy refuses what the next run would stop on.
    func testTheRealCheckRefusesWhatARunWould() async throws {
        guard let python = PythonTextCheck.venvPython(),
              FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("no venv") }
        try await handedOver()
        let real = try InventoryEditor(file: editor.file, checker: PythonTextCheck(python: python,
                                                                                   code: InventoryTests.repo))
        let zero = try await real.apply(.listAdd(sheet: ListsLayout.upkeep, cells: ["Task": .text("Test the pump"),
                                                                                  "Every": .number(0),
                                                                                  "Unit": .text("months")]))
        guard case .refused(let why) = zero else { return XCTFail("kept: \(zero)") }
        XCTAssertTrue(why.contains("Every can't be below 1"), why)
        let fine = try await real.apply(.listAdd(sheet: ListsLayout.upkeep, cells: ["Task": .text("Test the pump"),
                                                                                  "Every": .number(3),
                                                                                  "Unit": .text("months"),
                                                                                  "Active": .bool(true)]))
        guard case .done = fine else { return XCTFail("refused: \(fine)") }
    }
}

final class PhoneEventSwitchTests: XCTestCase {
    func testWaitingThenHeldThenThePagesOwn() {
        let set = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(PhoneEventSwitch.value(waiting: "On", local: "On", setAt: set, now: set.addingTimeInterval(86_400)),
                       "On", "away from home it holds while it waits")
        XCTAssertEqual(PhoneEventSwitch.value(waiting: nil, local: "On", setAt: set, now: set.addingTimeInterval(3600)),
                       "On")
        XCTAssertNil(PhoneEventSwitch.value(waiting: nil, local: "On", setAt: set, now: set.addingTimeInterval(7 * 3600)))
        XCTAssertNil(PhoneEventSwitch.value(waiting: nil, local: "Maybe", setAt: set, now: set))
        XCTAssertNil(PhoneEventSwitch.value(waiting: nil, local: "On", setAt: set, now: set.addingTimeInterval(-60)),
                     "a clock set back never holds it")
        XCTAssertEqual(PhoneEventSwitch.script("Off"),
                       "(function(){var c=document.getElementById('conditions');if(c)c.setAttribute('data-switch','off');})();")
        XCTAssertEqual(PhoneEventSwitch.script("x"), "")
    }

    func testANewerCopyFromTheMacWins() {
        let set = Date(timeIntervalSince1970: 1_000_000)
        let later = set.addingTimeInterval(600)
        XCTAssertEqual(PhoneEventSwitch.value(waiting: nil, local: "On", setAt: set, copy: "Off", copyAt: later,
                                              now: later.addingTimeInterval(60)), "Off", "switched back on the Mac")
        XCTAssertEqual(PhoneEventSwitch.value(waiting: nil, local: "On", setAt: set, copy: "Off",
                                              copyAt: set.addingTimeInterval(-60), now: later), "On",
                       "a copy from before the switch says nothing about it")
        XCTAssertEqual(PhoneEventSwitch.value(waiting: "On", local: "On", setAt: set, copy: "Off", copyAt: later,
                                              now: later), "On", "this phone's change still on its way")
        XCTAssertNil(PhoneEventSwitch.value(waiting: nil, local: "On", setAt: set, copy: "Off", copyAt: later,
                                            now: set.addingTimeInterval(7 * 3600)), "then the page's own")
    }
}
