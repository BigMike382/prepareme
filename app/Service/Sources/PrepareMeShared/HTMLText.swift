import Foundation

/// Markup's entities read back as plain text: one table for every screen that reads a page's words (Today's missing
/// pages, the topo maps' names), so a title shows the same everywhere.
public enum HTMLText {
    /// `text` with the entities a page's text carries made plain; `&amp;` goes last, so `&amp;lt;` stays `&lt;`.
    public static func unescaped(_ text: String) -> String {
        var out = text
        for (entity, plain) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"),
                                ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: plain)
        }
        return out
    }
}
