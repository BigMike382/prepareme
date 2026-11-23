import AppKit
import PrepareMeShared
import WebKit
import XCTest

/// The red night screen's page script (phase D), in a real web view: whatever a page's own colors, a blank spot on it
/// comes out dark while red (a page with no colors of its own, one painted white, one with dark text and no
/// background, the packer's with `--bg` black), an open page follows the switch, and turning it off leaves the page as
/// built, with nothing of the script's left in it.
@MainActor
final class RedNightTests: XCTestCase {
    func testTheWords() {
        XCTAssertEqual(RedNight.key, "PrepareMe.redNight")
        XCTAssertEqual(RedNight.title, "Red night screen")
    }

    let ask = """
        [document.documentElement.hasAttribute('data-pm-red-light'),
         getComputedStyle(document.body).getPropertyValue('--bg').trim(),
         !!document.getElementById('pm-red-style')].join('|')
        """

    func testEveryKindOfPageComesOutDark() async throws {
        let pages = [
            "plain": "<p>SAMPLE</p>",
            "white": "<body style='background:#fff;color:#000'><p>SAMPLE</p></body>",
            "dark text": "<style>body{color:#222}</style><body><p>SAMPLE</p></body>",
            "packer": "<style>body{--bg:#151b22;background:var(--bg);color:#eef1f4}</style><body><p>SAMPLE</p></body>",
        ]
        for (name, html) in pages {
            let view = try await page(html, red: true)
            let blank = try await brightness(view)
            XCTAssertLessThan(blank, 0.2, "\(name): a blank spot comes out dark")
        }
        let built = try await page(pages["packer"]!, red: true)
        let s1 = try await state(built)
        XCTAssertEqual(s1, "false|#000|true", "the packer's page: its own dark, the background true black")
        let lit = try await page(pages["white"]!, red: true)
        let s2 = try await state(lit)
        XCTAssertEqual(s2, "true|#000|true", "a white page is inverted")
    }

    func testOffLeavesThePageAsBuilt() async throws {
        let white = "<body style='background:#fff;color:#000'><p>SAMPLE</p></body>"
        let lit = try await page(white, red: true)
        _ = try await lit.evaluateJavaScript(RedNight.push(on: false))
        let s1 = try await state(lit)
        XCTAssertEqual(s1, "false||false")
        let off = try await page(white, red: false)
        let s2 = try await state(off)
        XCTAssertEqual(s2, "false||false", "nothing added while off")
        let blank = try await brightness(off)
        XCTAssertGreaterThan(blank, 0.8, "white as built")
        _ = try await off.evaluateJavaScript(RedNight.push(on: true))
        let s3 = try await state(off)
        XCTAssertEqual(s3, "true|#000|true", "an open page follows the switch")
    }

    private func state(_ view: WKWebView) async throws -> String? {
        try await view.evaluateJavaScript(ask) as? String
    }

    /// The brightness, 0 to 1, of a blank spot near the page's bottom right corner.
    private func brightness(_ view: WKWebView) async throws -> Double {
        let image = try await view.takeSnapshot(configuration: nil)
        let rep = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init))
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 10, y: rep.pixelsHigh - 10)?.usingColorSpace(.sRGB))
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done?.resume()
            done = nil
        }
    }

    private var delegates: [Loaded] = []

    private func page(_ html: String, red: Bool) async throws -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: RedNight.pageScript(on: red), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        let loaded = Loaded()
        delegates.append(loaded)
        view.navigationDelegate = loaded
        await withCheckedContinuation { done in
            loaded.done = done
            view.loadHTMLString("<!doctype html><html><head></head>\(html)</html>", baseURL: nil)
        }
        return view
    }
}
