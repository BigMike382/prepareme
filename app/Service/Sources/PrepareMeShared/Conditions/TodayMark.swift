import Foundation

/// The Today tab's red mark (look 3, spec section 9; plan Task 4.3): the phone reopens on the last tab used, so someone
/// left on Maps or Inventory saw no sign of a warning. It is on while Today's page is in event mode or says something
/// needs action, read from the page as it shows after its own script and the phone's live script (prepareme-live.js),
/// so it is the page's own condition: the phone's own reading and the Mac's copy both count, and so do event mode's
/// own rules (its switch, its 24 hours, the readings' age). The app reads it each time it shows the live block.
public enum TodayMark {
    /// Run on a front page after the live script: "event", "needs" or "calm", or "" on a page with no conditions (a
    /// library that isn't the daily one).
    public static let probe = """
        (function () {
          var s = document.getElementById('conditions');
          if (!s) return '';
          if (s.getAttribute('data-mode') === 'event') return 'event';
          return s.querySelector('.answer .needs') ? 'needs' : 'calm';
        })()
        """

    /// Whether the mark shows, from the probe's answer; nil leaves it as it was (a page with no conditions, or no
    /// answer at all).
    public static func needsAction(_ found: Any?) -> Bool? {
        switch found as? String {
        case "event", "needs": true
        case "calm": false
        default: nil
        }
    }

    /// The mark on the tab, and what VoiceOver reads for it: the page's own words for the same thing.
    public static let badge = "!"
    public static let spoken = "Needs action"
}
