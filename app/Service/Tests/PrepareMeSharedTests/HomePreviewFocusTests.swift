#if os(macOS)
import AppKit
@testable import PrepareMeShared
import Testing
import WebKit

/// Edit Our Home (the owner's Mac, 2026-11-18): typing in a step's box, the box let go of the keyboard partway through a
/// sentence and the next keys beeped. The preview refreshes 0.3 s after the last key and goes back to its screen; that
/// jump (`location.hash`) and the page's own `focus()` on the screen each moved the window's focus into the preview.
/// HomePage.previewShow and previewNoFocus, as the Mac's PreviewWeb uses them, leave the box the keyboard.
@MainActor
struct HomePreviewFocusTests {
    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// Whether a text box beside the page keeps the keyboard after `go` takes the page to step 2, and the page's hash.
    private func afterGoing(_ go: String, noFocus: Bool,
                            page: HouseholdPage = HouseholdPage(title: "SAMPLE", steps: [.init(words: "SAMPLE one."),
                                                                                      .init(words: "SAMPLE two.")]),
                            fill: Bool = false) async throws -> (kept: Bool, hash: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let box = NSTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
        let configuration = WKWebViewConfiguration()
        if noFocus {
            configuration.userContentController.addUserScript(
                WKUserScript(source: HomePage.previewNoFocus, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: NSRect(x: 320, y: 10, width: 460, height: 380), configuration: configuration)
        let loaded = Loaded()
        web.navigationDelegate = loaded
        window.contentView?.addSubview(box)
        window.contentView?.addSubview(web)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(box))
        await withCheckedContinuation { loaded.done = $0; web.loadHTMLString(HomePage.document(page, guideTitles: [:]), baseURL: nil) }
        if fill { try await Self.fill(web) }
        _ = try await web.evaluateJavaScript(go + "; 0")
        try await Task.sleep(for: .milliseconds(500))
        let hash = try await web.evaluateJavaScript("location.hash") as? String ?? ""
        let editor = window.firstResponder as? NSTextView
        return (editor != nil && editor === box.currentEditor(), hash)
    }

    @Test func thePreviewGoesToItsScreenWithoutTakingTheBox() async throws {
        let quiet = try await afterGoing(HomePage.previewShow("#step-2"), noFocus: true)
        #expect(quiet.kept)
        #expect(quiet.hash == "#step-2")
        // the jump it replaced took the box, so the check can tell
        let jump = try await afterGoing("location.hash = '#step-2'", noFocus: false)
        #expect(!jump.kept)
    }

    /// The editor plan's Review focus 4: the new parts (a picked place, a number, a guide, a manual and a thing) are
    /// filled in the preview as a phone fills them, and the box beside it still keeps the keyboard.
    @Test func theNewPartsFilledKeepTheBox() async throws {
        let page = HouseholdPage(title: "SAMPLE", things: [.init(id: 8, words: "SAMPLE wrench")], steps: [
            .init(words: "SAMPLE one."),
            .init(words: "SAMPLE two.", guide: "radio", call: .init(number: "911", label: "SAMPLE emergency"),
                  place: .init(id: 2, words: "SAMPLE Garage › SAMPLE Utility shelf"),
                  manual: .init(id: 7, words: "SAMPLE Generator")),
        ])
        let after = try await afterGoing(HomePage.previewShow("#step-2"), noFocus: true, page: page, fill: true)
        #expect(after.kept)
        #expect(after.hash == "#step-2")
    }

    /// PrepareMeOurHome.fill's two trips, over the made-up copy, through the same shared steps it takes
    /// (HomeSlots.readScript, HomeSlots.picked, HomeSlots.script); only its manual-on-this-device check, app-side, is left out.
    static func fill(_ web: WKWebView) async throws {
        let slots = try await web.evaluateJavaScript(HomeSlots.readScript) as? [[String]] ?? []
        let (places, items) = HomeSlots.picked(slots, in: HomeSlotsTests.copy(), links: true)
        #expect(places.count == 1 && items.count == 2, "the place, the manual and the thing")
        _ = try await web.evaluateJavaScript(HomeSlots.script(meet: [], kept: [:], places: places, items: items) + "; 0")
        let filled = try await web.evaluateJavaScript("document.querySelectorAll('.hp-filled').length") as? Int
        #expect(filled == 3, "each filled where its id says")
    }

    /// The design session's second review (2026-11-20): a picked thing's row names it once, with its current name
    /// (item 8 was picked as "SAMPLE old wrench" and is now "SAMPLE wrench"), then its place; a typed thing is its words.
    @Test func aPickedThingShowsItsNameOnce() async throws {
        let page = HouseholdPage(title: "SAMPLE", things: [.init(id: 8, words: "SAMPLE old wrench"),
                                                           .init(id: nil, words: "SAMPLE old towels")],
                                 steps: [.init(words: "SAMPLE one.")])
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { loaded.done = $0; web.loadHTMLString(HomePage.document(page, guideTitles: [:]), baseURL: nil) }
        let slots = try await web.evaluateJavaScript(HomeSlots.readScript) as? [[String]] ?? []
        let (places, items) = HomeSlots.picked(slots, in: HomeSlotsTests.copy(), links: true)
        _ = try await web.evaluateJavaScript(HomeSlots.script(meet: [], kept: [:], places: places, items: items) + "; 0")
        let rows = try await web.evaluateJavaScript(
            "[].map.call(document.querySelectorAll('.hp-need > li'), function (li) { return li.innerText.replace(/\\s+/g, ' ').trim(); })") as? [String]
        #expect(rows == ["SAMPLE wrench 📍 SAMPLE Garage › SAMPLE Tool chest", "SAMPLE old towels"])
    }

    @Test func thePageShowsTheScreenFromTheQuietChange() async throws {
        // the page's own script, run by the hashchange, shows step 2 and hides the start screen
        let page = HouseholdPage(title: "SAMPLE", steps: [.init(words: "SAMPLE one."), .init(words: "SAMPLE two.")])
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { loaded.done = $0; web.loadHTMLString(HomePage.document(page, guideTitles: [:]), baseURL: nil) }
        _ = try await web.evaluateJavaScript(HomePage.previewShow("#step-2") + "; 0")
        let shown = try await web.evaluateJavaScript(
            "[].filter.call(document.querySelectorAll('.hp-screen'), function (s) { return !s.hidden && getComputedStyle(s).display !== 'none'; }).map(function (s) { return s.id; }).join(',')") as? String
        #expect(shown == "step-2")
    }
}
#endif
