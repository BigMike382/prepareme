import Foundation

/// Tap-to-call (beta run 2, B2-15; owner's choice (a), 2026-10-20): "911" and Poison Control's 1-800-222-1222 in a
/// guide, a walk-through or a household page. The packer marks each in the page as `<span class="tel"
/// data-tel="NUMBER">` (packer.pages.mark_calls), words unchanged, and puts no link in the page; so the Mac and App
/// Store Kiwix, which cannot dial, show plain text. Only the phone app injects `pageScript`, which turns a marked
/// number into a tap that goes to `prepareme://call?n=NUMBER`; the app then dials with `telURL`, which accepts these
/// two numbers and nothing else (a page cannot make the phone dial any other number).
public enum CallLinks {
    /// The marked numbers (packer.pages.CALLS's, in its order; test_pages pins them equal), as the page's `data-tel`
    /// writes them.
    public static let numbers = ["911", "18002221222"]
    public static let scheme = "prepareme"
    public static let host = "call"
    /// The spoken label for the number, read by VoiceOver on the marked words.
    public static let labelPrefix = "Call "

    /// The tel: address a `prepareme://call?n=NUMBER` link means, or nil for any other link or any other number.
    /// `also`: the numbers written in the daily library's Our Home pages (`homeNumbers`), which only those pages
    /// mark (Our Home plan, Task 2.4: a page may dial only numbers written in an Our Home page).
    public static func telURL(_ url: URL) -> URL? { telURL(url, also: []) }

    public static func telURL(_ url: URL, also: Set<String>) -> URL? {
        guard url.scheme == scheme, url.host == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, items.count == 1,
              items[0].name == "n", let number = items[0].value,
              numbers.contains(number) || (also.contains(number) && GuideTopics.matches(number, anyPattern))
        else { return nil }
        return URL(string: "tel:\(number)")
    }

    /// The daily library's files of Our Home numbers (packer/home_calls.py): `homePath` holds the ones every app
    /// accepts (`homePattern`: an app before the editor's fresh look drops the whole file for any other), `otherPath`
    /// the rest (411, a short code: the editor plan, Task 1). The app dials a number in either.
    public static let homePath = "household/call-numbers.json"
    public static let otherPath = "household/call-numbers-other.json"
    public static let homePattern = "1?[0-9]{10}"
    static let anyPattern = "[0-9]{3,15}"  // packer/steps.py's _CALL

    /// The numbers in `homePath`'s file, `{"format": 1, "numbers": [...]}`; nothing for any other shape.
    public static func homeNumbers(_ data: Data) -> Set<String> { numbers(data, homePattern) }

    /// The numbers in `otherPath`'s file, the same shape with any Our Home number.
    public static func otherNumbers(_ data: Data) -> Set<String> { numbers(data, anyPattern) }

    static func numbers(_ data: Data, _ pattern: String) -> Set<String> {
        guard GuideTopics.keysAreOnceAndNumbersWhole(data),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(top.keys) == ["format", "numbers"], GuideTopics.count(top["format"]) == 1,
              let found = top["numbers"] as? [String], found.allSatisfy({ GuideTopics.matches($0, pattern) })
        else { return [] }
        return Set(found)
    }

    /// Whether a page gets the script: phones only (owner's choice); an iPad, the Mac and App Store Kiwix never do.
    public static func injectsScript(isPhone: Bool) -> Bool { isPhone }

    /// The number to dial for a navigation, or nil. Only a link activation dials (WKNavigationType.linkActivated: a
    /// tapped link, or a script's click on an anchor, as the page script makes on a tap; WebKit can't tell those two
    /// apart, so `telURL`'s two numbers are the real guard); a script's location change, a form, another app's or a QR
    /// code's prepareme:// address never does.
    public static func dial(_ url: URL, linkActivated: Bool, also: Set<String> = []) -> URL? {
        linkActivated ? telURL(url, also: also) : nil
    }

    /// The phone icon before each number on its button (owner's choice by click, 2026-10-21): decorative, hidden from
    /// VoiceOver, which reads the label alone.
    public static let icon = "📞"

    /// The look of a marked number on a phone: a small button in the sentence, "📞 911" (owner's choice by click,
    /// 2026-10-21), in the reading pages' button look (packer.reading_style's `button`: panel, 12 px corners, its
    /// weight) with an ink outline, from the page's own tokens, so the dark and red night screens recolor it as they
    /// do the page (red night: all red on black). It sits on the line as a word does, and a number wider than the line
    /// at the largest text wraps inside it, never clipped. A margin of tap above and below it (`::after`) adds nothing
    /// to the line's height, nor any width a page could scroll to. Only the two numbers get it: any other mark stays
    /// plain text.
    public static let style = ".tel[data-tel][role=link]{display:inline-block;max-width:100%;padding:0 .4em;"
        + "border:1px solid var(--link,currentColor);border-radius:12px;background:var(--panel,transparent);"
        + "color:var(--text);font-weight:600;line-height:1.35;text-decoration:none;overflow-wrap:anywhere;"
        + "position:relative;cursor:pointer}"
        + ".tel[data-tel][role=link]::after{content:\"\";position:absolute;inset:-.3em 0}"
        + ".tel[data-tel][role=link]>.tel-icon{margin-right:.25em}"
        + ".tel[data-tel][role=link]:focus-visible{outline:3px solid var(--link,currentColor);outline-offset:2px}"

    /// Run at each page's end, phone only (WebViewConfiguration). It makes each marked number a button (`style`, the
    /// icon before it), gives it a keyboard and VoiceOver role and label, and sends a tap to `prepareme://call`;
    /// nothing else on the page changes.
    public static let pageScript: String = """
        (function () {
          var ok = [\(numbers.map { "'\($0)'" }.joined(separator: ","))];
          var style = document.createElement('style');
          style.textContent = \(String(reflecting: style));  // a quoted string, as JavaScript reads one
          document.head.appendChild(style);
          // an Our Home page's own number to call (its step's call: line, already drawn with its icon and words);
          // only the numbers the daily library lists ever dial (telURL's `also`)
          function home(el) { return !!el.closest('.home-page .hp-call') && /^[0-9]{3,15}$/.test(el.getAttribute('data-tel')); }
          function allowed(el) { return ok.indexOf(el.getAttribute('data-tel')) >= 0 || home(el); }
          var marked = document.querySelectorAll('.tel[data-tel]'), i;
          for (i = 0; i < marked.length; i++) {
            if (!allowed(marked[i]) || marked[i].hasAttribute('role')) continue;
            marked[i].setAttribute('role', 'link');
            marked[i].setAttribute('tabindex', '0');
            if (home(marked[i])) { marked[i].setAttribute('aria-label', marked[i].textContent); continue; }
            marked[i].setAttribute('aria-label', '\(labelPrefix)' + marked[i].textContent);  // before the icon
            var icon = document.createElement('span');
            icon.className = 'tel-icon';
            icon.setAttribute('aria-hidden', 'true');
            icon.textContent = '\(icon)';
            marked[i].insertBefore(icon, marked[i].firstChild);
          }
          function call(el) {
            var n = el.getAttribute('data-tel');
            if (!allowed(el)) return;
            // a clicked link, so the app can tell a tap from a script's own navigation
            var a = document.createElement('a');
            a.href = 'prepareme://call?n=' + n;
            a.style.display = 'none';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
          }
          document.addEventListener('click', function (e) {
            var el = e.target && e.target.closest && e.target.closest('.tel[data-tel]');
            if (el) { e.preventDefault(); call(el); }
          });
          document.addEventListener('keydown', function (e) {
            var el = e.target && e.target.closest && e.target.closest('.tel[data-tel]');
            if (el && e.key === 'Enter') { e.preventDefault(); call(el); }
          });
        })();
        """
}
