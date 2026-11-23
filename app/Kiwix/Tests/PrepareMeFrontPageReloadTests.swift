// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household's Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import WebKit
import XCTest
@testable import Kiwix

/// PrepareMe (FINDINGS F-096): a library reopened while a tab's page is still loading. WebKit's `reload()` between a
/// page's start and its commit hands back a load that never runs, and the web view says it is loading for good though
/// the page finished: Today a spinner over its loaded page, the first start after an install. So the front pages'
/// reload waits for the page to finish, then reloads it once: after commit the page's text may have come from the
/// old file, and dropping the reload left Today on the old library until the next check (the 2026-10-25 review).
@MainActor
final class PrepareMeFrontPageReloadTests: XCTestCase {
    /// A page with a picture that both answer after a moment, so a reload lands while the page is on its way; the
    /// reload is asked for as the page starts (as the launch's first library check did) or once its text is in.
    private final class SlowPages: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        enum When { case start, commit }
        let when: When
        private(set) var pagesServed = 0
        private var asked = false

        init(reloadAt when: When) { self.when = when }

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let picture = task.request.url?.lastPathComponent == "slow.svg"
            if !picture { pagesServed += 1 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                let body = picture ? "<svg xmlns='http://www.w3.org/2000/svg'/>"
                                   : "<html><body>Today <img src='slow.svg'></body></html>"
                let data = Data(body.utf8)
                task.didReceive(URLResponse(url: task.request.url!, mimeType: picture ? "image/svg+xml" : "text/html",
                                            expectedContentLength: data.count, textEncodingName: "utf-8"))
                task.didReceive(data)
                task.didFinish()
            }
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

        private func ask(_ webView: WKWebView, _ now: When) {
            guard now == when, !asked else { return }
            asked = true
            BrowserViewModel.reloadWhenSettled(webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            ask(webView, .start)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            XCTAssertTrue(webView.isLoading, "the picture is still on its way")
            ask(webView, .commit)
        }
    }

    private func load(reloadAt when: SlowPages.When) async throws -> (SlowPages, WKWebView) {
        let pages = SlowPages(reloadAt: when)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(pages, forURLScheme: "f096")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.navigationDelegate = pages
        webView.load(URLRequest(url: try XCTUnwrap(URL(string: "f096://daily/index.html"))))
        for _ in 0..<100 where pages.pagesServed < 2 || webView.isLoading {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(1))  // a load that was going to run has started by now
        return (pages, webView)
    }

    func testAFrontPageReloadMidLoadLeavesTheTabSettled() async throws {
        let (pages, webView) = try await load(reloadAt: .start)
        XCTAssertFalse(webView.isLoading, "the page finished, so nothing is loading")
        XCTAssertEqual(pages.pagesServed, 2, "the page read again once it finished")
    }

    func testAFrontPageReloadAfterCommitReadsTheNewFile() async throws {
        let (pages, webView) = try await load(reloadAt: .commit)
        XCTAssertEqual(pages.pagesServed, 2, "the page, maybe from the old file, read again once it finished")
        XCTAssertFalse(webView.isLoading)
    }
}
