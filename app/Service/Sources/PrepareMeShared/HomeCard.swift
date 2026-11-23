import CoreImage
import Foundation

/// An Our Home page's paper card (docs/plans/2026-11-16-our-home.md, Task 4.3; board 24): one sheet to tape beside the
/// equipment, printed from the page's right-click in Edit Our Home (the owner's click, 2026-11-16). This is what the
/// card says; the Mac app draws it (PrepareMeHomeCard.swift). The page as saved: the strip with the house and Our
/// Home, its title, "Not finished" while blanks are left, when to use it, its danger, then each step with its danger
/// and caution before its words, its name as the screen's label, a Yes or No's steps, its ticks, its number to call
/// and its photo; the QR code of `prepareme://home/<name>` and the two fixed lines (OK'd with the boards). Never a
/// photo wanted, a video, a link, a slot or the search words: paper holds only what a person does there.
public struct HomeCard: Equatable, Sendable {
    public static let scanLine = "Scan to open this page in PrepareMe."
    public static let footLine = "Or open PrepareMe › Our Home › {title}. Printed {date}; the page in PrepareMe is the "
        + "one kept up to date."
    public static let answerLine = "Yes: step {yes}. No: step {no}."  // board 24's

    /// Words with each blank apart: an answered blank is its answer, an unanswered one its question as the screen
    /// shows it (BLANK_Q), drawn as a blank.
    public struct Part: Equatable, Sendable {
        public let text: String
        public let blank: Bool
    }

    public struct Step: Equatable, Sendable {
        public let number: Int
        public let name: String
        public let danger, caution, words: [Part]
        public let answer: String  // a Yes or No's steps, else ""
        public let ticks: [String]
        public let call: String  // "Call {label}: (555) 555-0142", else ""
        public let photo: String  // a file beside the page, else ""
        public let place: String  // the place's words as picked or typed, else ""
    }

    public let home, title, unfinished: String
    public let when, danger: [Part]
    public let things: [String]  // What you need's picked or typed things, as their words
    public let steps: [Step]
    public let link, scan, foot: String
    public let qr: [[Bool]]  // the code's modules, row by row, dark true; empty if CoreImage made none

    public init(_ page: HouseholdPage, name: String, printed: Date) {
        let w = HomePage.w, left = page.blanksLeft
        home = "\(w("HOUSE_EMOJI")) \(w("HOME_NAME"))"
        title = page.title
        unfinished = left == 0 ? "" : left == 1 ? w("BLANK_LEFT") : HomePage.format(w("BLANKS_LEFT"), ["n": "\(left)"])
        when = Self.parts(page.when)
        danger = Self.parts(page.danger)
        things = page.things.map(\.words)
        steps = page.steps.enumerated().map { index, step in
            Step(number: index + 1, name: step.name, danger: Self.parts(step.danger), caution: Self.parts(step.caution),
                 words: Self.parts(step.words),
                 answer: step.yes.map { HomePage.format(Self.answerLine, ["yes": "\($0)", "no": "\(step.no ?? 0)"]) } ?? "",
                 ticks: step.ticks,
                 call: step.call.map { "\(HomePage.format(w("CALL"), ["label": $0.label])): \(HomePage.shownNumber($0.number))" } ?? "",
                 photo: step.photo, place: step.place?.words ?? "")
        }
        link = Self.link(name)
        scan = Self.scanLine
        foot = HomePage.format(Self.footLine, ["title": page.title, "date": Self.day(printed)])
        qr = Self.modules(link) ?? []
    }

    /// The link the card's code holds, and nothing else (Task 2.6's).
    public static func link(_ name: String) -> String { "prepareme://\(HomeLinks.host)/\(name)" }

    /// "November 16, 2026", in English whatever the Mac's own settings.
    static func day(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "MMMM d, yyyy"
        return format.string(from: date)
    }

    static func parts(_ text: String) -> [Part] {
        let ns = text as NSString
        var out: [Part] = [], at = 0
        for m in HouseholdPage.blank.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > at { out.append(Part(text: ns.substring(with: NSRange(location: at, length: m.range.location - at)), blank: false)) }
            if m.range(at: 2).location != NSNotFound {
                out.append(Part(text: ns.substring(with: m.range(at: 2)), blank: false))
            } else {
                out.append(Part(text: HomePage.format(HomePage.w("BLANK_Q"), ["question": ns.substring(with: m.range(at: 1))]),
                                blank: true))
            }
            at = m.range.location + m.range.length
        }
        if at < ns.length { out.append(Part(text: ns.substring(from: at), blank: false)) }
        return out
    }

    /// The QR code of `text` by the Mac's own maker (CoreImage, error correction M), with no quiet zone of its own: the
    /// drawing leaves one. Nil if CoreImage made none.
    static func modules(_ text: String) -> [[Bool]]? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter?.outputImage else { return nil }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, width == height else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        CIContext().render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        let rows = (0..<height).map { y in (0..<width).map { x in pixels[(y * width + x) * 4] < 128 } }
        // CoreImage draws a module-wide light border; the drawing's quiet zone stands for it
        let inner = rows.dropFirst().dropLast().map { Array($0.dropFirst().dropLast()) }
        return rows.first?.contains(true) == false && rows.last?.contains(true) == false ? inner : rows
    }
}
