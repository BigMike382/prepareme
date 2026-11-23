import Foundation
import Testing
import WebKit
@testable import PrepareMeShared

/// Full-screen play (games plan, phase 3b): the game-page rule, and the mark's page script in a real web view, held to
/// the same cases so the Swift rule and the page's own words never part.
@MainActor
struct GamePlayTests {
    static let games = UUID(uuidString: "0F1E2D3C-4B5A-4968-8776-6554433221C9")!
    static let other = UUID(uuidString: "0F1E2D3C-4B5A-4968-8776-6554433221B1")!

    /// (address, whether it is a game page)
    static let cases: [(String, Bool)] = [
        ("zim://\(games.uuidString)/hearts/index.html", true),
        ("zim://\(games.uuidString.lowercased())/zimi/2048/index.html#play", true),
        ("zim://\(games.uuidString)/sudoku.html", true),
        ("zim://\(games.uuidString)/index.html", false),  // the Games list
        ("zim://\(games.uuidString)/rules/hearts.html", false),  // a printable rules page
        ("zim://\(other.uuidString)/hearts/index.html", false),  // another file
    ]

    @Test func theRule() {
        for (address, game) in Self.cases {
            #expect(GamePlay.isGamePage(URL(string: address), gamesID: Self.games) == game, "\(address)")
        }
        #expect(!GamePlay.isGamePage(URL(string: "zim://\(Self.games.uuidString)/x.html"), gamesID: nil))
        #expect(!GamePlay.isGamePage(nil, gamesID: Self.games))
        #expect(!GamePlay.isGamePath("/"))
        #expect(GamePlay.isGamePath("/rulesets/x.html"))  // only the rules folder itself is left out
    }

    @Test func thePageScriptMarksTheSamePages() async throws {
        for (address, game) in Self.cases {
            let view = try await page("<p>SAMPLE</p>", at: address)
            let mark = try await view.evaluateJavaScript("document.documentElement.getAttribute('data-pm-full')")
            #expect((mark as? String) == (game ? "1" : nil), "\(address)")
        }
    }

    @Test func noGamesFileNoMark() async throws {
        let view = try await page("<p>SAMPLE</p>", at: Self.cases[0].0, gamesID: nil)
        let mark = try await view.evaluateJavaScript("document.documentElement.hasAttribute('data-pm-full')")
        #expect((mark as? Bool) == false)
    }

    /// The page asks for edge to edge only once it sees the mark; the app hears of it, and of it taken back.
    @Test func thePageTellsTheAppWhenItAsksForCover() async throws {
        let html = """
            <meta name="viewport" content="width=device-width">
            <script>if (document.documentElement.hasAttribute('data-pm-full'))
              document.querySelector('meta[name=viewport]').content = 'width=device-width, viewport-fit=cover';</script>
            """
        let heard = Heard()
        let view = try await page(html, at: Self.cases[0].0, heard: heard)
        try await settle()
        #expect(heard.said == [true])
        _ = try await view.evaluateJavaScript(
            "document.querySelector('meta[name=viewport]').content = 'width=device-width'; 0")
        try await settle()
        #expect(heard.said == [true, false])
        let plain = Heard()
        _ = try await page("<meta name='viewport' content='width=device-width'>", at: Self.cases[0].0, heard: plain)
        try await settle()
        #expect(plain.said.isEmpty, "a page that never asks says nothing")
    }

    @Test func doneSitsInTheBandOnlyWhereItFits() {
        #expect(GamePlay.doneInBand(topInset: 59, height: 30))  // an upright iPhone with an island
        #expect(!GamePlay.doneInBand(topInset: 24, height: 30))  // an iPad
        #expect(!GamePlay.doneInBand(topInset: 0, height: 30))  // an iPhone on its side, the Mac
    }

    // MARK: A real web view

    private final class Heard: NSObject, WKScriptMessageHandler {
        var said: [Bool] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let cover = message.body as? Bool { said.append(cover) }
        }
    }

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

    /// The library's scheme, as the reader serves it: every address answers with the page.
    private final class Library: NSObject, WKURLSchemeHandler {
        let html: String
        init(html: String) { self.html = html }
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let data = Data(html.utf8)
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html",
                                        expectedContentLength: data.count,
                                        textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    private func page(_ html: String, at address: String, gamesID: UUID? = games,
                      heard: Heard? = nil) async throws -> WKWebView {
        let controller = WKUserContentController()
        let script = WKUserScript(source: GamePlay.pageScript(gamesID: gamesID), injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true)
        controller.addUserScript(script)
        if let heard { controller.add(heard, name: GamePlay.handler) }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(
            Library(html: "<!doctype html><html><head>\(html)</head><body></body></html>"), forURLScheme: "zim")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        let loaded = Loaded()
        view.navigationDelegate = loaded
        await withCheckedContinuation { done in
            loaded.done = done
            view.load(URLRequest(url: URL(string: address)!))
        }
        withExtendedLifetime(loaded) {}
        return view
    }
}
