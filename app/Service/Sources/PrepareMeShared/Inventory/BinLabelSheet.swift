#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A bin's label (build plan phase 7, slice 6): a QR code of `prepareme://place/<id>` (Barcode.placeURL: nothing of
/// the household in the code) beside the bin's name, its label and the place it's kept in. Pointing a phone at one
/// opens that bin's list.
public struct BinLabel: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let label: String
    public let place: String

    public init(id: Int64, name: String, label: String, place: String) {
        self.id = id
        self.name = name
        self.label = label
        self.place = place
    }
}

/// The sizes Print labels offers (step 6, part 2; the owner's answer 2026-10-19). The Letter sheet is ten 4 × 2 inch
/// labels (Avery 5163's layout). The Brother QL-810Wc's rolls print one label a page: the 62 mm continuous roll cut to
/// 62 × 40 mm, and the 29 × 90 mm address labels (DK-1201, the roll in its box). Brother's US page for the QL-810W
/// gives 62 mm as its widest label and those two rolls in the box; the 29 × 90 mm size is DK-1201's (retailers').
public enum BinLabelSize: String, CaseIterable, Identifiable, Sendable {
    case letter, roll62, address

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .letter: "Letter sheet (ten 4 × 2 in labels)"
        case .roll62: "62 mm roll (62 × 40 mm)"
        case .address: "29 × 90 mm labels"
        }
    }

    static let mm = 72 / 25.4  // points in a millimeter

    /// The page, in points: a roll's page is its one label.
    public var page: CGSize {
        switch self {
        case .letter: CGSize(width: 612, height: 792)
        case .roll62: CGSize(width: 62 * Self.mm, height: 40 * Self.mm)
        case .address: CGSize(width: 90 * Self.mm, height: 29 * Self.mm)
        }
    }

    var perPage: Int { self == .letter ? 10 : 1 }

    var label: CGSize { self == .letter ? CGSize(width: 288, height: 144) : page }

    /// The `n`th label's lower left corner on its page (PDF space: up from the bottom).
    func origin(_ n: Int) -> CGPoint {
        guard self == .letter else { return .zero }
        let left: CGFloat = 11, top: CGFloat = 36, gap: CGFloat = 14  // 0.15", 0.5", 0.19" between columns
        let column = CGFloat(n % 2), row = CGFloat(n / 2)
        return CGPoint(x: left + column * (label.width + gap), y: page.height - top - (row + 1) * label.height)
    }

    /// The lines the name, the label text and the place may wrap to: the 29 mm label is too short for more.
    var lines: (name: Int, label: Int, place: Int) { self == .address ? (2, 1, 1) : (3, 3, 2) }

    /// The code's side, the space around the label's edge (and between the code and the words) and the three lines'
    /// sizes, in points. The QR standard asks for 4 modules of white around a code: CIQRCodeGenerator draws 1, and the
    /// padding is at least 3 more for the longest place link (version 4, 35 modules with its border), on every side
    /// (the review).
    var look: (code: CGFloat, padding: CGFloat, name: CGFloat, text: CGFloat) {
        switch self {
        case .letter: (112, 12, 18, 12)
        case .roll62: (68, 7, 11, 8)  // a code 24 mm across, leaving the words room to wrap
        case .address: (62, 7, 13, 9)  // 22 mm, with 3 modules and more above and below on a label 29 mm tall
        }
    }
}

public enum BinLabelSheet {
    /// Error correction level H: the code still reads with about 30% of it dirty or damaged (garage, shed, vehicle).
    public static let correction = "H"

    /// The labels as a PDF in `size`: ten to a Letter page, one to a roll's.
    @MainActor
    public static func pdf(_ labels: [BinLabel], size: BinLabelSize) -> Data {
        guard !labels.isEmpty else { return Data() }  // no page at all: a roll wastes no label
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size.page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for start in stride(from: 0, to: labels.count, by: size.perPage) {
            context.beginPDFPage(nil)
            for (n, label) in labels[start..<min(start + size.perPage, labels.count)].enumerated() {
                let origin = size.origin(n)
                let renderer = ImageRenderer(content: BinLabelView(label: label, size: size)
                    .frame(width: size.label.width, height: size.label.height))
                context.saveGState()
                context.translateBy(x: origin.x, y: origin.y)
                renderer.render { _, draw in draw(context) }
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// `text` as a QR code at level H, each module 10 pixels (drawn without smoothing).
    public static func qr(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// One label: the code, then the name, the label and where it's kept, as far as they fit (a long name shrinks, then
/// wraps; a roll's small label keeps the name first). Black on white, for a thermal printer as for a sheet.
struct BinLabelView: View {
    let label: BinLabel
    let size: BinLabelSize

    var body: some View {
        let look = size.look
        HStack(spacing: look.padding) {
            if let image = BinLabelSheet.qr(Barcode.placeURL(label.id).absoluteString) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
                    .frame(width: look.code, height: look.code)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label.name).font(.system(size: look.name, weight: .bold)).lineLimit(size.lines.name)
                    .minimumScaleFactor(0.7)
                if !label.label.isEmpty { Text(label.label).font(.system(size: look.text)).lineLimit(size.lines.label) }
                if !label.place.isEmpty {
                    Text("In \(label.place)").font(.system(size: look.text)).lineLimit(size.lines.place)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(look.padding)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }
}
#endif
