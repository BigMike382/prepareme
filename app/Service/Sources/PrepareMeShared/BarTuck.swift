import Foundation

/// When a reading tab's top bar tucks away (FINDINGS F-079): while the reader drags down the page, and back when they
/// drag up, as Kiwix does it. Kiwix's page script decides from the page's own scroll position, which is the scroll
/// view's offset plus its inset; hiding the bar shrinks the inset by the bar's height, so the page seemed to move back
/// up, the script showed the bar again, the inset grew, and so on, about 20 times a second on a long page: Today's
/// choppy scrolling and the band flashing at its top (owner's iPhone, 2026-10-16). This goes by the scroll view's
/// offset alone, counts only the reader's own dragging and its glide, and starts counting afresh whenever the bar or
/// the inset changes, so the bar moving, and anything UIKit does to the offset to make up for it, never counts as the
/// reader turning back.
public struct BarTuck: Sendable {
    /// Points of travel one way before the bar moves, so a wobble of the finger doesn't flick it.
    public static let travelNeeded = 12.0
    /// The bar never tucks away this close to the page's top (Kiwix's script: 50).
    public static let nearTop = 50.0

    private var last: (offset: Double, inset: Double, hidden: Bool)?
    private var travel = 0.0

    public init() {}

    /// The scroll view moved to `offset` (its content offset, points) with `inset` (its adjusted top inset) while the
    /// bar is `hidden` or not; `byReader` while the reader drags or the page glides after a drag. Returns whether the
    /// bar should now be hidden when that changes, else nil.
    public mutating func scrolled(offset: Double, inset: Double, hidden: Bool, byReader: Bool) -> Bool? {
        defer { last = (offset, inset, hidden) }
        guard byReader, let last, last.inset == inset, last.hidden == hidden else {
            travel = 0
            return nil
        }
        let step = offset - last.offset
        guard step != 0 else { return nil }
        travel = travel == 0 || (travel > 0) == (step > 0) ? travel + step : step
        if travel >= Self.travelNeeded, !hidden, offset + inset > Self.nearTop {
            travel = 0
            return true
        }
        if travel <= -Self.travelNeeded, hidden {
            travel = 0
            return false
        }
        return nil
    }
}

/// A reading page's place across its view being rebuilt, and when the bar comes back (remaining-findings plan, Task
/// 10.2; F16, F59). A new page always shows the bar (a guide opened from a scrolled list came up with no Back or
/// Search); a jump within the same page (a citation's #fn:8) is not a new page. On the iPad the narrow and wide
/// layouts are different screens, so switching between them rebuilds the page's view: its place is kept as the share
/// of the page scrolled past, which survives the text reflowing to the new width.
public enum PagePlace {
    /// Whether `to` is another page than `from`: a different address once any #fragment is left out.
    public static func isNewPage(from: URL?, to: URL?) -> Bool {
        func page(_ url: URL?) -> String? {
            guard let url else { return nil }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.fragment = nil
            return parts?.string ?? url.absoluteString
        }
        return page(from) != page(to)
    }

    /// The share (0 to 1) of the scrollable length the page is scrolled past.
    public static func share(offset: Double, inset: Double, contentHeight: Double, viewHeight: Double) -> Double {
        let scrollable = contentHeight + inset - viewHeight
        guard scrollable > 0 else { return 0 }
        return min(1, max(0, (offset + inset) / scrollable))
    }

    /// The content offset that puts the page at `share` of its scrollable length, with its new size.
    public static func offset(share: Double, inset: Double, contentHeight: Double, viewHeight: Double) -> Double {
        let scrollable = contentHeight + inset - viewHeight
        guard scrollable > 0 else { return -inset }
        return share * scrollable - inset
    }
}

/// Tapping the reading tab you're already on (remaining-findings plan, Task 10.4; F45; owner, 2026-10-18, by click), as
/// iPhone apps do: scrolled down, it scrolls to the top; already at the top, it goes to the tab's first page; already
/// there, nothing.
public enum TabRetap: Equatable, Sendable {
    case scrollToTop, firstPage, nothing

    /// Points from the top that still count as at the top.
    public static let topSlack = 2.0

    public static func action(offset: Double, inset: Double, onFirstPage: Bool) -> TabRetap {
        if offset + inset > topSlack { return .scrollToTop }
        return onFirstPage ? .nothing : .firstPage
    }
}

/// Today's front page at a fresh start (owner, 2026-10-13: it opens fresh, at its top; F53) when the tab was restored on
/// that same page: the app loads it again on its own back list entry (PrepareMeLibrary.loadAgain, so Back never shows it
/// twice), and WebKit puts such a page back where it was scrolled, so once it has loaded the app puts it at its top,
/// where the once-a-run search bar is drawn in (owner, 2026-10-15; PrepareMeLibrary.showSearchOnce).
public enum FreshStart {
    /// The scroll view's offset with the page at its top, under the bars.
    public static func topOffset(inset: Double) -> Double { -inset }

    /// Whether the page is at its top: the search bar is drawn in only then (a page the person scrolled stays put).
    public static func atTop(offset: Double, inset: Double) -> Bool { offset <= 1 - inset }
}

/// One hand on a big phone (remaining-findings plan, Task 10.7; F33, F67; owner, 2026-10-18, by click): on an iPhone
/// whose screen's long side is at least `bigHeight` points (the Plus and Pro Max sizes from the iPhone 12 on; the 11 Pro
/// Max's 896 is left out with the XR's) a Search opens the reading tabs' search from above the tab bar, within the
/// thumb's reach; smaller iPhones and the iPad keep it at the top only.
public enum OneHand {
    public static let bigHeight = 900.0

    public static func searchAtBottom(phone: Bool, screenHeight: Double) -> Bool {
        phone && screenHeight >= bigHeight
    }
}

