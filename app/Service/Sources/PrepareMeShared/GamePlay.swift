import Foundation

/// Full-screen play (games plan, phase 3b, package B): which pages of the games file the app shows full screen, the
/// mark that tells such a page so, and where Done sits. Shared so `swift test` runs the page script in a real web view.
public enum GamePlay {
    /// On `<html>` of a game page shown full screen, value "1" (as `data-pm-red` marks the red night screen).
    public static let attribute = "data-pm-full"
    /// The page script's message to the app: whether the page now asks for edge to edge (`viewport-fit=cover`).
    public static let handler = "pmFull"

    /// Whether `url` is a game page: any page of the games file (`gamesID`) but its front page, the Games list, and
    /// its printable rules (`rules/…`). Our own games and the third-party ones alike.
    public static func isGamePage(_ url: URL?, gamesID: UUID?) -> Bool {
        guard let url, let gamesID, url.scheme == "zim",
              UUID(uuidString: url.host ?? "") == gamesID else { return false }
        return isGamePath(url.path(percentEncoded: false))
    }

    /// The same rule on a path within the games file, leading slashes or none.
    public static func isGamePath(_ path: String) -> Bool {
        let path = path.drop { $0 == "/" }
        return !path.isEmpty && path != "index.html" && !path.hasPrefix("rules/")
    }

    /// Run at each page's start (WebViewConfiguration), laid again when the games file changes: on a game page (the
    /// rule above, in the page's own words) it marks `<html>` with `data-pm-full="1"` before any script of the page
    /// runs, and from then on tells the app whether the page's viewport meta asks for `viewport-fit=cover`, so the app
    /// lays it edge to edge (cover) or inside the safe area (anything else). Any other page is left as built.
    public static func pageScript(gamesID: UUID?) -> String {
        """
        (function () {
          var host = "\(gamesID?.uuidString.lowercased() ?? "")";
          if (!host || location.protocol !== "zim:" || location.host.toLowerCase() !== host) return;
          var path = decodeURIComponent(location.pathname).replace(/^\\/+/, "");
          if (path === "" || path === "index.html" || path.indexOf("rules/") === 0) return;
          document.documentElement.setAttribute("\(attribute)", "1");
          var told = false;
          function tell() {
            var meta = document.querySelector("meta[name=viewport]");
            var cover = !!meta && /viewport-fit\\s*=\\s*cover/i.test(meta.content || "");
            if (cover === told) return;
            told = cover;
            try { window.webkit.messageHandlers.\(handler).postMessage(cover); } catch (e) {}
          }
          function watch() {
            if (document.head) {
              new MutationObserver(tell).observe(document.head,
                { childList: true, subtree: true, attributes: true, attributeFilter: ["content"] });
            }
            tell();
          }
          if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watch); else watch();
        })();
        """
    }

    /// Done's place: in the top safe-area band (an upright iPhone's status-bar row, beside the island) when the band
    /// holds it with room to spare; otherwise just inside the safe area's top-leading corner, within the box our game
    /// pages keep free there (120 by 56 points).
    public static func doneInBand(topInset: Double, height: Double) -> Bool { topInset >= height + 8 }

    /// The corner box our game pages keep free of anything a person must see or press, inside the safe area.
    public static let freeCorner = (width: 120.0, height: 56.0)
}
