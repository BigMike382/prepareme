import Foundation

/// Pages follow the phone's text size (the beta run's F02; plan 2026-10-16, Task 3.1). A library page ignores the
/// phone's text size (Settings › Accessibility › Display & Text Size › Larger Text), so the app scales its text by
/// how much bigger the phone's body text is than at the default size, on top of the reader's own Page zoom.
public enum TextSizeZoom {
    /// The Body text style's size in points at each of the phone's text sizes, keyed by UIContentSizeCategory's raw
    /// value. Read from UIFont.preferredFont(forTextStyle: .body) on the iOS 27.0 simulator, 2026-10-16; Apple's Human
    /// Interface Guidelines, Typography › Specifications › Dynamic Type sizes, give the same 23 points at xxxLarge.
    static let bodyPoints: [String: Double] = [
        "UICTContentSizeCategoryXS": 14, "UICTContentSizeCategoryS": 15, "UICTContentSizeCategoryM": 16,
        "UICTContentSizeCategoryL": 17, "UICTContentSizeCategoryXL": 19, "UICTContentSizeCategoryXXL": 21,
        "UICTContentSizeCategoryXXXL": 23, "UICTContentSizeCategoryAccessibilityM": 28,
        "UICTContentSizeCategoryAccessibilityL": 33, "UICTContentSizeCategoryAccessibilityXL": 40,
        "UICTContentSizeCategoryAccessibilityXXL": 47, "UICTContentSizeCategoryAccessibilityXXXL": 53,
    ]
    static let defaultBody = 17.0  // Large, the phone's default
    static let most = 3.0
    /// From this text size on, the page is marked data-large and Today's event band shortens (B2-14, packer/front_style.py).
    static let largeFrom = 1.5

    /// How much bigger the phone's body text is than at the default size; 1 for a size this table doesn't know.
    public static func factor(_ category: String) -> Double {
        (bodyPoints[category] ?? defaultBody) / defaultBody
    }

    /// The page's text size: the reader's Page zoom times the phone's factor, never below the reader's own (the smallest
    /// text sizes don't shrink pages below today's) and at most 300%.
    public static func effective(user: Double, category: String) -> Double {
        min(max(user * factor(category), user), most)
    }

    /// The page's script for `zoom` (from `effective`): Kiwix's own text size setting, as a whole percent, and past the
    /// normal size a word too long for a whole line breaks rather than run off the side, since the text grows but the
    /// page's width doesn't (no hyphens: they split words that would fit, "bleed-ing").
    public static func script(_ zoom: Double) -> String {
        "document.body.style.webkitTextSizeAdjust='\(String(format: "%.0f", zoom * 100))%';"
            + "document.documentElement.style.overflowWrap='\(zoom > 1 ? "anywhere" : "")';"
            + "document.documentElement.toggleAttribute('data-large',\(zoom >= largeFrom));"
    }
}
