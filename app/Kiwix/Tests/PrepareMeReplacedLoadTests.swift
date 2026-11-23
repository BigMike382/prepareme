// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household's Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import WebKit
import Testing
@testable import Kiwix

/// PrepareMe (owner's Mac, 2026-11-14 19:18): Today's tab was asked for its page twice, 0.4 seconds apart. WebKit ended
/// the first load as "interrupted" (WebKitErrorDomain 102), not "cancelled" (-999), so the failure handler took it for a
/// real failure: the "Unable to load the page requested" alert, and a stop that ended the second load too, leaving a
/// blank Today with a spinner. A load the next one replaced is no failure; one that really failed still is.
@MainActor
struct PrepareMeReplacedLoadTests {
    /// Pages that answer after a moment, so a second load lands while the first is on its way; `broken` fails instead.
    private final class Pages: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        var failures: [NSError] = []
        var replaceWith: URL?  // loaded as the first page starts, as the second ask for Today did
        private var stopped: Set<ObjectIdentifier> = []  // WebKit raises on an answer to a task it stopped

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !stopped.contains(ObjectIdentifier(task)) else { return }
                guard let url = task.request.url, url.lastPathComponent != "broken.html" else {
                    task.didFailWithError(URLError(.badServerResponse))
                    return
                }
                let data = Data("<html><body>\(url.lastPathComponent)</body></html>".utf8)
                task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count,
                                            textEncodingName: "utf-8"))
                task.didReceive(data)
                task.didFinish()
            }
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard let next = replaceWith else { return }
            replaceWith = nil
            webView.load(URLRequest(url: next))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            failures.append(error as NSError)
        }
    }

    private func webView(_ pages: Pages) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(pages, forURLScheme: "replaced")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.navigationDelegate = pages
        return webView
    }

    private func settle(_ webView: WKWebView) async throws {
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<50 where webView.isLoading { try await Task.sleep(for: .milliseconds(100)) }
    }

    @Test func aLoadReplacedByTheNextIsNoFailure() async throws {
        let pages = Pages()
        let webView = webView(pages)
        let today = try #require(URL(string: "replaced://daily/index.html"))
        pages.replaceWith = today
        webView.load(URLRequest(url: try #require(URL(string: "replaced://daily/first.html"))))
        try await settle(webView)

        #expect(webView.url == today, "the second load ran")
        #expect(!webView.isLoading)
        #expect(pages.failures.count == 1, "WebKit reports the replaced load as failed")
        for failure in pages.failures {
            #expect(BrowserViewModel.replacedByNextLoad(failure, canShowMimeType: true),
                    "\(failure.domain) \(failure.code) is the next load's doing, not a failure")
        }
    }

    @Test func aLoadThatFailedIsStillAFailure() async throws {
        let pages = Pages()
        let webView = webView(pages)
        webView.load(URLRequest(url: try #require(URL(string: "replaced://daily/broken.html"))))
        try await settle(webView)

        let failure = try #require(pages.failures.first)
        #expect(!BrowserViewModel.replacedByNextLoad(failure, canShowMimeType: true))
    }

    /// 102 also follows our own refusal of a type the page can't show, which the handler saves rather than alerts.
    @Test func anInterruptionForATypeThePageCantShowIsLeftToTheSave() {
        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        #expect(BrowserViewModel.replacedByNextLoad(interrupted, canShowMimeType: true))
        #expect(!BrowserViewModel.replacedByNextLoad(interrupted, canShowMimeType: false))
        #expect(BrowserViewModel.replacedByNextLoad(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
                                                    canShowMimeType: false))
    }
}
