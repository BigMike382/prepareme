import Foundation
import Testing
@testable import PrepareMeShared

/// The finished games' lines (players plan, stage 3): the store across a relaunch, with an unreadable file and with bad
/// lines in it, the cap, a line twice; the two asks' shapes, sizes and refusals; the pages a board reads; and never a
/// nickname in the store. The household is made up (PlayersTests.names, built from pieces).
@MainActor
struct GameLinesTests {
    static let names = PlayersTests.names
    static let key = GameSavesTests.key

    /// A finished Hearts game's line as the card table sends it.
    static func page(_ id: String = String(repeating: "a", count: 32), seat: Any = 1, more: [String: Any] = [:]) -> [String: Any] {
        var line: [String: Any] = [
            "id": id, "game": "hearts", "rules": 1, "strength": "medium", "players": 4, "goal": 100,
            "began": 1_795_000_000, "ended": 1_795_001_200, "seats": [seat, "Briar", "Ember", "Flint"],
            "scores": [40, 90, 101, 60], "winners": [0], "how": "finished", "hands": 6, "generation": 0,
            "extra": ["moons": [1, 0, 0, 0]],
        ]
        for (k, v) in more { line[k] = v }
        return line
    }
    /// A finished Solitaire game's line: one person, the turning rule as its strength, the moves as its score.
    static func solo(more: [String: Any] = [:]) -> [String: Any] {
        page(more: ["game": "klondike", "strength": "one", "players": 1, "seats": [1], "scores": [112], "hands": 1,
                    "extra": ["time": [305], "undo": [1], "hint": [0]]].merging(more) { $1 }).filter { $0.key != "goal" }
    }
    static func ask(_ line: Any) -> [String: Any] { ["v": 1, "ask": "line", "key": key, "line": line] }
    static func id(_ n: Int) -> String { String(format: "%032x", n) }

    static func household() throws -> PlayerList {
        var list = PlayerList()
        try list.add(names[0], color: .violet)
        try list.add(names[1], color: .pink)
        try list.add(names[2], color: .olive)
        try list.retire(3)
        return list
    }
    static func check(_ body: Any, _ frame: GameBridge.Frame = GameSavesTests.main) -> Result<GameBridge.Ask, GameBridge.Refusal> {
        GameBridge.check(body, from: frame, gamesID: GameSavesTests.games, ours: GameSavesTests.ours)
    }

    // MARK: The asks

    @Test func aLineIsCheckedForKindSizeAndRules() throws {
        guard case .success(.line(let k, let line)) = Self.check(Self.ask(Self.page())) else { Issue.record("refused"); return }
        #expect(k == Self.key && line.folder == "cardtable" && line.seats == [.player(1), .computer("Briar"), .computer("Ember"), .computer("Flint")])
        // fine: a guest's game, a game given up (no winners, by a person), a game with no goal and no extra
        for good in [Self.page(seat: "guest"), Self.page(more: ["how": "given up", "by": 0, "winners": [Int]()]),
                     Self.page().filter { $0.key != "goal" && $0.key != "extra" },
                     Self.page(more: ["players": 2, "seats": [1, "Moss"], "scores": [80, 210], "game": "eights", "extra": ["outs": [3, 4]]]),
                     Self.solo(), Self.solo(more: ["strength": "three", "seats": ["guest"]]), Self.solo(more: ["how": "given up", "by": 0, "winners": [Int]()]),
                     // Spades' own counts (games plan, section 44), at their highest, with the app already on the phones
                     Self.page(more: ["game": "spades", "goal": 500, "scores": [520, 300, 520, 300], "winners": [0, 2],
                                      "extra": ["nils": [1, 0, 2, 0], "sets": [0, 3, 0, 3], "bags": [100_000, 7, 100_000, 7]]])] {
            if case .failure(let why) = Self.check(Self.ask(good)) { Issue.record("refused, \(why.rawValue): \(good)") }
        }
        // anything else is refused as a line that breaks the rules
        let bad: [[String: Any]] = [
            Self.page(String(repeating: "A", count: 32)), Self.page("abc"), Self.page(more: ["game": "Hearts"]), Self.page(more: ["rules": 0]),
            Self.page(more: ["rules": true]), Self.page(more: ["rules": 1.5]), Self.page(more: ["strength": "expert"]),
            Self.page(more: ["players": 3]), Self.page(more: ["players": 1, "seats": [1], "scores": [3]]),
            Self.page(more: ["strength": "one"]), Self.solo(more: ["seats": ["Pip"]]), Self.solo(more: ["strength": "two"]), Self.solo(more: ["strength": "easy"]),
            Self.page(more: ["players": 9, "seats": Array(repeating: "Pip", count: 9), "scores": Array(repeating: 1, count: 9)]),
            Self.page(more: ["scores": [40, 90, 101]]), Self.page(more: ["scores": [40, 90, 101, 1_000_000]]),
            Self.page(more: ["goal": 0]), Self.page(more: ["goal": NSNull()]), Self.page(more: ["began": 100]),
            Self.page(more: ["ended": 1_794_999_999]), Self.page(more: ["winners": [Int]()]), Self.page(more: ["winners": [4]]),
            Self.page(more: ["winners": [0, 0]]), Self.page(more: ["how": "won"]), Self.page(more: ["by": 0]),
            Self.page(more: ["how": "given up", "winners": [Int]()]), Self.page(more: ["how": "given up", "by": 1, "winners": [Int]()]),
            Self.page(more: ["how": "given up", "by": 0, "winners": [0]]), Self.page(more: ["hands": -1]), Self.page(more: ["generation": 2000]),
            Self.page(more: ["extra": ["moons": [1, 0, 0]]]), Self.page(more: ["extra": ["Moons": [1, 0, 0, 0]]]),
            Self.page(more: ["extra": ["a": [0, 0, 0, 0], "b": [0, 0, 0, 0], "c": [0, 0, 0, 0], "d": [0, 0, 0, 0], "e": [0, 0, 0, 0]]]),
            Self.page(more: ["game": "spades", "scores": [520, 300, 520, 300], "winners": [0, 2], "extra": ["bags": [100_001, 0, 100_001, 0]]]),
            Self.page(seat: 0), Self.page(seat: true), Self.page(seat: "Guest"), Self.page(seat: "briar"), Self.page(seat: "A Name"),
            Self.page(seat: String(repeating: "B", count: 13)), Self.page(more: ["seats": [1, 1, "Ember", "Flint"]]),
            Self.page(more: ["folder": "other"]), Self.page(more: ["device": Self.id(1)]), Self.page(more: ["count": 3]),
            Self.page().filter { $0.key != "hands" }, Self.page().filter { $0.key != "seats" },
        ]
        for line in bad { #expect(Self.check(Self.ask(line)) == .failure(.badLine), "\(line)") }
        #expect(Self.check(Self.ask("a line")) == .failure(.badLine))
        // too big as sent: a line over 2 KB
        let big = Self.page(more: ["extra": ["moons": Array(repeating: 99_999, count: 4)],
                                    "seats": [1, String(repeating: "B", count: 12), "Ember", "Flint"]])
            .merging(["pad": String(repeating: "x", count: 2100)]) { $1 }
        #expect(Self.check(Self.ask(big)) == .failure(.lineTooBig))
        // the envelope: a field more or less, the version, the key
        #expect(Self.check(Self.ask(Self.page()).merging(["more": 1]) { $1 }) == .failure(.unknown))
        #expect(Self.check(Self.ask(Self.page()).merging(["key": "pm-other"]) { $1 }) == .failure(.unknown))
        #expect(Self.check(["v": 1, "ask": "lines", "key": Self.key]) == .failure(.unknown))
        #expect(Self.check(["v": 1, "ask": "lines", "key": Self.key, "from": -1]) == .failure(.unknown))
        #expect(Self.check(["v": 1, "ask": "lines", "key": Self.key, "from": true]) == .failure(.unknown))
        #expect(Self.check(["v": 1, "ask": "lines", "key": Self.key, "from": 0]) == .success(.lines(key: Self.key, from: 0)))
        // from another page: framed, outside the games file, outside our folders
        let framed = GameBridge.Frame(isMain: false, scheme: "zim", host: GameSavesTests.games.uuidString.lowercased(), path: "/cardtable/index.html")
        let rules = GameBridge.Frame(isMain: true, scheme: "zim", host: GameSavesTests.games.uuidString.lowercased(), path: "/rules/hearts.html")
        let other = GameBridge.Frame(isMain: true, scheme: "zim", host: GameSavesTests.other.uuidString.lowercased(), path: "/cardtable/index.html")
        for (frame, why) in [(framed, GameBridge.Refusal.framed), (rules, .notOurs), (other, .elsewhere)] {
            #expect(Self.check(Self.ask(Self.page()), frame) == .failure(why))
            #expect(Self.check(["v": 1, "ask": "lines", "key": Self.key, "from": 0], frame) == .failure(why))
        }
    }

    @Test func theStoreKeepsALineOnceAndOnlyForPlayersOnTheList() throws {
        let folder = GameSavesTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var saves = GameSaves()
        _ = saves.read(gamesID: GameSavesTests.games, ours: GameSavesTests.ours)
        let lines = GameLines.load(folder), list = try Self.household()
        func send(_ line: [String: Any]) -> (reply: [String: Any], refused: GameBridge.Refusal?) {
            let a = saves.answer(Self.ask(line), from: GameSavesTests.main, players: list, lines: lines)
            return (a.reply, a.refused)
        }
        #expect(send(Self.page()).refused == nil)
        let again = send(Self.page())
        #expect(again.refused == nil && again.reply["again"] as? Bool == true, "kept already: not written again")
        #expect(lines.texts.count == 1)
        #expect(send(Self.page(Self.id(2), seat: 3)).refused == nil, "a retired player is still on the list")
        #expect(send(Self.page(Self.id(3), seat: 7)).refused == .noPlayer)
        #expect(send(Self.page(Self.id(4), more: ["seats": [1, Self.names[1], "Ember", "Flint"]])).refused == .badLine,
                "a nickname as a computer's name")
        #expect(send(Self.page(Self.id(5), seat: "guest")).refused == nil)
        #expect(lines.texts.count == 3)
        // an older app (no lines store) answers both asks as unknown
        let old = saves.answer(Self.ask(Self.page(Self.id(6))), from: GameSavesTests.main, players: list)
        #expect(old.refused == .unknown)
        // the file: this device's number, then the lines, never a nickname
        let text = try String(contentsOf: folder.appendingPathComponent(GameLines.fileName), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 4)
        let url = folder.appendingPathComponent(GameLines.fileName)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "out of the device's backup")
        for name in Self.names { #expect(!text.contains(name)) }
        let first = try JSONSerialization.jsonObject(with: Data(lines.texts[0].utf8)) as? [String: Any]
        #expect(first?["device"] as? String == lines.device && first?["count"] as? Int == 1 && first?["folder"] as? String == "cardtable")
        #expect((first?["kept"] as? Int ?? 0) > 1_700_000_000 && first?["v"] as? Int == 1)
    }

    @Test func theStoreSurvivesARelaunchAndSkipsBadLines() throws {
        let folder = GameSavesTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = GameLines.load(folder)
        #expect(lines.device == nil && lines.texts.isEmpty)
        for n in 1...3 { #expect(try lines.keep(GameLine.page(Self.page(Self.id(n)), folder: "cardtable")!)) }
        let device = try #require(lines.device)
        var again = GameLines.load(folder)
        #expect(again.device == device && again.texts == lines.texts && again.last == 3 && again.skipped == 0)
        // a damaged line in the middle and a torn last line (a power cut mid-append): each skipped and counted, never the
        // whole file, and the next line starts on a line of its own
        let url = folder.appendingPathComponent(GameLines.fileName)
        var text = try String(contentsOf: url, encoding: .utf8)
        var rows = text.split(separator: "\n").map(String.init)
        rows.insert("{not a line", at: 2)
        text = rows.joined(separator: "\n") + "\n" + String(rows[1].prefix(40))
        try Data(text.utf8).write(to: url)
        again = GameLines.load(folder)
        #expect(again.texts.count == 3 && again.skipped == 2 && again.device == device)
        #expect(try again.keep(GameLine.page(Self.page(Self.id(4)), folder: "cardtable")!))
        let after = GameLines.load(folder)
        #expect(after.texts.count == 4 && after.skipped == 2 && after.last == 4)
        // a line copied twice into the file counts once
        try Data((try String(contentsOf: url, encoding: .utf8) + after.texts[0] + "\n").utf8).write(to: url)
        #expect(GameLines.load(folder).texts.count == 4)
    }

    @Test func anUnreadableFileIsSetAsideNeverOverwritten() throws {
        let folder = GameSavesTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(GameLines.fileName)
        for damaged in [Data([0xff, 0xfe, 0x00]), Data("not this store's file\n".utf8), Data(#"{"v":2,"device":"x"}"#.utf8)] {
            try damaged.write(to: url)
            let lines = GameLines.load(folder)
            let aside = try #require(lines.setAside)
            #expect(aside.hasPrefix("game-lines-unreadable-") && aside.hasSuffix(".jsonl") && !lines.blocked && lines.texts.isEmpty)
            #expect(try Data(contentsOf: folder.appendingPathComponent(aside)) == damaged)
            #expect(try lines.keep(GameLine.page(Self.page(), folder: "cardtable")!), "a new file, with a new number")
            try FileManager.default.removeItem(at: url)
        }
    }

    @Test func theCapRefusesNewLinesAndTheBoardIsTold() throws {
        let folder = GameSavesTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = GameLines.load(folder)
        try lines.keep(GameLine.page(Self.page(Self.id(0)), folder: "cardtable")!)
        // the rest of the cap written straight into the file, each line as the store writes it
        var line = try JSONDecoder().decode(GameLine.self, from: Data(lines.texts[0].utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var text = ""
        for n in 1..<GameLines.most {
            line.id = Self.id(n)
            line.count = n + 1
            text += String(decoding: try encoder.encode(line), as: UTF8.self) + "\n"
        }
        let file = try FileHandle(forWritingTo: folder.appendingPathComponent(GameLines.fileName))
        try file.seekToEnd()
        try file.write(contentsOf: Data(text.utf8))
        try file.close()
        let full = GameLines.load(folder)
        #expect(full.texts.count == GameLines.most && full.full)
        var saves = GameSaves()
        _ = saves.read(gamesID: GameSavesTests.games, ours: GameSavesTests.ours)
        let list = try Self.household()
        let refused = saves.answer(Self.ask(Self.page(Self.id(GameLines.most + 5))), from: GameSavesTests.main,
                                   players: list, lines: full)
        #expect(refused.refused == .full)
        // one already kept is still answered as kept
        #expect(saves.answer(Self.ask(Self.page(Self.id(7))), from: GameSavesTests.main, players: list,
                             lines: full).reply["again"] as? Bool == true)
        let said = saves.answer(["v": 1, "ask": "lines", "key": Self.key, "from": 9_007_199_254_740_991], from: GameSavesTests.main,
                                players: list, lines: full).reply
        #expect(said["total"] as? Int == GameLines.most && said["most"] as? Int == GameLines.most)
    }

    @Test func linesComeInPagesWithEveryPlayerNamed() throws {
        let folder = GameSavesTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = GameLines.load(folder)
        for n in 1...1_200 { try lines.keep(GameLine.page(Self.page(Self.id(n)), folder: "cardtable")!) }
        var saves = GameSaves()
        _ = saves.read(gamesID: GameSavesTests.games, ours: GameSavesTests.ours)
        var from = 0, seen: [[String: Any]] = [], pages = 0
        let list = try Self.household()
        while true {
            let said = saves.answer(["v": 1, "ask": "lines", "key": Self.key, "from": from], from: GameSavesTests.main,
                                    players: list, lines: lines).reply
            let page = try #require(try JSONSerialization.jsonObject(with: Data((said["lines"] as? String ?? "").utf8)) as? [[String: Any]])
            seen += page
            pages += 1
            let players = said["players"] as? [[String: Any]] ?? []
            #expect(players.count == 3 && players.contains { $0["retired"] as? Bool == true }, "retired players named too")
            guard let next = said["next"] as? Int else { break }
            from = next
        }
        #expect(pages == 3 && seen.count == 1_200 && seen.map { $0["count"] as? Int ?? 0 } == Array(1...1_200))
    }
}
