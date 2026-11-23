import Foundation
import Testing
@testable import PrepareMeShared
#if canImport(AppKit)
import AppKit
#endif

/// One shared set of marks (docs/plans/2026-11-12-one-shared-marks.md, phase 1): pins kept in the rally points' own
/// table, reaching phones apart from `marks`; an adult's phone adds and changes them through the Mac, a child's adds
/// pins and removes its own; the same pin arriving twice is kept once, and two phones' changes made apart never lose
/// one silently. Made-up rehearsal copies and made-up places (open ocean) only.
@MainActor
struct SharedMarksTests {
    let base: URL
    let check = FakeCheck()
    let editor: InventoryEditor

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-shared-marks-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: check)
    }

    static let water = PinLook(.water)
    let rally = MapMark(kind: .rally, name: "Meet at the big oak", points: [[-40.1, 10.9]])
    let route = MapMark(kind: .route, name: "Way out north", points: [[-40.1, 10.9], [-40.2, 11.0]])

    static func pin(_ name: String = water.name, at longitude: Double = -40.3) -> MapMark {
        MapMark.pin(PinLook(name: name, symbol: water.symbol, color: water.color), longitude: longitude, latitude: 10.5)
    }

    /// One POST's edits into the inbox, as Router.save names the file, then the Mac's turn.
    func send(_ changes: [InventoryChange], from label: String, child: Bool = false, n: Int) async throws -> [PhoneEdit] {
        let inbox = base.appendingPathComponent(PhoneInbox.inboxName)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let edits = changes.map { PhoneEdit(change: $0) }
        try JSONEncoder().encode(PhoneEdits(edits: edits, child: child ? true : nil))
            .write(to: inbox.appendingPathComponent(String(format: "2026-11-12T10-00-%02d-%@-x.json", n, label)))
        try await PhoneInbox.process(folder: base, editor: editor)
        return edits
    }

    func refusal(_ edit: PhoneEdit) throws -> String? {
        let result = try #require(try editor.file.phoneEditResults(since: .distantPast)[edit.id], "every edit is answered")
        return result.refused
    }

    @Test func aPinIsKeptApartFromTheRallyPointsWithWhoMadeItAndWhen() async throws {
        _ = try await editor.apply(.addMark(rally))
        var sent = Self.pin()
        (sent.made, sent.by) = ("2001-01-01T00:00:00Z", "device:someone-else")  // never taken from the sender
        guard case .done(let undo, let id) = try await editor.apply(.addMark(sent)) else { Issue.record("not kept"); return }
        #expect(check.asked.last?.place == "Map, a pin")
        #expect(editor.inventory.marks.map(\.kind) == [.rally], "never among the rally points and routes")
        let kept = try #require(editor.inventory.pins.first)
        #expect(kept.id == id && kept.uid == sent.uid && kept.by == MapMark.byMac && kept.made != sent.made)
        #expect(kept.symbol == Self.water.symbol, "lists show a pin with its own symbol")
        #expect(try editor.file.mark(id) == kept)
        _ = try await editor.apply(undo)
        #expect(editor.inventory.pins == [])
        #expect(editor.inventory.marks.count == 1)
    }

    @Test func aPinsNameAndNotePassTheIDCheckAndItsShapeIsFixed() async throws {
        var code = Self.pin("Gate")
        code.note = "REFUSE"  // FakeCheck's stand-in for a gate code
        guard case .refused = try await editor.apply(.addMark(code)) else { Issue.record("kept"); return }
        var look = Self.pin()
        look.pinSymbol = "not.a.symbol"
        var color = Self.pin()
        color.pinColor = "#ff0000"
        var role = Self.pin()
        role.role = .nearHome
        var uid = Self.pin()
        uid.uid = "not-a-uuid"
        var flagged = rally
        flagged.pinColor = "accent"
        let cases = [(look, MapMarkWords.pinLook), (color, MapMarkWords.pinLook), (role, MapMarkWords.routeRole),
                     (uid, MapMarkWords.notAMark), (flagged, MapMarkWords.pinLook)]
        for (mark, words) in cases {
            #expect(try await editor.apply(.addMark(mark)) == .refused(words))
        }
        #expect(try editor.file.pins() == [] && editor.file.marks() == [])
    }

    /// Failure 2 of the plan: a phone not yet updated reads the Mac's new copy as before.
    @Test func pinsReachPhonesUnderTheirOwnNameSoAnOlderAppStillReadsItsCopy() async throws {
        struct OlderMark: Decodable {
            enum Kind: String, Decodable { case rally, route, start }
            let id: Int64
            let kind: Kind
            let name: String
        }
        struct OlderCopy: Decodable {
            let marks: [OlderMark]?
            let start: OlderMark?
        }
        _ = try await editor.apply(.addMark(rally))
        _ = try await editor.apply(.addMark(Self.pin()))
        _ = try await editor.apply(.addMark(MapMark(kind: .start, name: "Start", points: [[-40.5, 10.5]])))
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        #expect(copy.pins?.map(\.name) == ["Water"])
        #expect(copy.marks?.contains { $0.kind == .pin } == false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sent = try encoder.encode(copy)
        let older = try JSONDecoder().decode(OlderCopy.self, from: sent)
        #expect(older.marks?.map(\.name) == ["Meet at the big oak"] && older.start == nil, "the Start point is Mac only")
        #expect(try JSONDecoder().decode(PhoneInventory.self, from: sent) == copy)
        // and a copy from a Mac before pins reads as "no pins yet", not as none
        var object = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        object["pins"] = nil
        let before = try JSONDecoder().decode(PhoneInventory.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(before.pins == nil)
    }

    @Test func anAdultsPhoneAddsAPinOrARallyPointAndChangesARoleOrALookButNeverARouteOrAMove() async throws {
        _ = try await editor.apply(.addMark(rally))
        _ = try await editor.apply(.addMark(Self.pin()))
        let oak = try #require(editor.inventory.marks.first), water = try #require(editor.inventory.pins.first)
        var role = oak, look = water, moved = water, kind = water
        role.role = .nearHome
        (look.name, look.pinSymbol, look.pinColor) = ("Cache", "shippingbox.fill", "ok-mark")
        moved.points = [[-40.9, 10.1]]
        kind.kind = .rally
        for change: InventoryChange in [.addMark(Self.pin()), .addMark(rally), .changeMark(role, expected: oak),
                                        .changeMark(look, expected: water), .removeMark(id: water.id, expected: water)] {
            #expect(PhoneRules.refusal(change, editor.inventory) == nil)
        }
        let start = MapMark(kind: .start, name: "Start", points: [[-40.5, 10.5]])
        for change: InventoryChange in [.addMark(route), .addMark(start), .changeMark(moved, expected: water),
                                        .changeMark(kind, expected: water), .putBackMark(water)] {
            #expect(PhoneRules.refusal(change, editor.inventory) == PhoneRules.notFromAPhone)
        }
    }

    /// A pin made away from home has no row yet: it shows on the phone at once, and a rename or a remove made before
    /// the Mac has it finds it by its `uid`.
    @Test func aPinMadeAwayShowsAtOnceAndItsLaterChangesFindItByItsUid() async throws {
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        let made = Self.pin(), gone = Self.pin(at: -40.6)
        var named = made
        named.name = "Spring by the creek"
        var phone = PhoneOutbox()
        phone.add(.addMark(made), what: "Add pin")
        phone.add(.addMark(made), what: "Add pin")  // sent twice: shown once
        phone.add(.changeMark(named, expected: made), what: "Rename")
        phone.add(.addMark(gone), what: "Add pin")
        phone.add(.removeMark(id: 0, expected: gone), what: "Remove")
        let shown = try #require(phone.view(copy).pins)
        #expect(shown.map(\.name) == ["Spring by the creek"])
        #expect(shown[0].id < 0 && shown[0].uid == made.uid, "numbered below 0 while it waits, found by its uid")
        // what the phone sends about it next carries that number, never a row of the Mac's
        var again = shown[0]
        again.note = "Cold, runs all year"
        phone.add(.changeMark(again, expected: shown[0]), what: "Note")
        let edits = try await send(phone.pending.map(\.edit.change), from: "phone1", n: 1)
        for edit in edits { #expect(try refusal(edit) == nil) }
        #expect(editor.inventory.pins.map(\.name) == ["Spring by the creek"])
        let kept = try #require(editor.inventory.pins.first)
        #expect(kept.uid == made.uid && kept.by == "phone1" && kept.made != nil, "who and when, said by the Mac")
        #expect(kept.note == "Cold, runs all year" && kept.id > 0)
        #expect(editor.inventory.deletedMarks.map(\.mark.uid) == [gone.uid], "a phone's delete, kept for Put back")
    }

    /// Failure 1 of the plan: two phones change things apart, and their changes reach the Mac in every order that
    /// keeps each phone's own. Each new pin is there once, the pin both were handed (a shared file) once, and of the
    /// two changes that clash (a rename and a delete of one pin) the first to arrive is kept and the other refused.
    @Test func twoPhonesChangesInEveryOrderLoseNothingSilentlyAndDoubleNothing() async throws {
        let shared = Self.pin("Shelter", at: -40.4), mine = Self.pin("Tree down", at: -40.5)
        let yours = Self.pin("Road flooded", at: -40.6)
        var orders: [[Bool]] = []  // true: phone A's next, false: phone B's
        func walk(_ so: [Bool], _ a: Int, _ b: Int) {
            if a == 0, b == 0 { return orders.append(so) }
            if a > 0 { walk(so + [true], a - 1, b) }
            if b > 0 { walk(so + [false], a, b - 1) }
        }
        walk([], 3, 3)
        #expect(orders.count == 20)
        for order in orders {
            let one = try SharedMarksTests()
            defer { try? FileManager.default.removeItem(at: one.base) }
            _ = try await one.editor.apply(.addMark(Self.pin("Water")))
            let seen = try #require(one.editor.inventory.pins.first)
            var renamed = seen
            renamed.name = "Spring"
            var a: [InventoryChange] = [.addMark(mine), .changeMark(renamed, expected: seen), .addMark(shared)]
            var b: [InventoryChange] = [.addMark(shared), .removeMark(id: seen.id, expected: seen), .addMark(yours)]
            var sent: [(change: InventoryChange, edit: PhoneEdit)] = []
            for (n, fromA) in order.enumerated() {
                let change = fromA ? a.removeFirst() : b.removeFirst()
                sent.append((change, try await one.send([change], from: fromA ? "phone1" : "phone2", n: n)[0]))
            }
            let pins = one.editor.inventory.pins
            #expect(Set(pins.compactMap(\.uid)).count == pins.count, "no pin twice: \(order)")
            for new in [shared, mine, yours] { #expect(pins.filter { $0.uid == new.uid }.count == 1, "\(order)") }
            var refused: [String] = []
            for one2 in sent {
                guard let why = try one.refusal(one2.edit) else { continue }
                if case .addMark = one2.change { Issue.record("an add refused: \(why), \(order)") }
                refused.append(why)
            }
            #expect(refused.count == 1, "one of the two that clash, said to its phone: \(order)")
            let renameFirst = order.enumerated().filter { $0.element }.map(\.offset)[1]
                < order.enumerated().filter { !$0.element }.map(\.offset)[1]
            #expect(refused == [renameFirst ? InventoryWords.changedSince : InventoryWords.noRow], "\(order)")
            #expect(pins.contains { $0.name == "Spring" } == renameFirst, "\(order)")
            #expect(pins.count == (renameFirst ? 4 : 3), "\(order)")
        }
    }

    /// A deleted pin never comes back by itself: a phone still holding it from a shared file sends it late.
    @Test func aLateCopyOfADeletedPinIsRefusedAndTheMacsPutBackStillWorks() async throws {
        let handed = Self.pin("Shelter")
        _ = try await send([.addMark(handed)], from: "phone1", n: 1)
        let kept = try #require(editor.inventory.pins.first)
        _ = try await send([.removeMark(id: kept.id, expected: kept)], from: "phone1", n: 2)
        let late = try await send([.addMark(handed)], from: "phone2", n: 3)
        #expect(try refusal(late[0]) == MapMarkWords.deletedSince)
        #expect(editor.inventory.pins == [])
        let deleted = try #require(editor.inventory.deletedMarks.first)
        guard case .done = try await editor.apply(deleted.putBack(among: editor.inventory.marks + editor.inventory.pins))
        else { Issue.record("Put back refused"); return }
        #expect(editor.inventory.pins == [kept])
        // its id taken meanwhile: Put back adds it as a new mark, which the Mac's own add is never refused
        _ = try await editor.apply(.removeMark(id: kept.id, expected: kept))
        _ = try await editor.apply(.addMark(Self.pin("Danger")))
        let taken = editor.inventory.pins
        guard case .done = try await editor.apply(deleted.putBack(among: editor.inventory.marks + taken))
        else { Issue.record("Put back refused"); return }
        #expect(editor.inventory.pins.map(\.uid).contains(handed.uid))
    }

    /// Owner checks §84 (2026-11-15, failed): a pin the phone renamed and deleted, put back on the Mac, never reached
    /// that phone. The Mac rewrites the phones' copy only when what it holds changed, and that comparison left the pins
    /// out, so a pin-only change on the Mac waited for the 10-minute rewrite. A meeting place's Put back is checked
    /// alongside (it passed on 2026-11-12).
    @Test func aPutBackOnTheMacReachesThePhoneThatDeletedIt() async throws {
        _ = try await editor.apply(.addMark(Self.pin("Water")))
        _ = try await editor.apply(.addMark(rally))
        var copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        var phone = PhoneOutbox()
        func fetch() throws {  // the Mac's copy as written now, and the phone's ordinary look settling it
            let fresh = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [],
                                            results: try editor.file.phoneEditResults(since: .distantPast))
            #expect(fresh.unstamped != copy.unstamped, "the Mac writes the phones' copy again")
            copy = fresh
            phone.settle(with: copy)
        }
        let water = try #require(copy.pins?.first)
        var renamed = water
        renamed.name = "Test water"
        phone.add(.changeMark(renamed, expected: water), what: "Edit")
        let shownRenamed = try #require(phone.view(copy).pins?.first)
        phone.add(.removeMark(id: shownRenamed.id, expected: shownRenamed), what: MapMarkWords.deleted("Test water"))
        let oak = try #require(copy.marks?.first)
        phone.add(.removeMark(id: oak.id, expected: oak), what: MapMarkWords.deleted(oak.name))
        let inbox = base.appendingPathComponent(PhoneInbox.inboxName)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try JSONEncoder().encode(PhoneEdits(edits: phone.pending.map(\.edit)))
            .write(to: inbox.appendingPathComponent("2026-11-15T10-00-00-phone1-x.json"))
        try await PhoneInbox.process(folder: base, editor: editor)
        try fetch()
        #expect(phone.pending.isEmpty && phone.refused.isEmpty, "every change answered and kept")
        #expect(phone.view(copy).pins == [] && phone.view(copy).marks == [])
        let deleted = DeletedMark.shown(editor.inventory.deletedMarks, marks: editor.inventory.marks + editor.inventory.pins)
        #expect(deleted.count == 2)
        for one in deleted {  // the Mac's Put back, then the Mac's next copy and the phone's next look
            guard case .done = try await editor.apply(one.putBack(among: editor.inventory.marks + editor.inventory.pins))
            else { Issue.record("Put back refused"); return }
            try fetch()
        }
        #expect(phone.view(copy).pins?.map(\.name) == ["Test water"], "back on the phone, as it was deleted")
        #expect(phone.view(copy).marks?.map(\.name) == [rally.name])
    }

    /// Failure 3 of the plan: a child's phone adds pins and removes its own, and nothing else, whatever it sends.
    @Test func aChildsPhoneAddsPinsAndRemovesOnlyItsOwn() async throws {
        _ = try await editor.apply(.addMark(rally))
        _ = try await editor.apply(.addMark(Self.pin("Danger")))
        _ = try await send([.addMark(Self.pin("Tree down", at: -40.7))], from: "phone1", n: 1)  // an adult's
        let added = try await send([.addMark(Self.pin("Car parked", at: -40.8))], from: "phone9", child: true, n: 2)
        #expect(try refusal(added[0]) == nil)
        let oak = try #require(editor.inventory.marks.first), pins = editor.inventory.pins
        let macs = try #require(pins.first { $0.by == MapMark.byMac }), adults = try #require(pins.first { $0.by == "phone1" })
        let own = try #require(pins.first { $0.by == "phone9" })
        let child = PhoneRules.Asker(phone: "phone9", child: true)
        #expect(PhoneRules.refusal(.addMark(Self.pin()), editor.inventory, from: child) == nil)
        #expect(PhoneRules.refusal(.removeMark(id: own.id, expected: own), editor.inventory, from: child) == nil)
        var renamed = own
        renamed.name = "Mine"
        let never: [InventoryChange] = [
            .removeMark(id: macs.id, expected: macs), .removeMark(id: adults.id, expected: adults),
            .removeMark(id: oak.id, expected: oak), .removeMark(id: 0, expected: adults),
            .changeMark(renamed, expected: own), .addMark(rally), .addMark(route), .putBackMark(own),
            .adjust(row: 3, by: -1), .delete(table: "Inventory", row: 3),
            .listAdd(sheet: ListsLayout.todo, cells: [:]), .startInsurance, .setPets([], expected: []),
        ]
        for change in never {
            #expect(PhoneRules.refusal(change, editor.inventory, from: child) == MapMarkWords.adultsOnly, "\(change)")
        }
        // a phone with no name is nobody's, and one phone's pins aren't another child's
        #expect(PhoneRules.refusal(.removeMark(id: own.id, expected: own), editor.inventory,
                                   from: .init(phone: "phone8", child: true)) == MapMarkWords.adultsOnly)
        // through the inbox: the stamp decides, and the refusal is that phone's answer
        let tried = try await send([.removeMark(id: adults.id, expected: adults), .removeMark(id: own.id, expected: own)],
                                   from: "phone9", child: true, n: 3)
        #expect(try refusal(tried[0]) == MapMarkWords.adultsOnly)
        #expect(try refusal(tried[1]) == nil)
        #expect(editor.inventory.pins.map(\.by) == [MapMark.byMac, "phone1"])
        #expect(editor.inventory.marks == [oak])
    }

    /// A phone not yet updated doesn't know `uid`, `made` or `by`: its rename of a rally point a phone made is still
    /// judged on what it could see, and the row keeps all three.
    @Test func anOlderPhonesRenameOfAPhoneMadeRallyPointIsKeptWithItsUid() async throws {
        var made = rally
        made.uid = UUID().uuidString.lowercased()
        _ = try await send([.addMark(made)], from: "phone1", n: 1)
        let kept = try #require(editor.inventory.marks.first)
        #expect(kept.uid == made.uid && kept.by == "phone1")
        var seen = kept  // as an older app decodes it
        (seen.uid, seen.made, seen.by) = (nil, nil, nil)
        var renamed = seen
        renamed.name = "Big oak at the park"
        let edits = try await send([.changeMark(renamed, expected: seen)], from: "phone2", n: 2)
        #expect(try refusal(edits[0]) == nil)
        let now = try #require(editor.inventory.marks.first)
        #expect(now.name == "Big oak at the park" && now.uid == kept.uid && now.by == "phone1" && now.made == kept.made)
        // the Mac's own rally points are as they always were: no uid, nothing new in the row
        _ = try await editor.apply(.addMark(route))
        #expect(editor.inventory.marks.last?.uid == nil && editor.inventory.marks.last?.made == nil)
    }

    /// The owner, 2026-11-12, by click: "Include pins". The backup's copy is the phones' copy, pins and all.
    @Test func theICloudBackupsCopyCarriesThePinsAsItDoesTheRallyPoints() async throws {
        _ = try await editor.apply(.addMark(rally))
        _ = try await editor.apply(.addMark(Self.pin()))
        try PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:]).write(in: base)
        let source = try #require(Backup.inventorySource(in: base))
        let backed = try JSONDecoder().decode(PhoneInventory.self, from: source.data)
        #expect(backed.pins?.map(\.name) == ["Water"])
        #expect(backed.marks?.map(\.name) == ["Meet at the big oak"])
        #expect(source.data == (try Data(contentsOf: base.appendingPathComponent(PhoneInventory.fileName))))
    }

    /// The owner, 2026-11-12: "When I label the phones by persons name the pins should carry that label." The Mac
    /// keeps the phone's pairing label on a mark it adds, and puts the owner's name for that phone in the phones'
    /// copy; a later phone under a reused label is never given an earlier one's pins, and a phone can't name itself.
    @Test func aPinCarriesTheOwnersNameForThePhoneThatAddedIt() async throws {
        var sent = Self.pin("Tree down")
        (sent.byName, sent.byLabel) = ("Mallory", "phone7")  // never taken from the sender
        _ = try await send([.addMark(sent)], from: "phone1", n: 1)
        _ = try await editor.apply(.addMark(Self.pin("Water")))
        let kept = try #require(editor.inventory.pins.first)
        #expect(kept.byLabel == "phone1" && kept.byName == nil)
        #expect(try editor.file.pins().first?.byLabel == "phone1", "kept in the file")
        let made = try #require(kept.made)
        let before = MapMark.PhoneName(label: "phone 1", added: "2020-01-01T00:00:00Z", name: "Sam's iPhone")
        #expect(kept.makerName([before]) == "Sam's iPhone")
        #expect(kept.makerName([MapMark.PhoneName(label: "phone 1", added: "2020-01-01T00:00:00Z", name: "")]) == nil)
        #expect(kept.makerName([MapMark.PhoneName(label: "phone 2", added: "2020-01-01T00:00:00Z", name: "Kit")]) == nil)
        #expect(kept.makerName([MapMark.PhoneName(label: "phone 1", added: "2999-01-01T00:00:00Z", name: "Later")]) == nil,
                "paired after the pin was made: another phone under a label used again")
        #expect(kept.makerName([MapMark.PhoneName(label: "phone 1", added: made, name: "Sam's iPhone")]) != nil)
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:], makers: [before])
        #expect(copy.pins?.map(\.byName) == ["Sam's iPhone", nil], "the Mac's own pin has no phone to name")
        #expect(copy.pins?.allSatisfy { $0.byLabel == nil } == true, "the label stays on the Mac")
        let shown = try #require(copy.pins?.first)
        #expect(MapMarkWords.added(shown, here: "device:someone", device: "iPhone")?.hasSuffix(" by Sam's iPhone") == true)
        #expect(MapMarkWords.added(shown, here: "phone1", device: "iPhone")?.hasSuffix(" on this iPhone") == true)
        #expect(MapMarkWords.added(kept, here: MapMark.byMac, device: "Mac", name: "Sam's iPhone")?
            .hasSuffix(" by Sam's iPhone") == true)
        // a phone's change made from the named copy is judged on what it could change, and the file keeps the label
        var renamed = shown
        renamed.name = "Big tree down"
        let edits = try await send([.changeMark(renamed, expected: shown)], from: "phone2", n: 2)
        #expect(try refusal(edits[0]) == nil)
        let now = try #require(editor.inventory.pins.first)
        #expect(now.name == "Big tree down" && now.byLabel == "phone1" && now.byName == nil)
    }

    /// What the map's pin layer gets (phase 2): each shared pin's name, its symbol's two pictures by name, its colors
    /// by day and in red night, and its uid as a property, after a phone's own pins from before.
    @Test func theMapGetsEachSharedPinWithItsLookAfterAPhonesOwn() throws {
        var cache = Self.pin("Cache")
        (cache.pinSymbol, cache.pinColor, cache.note) = ("shippingbox.fill", "red-mark", "Under the third step")
        var own = PersonalPins()
        own.add(.water, longitude: -40.2, latitude: 10.2)
        let data = MapMark.pinsGeoJSON([cache, rally], own: own)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try #require(object["features"] as? [[String: Any]])
        #expect(features.count == 2, "a rally point is never a pin")
        let mine = try #require(features[0]["properties"] as? [String: Any])
        #expect(mine["label"] as? String == "Water" && mine["shared"] == nil && mine["icon"] == nil)
        let shared = try #require(features[1]["properties"] as? [String: Any])
        #expect(shared["label"] as? String == "Cache" && shared["shared"] as? Bool == true)
        #expect(shared["pin"] as? String == cache.uid && shared["note"] as? String == "Under the third step")
        #expect(shared["icon"] as? String == "pm-pin-shippingbox.fill")
        #expect(shared["nightIcon"] as? String == "pm-pin-dark-shippingbox.fill", "red draws its symbol dark at night")
        #expect(shared["nightColor"] as? String == "#ffffff", "and its dot white, so danger stays the brightest")
        #expect(shared["color"] as? String == PersonalPins.Label.danger.mapColor)
        var water = Self.pin()
        water.pinColor = "info-mark"
        let blue = try #require(try JSONSerialization.jsonObject(with: MapMark.pinsGeoJSON([water])) as? [String: Any])
        let props = try #require((blue["features"] as? [[String: Any]])?.first?["properties"] as? [String: Any])
        #expect(props["nightIcon"] as? String == "pm-pin-drop.fill" && props["nightColor"] as? String == props["color"] as? String)
    }

    @Test func aMarkSaysWhenAndWhereItWasAddedWithoutNamingAPhone() {
        var pin = Self.pin()
        #expect(MapMarkWords.added(pin, here: MapMark.byMac, device: "Mac") == nil, "no record: nothing said")
        (pin.made, pin.by) = ("2026-11-12T15:00:00Z", MapMark.byMac)
        let onMac = MapMarkWords.added(pin, here: MapMark.byMac, device: "Mac")
        #expect(onMac?.hasPrefix("Added ") == true && onMac?.hasSuffix(" on this Mac") == true)
        let mine = MapMark.by(device: "0F1E2D3C-4B5A-4968-8776-6554433221A1")
        #expect(mine == "device:0f1e2d3c-4b5a-4968-8776-6554433221a1", "as the Mac's edits name the phone")
        #expect(MapMarkWords.added(pin, here: mine, device: "iPhone")?.hasSuffix(" on the Mac") == true)
        pin.by = mine
        #expect(MapMarkWords.added(pin, here: mine, device: "iPhone")?.hasSuffix(" on this iPhone") == true)
        #expect(MapMarkWords.added(pin, here: MapMark.byMac, device: "Mac")?.hasSuffix(" on a phone") == true)
        pin.by = "phone2"
        #expect(MapMarkWords.added(pin, here: mine, device: "iPad")?.hasSuffix(" on another phone") == true)
        #expect(MapMark.by(device: nil) == "")
    }

    /// A ticked pin goes out as a point: a placemark in KML, a waypoint in GPX, after the rally points and before the
    /// routes (GPX wants its waypoints first).
    @Test func aSharedFileCarriesATickedPinAsAPoint() throws {
        var oak = rally, north = route, pin = Self.pin("Spring")
        (oak.id, north.id, pin.id) = (1, 2, 3)
        let picked = OrganicMaps.picked([oak, north, pin], [1, 2, 3])
        #expect(picked.map(\.name) == ["Meet at the big oak", "Spring", "Way out north"])
        let kml = OrganicMaps.kml(picked)
        #expect(kml.components(separatedBy: "<Point>").count == 3 && kml.components(separatedBy: "<LineString>").count == 2)
        let gpx = OrganicMaps.gpx(picked)
        #expect(gpx.components(separatedBy: "<wpt ").count == 3)
        let lastPoint = try #require(gpx.range(of: "<wpt ", options: .backwards)), track = try #require(gpx.range(of: "<trk>"))
        #expect(lastPoint.lowerBound < track.lowerBound)
    }

    /// The file phones hand each other (phase 3): the shared pins with their uids, and a phone's own from before.
    @Test func thePinsFileCarriesSharedPinsAndStillReadsAPhonesOwnFromBefore() throws {
        var cache = Self.pin("Cache")
        (cache.id, cache.note, cache.made, cache.by) = (7, "Under the third step", "2026-11-12T15:00:00Z", "phone1")
        let data = try SharedPinsFile.encode([cache, rally])
        let read = try #require(SharedPinsFile.read(data))
        #expect(read.count == 1, "pins only")
        #expect(read[0].uid == cache.uid && read[0].name == "Cache" && read[0].note == "Under the third step")
        #expect(read[0].id == 0 && read[0].made == nil && read[0].by == nil, "who and when are the Mac's to say")
        #expect(PersonalPins.read(shared: data) == nil, "a phone not yet updated refuses it whole, never half reads it")
        // already here by its uid, or by its name within 5 m; a new one is added once
        var near = Self.pin("Cache")
        near.points = [[cache.points[0][0] + 0.00001, cache.points[0][1]]]
        let far = Self.pin("Cache", at: -41.0)
        #expect(SharedPinsFile.new(read, among: [cache]) == [])
        #expect(SharedPinsFile.new([near, far, far], among: [cache]) == [far])
        #expect(SharedPinsFile.words(added: 1, already: 2) == "Added 1 pin. 2 were already here.")
        // version 1: each kind becomes its look, Meet here kept as a pin of that name, its id the uid
        var own = PersonalPins()
        let added = own.add(.meet, longitude: -40.2, latitude: 10.2)
        let meet = try #require(added)
        own.add(.water, longitude: -40.3, latitude: 10.3)
        let old = try #require(SharedPinsFile.read(try own.shared()))
        #expect(old.map(\.name) == ["Meet here", "Water"] && old[0].uid == meet.id.uuidString.lowercased())
        #expect(old.allSatisfy { $0.problem == nil }, "each one the Mac would keep")
        #expect(own.asShared == old)
        // anything else is refused whole
        var bad = Self.pin()
        bad.pinSymbol = "not.a.symbol"
        let planted = try JSONSerialization.data(withJSONObject: [
            "prepareme": "pins", "version": 2,
            "marks": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(bad))]])
        #expect(SharedPinsFile.read(planted) == nil)
        #expect(SharedPinsFile.read(Data("{}".utf8)) == nil)
        let kindless = try JSONSerialization.data(withJSONObject: [
            "prepareme": "pins", "version": 2,
            "marks": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(rally))]])
        #expect(SharedPinsFile.read(kindless) == nil, "a rally point is never taken from a pins file")
    }

    /// What a phone offers to remove (phase 3): an adult's any but the Start point; a child's only a pin it made,
    /// or one it added that still waits for the Mac.
    @Test func aPhoneOffersToRemoveOnlyWhatTheMacWouldLetIt() {
        var mine = Self.pin(), theirs = Self.pin(), waiting = Self.pin()
        (mine.id, mine.by, theirs.id, theirs.by, waiting.id) = (3, "device:me", 4, "phone2", -12)
        var oak = rally
        oak.id = 1
        let start = MapMark(id: 2, kind: .start, name: "Start", points: [[-40.5, 10.5]])
        #expect([mine, theirs, waiting, oak].allSatisfy { $0.removable(adult: true, phone: "device:me") })
        #expect(!start.removable(adult: true, phone: "device:me"))
        #expect(mine.removable(adult: false, phone: "device:me") && waiting.removable(adult: false, phone: "device:me"))
        #expect(!theirs.removable(adult: false, phone: "device:me") && !oak.removable(adult: false, phone: "device:me"))
        #expect(!mine.removable(adult: false, phone: ""), "a phone with no id of its own removes none but its waiting ones")
    }

    /// A child's phone removes a pin it added before the Mac has numbered it: sent with the number it is shown under.
    @Test func aChildsRemoveOfItsOwnWaitingPinReachesTheMac() async throws {
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        let made = Self.pin("Car parked")
        var phone = PhoneOutbox()
        phone.add(.addMark(made), what: "Add")
        let shown = try #require(phone.view(copy).pins?.first)
        #expect(shown.removable(adult: false, phone: "phone9"))
        phone.add(.removeMark(id: shown.id, expected: shown), what: "Remove")
        #expect(phone.view(copy).pins == [])
        let edits = try await send(phone.pending.map(\.edit.change), from: "phone9", child: true, n: 1)
        for edit in edits { #expect(try refusal(edit) == nil) }
        #expect(editor.inventory.pins == [])
    }

    @Test func theLooksOfferedAreTheReadyMadeOnesThenThoseOnTheMapEachOnce() {
        #expect(!PinLook.readyMade.contains { $0.name == PersonalPins.Label.meet.rawValue }, "to meet is a rally point")
        #expect(PinLook.readyMade.count == PersonalPins.Label.allCases.count - 1)
        var cache = Self.pin("Cache")
        (cache.pinSymbol, cache.pinColor) = ("shippingbox.fill", "ok-mark")
        let offered = PinLook.offered([Self.pin(), cache, cache, rally])
        #expect(offered.count == PinLook.readyMade.count + 1 && offered.last?.name == "Cache")
        #expect(Set(PinLook.symbols).count == PinLook.symbols.count)
        #expect(Set(PinLook.symbols).isSuperset(of: PersonalPins.Label.allCases.map(\.symbol)), "every old kind's symbol")
        #expect(PinLook.colors.allSatisfy { Palette.tokens[$0] != nil } && PinLook.colors.count == 4)
        for label in PersonalPins.Label.allCases {  // the old kinds' looks and the new ones' agree
            #expect(PinLook.mapColor(label.color) == label.mapColor && PinLook.nightColor(label.color) == label.nightColor)
            #expect(PinLook.nightDark(label.color) == label.nightDark)
        }
        #if canImport(AppKit)
        for symbol in PinLook.symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
        #endif
    }
}
