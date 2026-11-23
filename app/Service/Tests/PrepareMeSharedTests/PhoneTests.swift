import Foundation
@testable import PrepareMeShared
import XCTest

/// The inventory on the phones (plan phase 7, slice 5): what they get, which edits they may make, the Mac applying
/// them once each, and a phone's outbox. Made-up rehearsal copies only.
@MainActor
final class PhoneTests: XCTestCase {
    var base: URL!
    var check: FakeCheck!
    var editor: InventoryEditor!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-phone-\(UUID())")
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
    func colId(_ label: String) -> String { inventory.items.column(label)!.colId }
    func quantity(_ name: String) -> SQLValue { item(name)[inventory.items.column("Quantity")!] }

    func send(_ edits: [PhoneEdit], name: String, device: String? = nil) throws {
        try JSONEncoder().encode(PhoneEdits(edits: edits, device: device))
            .write(to: base.appendingPathComponent("inbox").appendingPathComponent(name))
    }

    func testThePhonesNeverGetAPrivateRowOrTheMacOnlyColumn() throws {
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertFalse(copy.items.contains { $0.id == item("Indoor propane heater").id })
        XCTAssertEqual(copy.items.count, 4)
        XCTAssertFalse(copy.columns.contains { $0.label == "Mac only" })
        XCTAssertTrue(copy.items.allSatisfy { $0.values[colId("Mac only")] == nil })
        XCTAssertEqual(copy.places.count, 10)
        XCTAssertEqual(copy.categories.first { $0.name == "Water" }?.group, "Water")
        try copy.write(in: base)
        XCTAssertEqual(PhoneInventory.read(in: base), copy)
    }

    /// Beta run 2, B2-04 (choice a): the backup carries the phones' copy, exactly as the phones get it: a made-up
    /// inventory with a Private row and a serial number, written as the Mac app writes it, backed up, and neither in
    /// the backup's copy nor its list
    func testTheBackupsCopyHoldsNoPrivateRowAndNoSerialNumber() async throws {
        let started = try await editor.apply(.startInsurance)
        guard case .done = started else { return XCTFail("\(started)") }
        let serial = inventory.items.column(Insurance.serial)!.colId
        let made = "SAMPLE-QX7731C-0011223344"  // made up
        let set = try await editor.apply(.set(table: "Inventory", row: item("Drinking water jugs").id, colId: serial,
                                              value: .text(made)))
        guard case .done = set else { return XCTFail("\(set)") }
        let heater = item("Indoor propane heater").id
        XCTAssertTrue(inventory.isPrivate(item("Indoor propane heater")))
        let macFolder = base.appendingPathComponent("inventory")
        try FileManager.default.createDirectory(at: macFolder, withIntermediateDirectories: true)
        try PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:]).write(in: macFolder)

        // a backup round, with one made-up library file
        let library = base.appendingPathComponent("library"), folder = base.appendingPathComponent("PrepareMe Backup")
        for dir in [library, folder] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("daily".utf8).write(to: library.appendingPathComponent("copy-daily.zim"))
        let daily = Manifest.Entry(name: "prepareme-daily.zim", id: "0f1e2d3c-4b5a-4968-8776-6554433221a1",
                                   kind: "library", size: 5,
                                   sha256: try FileCheck.sha256(of: library.appendingPathComponent("copy-daily.zim")),
                                   deliveredAt: "2026-10-20T12:00:00-04:00")
        let source = try XCTUnwrap(Backup.inventorySource(in: macFolder))
        let plan = Backup.plan(delivery: Manifest(writtenAt: "x", files: [daily]),
                               held: [daily.name: HeldFile(entry: daily, file: "copy-daily.zim")], backup: nil,
                               present: [:], inventory: source)
        let outcome = try Backup.run(plan, source: library, folder: folder,
                                     mirror: base.appendingPathComponent("backup/manifest.json"), writtenAt: "x")
        XCTAssertTrue(outcome.inventoryCopied)

        let backedUp = try Data(contentsOf: folder.appendingPathComponent(PhoneInventory.fileName))
        XCTAssertEqual(backedUp, try Data(contentsOf: macFolder.appendingPathComponent(PhoneInventory.fileName)))
        let copy = try JSONDecoder().decode(PhoneInventory.self, from: backedUp)
        XCTAssertFalse(copy.items.contains { $0.id == heater }, "never a Private row")
        XCTAssertEqual(copy.items.count, 4)
        XCTAssertFalse(copy.columns.contains { [colId("Mac only"), serial].contains($0.colId) })
        XCTAssertFalse(copy.columns.contains { InventoryFile.same($0.label, Insurance.serial) })
        let text = String(decoding: backedUp, as: UTF8.self)
        XCTAssertFalse(text.contains(made), "never a serial number")
        XCTAssertFalse(text.contains("Indoor propane heater"))
        let list = String(decoding: try Data(contentsOf: folder.appendingPathComponent(Backup.manifestName)),
                          as: UTF8.self)
        XCTAssertFalse(list.contains(made))
    }

    /// Audit D2: a saved copy that can't be read now (a launch before the first unlock after a restart) reads as none,
    /// and the same file reads once it can be, so the app's next try on coming forward finds it.
    func testASavedCopyUnreadableAtLaunchIsReadAtTheNextTry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("inventory-cache.json")
        XCTAssertNil(PhoneInventoryCache.read(url), "none saved")
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        let saved = PhoneInventoryCache(copy: copy, canEdit: true, at: Date(timeIntervalSince1970: 1_800_000_000),
                                        fromBackup: false)
        try JSONEncoder().encode(saved).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        XCTAssertNil(PhoneInventoryCache.read(url), "locked: none for now")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(PhoneInventoryCache.read(url), saved, "unlocked: the copy as saved")
    }

    /// Audit D1, the lead's review: a phone restored from its own device backup onto a new device has its waiting
    /// changes but no pairing (the Keychain's are this device's only). Paired again, under a new id, it sends them all:
    /// the one the Mac took before the backup changes nothing again, the other is applied once, and the Mac's answers
    /// empty the outbox.
    func testARestoredPhonesWaitingChangesAreAppliedOnceAfterItPairsAgain() async throws {
        let jugs = item("Drinking water jugs").id
        let now = Date()
        var outbox = PhoneOutbox()
        outbox.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1", now: now.addingTimeInterval(-600))
        outbox.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1", now: now.addingTimeInterval(-500))
        let first = outbox.markSent([outbox.pending[0].id], now: now.addingTimeInterval(-590))
        try send(outbox.pending.filter { first.contains($0.id) }.map(\.edit), name: "a.json",
                 device: UUID().uuidString.lowercased())
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"), "the first reached the Mac; its answer never came")
        let backup = base.appendingPathComponent("inventory-outbox.json")
        try outbox.write(backup)  // in the phone's backup, then restored onto the new device
        var restored = try PhoneOutbox.read(backup)
        let again = restored.toSend(now: now)
        XCTAssertEqual(again.map(\.id), outbox.pending.map(\.id), "both go, the first again after its wait")
        _ = restored.markSent(again.map(\.id), now: now)
        try send(again.map(\.edit), name: "b.json", device: UUID().uuidString.lowercased())  // the new pairing's id
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(quantity("Drinking water jugs"), .text("4"), "each change once")
        let results = try editor.file.phoneEditResults(since: .distantPast)
        XCTAssertTrue(again.allSatisfy { results[$0.id] != nil && results[$0.id]?.refused == nil })
        restored.settle(with: PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: results), now: now)
        XCTAssertEqual(restored.pending, [], "answered: nothing left waiting")
        XCTAssertEqual(restored.refused, [])
    }

    /// B2-04 review: a copy taken from the PrepareMe Backup reads only. Restored from the cache it never allows an edit,
    /// whatever role was saved, and has no last look (so the next library check fetches the Mac's copy); a Mac copy keeps
    /// its role and its look time; a cache from before the field reads as a Mac copy
    func testABackupCopyReadsOnlyAndAnOlderCacheIsAMacCopy() throws {
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let backup = PhoneInventoryCache(copy: copy, canEdit: true, at: at, fromBackup: true)
        XCTAssertTrue(backup.isFromBackup)
        XCTAssertFalse(backup.mayEdit, "never an edit from a backup copy, even if a role says so")
        XCTAssertNil(backup.lastLook)
        let mac = PhoneInventoryCache(copy: copy, canEdit: true, at: at, fromBackup: false)
        XCTAssertTrue(mac.mayEdit)
        XCTAssertEqual(mac.lastLook, at)
        XCTAssertFalse(PhoneInventoryCache(copy: copy, canEdit: false, at: at, fromBackup: false).mayEdit)
        XCTAssertFalse(PhoneInventoryCache.mayEdit(canEdit: true, fromBackup: true))
        XCTAssertTrue(PhoneInventoryCache.mayEdit(canEdit: true, fromBackup: false))
        // round trip, and an older cache (no fromBackup key) as it was written before
        let again = try JSONDecoder().decode(PhoneInventoryCache.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(again, backup)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mac)) as? [String: Any])
        object["fromBackup"] = nil
        let older = try JSONDecoder().decode(PhoneInventoryCache.self,
                                             from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(older.isFromBackup)
        XCTAssertTrue(older.mayEdit)
        XCTAssertEqual(older.lastLook, at)
        XCTAssertEqual(Set(object.keys), ["copy", "canEdit", "at"], "the keys the app's cache always had")
    }

    func testWhatAPhoneMayChange() {
        let heater = item("Indoor propane heater").id, jugs = item("Drinking water jugs").id
        XCTAssertNil(PhoneRules.refusal(.adjust(row: jugs, by: -1), inventory))
        XCTAssertNil(PhoneRules.refusal(.set(table: "Inventory", row: jugs, colId: colId("Notes"), value: .text("x")),
                                        inventory))
        XCTAssertEqual(PhoneRules.refusal(.adjust(row: heater, by: -1), inventory), PhoneRules.privateRow)
        XCTAssertEqual(PhoneRules.refusal(.set(table: "Inventory", row: jugs, colId: colId("Mac only"),
                                               value: .int(1)), inventory), PhoneRules.notFromAPhone)
        XCTAssertEqual(PhoneRules.refusal(.set(table: "Locations", row: 1, colId: "Name", value: .text("x")),
                                          inventory), PhoneRules.notFromAPhone)
        XCTAssertEqual(PhoneRules.refusal(.add(table: "Inventory", values: [colId("Mac only"): .int(1)]), inventory),
                       PhoneRules.notFromAPhone)
        XCTAssertNil(PhoneRules.refusal(.tick(ToBuyTick(kind: .notNeeded, item: "S-1")), inventory))
    }

    /// Owner, 2026-11-18 (owner check 107: Undo last didn't take back a can Quick add had already sent): an adult's
    /// phone deletes an inventory item; a child's phone, another table and a Private item are still refused. The
    /// waiting delete hides the item and its code at once, and the Mac takes both out.
    func testAnAdultsPhoneDeletesAnItem() async throws {
        let jugs = item("Drinking water jugs").id, heater = item("Indoor propane heater").id
        XCTAssertNil(PhoneRules.refusal(.deleteSeen(row: jugs, cells: [:]), inventory))
        XCTAssertEqual(PhoneRules.refusal(.deleteSeen(row: jugs, cells: [:]), inventory,
                                          from: .init(child: true)), MapMarkWords.adultsOnly)
        XCTAssertEqual(PhoneRules.refusal(.deleteSeen(row: heater, cells: [:]), inventory), PhoneRules.privateRow)
        XCTAssertEqual(PhoneRules.refusal(.delete(table: "Inventory", row: jugs), inventory), PhoneRules.notFromAPhone,
                       "a phone's delete always says what it saw")
        XCTAssertEqual(PhoneRules.refusal(.delete(table: "Locations", row: 1), inventory), PhoneRules.notFromAPhone)
        XCTAssertEqual(PhoneRules.refusal(.deleteRows(table: "Inventory", rows: [jugs]), inventory),
                       PhoneRules.notFromAPhone, "one item at a time")
        // a can Quick add sent and the Mac took, then taken back
        let code = try XCTUnwrap(Barcode.valid(["0360", "0029", "1452"].joined()))  // as the Mac keeps it
        var phone = PhoneOutbox()
        phone.add(.addItem(values: [colId("Item"): .text("Zorvex beans")], barcode: code), what: "Zorvex beans")
        try send(phone.pending.map(\.edit), name: "2026-11-18T10-00-01-phone1-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        phone.settle(with: PhoneInventory.make(inventory, toBuy: nil, waiting: [],
                                               results: try editor.file.phoneEditResults(since: .distantPast)))
        XCTAssertEqual(phone.pending, [])
        let can = try XCTUnwrap(inventory.barcodes[code])
        let sent = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        phone.add(PhoneInventory.delete(try XCTUnwrap(sent.items.first { $0.id == can })), what: "Zorvex beans: taken back")
        let copy = phone.view(sent)
        XCTAssertFalse(copy.items.contains { $0.id == can }, "gone from the phone while it waits")
        XCTAssertNil(copy.barcodes?[code], "and its code with it: a scan of it is a new product again")
        XCTAssertTrue(copy.items.contains { $0.id == jugs })
        try send(phone.pending.map(\.edit), name: "2026-11-18T10-00-02-phone1-b.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertFalse(inventory.itemRows.contains { $0.id == can })
        // its code is left over until the editor next opens, as after a delete on the Mac; no phone finds it by it
        let after = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertFalse(after.items.contains { $0.id == (after.barcodes?[code] ?? can) })
        XCTAssertNil(try editor.file.phoneEditResults(since: .distantPast)[phone.pending[0].id]?.refused)
    }

    /// Undo last on a sent add deletes the row that add made, never whichever item holds its code now (review of
    /// 5cd50a6b): two phones add the same new product while out of touch, and the Mac gives the code to the newer one.
    func testUndoLastDeletesItsOwnAddsRow() async throws {
        let code = try XCTUnwrap(Barcode.valid(["0360", "0029", "1452"].joined()))
        var first = PhoneOutbox(), second = PhoneOutbox()
        first.add(.addItem(values: [colId("Item"): .text("Zorvex beans")], barcode: code), what: "Zorvex beans")
        second.add(.addItem(values: [colId("Item"): .text("Zorvex beans")], barcode: code), what: "Zorvex beans")
        let firstAdd = first.pending[0].id, secondAdd = second.pending[0].id
        XCTAssertEqual(PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:]).takeBack(add: firstAdd),
                       .wait, "no answer yet")
        try send(first.pending.map(\.edit), name: "2026-11-18T10-00-01-phone1-a.json")
        try send(second.pending.map(\.edit), name: "2026-11-18T10-00-02-phone2-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        let results = try editor.file.phoneEditResults(since: .distantPast)
        let mine = try XCTUnwrap(results[firstAdd]?.row), theirs = try XCTUnwrap(results[secondAdd]?.row)
        XCTAssertNotEqual(mine, theirs)
        XCTAssertEqual(inventory.barcodes[code], theirs, "the code went to the newer item")
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: results)
        guard case .delete(let change) = copy.takeBack(add: firstAdd) else { return XCTFail("no delete") }
        guard case .deleteSeen(let row, _) = change else { return XCTFail("not a checked delete") }
        XCTAssertEqual(row, mine)
        first.settle(with: copy)
        first.add(change, what: "Zorvex beans: deleted")
        try send(first.pending.map(\.edit), name: "2026-11-18T10-00-03-phone1-b.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertFalse(inventory.itemRows.contains { $0.id == mine })
        XCTAssertTrue(inventory.itemRows.contains { $0.id == theirs }, "the other phone's item stays")
        let after = PhoneInventory.make(inventory, toBuy: nil, waiting: [],
                                        results: try editor.file.phoneEditResults(since: .distantPast))
        XCTAssertEqual(after.takeBack(add: firstAdd), .gone, "already taken back")
        XCTAssertNil(after.results[first.pending[0].id]?.refused)
    }

    /// Undo last twice on a new item scanned twice (re-read of dea3668a): the delete is built from the copy with this
    /// phone's waiting changes on top, so a waiting 1 less sent with it doesn't make the Mac refuse it as changed since.
    /// Both orders: the 1 more already applied with the 1 less waiting, and the 1 more itself still waiting.
    func testUndoLastsDeleteCountsThisPhonesWaitingChanges() async throws {
        let code = try XCTUnwrap(Barcode.valid(["0360", "0029", "1452"].joined()))
        for moreApplied in [true, false] {
            var phone = PhoneOutbox()
            phone.add(.addItem(values: [colId("Item"): .text("Zorvex beans \(moreApplied)"), colId("Quantity"): .text("1")],
                               barcode: code), what: "Zorvex beans")
            let add = phone.pending[0].id
            try send(phone.pending.map(\.edit), name: "2026-11-18T12-00-0\(moreApplied ? 1 : 4)-phone1-a.json")
            try await PhoneInbox.process(folder: base, editor: editor)
            phone.settle(with: PhoneInventory.make(inventory, toBuy: nil, waiting: [],
                                                   results: try editor.file.phoneEditResults(since: .distantPast)))
            let row = try XCTUnwrap(try editor.file.phoneEditResults(since: .distantPast)[add]?.row)
            phone.add(.adjust(row: row, by: 1), what: "Zorvex beans: 1 more")
            if moreApplied {
                try send(phone.pending.map(\.edit), name: "2026-11-18T12-00-02-phone1-b.json")
                try await PhoneInbox.process(folder: base, editor: editor)
                phone.settle(with: PhoneInventory.make(inventory, toBuy: nil, waiting: [],
                                                       results: try editor.file.phoneEditResults(since: .distantPast)))
                phone.add(.adjust(row: row, by: -1), what: "Zorvex beans: 1 less")  // the first Undo last, still waiting
            }
            let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [],
                                           results: try editor.file.phoneEditResults(since: .distantPast))
            guard case .delete(let change) = phone.view(copy).takeBack(add: add) else { return XCTFail("no delete") }
            phone.add(change, what: "Zorvex beans: deleted")
            try send(phone.pending.map(\.edit), name: "2026-11-18T12-00-0\(moreApplied ? 3 : 5)-phone1-c.json")
            try await PhoneInbox.process(folder: base, editor: editor)
            let results = try editor.file.phoneEditResults(since: .distantPast)
            XCTAssertFalse(inventory.itemRows.contains { $0.id == row }, "taken back (1 more applied: \(moreApplied))")
            XCTAssertEqual(phone.pending.compactMap { results[$0.id]?.refused }, [], "nothing refused")
        }
    }

    /// Owner, 2026-11-18, by click ("Warn and refuse stale"): a phone's delete of an item the Mac changed after that
    /// phone's copy is refused in the changed-since words (listed under Not saved); one of an unchanged item goes.
    func testAPhonesDeleteOfAnItemChangedSinceIsRefused() async throws {
        let jugs = item("Drinking water jugs").id, candles = item("Test flashlight").id
        let seen = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        var phone = PhoneOutbox()
        phone.add(PhoneInventory.delete(try XCTUnwrap(seen.items.first { $0.id == jugs })), what: "jugs: deleted")
        phone.add(PhoneInventory.delete(try XCTUnwrap(seen.items.first { $0.id == candles })), what: "candles: deleted")
        _ = try await editor.apply(.adjust(row: jugs, by: 4))  // restocked on the Mac after the phone's copy
        try send(phone.pending.map(\.edit), name: "2026-11-18T11-00-01-phone1-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        let results = try editor.file.phoneEditResults(since: .distantPast)
        XCTAssertTrue(inventory.itemRows.contains { $0.id == jugs }, "changed since: kept")
        XCTAssertEqual(results[phone.pending[0].id]?.refused, InventoryWords.changedSince)
        XCTAssertFalse(inventory.itemRows.contains { $0.id == candles }, "unchanged: deleted")
        XCTAssertNil(results[phone.pending[1].id]?.refused)
        phone.settle(with: PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: results))
        XCTAssertEqual(phone.refused.count, 1, "listed under Not saved")
    }

    /// Two phones each use some of the same item while the Mac is off; their edits wait, and the Mac counts both.
    func testTwoPhonesUsingSomeWhileTheMacIsOffBothCount() async throws {
        let jugs = item("Drinking water jugs").id  // 6
        var first = PhoneOutbox(), second = PhoneOutbox()
        first.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1")
        first.add(.adjust(row: jugs, by: -2), what: "Drinking water jugs: used 2")
        second.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1")
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        let quantityColumn = colId("Quantity")
        XCTAssertEqual(first.view(copy).items.first { $0.id == jugs }?.values[quantityColumn], .text("3"))
        XCTAssertEqual(second.view(copy).items.first { $0.id == jugs }?.values[quantityColumn], .text("5"))
        // the Mac comes back: both send, the first twice (its answer was lost)
        try send(first.pending.map(\.edit), name: "2026-10-14T10-00-01-phone1-a.json")
        try send(second.pending.map(\.edit), name: "2026-10-14T10-00-02-phone2-b.json")
        try send(first.pending.map(\.edit), name: "2026-10-14T10-00-03-phone1-c.json")
        let applied = try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertTrue(applied)
        XCTAssertEqual(quantity("Drinking water jugs"), .text("2"), "6 - 1 - 2 - 1, each once")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("inbox").path), [])
        let answered = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: try editor.file.phoneEditResults(since: .distantPast))
        first.settle(with: answered)
        second.settle(with: answered)
        XCTAssertEqual(first.pending, [])
        XCTAssertEqual(second.pending, [])
        XCTAssertEqual(first.refused, [])
    }

    /// Entry fixes plan, Task 1.8 (owner, 2026-10-23, by click): a phone's cell change says what it saw, and a cell the
    /// Mac changed since is never overwritten: it is refused with "This has changed since", which the phone shows. A
    /// change against what the Mac holds still goes in; the waiting change shows on the phone's copy as before; the
    /// rules stay a cell set's (no Mac-only column, never a name blanked).
    func testAStalePhoneChangeIsRefused() async throws {
        let jugs = item("Drinking water jugs").id, q = colId("Quantity")
        let six = try XCTUnwrap(inventory.itemRows.first { $0.id == jugs }?[inventory.items.column("Quantity")!])
        guard case .done = try await editor.apply(.set(table: "Inventory", row: jugs, colId: q, value: .text("4")))
        else { return XCTFail() }
        var phone = PhoneOutbox()
        // the form opened on 6 and the Mac's 4 reached the phone before Save: the change still says 6 (stale edit
        // base fix, 2026-11-18)
        let stale = try XCTUnwrap(PhoneEditRules.cellChange(row: jugs, colId: q, value: .text("5"), opened: [q: six],
                                                            latest: [q: .text("4")]))
        phone.add(stale, what: "Drinking water jugs: Quantity")
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertEqual(phone.view(copy).items.first { $0.id == jugs }?.values[q], .text("5"), "shown while it waits")
        try send(phone.pending.map(\.edit), name: "2026-10-23T10-00-01-phone1-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(quantity("Drinking water jugs"), .text("4"), "the Mac's newer 4 stays")
        let results = try editor.file.phoneEditResults(since: .distantPast)
        XCTAssertEqual(results[phone.pending[0].id]?.refused, InventoryWords.changedSince)
        var settled = phone
        settled.settle(with: PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: results))
        XCTAssertEqual(settled.refused.map(\.message), [InventoryWords.changedSince],
                       "listed among the phone's refused changes, as any other")
        var fresh = PhoneOutbox()
        fresh.add(.revert(table: "Inventory", row: jugs, colId: q, value: .text("5"), expected: .text("4")),
                  what: "Drinking water jugs: Quantity")
        try send(fresh.pending.map(\.edit), name: "2026-10-23T10-00-02-phone1-b.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"), "made against what the Mac holds: kept")
        XCTAssertEqual(PhoneRules.refusal(.revert(table: "Inventory", row: jugs, colId: colId("Mac only"),
                                                  value: .int(1), expected: .int(0)), inventory), PhoneRules.notFromAPhone)
        XCTAssertEqual(PhoneRules.refusal(.revert(table: "Inventory", row: jugs, colId: colId("Item"),
                                                  value: .text(" "), expected: .text("Drinking water jugs")), inventory),
                       InventoryWords.noName)
        XCTAssertEqual(PhoneEdit.item(of: .revert(table: "Inventory", row: jugs, colId: q, value: .text("5"),
                                                  expected: .text("4"))), jugs)
        XCTAssertEqual(PhoneEditRules.refusalLine(message: InventoryWords.changedSince, item: "Jugs (Garage)",
                                                  what: "Jugs: Quantity"), PhoneEditRules.changedOnMac,
                       "the Mac's words speak of its Undo; the phone's say what happened")
        XCTAssertEqual(PhoneEditRules.changedOnMac, "This was changed on the Mac since you last saw it, so your change "
                       + "wasn't kept. Look at it now and change it again if you still need to.")
    }

    // MARK: A phone makes a place or category (entry fixes plan, Task 1.6; owner, 2026-10-23, by click)

    func withPlaceColumns() throws {
        try editor.file.ensureColumn("Locations", colId: "Kept_in", label: Inventory.Label.keptIn, type: "Ref:Locations")
        try editor.file.ensureColumn("Locations", colId: "Vehicle", label: Inventory.Label.vehicle, type: "Bool")
        try editor.reload()
    }

    /// A phone away from home makes "Garage shelf" in the garage and adds a lantern to it; both wait, then go in one
    /// POST, in order. The place's fields go by their names (the phone's copy has no Locations column ids), and the
    /// lantern's place is the place's waiting number, which the Mac puts back as the row it made. The phone shows the
    /// waiting place in its pick lists meanwhile.
    func testAPhoneAddsAPlaceThenAnItemInIt() async throws {
        try withPlaceColumns()
        let garage = try XCTUnwrap(inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Garage" }).id
        var phone = PhoneOutbox()
        let place = phone.add(.add(table: "Locations", values: ["Name": .text("Garage shelf"), "Kept in": .int(garage),
                                                                "Vehicle": .int(0)]), what: "New place: Garage shelf")
        let waiting = PhoneOutbox.temporaryID(place)
        phone.add(.add(table: "Inventory", values: [colId("Item"): .text("Zorvex lantern"), colId("Location"): .int(waiting)]),
                  what: "Added Zorvex lantern")
        let copy = phone.view(PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:]))
        XCTAssertEqual(copy.places.first { $0.id == waiting }?.name, "Garage shelf", "in the pick lists while waiting")
        XCTAssertEqual(copy.path(waiting), "Garage › Garage shelf")
        try send(phone.pending.map(\.edit), name: "2026-10-23T11-00-01-phone1-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        let shelf = try XCTUnwrap(inventory.locationRows.first { inventory.name(ofLocation: $0.id) == "Garage shelf" })
        XCTAssertEqual(inventory.keptIn(shelf.id), garage)
        XCTAssertEqual(item("Zorvex lantern")[inventory.items.column("Location")!].whole, shelf.id)
    }

    /// The place is refused (a look-alike, Task 1.3), so the lantern waiting on it is refused too, never filed nowhere.
    func testAnItemInARefusedNewPlaceIsRefused() async throws {
        try withPlaceColumns()
        var phone = PhoneOutbox()
        let place = phone.add(.add(table: "Locations", values: ["Name": .text("GARAGE")]), what: "New place: GARAGE")
        let item = phone.add(.add(table: "Inventory", values: [colId("Item"): .text("Zorvex lantern"),
                                                                colId("Location"): .int(PhoneOutbox.temporaryID(place))]),
                             what: "Added Zorvex lantern")
        try send(phone.pending.map(\.edit), name: "2026-10-23T11-00-02-phone1-b.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        let results = try editor.file.phoneEditResults(since: .distantPast)
        XCTAssertEqual(results[place]?.refused, String(format: InventoryWords.samePlace, "Garage"))
        XCTAssertEqual(results[item]?.refused, InventoryWords.notThere)
        XCTAssertNil(inventory.itemRows.first { inventory.name(ofItem: $0) == "Zorvex lantern" })
    }

    /// A phone may add a place with only its name, Kept in and Vehicle, and a category with only its name and Counts
    /// as; any other column is the Mac's. Setting a place's cells stays the Mac's too.
    func testPhonesMayAddOnlyNameKeptInVehicleOrCountsAs() throws {
        try withPlaceColumns()
        XCTAssertNil(PhoneRules.refusal(PhoneInbox.byColumnIds(.add(table: "Locations", values: [
            "Name": .text("Shelf"), "Kept in": .int(0), "Vehicle": .int(1)]), inventory), inventory))
        XCTAssertNil(PhoneRules.refusal(PhoneInbox.byColumnIds(.add(table: "Categories", values: [
            "Name": .text("Heating"), "Counts as": .text("Heat and shelter")]), inventory), inventory))
        XCTAssertEqual(PhoneRules.refusal(PhoneInbox.byColumnIds(.add(table: "Locations", values: [
            "Name": .text("Shelf"), "Grab": .text("10 min")]), inventory), inventory), PhoneRules.notFromAPhone)
        XCTAssertEqual(PhoneRules.refusal(.add(table: "Settings", values: [:]), inventory), PhoneRules.notFromAPhone)
        // never a blank place, nor a category with no Counts as (the final review, 6): the phone's form never sends one
        XCTAssertEqual(PhoneRules.refusal(PhoneInbox.byColumnIds(.add(table: "Locations", values: [:]), inventory),
                                          inventory), InventoryWords.noPlaceName)
        XCTAssertEqual(PhoneRules.refusal(PhoneInbox.byColumnIds(.add(table: "Categories", values: [
            "Name": .text("Heating")]), inventory), inventory), String(format: InventoryWords.countsAsChoices,
                                                                        ToBuyList.groups.map(InventoryLook.title).joined(separator: ", ")))
    }

    /// The final review (2, 7): Edit again on an item whose new place the Mac refused opens with no place, never the
    /// gone waiting number (which would be refused again); a waiting vehicle shows as one.
    func testEditAgainDropsAGoneWaitingPlaceAndAWaitingVehicleIsOne() throws {
        try withPlaceColumns()
        var phone = PhoneOutbox()
        let truck = phone.add(.add(table: "Locations", values: ["Name": .text("Truck"), "Vehicle": .int(1)]),
                              what: "New place: Truck")
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertEqual(phone.view(copy).places.first { $0.id == PhoneOutbox.temporaryID(truck) }?.vehicle, true)
        let location = colId("Location"), item = colId("Item")
        let values: [String: SQLValue] = [item: .text("Zorvex lantern"), location: .int(PhoneOutbox.temporaryID(truck))]
        let none: [String: SQLValue] = [item: .text("Zorvex lantern"), location: .int(0)]
        XCTAssertEqual(copy.withoutGoneWaiting(values), none, "the truck isn't waiting any more (refused): no place")
        XCTAssertEqual(phone.view(copy).withoutGoneWaiting(values), values, "still waiting: kept")
    }

    // MARK: Items waiting for the Mac (entry fixes plan, Task 2.5)

    /// Quick add with the Mac off: six scans of one new product make one add of 6, and nothing is held; once a send of
    /// it began, a scan can't raise it (the Mac may have it).
    func testScansOfAWaitingNewItemRaiseItsQuantity() throws {
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        let quantity = try XCTUnwrap(copy.column("Quantity"))
        var outbox = PhoneOutbox()
        let id = outbox.add(.addItem(values: [colId("Item"): .text("Zorvex beans"), quantity.colId: .text("1")],
                                     barcode: "036000291452"), what: "Added Zorvex beans")
        let waiting = PhoneOutbox.temporaryID(id)
        for _ in 1...5 { XCTAssertTrue(outbox.raiseWaitingAdd(waiting, by: 1, quantity: quantity)) }
        XCTAssertEqual(outbox.pending.count, 1, "one add")
        XCTAssertEqual(outbox.view(copy).items.first { $0.id == waiting }?.values[quantity.colId], .text("6"))
        XCTAssertEqual(outbox.pending.first?.id, id, "the same change: its id kept")
        XCTAssertFalse(outbox.raiseWaitingAdd(waiting, by: 1, quantity: try XCTUnwrap(copy.column("Item"))),
                       "a cell that isn't a number is never raised")
        outbox.markSent([id])
        XCTAssertFalse(outbox.raiseWaitingAdd(waiting, by: 1, quantity: quantity), "a send began: held instead")
        XCTAssertNil(outbox.waitingAdd(waiting))
        // the send never reached the Mac (it was off): the add is this phone's again, and the next scan raises it
        outbox.unsend(PhoneDelivery(notReached: [id]), marked: [id])
        XCTAssertTrue(outbox.raiseWaitingAdd(waiting, by: 1, quantity: quantity))
        XCTAssertEqual(outbox.view(copy).items.first { $0.id == waiting }?.values[quantity.colId], .text("7"))
        XCTAssertTrue(outbox.raiseWaitingAdd(waiting, by: -10, quantity: quantity))
        XCTAssertEqual(outbox.view(copy).items.first { $0.id == waiting }?.values[quantity.colId], .text("0"),
                       "never below 0")
        XCTAssertNil(PhoneOutbox().waitingAdd(waiting))
    }

    /// Edit on a new item still on the phone saves over its add: one add, as finally typed.
    func testAWaitingAddCanBeEdited() throws {
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        var outbox = PhoneOutbox()
        let name = colId("Item")
        let id = outbox.add(.add(table: "Inventory", values: [name: .text("Zorvex rice")]), what: "Added Zorvex rice")
        let waiting = PhoneOutbox.temporaryID(id)
        XCTAssertNotNil(outbox.waitingAdd(waiting))
        XCTAssertTrue(outbox.changeWaitingAdd(waiting) { $0.merging([name: .text("Zorvex brown rice")]) { $1 } })
        XCTAssertEqual(outbox.pending.count, 1)
        XCTAssertEqual(outbox.view(copy).items.first { $0.id == waiting }?.values[name], .text("Zorvex brown rice"))
        let used = outbox.add(.adjust(row: item("Test flashlight").id, by: -1), what: "used 1")
        XCTAssertNil(outbox.waitingAdd(PhoneOutbox.temporaryID(used)), "only an add")
        XCTAssertEqual(WaitingChanges.sentWhileEditing,
                       "This item went to the Mac while you edited. Edit it again once it's there.")
    }

    /// An item opened while its add waited follows the number the Mac gave it.
    func testAnOpenedNewItemFollowsItsMacNumber() async throws {
        var outbox = PhoneOutbox()
        let id = outbox.add(.add(table: "Inventory", values: [colId("Item"): .text("Zorvex candles")]),
                            what: "Added Zorvex candles")
        let waiting = PhoneOutbox.temporaryID(id)
        let before = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertEqual(outbox.view(before).settledID(waiting), waiting, "still waiting: its own id")
        try send(outbox.pending.map(\.edit), name: "2026-10-23T10-00-01-phone1-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results:
                                        try editor.file.phoneEditResults(since: .distantPast))
        outbox.settle(with: copy)
        let shown = outbox.view(copy)
        XCTAssertEqual(shown.settledID(waiting), item("Zorvex candles").id)
        XCTAssertEqual(shown.settledID(item("Test flashlight").id), item("Test flashlight").id)
    }

    /// Phase 2 review, finding 1: Edit opened on an item whose add still waited; the add reached the Mac, then Save
    /// filled a field the add left blank. The Mac stores that blank as the file's blank text, so a change expecting
    /// the waiting add's missing value (null) is refused as changed since (seen failing first, 2026-11-18); the form's
    /// change, built by `QuickForm.sent` from the id the form opened with, expects the Mac's row and is kept.
    func testAnEditOpenedOnAWaitingAddIsKeptOnceTheMacHasTheItem() async throws {
        let notes = colId("Notes")
        var outbox = PhoneOutbox()
        let id = outbox.add(.add(table: "Inventory", values: [colId("Item"): .text("Zorvex jar")]), what: "Added Zorvex jar")
        let waiting = PhoneOutbox.temporaryID(id)
        let form = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        let opened = try XCTUnwrap(outbox.view(form).items.first { $0.id == waiting })
        try send(outbox.pending.map(\.edit), name: "2026-11-18T10-00-01-phone1-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        let jar = item("Zorvex jar").id
        XCTAssertEqual(item("Zorvex jar")[inventory.items.column("Notes")!], .text(""), "the file's blank text")
        guard case .refused(InventoryWords.changedSince) = try await editor.apply(.revert(
            table: "Inventory", row: jar, colId: notes, value: .text("Top shelf"), expected: .null))
        else { return XCTFail("the Mac's strict compare: null is not its blank text") }

        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results:
                                        try editor.file.phoneEditResults(since: .distantPast))
        let row = try XCTUnwrap(copy.items.first { $0.id == jar }), columns = copy.columns.filter(\.editable)
        let shown = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column.colId, column.kind == "reference" ? String(opened.values[column.colId]?.whole ?? 0)
                : InventoryValues.plain(opened.values[column.colId] ?? .null))
        })
        var saving = false
        let sent = QuickForm.sent(copy: copy, columns: columns, row: row, openedID: waiting, openedValues: opened.values,
                                  was: shown, now: shown.merging([notes: "Top shelf"]) { $1 },
                                  new: .add(editAgain: false), barcode: nil, saving: &saving)
        guard case .cells(let cells) = sent, cells.count == 1 else { return XCTFail("\(sent)") }
        var phone = PhoneOutbox()
        phone.add(cells[0].change, what: cells[0].what)
        try send(phone.pending.map(\.edit), name: "2026-11-18T10-00-02-phone1-b.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertNil(try editor.file.phoneEditResult(phone.pending[0].id)?.refused)
        XCTAssertEqual(item("Zorvex jar")[inventory.items.column("Notes")!], .text("Top shelf"))
    }

    /// Phase 2 review, round 2, 1: as above, but the Mac renamed the new item before this phone's copy caught up. The
    /// form's base after arrival (`QuickForm.arrived`) keeps the add's own name and Quantity and takes the Mac's row
    /// only for what the add left out: Save's rename is refused as changed since and listed with the typed name kept
    /// (Edit again opens it), while the blank Notes filled and the Quantity the Mac left alone are kept.
    func testAnAddsCellTheMacChangedBeforeThePhoneCaughtUpIsRefused() async throws {
        let name = colId("Item"), notes = colId("Notes"), quantity = colId("Quantity")
        var outbox = PhoneOutbox()
        let id = outbox.add(.add(table: "Inventory", values: [name: .text("Zorvex jar"), quantity: .text("2")]),
                            what: "Added Zorvex jar")
        let waiting = PhoneOutbox.temporaryID(id)
        let opened = try XCTUnwrap(outbox.view(PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:]))
            .items.first { $0.id == waiting })
        try send(outbox.pending.map(\.edit), name: "2026-11-18T11-00-01-phone1-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        let jar = item("Zorvex jar").id
        guard case .done = try await editor.apply(.set(table: "Inventory", row: jar, colId: name,
                                                       value: .text("Zorvex crock"))) else { return XCTFail() }

        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results:
                                        try editor.file.phoneEditResults(since: .distantPast))
        let row = try XCTUnwrap(copy.items.first { $0.id == jar }), columns = copy.columns.filter(\.editable)
        let shown = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column.colId, column.kind == "reference" ? String(opened.values[column.colId]?.whole ?? 0)
                : InventoryValues.plain(opened.values[column.colId] ?? .null))
        })
        let typed = shown.merging([name: "Zorvex jar, big", notes: "Top shelf", quantity: "3"]) { $1 }
        let arrived = QuickForm.arrived(openedID: waiting, openedValues: opened.values, row: row)
        var saving = false, again = false
        let sent = QuickForm.sent(copy: copy, columns: columns, row: row, openedID: arrived.id, openedValues: arrived.values,
                                  was: shown, now: typed, new: .add(editAgain: false), barcode: nil, saving: &saving)
        XCTAssertEqual(QuickForm.sent(copy: copy, columns: columns, row: row, openedID: waiting,
                                      openedValues: opened.values, was: shown, now: typed, new: .add(editAgain: false),
                                      barcode: nil, saving: &again), sent, "Save's fallback says the same")
        guard case .cells(let cells) = sent, cells.count == 3 else { return XCTFail("\(sent)") }
        var phone = PhoneOutbox()
        for cell in cells { phone.add(cell.change, what: cell.what) }
        try send(phone.pending.map(\.edit), name: "2026-11-18T11-00-02-phone1-b.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        let results = try editor.file.phoneEditResults(since: .distantPast)
        let byColumn = Dictionary(uniqueKeysWithValues: zip(cells.map { cell -> String in
            guard case .revert(_, _, let colId, _, _) = cell.change else { return "" }
            return colId
        }, phone.pending.map(\.id)))
        XCTAssertEqual(results[byColumn[name]!]?.refused, InventoryWords.changedSince)
        XCTAssertNil(results[byColumn[notes]!]?.refused)
        XCTAssertNil(results[byColumn[quantity]!]?.refused)
        XCTAssertEqual(item("Zorvex crock")[inventory.items.column("Notes")!], .text("Top shelf"))
        XCTAssertEqual(InventoryValues.plain(item("Zorvex crock")[inventory.items.column("Quantity")!]), "3")
        var settled = phone
        settled.settle(with: PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: results))
        XCTAssertEqual(settled.refused.map(\.message), [InventoryWords.changedSince])
        let edit = try XCTUnwrap(settled.refused.first?.again(in: PhoneInventory.make(inventory, toBuy: nil, waiting: [],
                                                                                         results: results)))
        XCTAssertEqual(edit.values, [name: .text("Zorvex jar, big")], "the typed name kept for Edit again")
    }

    /// Phase 2 review, 13: a switch's 0 reaching a blank cell. The Mac's editor and `PhoneRules` are as they were at
    /// d133ab2d (no change to either since), so an older Mac answers as this one does. A phone sends a switch only when
    /// its shown value changed, and a blank cell shows off, so a 0 reaches a blank cell only after the Mac blanked one
    /// the form showed on: refused as changed since, as any cell the Mac changed meanwhile. A plain set of 0 on a blank
    /// cell is kept as 0, which every reader takes as off.
    func testASwitchsZeroOnABlankCell() async throws {
        try editor.file.ensureColumn("Inventory", colId: "Empty_until_needed", label: Inventory.Label.emptyUntilNeeded,
                                     type: "Bool")
        try editor.reload()
        let flashlight = item("Test flashlight").id, empty = colId(Inventory.Label.emptyUntilNeeded)
        let cell = { self.item("Test flashlight")[self.inventory.items.column(Inventory.Label.emptyUntilNeeded)!] }
        let blank = cell()
        XCTAssertNotEqual(blank, .int(1), "off before anything is sent")
        var phone = PhoneOutbox()
        phone.add(.revert(table: "Inventory", row: flashlight, colId: empty, value: .int(0), expected: .int(1)),
                  what: "Test flashlight: \(Inventory.Label.emptyUntilNeeded)")
        phone.add(.set(table: "Inventory", row: flashlight, colId: empty, value: .int(0)),
                  what: "Test flashlight: \(Inventory.Label.emptyUntilNeeded)")
        try send(phone.pending.map(\.edit), name: "2026-11-18T10-00-03-phone1-c.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(try editor.file.phoneEditResult(phone.pending[0].id)?.refused, InventoryWords.changedSince)
        XCTAssertNil(try editor.file.phoneEditResult(phone.pending[1].id)?.refused)
        XCTAssertEqual(cell(), .int(0))
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        let row = try XCTUnwrap(copy.items.first { $0.id == flashlight }), column = try XCTUnwrap(copy.column(Inventory.Label.emptyUntilNeeded))
        XCTAssertFalse(PhoneEditRules.isOn(copy.cell(row, column)), "the phone shows it off")
    }

    // MARK: Also changed on another phone (beta run 3's S4.4, run 2's B2-13)

    /// B2-13's own case: the Pro Max typed 10 for the jugs and the iPad tapped Used 1 twice, both on the copy from
    /// before the Mac went off (the iPad's an older phone's, with only its tap times). The Mac keeps all three as
    /// before (6 → 10 → 8); each of the two phones then says "Also changed on another phone" under the jugs' number
    /// for a day, and no longer after it; a third phone, another item, and the Mac's copy's Private items never do.
    func testTwoPhonesChangingAnItemApartEachSayItForADay() async throws {
        let jugs = item("Drinking water jugs").id  // 6
        let before = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:],
                                         now: Date().addingTimeInterval(-3600))
        var proMax = PhoneOutbox(), iPad = PhoneOutbox(), third = PhoneOutbox()
        proMax.add(.set(table: "Inventory", row: jugs, colId: colId("Quantity"), value: .text("10")),
                   what: "Drinking water jugs: Quantity", seen: before.writtenAt)
        let tapped = Date().addingTimeInterval(-1800)
        iPad.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1", now: tapped)
        iPad.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1", now: tapped)
        third.add(.adjust(row: item("Test flashlight").id, by: -1), what: "Test flashlight: used 1",
                  seen: before.writtenAt)
        try send(proMax.pending.map(\.edit), name: "2026-10-14T10-00-01-phone1-a.json")
        try send(iPad.pending.map(\.edit), name: "2026-10-14T10-00-02-phone2-b.json")
        try send(third.pending.map(\.edit), name: "2026-10-14T10-00-03-phone3-c.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(quantity("Drinking water jugs"), .text("8"), "merged as before: 6 → 10 → 8")

        let merged = try editor.file.alsoChanged()
        XCTAssertEqual(merged.map(\.item), [jugs], "only the item two phones changed")
        XCTAssertEqual(merged.first?.edits, proMax.pending.map(\.id) + iPad.pending.map(\.id))
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results:
                                        try editor.file.phoneEditResults(since: .distantPast), alsoChanged: merged)
        XCTAssertEqual(copy.alsoChanged, merged)
        let proMaxEdit = proMax.pending.map(\.id)
        proMax.settle(with: copy)
        iPad.settle(with: copy)
        third.settle(with: copy)
        XCTAssertEqual(proMax.kept, Set(proMaxEdit), "its own change, kept by the Mac")
        let met = Date()
        for (name, phone) in [("Pro Max", proMax), ("iPad", iPad)] {
            XCTAssertTrue(phone.alsoChanged(forItem: jugs, in: copy, now: met), name)
            XCTAssertTrue(phone.alsoChanged(forItem: jugs, in: copy, now: met.addingTimeInterval(23 * 3600)),
                          "\(name): still the same day")
            XCTAssertFalse(phone.alsoChanged(forItem: jugs, in: copy, now: met.addingTimeInterval(25 * 3600)),
                           "\(name): a day after they met at the Mac, gone")
            XCTAssertFalse(phone.alsoChanged(forItem: item("Test flashlight").id, in: copy, now: met), name)
        }
        XCTAssertFalse(third.alsoChanged(forItem: jugs, in: copy, now: met), "a phone that changed none of it")
        XCTAssertFalse(PhoneOutbox().alsoChanged(forItem: jugs, in: copy, now: met))
        XCTAssertEqual(try editor.file.alsoChanged(now: met.addingTimeInterval(25 * 3600)), [], "the Mac's day is over")
        XCTAssertEqual(PhoneInventory.AlsoChanged.line, "Also changed on another phone")

        let heater = item("Indoor propane heater").id
        let hidden = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:], alsoChanged: [
            .init(item: heater, until: "2099-01-01T00:00:00Z", edits: ["x", "y"])])
        XCTAssertNil(hidden.alsoChanged, "a Private item never reaches a phone")
        let saved = try JSONDecoder().decode(PhoneOutbox.self, from: JSONEncoder().encode(proMax))
        XCTAssertEqual(saved, proMax)
        XCTAssertTrue(saved.alsoChanged(forItem: jugs, in: copy, now: met), "kept across the app's restarts")
    }

    /// F-095: one phone paired again between its two changes to the jugs (its label "phone1", then "phone3"), the
    /// second made on the copy from before the first reached the Mac. It sends its own id with both, so the Mac sees
    /// one phone and says nothing; a second phone's id, the same two changes, says it. A label and an id are never
    /// two phones (a phone from before the id, then the same one upgraded), and an id that isn't one is the label.
    func testAPhonePairedAgainIsStillOnePhone() async throws {
        let jugs = item("Drinking water jugs").id
        let old = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:],
                                      now: Date().addingTimeInterval(-3600))
        let me = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        func twice(_ firstDevice: String?, _ secondDevice: String?) async throws -> [PhoneInventory.AlsoChanged] {
            try editor.file.db.execute("DROP TABLE IF EXISTS \"PrepareMe_PhoneEdits\"")
            var first = PhoneOutbox(), second = PhoneOutbox()
            first.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1", seen: old.writtenAt)
            second.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1", seen: old.writtenAt)
            try send(first.pending.map(\.edit), name: "2026-10-14T10-00-01-phone1-a.json", device: firstDevice)
            try send(second.pending.map(\.edit), name: "2026-10-14T10-00-02-phone3-b.json", device: secondDevice)
            try await PhoneInbox.process(folder: base, editor: editor)
            return try editor.file.alsoChanged()
        }
        let repaired = try await twice(me, me), two = try await twice(me, other)
        let labels = try await twice(nil, nil), upgraded = try await twice(nil, me)
        XCTAssertEqual(repaired, [], "one phone through a new pairing")
        XCTAssertEqual(two.map(\.item), [jugs], "two phones' ids: two phones")
        XCTAssertEqual(labels.map(\.item), [jugs], "two labels and no ids: as before")
        XCTAssertEqual(upgraded, [], "a label, then an id: maybe the same phone, upgraded")
        XCTAssertEqual(PhoneInbox.who(device: "not-an-id", label: "phone2"), "phone2")
        XCTAssertEqual(PhoneInbox.who(device: me.uppercased(), label: "phone2"), "device:" + me)
        XCTAssertEqual(PhoneInbox.who(device: nil, label: "phone2"), "phone2")
    }

    /// The phone that made the only change says nothing, and so does one whose change was made with the other's already
    /// in its copy (one after the other at home); the line never comes back once the copy drops its answers.
    func testOnlyAChangeMadeWithoutTheOthersInViewSaysIt() async throws {
        let jugs = item("Drinking water jugs").id
        var first = PhoneOutbox(), second = PhoneOutbox()
        let old = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:],
                                      now: Date().addingTimeInterval(-3600))
        first.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1", seen: old.writtenAt)
        try send(first.pending.map(\.edit), name: "2026-10-14T10-00-01-phone1-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(try editor.file.alsoChanged(), [], "one phone alone")
        let fresh = PhoneInventory.make(inventory, toBuy: nil, waiting: [],
                                        results: try editor.file.phoneEditResults(since: .distantPast),
                                        now: Date().addingTimeInterval(1))
        first.settle(with: fresh)
        XCTAssertFalse(first.alsoChanged(forItem: jugs, in: fresh))
        second.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1", seen: fresh.writtenAt)
        try send(second.pending.map(\.edit), name: "2026-10-14T10-00-02-phone2-b.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(quantity("Drinking water jugs"), .text("4"))
        XCTAssertEqual(try editor.file.alsoChanged(), [], "the second saw the first's change: nothing to say")
        first.settle(with: PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:]))
        XCTAssertNil(first.kept, "forgotten once the copy no longer carries its answer")
    }

    /// Fix round 1: a pair counts only for its own day. Two phones' changes two days ago (an old pair) and two other
    /// changes in the last hour (a new pair, the later one's copy showing the old pair but not the newer change): only
    /// the new pair's ids, and a day from the newer change; the old pair's phone that changed nothing since says
    /// nothing.
    func testAnOldPairNeverComesBackWithANewOne() throws {
        try editor.file.ensurePhoneEdits()
        let jugs = item("Drinking water jugs").id, now = Date(), format = ISO8601DateFormatter()
        func kept(_ id: String, _ phone: String, hoursAgo: Double, seenHoursAgo: Double) throws {
            try editor.file.db.execute("INSERT INTO \"PrepareMe_PhoneEdits\" (id, phone, at, refused, row, seen) "
                                       + "VALUES (?, ?, ?, NULL, ?, ?)",
                                       [.text(id), .text(phone), .text(format.string(from: now - hoursAgo * 3600)),
                                        .int(jugs), .text(format.string(from: now - seenHoursAgo * 3600))])
        }
        try kept("a", "phone1", hoursAgo: 50, seenHoursAgo: 60)
        try kept("b", "phone2", hoursAgo: 49, seenHoursAgo: 60)  // apart from a, two days ago
        try kept("d", "phone1", hoursAgo: 2, seenHoursAgo: 3)
        try kept("c", "phone3", hoursAgo: 1, seenHoursAgo: 3)  // its copy held a and b, not d
        let merged = try editor.file.alsoChanged(now: now)
        XCTAssertEqual(merged.map(\.edits), [["d", "c"]], "only the pair whose day isn't over")
        XCTAssertEqual(merged.first?.until, format.string(from: now - 3600 + PhoneInventory.AlsoChanged.shownFor))
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:], alsoChanged: merged)
        var second = PhoneOutbox()
        second.kept = ["b"]
        XCTAssertFalse(second.alsoChanged(forItem: jugs, in: copy, now: now), "b's day was two days ago")
        second.kept = ["c"]
        XCTAssertTrue(second.alsoChanged(forItem: jugs, in: copy, now: now))
    }

    /// An inventory file whose phone-edit record was made before `seen` reads as none, keeps its rows, and takes the
    /// column with the next phone change.
    func testAnOlderPhoneEditRecordGetsItsNewColumn() async throws {
        try editor.file.db.execute("CREATE TABLE \"PrepareMe_PhoneEdits\" (id TEXT PRIMARY KEY, phone TEXT NOT NULL, "
                                   + "at TEXT NOT NULL, refused TEXT, row INTEGER)")
        try editor.file.db.execute("INSERT INTO \"PrepareMe_PhoneEdits\" (id, phone, at, refused, row) VALUES "
                                   + "('older', 'phone1', '2026-10-01T12:00:00Z', NULL, 3)")
        XCTAssertEqual(try editor.file.alsoChanged(), [])
        let jugs = item("Drinking water jugs").id
        var first = PhoneOutbox(), second = PhoneOutbox()
        first.add(.adjust(row: jugs, by: -1), what: "a", seen: "2026-10-01T00:00:00Z")
        second.add(.adjust(row: jugs, by: -1), what: "b", seen: "2026-10-01T00:00:00Z")
        try send(first.pending.map(\.edit), name: "2026-10-14T10-00-01-phone1-a.json")
        try send(second.pending.map(\.edit), name: "2026-10-14T10-00-02-phone2-b.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(try editor.file.alsoChanged().map(\.item), [jugs])
        XCTAssertEqual(try editor.file.phoneEditResult("older"),
                       PhoneInventory.Result(at: "2026-10-01T12:00:00Z", refused: nil, row: 3), "the older row reads")
    }

    func testARefusedEditIsAnsweredAndShownOnThePhone() async throws {
        var outbox = PhoneOutbox()
        outbox.add(.set(table: "Inventory", row: item("Test flashlight").id, colId: colId("Notes"),
                        value: .text("REFUSE")), what: "Test flashlight: Notes")
        outbox.add(.adjust(row: item("Indoor propane heater").id, by: -1), what: "a private row")
        try send(outbox.pending.map(\.edit), name: "a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        outbox.settle(with: PhoneInventory.make(inventory, toBuy: nil, waiting: [],
                                                results: try editor.file.phoneEditResults(since: .distantPast)))
        XCTAssertEqual(outbox.refused.map(\.message), ["Inventory row 5, Notes: refused", PhoneRules.privateRow])
        XCTAssertEqual(InventoryValues.plain(item("Test flashlight")[inventory.items.column("Notes")!]), "")
        // the edit itself is kept with its refusal, so the form can open again with what was typed (Task 4.1)
        XCTAssertEqual(outbox.refused.first?.edit?.change,
                       .set(table: "Inventory", row: item("Test flashlight").id, colId: colId("Notes"),
                            value: .text("REFUSE")))
    }

    func testARefusalSavedBeforeItKeptItsEditStillReads() throws {
        let old = #"{"pending":[],"refused":[{"id":"a","what":"Test flashlight: Notes","message":"no"}]}"#
        let outbox = try JSONDecoder().decode(PhoneOutbox.self, from: Data(old.utf8))
        XCTAssertEqual(outbox.refused.first?.what, "Test flashlight: Notes")
        XCTAssertNil(outbox.refused.first?.edit)
    }

    /// B2-11 (R4.3): the item and its place, as the phone knew them when the change was made, go with the refusal (the
    /// Mac's next copy no longer has a removed item); a refusal kept before then reads without.
    func testARefusalKeepsTheItemAndItsPlace() throws {
        var outbox = PhoneOutbox()
        outbox.add(.adjust(row: 7, by: -1), what: "Headlamp: used 1", item: "Headlamp (Bin 29)")
        outbox.add(.adjust(row: 8, by: -1), what: "Other: used 1")
        outbox.refuse(outbox.pending.map(\.id), message: "no")
        XCTAssertEqual(outbox.refused.map(\.item), ["Headlamp (Bin 29)", nil])
        let saved = try JSONDecoder().decode(PhoneOutbox.self, from: JSONEncoder().encode(outbox))
        XCTAssertEqual(saved.refused.map(\.item), ["Headlamp (Bin 29)", nil])
    }

    func testForgettingOneRefusalKeepsTheOthers() {
        var outbox = PhoneOutbox()
        outbox.add(.adjust(row: 1, by: -1), what: "one")
        outbox.add(.adjust(row: 2, by: -1), what: "two")
        outbox.refuse(outbox.pending.map(\.id), message: "no")
        outbox.forgetRefusal(outbox.refused[0].id)
        XCTAssertEqual(outbox.refused.map(\.what), ["two"])
    }

    func testAnEditAppliedBeforeACheckThatCantRunIsNeverAppliedAgain() async throws {
        let jugs = item("Drinking water jugs").id
        let one = PhoneEdit(change: .adjust(row: jugs, by: -1))
        let two = PhoneEdit(change: .set(table: "Inventory", row: jugs, colId: colId("Notes"), value: .text("x")))
        try send([one, two], name: "a.json")
        check.brokenAfter = 1  // the first check answers, the second can't run
        do {
            try await PhoneInbox.process(folder: base, editor: editor)
            XCTFail("must throw")
        } catch is CheckUnavailable {}
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"))
        check.brokenAfter = nil
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"), "the first edit isn't applied twice")
        XCTAssertNotNil(try editor.file.phoneEditResult(two.id))
    }

    // MARK: The slice 5 review

    func testAPrivateCellHoldingTextNeverReachesAPhone() throws {
        let generator = item("Dual fuel generator").id
        try editor.file.set(inventory.items, row: generator, column: inventory.items.column("Mac only")!,
                            to: .text("yes"))
        try editor.reload()
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertFalse(copy.items.contains { $0.id == generator })
        XCTAssertTrue(inventory.isPrivate(item("Dual fuel generator")))
    }

    func testAnEditSentAgainWeeksLaterIsNeverAppliedTwice() async throws {
        let jugs = item("Drinking water jugs").id
        let edit = PhoneEdit(change: .adjust(row: jugs, by: -1))
        try send([edit], name: "a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        try send([edit], name: "b.json")  // the phone never heard back, and sends it again much later
        try await PhoneInbox.process(folder: base, editor: editor, now: Date().addingTimeInterval(20 * 86_400))
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"))
    }

    func testOneEditThatCantBeSavedNeverHoldsUpTheRest() async throws {
        let jugs = item("Drinking water jugs").id
        let tick = ToBuyTick(kind: .notNeeded, item: "S-1")
        let first = PhoneEdit(change: .tick(tick)), again = PhoneEdit(change: .tick(tick))  // the same tick twice
        let after = PhoneEdit(change: .adjust(row: jugs, by: -1))
        try send([first, again, after], name: "a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(try editor.file.phoneEditResult(again.id)?.refused, InventoryWords.alreadySent)
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("inbox").path), [])
    }

    func testTheMacsUndoNeverOverwritesAPhonesChangeMadeSince() async throws {
        let jugs = item("Drinking water jugs").id
        guard case .done(let undo, _) = try await editor.apply(.adjust(row: jugs, by: -1)) else { return XCTFail() }
        try send([PhoneEdit(change: .adjust(row: jugs, by: -1))], name: "a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        let outcome = try await editor.apply(undo)
        XCTAssertEqual(outcome, .refused(InventoryWords.changedSince))
        XCTAssertEqual(quantity("Drinking water jugs"), .text("4"))
    }

    func testAPhonesAnswerNeverSaysAnItemWentPrivate() {
        XCTAssertEqual(PhoneRules.privateRow, InventoryWords.noRow)
    }

    /// R4.4: a copy from before categories carried a group still lists each supply's calculators by the category's name.
    func testAnOlderCopyWithoutGroupsStillGroupsSuppliesByName() throws {
        let links = try CalculatorLinks(try Data(contentsOf: CalculatorLinksTests.fixtures
            .appendingPathComponent("calculator-links.json")))
        let columns = [PhoneInventory.Column(colId: "Item", label: "Item", kind: "text", target: nil, choices: [], editable: true),
                       PhoneInventory.Column(colId: "Category", label: "Category", kind: "reference", target: "Categories",
                                             choices: [], editable: true)]
        let rice = PhoneInventory.Row(id: 1, position: 1, values: ["Item": .text("Rice"), "Category": .int(2)])
        let copy = PhoneInventory(writtenAt: "", columns: columns, items: [rice], places: [],
                                  categories: [.init(id: 1, name: "Water", group: nil), .init(id: 2, name: "Food", group: nil)],
                                  headsUpDays: 60, toBuy: [], results: [:])
        let supplies = copy.supplyCalculators(links: links, figures: nil)
        XCTAssertEqual(supplies.first { $0.group == "Food" }?.stocked, "1 item")
        XCTAssertEqual(supplies.first { $0.group == "Water" }?.stocked, "none entered")
    }

    func testAnAddedRowAndBoughtShowOnThePhoneUntilTheMacAnswers() {
        var outbox = PhoneOutbox()
        outbox.add(.add(table: "Inventory", values: [colId("Item"): .text("Lantern")]), what: "Lantern")
        outbox.add(.bought(values: [colId("Item"): .text("Water")], tick: ToBuyTick(kind: .bought, item: "S-1")),
                   what: "Bought Water")
        outbox.add(.tick(ToBuyTick(kind: .add, text: "Mantles")), what: "Mantles")
        let item = ToBuyList.Item(id: "S-1", text: "Water", why: "", need: 12, unit: "gallons", category: "Water",
                                  horizon: nil, lifeSafety: true, cost: nil)
        let copy = PhoneInventory(writtenAt: "", columns: [], items: [], places: [], categories: [], headsUpDays: 60,
                                  toBuy: [item], results: [:])
        let shown = outbox.view(copy)
        XCTAssertEqual(shown.items.map(\.id), outbox.pending.prefix(2).map { PhoneOutbox.temporaryID($0.id) })
        XCTAssertTrue(shown.items.allSatisfy { $0.id < 0 })
        XCTAssertEqual(shown.toBuy, [])
        XCTAssertEqual(outbox.ownItems.map(\.text), ["Mantles"])
    }

    func testEditsOfAnyOtherShapeOrOverTheLimitsAreRefused() throws {
        XCTAssertNil(PhoneEdits.read(Data("{}".utf8)))
        XCTAssertNil(PhoneEdits.read(Data(#"{"edits": []}"#.utf8)))
        let many = PhoneEdits(edits: (0...PhoneEdits.maxEdits).map { _ in PhoneEdit(change: .adjust(row: 1, by: 1)) })
        XCTAssertNil(PhoneEdits.read(try JSONEncoder().encode(many)))
        let one = PhoneEdits(edits: [PhoneEdit(change: .adjust(row: 1, by: 1))])
        XCTAssertEqual(PhoneEdits.read(try JSONEncoder().encode(one)), one)
    }

    // MARK: Equipment manuals (top-ten plan, phase 7, Task 7.3)

    func testTheCopyCarriesAManualPath() throws {
        let jugs = item("Drinking water jugs").id
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:], manuals: [jugs])
        XCTAssertEqual(copy.items.first { $0.id == jugs }?.manual, "item-\(jugs).pdf")
        XCTAssertTrue(copy.items.filter { $0.id != jugs }.allSatisfy { $0.manual == nil })
        try copy.write(in: base)
        XCTAssertEqual(PhoneInventory.read(in: base), copy)
        // a phone's waiting change to the item keeps its manual
        var outbox = PhoneOutbox()
        outbox.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1")
        outbox.add(.set(table: "Inventory", row: jugs, colId: colId("Notes"), value: .text("x")), what: "Notes")
        XCTAssertEqual(outbox.view(copy).items.first { $0.id == jugs }?.manual, "item-\(jugs).pdf")
    }

    func testAPrivateItemsManualNeverReachesTheCopy() throws {
        let heater = item("Indoor propane heater").id
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:], manuals: [heater])
        XCTAssertFalse(copy.items.contains { $0.manual != nil })
        let written = String(decoding: try JSONEncoder().encode(copy), as: UTF8.self)
        XCTAssertFalse(written.contains("item-\(heater).pdf"))
    }

    func testAnOlderCopyWithoutManualsStillReads() throws {
        let older = #"{"id": 3, "position": 1, "values": {}}"#
        let row = try JSONDecoder().decode(PhoneInventory.Row.self, from: Data(older.utf8))
        XCTAssertNil(row.manual)
        XCTAssertEqual(row, PhoneInventory.Row(id: 3, position: 1, values: [:]))
        // and a copy without a manual writes no manual key, so an older phone reads it as before
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(copy), as: UTF8.self).contains("\"manual\""))
    }

    // MARK: Undo after Used 1 and 1 more (B2-08, beta run 2)

    /// Beta run 3, B3-07: an item with a change the Mac hasn't taken says "Waiting for the Mac." on its own screen, for
    /// any kind of change to it; not while the change is still held for its Undo, and not for another item.
    func testAnItemWithAChangeWaitingForTheMacSaysSo() {
        let jugs = item("Drinking water jugs").id
        let other = item("Test flashlight").id
        let made = Date()
        var outbox = PhoneOutbox()
        XCTAssertFalse(outbox.hasWaitingChange(forItem: jugs, now: made))
        outbox.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1", now: made, withUndo: true)
        XCTAssertFalse(outbox.hasWaitingChange(forItem: jugs, now: made.addingTimeInterval(2)), "still held for Undo")
        XCTAssertTrue(outbox.hasWaitingChange(forItem: jugs, now: made.addingTimeInterval(6)), "its hold is over")
        XCTAssertFalse(outbox.hasWaitingChange(forItem: other, now: made.addingTimeInterval(6)),
                       "only the item changed")
        outbox.add(.set(table: "Inventory", row: other, colId: colId("Quantity"), value: .text("3")), what: "edit",
                   now: made)
        XCTAssertTrue(outbox.hasWaitingChange(forItem: other, now: made.addingTimeInterval(6)), "an edit counts too")
        XCTAssertEqual(WaitingChanges.itemLine, "Waiting for the Mac.")
    }

    /// Entry fixes, phase 4: a change a send began less than 30 seconds ago, still waiting for the Mac's answer, isn't
    /// sent again at the next look; after that it is, as before. One that never reached the Mac (unsent) goes at once.
    func testRecentlySentChangesAreNotResent() {
        var outbox = PhoneOutbox()
        let made = Date()
        let first = outbox.add(.adjust(row: item("Drinking water jugs").id, by: -1), what: "used 1", now: made)
        let second = outbox.add(.adjust(row: item("Test flashlight").id, by: -1), what: "used 1", now: made)
        outbox.markSent([first], now: made)
        XCTAssertEqual(outbox.toSend(now: made.addingTimeInterval(10)).map(\.id), [second])
        XCTAssertEqual(outbox.ready(now: made.addingTimeInterval(10)).count, 2, "both still wait, as the line counts")
        XCTAssertEqual(outbox.toSend(now: made.addingTimeInterval(31)).map(\.id), [first, second])
        XCTAssertTrue(outbox.awaitingAnswer, "the phone looks again for the answer")
        XCTAssertEqual(outbox.toSend(now: made.addingTimeInterval(-60)).map(\.id), [first, second],
                       "a clock set back: sent again, never held for good")
        outbox.unsend(PhoneDelivery(notReached: [first]), marked: [first])
        XCTAssertEqual(outbox.toSend(now: made.addingTimeInterval(10)).map(\.id), [first, second], "never reached: at once")
        XCTAssertFalse(outbox.awaitingAnswer)
    }

    func testUndoWithinAFewSecondsTakesTheChangeBackBeforeItIsSent() {
        let jugs = item("Drinking water jugs").id  // 6
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        let quantityColumn = colId("Quantity")
        func shown(_ outbox: PhoneOutbox) -> SQLValue? {
            outbox.view(copy).items.first { $0.id == jugs }?.values[quantityColumn]
        }
        XCTAssertEqual(PhoneOutbox.undoFor, 5)
        let tapped = Date()
        var outbox = PhoneOutbox()
        let id = outbox.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1", now: tapped, withUndo: true)
        XCTAssertEqual(shown(outbox), .text("5"), "shown at once")
        XCTAssertEqual(outbox.ready(now: tapped.addingTimeInterval(4)), [], "held for its Undo: not sent yet")
        XCTAssertEqual(outbox.undoable(row: jugs, now: tapped.addingTimeInterval(4))?.id, id)
        XCTAssertEqual(outbox.pending.first.map { PhoneOutbox.undoLabel($0, unit: "") }, "Undo Used 1")
        XCTAssertFalse(PhoneInventoryCache.mayEdit(canEdit: false, fromBackup: false),
                       "a phone that reads only shows no Undo: its model never asks")
        XCTAssertNil(outbox.undoable(row: item("Test flashlight").id, now: tapped.addingTimeInterval(4)),
                     "only on the item changed")
        XCTAssertTrue(outbox.undo(id, now: tapped.addingTimeInterval(4)))
        XCTAssertEqual(outbox.pending, [], "taken back: nothing goes to the Mac")
        XCTAssertEqual(shown(outbox), .text("6"), "the number goes back")
        let more = outbox.add(.adjust(row: jugs, by: 1), what: "Drinking water jugs: 1 more", now: tapped, withUndo: true)
        XCTAssertEqual(outbox.pending.first.map { PhoneOutbox.undoLabel($0, unit: "") }, "Undo 1 more")
        XCTAssertEqual(shown(outbox), .text("7"))
        XCTAssertTrue(outbox.undo(more, now: tapped.addingTimeInterval(1)))
        XCTAssertEqual(shown(outbox), .text("6"))
    }

    func testOnceItsFewSecondsAreOverTheChangeGoesAndIsNeverTakenBack() {
        let jugs = item("Drinking water jugs").id
        let tapped = Date()
        var outbox = PhoneOutbox()
        let first = outbox.add(.adjust(row: jugs, by: -1), what: "used 1", now: tapped, withUndo: true)
        let notes = outbox.add(.set(table: "Inventory", row: jugs, colId: colId("Notes"), value: .text("Made-up")),
                               what: "Notes", now: tapped.addingTimeInterval(1))
        let second = outbox.add(.adjust(row: jugs, by: -1), what: "used 1", now: tapped.addingTimeInterval(3),
                                withUndo: true)
        XCTAssertEqual(outbox.undoable(row: jugs, now: tapped.addingTimeInterval(4))?.id, second,
                       "the latest is the one Undo takes back")
        let later = tapped.addingTimeInterval(6)
        XCTAssertEqual(outbox.ready(now: later).map(\.id), [first, notes],
                       "they go in order: a change after a held one waits with it")
        XCTAssertFalse(outbox.undo(first, now: later), "its few seconds are over: it stays")
        outbox.markSent([first, notes])
        XCTAssertFalse(outbox.undo(first, now: tapped.addingTimeInterval(1)), "a clock set back never takes back one sent")
        XCTAssertEqual(outbox.pending.count, 3, "nothing lost")
        XCTAssertEqual(outbox.ready(now: tapped.addingTimeInterval(-3600)).map(\.id), [first, notes, second],
                       "a clock set back hours never holds a change for good")
        XCTAssertEqual(outbox.ready(now: tapped.addingTimeInterval(9)).map(\.id), [first, notes, second])
        let plain = outbox.add(.adjust(row: jugs, by: 1), what: "1 more", now: later)  // quick add's: no Undo here
        XCTAssertFalse(outbox.ready(now: later).contains { $0.id == plain }, "behind a held one, it waits with it")
        XCTAssertTrue(outbox.ready(now: tapped.addingTimeInterval(9)).contains { $0.id == plain })
        var fresh = PhoneOutbox()
        let alone = fresh.add(.adjust(row: jugs, by: 1), what: "1 more", now: later)
        XCTAssertEqual(fresh.ready(now: later).map(\.id), [alone], "a change without Undo goes at once")
        XCTAssertNil(fresh.undoable(row: jugs, now: later), "and has no Undo")
    }

    /// Fix round 1: a change once sent (posted, not yet answered) is never withdrawn: the Mac may apply it still. Quick
    /// add's Undo last then sends a 1 less marked as a correction instead.
    func testAChangeSentButNotAnsweredIsNeverWithdrawn() throws {
        let jugs = item("Drinking water jugs").id
        var outbox = PhoneOutbox()
        let scan = outbox.add(.adjust(row: jugs, by: 1), what: "Drinking water jugs: 1 more")
        let other = outbox.add(.adjust(row: jugs, by: 1), what: "Drinking water jugs: 1 more")
        outbox.markSent([scan])
        XCTAssertFalse(outbox.withdraw(scan), "sent: it stays until the Mac answers")
        XCTAssertEqual(outbox.pending.map(\.id), [scan, other])
        XCTAssertTrue(outbox.withdraw(other), "not sent yet: taken back")
        var back = try JSONDecoder().decode(PhoneOutbox.self, from: try JSONEncoder().encode(outbox))
        XCTAssertFalse(back.withdraw(scan), "and still once saved and read again")
        let less = outbox.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: 1 less", correction: true)
        XCTAssertEqual(outbox.pending.last?.edit.correction, true)
        XCTAssertEqual(RunsOut.ownTaps(outbox).count, 0, "a correction is never counted as use on the phone")
        XCTAssertNil(outbox.pending.first { $0.id == less }?.use)
    }

    /// A send that never reached the Mac (away from home, the Mac off, or left out when the one-at-a-time sends
    /// stopped) leaves its changes waiting as never sent, so quick add's Undo last takes them back again; one that may
    /// have arrived (an answer, or a post that went out with no answer) stays sent (checkpoint 2).
    func testOnlyASendThatMayHaveReachedTheMacStaysSent() async throws {
        let jugs = item("Drinking water jugs").id
        func three() -> (PhoneOutbox, [String]) {
            var outbox = PhoneOutbox()
            let ids = (1...3).map { _ in outbox.add(.adjust(row: jugs, by: 1), what: "Drinking water jugs: 1 more") }
            outbox.markSent(ids)
            return (outbox, ids)
        }
        var (outbox, ids) = three()
        let away = await PhoneDelivery.run(outbox.pending) { _ in .notReached }
        XCTAssertEqual(away.notReached, ids, "away from home: nothing reached the Mac")
        XCTAssertNil(away.status)
        outbox.unsend(away, marked: ids)
        XCTAssertTrue(outbox.withdraw(ids[0]), "so Undo last takes it back, as before the send")
        XCTAssertEqual(outbox.ready().map(\.id), [ids[1], ids[2]], "and the rest go at the next look")
        let back = try JSONDecoder().decode(PhoneOutbox.self, from: try JSONEncoder().encode(outbox))
        XCTAssertNil(back.pending.first?.sentAt, "saved as not sent")

        (outbox, ids) = three()
        let unanswered = await PhoneDelivery.run(outbox.pending) { _ in .unsure }
        XCTAssertEqual(unanswered.notReached, [], "the post went out: the Mac may have them")
        XCTAssertFalse(outbox.withdraw(ids[0]))

        let taken = await PhoneDelivery.run(outbox.pending) { _ in .answered(202) }
        XCTAssertEqual(taken, PhoneDelivery(status: 202))

        var batches: [[String]] = []
        let stopped = await PhoneDelivery.run(outbox.pending) { edits in
            batches.append(edits.edits.map(\.id))
            switch batches.count {
            case 1: return .answered(400)  // one of them the Mac can't read: one at a time
            case 2: return .answered(202)
            default: return .notReached  // the Mac went off in the middle
            }
        }
        XCTAssertEqual(batches, [ids, [ids[0]], [ids[1]]], "nothing more is sent once one doesn't reach the Mac")
        XCTAssertEqual(stopped.notReached, [ids[1], ids[2]], "that one, and the one never sent")
        XCTAssertEqual(stopped.unreadable, [])

        batches = []
        let busy = await PhoneDelivery.run(outbox.pending) { edits in
            batches.append(edits.edits.map(\.id))
            return batches.count == 1 ? .answered(413) : batches.count == 2 ? .answered(400) : .answered(503)
        }
        XCTAssertEqual(busy.unreadable, [ids[0]], "a 400 alone: a kind the Mac doesn't read")
        XCTAssertEqual(busy.tooLong, [])
        XCTAssertEqual(busy.notReached, [ids[1], ids[2]],
                       "the Mac's inbox full (503) didn't take it; the one left out was never sent")
        XCTAssertEqual(busy.status, 413)
        let full = await PhoneDelivery.run(outbox.pending) { _ in .answered(503) }
        XCTAssertEqual(full, PhoneDelivery(status: 503, notReached: ids), "503: the Mac took none of them")

        let noAnswer = await PhoneDelivery.run(outbox.pending) { edits in
            edits.edits.count == 3 ? .answered(400) : .unsure
        }
        XCTAssertEqual(noAnswer.notReached, [ids[1], ids[2]], "the first went out unanswered; the rest never went")

        let readOnly = await PhoneDelivery.run(outbox.pending) { _ in .answered(403) }
        XCTAssertEqual(readOnly.readOnly, ids)
        let one = await PhoneDelivery.run(Array(outbox.pending.prefix(1))) { _ in .answered(400) }
        XCTAssertEqual(one.unreadable, [ids[0]], "one alone the Mac can't read is refused at once")
        let long = await PhoneDelivery.run(Array(outbox.pending.prefix(1))) { _ in .answered(413) }
        XCTAssertEqual(long, PhoneDelivery(status: 413, tooLong: [ids[0]]), "too long is told apart from an older Mac")
        batches = []
        let mixed = await PhoneDelivery.run(outbox.pending) { edits in
            batches.append(edits.edits.map(\.id))
            return batches.count == 1 ? .answered(400) : batches.count == 2 ? .answered(413) : .answered(202)
        }
        XCTAssertEqual(mixed.tooLong, [ids[0]])
        XCTAssertEqual(mixed.unreadable, [], "one at a time: each answer goes to its own list")
        let forgotten = await PhoneDelivery.run(outbox.pending) { _ in .answered(401) }
        XCTAssertEqual(forgotten, PhoneDelivery(status: 401))

        // the whole-plan review: the Mac forgot this phone between the batch (400) and the one-at-a-time sends: the
        // first 401 stops them and is the status, so the phone is forgotten as after a batch's 401
        batches = []
        let removed = await PhoneDelivery.run(outbox.pending) { edits in
            batches.append(edits.edits.map(\.id))
            return batches.count == 1 ? .answered(400) : .answered(401)
        }
        XCTAssertEqual(batches, [ids, [ids[0]]], "nothing more is posted to a Mac that no longer knows this phone")
        XCTAssertEqual(removed, PhoneDelivery(status: 401, notReached: [ids[1], ids[2]]),
                       "the 401 kept as sent, as a batch's is; the ones never sent wait as never sent")
    }

    /// Re-review of checkpoint 2: a change an earlier look delivered (202), not yet settled, is sent again with the
    /// next look's; when that look never reaches the Mac, only the changes it marked sent itself go back to unsent, so Undo
    /// last never withdraws one the Mac already has (it would be applied, and the phone would say it was taken back).
    func testALaterSendThatNeverArrivesLeavesAnEarlierDeliveredChangeSent() async throws {
        let jugs = item("Drinking water jugs").id
        var outbox = PhoneOutbox()
        let a = outbox.add(.adjust(row: jugs, by: 1), what: "Drinking water jugs: 1 more")
        XCTAssertEqual(outbox.markSent(outbox.ready().map(\.id)), [a])
        let first = await PhoneDelivery.run(outbox.ready()) { _ in .answered(202) }
        outbox.unsend(first, marked: [a])
        let b = outbox.add(.adjust(row: jugs, by: 1), what: "Drinking water jugs: 1 more")
        let sent = outbox.ready()
        XCTAssertEqual(sent.map(\.id), [a, b], "A waits for the Mac's answer, and goes again with B")
        let marked = outbox.markSent(sent.map(\.id))
        XCTAssertEqual(marked, [b], "only B was marked by this look")
        let away = await PhoneDelivery.run(sent) { _ in .notReached }
        XCTAssertEqual(away.notReached, [a, b])
        outbox.unsend(away, marked: marked)
        XCTAssertFalse(outbox.withdraw(a), "A reached the Mac on the first look: never taken back")
        XCTAssertTrue(outbox.withdraw(b), "B never reached it: taken back")
    }

    /// Whether an unanswered post may have reached the Mac: only when some of it went out (URLSession's count of the
    /// body's bytes sent is 0 for a Mac that can't be reached, a refused connection or a certificate refused, and the
    /// whole body for a post that went out and got no answer: measured on this Mac, checkpoint 2). Of the Mac's two
    /// addresses, an answer counts first, then a post that went out.
    func testAnUnansweredPostMayHaveArrivedOnlyWhenItWentOut() {
        XCTAssertEqual(PhoneSend.unanswered(bodyBytesSent: 0), .notReached)
        XCTAssertEqual(PhoneSend.unanswered(bodyBytesSent: 300), .unsure)
        XCTAssertEqual(PhoneSend.first([.notReached, .unsure]), .unsure)
        XCTAssertEqual(PhoneSend.first([.unsure, .notReached]), .unsure)
        XCTAssertEqual(PhoneSend.first([.notReached, .notReached]), .notReached)
        XCTAssertEqual(PhoneSend.first([]), .notReached, "not paired: nothing sent")
    }

    /// The mark on a phone's change: only when set, so an older Mac's reader reads it as before (it ignores a key it
    /// doesn't know), and a phone's change without it reads with none.
    func testTheCorrectionMarkIsReadByAnOlderMacAsBefore() throws {
        let marked = PhoneEdit(change: .adjust(row: 3, by: 1), at: "2026-10-20T10:00:00Z", correction: true)
        let data = try JSONEncoder().encode(PhoneEdits(edits: [marked]))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"correction\":true"))
        struct OlderEdit: Decodable { let id: String; let change: InventoryChange; let at: String? }
        struct OlderEdits: Decodable { let edits: [OlderEdit] }
        let older = try JSONDecoder().decode(OlderEdits.self, from: data)
        XCTAssertEqual(older.edits.map(\.id), [marked.id], "an older Mac's shape reads it, the mark ignored")
        XCTAssertEqual(older.edits.first?.change, .adjust(row: 3, by: 1))
        var withUnknown = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var edits = withUnknown["edits"] as! [[String: Any]]
        edits[0]["a_key_from_a_newer_phone"] = 1
        withUnknown["edits"] = edits
        XCTAssertEqual(PhoneEdits.read(try JSONSerialization.data(withJSONObject: withUnknown))?.edits, [marked],
                       "PhoneEdits.read ignores a key it doesn't know")
        let plain = try JSONEncoder().encode(PhoneEdit(change: .adjust(row: 3, by: 1)))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("correction"), "unmarked: no key at all")
        XCTAssertNil(try JSONDecoder().decode(PhoneEdit.self, from: plain).correction)
    }

    /// With VoiceOver on, the Undo shows longer: it takes longer to reach.
    func testVoiceOverGetsALongerUndo() {
        XCTAssertEqual(PhoneOutbox.undoForVoiceOver, 15)
        let jugs = item("Drinking water jugs").id
        let tapped = Date()
        var outbox = PhoneOutbox()
        let id = outbox.add(.adjust(row: jugs, by: -1), what: "used 1", now: tapped, withUndo: true,
                            holdFor: PhoneOutbox.undoForVoiceOver)
        XCTAssertEqual(outbox.undoable(row: jugs, now: tapped.addingTimeInterval(14))?.id, id)
        XCTAssertEqual(outbox.ready(now: tapped.addingTimeInterval(14)), [])
        XCTAssertEqual(outbox.ready(now: tapped.addingTimeInterval(16)).map(\.id), [id])
    }

    /// A phone's outbox from before this build (no Undo in it) still sends, and the Mac applies it as before.
    func testAnOutboxFromBeforeUndoStillSendsAndIsApplied() async throws {
        let jugs = item("Drinking water jugs").id
        var made = PhoneOutbox()
        made.add(.adjust(row: jugs, by: -1), what: "Drinking water jugs: used 1")
        let older = try JSONEncoder().encode(made)
        XCTAssertFalse(String(decoding: older, as: UTF8.self).contains("hold"), "the older shape: no hold in it")
        let outbox = try JSONDecoder().decode(PhoneOutbox.self, from: older)
        XCTAssertEqual(outbox.ready().map(\.id), made.pending.map(\.id), "ready at once")
        XCTAssertNil(outbox.undoable(row: jugs, now: Date()), "and no Undo for it")
        try send(outbox.ready().map(\.edit), name: "2026-10-20T10-00-01-phone1-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(quantity("Drinking water jugs"), .text("5"))
    }

    // MARK: offline fixes, task 1.1: a waiting-changes file that can't be read is never taken for an empty one

    func testAnOutboxFileThatCantBeReadThrows() throws {
        let url = base.appendingPathComponent("inventory-outbox.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try PhoneOutbox.read(url)) { XCTAssertEqual($0 as? PhoneOutbox.Problem, .unreadable) }
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8), "the file is left as it was")
    }

    func testNoOutboxFileReadsEmpty() throws {
        XCTAssertEqual(try PhoneOutbox.read(base.appendingPathComponent("inventory-outbox.json")), PhoneOutbox())
    }

    /// Valid JSON that can't be decoded (review focus 2): Swift ignores an unknown field, so a wrong-typed one.
    func testAnOutboxWithAWrongTypedFieldThrows() throws {
        let url = base.appendingPathComponent("inventory-outbox.json")
        try Data(#"{"pending": "water", "refused": []}"#.utf8).write(to: url)
        XCTAssertThrowsError(try PhoneOutbox.read(url))
    }

    func testAnOutboxWrittenReadsBack() throws {
        let url = base.appendingPathComponent("inventory-outbox.json")
        var outbox = PhoneOutbox()
        outbox.add(.adjust(row: 1, by: -1), what: "Water: used 1")
        try outbox.write(url)
        XCTAssertEqual(try PhoneOutbox.read(url), outbox)
    }

    /// The file read at last (after the phone's first unlock, say): its changes come first, then those made since,
    /// each once.
    func testAnOutboxReadLateTakesInTheChangesMadeSince() {
        var kept = PhoneOutbox(), since = PhoneOutbox()
        let a = kept.add(.adjust(row: 1, by: -1), what: "Water: used 1")
        since.pending.append(kept.pending[0])
        let b = since.add(.adjust(row: 2, by: 1), what: "Rice: 1 more")
        since.refuse([b], message: "No.")
        let c = since.add(.adjust(row: 3, by: 1), what: "Beans: 1 more")
        kept.takeIn(since)
        XCTAssertEqual(kept.pending.map(\.id), [a, c])
        XCTAssertEqual(kept.refused.map(\.id), [b])
    }

    // MARK: offline fixes, task 1.3: a change the Mac answered past its 60 days of answers settles

    func testAChangeSentOver61DaysAgoWithNoAnswerSettles() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var outbox = PhoneOutbox()
        let old = outbox.add(.adjust(row: 1, by: -1), what: "Water: used 1", now: now)
        outbox.markSent([old], now: now.addingTimeInterval(-62 * 86_400))
        let recent = outbox.add(.adjust(row: 2, by: -1), what: "Rice: used 1", now: now)
        outbox.markSent([recent], now: now.addingTimeInterval(-60 * 86_400))
        let unsent = outbox.add(.adjust(row: 3, by: -1), what: "Beans: used 1", now: now.addingTimeInterval(-90 * 86_400))
        let copy = PhoneInventory(writtenAt: "", columns: [], items: [], places: [], categories: [], headsUpDays: 60,
                                  toBuy: [], results: [:])
        outbox.settle(with: copy, now: now)
        XCTAssertEqual(outbox.pending.map(\.id), [recent, unsent], "never sent: it still waits to go")
        XCTAssertEqual(outbox.refused, [])
    }

    // MARK: offline fixes, task 3.1: the Mac's service has a change, but PrepareMe on the Mac isn't applying it

    func testAChangeTakenButNotAppliedIsCounted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func copy(_ written: Date) -> PhoneInventory {
            PhoneInventory(writtenAt: ISO8601DateFormatter().string(from: written), columns: [], items: [], places: [],
                           categories: [], headsUpDays: 60, toBuy: [], results: [:])
        }
        var outbox = PhoneOutbox()
        let id = outbox.add(.adjust(row: 1, by: -1), what: "Water: used 1", now: now.addingTimeInterval(-180))
        let old = copy(now.addingTimeInterval(-3600))
        XCTAssertEqual(outbox.takenUnapplied(copy: old, lookedAt: now), 0, "never sent")
        outbox.markSent([id], now: now.addingTimeInterval(-180))
        XCTAssertEqual(outbox.takenUnapplied(copy: old, lookedAt: now), 1, "taken 3 minutes ago, no copy since")
        XCTAssertEqual(outbox.takenUnapplied(copy: old, lookedAt: now.addingTimeInterval(-90)), 0,
                       "no look over 2 minutes after the send")
        XCTAssertEqual(outbox.takenUnapplied(copy: copy(now.addingTimeInterval(-270)), lookedAt: now), 0,
                       "a copy 90 seconds before the send: within the clocks' slack")
        XCTAssertEqual(outbox.takenUnapplied(copy: copy(now.addingTimeInterval(-170)), lookedAt: now), 0,
                       "a copy written since the send: the app is running")
        XCTAssertEqual(outbox.takenUnapplied(copy: nil, lookedAt: now), 0)
        XCTAssertEqual(outbox.takenUnapplied(copy: old, lookedAt: nil), 0)
    }

    // MARK: offline fixes, task 1.4: a Mac set up from an older file refuses a change made from a newer one

    /// The stretches of time this file's Mac wrote the phones' copy: one per run of the app, its end kept within
    /// `copyRecordEvery`, so a copy a phone saw within `copySlack` of a run's recorded end is still this file's.
    func testTheCopiesThisFileWroteAreKnown() throws {
        let file = editor.file
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func minutes(_ n: Double) -> Date { t.addingTimeInterval(n * 60) }
        XCTAssertFalse(try file.copyUnknown(minutes(0)), "no copy recorded yet: nothing refused")
        try file.recordCopyWritten(minutes(0), newRun: true)
        try file.recordCopyWritten(minutes(20), newRun: false)  // within copyRecordEvery: not written
        try file.recordCopyWritten(minutes(40), newRun: false)
        XCTAssertFalse(try file.copyUnknown(minutes(30)))
        XCTAssertFalse(try file.copyUnknown(minutes(95)), "within the slack after the recorded end")
        XCTAssertTrue(try file.copyUnknown(minutes(120)), "written by a Mac this file never was")
        XCTAssertFalse(try file.copyUnknown(minutes(-60)), "older than any recorded: from before the record began")
        try file.recordCopyWritten(minutes(300), newRun: true)
        XCTAssertFalse(try file.copyUnknown(minutes(300)))
        XCTAssertTrue(try file.copyUnknown(minutes(180)), "between two runs: a gap no copy of this file's is in")
    }

    /// The restored-Mac case: the file's last copy at T; a phone's change made from a copy written a day later (by the
    /// Mac this file is an older backup of) is refused, one from an hour before applies, and one with no copy applies.
    func testAPhoneChangeSeenAfterTheNewestCopyIsRefused() async throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try editor.file.recordCopyWritten(t.addingTimeInterval(-2 * 3600), newRun: true)
        try editor.file.recordCopyWritten(t, newRun: false)
        let stamp = ISO8601DateFormatter()
        let jugs = item("Drinking water jugs").id
        var outbox = PhoneOutbox()
        let newer = outbox.add(.adjust(row: jugs, by: -1), what: "a", seen: stamp.string(from: t.addingTimeInterval(86_400)))
        let older = outbox.add(.adjust(row: jugs, by: -1), what: "b", seen: stamp.string(from: t.addingTimeInterval(-3600)))
        let none = outbox.add(.adjust(row: jugs, by: -1), what: "c")
        let before = InventoryValues.parseNumber(InventoryValues.plain(quantity("Drinking water jugs")))!
        try send(outbox.pending.map(\.edit), name: "2026-10-23T10-00-01-phone1-a.json")
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(try editor.file.phoneEditResult(newer)?.refused, InventoryWords.restoredSince)
        XCTAssertNil(try editor.file.phoneEditResult(older)?.refused)
        XCTAssertNil(try editor.file.phoneEditResult(none)?.refused)
        XCTAssertEqual(InventoryValues.parseNumber(InventoryValues.plain(quantity("Drinking water jugs"))), before - 2)
        XCTAssertEqual(InventoryWords.restoredSince,
                       "The Mac was set up from an older copy of the inventory, so this change wasn't kept. Look at the "
                           + "item and change it again if you still need to.")
    }
}
