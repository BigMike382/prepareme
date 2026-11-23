import Foundation
import Testing
@testable import PrepareMeShared

/// The Start point (hand-off improvements plan, phase 3): one at most, through the editor's ID check like any mark,
/// never sent to phones (the map pins plan, 2026-11-14: Mac only), never somewhere to go, never in a shared file. Made-up rehearsal copies and made-up places (open ocean) only.
@MainActor
struct StartPointTests {
    let base: URL
    let check = FakeCheck()
    let editor: InventoryEditor

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-start-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: check)
    }

    let start = MapMark(kind: .start, name: "End of the lane", points: [[-40.5, 10.5]])
    let rally = MapMark(kind: .rally, name: "Meet at the big oak", points: [[-40.1, 10.9]], role: .nearHome)

    @Test func oneStartIsCheckedKeptAndASecondRefused() async throws {
        guard case .done(_, let id) = try await editor.apply(.addMark(start)) else { Issue.record("not kept"); return }
        #expect(check.asked.last?.place == "Map, the printed directions' start")
        #expect(try editor.file.marks().map(\.kind) == [.start])
        #expect(try await editor.apply(.addMark(start)) == .refused(MapMarkWords.oneStart))
        guard case .done = try await editor.apply(.addMark(rally)) else { Issue.record("rally refused"); return }
        // a rally point changed into a second Start is refused too; the Start itself may be renamed
        let kept = try #require(editor.inventory.marks.first { $0.kind == .rally })
        var changed = kept
        changed.kind = .start
        changed.role = nil
        #expect(try await editor.apply(.changeMark(changed, expected: kept)) == .refused(MapMarkWords.oneStart))
        var renamed = try #require(editor.inventory.marks.first { $0.id == id })
        let seen = renamed
        renamed.name = "Corner by the mailboxes"
        guard case .done = try await editor.apply(.changeMark(renamed, expected: seen)) else { Issue.record(); return }
        #expect(editor.inventory.marks.first { $0.id == id }?.name == "Corner by the mailboxes")
    }

    @Test func aStartIsOnePointWithNoRole() {
        var two = start
        two.points.append([-40, 10])
        #expect(two.problem == MapMarkWords.startOnePoint)
        var role = start
        role.role = .nearHome
        #expect(role.problem == MapMarkWords.routeRole)
        var routeRole = start
        routeRole.routeRole = .main
        #expect(routeRole.problem == MapMarkWords.rallyRouteRole)
        #expect(start.problem == nil)
    }

    /// The map pins plan, Task 1.2 (owner, 2026-11-14): the Start point is Mac only, so it never reaches a phone.
    @Test func phonesNeverGetIt() async throws {
        _ = try await editor.apply(.addMark(start))
        _ = try await editor.apply(.addMark(rally))
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        #expect(copy.start == nil)
        #expect(copy.marks?.map(\.kind) == [.rally])
        #expect(copy.mapMarks.map(\.kind) == [.rally])
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any])
        #expect(json["start"] == nil || json["start"] is NSNull)
        #expect(!String(decoding: try JSONEncoder().encode(copy), as: UTF8.self).contains("\"kind\":\"start\""),
                "no mark of kind start anywhere in the copy")
        #expect(PhoneOutbox().view(copy).start == nil)
    }

    /// An updated phone beside a Mac not yet updated, which still sends its Start (Review Focus 1): still decodable,
    /// never shown.
    @Test func anOlderMacsStartIsIgnored() async throws {
        _ = try await editor.apply(.addMark(rally))
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        var older = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any])
        var kept = start
        kept.id = 9
        older["start"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(kept))
        let read = try JSONDecoder().decode(PhoneInventory.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(read.start?.name == "End of the lane", "the field still reads")
        #expect(read.mapMarks.map(\.kind) == [.rally])
        #expect(PhoneOutbox().view(read).mapMarks.map(\.kind) == [.rally])
    }

    @Test func itIsNeverSomewhereToGoNorShared() {
        var kept = start
        kept.id = 1
        var meet = rally
        meet.id = 2
        let ways = Position.ways(from: (10.5, -40.5), to: [kept, meet])
        #expect(ways.map(\.mark.id) == [2], "never the kids' arrow's target")
        #expect(Position.ordered([meet, kept]).map(\.id) == [1, 2], "the Start first in every list")
        #expect(Position.rallyNumbers([kept, meet]) == [2: 1])
        #expect(!OrganicMaps.kml([kept, meet]).contains("End of the lane"))
        #expect(!OrganicMaps.gpx([kept, meet]).contains("End of the lane"))
        #expect(OrganicMaps.picked([kept, meet], [1, 2]).map(\.id) == [2])
        let features = (try? JSONSerialization.jsonObject(with: MapMark.geoJSON([kept])) as? [String: Any])?["features"]
        let geometry = (features as? [[String: Any]])?.first?["geometry"] as? [String: Any]
        #expect(geometry?["type"] as? String == "Point")
    }
}
