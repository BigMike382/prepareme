import Foundation
import Testing
import WebKit
@testable import PrepareMeShared

/// "Who is playing?" on the card table's opening card (players plan, stage 2), the real page and kit in a real web
/// view served the way the reader serves the games file: the list with the device's usual player first, Guest, the
/// first pick making the usual player, "Play as …?" for anyone else, no nickname ever in the page's storage or the
/// app's save, the asks refused from a page outside our folders and a framed page, and the four pairings of an app
/// and a games file from before stage 2 or after it, where nothing typed or chosen is lost.
@MainActor
struct PlayersCardTests {
    static let names = PlayersTests.names

    enum Side { case old, new }

    /// One device: its page storage, and the app's bridge with the made-up household on it.
    @MainActor
    final class Device {
        let storage = WKWebsiteDataStore.nonPersistent()
        let bridge = GameSavesTests.Bridge(ours: GameSavesTests.ours)

        init(players: PlayerList) { bridge.players = players }

        func open(app: Side, file: Side, path: String = "cardtable/index.html") async throws -> WKWebView {
            bridge.beforePlayers = app == .old
            let fixtures = GameSavesTests.fixtures, games = GameSavesTests.repo.appendingPathComponent("games")
            let kit = file == .new ? games.appendingPathComponent("kit/kit.js")
                                   : fixtures.appendingPathComponent("kit-before-players.js")
            let table = file == .new ? games.appendingPathComponent("cardtable/table.js")
                                     : fixtures.appendingPathComponent("table-before-players.js")
            let view = try await Card.open(GameSavesTests.at(path + "?table=flat&fast=1"), bridge: bridge,
                                           storage: storage, swap: ["/kit/kit.js": try Data(contentsOf: kit),
                                                                    "/cardtable/table.js": try Data(contentsOf: table)])
            try await Card.waitFor(view, "!document.getElementById('veil').hidden")
            return view
        }
    }

    static func household() throws -> PlayerList {
        var list = PlayerList()
        try list.add(names[0], color: .violet)
        try list.add(names[1], color: .pink)
        try list.add(names[2], color: .olive)
        try list.add(names[3], color: .slate)
        try list.retire(4)
        return list
    }

    /// A button's words without its chip's letter.
    static let words = """
        function words(b) { return Array.prototype.filter.call(b.childNodes, function (c) {
          return !(c.classList && c.classList.contains('pm-chip')); }).map(function (c) { return c.textContent; }).join(''); }
        """
    /// The opening card's rows: each row's words, and which is pressed. The usual player reads "Usual here": printed
    /// on its row in a games file from before the shorter card, said in its label and ringed (`data-usual`) since
    /// (2026-11-20); a usual player said but not ringed reads "!".
    static func rows(_ view: WKWebView) async throws -> [String] {
        let found = try await view.evaluateJavaScript("""
            \(words)
            Array.prototype.map.call(document.querySelectorAll('.pm-who button'), function (b) {
              var w = words(b), usual = /, usual on this device$/.test(b.getAttribute('aria-label') || '');
              if (usual && w.indexOf('Usual here') < 0) w += b.hasAttribute('data-usual') ? 'Usual here' : '!';
              return (b.getAttribute('aria-pressed') === 'true' ? '*' : '') + w; })
            """)
        return found as? [String] ?? []
    }
    static func press(_ view: WKWebView, _ text: String) async throws {
        let pressed = try await view.evaluateJavaScript("""
            \(words)
            var b = Array.prototype.filter.call(document.querySelectorAll('#paper button, #menu-btn'), function (b) {
              return words(b).indexOf(\(Card.json(text))) === 0; })[0];
            if (b) b.click(); !!b
            """) as? Bool
        #expect(pressed == true, "no button \(text)")
        try await Task.sleep(for: .milliseconds(150))
    }
    static func text(_ view: WKWebView, _ js: String) async throws -> String {
        try await view.evaluateJavaScript(js) as? String ?? ""
    }
    /// Deal (or New game), then the menu's Choose a game, back to the opening card as a person would.
    static func dealAndLeave(_ view: WKWebView, fresh: Bool = false) async throws {
        try await press(view, fresh ? "New game" : "Deal")
        try await Card.waitFor(view, "document.getElementById('veil').hidden")
        try await press(view, "Menu")
        try await press(view, "Choose a game")
        try await GameSavesTests.Page.settle()
    }
    static func typedBox(_ view: WKWebView) async throws -> Bool {
        try await view.evaluateJavaScript("!!document.querySelector('#paper input[type=text]')") as? Bool ?? false
    }

    @Test func whoIsPlayingThenPlayAsOnce() async throws {
        let device = Device(players: try Self.household())
        let card = try await device.open(app: .new, file: .new)
        #expect(try await Self.text(card, "document.getElementById('paper').textContent").contains("Who is playing?"))
        // no usual player yet: the list in the Mac's order, the retired player left out, Guest last and chosen, the
        // typed name under it
        #expect(try await Self.rows(card) == [Self.names[0], Self.names[1], Self.names[2], "*Guest"])
        #expect(try await Self.typedBox(card))
        // the first pick on the device makes its usual player, with no question
        try await Self.press(card, Self.names[1])
        #expect(device.bridge.store.usual == 2)
        #expect(try await Self.rows(card) == ["*\(Self.names[1])Usual here", Self.names[0], Self.names[2], "Guest"])
        #expect(try await !Self.typedBox(card))
        // anyone else: "Play as …?" once; Cancel keeps the usual player
        try await Self.press(card, Self.names[0])
        #expect(try await Self.text(card, "document.querySelector('#paper h1').textContent") == "Play as \(Self.names[0])?")
        try await Self.press(card, "Cancel")
        #expect(try await Self.rows(card).first == "*\(Self.names[1])Usual here")
        try await Self.press(card, Self.names[0])
        try await Self.press(card, "Play as")
        #expect(try await Self.rows(card) == ["\(Self.names[1])Usual here", "*\(Self.names[0])", Self.names[2], "Guest"])
        #expect(device.bridge.store.usual == 2, "playing as someone else leaves the usual player")
        try await Self.press(card, Self.names[0])  // picked again: asked no more
        #expect(try await Self.text(card, "document.querySelector('#paper h1').textContent") == "The Card Table")
        // the third choice: that player plays here from now on, the device's usual player changed through the app
        try await Self.press(card, Self.names[2])
        try await Self.press(card, "\(Self.names[2]) plays here from now on")
        #expect(device.bridge.store.usual == 3)
        #expect(try await Self.rows(card) == ["*\(Self.names[2])Usual here", Self.names[0], Self.names[1], "Guest"])
        try await Self.press(card, Self.names[0])  // and once more as someone else, which leaves it
        try await Self.press(card, "Play as")
        #expect(device.bridge.store.usual == 3)
        #expect(try await Self.rows(card) == ["\(Self.names[2])Usual here", "*\(Self.names[0])", Self.names[1], "Guest"])
        // the game's name is the player's, from the app
        try await Self.press(card, "Deal")
        try await Card.waitFor(card, "document.getElementById('flat').innerText.indexOf(\(Card.json(Self.names[0]))) >= 0")
        // never a nickname in the page's storage or the app's copy of the save: only the number
        try await GameSavesTests.Page.settle()
        let page = try await Self.text(card, "localStorage.getItem('pm-cardtable') || ''")
        let kept = device.bridge.store.saves[GameSavesTests.key]?.save ?? ""
        #expect(page.contains("\"player\":1") && kept.contains("\"player\":1"))
        for name in Self.names { #expect(!page.contains(name) && !kept.contains(name), "\(name)") }
        // opened again: straight back to the game, with the name from the app
        let games = GameSavesTests.repo.appendingPathComponent("games")  // named here: tests beside it open old files
        let again = try await Card.open(GameSavesTests.at("cardtable/index.html?table=flat&fast=1"), bridge: device.bridge,
                                        storage: device.storage,
                                        swap: ["/kit/kit.js": try Data(contentsOf: games.appendingPathComponent("kit/kit.js")),
                                               "/cardtable/table.js": try Data(contentsOf: games.appendingPathComponent("cardtable/table.js"))])
        try await Card.waitFor(again, "document.getElementById('flat').innerText.indexOf(\(Card.json(Self.names[0]))) >= 0")
    }

    /// The usual player retired on the Mac: no usual is offered, and the next pick makes a new one.
    @Test func aRetiredUsualPlayerIsReplacedByTheNextPick() async throws {
        var list = try Self.household()
        let device = Device(players: list)
        device.bridge.store.usual = 1
        try list.retire(1)
        device.bridge.players = list
        let card = try await device.open(app: .new, file: .new)
        #expect(try await Self.rows(card) == [Self.names[1], Self.names[2], "*Guest"])
        try await Self.press(card, Self.names[2])
        #expect(device.bridge.store.usual == 3)
    }

    /// No players on the Mac yet: the typed name, as before.
    @Test func anEmptyListKeepsTheTypedName() async throws {
        let device = Device(players: PlayerList())
        let card = try await device.open(app: .new, file: .new)
        #expect(try await Self.rows(card).isEmpty)
        #expect(try await Self.typedBox(card))
    }

    /// The four pairings: an app and a games file each from before stage 2 or after it. Only the newest pair asks who
    /// is playing; every other shows the typed name, as before, and neither the typed name nor the chosen player is
    /// lost on the way between them.
    @Test func theFourPairings() async throws {
        let device = Device(players: try Self.household())
        let typed = "Typ" + "ed"
        // an old app with an old games file: the typed name, as today
        var card = try await device.open(app: .old, file: .old)
        #expect(try await Self.rows(card).isEmpty)
        #expect(try await Self.typedBox(card))
        _ = try await card.evaluateJavaScript("var i = document.querySelector('#paper input'); i.value = \(Card.json(typed)); 0")
        try await Self.dealAndLeave(card)
        // an old app with the new games file: the kit's asks are refused as unknown (the players, and since stage 3 the
        // lines too), and the typed name stays
        let refusedBefore = device.bridge.refused[.unknown, default: 0]
        card = try await device.open(app: .old, file: .new)
        #expect(device.bridge.refused[.unknown, default: 0] == refusedBefore + 2)
        #expect(try await Self.rows(card).isEmpty)
        #expect(try await Self.text(card, "document.querySelector('#paper input').value") == typed)
        // the new app with the new games file: the list; Guest keeps the typed name
        card = try await device.open(app: .new, file: .new)
        #expect(try await Self.rows(card).last == "*Guest")
        #expect(try await Self.text(card, "document.querySelector('#paper input').value") == typed)
        try await Self.press(card, Self.names[2])
        #expect(device.bridge.store.usual == 3)
        // the new app with an old games file: the old card's typed name, still the one typed
        card = try await device.open(app: .new, file: .old)
        #expect(try await Self.rows(card).isEmpty)
        #expect(try await Self.text(card, "document.querySelector('#paper input').value") == typed)
        // (the game dealt with the old card went, once, to the player chosen on the new one: stage 3 keeps each player's
        // own game, which an older card doesn't see, so this card offers a deal of its own)
        try await Self.dealAndLeave(card)
        // and back to the newest pair: the chosen player is still chosen
        card = try await device.open(app: .new, file: .new)
        #expect(try await Self.rows(card).first == "*\(Self.names[2])Usual here")
    }

    /// The asks from a page outside our folders, from a framed page, and from a page of another file: all refused,
    /// and no nickname in any answer.
    @Test func theAsksAreRefusedFromAnyOtherPage() async throws {
        let device = Device(players: try Self.household())
        let players: [String: Any] = ["v": 1, "ask": "players", "key": GameSavesTests.key]
        let usual: [String: Any] = ["v": 1, "ask": "usual", "key": GameSavesTests.key, "player": 1]
        for path in ["index.html", "zimi/2048/index.html", "rules/hearts.html"] {
            let view = try await GameSavesTests.Page.open(GameSavesTests.at(path), bridge: device.bridge)
            #expect(try await GameSavesTests.Page.ask(view, players) == nil, "\(path): its asks go nowhere")
            for message in [players, usual] {
                let said = try await GameSavesTests.Page.forge(view, message)
                #expect(said?["why"] as? String == GameBridge.Refusal.notOurs.rawValue, "\(path)")
                #expect(said?["players"] == nil)
            }
        }
        let elsewhere = try await GameSavesTests.Page.open(GameSavesTests.at("cardtable/index.html", GameSavesTests.other),
                                                           bridge: device.bridge)
        #expect(try await GameSavesTests.Page.forge(elsewhere, players)?["why"] as? String
                == GameBridge.Refusal.elsewhere.rawValue)
        let frames = GameSavesTests.Frames()
        let outer = try await GameSavesTests.Page.open(GameSavesTests.at("cardtable/index.html"), bridge: device.bridge,
                                                       frames: frames, html: "<iframe src='inner.html'></iframe>")
        try await GameSavesTests.Page.settle()
        let inner = try #require(frames.inner)
        for message in [players, usual] {
            let said = try await GameSavesTests.Page.forge(outer, message, in: inner)
            #expect(said?["why"] as? String == GameBridge.Refusal.framed.rawValue)
        }
        #expect(device.bridge.store.usual == nil)
    }

    // MARK: The games file as the reader serves it

    @MainActor
    final class Folder: NSObject, WKURLSchemeHandler {
        let swap: [String: Data]
        init(swap: [String: Data]) { self.swap = swap }
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let url = task.request.url!
            let path = url.path(percentEncoded: false)
            let file = GameSavesTests.repo.appendingPathComponent("games").appendingPathComponent(path)
            guard let data = swap[path] ?? (try? Data(contentsOf: file)) else {
                task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
                task.didFinish()
                return
            }
            let type = path.hasSuffix(".js") ? "text/javascript" : path.hasSuffix(".css") ? "text/css" : "text/html"
            task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    @MainActor
    enum Card {
        static var held: [AnyObject] = []
        /// The page opened, the folder's file swapped where `swap` names it (the kit and the table, old or new).
        /// `seen`: the page told it is on the screen, as in the app: a web view in no window counts as hidden, and a
        /// game's waits (the kit's sleep) stand still while it is (stage 3's tests play cards).
        static func open(_ address: String, bridge: GameSavesTests.Bridge, storage: WKWebsiteDataStore,
                         swap: [String: Data], seen: Bool = false) async throws -> WKWebView {
            let controller = WKUserContentController()
            controller.addUserScript(bridge.script)
            if seen {
                controller.addUserScript(WKUserScript(source: """
                    Object.defineProperty(document, 'hidden', { get: function () { return false; } });
                    Object.defineProperty(document, 'visibilityState', { get: function () { return 'visible'; } });
                    """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            controller.addScriptMessageHandler(bridge, contentWorld: .world(name: GameBridge.world), name: GameBridge.handler)
            bridge.controllers.add(controller)
            let configuration = WKWebViewConfiguration()
            configuration.userContentController = controller
            configuration.websiteDataStore = storage
            let folder = Folder(swap: swap.isEmpty ? held.compactMap { $0 as? Folder }.last?.swap ?? [:] : swap)
            held.append(folder)
            configuration.setURLSchemeHandler(folder, forURLScheme: "zim")
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 800), configuration: configuration)
            held.append(view)
            view.load(URLRequest(url: URL(string: address)!))
            try await waitFor(view, "document.readyState === 'complete'")
            return view
        }

        static func waitFor(_ view: WKWebView, _ condition: String) async throws {
            for _ in 0..<100 {
                if (try? await view.evaluateJavaScript("!!(\(condition))")) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            Issue.record("waited ten seconds for: \(condition)")
        }

        static func json(_ text: String) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
                .description
        }
    }
}
