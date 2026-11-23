import AppKit
@testable import PrepareMeShared
import WebKit
import XCTest

/// Today in a warning on an iPhone SE (beta run 2, R9.1; mockup 1, the owner's pick): the committed pages
/// (Fixtures/today/warning.html and two-warnings.html, written by `python -m dashboard.tests.phone_cases` and pinned to
/// the Mac's render by test_phone_cases) laid out in a real web view 375 points wide, with the phone app's own live
/// script (prepareme-live.js) applied as the app applies it: the page marked as the phone's, and the rally line made
/// the street map's link, named. Measured against the SE's first screen in the phone app: the page starts under the
/// title and search bars and ends at the top of the tab bar (beta run 2's screenshots, se-05-today-dark and
/// se-50-today-axxxl: at the default text size the page starts 128 points down, at the largest 210; the tab bar's top
/// is at 585 either way).
///
/// The Mac's web view has no text size setting (iOS WebKit's -webkit-text-size-adjust, which TextSizeZoom uses, does
/// nothing here), so the largest size is laid out as iOS does it: every text three times its size (TextSizeZoom.most)
/// except an emoji (.em, the page's one text-size-adjust:none), with data-large and the breaking long words the app's
/// script sets. Checked once against the simulator's Safari at both sizes (R9.1's report).
@MainActor
final class TodayFirstScreenTests: XCTestCase {
    static let tabBarTop = 585.0
    static let pageTop = (normal: 128.0, largest: 210.0)
    static let name = "Made-up park meeting spot"

    func testAtTheDefaultSizeTheWarningFirstAidAndTheRallyLineAreOnTheFirstScreen() async throws {
        let view = try await page("warning", zoom: 1)
        let screen = Self.tabBarTop - Self.pageTop.normal
        let found = try await boxes(view)
        for part in ["headline", "instruction", "bleeding", "cpr", "burns", "guide", "rally"] {
            let box = try XCTUnwrap(found[part], part)
            XCTAssertGreaterThanOrEqual(box.top, 0, part)
            XCTAssertLessThanOrEqual(box.bottom, screen, "\(part) ends below the SE's first screen")
        }
        try order(found, ["headline", "instruction", "bleeding", "burns", "rally"])
        try beside(found, "mark", "headline")
    }

    /// Checkpoint 4's hard budget: an Extreme Wind Warning-style instruction, a long first sentence before its action
    /// (245 characters, Fixtures/today/wind-warning.html), shows its action alone, so first aid and the rally line still
    /// end on the SE's first screen at the default size.
    func testALongInstructionStillLeavesFirstAidOnTheFirstScreen() async throws {
        let view = try await page("wind-warning", zoom: 1)
        let screen = Self.tabBarTop - Self.pageTop.normal
        let found = try await boxes(view)
        for part in ["headline", "instruction", "bleeding", "cpr", "burns", "guide", "rally"] {
            let box = try XCTUnwrap(found[part], part)
            XCTAssertLessThanOrEqual(box.bottom, screen, "\(part) ends below the SE's first screen")
        }
        try order(found, ["headline", "instruction", "bleeding", "burns", "rally"])
    }

    /// Checkpoint 4 (R9.1's deferred minors): while a warning shows, the marks' row hides only that warning's own mark
    /// (it stands beside the headline); an outage's mark stays, in its row. The lead's ruling: that row then comes after
    /// the rally line, so a tornado warning with an outage still has the warning, first aid and the rally line on the
    /// SE's first screen at the default size; the outage's mark stays visible, lower.
    func testTheOutageMarkStaysWhileAWarningShows() async throws {
        let view = try await page("warning", zoom: 1)
        let shown = try await view.evaluateJavaScript("""
            (function () {
              var row = document.querySelector('#band > .marks');
              row.querySelector('[data-kind=outage]').hidden = false;
              function on(el) { return getComputedStyle(el).display !== 'none'; }
              return [on(row), on(row.querySelector('[data-kind=outage]')), on(row.querySelector('[data-kind=tornado]'))]
                .join(',');
            })()
            """) as? String
        XCTAssertEqual(shown, "true,true,false", "the row and the outage's mark show; the tornado's moved beside it")
        let found = try await boxes(view)
        let screen = Self.tabBarTop - Self.pageTop.normal
        for part in ["headline", "instruction", "bleeding", "cpr", "burns", "guide", "rally"] {
            XCTAssertLessThanOrEqual(try XCTUnwrap(found[part], part).bottom, screen,
                                     "\(part) ends below the SE's first screen with the outage's mark shown")
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(found["row"], "the marks' row").top,
                                    try XCTUnwrap(found["rally"]).bottom, "the leftover marks come after the rally line")
        let alone = try await page("warning", zoom: 1)
        let row = try await alone.evaluateJavaScript(
            "getComputedStyle(document.querySelector('#band > .marks')).display") as? String
        XCTAssertEqual(row, "none", "with only the warning's own mark in it, the row gives way")
    }

    /// The lead's ruling (R9.1 fix round 1): at the largest text the headline, the buttons and the rally line come
    /// before the instruction, so first aid starts on the first screen; VoiceOver keeps the page's order.
    func testAtTheLargestSizeFirstAidStartsOnTheFirstScreen() async throws {
        let view = try await page("warning", zoom: TextSizeZoom.most)
        let screen = Self.tabBarTop - Self.pageTop.largest
        let found = try await boxes(view)
        let headline = try XCTUnwrap(found["headline"]), bleeding = try XCTUnwrap(found["bleeding"])
        XCTAssertLessThan(headline.top, 48, "the warning starts the page: Today and the date leave the sight")
        XCTAssertLessThan(bleeding.top, screen - 48, "the first button starts on the first screen")
        XCTAssertNil(found["mark"], "no marks at the largest size")
        let tops = try ["headline", "bleeding", "cpr", "burns", "guide", "rally", "instruction"].map {
            try XCTUnwrap(found[$0], $0).top
        }
        XCTAssertEqual(tops, tops.sorted(), "one button a row, the instruction after the rally line")
    }

    /// Two warnings at once (R9.1 fix round 1): each headline beside its own mark and inside the band, each
    /// instruction under its own headline, then the buttons; and a warning the phone read itself, put in the band as
    /// its live script puts it, the same way.
    func testTwoWarningsEachBesideItsOwnMark() async throws {
        let view = try await page("two-warnings", zoom: 1)
        var found = try await boxes(view)
        try beside(found, "mark", "headline")
        try beside(found, "mark2", "headline2")
        try order(found, ["headline", "instruction", "headline2", "instruction2", "bleeding", "rally"])
        XCTAssertLessThan(try XCTUnwrap(found["bleeding"]).top, Self.tabBarTop - Self.pageTop.normal,
                          "first aid still starts on the first screen")
        // The phone's own reading of a flash flood warning, in the band before the buttons (prepareme-live.js)
        let one = try await page("warning", zoom: 1)
        let flood = ConditionItem("...FLASH FLOOD WARNING IN EFFECT UNTIL 2:45 PM EDT...", flag: "warn",
                                  expires: "2099-01-01T14:45:00-05:00", code: "FF.W", vtec: ["NEW.KLWX.FF.W.0003"],
                                  instruction: "Turn around, don't drown when encountering flooded roads.")
        let settings = try ConditionsSettings(Data(#"{"county":"Example","format":1,"gauges":[],"live_alerts":true,"nws_county":"ZZC183","nws_fire_zone":"ZZZ041","nws_zone":"ZZZ041"}"#.utf8))
        let now = Date()
        let band = LiveBlock.payload(settings, ["home-alerts": LiveReading(goodAt: now, items: [flood], triedAt: now)],
                                     now: now).band
        XCTAssertFalse(band.isEmpty)
        let json = String(decoding: try JSONEncoder().encode([band]), as: UTF8.self)
        _ = try await one.evaluateJavaScript("""
            var box = document.createElement('div'), b = document.getElementById('band');
            box.innerHTML = \(json)[0];
            while (box.firstChild) b.insertBefore(box.firstChild, document.getElementById('sos'));
            true;
            """)
        found = try await boxes(one)
        try beside(found, "mark2", "headline2")
        try order(found, ["instruction", "headline2", "instruction2", "bleeding"])
    }

    /// `parts` top to bottom, in that order; first aid two across.
    private func order(_ found: [String: Box], _ parts: [String]) throws {
        let tops = try parts.map { try XCTUnwrap(found[$0], $0).top }
        XCTAssertEqual(tops, tops.sorted(), "top to bottom: \(parts)")
        XCTAssertEqual(try XCTUnwrap(found["bleeding"]).top, try XCTUnwrap(found["cpr"]).top, "two across")
        XCTAssertEqual(try XCTUnwrap(found["burns"]).top, try XCTUnwrap(found["guide"]).top, "two across")
    }

    /// A mark on its headline's line, left of it, the headline inside the band.
    private func beside(_ found: [String: Box], _ mark: String, _ headline: String) throws {
        let m = try XCTUnwrap(found[mark], mark), h = try XCTUnwrap(found[headline], headline)
        let band = try XCTUnwrap(found["band"])
        XCTAssertLessThan(m.right, h.left, "\(mark) left of \(headline)")
        XCTAssertLessThan(abs((m.top + m.bottom) / 2 - (h.top + h.bottom) / 2), 24, "\(mark) on \(headline)'s line")
        XCTAssertLessThanOrEqual(h.right, band.right, "\(headline) inside the band")
    }

    struct Box { let top, bottom, left, right: Double }

    private let measure = """
        (function () {
          function shown(el) { return el && getComputedStyle(el).display !== 'none' ? el : null; }
          function box(el) { if (!shown(el)) return null; var r = el.getBoundingClientRect();
            return [r.top, r.bottom, r.left, r.right]; }
          var b = document.getElementById('band'), sos = document.querySelectorAll('#sos > p'), out = {band: box(b),
            row: box(b.querySelector(':scope > .marks'))},
            alerts = [], all = b.querySelectorAll('.alert'), i;
          for (i = 0; i < all.length; i++) if (!all[i].hidden) alerts.push(all[i]);
          alerts.forEach(function (a, n) {
            var k = n ? String(n + 1) : '';
            out['mark' + k] = box(a.querySelector('.mark'));
            out['headline' + k] = box(a.querySelector('span[data-expires]'));
            out['instruction' + k] = box(a.querySelector('.do'));
          });
          out.bleeding = box(sos[0]); out.cpr = box(sos[1]); out.burns = box(sos[2]); out.guide = box(sos[3]);
          out.rally = box(document.getElementById('pm-rally'));
          out.spill = Array.prototype.some.call(document.querySelectorAll('#sos a, #pm-rally a'),
            function (el) { return el.scrollWidth > el.clientWidth + 1; }) ? 1 : 0;
          return JSON.stringify(out);
        })()
        """

    private func boxes(_ view: WKWebView) async throws -> [String: Box] {
        let answer = try await view.evaluateJavaScript(measure)
        let json = try XCTUnwrap(answer as? String)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(raw["spill"] as? Int, 0, "a button's or the rally line's words run past its edge")
        var found: [String: Box] = [:]
        for (key, value) in raw {
            if let box = value as? [Double], box.count == 4 {
                found[key] = Box(top: box[0], bottom: box[1], left: box[2], right: box[3])
            }
        }
        return found
    }

    /// The page as the phone app shows it at `zoom`: its own live script applied with no feeds read (LiveBlock's
    /// limitsOnly) and the rally point's name, the map view ready; past the normal size, iOS's text scaling.
    private func page(_ name: String, zoom: Double) async throws -> WKWebView {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let html = try String(contentsOf: here.appendingPathComponent("Fixtures/today/\(name).html"), encoding: .utf8)
        let live = try String(contentsOf: here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Kiwix/PrepareMeApp/prepareme-live.js"), encoding: .utf8)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        let loaded = Loaded()
        delegates.append(loaded)
        view.navigationDelegate = loaded
        await withCheckedContinuation { done in
            loaded.done = done
            view.loadHTMLString(html, baseURL: nil)
        }
        var payload = LiveBlock.limitsOnly(host: "phone")
        payload.rally = Self.name
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        _ = try await view.evaluateJavaScript("window.PrepareMeStreetMap = true;\n\(live)\n;window.PrepareMeLive.apply(\(json)); true;")
        _ = try await view.evaluateJavaScript("""
            document.documentElement.toggleAttribute('data-large', \(zoom >= 1.5));
            document.documentElement.style.overflowWrap = '\(zoom > 1 ? "anywhere" : "")';
            if (\(zoom) > 1) {
              var all = document.querySelectorAll('body, body *'), sizes = [], i;
              for (i = 0; i < all.length; i++) sizes.push(parseFloat(getComputedStyle(all[i]).fontSize));
              for (i = 0; i < all.length; i++)
                all[i].style.fontSize = (all[i].closest('.em') ? sizes[i] : sizes[i] * \(zoom)) + 'px';
            }
            true;
            """)
        return view
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done?.resume()
            done = nil
        }
    }

    private var delegates: [Loaded] = []
}
