import Foundation

/// The red night screen's words and its page script (concept-doc plan, phase D), shared so `swift test` can run the
/// script in a real web view; the app's PrepareMeRedNight lays the red layer and the switches.
public enum RedNight {
    /// This device's switch, in its own defaults: never synced, never sent to the service.
    public static let key = "PrepareMe.redNight"
    public static let title = "Red night screen"

    /// Run at each page's start (WebViewConfiguration) with the switch as it stands, and again into open pages when it
    /// changes (`push`). While red: the page's own dark colors (`color-scheme: dark`, so a page with no colors of its
    /// own starts dark rather than white) and the packer's background (`--bg`) true black. A page that is light anyway,
    /// checked as it loads, is inverted (its pictures inverted back): one that paints itself light, or one with dark
    /// text and no background of its own, which dark colors alone would leave dark on black (the review). Nothing is
    /// added to a page while it is off, and turning it off takes it all away.
    public static func pageScript(on: Bool) -> String {
        """
        (function () {
          var style = "html[data-pm-red]{color-scheme:dark}html[data-pm-red] body{--bg:#000}"
            + "html[data-pm-red-light]{color-scheme:light;background:#fff}"
            + "html[data-pm-red-light],html[data-pm-red-light] img,html[data-pm-red-light] video,"
            + "html[data-pm-red-light] picture,html[data-pm-red-light] canvas{filter:invert(1) hue-rotate(180deg)}";
          function rgb(value) {
            var m = value ? value.match(/[\\d.]+/g) : null;
            return m && m.length >= 3 && !(m.length > 3 && +m[3] === 0) ? m : null;
          }
          function bright(m) { return 0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]; }
          function light() {
            var root = document.documentElement, body = document.body;
            var paint = (body && rgb(getComputedStyle(body).backgroundColor)) || rgb(getComputedStyle(root).backgroundColor);
            if (paint) return bright(paint) > 140;
            var ink = rgb(getComputedStyle(body || root).color);
            return !!ink && bright(ink) < 100 && !/dark/.test(getComputedStyle(root).colorScheme + "|"
              + (document.querySelector("meta[name=color-scheme]") || {}).content);
          }
          function check() {  // decided again as the page loads; none of it is drawn in between
            var root = document.documentElement;
            if (!root || !document.body || !root.hasAttribute("data-pm-red")) return;
            root.removeAttribute("data-pm-red");  // the page's own colors, without ours, decide
            root.removeAttribute("data-pm-red-light");
            var isLight = light();
            root.setAttribute("data-pm-red", "");
            if (isLight) root.setAttribute("data-pm-red-light", "");
          }
          window.pmRed = function (on) {
            var root = document.documentElement, sheet = document.getElementById("pm-red-style");
            if (!root) return;
            if (on) {
              if (!sheet) {
                sheet = document.createElement("style");
                sheet.id = "pm-red-style";
                sheet.textContent = style;
                (document.head || root).appendChild(sheet);
              }
              root.setAttribute("data-pm-red", "");
              check();
            } else {
              root.removeAttribute("data-pm-red");
              root.removeAttribute("data-pm-red-light");
              if (sheet) sheet.remove();
            }
          };
          window.pmRed(\(on));
          document.addEventListener("readystatechange", check);
          document.addEventListener("DOMContentLoaded", check);
          window.addEventListener("load", check);
        })();
        """
    }

    /// What an open page runs when the switch changes.
    public static func push(on: Bool) -> String { "window.pmRed && window.pmRed(\(on));" }
}
