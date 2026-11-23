import Foundation

/// The pages Today looks for that aren't in the library (beta run 2, B2-26). The packer leaves a
/// `<p class="missing">Not in the library yet: A, B.</p>` line in Today's markup (the style hides it in event mode, so
/// a storm never shows it); the Mac's Household pages screen reads the names from it, as a note for the owner.
public enum MissingPages {
    /// The packer's words (packer/build.py `MISSING_PAGES`), held to them by the shared cases' `copy`.
    public static let template = "Not in the library yet: {names}."

    /// The names in the line, in the page's order; empty when the page has no such line or its words aren't these.
    public static func names(inPage html: String) -> [String] {
        guard let open = html.range(of: "<p class=\"missing\">"),
              let close = html.range(of: "</p>", range: open.upperBound..<html.endIndex) else { return [] }
        let text = HTMLText.unescaped(String(html[open.upperBound..<close.lowerBound]))
        let parts = template.components(separatedBy: "{names}")
        guard parts.count == 2, text.hasPrefix(parts[0]), text.hasSuffix(parts[1]),
              text.count > parts[0].count + parts[1].count else { return [] }
        let body = String(text.dropFirst(parts[0].count).dropLast(parts[1].count))
        return body.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
