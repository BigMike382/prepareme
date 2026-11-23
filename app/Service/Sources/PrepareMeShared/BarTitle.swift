import Foundation

/// The words a reading tab's top bar can show, longest first (beta run 1's F63, beta run 2's B2-17; owner, 2026-10-21):
/// the page's whole title, then its subject, the words before its first colon ("Tornadoes" for "Tornadoes: watches,
/// warnings and safe rooms"), then the tab's name. The bar shows the first that fits (PrepareMeTabs' BarTitleView), so
/// the small iPhone never cuts a title to "Tornadoes:…"; the page's own heading, just under the bar, gives the whole
/// title. Half the guides' titles are over 50 letters, which no bar on that phone holds.
public enum BarTitle {
    public static func choices(title: String, tab: String) -> [String] {
        var found = [String]()
        for words in [title, subject(title), tab] {
            let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !found.contains(trimmed) { found.append(trimmed) }
        }
        return found.isEmpty ? [tab] : found
    }

    /// The words before the title's first colon, or "" when it has none
    static func subject(_ title: String) -> String {
        guard let colon = title.firstIndex(of: ":") else { return "" }
        return String(title[..<colon])
    }
}
