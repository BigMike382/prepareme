import Foundation
import Testing
import WebKit
@testable import PrepareMeShared

/// The game bridge and the app's store for saves (players plan, stage 1): the rule of which pages are ours, held to
/// the same cases in Swift and in the page script; every message refused from anywhere else; the checks of kind and
/// size; the store across a close and a later build; and the real kit.js through all four pairings of an old or new
/// app with an old or new games file, in a real web view served the way the reader serves the games file. Stage 1b:
/// the counts (the newest save wins wherever it is), two pages of one game, the list missing and back, the way back
/// from an older app or games file, an unreadable store, and a save the app never answers.
@MainActor
struct GameSavesTests {
    static let games = UUID(uuidString: "0F1E2D3C-4B5A-4968-8776-6554433221C9")!
    static let other = UUID(uuidString: "0F1E2D3C-4B5A-4968-8776-6554433221B1")!
    static let ours = ["cardtable"]
    static let key = "pm-cardtable"
    static func at(_ path: String, _ id: UUID = games) -> String { "zim://\(id.uuidString.lowercased())/\(path)" }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/games")
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// (path in the games file, the folder of ours it is in)
    static let cases: [(String, String?)] = [
        ("cardtable/index.html", "cardtable"),
        ("/cardtable/sub/page.html", "cardtable"),
        ("cardtable/", "cardtable"),
        ("index.html", nil),  // the Games list
        ("rules/hearts.html", nil),  // a printable rules page
        ("zimi/2048/index.html", nil),  // a third-party game
        ("kit/kit.js", nil),  // the kit is no game
        ("cardtable", nil),  // not inside the folder
        ("cardtablex/index.html", nil),
        ("cardtable/../zimi/index.html", nil),
    ]

    // MARK: The rule, the list, the checks

    @Test func theRule() {
        for (path, folder) in Self.cases {
            #expect(GameBridge.folder(of: path, ours: Self.ours) == folder, "\(path)")
        }
        #expect(GameBridge.folder(of: "cardtable/index.html", ours: []) == nil)
    }

    @Test func thePageScriptJoinsTheSamePages() async throws {
        for (path, folder) in Self.cases where !path.contains("..") {  // a web view folds "..": the Swift rule refuses it
            let view = try await Page.open(Self.at(path), bridge: Bridge(ours: Self.ours))
            let mark = try await view.evaluateJavaScript("document.documentElement.getAttribute('data-pm-games')")
            #expect((mark as? String) == folder.map(GameBridge.key(of:)), "\(path)")
        }
        let elsewhere = try await Page.open(Self.at("cardtable/index.html", Self.other), bridge: Bridge(ours: Self.ours))
        #expect(try await elsewhere.evaluateJavaScript("document.documentElement.hasAttribute('data-pm-games')") as? Bool
                == false)
    }

    @Test func theListOfOurOwnGames() {
        let read = { (text: String) in GameBridge.ours(from: Data(text.utf8)) }
        #expect(read(#"{"ours": ["cardtable", "draw-4"]}"#) == ["cardtable", "draw-4"])
        #expect(read(#"{"ours": []}"#) == [])
        #expect(GameBridge.ours(from: nil) == nil)  // a games file from before stage 1
        for wrong in [#"{"ours": ["Cardtable"]}"#, #"{"ours": ["kit"]}"#, #"{"ours": ["rules"]}"#, #"{"ours": ["a/b"]}"#,
                      #"{"ours": ["x", "x"]}"#, #"{"ours": "cardtable"}"#, #"{"ours": [], "more": 1}"#, #"["cardtable"]"#,
                      #"{"ours": [""]}"#, "{\"ours\": [\"\(String(repeating: "a", count: 41))\"]}", "not json"] {
            #expect(read(wrong) == nil, "\(wrong)")
        }
        let many = (0...GameBridge.oursMost).map { "g\($0)" }
        #expect(GameBridge.ours(from: try! JSONSerialization.data(withJSONObject: ["ours": many])) == nil)
    }

    static let main = GameBridge.Frame(isMain: true, scheme: "zim", host: games.uuidString.lowercased(),
                                       path: "/cardtable/index.html")

    @Test func messagesAreCheckedForKindAndSize() {
        let check = { (body: Any, frame: GameBridge.Frame) in
            GameBridge.check(body, from: frame, gamesID: Self.games, ours: Self.ours)
        }
        let keep: [String: Any] = ["v": 1, "ask": "keep", "key": Self.key, "save": #"{"a":1}"#, "n": 1]
        let give: [String: Any] = ["v": 1, "ask": "give", "key": Self.key]
        #expect(check(keep, Self.main) == .success(.keep(key: Self.key, save: #"{"a":1}"#, n: 1)))
        #expect(check(keep.merging(["n": 0]) { $1 }, Self.main) == .success(.keep(key: Self.key, save: #"{"a":1}"#, n: 0)))
        #expect(check(keep.merging(["n": GameBridge.countMost]) { $1 }, Self.main)
                == .success(.keep(key: Self.key, save: #"{"a":1}"#, n: GameBridge.countMost)))
        #expect(check(give, Self.main) == .success(.give(key: Self.key)))
        var framed = Self.main
        framed.isMain = false
        #expect(check(give, framed) == .failure(.framed))
        for (scheme, host) in [("zim", Self.other.uuidString), ("http", Self.games.uuidString), ("zim", "")] {
            var frame = Self.main
            frame.scheme = scheme
            frame.host = host
            #expect(check(give, frame) == .failure(.elsewhere), "\(scheme) \(host)")
        }
        #expect(GameBridge.check(give, from: Self.main, gamesID: nil, ours: Self.ours) == .failure(.elsewhere))
        for path in ["/index.html", "/rules/hearts.html", "/zimi/2048/index.html", "/kit/x.html", "/cardtable"] {
            var frame = Self.main
            frame.path = path
            #expect(check(give, frame) == .failure(.notOurs), "\(path)")
        }
        let limit = String(repeating: "x", count: GameBridge.saveLimit - 2)
        #expect(check(keep.merging(["save": "\"\(limit)\""]) { $1 }, Self.main) != .failure(.tooBig))
        #expect(check(keep.merging(["save": "\"\(limit)x\""]) { $1 }, Self.main) == .failure(.tooBig))
        let wrong: [Any] = [
            keep.merging(["v": 2]) { $1 }, keep.merging(["v": true]) { $1 }, keep.merging(["v": "1"]) { $1 },
            keep.merging(["key": "pm-other"]) { $1 }, keep.merging(["key": "cardtable"]) { $1 },
            keep.merging(["more": 1]) { $1 }, keep.merging(["save": 5]) { $1 }, keep.merging(["save": "{not json"]) { $1 },
            keep.filter { $0.key != "save" }, give.merging(["save": "{}"]) { $1 }, give.merging(["ask": "players", "n": 1]) { $1 },
            keep.filter { $0.key != "n" }, keep.merging(["n": true]) { $1 }, keep.merging(["n": -1]) { $1 },
            keep.merging(["n": 1.5]) { $1 }, keep.merging(["n": "1"]) { $1 }, keep.merging(["n": NSNull()]) { $1 },
            keep.merging(["n": Double(GameBridge.countMost) * 2]) { $1 }, give.merging(["n": 1]) { $1 },
            give.merging(["ask": "line"]) { $1 }, give.filter { $0.key != "v" }, "keep", [keep], NSNull(),
        ]
        for body in wrong { #expect(check(body, Self.main) == .failure(.unknown), "\(body)") }
    }

    // MARK: The store

    @Test func theStoreSurvivesClosingAndReopening() throws {
        let folder = Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var store = GameSaves()
        let read = store.read(gamesID: Self.games, ours: Self.ours), again = store.read(gamesID: Self.games, ours: Self.ours)
        #expect(read && !again)
        let keep: [String: Any] = ["v": 1, "ask": "keep", "key": Self.key, "save": #"{"hand":2}"#, "n": 1]
        let first = store.answer(keep, from: Self.main).changed, same = store.answer(keep, from: Self.main)
        #expect(first && !same.changed && same.refused == nil)  // the same save again: yes, nothing to write
        try store.save(folder)
        let back = GameSaves.load(folder)
        #expect(back == store)
        #expect(back.saves[Self.key] == GameSaves.Kept(n: 1, save: #"{"hand":2}"#))
        let url = folder.appendingPathComponent(GameSaves.fileName)
        // in the device's backup (audit D1; owner, 2026-11-22), and an earlier build's mark is taken off when read
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
        try EarlierBuild.leaveBackupMark(on: url)
        _ = GameSaves.load(folder)
        #expect(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup == false)
        #expect(GameSaves.load(Self.scratch()) == GameSaves())  // no file: an empty store
    }

    /// A store written by the first build that had it: every later build reads it (add fields, never rename these).
    @Test func aLaterBuildReadsTheFirstBuildsFile() {
        let folder = Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("game-saves-v1.json"),
                                          to: folder.appendingPathComponent(GameSaves.fileName))
        let store = GameSaves.load(folder)
        #expect(store.games == Self.games)
        #expect(store.ours == Self.ours)
        #expect(store.saves[Self.key] == GameSaves.Kept(n: 0, save: #"{"name":"Sample","hand":3}"#))  // stage 1: count 0
        #expect(store.version == GameSaves.current && store.setAside == nil)
    }

    /// The count decides: a save is taken only over a lower count; the same save again is yes and changes nothing;
    /// anything else at or under the count held is refused as older, whatever its text.
    @Test func theNewestSaveWins() {
        var store = GameSaves()
        _ = store.read(gamesID: Self.games, ours: Self.ours)
        let keep = { (save: String, n: Int) -> [String: Any] in ["v": 1, "ask": "keep", "key": Self.key, "save": save, "n": n] }
        #expect(store.answer(keep("{\"hand\":1}", 1), from: Self.main).changed)
        #expect(store.answer(keep("{\"hand\":3}", 3), from: Self.main).changed)  // a count may jump
        let same = store.answer(keep("{\"hand\":3}", 3), from: Self.main)
        #expect(!same.changed && same.refused == nil && NSDictionary(dictionary: same.reply) == ["ok": true])
        for (save, n) in [("{\"hand\":2}", 2), ("{\"hand\":9}", 3), ("{\"hand\":1}", 1), ("{\"hand\":0}", 0)] {
            let older = store.answer(keep(save, n), from: Self.main)
            #expect(!older.changed && older.refused == .older, "\(n)")
            #expect(NSDictionary(dictionary: older.reply) == ["ok": false, "why": GameBridge.Refusal.older.rawValue])
        }
        #expect(store.saves[Self.key] == GameSaves.Kept(n: 3, save: "{\"hand\":3}"))
        let give = store.answer(["v": 1, "ask": "give", "key": Self.key], from: Self.main)
        #expect(NSDictionary(dictionary: give.reply) == ["ok": true, "save": "{\"hand\":3}", "n": 3])
    }

    /// A store that can't be read is renamed aside with the date and never overwritten; the store starts empty. If
    /// even the rename fails, the store won't write at all.
    @Test func anUnreadableStoreIsSetAsideNeverOverwritten() throws {
        let when = Date(timeIntervalSince1970: 1_795_000_000)
        for bad in ["not json", #"{"version": 3, "saves": {}}"#, #"{"version": 2, "saves": {"pm-cardtable": "text"}}"#] {
            let folder = Self.scratch()
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(GameSaves.fileName)
            try Data(bad.utf8).write(to: url)
            var store = GameSaves.load(folder, now: when)
            let aside = try #require(store.setAside, "\(bad)")
            #expect(aside.hasPrefix("game-saves-unreadable-") && aside.hasSuffix(".json"))
            #expect(store.saves.isEmpty && !store.blocked)
            #expect(try String(contentsOf: folder.appendingPathComponent(aside), encoding: .utf8) == bad)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            _ = store.read(gamesID: Self.games, ours: Self.ours)
            try store.save(folder)  // a new store beside the one set aside
            #expect(try String(contentsOf: folder.appendingPathComponent(aside), encoding: .utf8) == bad)
            #expect(GameSaves.load(folder).games == Self.games)
            let again = try Data("not json".utf8)
            try again.write(to: url)
            #expect(GameSaves.load(folder, now: when).setAside == aside.replacingOccurrences(of: ".json", with: "-1.json"))
        }
        // the rename refused (a folder that can't be written): nothing is ever written over the file
        let folder = Self.scratch()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(GameSaves.fileName)
        try Data("not json".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = GameSaves.load(folder, now: when)
        #expect(store.blocked && store.setAside == nil)
        #expect(throws: (any Error).self) { try store.save(folder) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }

    /// A store that is there but can't be read at all (still locked after a restart) isn't damaged (audit D3): it is
    /// left where it is, never set aside, and this run never writes over it.
    @Test func aStoreThatCantBeReadNowIsLeftAlone() throws {
        let folder = Self.scratch()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(GameSaves.fileName)
        try Data(#"{"version": 2, "saves": {}}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = GameSaves.load(folder)
        #expect(store.blocked && store.setAside == nil)
        #expect(throws: (any Error).self) { try store.save(folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [GameSaves.fileName])
    }

    // MARK: The bridge in a real web view

    @Test func aPageOfOursKeepsItsSaveAndGetsItBack() async throws {
        let bridge = Bridge(ours: Self.ours)
        let view = try await Page.open(Self.at("cardtable/index.html"), bridge: bridge)
        #expect(try await Page.ask(view, ["v": 1, "ask": "give", "key": Self.key])
                == ["ok": true, "save": NSNull(), "n": NSNull()])
        #expect(try await Page.ask(view, ["v": 1, "ask": "keep", "key": Self.key, "save": #"{"hand":7}"#, "n": 4])
                == ["ok": true])
        #expect(try await Page.ask(view, ["v": 1, "ask": "give", "key": Self.key])
                == ["ok": true, "save": #"{"hand":7}"#, "n": 4])
        #expect(GameSaves.load(bridge.folder).saves[Self.key] == GameSaves.Kept(n: 4, save: #"{"hand":7}"#))
        // the next page opened starts with it and its count, before its own scripts
        let next = try await Page.open(Self.at("cardtable/index.html"), bridge: bridge)
        #expect(try await next.evaluateJavaScript("document.documentElement.getAttribute('data-pm-save')") as? String
                == #"{"hand":7}"#)
        #expect(try await next.evaluateJavaScript("document.documentElement.getAttribute('data-pm-n')") as? String == "4")
        // and the page's own scripts never see the handler
        #expect(try await view.evaluateJavaScript("typeof (window.webkit && window.webkit.messageHandlers.pmGame)")
                as? String == "undefined")
    }

    @Test func oversizeAndWrongShapedMessagesAreRefusedFromAPageOfOurs() async throws {
        let bridge = Bridge(ours: Self.ours)
        let view = try await Page.open(Self.at("cardtable/index.html"), bridge: bridge)
        let big = "\"" + String(repeating: "x", count: GameBridge.saveLimit) + "\""
        #expect(try await Page.ask(view, ["v": 1, "ask": "keep", "key": Self.key, "save": big, "n": 1])
                == ["ok": false, "why": GameBridge.Refusal.tooBig.rawValue])
        for wrong: [String: Any] in [["v": true, "ask": "give", "key": Self.key], ["v": 1, "ask": "players"],
                                     ["v": 1, "ask": "keep", "key": Self.key, "save": "{oops", "n": 1],
                                     ["v": 1, "ask": "keep", "key": Self.key, "save": ["a": 1], "n": 1]] {
            #expect(try await Page.ask(view, wrong) == ["ok": false, "why": GameBridge.Refusal.unknown.rawValue],
                    "\(wrong)")
        }
        #expect(bridge.refused[.unknown] == 4 && bridge.refused[.tooBig] == 1)
        #expect(GameSaves.load(bridge.folder).saves.isEmpty)
    }

    /// The Games list, a rules page, a third-party game, the kit, another file's page of the same path: each sends
    /// every message both ways a page could (its own scripts' event, and straight to the handler from the bridge's
    /// world, which no page can reach but a test can); nothing is answered yes and nothing is kept.
    @Test func everyOtherPageIsRefused() async throws {
        let bridge = Bridge(ours: Self.ours)
        let pages: [(String, GameBridge.Refusal)] = [
            (Self.at("index.html"), .notOurs), (Self.at("rules/hearts.html"), .notOurs),
            (Self.at("zimi/2048/index.html"), .notOurs), (Self.at("kit/page.html"), .notOurs),
            (Self.at("cardtable/index.html", Self.other), .elsewhere),
        ]
        for (address, why) in pages {
            let view = try await Page.open(address, bridge: bridge)
            for message in Self.everyMessage {
                #expect(try await Page.ask(view, message) == Optional<NSDictionary>.none, "\(address): its own event goes nowhere")
                #expect(try await Page.forge(view, message) == ["ok": false, "why": why.rawValue], "\(address)")
            }
        }
        #expect(GameSaves.load(bridge.folder).saves.isEmpty)
    }

    static let everyMessage: [[String: Any]] = [["v": 1, "ask": "give", "key": key],
                                                ["v": 1, "ask": "keep", "key": key, "save": "{}", "n": 1]]

    @Test func aFramedPageIsRefused() async throws {
        let bridge = Bridge(ours: Self.ours)
        let frames = Frames()
        let view = try await Page.open(Self.at("cardtable/index.html"), bridge: bridge, frames: frames,
                                       html: "<iframe src='\(Self.at("cardtable/inner.html"))'></iframe>")
        try await Page.settle()
        let inner = try #require(frames.inner)
        #expect(!inner.isMainFrame)
        for message in Self.everyMessage {
            #expect(try await Page.forge(view, message, in: inner)
                    == ["ok": false, "why": GameBridge.Refusal.framed.rawValue])
        }
        let none = try await view.callAsyncJavaScript(
            "return document.documentElement.hasAttribute('data-pm-games')", in: inner, contentWorld: .page)
        #expect(none as? Bool == false, "no bridge in a frame")
        #expect(GameSaves.load(bridge.folder).saves.isEmpty)
    }

    /// A third-party page that moves its own address into our folder (pushState) is still the page it was at its
    /// start, when the bridge's script judged it.
    @Test func aPageMovingItselfIntoOurFolderStaysOutside() async throws {
        let bridge = Bridge(ours: Self.ours)
        let view = try await Page.open(Self.at("zimi/2048/index.html"), bridge: bridge)
        _ = try await view.evaluateJavaScript("history.pushState({}, '', '/cardtable/index.html'); 0")
        #expect(try await view.evaluateJavaScript("location.pathname") as? String == "/cardtable/index.html")
        for message in Self.everyMessage { #expect(try await Page.ask(view, message) == Optional<NSDictionary>.none) }
        #expect(GameSaves.load(bridge.folder).saves.isEmpty)
    }

    // MARK: kit.js, the four pairings

    enum Side { case old, new }

    /// One opening of the card table with kit.js: the app old (no bridge) or new, the games file old (today's kit, no
    /// list of our own games) or new. Every opening of one test shares the page storage and the app's folder, as one
    /// device does across updates. `list: false`: a new games file whose list the app couldn't read.
    @MainActor
    final class Device {
        let storage = WKWebsiteDataStore.nonPersistent()
        let bridge = Bridge(ours: [])

        func open(app: Side, file: Side, list: Bool = true) async throws -> WKWebView {
            bridge.store.ours = file == .new && list ? GameSavesTests.ours : []  // a new app reads the file's list, or finds none
            let kit = file == .new ? GameSavesTests.repo.appendingPathComponent("games/kit/kit.js")
                                   : GameSavesTests.fixtures.appendingPathComponent("kit-before-bridge.js")
            return try await Page.open(GameSavesTests.at("cardtable/index.html"), bridge: app == .new ? bridge : nil,
                                       html: "<script src='../kit/kit.js'></script>", storage: storage,
                                       kit: try Data(contentsOf: kit))
        }

        func store() -> String? { GameSaves.load(bridge.folder).saves[GameSavesTests.key]?.save }
        func count() -> Int? { GameSaves.load(bridge.folder).saves[GameSavesTests.key]?.n }
        /// The app opened again: what its file holds, and the games file's list read again.
        func reopen() {
            bridge.store = GameSaves.load(bridge.folder)
            _ = bridge.store.read(gamesID: GameSavesTests.games, ours: GameSavesTests.ours)
        }
    }

    static func load(_ view: WKWebView) async throws -> String? {
        try await view.evaluateJavaScript("JSON.stringify(PMKit.load('\(key)'))") as? String
    }
    static func save(_ view: WKWebView, _ hand: Int) async throws {
        _ = try await view.evaluateJavaScript("PMKit.save('\(key)', {hand: \(hand)}); 0")
        try await Page.settle()
    }
    static func page(_ view: WKWebView, _ key: String = key) async throws -> String? {
        try await view.evaluateJavaScript("localStorage.getItem('\(key)')") as? String
    }
    /// The page's copy's count as written beside it.
    static func pageCount(_ view: WKWebView) async throws -> Int? {
        try await view.evaluateJavaScript("(JSON.parse(localStorage.getItem('\(key):n') || 'null') || {}).n") as? Int
    }
    /// A mark on the page that a reload takes away.
    static func mark(_ view: WKWebView) async throws { _ = try await view.evaluateJavaScript("window.pmMark = 1; 0") }
    static func reloaded(_ view: WKWebView) async throws -> Bool {
        try await view.evaluateJavaScript("typeof window.pmMark") as? String == "undefined"
    }

    @Test func eachPairingPlaysAndNothingIsLostReachingTheNewest() async throws {
        for start in [(Side.old, Side.old), (.old, .new), (.new, .old)] {
            let device = Device()
            let first = try await device.open(app: start.0, file: start.1)
            #expect(try await Self.load(first) == "null")
            try await Self.save(first, 1)
            #expect(try await Self.load(first) == #"{"hand":1}"#, "\(start)")
            #expect(try await Self.page(first) == #"{"hand":1}"#, "\(start): the page's own storage, as today")
            #expect(device.store() == nil, "\(start): nothing called the bridge")
            let newest = try await device.open(app: .new, file: .new)
            #expect(try await Self.load(newest) == #"{"hand":1}"#, "\(start): the game is where it was")
            try await Page.settle()
            #expect(device.store() == #"{"hand":1}"#, "\(start): copied into the app")
            try await Self.save(newest, 2)
            #expect(device.store() == #"{"hand":2}"#)
            #expect(try await Self.page(newest) == #"{"hand":2}"#, "\(start): the page's copy follows, counted")
            let again = try await device.open(app: .new, file: .new)
            #expect(try await Self.load(again) == #"{"hand":2}"#, "\(start)")
        }
    }

    @Test func theNewestPairingKeepsACountedCopyInThePagesStorage() async throws {
        let device = Device()
        let view = try await device.open(app: .new, file: .new)
        try await Self.save(view, 5)
        try await Self.save(view, 6)
        #expect(device.store() == #"{"hand":6}"# && device.count() == 2)
        #expect(try await Self.page(view) == #"{"hand":6}"#)
        #expect(try await Self.pageCount(view) == 2)
        // the same save again spends no count
        try await Self.save(view, 6)
        #expect(device.count() == 2)
        // another key of the page's is not a game's save: the page's own storage, counted the same way
        _ = try await view.evaluateJavaScript("PMKit.save('pm-cardtable-extra', 1); 0")
        #expect(try await Self.page(view, "pm-cardtable-extra") == "1")
    }

    /// A copy in the page's storage with no count (from before the counts) is count 0: taken while the app holds
    /// none, never over a save the app holds.
    @Test func aCopyWithNoCountLosesToTheAppsCount() async throws {
        let device = Device()
        let old = try await device.open(app: .old, file: .old)
        try await Self.save(old, 1)  // today's kit: no count
        let first = try await device.open(app: .new, file: .new)
        #expect(try await Self.load(first) == #"{"hand":1}"#)
        try await Page.settle()
        #expect(device.store() == #"{"hand":1}"# && device.count() == 0)
        try await Self.save(first, 2)
        _ = try await first.evaluateJavaScript("localStorage.setItem('\(Self.key)', '{\"hand\":9}'); localStorage.removeItem('\(Self.key):n'); 0")
        let next = try await device.open(app: .new, file: .new)
        #expect(try await Self.load(next) == #"{"hand":2}"#, "the app's count, not the page's uncounted copy")
    }

    @Test func aSaveTheAppCouldNotKeepStaysWithThePageAndIsTakenNextTime() async throws {
        let device = Device()
        device.bridge.failWrites = true
        let view = try await device.open(app: .new, file: .new)
        try await Self.save(view, 3)
        #expect(device.store() == nil)
        #expect(try await Self.page(view) == #"{"hand":3}"#)
        #expect(try await Self.pageCount(view) == 1)
        device.bridge.failWrites = false
        device.reopen()  // its file holds none
        let next = try await device.open(app: .new, file: .new)
        #expect(try await Self.load(next) == #"{"hand":3}"#)
        try await Page.settle()
        #expect(device.store() == #"{"hand":3}"# && device.count() == 1)
    }

    /// The app holds an older save and the page a newer one the app couldn't keep: the higher count wins.
    @Test func aNewerPageCopyWinsOverTheAppsOlderOne() async throws {
        let device = Device()
        let view = try await device.open(app: .new, file: .new)
        try await Self.save(view, 1)
        #expect(device.store() == #"{"hand":1}"#)
        device.bridge.failWrites = true
        try await Self.save(view, 2)
        device.bridge.failWrites = false
        device.reopen()  // its file holds 1
        let next = try await device.open(app: .new, file: .new)
        #expect(try await Self.load(next) == #"{"hand":2}"#)
        try await Page.settle()
        #expect(device.store() == #"{"hand":2}"#)
    }

    /// The store survives the app being closed: a new bridge reads only its file, and the page starts from it.
    @Test func aGameIsWhereItWasAfterTheAppIsOpenedAgain() async throws {
        let device = Device()
        let view = try await device.open(app: .new, file: .new)
        try await Self.save(view, 4)
        device.bridge.store = GameSaves.load(device.bridge.folder)
        let reopened = Device()
        reopened.bridge.store = GameSaves.load(device.bridge.folder)
        reopened.bridge.folder = device.bridge.folder
        let fresh = try await reopened.open(app: .new, file: .new)  // a fresh page storage too: only the app's file
        #expect(try await Self.load(fresh) == #"{"hand":4}"#)
    }

    // MARK: Stage 1b: the counts at work

    /// Two pages of one game (the reader's hidden reopened page and the one in front, say), both from the same save.
    /// The front one plays on; the older one saving last never rolls the game back, in the app or the page's storage,
    /// and it starts again from the newest. Sent straight to the app, an older save is refused.
    @Test func twoPagesOfOneGameTheOlderSavingLast() async throws {
        let device = Device()
        let older = try await device.open(app: .new, file: .new)
        let front = try await device.open(app: .new, file: .new)
        try await Self.mark(older)
        for hand in 1...3 { try await Self.save(front, hand) }
        #expect(device.store() == #"{"hand":3}"# && device.count() == 3)
        try await Self.save(older, 9)
        #expect(device.store() == #"{"hand":3}"#, "the app keeps the newest")
        #expect(try await Self.page(front) == #"{"hand":3}"#, "and so does the page's storage")
        #expect(try await Self.reloaded(older), "the older page started again")
        #expect(try await Self.load(older) == #"{"hand":3}"#, "from the newest")
        // an older save sent to the app: refused, whatever its text
        #expect(try await Page.ask(front, ["v": 1, "ask": "keep", "key": Self.key, "save": #"{"hand":0}"#, "n": 2])
                == ["ok": false, "why": GameBridge.Refusal.older.rawValue])
        #expect(device.store() == #"{"hand":3}"#)
    }

    /// The same two pages with no bridge (an older app, or the list unreadable): the page's storage is the only copy,
    /// and the older page saving last neither overwrites it nor carries on.
    @Test func twoPagesOfOneGameWithoutTheBridge() async throws {
        let device = Device()
        let older = try await device.open(app: .old, file: .new)
        let front = try await device.open(app: .old, file: .new)
        for view in [older, front] { _ = try await Self.load(view) }  // as a game does at its start
        try await Self.mark(older)
        for hand in 1...3 { try await Self.save(front, hand) }
        try await Self.save(older, 9)
        try await Page.settle()
        #expect(try await Self.page(front) == #"{"hand":3}"#, "the page's storage keeps the newest")
        #expect(try await Self.pageCount(front) == 3)
        #expect(try await Self.reloaded(older), "the older page started again")
        #expect(try await Self.load(older) == #"{"hand":3}"#)
    }

    /// The app lays its script again only after the saves stop, so a page reloaded while a game is played gets the
    /// script with the save it opened with: it still starts from the newest, the page's own counted copy.
    @Test func aPageReloadedBeforeTheScriptIsLaidAgainStartsFromTheNewest() async throws {
        let device = Device()
        let view = try await device.open(app: .new, file: .new)
        for hand in 1...3 { try await Self.save(view, hand) }
        try await Self.mark(view)
        _ = try await view.evaluateJavaScript("location.reload(); 0")
        try await Page.settle()
        #expect(try await Self.reloaded(view))
        #expect(try await Self.load(view) == #"{"hand":3}"#)
        try await Page.settle()
        #expect(device.store() == #"{"hand":3}"# && device.count() == 3, "and the app still holds it, unchanged")
    }

    /// The page's storage lost its copy (the newer page's count with it), so only the app knows the game moved on:
    /// told older, the page starts again from the newest instead of carrying on with a game nobody keeps.
    @Test func aPageToldOlderByTheAppStartsAgain() async throws {
        let device = Device()
        let older = try await device.open(app: .new, file: .new)
        let front = try await device.open(app: .new, file: .new)
        for hand in 1...3 { try await Self.save(front, hand) }
        _ = try await older.evaluateJavaScript("localStorage.clear(); window.pmMark = 1; 0")
        try await Self.save(older, 9)
        #expect(device.store() == #"{"hand":3}"#)
        #expect(device.bridge.refused[.older] == 1)
        #expect(try await Self.reloaded(older))
        #expect(try await Self.load(older) == #"{"hand":3}"#)
        #expect(try await Self.page(older) == #"{"hand":3}"#, "and the page's copy caught up")
    }

    /// The games file's list unreadable for a while (no bridge offered): play goes to the page's storage with its
    /// count, and wins when the list is back.
    @Test func theListMissingAndThenBack() async throws {
        let device = Device()
        let first = try await device.open(app: .new, file: .new)
        try await Self.save(first, 1)
        #expect(device.count() == 1)
        let missing = try await device.open(app: .new, file: .new, list: false)
        #expect(try await Self.load(missing) == #"{"hand":1}"#)
        try await Self.save(missing, 2)
        #expect(device.store() == #"{"hand":1}"#, "no bridge: the app still holds the older one")
        #expect(try await Self.pageCount(missing) == 2)
        let back = try await device.open(app: .new, file: .new)
        #expect(try await Self.load(back) == #"{"hand":2}"#)
        try await Page.settle()
        #expect(device.store() == #"{"hand":2}"# && device.count() == 2)
    }

    /// From the newest pair to an older app, and to an older games file, and back each time: the play in between is
    /// kept. The older games file's kit writes no count; its change to the page's copy counts one more.
    @Test func newestToOlderAndBackKeepsThePlayInBetween() async throws {
        let device = Device()
        let newest = try await device.open(app: .new, file: .new)
        try await Self.save(newest, 1)
        try await Self.save(newest, 2)
        // an older app (no bridge), the new games file
        let oldApp = try await device.open(app: .old, file: .new)
        #expect(try await Self.load(oldApp) == #"{"hand":2}"#)
        try await Self.save(oldApp, 3)
        let back = try await device.open(app: .new, file: .new)
        #expect(try await Self.load(back) == #"{"hand":3}"#)
        try await Page.settle()
        #expect(device.store() == #"{"hand":3}"#)
        try await Self.save(back, 4)
        // an older games file (today's kit), the new app
        let oldFile = try await device.open(app: .new, file: .old)
        #expect(try await Self.load(oldFile) == #"{"hand":4}"#, "the older kit finds the latest game")
        try await Self.save(oldFile, 5)
        let backAgain = try await device.open(app: .new, file: .new)
        #expect(try await Self.load(backAgain) == #"{"hand":5}"#)
        try await Page.settle()
        #expect(device.store() == #"{"hand":5}"#)
    }

    /// Two trips to an older games file with no move on the newest between them: the older kit's last play wins, in
    /// the page and in the app. The newest kit writes the count it read a changed copy at, so the second uncounted
    /// change counts one past it rather than tying the app's copy.
    @Test func twoTripsToAnOlderGamesFileWithNoMoveBetween() async throws {
        let device = Device()
        let newest = try await device.open(app: .new, file: .new)
        try await Self.save(newest, 1)
        let firstTrip = try await device.open(app: .new, file: .old)
        try await Self.save(firstTrip, 2)
        let between = try await device.open(app: .new, file: .new)  // opened, no move made
        #expect(try await Self.load(between) == #"{"hand":2}"#)
        try await Page.settle()
        #expect(device.store() == #"{"hand":2}"# && device.count() == 2)
        let secondTrip = try await device.open(app: .new, file: .old)
        try await Self.save(secondTrip, 3)
        let back = try await device.open(app: .new, file: .new)
        #expect(try await Self.load(back) == #"{"hand":3}"#, "the last older play is where the game starts")
        try await Page.settle()
        #expect(device.store() == #"{"hand":3}"# && device.count() == 3, "and the app holds it")
    }

    /// The app's store unreadable at a launch: set aside, and the game comes back from the page's counted copy.
    @Test func anUnreadableStoreGivesTheGameBackFromThePage() async throws {
        let device = Device()
        let first = try await device.open(app: .new, file: .new)
        try await Self.save(first, 1)
        try await Self.save(first, 2)
        try Data("damaged".utf8).write(to: device.bridge.folder.appendingPathComponent(GameSaves.fileName))
        device.reopen()
        #expect(device.bridge.store.setAside != nil && device.bridge.store.saves.isEmpty)
        let next = try await device.open(app: .new, file: .new)
        #expect(try await Self.load(next) == #"{"hand":2}"#)
        try await Page.settle()
        #expect(device.store() == #"{"hand":2}"# && device.count() == 2)
    }

    /// A save the app never answers: after the kit's ten seconds the page carries on, its counted copy already holds
    /// the save, and the next start gives it to the app.
    @Test func aSaveTheAppNeverAnswers() async throws {
        let device = Device()
        device.bridge.silent = true
        let view = try await device.open(app: .new, file: .new)
        try await Self.mark(view)
        try await Self.save(view, 6)
        _ = try await view.evaluateJavaScript("setTimeout(function () { window.pmTimer = 1; }, 10000); 0")
        for _ in 0..<80 {  // the kit's ten seconds started just before this timer's
            try await Task.sleep(for: .milliseconds(500))
            let state = try await view.evaluateJavaScript("String(window.pmTimer) + String(window.pmMark)") as? String
            if state != "undefined1" { break }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(device.store() == nil)
        #expect(try await Self.page(view) == #"{"hand":6}"#)
        #expect(try await Self.pageCount(view) == 1)
        #expect(try await !Self.reloaded(view), "no answer is no reason to start again")
        device.bridge.silent = false
        device.bridge.answerLate()
        let next = try await device.open(app: .new, file: .new)
        #expect(try await Self.load(next) == #"{"hand":6}"#)
        try await Page.settle()
        #expect(device.store() == #"{"hand":6}"#)
    }

    // MARK: A real web view

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("game-saves-\(UUID().uuidString)")
    }

    /// The app's handler (`PrepareMeGameSaves`) as the test runs it: the same frame facts, `GameSaves.answer`, the
    /// store written before the answer, and the script laid again only for a page told older.
    @MainActor
    final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        var store = GameSaves()
        var folder = GameSavesTests.scratch()
        var failWrites = false
        var silent = false  // takes nothing in and answers nothing, until answerLate
        /// Stage 2: the device's player list, and an app from before stage 2, which knows neither ask about players.
        var players = PlayerList()
        var beforePlayers = false
        /// Stage 3: the device's lines, in the bridge's own scratch folder, and an app from before stage 3, which knows
        /// neither ask about lines.
        lazy var lines = GameLines.load(folder)
        var beforeLines = false
        var held: [(Any?, String?) -> Void] = []
        var refused: [GameBridge.Refusal: Int] = [:]
        let controllers = NSHashTable<WKUserContentController>.weakObjects()

        /// The bridge's script laid again in every page's controller, as the app's `relay` does: like the app, only
        /// when a page is told older (the app also does it a moment after the saves stop, which no test waits for).
        func relay() {
            for controller in controllers.allObjects {
                controller.removeAllUserScripts()  // the test's pages hold only the bridge's script
                controller.addUserScript(script)
            }
        }

        /// The answers held back, given at last (the kit has stopped waiting for them).
        func answerLate() {
            for reply in held { reply(["ok": false, "why": "late"], nil) }
            held = []
        }

        init(ours: [String]) {
            _ = store.read(gamesID: GameSavesTests.games, ours: ours)
        }

        var script: WKUserScript {
            WKUserScript(source: GameBridge.pageScript(gamesID: store.games, ours: store.ours, saves: store.saves),
                         injectionTime: .atDocumentStart, forMainFrameOnly: true,
                         in: .world(name: GameBridge.world))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            if silent {  // the message taken in by nobody, as if the app had stopped
                held.append(replyHandler)
                return
            }
            let info = message.frameInfo
            let frame = GameBridge.Frame(isMain: info.isMainFrame, scheme: info.securityOrigin.protocol,
                                         host: info.securityOrigin.host,
                                         path: info.request.url?.path(percentEncoded: false) ?? "")
            let ask = (message.body as? [String: Any])?["ask"] as? String ?? ""
            if (beforePlayers && ["players", "usual", "line", "lines"].contains(ask)) || (beforeLines && ["line", "lines"].contains(ask)) {
                refused[.unknown, default: 0] += 1
                return replyHandler(GameBridge.reply(.failure(.unknown), saves: [:]), nil)
            }
            var answer = store.answer(message.body, from: frame, players: players, lines: lines)
            if answer.changed {
                if failWrites || (try? store.save(folder)) == nil {
                    answer.reply = GameBridge.reply(.failure(.notSaved), saves: [:])
                    answer.refused = .notSaved
                }
            }
            if let why = answer.refused { refused[why, default: 0] += 1 }
            if answer.refused == .older { relay() }
            replyHandler(answer.reply, nil)
        }
    }

    /// The inner frame's facts, from a word it sends its own page world's test handler.
    @MainActor
    final class Frames: NSObject, WKScriptMessageHandler {
        var inner: WKFrameInfo?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if !message.frameInfo.isMainFrame { inner = message.frameInfo }
        }
    }

    @MainActor
    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func finish() {
            done?.resume()
            done = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) { finish() }
    }

    /// The games file as the reader serves it: kit.js at kit/kit.js, the page under test at every other address, and
    /// a page that says it is framed at cardtable/inner.html.
    @MainActor
    private final class Library: NSObject, WKURLSchemeHandler {
        let html: String
        let kit: Data
        init(html: String, kit: Data) {
            self.html = html
            self.kit = kit
        }
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let url = task.request.url!
            let (data, type): (Data, String) = url.path == "/kit/kit.js" ? (kit, "text/javascript")
                : url.path == "/cardtable/inner.html"
                ? (Data("<script>webkit.messageHandlers.frames.postMessage(1)</script>".utf8), "text/html")
                : (Data("<!doctype html><html><head>\(html)</head><body></body></html>".utf8), "text/html")
            task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count,
                                        textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    @MainActor
    enum Page {
        static func settle() async throws { try await Task.sleep(for: .milliseconds(800)) }

        static var held: [AnyObject] = []  // the navigation delegates, kept for the test run

        static func open(_ address: String, bridge: Bridge?, frames: Frames? = nil, html: String = "<p>SAMPLE</p>",
                         storage: WKWebsiteDataStore = .nonPersistent(), kit: Data = Data()) async throws -> WKWebView {
            let controller = WKUserContentController()
            if let bridge {
                controller.addUserScript(bridge.script)
                controller.addScriptMessageHandler(bridge, contentWorld: .world(name: GameBridge.world),
                                                   name: GameBridge.handler)
                bridge.controllers.add(controller)
            }
            if let frames { controller.add(frames, name: "frames") }
            let configuration = WKWebViewConfiguration()
            configuration.userContentController = controller
            configuration.websiteDataStore = storage
            configuration.setURLSchemeHandler(Library(html: html, kit: kit), forURLScheme: "zim")
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
            let loaded = Loaded()
            held.append(loaded)
            view.navigationDelegate = loaded
            await withCheckedContinuation { done in
                loaded.done = done
                view.load(URLRequest(url: URL(string: address)!))
            }
            return view
        }

        /// A message sent the way kit.js sends it, from the page's own scripts: the answer, or nil when none came.
        static func ask(_ view: WKWebView, _ message: [String: Any]) async throws -> NSDictionary? {
            let answer = try await view.callAsyncJavaScript("""
                return await new Promise(function (done) {
                  var ask = JSON.parse(text); ask.id = 77;
                  document.addEventListener('pm-game-answer', function (e) { done(e.detail); });
                  document.dispatchEvent(new CustomEvent('pm-game-ask', { detail: JSON.stringify(ask) }));
                  setTimeout(function () { done(null); }, 2000);
                });
                """, arguments: ["text": json(message)], in: nil, contentWorld: .page)
            guard let text = answer as? String,
                  let said = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
            #expect(said["id"] as? Int == 77)
            return said.filter { $0.key != "id" } as NSDictionary
        }

        /// A message sent straight to the handler from the bridge's own world, in `frame` (the main frame: nil).
        static func forge(_ view: WKWebView, _ message: [String: Any], in frame: WKFrameInfo? = nil) async throws
            -> NSDictionary? {
            try await view.callAsyncJavaScript(
                "return await window.webkit.messageHandlers.\(GameBridge.handler).postMessage(JSON.parse(text))",
                arguments: ["text": json(message)], in: frame, contentWorld: .world(name: GameBridge.world))
                as? NSDictionary
        }

        static func json(_ message: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
        }
    }
}

/// Answers compared as plain dictionaries.
private func == (left: NSDictionary?, right: [String: Any]) -> Bool { left?.isEqual(to: right) ?? false }
