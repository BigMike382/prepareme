import Foundation
@testable import PrepareMeShared
import XCTest

/// The street map's rally points and routes (plan phase 9): kept in the inventory file's own table through the editor
/// (its ID check on each name and note, its undo), copied whole to every phone; an adult's phone may delete one or
/// change its name or note (2026-11-12), never where it is. Made-up
/// rehearsal document copies and made-up places (open ocean) only.
@MainActor
final class MapMarksTests: XCTestCase {
    var base: URL!
    var check: FakeCheck!
    var editor: InventoryEditor!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-marks-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        check = FakeCheck()
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: check)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    let point = MapMark(kind: .rally, name: "Meet at the big oak", note: "If the bridge is out, wait here.",
                        points: [[-40.123456789, 10.987654321]])
    let route = MapMark(kind: .route, name: "Way out north", points: [[-40.1, 10.9], [-40.2, 11.0], [-40.3, 11.2]])

    func testARallyPointIsCheckedKeptAndUndone() async throws {
        let outcome = try await editor.apply(.addMark(point))
        guard case .done(let undo, let id) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(check.asked.last?.place, "Map, a meeting place")
        XCTAssertEqual(check.asked.last?.cells.map(\.text), ["Meet at the big oak", "If the bridge is out, wait here."])
        XCTAssertNotNil(check.files.last, "checked on a whole copy of the file, as every change is")
        let kept = try XCTUnwrap(editor.inventory.marks.first)
        XCTAssertEqual(kept.id, id)
        XCTAssertEqual(kept.points, [[-40.123457, 10.987654]], "kept to 6 decimal places")
        _ = try await editor.apply(undo)
        XCTAssertEqual(editor.inventory.marks, [])
    }

    func testANameTheIDCheckRefusesIsNeverKept() async throws {
        var bad = point
        bad.note = "REFUSE"
        guard case .refused = try await editor.apply(.addMark(bad)) else { return XCTFail("kept") }
        XCTAssertEqual(try editor.file.marks(), [])
    }

    func testShapesThatArentAPointOrARouteAreRefusedInFixedWords() async throws {
        var noName = point
        noName.name = "  "
        var twoPlaces = point
        twoPlaces.points.append([-40, 10])
        var shortRoute = route
        shortRoute.points = [[-40, 10]]
        var offMap = point
        offMap.points = [[-40, 89]]
        var notANumber = point
        notANumber.points = [[.nan, 10]]
        let cases: [(MapMark, String)] = [(noName, MapMarkWords.noName), (twoPlaces, MapMarkWords.onePoint),
                                          (shortRoute, MapMarkWords.twoPoints), (offMap, MapMarkWords.offTheMap),
                                          (notANumber, MapMarkWords.offTheMap)]
        for (mark, words) in cases {
            let outcome = try await editor.apply(.addMark(mark))
            XCTAssertEqual(outcome, .refused(words))
        }
        XCTAssertEqual(check.calls, 0, "refused before the check")
    }

    func testAChangeAndARemoveHappenOnlyWhileTheMarkIsAsSeenAndBothUndo() async throws {
        guard case .done(_, let id) = try await editor.apply(.addMark(route)) else { return XCTFail() }
        let seen = try XCTUnwrap(editor.inventory.marks.first)
        var moved = seen
        moved.points.append([-40.4, 11.3])
        guard case .done(let undoMove, _) = try await editor.apply(.changeMark(moved, expected: seen)) else {
            return XCTFail()
        }
        XCTAssertEqual(editor.inventory.marks.first?.points.count, 4)
        let again = try await editor.apply(.changeMark(moved, expected: seen))
        XCTAssertEqual(again, .refused(InventoryWords.changedSince))
        _ = try await editor.apply(undoMove)
        XCTAssertEqual(editor.inventory.marks.first, seen)
        let stale = try await editor.apply(.removeMark(id: id, expected: moved))
        XCTAssertEqual(stale, .refused(InventoryWords.changedSince))
        guard case .done(let undoRemove, _) = try await editor.apply(.removeMark(id: id, expected: seen)) else {
            return XCTFail()
        }
        XCTAssertEqual(editor.inventory.marks, [])
        _ = try await editor.apply(undoRemove)
        XCTAssertEqual(editor.inventory.marks, [seen], "put back at its own id")
    }

    func testEveryPhoneGetsEveryMarkAndNoPhoneMayMoveOneOrAddARoute() async throws {
        _ = try await editor.apply(.addMark(point))
        _ = try await editor.apply(.addMark(route))
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertEqual(copy.marks?.map(\.name), ["Meet at the big oak", "Way out north"])
        let sent = try JSONDecoder().decode(PhoneInventory.self, from: JSONEncoder().encode(copy))
        XCTAssertEqual(sent.marks, copy.marks)
        XCTAssertEqual(PhoneOutbox().view(sent).marks, copy.marks)
        var moved = route
        moved.points.removeLast()
        // an adult's phone adds a rally point since 2026-11-12 (SharedMarksTests); a route and a move stay the Mac's
        for change: InventoryChange in [.addMark(route), .changeMark(moved, expected: route), .putBackMark(point)] {
            XCTAssertEqual(PhoneRules.refusal(change, editor.inventory), PhoneRules.notFromAPhone)
        }
    }

    /// An adult's phone deletes rally points and routes from Select (owner, 2026-11-12, by click: everywhere, through
    /// the Mac): gone from that phone at once, then from the Mac at its next check, kept for the Mac's Put back. Never
    /// the Start point; one the Mac changed since the phone saw it is refused, never deleted.
    func testAPhonesDeleteLeavesTheMacAndIsKeptForPutBack() async throws {
        _ = try await editor.apply(.addMark(point))
        _ = try await editor.apply(.addMark(route))
        let start = MapMark(kind: .start, name: "Start", points: [[-40.5, 10.5]])
        _ = try await editor.apply(.addMark(start))
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        let oak = try XCTUnwrap(copy.marks?.first { $0.kind == .rally })
        let north = try XCTUnwrap(copy.marks?.first { $0.kind == .route })
        XCTAssertNil(copy.start, "Mac only since the map pins plan")
        let home = try XCTUnwrap(editor.inventory.marks.first { $0.kind == .start })  // an older phone may hold it
        XCTAssertEqual(PhoneRules.refusal(.removeMark(id: home.id, expected: home), editor.inventory),
                       PhoneRules.notFromAPhone, "never the Start point")
        XCTAssertNil(PhoneRules.refusal(.removeMark(id: 99, expected: oak), editor.inventory))
        var phone = PhoneOutbox()
        phone.add(.removeMark(id: oak.id, expected: oak), what: "Delete: \(oak.name)")
        phone.add(.removeMark(id: north.id, expected: north), what: "Delete: \(north.name)")
        XCTAssertEqual(phone.view(copy).marks, [], "gone from this phone while it waits")
        XCTAssertNil(phone.view(copy).start, "the Start point is Mac only")
        // the Mac renames the route meanwhile: that delete is refused, the rally point's goes through
        var renamed = north
        renamed.name = "Way out north, by the creek"
        _ = try await editor.apply(.changeMark(renamed, expected: north))
        let inbox = base.appendingPathComponent(PhoneInbox.inboxName)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try JSONEncoder().encode(PhoneEdits(edits: phone.pending.map(\.edit)))
            .write(to: inbox.appendingPathComponent("2026-11-12T10-00-01-phone1-a.json"))
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(editor.inventory.marks.map(\.name), ["Way out north, by the creek", "Start"])
        let results = try editor.file.phoneEditResults(since: .distantPast)
        XCTAssertNil(results[phone.pending[0].id]?.refused)
        XCTAssertEqual(results[phone.pending[1].id]?.refused, InventoryWords.changedSince)
        XCTAssertEqual(editor.inventory.deletedMarks.map(\.mark), [oak], "kept for Put back; the refused one isn't")
        // a second phone deletes the same one: done, nothing changed, kept once
        let second = PhoneEdit(change: .removeMark(id: oak.id, expected: oak))
        try JSONEncoder().encode(PhoneEdits(edits: [second]))
            .write(to: inbox.appendingPathComponent("2026-11-12T10-00-02-phone2-b.json"))
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertNil(try editor.file.phoneEditResults(since: .distantPast)[second.id]?.refused)
        XCTAssertEqual(editor.inventory.marks.count, 2)
        XCTAssertEqual(editor.inventory.deletedMarks.count, 1)
        let macOwn = try await editor.apply(.removeMark(id: oak.id, expected: oak))
        XCTAssertEqual(macOwn, .refused(InventoryWords.noRow), "the Mac's own (an Undo of an add) still says it's gone")
        // the Mac's panel lists it until it is back on the map; Put back takes its own id while that is free
        let shown = DeletedMark.shown(editor.inventory.deletedMarks, marks: editor.inventory.marks)
        XCTAssertEqual(shown.map(\.mark), [oak])
        XCTAssertEqual(shown[0].putBack(among: editor.inventory.marks), .putBackMark(oak))
        guard case .done(let undo, _) = try await editor.apply(shown[0].putBack(among: editor.inventory.marks)) else {
            return XCTFail()
        }
        XCTAssertEqual(editor.inventory.marks.first, oak)
        XCTAssertEqual(DeletedMark.shown(editor.inventory.deletedMarks, marks: editor.inventory.marks), [])
        _ = try await editor.apply(undo)
        XCTAssertEqual(DeletedMark.shown(editor.inventory.deletedMarks, marks: editor.inventory.marks).map(\.mark), [oak],
                       "Edit › Undo of Put back lists it again")
        XCTAssertEqual(DeletedMark.shown(editor.inventory.deletedMarks, marks: editor.inventory.marks,
                                         now: Date().addingTimeInterval(DeletedMark.keptFor + 60)), [],
                       "listed 30 days only")
    }

    func testAPhonesRenameAndNoteReachTheMacButNeverAMove() async throws {
        _ = try await editor.apply(.addMark(point))
        _ = try await editor.apply(.addMark(route))
        _ = try await editor.apply(.addMark(MapMark(kind: .start, name: "Start", points: [[-40.5, 10.5]])))
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        let oak = try XCTUnwrap(copy.marks?.first { $0.kind == .rally })
        let north = try XCTUnwrap(copy.marks?.first { $0.kind == .route })
        XCTAssertNil(copy.start, "Mac only since the map pins plan")
        let home = try XCTUnwrap(editor.inventory.marks.first { $0.kind == .start })  // an older phone may hold it
        var moved = oak
        moved.points = [[-40.2, 10.2]]
        XCTAssertEqual(PhoneRules.refusal(.changeMark(moved, expected: oak), editor.inventory), PhoneRules.notFromAPhone)
        var role = oak
        role.role = .nearHome  // a role too, since 2026-11-12 (the shared marks plan)
        XCTAssertNil(PhoneRules.refusal(.changeMark(role, expected: oak), editor.inventory))
        var renamed = oak, homeNote = home, northNote = north
        renamed.name = "Big oak at the park"
        homeNote.note = "Back door"
        northNote.note = "Mind the creek"
        for change in [InventoryChange.changeMark(renamed, expected: oak), .changeMark(homeNote, expected: home),
                       .changeMark(northNote, expected: north)] {
            XCTAssertNil(PhoneRules.refusal(change, editor.inventory), "a name or note, the Start's too")
        }
        var phone = PhoneOutbox()
        phone.add(.changeMark(renamed, expected: oak), what: MapMarkWords.changed(renamed.name))
        phone.add(.changeMark(homeNote, expected: home), what: MapMarkWords.changed(home.name))
        phone.add(.changeMark(northNote, expected: north), what: MapMarkWords.changed(north.name))
        XCTAssertEqual(phone.view(copy).mapMarks.map(\.name), ["Big oak at the park", "Way out north"])
        XCTAssertNil(phone.view(copy).start, "never shown on a phone, even while its note waits")
        // the Mac changes the route's role meanwhile: that note is refused, the other two go through
        var main = north
        main.routeRole = .main
        _ = try await editor.apply(.changeMark(main, expected: north))
        let inbox = base.appendingPathComponent(PhoneInbox.inboxName)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try JSONEncoder().encode(PhoneEdits(edits: phone.pending.map(\.edit)))
            .write(to: inbox.appendingPathComponent("2026-11-12T11-00-01-phone1-a.json"))
        try await PhoneInbox.process(folder: base, editor: editor)
        XCTAssertEqual(editor.inventory.marks.map(\.name), ["Big oak at the park", "Way out north", "Start"])
        XCTAssertEqual(editor.inventory.marks.map(\.note), [oak.note, "", "Back door"])
        let results = try editor.file.phoneEditResults(since: .distantPast)
        XCTAssertNil(results[phone.pending[0].id]?.refused)
        XCTAssertNil(results[phone.pending[1].id]?.refused)
        XCTAssertEqual(results[phone.pending[2].id]?.refused, InventoryWords.changedSince)
        XCTAssertEqual(check.asked.last?.cells.map(\.text), ["Start", "Back door"], "the Mac's ID check, as its own")
    }

    func testPutBackTakesANewIdWhenItsOwnWasUsedAgain() {
        var gone = point
        gone.id = 3
        var other = route
        other.id = 3
        let deleted = DeletedMark(mark: gone, at: Date())
        guard case .addMark(let fresh) = deleted.putBack(among: [other]) else { return XCTFail() }
        XCTAssertEqual(fresh.id, 0)
        XCTAssertEqual(fresh.name, gone.name)
    }

    func testAPhonesCopyFromBeforeMarksStillReads() throws {
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any])
        json["marks"] = nil
        let older = try JSONDecoder().decode(PhoneInventory.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(older.marks)
    }

    func testTheMapGetsThemAsGeoJSON() throws {
        var kept = point
        kept.id = 1
        var line = route
        line.id = 2
        let found = try XCTUnwrap(JSONSerialization.jsonObject(with: MapMark.geoJSON([kept, line])) as? [String: Any])
        let features = try XCTUnwrap(found["features"] as? [[String: Any]])
        XCTAssertEqual(found["type"] as? String, "FeatureCollection")
        XCTAssertEqual(features.compactMap { ($0["geometry"] as? [String: Any])?["type"] as? String },
                       ["Point", "LineString"])
        XCTAssertEqual((features[0]["properties"] as? [String: Any])?["name"] as? String, "Meet at the big oak")
    }

    /// Roles (owner, 2026-10-14): kept and undone with the mark, refused on a route, and a table made before roles
    /// reads as before and gains the column at its next write.
    func testARallyPointsRoleIsKeptAndAnOlderTableStillReads() async throws {
        try editor.file.db.execute("""
            CREATE TABLE "PrepareMe_MapMarks" (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, \
            note TEXT NOT NULL, points TEXT NOT NULL)
            """)
        try editor.file.db.execute("INSERT INTO \"PrepareMe_MapMarks\" VALUES (1, 'rally', 'Old one', '', '[[-40,10]]')")
        XCTAssertEqual(try editor.file.marks().map(\.role), [nil])
        var away = point
        away.role = .outOfTown
        guard case .done = try await editor.apply(.addMark(away)) else { return XCTFail() }
        XCTAssertEqual(try editor.file.marks().map(\.role), [nil, .outOfTown])
        let seen = try XCTUnwrap(try editor.file.marks().last)
        var near = seen
        near.role = .nearHome
        guard case .done(let undo, _) = try await editor.apply(.changeMark(near, expected: seen)) else { return XCTFail() }
        XCTAssertEqual(try editor.file.marks().last?.role, .nearHome)
        _ = try await editor.apply(undo)
        XCTAssertEqual(try editor.file.marks().last?.role, .outOfTown)
        var routeWithRole = route
        routeWithRole.role = .nearHome
        let refused = try await editor.apply(.addMark(routeWithRole))
        XCTAssertEqual(refused, .refused(MapMarkWords.routeRole))

        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any])
        json["marks"] = [["id": 1, "kind": "rally", "name": "Older copy", "note": "", "points": [[-40, 10]]]]
        let older = try JSONDecoder().decode(PhoneInventory.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(older.marks?.first?.role, nil, "a phone's copy from before roles")
        let features = try XCTUnwrap((JSONSerialization.jsonObject(with: MapMark.geoJSON([away, route])) as? [String: Any])?["features"] as? [[String: Any]])
        XCTAssertEqual((features[0]["properties"] as? [String: Any])?["role"] as? String, "Out of town")
        XCTAssertEqual((features[1]["properties"] as? [String: Any])?["end"] as? [Double], [-40.3, 11.2])
    }

    /// A route's part (the street map fixes plan, task 2.1): main or alternate, kept and undone like a rally point's
    /// role, in the same column; refused on a rally point; and carried to the phones under its own name, so a phone
    /// still on an older PrepareMe, which knows only the rally roles, reads its whole copy as before.
    func testRouteRolesRoundTripThroughTheTable() async throws {
        var main = route
        main.routeRole = .main
        guard case .done = try await editor.apply(.addMark(main)) else { return XCTFail() }
        let seen = try XCTUnwrap(try editor.file.marks().last)
        XCTAssertEqual(seen.routeRole, .main)
        XCTAssertNil(seen.role)
        var alternate = seen
        alternate.routeRole = .alternate
        guard case .done(let undo, _) = try await editor.apply(.changeMark(alternate, expected: seen)) else {
            return XCTFail()
        }
        XCTAssertEqual(try editor.file.marks().last?.routeRole, .alternate)
        _ = try await editor.apply(undo)
        XCTAssertEqual(try editor.file.marks().last?.routeRole, .main)
        var rallyWithRouteRole = point
        rallyWithRouteRole.routeRole = .main
        let refused = try await editor.apply(.addMark(rallyWithRouteRole))
        XCTAssertEqual(refused, .refused(MapMarkWords.rallyRouteRole))

        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any])
        let sent = try XCTUnwrap((json["marks"] as? [[String: Any]])?.last)
        XCTAssertNil(sent["role"], "an older phone fails to read its whole copy on a role it doesn't know")
        XCTAssertEqual(sent["routeRole"] as? String, "main-route")
        let features = try XCTUnwrap((JSONSerialization.jsonObject(with: MapMark.geoJSON([alternate])) as? [String: Any])?["features"] as? [[String: Any]])
        XCTAssertEqual((features[0]["properties"] as? [String: Any])?["route"] as? String, "alternate-route",
                       "the map draws the alternate dashed")
    }

    // MARK: The map pins plan (2026-11-14): one gray line per row, and a mark known before the Mac has it

    func testARowsGrayLine() {
        let oak = MapMark(id: 1, kind: .rally, name: "Oak", points: [[0, 0]], role: .nearHome)
        XCTAssertEqual(MapMarkWords.rowLine(oak, waiting: true, kidsTarget: true, added: "Added"), MapMarkWords.waiting)
        XCTAssertEqual(MapMarkWords.rowLine(oak, waiting: false, kidsTarget: true, added: nil),
                       "Near home. The kids' phones point here")
        let church = MapMark(id: 2, kind: .rally, name: "Church", points: [[0, 0]])
        XCTAssertEqual(MapMarkWords.rowLine(church, waiting: false, kidsTarget: false, added: nil), "Another place to meet")
        let main = MapMark(id: 3, kind: .route, name: "Out", points: [[0, 0], [1, 1]], routeRole: .main)
        XCTAssertEqual(MapMarkWords.rowLine(main, waiting: false, kidsTarget: false, added: nil), "Main route")
        let pin = MapMark(id: 4, kind: .pin, name: "Tap", points: [[0, 0]])
        XCTAssertEqual(MapMarkWords.rowLine(pin, waiting: false, kidsTarget: false, added: "Added Nov 12 on the Mac"),
                       "Added Nov 12 on the Mac")
        XCTAssertNil(MapMarkWords.rowLine(pin, waiting: false, kidsTarget: false, added: nil), "no record of who added it")
    }

    func testAPinWaitingForTheMacIsTheSameMarkOnceItHasARow() {
        var waiting = MapMark(id: -1, kind: .pin, name: "Car", points: [[0, 0]])
        waiting.uid = "abc"
        var saved = MapMark(id: 12, kind: .pin, name: "Car", points: [[0, 0]])
        saved.uid = "abc"
        XCTAssertTrue(waiting.sameMark(saved))
        let a = MapMark(id: 5, kind: .rally, name: "A", points: [[0, 0]])
        XCTAssertTrue(a.sameMark(MapMark(id: 5, kind: .rally, name: "A renamed", points: [[0, 0]])))
        XCTAssertFalse(a.sameMark(MapMark(id: 6, kind: .rally, name: "A", points: [[0, 0]])))
    }

}
