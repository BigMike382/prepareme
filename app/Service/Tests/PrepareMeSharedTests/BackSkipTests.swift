import AppKit
@testable import PrepareMeShared
import WebKit
import XCTest

/// Back or Forward onto a page the library no longer has (owner's phone, 2026-10-21): the step goes quietly past it,
/// never round to it again; and a tab's page loaded again at launch takes its own entry, never a second one.
@MainActor
final class BackSkipTests: XCTestCase {
    private func pages(_ names: String...) -> [URL] { names.map { URL(string: "zim://lib/\($0)")! } }

    func testBackGoesToTheEntryBeforeTheGonePage() {
        let list = pages("a", "b", "gone", "shown")
        // as WebKit has it while deciding: the cursor already on the gone entry
        XCTAssertEqual(BackSkip.step(entries: list, cursor: 2, gone: list[2], shown: 3), .go(1))
        // and if it hadn't moved yet
        XCTAssertEqual(BackSkip.step(entries: list, cursor: 3, gone: list[2], shown: 3), .go(1))
    }

    func testBackWithNothingBeforeTheGonePageGoesToTheStartPage() {
        let list = pages("gone", "guides")
        XCTAssertEqual(BackSkip.step(entries: list, cursor: 0, gone: list[0], shown: 1), .startPage)
    }

    func testForwardGoesToTheEntryAfterTheGonePageOrStays() {
        let list = pages("shown", "gone", "c")
        XCTAssertEqual(BackSkip.step(entries: list, cursor: 1, gone: list[1], shown: 0), .go(2))
        let last = pages("shown", "gone")
        XCTAssertEqual(BackSkip.step(entries: last, cursor: 1, gone: last[1], shown: 0), .stay)
    }

    func testARestoredTabsOwnGonePageGoesBack() {
        // restored at launch: nothing on screen yet, the cursor on the tab's own page
        let list = pages("a", "gone")
        XCTAssertEqual(BackSkip.step(entries: list, cursor: 1, gone: list[1], shown: nil), .go(0))
        let alone = pages("gone")
        XCTAssertEqual(BackSkip.step(entries: alone, cursor: 0, gone: alone[0], shown: nil), .startPage)
    }

    func testNeverTheGoneEntryItselfAndAHeadingIsTheSamePage() {
        let list = pages("a", "gone#part", "shown")
        let gone = URL(string: "zim://lib/gone")!
        XCTAssertEqual(BackSkip.step(entries: list, cursor: 1, gone: gone, shown: 2), .go(0))
        for cursor in list.indices {
            for shown in [nil] + list.indices.map(Optional.some) {
                XCTAssertNotEqual(BackSkip.step(entries: list, cursor: cursor, gone: gone, shown: shown), .go(1))
            }
        }
    }

    func testAPageNotInTheListOrAnEmptyListStays() {
        let list = pages("a", "b")
        XCTAssertEqual(BackSkip.step(entries: list, cursor: 1, gone: pages("x")[0], shown: 1), .stay)
        XCTAssertEqual(BackSkip.step(entries: [], cursor: 0, gone: list[0], shown: nil), .stay)
    }

    func testALinkToAGonePageSaysSoInPrepareMesWords() {
        XCTAssertEqual(BackSkip.goneWords(device: "phone"), "This page isn't in the library on this phone.")
        XCTAssertEqual(BackSkip.goneWords(device: "iPad"), "This page isn't in the library on this iPad.")
    }

    func testTheStartPageGoesToItsEntryAlreadyInTheListElseLoads() {
        let start = pages("guides.html")[0]
        // a skip that opened the guide list before: its entry ahead of the guide on screen, so no new one
        XCTAssertEqual(BackSkip.startEntry(entries: pages("gone", "guide", "guides.html"), start: start, shown: 1), 2)
        // one behind the page on screen comes first
        XCTAssertEqual(BackSkip.startEntry(entries: pages("guides.html", "x", "guide", "guides.html#top"), start: start,
                                           shown: 2), 0)
        XCTAssertNil(BackSkip.startEntry(entries: pages("gone", "guide"), start: start, shown: 1))
        XCTAssertNil(BackSkip.startEntry(entries: pages("gone", "guides.html"), start: start, shown: 1), "never the page on screen")
    }

    func testAScrolledRestoredTodayIsPutAtItsTopAndStillGetsTheSearchBar() {
        // the bars over Today (the search drawer open) and the page where it was left, as WebKit restores it
        let inset = 170.0, restored = 3000.0
        XCTAssertFalse(FreshStart.atTop(offset: restored, inset: inset), "left there, the search bar was skipped")
        let top = FreshStart.topOffset(inset: inset)
        XCTAssertEqual(top, -170)
        XCTAssertTrue(FreshStart.atTop(offset: top, inset: inset), "at its top, the search bar is drawn in")
        XCTAssertFalse(FreshStart.atTop(offset: 40, inset: inset), "a page the person scrolled is left alone")
    }

    // MARK: A real web view

    /// Serves any page, as a library would; the delegate says which are gone.
    private final class Library: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let url = task.request.url!
            let page = "<!doctype html><title>\(url.path)</title><p>\(url.path)</p><div style=\"height:8000px\"></div>"
            let data = Data(page.utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count,
                                        textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    /// BrowserViewModel's part, as the app does it: a gone page on a back or forward step is cancelled and skipped.
    private final class Reader: NSObject, WKNavigationDelegate {
        var gone: Set<String> = []
        var turnAway = false  // a library not open yet, just after a start
        var shown: WKBackForwardListItem?
        var startPage: URL?
        var finished: CheckedContinuation<Void, Never>?
        var types: [WKNavigationType] = []

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            shown = webView.backForwardList.currentItem
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished?.resume()
            finished = nil
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            types.append(action.navigationType)
            guard let url = action.request.url else { return .cancel }
            if turnAway { return .cancel }
            guard gone.contains(url.path) else { return .allow }
            guard action.navigationType == .backForward else { return .cancel }
            let list = webView.backForwardList
            guard let current = list.currentItem else { return .cancel }
            let items = list.backList + [current] + list.forwardList
            let shownAt = shown.flatMap { shown in items.firstIndex { $0 === shown } }
            switch BackSkip.step(entries: items.map(\.url), cursor: list.backList.count, gone: url, shown: shownAt) {
            case .go(let index):
                let item = items[index]
                Task { @MainActor in webView.go(to: item) }
            case .startPage:
                if let startPage { Task { @MainActor in webView.load(URLRequest(url: startPage)) } }
            case .stay:
                break
            }
            return .cancel
        }
    }

    private var readers: [Reader] = []

    private func view() -> (WKWebView, Reader) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(Library(), forURLScheme: "zim")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), configuration: configuration)
        let reader = Reader()
        readers.append(reader)
        view.navigationDelegate = reader
        return (view, reader)
    }

    private func open(_ view: WKWebView, _ reader: Reader, _ names: String...) async {
        for name in names {
            await withCheckedContinuation { done in
                reader.finished = done
                view.load(URLRequest(url: pages(name)[0]))
            }
        }
    }

    private func settle(_ reader: Reader, _ step: () -> Void) async {
        await withCheckedContinuation { done in
            reader.finished = done
            step()
        }
    }

    private func paths(_ view: WKWebView) -> String {
        let list = view.backForwardList
        let current = "[" + (list.currentItem?.url.lastPathComponent ?? "") + "]"
        return (list.backList.map { $0.url.lastPathComponent } + [current] + list.forwardList.map { $0.url.lastPathComponent })
            .joined(separator: " ")
    }

    func testBackAndForwardGoPastGonePagesOnARealWebView() async {
        let (view, reader) = view()
        await open(view, reader, "a", "b", "c", "d", "e")
        reader.gone = ["/c", "/d"]
        await settle(reader) { view.goBack() }
        XCTAssertEqual(view.url?.lastPathComponent, "b")
        XCTAssertEqual(paths(view), "a [b] c d e")
        await settle(reader) { view.goForward() }
        XCTAssertEqual(view.url?.lastPathComponent, "e", "forward past both, never back onto b")
        XCTAssertEqual(paths(view), "a b c d [e]")
    }

    func testBackWithOnlyGonePagesBehindOpensTheStartPage() async {
        let (view, reader) = view()
        await open(view, reader, "gone", "walkthrough")
        reader.gone = ["/gone"]
        reader.startPage = pages("guides.html")[0]
        await settle(reader) { view.goBack() }
        XCTAssertEqual(view.url?.lastPathComponent, "guides.html")
    }

    func testARestoredTabsPageLoadedAgainTakesItsOwnEntry() async throws {
        let (before, beforeReader) = view()
        await open(before, beforeReader, "a", "guides.html")
        let saved = before.interactionState

        // restored, its page turned away while the libraries open; then loaded again
        let (loaded, loadedReader) = view()
        loadedReader.turnAway = true
        loaded.interactionState = saved
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(loadedReader.types, [.backForward], "a restored tab's page is a back-forward step")
        loadedReader.turnAway = false
        await settle(loadedReader) { loaded.load(URLRequest(url: pages("guides.html")[0])) }
        XCTAssertEqual(paths(loaded), "a guides.html [guides.html]", "load puts a second entry behind it")

        let (reopened, reopenedReader) = view()
        reopenedReader.turnAway = true
        reopened.interactionState = saved
        try await Task.sleep(nanoseconds: 300_000_000)
        reopenedReader.turnAway = false
        let item = try XCTUnwrap(reopened.backForwardList.currentItem)
        await settle(reopenedReader) { reopened.go(to: item) }
        XCTAssertEqual(paths(reopened), "a [guides.html]", "its own entry: nothing new behind Back")

        // and on a page already on screen (Today's tab made only after the libraries opened) it loads it again, no more
        let shownItem = try XCTUnwrap(reopened.backForwardList.currentItem)
        reopened.go(to: shownItem)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(paths(reopened), "a [guides.html]")
        XCTAssertFalse(reopened.isLoading)
        XCTAssertEqual(reopened.url?.lastPathComponent, "guides.html")
    }

    func testAPageReloadedOnItsEntryComesBackScrolledSoTodayIsPutAtItsTop() async throws {
        let (before, beforeReader) = view()
        await open(before, beforeReader, "a", "front")
        _ = try await before.evaluateJavaScript("window.scrollTo(0, 3000); 1")
        try await Task.sleep(nanoseconds: 300_000_000)
        // the session as saved, the page's place with it (WebKit records it when the page is left; the app saves its
        // tabs as they move on and come back)
        await open(before, beforeReader, "b")
        await settle(beforeReader) { before.goBack() }
        let saved = before.interactionState

        let (today, reader) = view()
        reader.turnAway = true
        today.interactionState = saved
        try await Task.sleep(nanoseconds: 300_000_000)
        reader.turnAway = false
        let item = try XCTUnwrap(today.backForwardList.currentItem)
        await settle(reader) { today.go(to: item) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let scrolled = try await today.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(scrolled, 3000, "WebKit puts it back where it was, as on Back (why the app puts it at its top)")
        // the app's step once it has loaded (on the phone, the scroll view's offset to FreshStart.topOffset): it stays
        _ = try await today.evaluateJavaScript("window.scrollTo(0, 0); 1")
        try await Task.sleep(nanoseconds: 500_000_000)
        let top = try await today.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(top, 0, "nothing puts it back down after")
        XCTAssertEqual(paths(today), "a [front] b")
    }
}
