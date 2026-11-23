#if os(macOS)
import Foundation
import PDFKit
@testable import PrepareMeShared
import XCTest

/// The printable blank inventory sheet (Mac, Inventory › All Items › Print Blank Sheet…). It reads nothing from the
/// inventory. PREPAREME_BLANK_SHEET_PDF=<path> also writes the sheet there, to look at.
@MainActor
final class BlankSheetTests: XCTestCase {
    /// One page (owner, 2026-10-21): the form and the Grab note, with no codes of any kind.
    func testTheSheetIsOneLandscapePage() throws {
        let data = BlankSheet.pdf()
        if let path = ProcessInfo.processInfo.environment["PREPAREME_BLANK_SHEET_PDF"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).size, CGSize(width: 792, height: 612))
        let form = try XCTUnwrap(document.page(at: 0)?.string)
        XCTAssertTrue(form.contains("PrepareMe Inventory"), form)
        for column in BlankSheet.columns {
            XCTAssertTrue(form.contains(column.title), column.title)
            XCTAssertTrue(column.hint.isEmpty || form.contains(column.hint), column.hint)
        }
        XCTAssertTrue(form.contains("Grab: write 10 to grab it in 10 minutes, 1 to grab it in an hour."), form)
        XCTAssertFalse(form.contains("code"), "no codes on the sheet")
    }

    /// The owner's picks: Grab and Serial number added (2026-10-21, by click); Year, Private, Calories each, Manual,
    /// Price and Purchased stay off the paper; Barcode and Category off, and Place named Location as the app names
    /// it (2026-11-21). Location is written in words (a wide column).
    func testTheFormsColumns() {
        XCTAssertEqual(BlankSheet.columns.map(\.title), ["Item", "Brand", "Model", "Qty", "Unit", "Location", "Grab",
                                                         "Expires", "Serial No.", "Notes"])
        XCTAssertEqual(BlankSheet.columns.map(\.hint), ["", "", "", "", "", "", "10 or 1", "Month/Day/Year",
                                                        "Stays on the Mac", ""])
        let width = BlankSheet.columns.map(\.width).reduce(0, +)
        XCTAssertEqual(width, BlankSheet.page.width - 2 * BlankSheet.margin, accuracy: 0.01, "the rows fill the page")
        XCTAssertGreaterThanOrEqual(BlankSheet.margin, 18, "inside a printer's unprintable edge")
        XCTAssertGreaterThanOrEqual(BlankSheet.columns.first { $0.title == "Location" }?.width ?? 0, 80)
    }

    /// Twenty rows and the note fit inside the margins.
    func testTheRowsFitThePage() {
        XCTAssertEqual(BlankSheet.rows, 20)
        let used = BlankSheet.title + BlankSheet.gap + BlankSheet.head + CGFloat(BlankSheet.rows) * BlankSheet.row
            + BlankSheet.gap + BlankSheet.note
        XCTAssertLessThanOrEqual(used, BlankSheet.page.height - 2 * BlankSheet.margin)
    }
}
#endif
