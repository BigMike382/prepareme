import Foundation
import Testing
import WebKit
@testable import PrepareMeShared

/// The card table's lines (players plan, stage 3), the real page and kit in a real web view served the way the reader
/// serves the games file, with the app's bridge holding a made-up household: a finished game writes exactly one line
/// and none when the same game ends again after a reload; giving up asks once a hand has been played, and writes a
/// line that counts as a loss; the lesson, a seeded check and a Guest; each player's own unfinished game, with
/// today's single save going once to the first player chosen; and the four pairings of an app and a games file from
/// before stage 3 or after it. Never a nickname in a line or the store.
@MainActor
struct LinesCardTests {
    static let names = PlayersTests.names
    static let key = GameSavesTests.key

    enum App { case stage2, stage3 }
    enum File { case stage2, stage3 }

    /// A Hearts game in its fourth hand (no passing), the person on 0 and the others on 99: any hand ends it, and the
    /// person always wins it (whoever takes points but the person passes 100; all 26 to the person is the moon).
    static func lastHand(_ pm: [String: Any]? = nil) -> [String: Any] {
        var sv: [String: Any] = ["seed": 7, "handNo": 3, "scores": [0, 99, 99, 99], "rows": [[0, 26, 0, 0], [0, 0, 26, 0], [0, 0, 0, 26]],
                                 "pass": NSNull(), "moves": [Int](), "strength": "easy"]
        if let pm { sv["pm"] = pm }
        return sv
    }
    /// A Hearts game after its first hand.
    static let secondHand: [String: Any] = ["seed": 11, "handNo": 1, "scores": [5, 9, 12, 0], "rows": [[5, 9, 12, 0]], "pass": NSNull(),
                                            "moves": [Int](), "strength": "medium"]
    static let cast = ["Briar", "Ember", "Flint"]

    /// The table's whole save with `sv` as `who`'s unfinished Hearts, the game open (a reload goes straight back to it).
    static func table(_ sv: [String: Any], who: Any = 1, open: Bool = true) -> [String: Any] {
        ["player": who, "game": "hearts", "open": open ? "hearts" : "", "strength": "easy",
         "held": ["\(who)": ["saves": ["hearts": sv], "cast": ["hearts": cast]]]]
    }

    @MainActor
    final class Device {
        let storage = WKWebsiteDataStore.nonPersistent()
        let bridge = GameSavesTests.Bridge(ours: GameSavesTests.ours)
        var n = 1000

        init() throws { bridge.players = try PlayersCardTests.household() }

        /// The table's save put in the app's store, counted past anything the page holds.
        func give(_ data: [String: Any]) throws {
            n += 1000
            let text = String(data: try JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
            bridge.store.saves[LinesCardTests.key] = GameSaves.Kept(n: n, save: text)
        }

        func open(app: App = .stage3, file: File = .stage3, options: String = "") async throws -> WKWebView {
            bridge.beforeLines = app == .stage2
            let games = GameSavesTests.repo.appendingPathComponent("games"), fixtures = GameSavesTests.fixtures
            let kit = file == .stage3 ? games.appendingPathComponent("kit/kit.js") : fixtures.appendingPathComponent("kit-before-lines.js")
            let table = file == .stage3 ? games.appendingPathComponent("cardtable/table.js") : fixtures.appendingPathComponent("table-before-lines.js")
            let view = try await PlayersCardTests.Card.open(GameSavesTests.at("cardtable/index.html?table=flat&fast=1" + options),
                                                            bridge: bridge, storage: storage,
                                                            swap: ["/kit/kit.js": try Data(contentsOf: kit),
                                                                   "/cardtable/table.js": try Data(contentsOf: table)], seen: true)
            try await PlayersCardTests.Card.waitFor(view, "document.getElementById('paper').childElementCount > 0 || document.getElementById('hand').childElementCount > 0")
            return view
        }

        func lines() -> [[String: Any]] {
            bridge.lines.texts.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }

    /// The person's cards played until a score pad says who won (or the lesson's last pad): a card that may be played
    /// is pressed whenever one is offered, and a ready Pass button too. Returns the pad's headline.
    static func playOut(_ view: WKWebView, until: String = "win") async throws -> String {
        for _ in 0..<600 {
            let said = try await view.evaluateJavaScript("""
                (function () {
                  var veil = document.getElementById('veil'), go = document.getElementById('go');
                  if (!veil.hidden) { var h = document.querySelector('#paper h1'); return h ? h.textContent : ''; }
                  if (!go.hidden && !go.disabled) { go.click(); return ''; }
                  var b = Array.prototype.filter.call(document.querySelectorAll('#hand button'), function (b) {
                    return !/can.t be played now/.test(b.getAttribute('aria-label') || ''); })[0];
                  if (b) b.click();
                  return '';
                })()
                """) as? String ?? ""
            if said.contains(until) { return said }
            try await Task.sleep(for: .milliseconds(30))
        }
        Issue.record("the hand never ended")
        return ""
    }
    static func headline(_ view: WKWebView) async throws -> String {
        try await view.evaluateJavaScript("(document.querySelector('#paper h1') || {}).textContent || ''") as? String ?? ""
    }
    static func page(_ view: WKWebView) async throws -> [String: Any] {
        let text = try await view.evaluateJavaScript("localStorage.getItem('pm-cardtable') || '{}'") as? String ?? "{}"
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(600)) }
    static func noNicknames(_ device: Device) {
        for text in device.bridge.lines.texts { for name in names { #expect(!text.contains(name), "a nickname in a line") } }
    }

    @Test func aFinishedGameWritesOneLineAndNoneWhenItEndsAgain() async throws {
        let device = try Device()
        let start = Int(Date().timeIntervalSince1970)
        try device.give(Self.table(Self.lastHand()))  // a game under way before lines: no pm yet
        let card = try await device.open()
        #expect(try await Self.playOut(card) == "You win")
        try await Self.settle()
        let lines = device.lines()
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line["seats"] as? [AnyHashable] == [1, "Briar", "Ember", "Flint"])
        #expect(line["how"] as? String == "finished" && line["winners"] as? [Int] == [0] && line["hands"] as? Int == 4)
        #expect(line["game"] as? String == "hearts" && line["folder"] as? String == "cardtable" && line["strength"] as? String == "easy")
        #expect(line["rules"] as? Int == 1 && line["goal"] as? Int == 100 && line["players"] as? Int == 4 && line["by"] == nil)
        let began = line["began"] as? Int ?? 0, ended = line["ended"] as? Int ?? 0
        #expect(began >= start - 2 && ended >= began, "a game under way takes the moment it is first picked up")
        let scores = line["scores"] as? [Int] ?? []
        #expect(scores.count == 4 && scores[0] < scores[1...].min()! && scores[1...].allSatisfy { $0 >= 99 })
        let id = try #require(line["id"] as? String)
        #expect(id.count == 32)
        // the record counted from the line, not page storage: no old totals written
        let records = (try await Self.page(card))["records"] as? [String: Any] ?? [:]
        #expect(records.isEmpty)
        // the same game loaded again and ended again (its save, with its line's number): answered "again", nothing written
        try device.give(Self.table(Self.lastHand(["id": id, "began": began, "seat": 1])))
        let again = try await device.open()
        #expect(try await Self.playOut(again) == "You win")
        try await Self.settle()
        #expect(device.lines().count == 1, "a game ended twice is one line")
        #expect(device.bridge.refused.isEmpty, "\(device.bridge.refused)")
        Self.noNicknames(device)
    }

    @Test func givingUpAsksOnceAHandIsPlayedAndCountsAsALoss() async throws {
        let device = try Device()
        try device.give(Self.table(Self.secondHand))
        let card = try await device.open()
        try await PlayersCardTests.Card.waitFor(card, "document.getElementById('veil').hidden")
        try await PlayersCardTests.press(card, "Menu")
        try await PlayersCardTests.press(card, "New game")
        #expect(try await Self.headline(card) == "Give up this game?")
        #expect(try await PlayersCardTests.text(card, "document.getElementById('paper').textContent").contains("It counts as a loss for \(Self.names[0])."))
        try await PlayersCardTests.press(card, "Cancel")
        #expect(try await Self.headline(card) == "Hearts", "Cancel goes back to the menu")
        #expect(device.lines().isEmpty)
        try await PlayersCardTests.press(card, "New game")
        try await PlayersCardTests.press(card, "Give up")
        try await Self.settle()
        let line = try #require(device.lines().first)
        #expect(line["how"] as? String == "given up" && line["by"] as? Int == 0 && line["winners"] as? [Int] == [])
        #expect(line["scores"] as? [Int] == [5, 9, 12, 0] && line["hands"] as? Int == 1 && line["strength"] as? String == "medium")
        // a new game dealt in its place, with a line number of its own
        let held = ((try await Self.page(card))["held"] as? [String: Any])?["1"] as? [String: Any]
        let pm = ((held?["saves"] as? [String: Any])?["hearts"] as? [String: Any])?["pm"] as? [String: Any]
        #expect(pm?["id"] as? String != nil && pm?["id"] as? String != line["id"] as? String)
        // before a hand has been played: nothing asked, nothing written
        try await PlayersCardTests.press(card, "Menu")
        try await PlayersCardTests.press(card, "New game")
        #expect(try await card.evaluateJavaScript("document.getElementById('veil').hidden") as? Bool == true)
        try await Self.settle()
        #expect(device.lines().count == 1)
        Self.noNicknames(device)
    }

    @Test func theOpeningCardsNewGameAsksToo() async throws {
        let device = try Device()
        try device.give(Self.table(Self.secondHand, open: false))
        let card = try await device.open()
        #expect(try await Self.headline(card) == "The Card Table")
        try await PlayersCardTests.press(card, "New game")
        #expect(try await Self.headline(card) == "Give up this game?")
        try await PlayersCardTests.press(card, "Cancel")
        #expect(try await Self.headline(card) == "The Card Table")
        try await PlayersCardTests.press(card, "Continue")  // changing nothing gave nothing up
        try await Self.settle()
        #expect(device.lines().isEmpty)
    }

    @Test func noLineFromTheLessonOrASeededCheckAndAGuestsIsKept() async throws {
        let device = try Device()
        try device.give(["player": 1, "game": "hearts"])
        var card = try await device.open()
        try await PlayersCardTests.press(card, "Show me how")
        #expect(try await Self.playOut(card, until: "hand of Hearts").contains("hand of Hearts"))
        try await Self.settle()
        #expect(device.lines().isEmpty, "the lesson writes no line")
        // a check that gives a seed: no line either (and the old record counts it, as before players)
        try device.give(Self.table(Self.lastHand()))
        card = try await device.open(options: "&seed=7")
        _ = try await Self.playOut(card)
        try await Self.settle()
        #expect(device.lines().isEmpty, "a seeded game writes no line")
        // a Guest's game: kept, its seat 'guest'
        try device.give(Self.table(Self.lastHand(), who: "guest"))
        card = try await device.open()
        #expect(try await Self.playOut(card) == "You win")
        try await Self.settle()
        let line = try #require(device.lines().first)
        #expect((line["seats"] as? [Any])?.first as? String == "guest")
    }

    @Test func eachPlayerKeepsTheirOwnGame() async throws {
        let device = try Device()
        // today's single save, from the table before lines: it goes, once, to the first player chosen
        try device.give(["player": 1, "game": "hearts", "saves": ["hearts": Self.secondHand], "cast": ["hearts": Self.cast]])
        device.bridge.store.usual = 1
        var card = try await device.open()
        #expect(try await PlayersCardTests.text(card, "document.getElementById('paper').textContent").contains("Continue"))
        var data = try await Self.page(card)
        #expect((data["saves"] as? [String: Any])?.isEmpty == true)
        #expect((((data["held"] as? [String: Any])?["1"] as? [String: Any])?["saves"] as? [String: Any])?["hearts"] != nil)
        // another player: none of their own yet; they deal one
        try await PlayersCardTests.press(card, Self.names[1])
        try await PlayersCardTests.press(card, "Play as")
        #expect(try await !PlayersCardTests.text(card, "document.getElementById('paper').textContent").contains("Continue"))
        try await PlayersCardTests.dealAndLeave(card)
        #expect(try await PlayersCardTests.text(card, "document.getElementById('paper').textContent").contains("Continue"))
        // back to the first (the usual player: no question): their own game, the second hand, still there
        try await PlayersCardTests.press(card, Self.names[0])
        let words = try await PlayersCardTests.text(card, "document.getElementById('paper').textContent")
        #expect(words.contains("Continue") && words.contains("Hand 2 of a game to 100 on medium"))
        data = try await Self.page(card)
        let held = data["held"] as? [String: Any] ?? [:]
        #expect(Set(held.keys) == ["1", "2"])
        // a player no longer on the list: their game stays, untouched and unseen
        var list = try PlayersCardTests.household()
        try list.retire(2)
        device.bridge.players = list
        try await Task.sleep(for: .milliseconds(300))
        card = try await device.open()
        try await Self.settle()
        let after = (try await Self.page(card))["held"] as? [String: Any] ?? [:]
        #expect(after["2"] != nil)
        // never a nickname in the page's storage
        let text = try await card.evaluateJavaScript("localStorage.getItem('pm-cardtable') || ''") as? String ?? ""
        for name in Self.names { #expect(!text.contains(name)) }
    }

    /// The older table's one save goes to the device's usual player, never to whoever is picked (2026-11-19: the owner's
    /// Draw4 game went to the player picked when the new table first opened).
    @Test func theOlderSingleSaveGoesToTheUsualPlayerNotWhoeverIsPicked() async throws {
        let device = try Device()
        try device.give(["player": 2, "game": "hearts", "saves": ["hearts": Self.secondHand], "cast": ["hearts": Self.cast]])
        device.bridge.store.usual = 1
        let card = try await device.open()
        let words = try await PlayersCardTests.text(card, "document.getElementById('paper').textContent")
        #expect(words.contains("Deal") && !words.contains("Continue"))
        let data = try await Self.page(card)
        let held = data["held"] as? [String: Any] ?? [:]
        #expect(data["player"] as? Int == 2)
        #expect(((held["1"] as? [String: Any])?["saves"] as? [String: Any])?["hearts"] != nil)
        #expect(((held["2"] as? [String: Any])?["saves"] as? [String: Any])?["hearts"] == nil)
        #expect((data["saves"] as? [String: Any])?.isEmpty == true)
        try await PlayersCardTests.press(card, Self.names[0])
        #expect(try await PlayersCardTests.text(card, "document.getElementById('paper').textContent").contains("Continue"))
    }

    /// A player who already holds that game keeps it, and the older one stays where it was, untouched (Draw4 here).
    @Test func anOlderSaveNeverReplacesOrDropsAGameTheUsualPlayerHolds() async throws {
        let device = try Device()
        let mine = ["seed": 11, "handNo": 1, "scores": [5, 9, 12, 0], "rows": [[5, 9, 12, 0]], "moves": [Int](), "strength": "medium", "players": 3] as [String: Any]
        var older = mine; older["seed"] = 12
        try device.give(["player": 1, "game": "eights", "saves": ["eights": older], "cast": ["eights": Self.cast],
                         "held": ["1": ["saves": ["eights": mine], "cast": ["eights": Self.cast]]]])
        device.bridge.store.usual = 1
        let card = try await device.open()
        let data = try await Self.page(card)
        let held = (data["held"] as? [String: Any])?["1"] as? [String: Any]
        #expect((((held?["saves"]) as? [String: Any])?["eights"] as? [String: Any])?["seed"] as? Int == 11)
        #expect(((data["saves"] as? [String: Any])?["eights"] as? [String: Any])?["seed"] as? Int == 12)
    }

    @Test func theRecordCardCountsTheLinesAndKeepsTheOldTotalsApart() async throws {
        let device = try Device()
        var data = Self.table(Self.lastHand())
        data["records"] = ["hearts": ["easy": ["played": 9, "won": 4, "streak": 0, "best": 2]]]
        try device.give(data)
        let card = try await device.open()
        #expect(try await Self.playOut(card) == "You win")
        try await Self.settle()
        try await PlayersCardTests.press(card, "Choose a game")
        try await PlayersCardTests.press(card, "Record")
        try await PlayersCardTests.Card.waitFor(card, "document.querySelectorAll('#paper table').length === 2")
        let rows = try await card.evaluateJavaScript("""
            Array.prototype.map.call(document.querySelectorAll('#paper table'), function (t) {
              return Array.prototype.map.call(t.querySelectorAll('tr'), function (r) {
                return Array.prototype.map.call(r.children, function (c) { return c.textContent; }).join('|'); }).join(' / '); })
            """) as? [String] ?? []
        let low = (device.lines().first?["scores"] as? [Int])?.first ?? -1
        #expect(rows.first == "|Played|Won|Given up|Best run|Lowest win|All 26 / Easy|1|1|0|1|\(low)|\(low == 0 ? 1 : 0)", "\(rows)")
        #expect(rows.last?.contains("Easy|9|4|2") == true, "the old totals, as they were")
        let words = try await PlayersCardTests.text(card, "document.getElementById('paper').textContent")
        #expect(words.contains("Hearts, \(Self.names[0]), on this device.") && words.contains("Before players, on this device"))
        // a Guest: no record on the board
        try await PlayersCardTests.press(card, "Back")
        try await PlayersCardTests.press(card, "Guest")
        try await PlayersCardTests.press(card, "Record")
        try await PlayersCardTests.Card.waitFor(card, "document.getElementById('paper').textContent.indexOf('A guest') >= 0")
    }

    @Test func theScoreboardShowsThisDevicesGames() async throws {
        let bridge = GameSavesTests.Bridge(ours: ["cardtable", "scoreboard"])
        bridge.players = try PlayersCardTests.household()  // the fourth retired
        let now = Int(Date().timeIntervalSince1970)
        for (n, seat) in [(1, 1 as Any), (2, 1), (3, 2), (4, 4), (5, "guest")] {
            let page = GameLinesTests.page(GameLinesTests.id(n), seat: seat, more: ["began": now - 900, "ended": now - 600 + n,
                                                                                     "winners": [n == 2 ? 1 : 0]])
            try bridge.lines.keep(try #require(GameLine.page(page, folder: "cardtable")))
        }
        let kit = try Data(contentsOf: GameSavesTests.repo.appendingPathComponent("games/kit/kit.js"))
        let view = try await PlayersCardTests.Card.open(GameSavesTests.at("scoreboard/index.html?fast=1"), bridge: bridge,
                                                        storage: .nonPersistent(), swap: ["/kit/kit.js": kit], seen: true)
        try await PlayersCardTests.Card.waitFor(view, "document.querySelector('table.sb-t')")
        let heads = try await view.evaluateJavaScript("""
            Array.prototype.map.call(document.querySelectorAll('#sb-board > table.sb-t tbody tr'), function (r) {
              return Array.prototype.map.call(r.children, function (c) { return c.textContent; }).join('|'); })
            """) as? [String] ?? []
        let n = Self.names
        #expect(heads == ["\(n[1].prefix(1).uppercased())\(n[1])|1|1|100%|0|1|1", "\(n[3].prefix(1).uppercased())\(n[3]) retired|1|1|100%|0|1|1",
                          "\(n[0].prefix(1).uppercased())\(n[0])|2|1|50%|0|1|0"], "the best share first, a retired player marked, no Guest")
        let words = try await PlayersCardTests.text(view, "document.body.textContent")
        #expect(words.contains("This device’s games only.") && words.contains("Against the computer players") && !words.contains("Guest"))
        // more lines than one page of the app's answer (500): every page is read before the board is whole
        for n in 6...1105 {
            let page = GameLinesTests.page(GameLinesTests.id(n), seat: 1, more: ["began": now - 900, "ended": now - 600])
            try bridge.lines.keep(try #require(GameLine.page(page, folder: "cardtable")))
        }
        let many = try await PlayersCardTests.Card.open(GameSavesTests.at("scoreboard/index.html?fast=1"), bridge: bridge,
                                                        storage: .nonPersistent(), swap: ["/kit/kit.js": kit], seen: true)
        try await PlayersCardTests.Card.waitFor(many, "document.querySelector('table.sb-t') && document.body.textContent.indexOf('Counting') < 0")
        let top = try await PlayersCardTests.text(many, "Array.prototype.map.call(document.querySelector('#sb-board > table.sb-t tbody tr').children, function (c) { return c.textContent; }).join('|')")
        #expect(top == "\(n[0].prefix(1).uppercased())\(n[0])|1102|1101|100%|0|1100|1100", "every page counted")
        // an app from before lines: the board says so, and counts nothing from page storage
        bridge.beforeLines = true
        let old = try await PlayersCardTests.Card.open(GameSavesTests.at("scoreboard/index.html?fast=1"), bridge: bridge,
                                                       storage: .nonPersistent(), swap: ["/kit/kit.js": kit], seen: true)
        try await PlayersCardTests.Card.waitFor(old, "document.body.textContent.indexOf('needs a newer PrepareMe') >= 0")
    }

    /// The four pairings: an app and a games file each from stage 2 (before lines) or stage 3. Only the newest pair
    /// writes a line; every other plays as before, its game counted in the page's own record, nothing lost.
    @Test func theFourPairings() async throws {
        // the stage 2 app with the new games file: the line is refused as unknown, the old record counts it
        var device = try Device()
        try device.give(Self.table(Self.lastHand()))
        var card = try await device.open(app: .stage2)
        #expect(try await Self.playOut(card) == "You win")
        try await Self.settle()
        #expect(device.lines().isEmpty)
        var records = (try await Self.page(card))["records"] as? [String: [String: [String: Int]]]
        #expect(records?["hearts"]?["easy"]?["played"] == 1 && records?["hearts"]?["easy"]?["won"] == 1)
        // the stage 3 app with the stage 2 games file: nothing asks for lines, nothing breaks, the record counts it
        for app in [App.stage3, .stage2] {
            device = try Device()
            try device.give(["player": 1, "game": "hearts", "open": "hearts", "saves": ["hearts": Self.lastHand()], "cast": ["hearts": Self.cast]])
            card = try await device.open(app: app, file: .stage2)
            #expect(try await Self.playOut(card) == "You win")
            try await Self.settle()
            #expect(device.lines().isEmpty && device.bridge.refused[.unknown, default: 0] == 0, "\(app)")
            records = (try await Self.page(card))["records"] as? [String: [String: [String: Int]]]
            #expect(records?["hearts"]?["easy"]?["played"] == 1)
        }
    }
}
