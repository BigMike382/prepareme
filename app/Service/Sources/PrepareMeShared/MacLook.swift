import Foundation

/// Small rules of the Mac app's look, kept here apart from the app so `swift test` holds them (the Kiwix tests build
/// Kiwix alone, without PrepareMe's Mac screens).
public enum MacLook {
    /// Each sidebar group's emoji, by its name in the guide list (A4; owner, 2026-10-18): dashboard/emoji.py's
    /// GROUP_EMOJI exactly (packer/tests/test_build.py reads this table and pins the two equal), drawn before the name
    /// as the guide list draws it. No red-cross or calculator emoji exists: the owner picked the helmet and the numbers
    /// key. Our Home takes the house so the list reads alike.
    public static let emoji: [String: String] = [
        "Our Home": "🏠",
        "Water and Food": "💧",
        "Power, Heat and Fuel": "⚡",
        "Fire, Storms, Floods": "🌪️",
        "Medical": "⛑️",
        "Family and Animals": "👪",
        "After a Disaster": "🏚️",
        "Kits and Planning": "🎒",
        "Radio, Phones, Maps": "📱",
        "Calculators, Tables": "🔢",
        "Living Outdoors": "⛺",
    ]

    /// A group's name as it is now: a library built before a rename still names it the old way until it's rebuilt
    /// (Our Household became Our Home, Our Home phase 1, 2026-11-16).
    public static func current(_ name: String) -> String {
        name.lowercased() == "our household" ? SearchMark.household : name
    }

    /// A group's emoji, its name matched ignoring case, so a library built before the groups went to title case
    /// (2026-10-18) still shows them; nil for a group without one, which keeps its symbol.
    public static func emoji(_ name: String) -> String? {
        let folded = current(name).lowercased()
        return emoji.first { $0.key.lowercased() == folded }?.value
    }

    /// The icon of a group without an emoji (the fixed sections Other and For Adults). With an icon, a group's words
    /// line up under "Categories", not left of it (owner, 2026-10-16).
    public static let symbols: [String: String] = [
        "Other": "doc.text",
        "For Adults": "person",
    ]
    /// A group added later shows a folder until it's given an emoji or an icon above.
    public static let otherSymbol = "folder"

    /// Matched ignoring case, as `emoji` is, so a library built before the fixed sections' title case ("For adults",
    /// 2026-10-30) still finds its icon.
    public static func symbol(_ name: String) -> String {
        let folded = name.lowercased()
        return symbols.first { $0.key.lowercased() == folded }?.value ?? otherSymbol
    }

    /// Where a window grown to `frame` goes so its bottom is on `visible` (the screen less the menu bar and Dock, in
    /// macOS's bottom-up points): moved up only as far as that needs, its top never above `visible`'s; one already on
    /// screen stays where it is. Settings' tall PrepareMe tab, opened after the short Reading tab, ran off a laptop's
    /// screen (on-screen look, 2026-10-16; both tabs gone 2026-10-23, the Phones tab is the tall one now).
    public static func onScreen(_ frame: CGRect, in visible: CGRect) -> CGPoint {
        var y = max(frame.minY, visible.minY)
        y = min(y, visible.maxY - frame.height)
        return CGPoint(x: frame.minX, y: max(y, frame.minY))
    }
}
