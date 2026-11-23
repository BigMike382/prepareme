import Foundation

/// The pages' colors for the app's own screens (the Today redesign's phase 5, ruling 12): each of BASE's tokens in
/// `packer/front_style.py`, light and dark, as 0xRRGGBB. One meaning, one look: the app colors a thing only for what
/// the same token means on the pages (red danger, amber caution, blue a key fact, green fine; links and the tint
/// PrepareMe's teal, look 3).
/// `PaletteTests` reads front_style.py and fails on any difference; a token the dark block leaves out keeps its light
/// value there, as CSS does.
public enum Palette {
    public struct Pair: Equatable, Sendable {
        public let light: UInt32, dark: UInt32
        init(_ light: UInt32, _ dark: UInt32) { (self.light, self.dark) = (light, dark) }
    }

    public static let bg = Pair(0xe7ece3, 0x0d171c)
    public static let panel = Pair(0xfbfcf8, 0x15242a)
    public static let text = Pair(0x16191d, 0xeef1f4)
    public static let text2 = Pair(0x3c463f, 0xc6ced6)
    public static let line = Pair(0xcbd3c4, 0x263c45)
    public static let edge = Pair(0x69727c, 0x8d99a6)
    public static let link = Pair(0x0c5d57, 0x6fdccf)
    public static let caution = Pair(0x92400e, 0xfcd34d)
    public static let accent = Pair(0xb45309, 0xf59e0b)
    public static let accentBg = Pair(0xfffbeb, 0x2e2208)
    public static let red = Pair(0x991b1b, 0xfca5a5)
    public static let redMark = Pair(0xb91c1c, 0xf87171)
    public static let redBg = Pair(0xfef2f2, 0x3a1717)
    public static let miss = Pair(0xdfe6d9, 0x1d323a)
    public static let fill = Pair(0x991b1b, 0x991b1b)
    public static let okMark = Pair(0x15803d, 0x4ade80)
    public static let okBg = Pair(0xf0fdf4, 0x10261a)
    public static let ev = Pair(0x7f1d1d, 0x5c1414)
    public static let evText = Pair(0xffffff, 0xfff5f5)
    public static let info = Pair(0x1e3a8a, 0xbfdbfe)
    public static let infoMark = Pair(0x1d4ed8, 0x60a5fa)
    public static let infoBg = Pair(0xeff6ff, 0x14213b)
    public static let onFill = Pair(0xffffff, 0xffffff)
    // Look 3 (spec section 3): the teal fill for buttons and its words, the tint of the row or tab you're on, and the
    // band at the top of a screen with its words; a band that needs action is `ev` and `evText`.
    public static let idFill = Pair(0x0c5d57, 0x5fd0c2)
    public static let onId = Pair(0xffffff, 0x07211f)
    public static let idTint = Pair(0xd6e8e1, 0x143630)
    public static let band = Pair(0x0e4a48, 0x0e4443)
    public static let bandText = Pair(0xf2fbf9, 0xf2fbf9)

    /// Increase Contrast (the Apple guidelines plan, phase 4): what the pages' `prefers-contrast:more` line does, each
    /// token it changes and the token it takes instead; `PaletteTests` holds the two alike.
    public static let moreContrast: [String: String] = ["text2": "text", "edge": "text", "line": "text"]

    /// A token's Increase Contrast stand-in, if the pages change it.
    public static func moreContrast(_ name: String) -> Pair? { moreContrast[name].flatMap { tokens[$0] } }

    /// Every token by its name in the stylesheet, for the test.
    public static let tokens: [String: Pair] = [
        "bg": bg, "panel": panel, "text": text, "text2": text2, "line": line, "edge": edge, "link": link,
        "caution": caution, "accent": accent, "accent-bg": accentBg, "red": red, "red-mark": redMark, "red-bg": redBg,
        "miss": miss, "fill": fill, "ok-mark": okMark, "ok-bg": okBg, "ev": ev, "ev-text": evText, "info": info,
        "info-mark": infoMark, "info-bg": infoBg, "on-fill": onFill, "id-fill": idFill, "on-id": onId,
        "id-tint": idTint, "band": band, "band-text": bandText,
    ]
}
