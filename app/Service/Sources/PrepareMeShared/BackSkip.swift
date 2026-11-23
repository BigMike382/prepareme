import Foundation

/// Back or Forward to a page that is no longer in the library (owner's phone, 2026-10-21: Back on the guide list showed
/// Kiwix's "Unable to load the page requested"). A reading tab keeps its back list across launches and new copies of a
/// library, so an entry in it can name a page the copy on the phone no longer has: a walk-through held back while its
/// guide is rewritten, a renamed household page, a dropped guide, a library the phone has removed. The app cancels that
/// step quietly and goes past the gone entry instead.
///
/// WebKit, while it decides on a back or forward step, has already moved the list's current entry onto the step's
/// target, and puts it back when the step is cancelled (BackSkipTests pins both on a real web view).
public enum BackSkip {
    /// A link followed to a page that isn't in the library, or into a library the Mac doesn't send this device (family
    /// downloads plan, phase 3), keeps Kiwix's alert with our title ("Not on this phone", never "Unable to load the page
    /// requested") and these words in place of Kiwix's "The download could not be completed."; the alert's notice
    /// carries `goneKey` to ask for them. `device`: phone, iPad or Mac.
    public static func goneWords(device: String) -> String {
        "This page isn't in the library on this \(device)."
    }
    public static let goneKey = "prepareme.pageGone"

    public enum Step: Equatable {
        case go(Int)  // the entry at this index of the whole list
        case startPage  // nothing earlier: the tab's own first page
        case stay  // nowhere to go: the page on screen stays
    }

    /// Where to go instead of the gone page.
    /// - entries: the tab's whole back-forward list as it stands while the step is decided, oldest first.
    /// - cursor: the index of the list's current entry then.
    /// - gone: the page that isn't in the library.
    /// - shown: the index of the page on screen, when it is in the list (nil for a tab restored at launch, which
    ///   shows nothing yet).
    ///
    /// Going back, it is the entry before the gone one, or the start page when there is none; going forward, the entry
    /// after it, or nowhere. Never the gone entry itself, so a skip never comes round to it again, and a skip onto
    /// another gone entry moves on the same way, always further from the page on screen.
    public static func step(entries: [URL], cursor: Int, gone: URL, shown: Int?) -> Step {
        guard entries.indices.contains(cursor) else { return .stay }
        let target: Int
        if same(entries[cursor], gone) {
            target = cursor
        } else if let before = entries[..<cursor].lastIndex(where: { same($0, gone) }) {
            target = before
        } else if let after = entries[(cursor + 1)...].firstIndex(where: { same($0, gone) }) {
            target = after
        } else {
            return .stay
        }
        let back = shown.map { $0 > target } ?? (target <= cursor)
        if back {
            return target > 0 ? .go(target - 1) : .startPage
        }
        return target + 1 < entries.count ? .go(target + 1) : .stay
    }

    /// Where `.startPage` goes: an entry of the start page already in the list, so the list doesn't grow and Back from it
    /// goes where it went before; the nearest one behind the page on screen, else the nearest ahead of it (the guide
    /// list a skip opened before: Back from a guide whose only entry behind is gone alternates with the guide list,
    /// never adding to it). Nil when there is none: the start page is loaded.
    public static func startEntry(entries: [URL], start: URL, shown: Int?) -> Int? {
        let matches = entries.indices.filter { $0 != shown && same(entries[$0], start) }
        guard let shown else { return matches.last }
        return matches.last(where: { $0 < shown }) ?? matches.first(where: { $0 > shown })
    }

    /// One page: the same address, whatever heading it was at.
    static func same(_ a: URL, _ b: URL) -> Bool { !PagePlace.isNewPage(from: a, to: b) }
}
