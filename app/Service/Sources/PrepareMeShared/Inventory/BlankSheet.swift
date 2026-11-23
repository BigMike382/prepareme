#if os(macOS)
import AppKit
import PDFKit
import SwiftUI

/// The blank inventory sheet (owner, 2026-10-14; Grab and Serial number added 2026-10-21): one landscape US Letter
/// page of empty rows to carry around and fill in by hand. One page only. No Barcode, and no Category or codes for
/// it (owner, 2026-11-21: never written by hand; the category is picked in the app when the item is typed in), and
/// no codes for locations (owner, 2026-10-21: written in your own words). In the shared package so its tests can
/// make the PDF.
public enum BlankSheet {
    public static let page = CGSize(width: 792, height: 612)  // US Letter, landscape
    public static let margin: CGFloat = 30  // points: inside the unprintable edge of a home printer (about 18)
    public static let rows = 20
    static let title: CGFloat = 24, gap: CGFloat = 8, head: CGFloat = 26, row: CGFloat = 23.5
    static let note: CGFloat = 12

    /// A column of the form: its title, what to write in it (under the title, smaller), and its width in points.
    public struct Column: Equatable, Sendable {
        public let title: String
        public let hint: String
        public let width: CGFloat
    }

    /// Year, Private, Calories each, Manual, Price and Purchased stay off the paper (owner, 2026-10-21, by click):
    /// they are filled in on the Mac, or by the phone's scan. Location is written in words, so it is wide.
    public static let columns: [Column] = [
        Column(title: "Item", hint: "", width: 140), Column(title: "Brand", hint: "", width: 64),
        Column(title: "Model", hint: "", width: 64), Column(title: "Qty", hint: "", width: 34),
        Column(title: "Unit", hint: "", width: 44), Column(title: "Location", hint: "", width: 106),
        Column(title: "Grab", hint: "10 or 1", width: 36),
        Column(title: "Expires", hint: "Month/Day/Year", width: 68),
        Column(title: "Serial No.", hint: "Stays on the Mac", width: 80), Column(title: "Notes", hint: "", width: 96),
    ]

    @MainActor
    public static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let renderer = ImageRenderer(content: BlankForm().frame(width: page.width, height: page.height))
        context.beginPDFPage(nil)
        renderer.render { _, draw in draw(context) }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @MainActor
    public static func print() {
        guard let document = PDFDocument(data: pdf()) else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.paperSize = page
        info.orientation = .landscape
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: true)?.run()
    }

    // Ink on paper: black, and BASE's light neutrals (docs/design/prepareme.css) for hints, rules and the header.
    static let ink = Color.black
    static let text2 = Color(red: 0x3d / 255, green: 0x45 / 255, blue: 0x50 / 255)
    static let edge = Color(red: 0x69 / 255, green: 0x72 / 255, blue: 0x7c / 255)
    static let ground = Color(red: 0xec / 255, green: 0xee / 255, blue: 0xf0 / 255)
}

/// The form: a column that takes a set answer says under its title what to write, and a heavier rule every five
/// rows keeps a row in sight across the page.
struct BlankForm: View {
    var body: some View {
        VStack(alignment: .leading, spacing: BlankSheet.gap) {
            HStack(alignment: .firstTextBaseline) {
                Text("PrepareMe Inventory").font(.system(size: 17, weight: .bold))
                Spacer()
                Text("Date ____________     Page ____     Entered in the App ☐").font(.system(size: 10))
            }
            .frame(height: BlankSheet.title)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(BlankSheet.columns, id: \.title) { column in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(column.title).font(.system(size: 10, weight: .semibold))
                            Text(column.hint.isEmpty ? " " : column.hint).font(.system(size: 7))
                                .foregroundStyle(BlankSheet.text2).lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                        .frame(width: column.width, height: BlankSheet.head, alignment: .leading)
                    }
                }
                .background(BlankSheet.ground)
                Color.clear.frame(height: BlankSheet.row * CGFloat(BlankSheet.rows))
            }
            .overlay { FormLines(heavy: false).stroke(BlankSheet.edge, lineWidth: 0.5) }
            .overlay { FormLines(heavy: true).stroke(BlankSheet.ink, lineWidth: 1) }
            Text("Grab: write 10 to grab it in 10 minutes, 1 to grab it in an hour.")
                .font(.system(size: 8)).foregroundStyle(BlankSheet.text2)
                .frame(height: BlankSheet.note, alignment: .top)
            Spacer(minLength: 0)
        }
        .padding(BlankSheet.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(BlankSheet.ink)
        .background(.white)
        .environment(\.colorScheme, .light)
    }
}

/// The form's lines, drawn whole: the thin ones (the columns' edges and the rows'), or the heavy ones (the frame,
/// under the header and every fifth row).
struct FormLines: Shape {
    let heavy: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func across(_ y: CGFloat) {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        let head = BlankSheet.head, row = BlankSheet.row, rows = BlankSheet.rows
        let isHeavy = { (n: Int) in n % 5 == 0 || n == rows }
        if heavy {
            path.addRect(rect)
            across(head)
            for n in 1..<rows where isHeavy(n) { across(head + CGFloat(n) * row) }
            return path
        }
        for n in 1...rows where !isHeavy(n) { across(head + CGFloat(n) * row) }
        var x: CGFloat = 0
        for edge in BlankSheet.columns.dropLast().map(\.width) {
            x += edge
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }
}
#endif
