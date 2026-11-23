import Foundation
import Testing
@testable import PrepareMeShared

/// The household's player list (players plan, stage 2): add, rename, recolor and retire on the Mac, the caps and the
/// nickname rules, numbers never used twice, the file's limits wherever it is read, an unreadable file set aside as
/// the game saves' is, and the bridge's two asks with every field checked. Names are made up and built from pieces,
/// so no file holds a whole one (and `PlayersRouteTests` looks for them in the service's log).
@MainActor
struct PlayersTests {
    /// Made-up nicknames, assembled from pieces.
    static let names = ["Wil" + "low", "Ce" + "dar", "As" + "pen", "Ha" + "zel", "Ro" + "wan"]

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("players-\(UUID().uuidString)")
    }

    @Test func addRenameRecolorRetire() throws {
        var list = PlayerList()
        let first = try list.add("  \(Self.names[0])  ", color: .violet)
        let second = try list.add(Self.names[1], color: .olive)
        #expect(first == Player(id: 1, name: Self.names[0], color: .violet, retired: false))  // spaces at the ends go
        #expect(second.id == 2 && list.next == 3)
        try list.rename(1, to: Self.names[2])
        try list.recolor(1, to: .slate)
        #expect(list.player(1) == Player(id: 1, name: Self.names[2], color: .slate, retired: false))
        try list.retire(2)
        #expect(list.active.map(\.id) == [1] && list.players.count == 2, "retiring never deletes")
        let third = try list.add(Self.names[1], color: .pink)  // a retired player's nickname is free again
        #expect(third.id == 3, "a number is never used again")
        #expect(throws: PlayerList.Problem.taken) { try list.retire(2, false) }  // brought back only under a free name
        try list.rename(3, to: Self.names[3])
        try list.retire(2, false)
        #expect(list.active.map(\.id) == [1, 2, 3])
        #expect(throws: PlayerList.Problem.unknown) { try list.rename(9, to: Self.names[4]) }
        #expect(throws: PlayerList.Problem.unknown) { try list.recolor(9, to: .pink) }
        #expect(throws: PlayerList.Problem.unknown) { try list.retire(9) }
        #expect(throws: PlayerList.Problem.taken) { try list.add(Self.names[2].uppercased(), color: .pink) }
        #expect(first.letter == String(Self.names[0].prefix(1)))
    }

    @Test func theNicknameRules() {
        #expect(PlayerList.nickname(String(repeating: "x", count: PlayerList.nameMost)) != .failure(.tooLong))
        #expect(PlayerList.nickname(String(repeating: "x", count: PlayerList.nameMost + 1)) == .failure(.tooLong))
        #expect(PlayerList.nickname("   ") == .failure(.empty))
        #expect(PlayerList.nickname("") == .failure(.empty))
        for odd in ["a\nb", "a\u{0}b", "a\u{200B}b", "a\u{7}b", "a\u{2028}b", "a\u{202E}b", "a\u{FEFF}b"] {
            #expect(PlayerList.nickname(odd) == .failure(.odd), "\(odd.unicodeScalars.map(\.value))")
        }
        #expect(PlayerList.nickname("Zoë 2") == .success("Zoë 2"))
        #expect(PlayerList.nickname("👩🏽‍🚀" + "x") == .success("👩🏽‍🚀x"), "a person counts a picture as one character")
    }

    @Test func theCaps() throws {
        var list = PlayerList()
        for n in 0..<PlayerList.most { try list.add("P\(n)", color: .brown) }
        #expect(throws: PlayerList.Problem.full) { try list.add("One more", color: .brown) }
        try list.retire(1)
        try list.add("One more", color: .brown)  // a retired player leaves room
        #expect(throws: PlayerList.Problem.full) { try list.retire(1, false) }  // and comes back only with room
        // 64 in all, retired ones included: past that, no more, so the file stays small
        var many = PlayerList()
        for n in 0..<PlayerList.mostInAll {
            try many.add("R\(n)", color: .slate)
            try many.retire(many.players.last!.id)
        }
        #expect(throws: PlayerList.Problem.allUsed) { try many.add("Last", color: .slate) }
        let data = try many.encoded()
        #expect(data.count < PlayerList.fileLimit / 2)
        #expect(PlayerList.read(data) == many)
    }

    @Test func theFileIsCheckedWhereverItIsRead() throws {
        var list = PlayerList()
        try list.add(Self.names[0], color: .violet)
        try list.add(Self.names[1], color: .pink)
        let good = String(data: try list.encoded(), encoding: .utf8)!
        #expect(PlayerList.read(Data(good.utf8)) == list)
        let player = { (id: Int, name: String, color: String, retired: Bool) in
            "{\"id\":\(id),\"name\":\"\(name)\",\"color\":\"\(color)\",\"retired\":\(retired)}"
        }
        let file = { (next: Int, players: [String], version: Int) in
            Data("{\"version\":\(version),\"next\":\(next),\"players\":[\(players.joined(separator: ","))]}".utf8)
        }
        #expect(PlayerList.read(file(2, [player(1, "Ok", "plum", false)], 1)) != nil)
        let wrong: [Data] = [
            file(2, [player(1, "Ok", "plum", false)], 2),  // a later build's
            file(2, [player(1, "Ok", "red", false)], 1),  // not one of the players' colors
            file(2, [player(1, String(repeating: "x", count: 13), "plum", false)], 1),
            file(2, [player(1, " Ok", "plum", false)], 1),  // not as the Mac keeps a nickname
            file(2, [player(1, "", "plum", false)], 1),
            file(3, [player(1, "Ok", "plum", false), player(1, "Ko", "plum", false)], 1),  // one number twice
            file(2, [player(2, "Ok", "plum", false)], 1),  // a number not yet given
            file(2, [player(0, "Ok", "plum", false)], 1),
            file(3, [player(1, "Ok", "plum", false), player(2, "ok", "plum", false)], 1),  // one nickname twice
            file(14, (1...13).map { player($0, "P\($0)", "plum", false) }, 1),  // thirteen not retired
            Data(#"{"version":1,"next":2}"#.utf8), Data("[]".utf8), Data("damaged".utf8),
            Data(good.utf8) + Data(repeating: 0x20, count: PlayerList.fileLimit),  // over the size limit
        ]
        for data in wrong { #expect(PlayerList.read(data) == nil, "\(String(decoding: data.prefix(120), as: UTF8.self))") }
        #expect(PlayerList.read(file(3, [player(1, "Ok", "plum", false), player(2, "ok", "plum", true)], 1)) != nil,
                "a retired player's nickname may come back on another")
    }

    @Test func savedWholeAndKeptOutOfBackups() throws {
        let folder = Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var list = PlayerList()
        try list.add(Self.names[0], color: .olive)
        try list.save(folder)
        try list.save(folder, as: PlayerList.phoneFileName)
        #expect(PlayerList.load(folder) == list)
        for name in [PlayerList.fileName, PlayerList.phoneFileName] {
            let url = folder.appendingPathComponent(name)
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        #expect(PlayerList.load(Self.scratch()) == PlayerList())  // none yet: an empty list
    }

    @Test func anUnreadableListIsSetAsideNeverOverwritten() throws {
        let folder = Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(PlayerList.fileName)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for bad in ["damaged", #"{"version":9,"next":1,"players":[]}"#] {
            try Data(bad.utf8).write(to: url)
            var list = PlayerList.load(folder, now: now)
            let aside = try #require(list.setAside, "set aside, not treated as empty")
            #expect(aside.hasPrefix("players-unreadable-") && !list.blocked && list.players.isEmpty)
            #expect(String(decoding: try Data(contentsOf: folder.appendingPathComponent(aside)), as: UTF8.self) == bad)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            try list.add(Self.names[0], color: .violet)
            try list.save(folder)
        }
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("unreadable") }
        #expect(aside.count == 2, "the second took -1: \(aside.sorted())")
        // a folder that can't be written: the file can't be renamed, so the list writes nothing
        let locked = Self.scratch()
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: locked)
        }
        try Data("damaged".utf8).write(to: locked.appendingPathComponent(PlayerList.fileName))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        var stuck = PlayerList.load(locked)
        #expect(stuck.blocked && stuck.setAside == nil)
        #expect(throws: PlayerList.Problem.blocked) { try stuck.add(Self.names[0], color: .violet) }
        #expect(throws: PlayerList.Problem.blocked) { try stuck.save(locked) }
    }

    @Test func playerColorsKeepClearOfThePagesMeanings() {
        let meanings = [Palette.red, Palette.redMark, Palette.caution, Palette.accent, Palette.okMark, Palette.info,
                        Palette.infoMark, Palette.link, Palette.idFill]
        for color in PlayerColor.allCases {
            #expect(!meanings.contains(color.pair), "\(color)")
        }
        #expect(Set(PlayerColor.allCases.map(\.pair.light)).count == PlayerColor.allCases.count)
    }

    // MARK: The bridge's two asks

    static let main = GameSavesTests.main
    static let key = GameSavesTests.key

    static func household() throws -> PlayerList {
        var list = PlayerList()
        try list.add(names[0], color: .violet)
        try list.add(names[1], color: .pink)
        try list.add(names[2], color: .olive)
        try list.retire(3)
        return list
    }

    @Test func thePlayersAskIsCheckedForKindAndSize() {
        let check = { (body: Any, frame: GameBridge.Frame) in
            GameBridge.check(body, from: frame, gamesID: GameSavesTests.games, ours: GameSavesTests.ours)
        }
        let players: [String: Any] = ["v": 1, "ask": "players", "key": Self.key]
        let usual: [String: Any] = ["v": 1, "ask": "usual", "key": Self.key, "player": 2]
        #expect(check(players, Self.main) == .success(.players(key: Self.key)))
        #expect(check(usual, Self.main) == .success(.usual(key: Self.key, id: 2)))
        var framed = Self.main
        framed.isMain = false
        #expect(check(players, framed) == .failure(.framed))
        #expect(check(usual, framed) == .failure(.framed))
        for path in ["/index.html", "/zimi/2048/index.html", "/kit/x.html"] {
            var frame = Self.main
            frame.path = path
            #expect(check(players, frame) == .failure(.notOurs) && check(usual, frame) == .failure(.notOurs), "\(path)")
        }
        var elsewhere = Self.main
        elsewhere.host = GameSavesTests.other.uuidString
        #expect(check(players, elsewhere) == .failure(.elsewhere))
        let wrong: [Any] = [
            players.merging(["id": 1]) { $1 }, players.merging(["key": "pm-other"]) { $1 }, players.merging(["v": 2]) { $1 },
            usual.filter { $0.key != "player" }, usual.merging(["player": 0]) { $1 }, usual.merging(["player": -1]) { $1 },
            usual.merging(["player": 1.5]) { $1 }, usual.merging(["player": true]) { $1 },
            usual.merging(["player": "2"]) { $1 }, usual.merging(["player": NSNull()]) { $1 },
            usual.merging(["player": Double(GameBridge.countMost) * 2]) { $1 }, usual.merging(["id": 2]) { $1 },
            usual.merging(["name": "x"]) { $1 }, usual.merging(["save": "{}"]) { $1 },
        ]
        for body in wrong { #expect(check(body, Self.main) == .failure(.unknown), "\(body)") }
    }

    @Test func theAnswersGiveOnlyPlayersNotRetiredAndKeepTheUsualOne() throws {
        let list = try Self.household()
        var store = GameSaves()
        _ = store.read(gamesID: GameSavesTests.games, ours: GameSavesTests.ours)
        let ask: [String: Any] = ["v": 1, "ask": "players", "key": Self.key]
        let first = store.answer(ask, from: Self.main, players: list)
        let shown = (first.reply["players"] as? [[String: Any]])?.map { $0["id"] as? Int }
        #expect(first.reply["ok"] as? Bool == true && shown == [1, 2] && first.reply["usual"] is NSNull)
        #expect(!first.changed && first.refused == nil)
        let named = (first.reply["players"] as? [[String: Any]])?.first
        #expect(named?["name"] as? String == Self.names[0] && named?["color"] as? String == "violet")
        // the usual player: one not retired, else refused and nothing changes
        let set = store.answer(["v": 1, "ask": "usual", "key": Self.key, "player": 2], from: Self.main, players: list)
        #expect(set.changed && set.reply["ok"] as? Bool == true && store.usual == 2)
        for id in [3, 9] {
            let no = store.answer(["v": 1, "ask": "usual", "key": Self.key, "player": id], from: Self.main, players: list)
            #expect(no.refused == .noPlayer && !no.changed && store.usual == 2, "\(id)")
        }
        #expect(store.answer(ask, from: Self.main, players: list).reply["usual"] as? Int == 2)
        // the usual player retired on the Mac: not offered as usual, until a new first pick
        var later = list
        try later.retire(2)
        #expect(store.answer(ask, from: Self.main, players: later).reply["usual"] is NSNull)
        // the usual player kept with the store, and read by a version 2 file's reader
        let folder = Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.save(folder)
        #expect(GameSaves.load(folder).usual == 2)
        // no player list on the device: an empty answer, and no usual player can be set
        let none = store.answer(ask, from: Self.main)
        #expect((none.reply["players"] as? [Any])?.isEmpty == true)
        #expect(store.answer(["v": 1, "ask": "usual", "key": Self.key, "player": 1], from: Self.main).refused == .noPlayer)
    }
}
