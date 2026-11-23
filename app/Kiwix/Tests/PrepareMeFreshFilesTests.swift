// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household's Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import WebKit
import Testing
@testable import Kiwix

/// PrepareMe (games plan, section 41; the owner's iPhone, 2026-11-20): after a games delivery under the same ID, the
/// card table left open loaded its new page with its old style file. WebKit keeps a zim: style, script or picture
/// for as long as its web process lives and never asks the file server again, unless the answer says not to keep
/// it. The headers here are the reader's own (HTTPSuccess), so a changed file under the same address loads fresh.
@MainActor
struct PrepareMeFreshFilesTests {
    private final class Files: NSObject, WKURLSchemeHandler {
        var style = "body{color:rgb(255,0,0)}"
        var asked: [String] = []

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            asked.append(url.lastPathComponent)
            let page = url.lastPathComponent == "kit.css"
            let html = "<html><head><link rel=stylesheet href='kit.css'></head><body>x</body></html>"
            let body = Data((page ? style : html).utf8)
            let meta = URLContentMetaData(mime: page ? "text/css" : "text/html", size: UInt(body.count),
                                          zimTitle: "made up", lastModified: Date().addingTimeInterval(-86_400))
            guard let response = HTTPSuccess.response(url: url, metaData: meta, requestedRange: nil) else { return }
            task.didReceive(response)
            task.didReceive(body)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    private func color(after url: URL, in webView: WKWebView) async throws -> String {
        webView.load(URLRequest(url: url))
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            if !webView.isLoading, let color = try? await webView.evaluateJavaScript(
                "getComputedStyle(document.body).color") as? String { return color }
        }
        return "not loaded"
    }

    @Test func aChangedStyleUnderTheSameAddressLoadsFresh() async throws {
        let files = Files()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(files, forURLScheme: "zim")  // the headers' policy allows only zim:
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), configuration: configuration)
        let page = try #require(URL(string: "zim://games/cardtable/index.html"))
        #expect(try await color(after: page, in: webView) == "rgb(255, 0, 0)")
        files.style = "body{color:rgb(0, 0, 255)}"  // the delivery: same address, new contents
        files.asked = []
        #expect(try await color(after: page, in: webView) == "rgb(0, 0, 255)")
        #expect(files.asked.contains("kit.css"))
    }

    /// The packer's stamp (games plan, section 41): every app reads a file by its address's path alone
    /// (URL.contentPath, as in Kiwix 3.17.1), so `kit.css?v=…` finds kit.css; were the query read, every game would
    /// break on that device at the next delivery.
    @Test func aStampedAddressFindsTheSameFile() throws {
        let id = "0F1E2D3C-4B5A-4968-8776-6554433221C9"
        let page = try #require(URL(string: "zim://\(id)/cardtable/index.html"))
        for (stamped, path) in [("../kit/kit.css?v=hlilcdfinndi", "kit/kit.css"),
                                ("assets/felt.jpg?v=hlilcdfinndi", "cardtable/assets/felt.jpg"),
                                ("../kit/ours.json?v=hlilcdfinndi", "kit/ours.json")] {
            let url = try #require(URL(string: stamped, relativeTo: page)?.absoluteURL)
            #expect(url.contentPath == path)
            #expect(url.zimFileID == UUID(uuidString: id))
        }
    }
}
