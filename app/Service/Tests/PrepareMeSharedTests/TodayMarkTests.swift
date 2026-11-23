import Foundation
@testable import PrepareMeShared
import Testing
import WebKit

/// The Today tab's red mark (look 3, spec section 9; plan Task 4.3): read from Today's page as it shows, after the
/// page's own script and the phone's live script, so it is the page's own condition. The truth table runs on the
/// committed event-mode pages (Fixtures/today, written by `python -m dashboard.tests.phone_cases`), and on the same
/// page out of event mode (data-mode "preparing", as the page's own script sets it; the fixtures carry no script), with
/// and without a Needs action line.
@MainActor
struct TodayMarkTests {
    @Test(arguments: ["warning", "wind-warning", "two-warnings"])
    func anEventModePageMarksTheTab(_ name: String) async throws {
        #expect(try await read(page(name)) == true)
    }

    @Test func aPageOutOfEventModeWithNothingNeedingActionClearsTheMark() async throws {
        #expect(try await read(preparing()) == false)
    }

    @Test func aNeedsActionLineMarksTheTabOutsideEventModeToo() async throws {
        #expect(try await read(preparing(), then: """
            var box = document.createElement('div'), line = document.createElement('p');
            box.className = 'answer'; line.className = 'needs'; box.appendChild(line);
            document.getElementById('conditions').appendChild(box);
            """) == true)
    }

    @Test func aPageWithoutConditionsLeavesTheMarkAsItWas() async throws {
        #expect(try await read("<!doctype html><html><body><h1>A guide</h1></body></html>") == nil)
    }

    @Test func theMarkSaysNeedsAction() {
        #expect(TodayMark.badge == "!")
        #expect(TodayMark.spoken == "Needs action")
    }

    // MARK: Helpers

    func preparing() throws -> String {
        let html = try page("warning")
        #expect(html.contains("data-mode=\"event\""))
        return html.replacingOccurrences(of: "data-mode=\"event\"", with: "data-mode=\"preparing\"")
    }

    func page(_ name: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(contentsOf: here.appendingPathComponent("Fixtures/today/\(name).html"), encoding: .utf8)
    }

    /// Loads `html`, applies the phone's live script as the app does, runs `then`, and reads the mark.
    func read(_ html: String, then extra: String = "") async throws -> Bool? {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let live = try String(contentsOf: here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Kiwix/PrepareMeApp/prepareme-live.js"), encoding: .utf8)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        let loaded = Loaded()
        view.navigationDelegate = loaded
        await withCheckedContinuation { done in
            loaded.done = done
            view.loadHTMLString(html, baseURL: nil)
        }
        let json = String(decoding: try JSONEncoder().encode(LiveBlock.limitsOnly(host: "phone")), as: UTF8.self)
        let found = try await view.evaluateJavaScript(
            live + "\n;if (document.getElementById('conditions')) window.PrepareMeLive.apply(\(json));\n" + extra
                + "\n;" + TodayMark.probe)
        return TodayMark.needsAction(found)
    }

    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done?.resume()
            done = nil
        }
    }
}
