#if os(macOS)
import CoreGraphics
import PDFKit
@testable import PrepareMeShared
import Vision
import XCTest

/// Bin labels in three sizes (step 6, part 2; the owner's answer 2026-10-19: the 62 mm roll and the 29 × 90 mm labels
/// of a Brother QL-810Wc, with the Letter sheet kept): each size's pages are its own size, the sheet ten labels to a
/// page and a roll one, and every label's code reads back with the Mac's own reader (Vision) at its printed size,
/// holding its place's link. The codes use error correction level H. Made-up places only.
@MainActor
final class BinLabelSheetTests: XCTestCase {
    let labels = [
        BinLabel(id: 3, name: "SAMPLE Bin 03", label: "Made-up batteries and bulbs", place: "Made-up garage shelf"),
        BinLabel(id: 41, name: "SAMPLE A made-up bin with a very long name of forty letters", label: "", place: ""),
        BinLabel(id: 1207, name: "SAMPLE Go-bag", label: "Made-up first aid", place: "Made-up hall closet"),
        BinLabel(id: 123_456_789_012, name: "SAMPLE Shed", label: "", place: "Made-up yard"),  // a longer link
    ]

    func testEachSizeHasItsPagesAndItsLabelsPerPage() throws {
        XCTAssertEqual(BinLabelSheet.correction, "H")
        let mm = 72 / 25.4
        XCTAssertEqual(BinLabelSize.letter.page, CGSize(width: 612, height: 792))
        XCTAssertEqual(BinLabelSize.roll62.page.width, 62 * mm, accuracy: 0.01)
        XCTAssertEqual(BinLabelSize.roll62.page.height, 40 * mm, accuracy: 0.01)
        XCTAssertEqual(BinLabelSize.address.page.width, 90 * mm, accuracy: 0.01)
        XCTAssertEqual(BinLabelSize.address.page.height, 29 * mm, accuracy: 0.01)
        for (size, pages) in [(BinLabelSize.letter, 1), (.roll62, 4), (.address, 4)] {
            let document = try XCTUnwrap(PDFDocument(data: BinLabelSheet.pdf(labels, size: size)), "\(size)")
            XCTAssertEqual(document.pageCount, pages, "\(size)")
            for n in 0..<document.pageCount {
                let box = try XCTUnwrap(document.page(at: n)).bounds(for: .mediaBox)
                XCTAssertEqual(box.width, size.page.width, accuracy: 0.5, "\(size)")
                XCTAssertEqual(box.height, size.page.height, accuracy: 0.5, "\(size)")
            }
        }
        for size in BinLabelSize.allCases {
            XCTAssertEqual(PDFDocument(data: BinLabelSheet.pdf([], size: size))?.pageCount ?? 0, 0, "no labels, no page")
        }
        XCTAssertEqual(BinLabelSize.allCases.map(\.title),
                       ["Letter sheet (ten 4 × 2 in labels)", "62 mm roll (62 × 40 mm)", "29 × 90 mm labels"])
    }

    func testEveryCodeReadsBackAtItsPrintedSize() throws {
        for size in BinLabelSize.allCases {
            let document = try XCTUnwrap(PDFDocument(data: BinLabelSheet.pdf(labels, size: size)))
            var found: [String] = []
            for n in 0..<document.pageCount {
                found += try codes(on: try XCTUnwrap(document.page(at: n)))
            }
            XCTAssertEqual(Set(found), Set(labels.map { Barcode.placeURL($0.id).absoluteString }), "\(size)")
        }
    }

    /// The QR codes on `page` drawn at 300 dots an inch and made pure black and white, as a thermal label printer
    /// prints them (the QL-810W's resolution; the review: a grey render is kinder than the printer).
    private func codes(on page: PDFPage) throws -> [String] {
        let box = page.bounds(for: .mediaBox)
        let scale = 300.0 / 72
        let width = Int(box.width * scale), height = Int(box.height * scale)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for n in 0..<(context.bytesPerRow * height) { pixels[n] = pixels[n] < 128 ? 0 : 255 }
        let image = try XCTUnwrap(context.makeImage())
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
#endif
