import AppKit
import PrepareMeShared
import Testing
import WebKit
import XCTest

/// Tap-to-call (B2-15): the app dials only the two numbers the packer marks, and only from its own prepareme://call
/// link; the page script turns a marked number into that link in a real web view, and leaves anything else alone.
@MainActor
final class CallLinksTests: XCTestCase {
    func testOnlyTheTwoNumbersDial() {
        func tel(_ s: String) -> String? { URL(string: s).flatMap(CallLinks.telURL)?.absoluteString }
        XCTAssertEqual(tel("prepareme://call?n=911"), "tel:911")
        XCTAssertEqual(tel("prepareme://call?n=18002221222"), "tel:18002221222")
        for other in ["prepareme://call?n=5551212", "prepareme://call?n=911;5551212", "prepareme://call?n=%2B911",
                      "prepareme://call", "prepareme://call?n=911&x=1", "prepareme://call?x=911",
                      "prepareme://streetmap?n=911", "tel:911", "https://call/?n=911", "other://call?n=911"] {
            XCTAssertNil(tel(other), other)
        }
    }

    private final class Watcher: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        var links: [String] = []
        var types: [WKNavigationType] = []
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done?.resume()
            done = nil
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let url = action.request.url, url.scheme == "prepareme" { links.append(url.absoluteString); types.append(action.navigationType); return .cancel }
            return .allow
        }
    }

    private var watchers: [Watcher] = []

    private func page(_ body: String, script: Bool, head: String = "", width: CGFloat = 400, dark: Bool = false,
                      red: Bool = false) async -> (WKWebView, Watcher) {
        let controller = WKUserContentController()
        if red {
            controller.addUserScript(WKUserScript(source: RedNight.pageScript(on: true), injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
        }
        if script {
            controller.addUserScript(WKUserScript(source: CallLinks.pageScript, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 400), configuration: configuration)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let watcher = Watcher()
        watchers.append(watcher)
        view.navigationDelegate = watcher
        await withCheckedContinuation { done in
            watcher.done = done
            view.loadHTMLString("<!doctype html><html><head><meta name=viewport content=\"width=device-width\">\(head)"
                                + "</head><body>\(body)</body></html>", baseURL: nil)
        }
        return (view, watcher)
    }

    private let body = """
        <p>Call <span class="tel" id="a" data-tel="911">911</span> or <span class="tel" id="b" data-tel="18002221222">1-800-222-1222</span>
        or <span class="tel" id="c" data-tel="5551212">555-1212</span>.</p>
        """

    func testATapOnAMarkedNumberGoesToTheAppsCallLink() async throws {
        let (view, watcher) = await page(body, script: true)
        for id in ["a", "b", "c"] {  // one tap at a time, as a person taps
            _ = try await view.evaluateJavaScript("document.getElementById('\(id)').click(); 1")
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertEqual(watcher.links, ["prepareme://call?n=911", "prepareme://call?n=18002221222"],
                       "only the two numbers; any other mark is ignored")
        let roles = try await view.evaluateJavaScript(
            "[a,b,c].map(function (e) { return e.getAttribute('role') + '/' + e.getAttribute('aria-label'); }).join('|')") as? String
        XCTAssertEqual(roles, "link/Call 911|link/Call 1-800-222-1222|null/null")
    }

    func testOnlyATapDialsAndOnlyOnAPhone() async throws {
        let url = try XCTUnwrap(URL(string: "prepareme://call?n=911"))
        XCTAssertEqual(CallLinks.dial(url, linkActivated: true)?.absoluteString, "tel:911")
        XCTAssertNil(CallLinks.dial(url, linkActivated: false), "a script's navigation or another app's address")
        XCTAssertTrue(CallLinks.injectsScript(isPhone: true))
        XCTAssertFalse(CallLinks.injectsScript(isPhone: false), "an iPad gets plain text")
        // the real web view: a tap on a marked number arrives as a link activation, a script's own jump does not
        let (view, watcher) = await page(body, script: true)
        _ = try await view.evaluateJavaScript("document.getElementById('a').click(); 1")
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await view.evaluateJavaScript("location.href = 'prepareme://call?n=911'; 1")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(watcher.types, [.linkActivated, .other])
    }

    /// The reading pages' tokens as packer.front_style.BASE sets them, light and dark.
    private let tokens = """
        <style>body{--panel:#fbfcf8;--text:#16191d;--link:#0c5d57;--bg:#e7ece3;margin:0;padding:0 16px;
        font:17px/1.5 -apple-system,system-ui,sans-serif;color:var(--text);background:var(--bg)}
        @media (prefers-color-scheme:dark){body{--panel:#15242a;--text:#eef1f4;--link:#6fdccf;--bg:#0d171c;
        color-scheme:dark}}html[data-pm-red] body{--link:var(--text)}</style>
        """

    private func look(_ view: WKWebView, _ id: String) async throws -> [String] {
        let js = """
            (function (e) { var s = getComputedStyle(e), i = e.querySelector('.tel-icon');
              return [s.display, s.borderTopStyle, s.borderTopColor, s.borderRadius, s.backgroundColor, s.color,
                      s.fontWeight, i ? i.textContent + '/' + i.getAttribute('aria-hidden') : 'none',
                      e.getAttribute('aria-label') || ''].join('|'); })(document.getElementById('\(id)'))
            """
        let found = try await view.evaluateJavaScript(js) as? String
        return try XCTUnwrap(found).components(separatedBy: "|")
    }

    func testAMarkedNumberIsASmallButtonWithAPhoneIcon() async throws {
        let (view, _) = await page(body, script: true, head: tokens)
        let call = try await look(view, "a")
        // owner's choice, 2026-10-21: "📞 911", an outline in the link color on the panel (ink then; teal since look 3,
        // as every link), ink words, the reading pages' button corners and weight
        XCTAssertEqual(call, ["inline-block", "solid", "rgb(12, 93, 87)", "12px", "rgb(251, 252, 248)",
                              "rgb(22, 25, 29)", "600", "📞/true", "Call 911"])
        let poison = try await look(view, "b")
        XCTAssertEqual(poison[7...8], ["📞/true", "Call 1-800-222-1222"], "the label without the icon")
        let other = try await look(view, "c")
        XCTAssertEqual(other[0], "inline", "any other mark stays plain text")
        XCTAssertEqual(other[7], "none")
        // the line around it: the icon is the only new text, and a tap on it is a tap on the number
        let text = try await view.evaluateJavaScript("document.getElementById('a').textContent") as? String
        XCTAssertEqual(text, "📞911")
    }

    func testTheButtonFollowsTheDarkAndRedNightScreens() async throws {
        // dark: the page's dark tokens
        let (dark, _) = await page(body, script: true, head: tokens, dark: true)
        let call = try await look(dark, "a")
        XCTAssertEqual(call[2], "rgb(111, 220, 207)", "a light teal outline")
        XCTAssertEqual(call[4], "rgb(21, 36, 42)")
        XCTAssertEqual(call[5], "rgb(238, 241, 244)")
        // red night (the app is dark under its red layer): the light ink outline and words on a dark panel, on a black
        // page, never inverted, so the layer turns it bright red on black
        let (red, _) = await page(body, script: true, head: tokens, dark: true, red: true)
        let redCall = try await look(red, "a")
        XCTAssertEqual(redCall[2], "rgb(238, 241, 244)", "the teal gives way to the ink")
        XCTAssertEqual(redCall[3...5], call[3...5])
        let ground = try await red.evaluateJavaScript(
            "getComputedStyle(document.body).backgroundColor + '|' + document.documentElement.hasAttribute('data-pm-red-light')") as? String
        XCTAssertEqual(ground, "rgb(0, 0, 0)|false")
    }

    func testAtTheLargestTextTheButtonWrapsAndNeverClips() async throws {
        // an iPhone SE's column (375 points less the page's 16 px each side), at the app's largest text, 300%
        let big = tokens + "<style>body{font-size:51px}</style>"
        let line = "<p>Call Poison Control at <span class=\"tel\" id=\"b\" data-tel=\"18002221222\">1-800-222-1222</span> now.</p>"
        let (view, _) = await page(line, script: true, head: big, width: 375)
        let fit = try await view.evaluateJavaScript("""
            (function () { var e = document.getElementById('b'), r = e.getBoundingClientRect(),
              p = e.parentNode.getBoundingClientRect();
              return [r.left >= p.left - 0.5, r.right <= p.right + 0.5, e.scrollWidth <= e.clientWidth,
                      document.documentElement.scrollWidth <= 375, r.height > 51 * 1.35 * 1.5].join('|'); })()
            """) as? String
        XCTAssertEqual(fit, "true|true|true|true|true", "inside the column, nothing hidden, wrapped onto two lines")
    }

    func testWithoutTheScriptThePageIsPlainText() async throws {
        let (view, watcher) = await page(body, script: false)
        _ = try await view.evaluateJavaScript("document.getElementById('a').click(); 1")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(watcher.links.isEmpty)
        let extra = try await view.evaluateJavaScript(
            "[document.getElementById('a').hasAttribute('role'), document.getElementsByTagName('style').length, document.getElementsByTagName('a').length].join('|')") as? String
        XCTAssertEqual(extra, "false|0|0")
    }
}

/// Our Home plan, Task 2.4: a page may dial only numbers written in an Our Home page, from the daily library's
/// household/call-numbers.json; 911 and Poison Control as ever.
@Suite struct HomeCallTests {
    let link = { (n: String) in URL(string: "prepareme://call?n=\(n)")! }

    @Test func onlyTheListedNumbersAreAdded() {
        let also = CallLinks.homeNumbers(Data(#"{"format": 1, "numbers": ["5555550142", "18005550199"]}"#.utf8))
        #expect(also == ["5555550142", "18005550199"])
        #expect(CallLinks.telURL(link("5555550142"), also: also) == URL(string: "tel:5555550142"))
        #expect(CallLinks.telURL(link("5555550143"), also: also) == nil)
        #expect(CallLinks.telURL(link("5555550142")) == nil, "not listed: never dialed")
        #expect(CallLinks.telURL(link("911"), also: also) == URL(string: "tel:911"))
        #expect(CallLinks.telURL(link("12"), also: ["12"]) == nil, "an Our Home number is 10 or 11 digits")
    }

    @Test func aFileOfAnyOtherShapeAddsNothing() {
        for text in [#"{"format": 2, "numbers": ["5555550142"]}"#, #"{"numbers": ["5555550142"]}"#,
                     #"{"format": 1, "numbers": ["555-555-0142"]}"#, #"{"format": 1, "numbers": [5555550142]}"#,
                     #"{"format": 1, "numbers": ["5555550142"], "more": 1}"#, "not json", #"[]"#] {
            #expect(CallLinks.homeNumbers(Data(text.utf8)).isEmpty, "\(text)")
        }
    }

    @Test func thePageScriptMarksAnOurHomeNumber() {
        #expect(CallLinks.pageScript.contains(".home-page .hp-call"))
        #expect(CallLinks.pageScript.contains("if (!allowed(el)) return;"))
    }

    @Test func testOtherNumbersTakeShortOnes() {
        let also = CallLinks.otherNumbers(Data(#"{"format": 1, "numbers": ["411", "5555550142", "555555555555555"]}"#.utf8))
        #expect(also == ["411", "5555550142", "555555555555555"])
        #expect(CallLinks.telURL(URL(string: "prepareme://call?n=411")!, also: also) == URL(string: "tel:411"))
        #expect(CallLinks.telURL(URL(string: "prepareme://call?n=811")!, also: also) == nil, "not listed: never dialed")
        #expect(CallLinks.otherNumbers(Data(#"{"format": 1, "numbers": ["55"]}"#.utf8)).isEmpty)
        #expect(CallLinks.otherPath == "household/call-numbers-other.json")
        #expect(CallLinks.pageScript.contains("/^[0-9]{3,15}$/"))
    }

    /// The first file stays as an app before the editor's fresh look reads it: main's rule, written out, with any
    /// other number dropping the whole file; so packer/home_calls.py puts a short number in the second file only.
    @Test func testHomeNumbersKeepMainsRule() {
        let mainRule = "1?[0-9]{10}"
        #expect(CallLinks.homePattern == mainRule)
        #expect(CallLinks.homePath == "household/call-numbers.json")
        #expect(CallLinks.homeNumbers(Data(#"{"format": 1, "numbers": ["5555550142", "15555550142"]}"#.utf8)).count == 2)
        #expect(CallLinks.homeNumbers(Data(#"{"format": 1, "numbers": ["5555550142", "411"]}"#.utf8)).isEmpty)
    }
}
