import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import PDFKit
@testable import PrepareMeShared
import XCTest

/// Equipment manuals (top-ten plan, phase 7, Task 7.2): the Mac copies an item's manual into item-manuals and lists it
/// in manuals.json, after reading every page (PDFKit's text, Vision for a page that is only a picture) through the ID
/// check. Made-up items and PDFs made here only; the ID-shaped sample is assembled from pieces (guard/tests/samples.py),
/// so no file holds it whole.
final class ItemManualsTests: XCTestCase {
    var base: URL!
    var check: FakeCheck!
    var manuals: ItemManuals!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-manuals-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        check = FakeCheck()
        manuals = ItemManuals(support: base, checker: check)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    enum Page {
        case text([String])  // drawn as text: PDFKit reads it
        case picture([String])  // drawn as a picture of the words: only Vision reads it
        case textAndPicture([String], [String])  // typed lines, and below them a picture (a photo's size) of words
    }

    /// A PDF of `pages`, letter size, in large type; `info`, its document details (title, author and so on).
    static func pdf(_ pages: [Page], at url: URL, info: [CFString: String] = [:]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, info.isEmpty ? nil : info as CFDictionary))
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let lines):
                draw(lines, in: context, height: box.height)
            case .picture(let lines):
                let scale: CGFloat = 2
                let bitmap = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
                                       bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
                bitmap.scaleBy(x: scale, y: scale)
                draw(lines, in: bitmap, height: box.height)
                context.draw(bitmap.makeImage()!, in: box)
            case .textAndPicture(let lines, let pictured):
                draw(lines, in: context, height: box.height)
                let photo = CGRect(x: 60, y: 120, width: 480, height: 200), scale: CGFloat = 2
                let bitmap = CGContext(data: nil, width: Int(photo.width * scale), height: Int(photo.height * scale),
                                       bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: photo.width * scale, height: photo.height * scale))
                bitmap.scaleBy(x: scale, y: scale)
                draw(pictured, in: bitmap, height: photo.height + 20)
                context.draw(bitmap.makeImage()!, in: photo)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func draw(_ lines: [String], in context: CGContext, height: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        for (n, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 60, y: height - 100 - CGFloat(n) * 48)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
    }

    func made(_ pages: [Page], name: String = "manual.pdf", info: [CFString: String] = [:]) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Self.pdf(pages, at: url, info: info)
        return url
    }

    /// `made`'s PDF with `annotate` run on its first page, saved through PDFKit.
    func made(_ pages: [Page], name: String, annotate: (PDFPage) -> Void) throws -> URL {
        let url = try made(pages, name: name)
        let document = try XCTUnwrap(PDFDocument(url: url))
        annotate(try XCTUnwrap(document.page(at: 0)))
        XCTAssertTrue(document.write(to: url))
        return url
    }

    func report(_ json: String) throws {
        try Data(json.utf8).write(to: base.appendingPathComponent("item-manuals-report.json"))
    }

    var listed: [String: [String: String]] {
        get throws {
            let data = try Data(contentsOf: base.appendingPathComponent("item-manuals/manuals.json"))
            return try JSONDecoder().decode([String: [String: String]].self, from: data)
        }
    }

    func testAManualIsCopiedAndListed() async throws {
        let pdf = try made([.text(["CAMP STOVE 2", "Light the burner"]), .text(["Page two"])])
        let entry = try await manuals.add(pdf: pdf, itemID: 7, itemName: "Camp stove", isPrivate: false)
        let copied = base.appendingPathComponent("item-manuals/item-7.pdf")
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: pdf), "copied whole")
        let sha = SHA256.hash(data: try Data(contentsOf: pdf)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(entry, ItemManuals.Entry(file: "item-7.pdf", item: "Camp stove", sha256: sha))
        XCTAssertEqual(try listed, ["7": ["file": "item-7.pdf", "item": "Camp stove", "sha256": sha]])
        XCTAssertEqual(manuals.entry(itemID: 7), entry)
        // each page went through the check, by its number
        XCTAssertEqual(check.asked.map(\.place).filter { $0.hasPrefix("The manual,") },
                       ["The manual, page 1", "The manual, page 2"])
        XCTAssertTrue(check.asked[0].cells[0].text.contains("CAMP STOVE"))
        // no temporary file left beside them
        let names = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("item-manuals").path)
        XCTAssertEqual(Set(names), ["item-7.pdf", "manuals.json"])
        // a second item's manual is added beside it; a replaced one swaps its file and its line
        _ = try await manuals.add(pdf: try made([.text(["Lantern"])], name: "b.pdf"), itemID: 9, itemName: "Lantern",
                                  isPrivate: false)
        let replaced = try await manuals.add(pdf: try made([.text(["Stove, new edition"])], name: "c.pdf"), itemID: 7,
                                             itemName: "Camp stove", isPrivate: false)
        XCTAssertNotEqual(replaced.sha256, sha)
        XCTAssertEqual(Set(try listed.keys), ["7", "9"])
        XCTAssertEqual(try listed["7"]?["sha256"], replaced.sha256)
    }

    func testAPrivateItemIsRefused() async throws {
        let pdf = try made([.text(["Safe"])])
        do {
            _ = try await manuals.add(pdf: pdf, itemID: 4, itemName: "Heater", isPrivate: true)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertEqual(refused.words, "A Mac-only item's manual would reach every phone.")
        }
        XCTAssertTrue(check.asked.isEmpty, "never read")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("item-manuals/item-4.pdf").path))
        XCTAssertNil(manuals.entry(itemID: 4))
    }

    func testAnIDInTheTextIsRefusedWithItsPageOnly() async throws {
        let pdf = try made([.text(["Fine"]), .text(["Fine too"]), .text(["Owner REFUSE 12345"])])
        do {
            _ = try await manuals.add(pdf: pdf, itemID: 7, itemName: "Camp stove", isPrivate: false)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertTrue(refused.words.contains("page 3"), refused.words)
            XCTAssertFalse(refused.words.contains("12345"), "never the text")
        }
        XCTAssertNil(manuals.entry(itemID: 7))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("item-manuals/item-7.pdf").path))

        // The real check, when this Mac has it: an ID number's shape on page 2, refused naming the page and the kind.
        guard let python = PythonTextCheck.venvPython(),
              FileManager.default.isExecutableFile(atPath: python.path) else { return }
        let real = ItemManuals(support: base, checker: PythonTextCheck(python: python, code: InventoryTests.repo))
        let made = [String(200 + 19), "0" + String(4 + 5), String(9000 + 999)].joined(separator: "-")  // made up
        let withID = try self.made([.text(["Fine"]), .text(["SSN " + made])], name: "id.pdf")
        do {
            _ = try await real.add(pdf: withID, itemID: 7, itemName: "Camp stove", isPrivate: false)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertTrue(refused.words.hasPrefix("The manual, page 2"), refused.words)
            XCTAssertFalse(refused.words.contains(made))
        }
        XCTAssertNil(real.entry(itemID: 7))
    }

    func testAScannedPageIsReadWithVision() async throws {
        let pdf = try made([.text(["LANTERN 400", "Fit the mantle"]), .picture(["WIRING DIAGRAM"]),
                            .text(["Care and storage"])])
        _ = try await manuals.add(pdf: pdf, itemID: 3, itemName: "Lantern", isPrivate: false)
        check.asked.removeAll { !$0.place.hasPrefix("The manual,") }  // only the pages here
        XCTAssertEqual(check.asked.count, 3)
        XCTAssertEqual(check.asked[1].place, "The manual, page 2")
        XCTAssertTrue(check.asked[1].cells[0].text.uppercased().contains("WIRING"),
                      "the picture's words reached the check: \(check.asked[1].cells[0].text)")
        XCTAssertNotNil(manuals.entry(itemID: 3))

        // a picture page holding what the check refuses is refused by its number
        let refusedPDF = try made([.text(["Fine"]), .picture(["REFUSE"])], name: "b.pdf")
        do {
            _ = try await manuals.add(pdf: refusedPDF, itemID: 5, itemName: "Radio", isPrivate: false)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertTrue(refused.words.contains("page 2"), refused.words)
        }
        XCTAssertNil(manuals.entry(itemID: 5))
    }

    /// A picture on a page that also has typed text (a rating plate's photo) is read with Vision too, so an ID number
    /// in it is refused (phase K finding 4); the page's typed text and the picture's both reach the check.
    func testAPictureOnATypedPageIsReadToo() async throws {
        let pdf = try made([.text(["LANTERN 400"]), .textAndPicture(["Rating plate"], ["MODEL 400 WATTS"])])
        _ = try await manuals.add(pdf: pdf, itemID: 3, itemName: "Lantern", isPrivate: false)
        let page = try XCTUnwrap(check.asked.first { $0.place == "The manual, page 2" }).cells[0].text
        XCTAssertTrue(page.contains("Rating plate"), page)
        XCTAssertTrue(page.uppercased().contains("WATTS"), "the picture's words reached the check: \(page)")

        let refusedPDF = try made([.text(["Fine"]), .textAndPicture(["Rating plate"], ["REFUSE"])], name: "b.pdf")
        do {
            _ = try await manuals.add(pdf: refusedPDF, itemID: 5, itemName: "Radio", isPrivate: false)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertTrue(refused.words.hasPrefix("The manual, page 2"), refused.words)
        }
        XCTAssertNil(manuals.entry(itemID: 5))

        // The real check, when this Mac has it: an ID number's shape in the picture only.
        guard let python = PythonTextCheck.venvPython(),
              FileManager.default.isExecutableFile(atPath: python.path) else { return }
        let real = ItemManuals(support: base, checker: PythonTextCheck(python: python, code: InventoryTests.repo))
        let sample = [String(200 + 19), "0" + String(4 + 5), String(9000 + 999)].joined(separator: "-")  // made up
        let withID = try made([.text(["Fine"]), .textAndPicture(["Rating plate"], ["SSN " + sample])], name: "id.pdf")
        do {
            _ = try await real.add(pdf: withID, itemID: 7, itemName: "Camp stove", isPrivate: false)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertTrue(refused.words.hasPrefix("The manual, page 2"), refused.words)
            XCTAssertFalse(refused.words.contains(sample))
        }
        XCTAssertNil(real.entry(itemID: 7))
    }

    /// A manuals.json that can't be read is never taken for an empty list: add, remove and keep refuse and change
    /// nothing, in the Mac's line (phase K finding 6). A missing one is an empty list, as before.
    func testAnUnreadableListChangesNothing() async throws {
        XCTAssertEqual(try manuals.entries(), [:], "no list yet")
        _ = try await manuals.add(pdf: try made([.text(["Lantern"])]), itemID: 9, itemName: "Lantern", isPrivate: false)
        let list = base.appendingPathComponent("item-manuals/manuals.json")
        let kept = base.appendingPathComponent("item-manuals/item-9.pdf")
        let words = "The list of equipment manuals can't be read, so nothing was changed: it isn't in the list's form."
        for damaged in [Data("{\"9\": {\"file\": \"item-9.pdf\"".utf8), Data([0xFF, 0x00]),
                        Data(#"{"nine": {"file": "item-9.pdf", "item": "Lantern", "sha256": "00"}}"#.utf8)] {
            try damaged.write(to: list)
            XCTAssertThrowsError(try manuals.entries()) { XCTAssertEqual("\($0)", words) }
            do {
                _ = try await manuals.add(pdf: try made([.text(["Stove"])], name: "s.pdf"), itemID: 7,
                                          itemName: "Camp stove", isPrivate: false)
                XCTFail("added")
            } catch let unreadable as ItemManuals.Unreadable {
                XCTAssertEqual(unreadable.description, words)
            }
            XCTAssertThrowsError(try manuals.remove(itemID: 9)) { XCTAssertTrue($0 is ItemManuals.Unreadable) }
            XCTAssertThrowsError(try manuals.keep(shared: [:])) { XCTAssertTrue($0 is ItemManuals.Unreadable) }
            XCTAssertEqual(try Data(contentsOf: list), damaged, "the list as it was")
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "the kept manual stays")
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("item-manuals/item-7.pdf").path))
            XCTAssertNil(manuals.entry(itemID: 9))
            XCTAssertEqual(manuals.forPhones(), [])
        }
        try FileManager.default.removeItem(at: list)
        try FileManager.default.createDirectory(at: list, withIntermediateDirectories: false)  // a folder in its place
        XCTAssertThrowsError(try manuals.entries()) {
            XCTAssertEqual("\($0)", "The list of equipment manuals can't be read, so nothing was changed: "
                           + "the file couldn't be opened.")
        }
    }

    /// The owner's ruling (2026-10-30; refused since 2026-10-18): a manual with no text at all (a scan, or words drawn
    /// as shapes) has every page read with Vision and is listed as read as pictures; one with no words even so is refused.
    func testAWhollyScannedManualIsReadAsPictures() async throws {
        let pdf = try made([.picture(["SCANNED PAGE ONE"]), .picture(["SCANNED PAGE TWO"])])
        let entry = try await manuals.add(pdf: pdf, itemID: 7, itemName: "Camp stove", isPrivate: false)
        XCTAssertEqual(entry.pictures, true)
        let pages = check.asked.filter { $0.place.hasPrefix("The manual,") }
        XCTAssertEqual(pages.map(\.place), ["The manual, page 1", "The manual, page 2"])
        XCTAssertTrue(pages[1].cells[0].text.uppercased().contains("PAGE TWO"), pages[1].cells[0].text)
        let raw = try Data(contentsOf: base.appendingPathComponent("item-manuals/manuals.json"))
        let line = try XCTUnwrap((try JSONSerialization.jsonObject(with: raw) as? [String: [String: Any]])?["7"])
        XCTAssertEqual(line["pictures"] as? Bool, true, "the packer takes it as checked by this")
        // a renamed item keeps the mark
        try manuals.keep(shared: [7: "Camp stove two"])
        XCTAssertEqual(manuals.entry(itemID: 7)?.pictures, true)
        // a typed manual has no mark at all
        let typed = try await manuals.add(pdf: try made([.text(["Typed"])], name: "typed.pdf"), itemID: 8,
                                          itemName: "Lantern", isPrivate: false)
        XCTAssertNil(typed.pictures)

        // a picture-only page holding what the check refuses is refused by its number
        do {
            _ = try await manuals.add(pdf: try made([.picture(["FINE"]), .picture(["REFUSE"])], name: "r.pdf"),
                                      itemID: 9, itemName: "Radio", isPrivate: false)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertTrue(refused.words.contains("page 2"), refused.words)
        }
        XCTAssertNil(manuals.entry(itemID: 9))

        // no words on any page, even as pictures: refused
        do {
            _ = try await manuals.add(pdf: try made([.text([]), .text([])], name: "blank.pdf"), itemID: 10,
                                      itemName: "Stove", isPrivate: false)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertEqual(refused.words, ItemManuals.scanned)
            XCTAssertEqual(refused.words, "No words could be read on any page, even as pictures, so it can't be "
                           + "checked for ID numbers. Look for another copy of the manual.")
        }
        XCTAssertNil(manuals.entry(itemID: 10))
        // and a file that isn't a PDF is refused too
        let notPDF = base.appendingPathComponent("notes.pdf")
        try Data("not a pdf".utf8).write(to: notPDF)
        do {
            _ = try await manuals.add(pdf: notPDF, itemID: 7, itemName: "Camp stove", isPrivate: false)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertEqual(refused.words, ItemManuals.notAPDF)
        }
    }

    func testACheckThatCantRunKeepsNothing() async throws {
        check.broken = true
        let pdf = try made([.text(["Fine"])])
        do {
            _ = try await manuals.add(pdf: pdf, itemID: 7, itemName: "Camp stove", isPrivate: false)
            XCTFail("added")
        } catch is CheckUnavailable {}
        XCTAssertNil(manuals.entry(itemID: 7))
    }

    func testRemoveForgetsIt() async throws {
        _ = try await manuals.add(pdf: try made([.text(["Stove"])]), itemID: 7, itemName: "Camp stove",
                                  isPrivate: false)
        _ = try await manuals.add(pdf: try made([.text(["Lantern"])], name: "b.pdf"), itemID: 9, itemName: "Lantern",
                                  isPrivate: false)
        try manuals.remove(itemID: 7)
        XCTAssertNil(manuals.entry(itemID: 7))
        XCTAssertNotNil(manuals.entry(itemID: 9))
        XCTAssertEqual(Set(try listed.keys), ["9"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("item-manuals/item-7.pdf").path))
        try manuals.remove(itemID: 7)  // again: nothing to do
    }

    /// An item that turns Private or is deleted has its manual dropped (it would reach every phone in the library), and
    /// a renamed one's line takes its new name (the library's index titles it).
    func testKeepDropsPrivateAndGoneItemsAndRenames() async throws {
        for (id, name) in [(Int64(1), "Stove"), (2, "Heater"), (3, "Lantern")] {
            _ = try await manuals.add(pdf: try made([.text([name])], name: "\(id).pdf"), itemID: id, itemName: name,
                                      isPrivate: false)
        }
        try manuals.keep(shared: [1: "Camp stove", 3: "Lantern"])
        XCTAssertEqual(try manuals.entries().keys.sorted(), [1, 3])
        XCTAssertEqual(manuals.entry(itemID: 1)?.item, "Camp stove")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("item-manuals/item-2.pdf").path))
    }

    /// Where the item stands against the packer's report (beside the folder, never inside it).
    func testTheStateFollowsThePackersReport() async throws {
        XCTAssertEqual(manuals.state(itemID: 7), .none)
        let entry = try await manuals.add(pdf: try made([.text(["Stove"])]), itemID: 7, itemName: "Camp stove",
                                          isPrivate: false)
        XCTAssertEqual(manuals.state(itemID: 7), .waiting, "no report yet")
        let report = base.appendingPathComponent("item-manuals-report.json")
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        try Data(#"{"built": "\#(later)", "in": {"7": "\#(entry.sha256)"}, "left_out": {}}"#.utf8).write(to: report)
        XCTAssertEqual(manuals.state(itemID: 7), .ready)
        try Data(#"{"built": "\#(later)", "in": {}, "left_out": {"7": "it holds a script"}}"#.utf8).write(to: report)
        XCTAssertEqual(manuals.state(itemID: 7), .leftOut("it holds a script"))
        // a report from before the manual was added says nothing about it yet
        let earlier = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        try Data(#"{"built": "\#(earlier)", "in": {}, "left_out": {"7": "old"}}"#.utf8).write(to: report)
        XCTAssertEqual(manuals.state(itemID: 7), .waiting)
    }

    // MARK: Review fixes (2026-10-18)

    /// The packer reads the PDF's title (its name in the library's index), so the details go through the same check:
    /// a Mac-accepted manual must never stop the whole library. Refused naming the detail and the kind only.
    /// The owner's radio manual (2026-10-18): a page's tone and code tables pass the code rule (codes_ok); the
    /// details, which title the library, keep the whole check.
    func testAPageMayHoldCodeTablesButTheDetailsMayNot() throws {
        let page = ItemManuals.pageRow("DCS code 023 025", page: 55).cells
        XCTAssertEqual(page, [CheckCell(label: "text", text: "DCS code 023 025", longNumbersOK: true, amountsOK: true,
                                        codesOK: true)])
        XCTAssertFalse(try XCTUnwrap(ItemManuals.detailRow("x", name: "title").cells.first).codesOK)
        let sent = String(decoding: try JSONEncoder().encode(page[0]), as: UTF8.self)
        XCTAssertTrue(sent.contains("\"codes_ok\":true"), sent)
    }

    func testTheManualsDetailsGoThroughTheCheck() async throws {
        let titled = try made([.text(["Camp stove"])], name: "t.pdf", info: [kCGPDFContextTitle: "Owner REFUSE 12345"])
        do {
            _ = try await manuals.add(pdf: titled, itemID: 7, itemName: "Camp stove", isPrivate: false)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertTrue(refused.words.hasPrefix("The manual's title"), refused.words)
            XCTAssertFalse(refused.words.contains("12345"), "never the text")
        }
        XCTAssertNil(manuals.entry(itemID: 7))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("item-manuals/item-7.pdf").path))
        for (key, place) in [(kCGPDFContextSubject, "The manual's subject"), (kCGPDFContextAuthor, "The manual's author"),
                             (kCGPDFContextKeywords, "The manual's keywords"),
                             (kCGPDFContextCreator, "The manual's creator")] {
            let pdf = try made([.text(["Camp stove"])], name: "d.pdf", info: [key: "REFUSE"])
            do {
                _ = try await manuals.add(pdf: pdf, itemID: 7, itemName: "Camp stove", isPrivate: false)
                XCTFail("added with \(place)")
            } catch let refused as ItemManuals.Refused {
                XCTAssertTrue(refused.words.hasPrefix(place), refused.words)
            }
        }
        XCTAssertNil(manuals.entry(itemID: 7))
        // fine details are read and kept
        let fine = try made([.text(["Camp stove"])], name: "f.pdf", info: [kCGPDFContextTitle: "Camp Stove Manual"])
        _ = try await manuals.add(pdf: fine, itemID: 7, itemName: "Camp stove", isPrivate: false)
        XCTAssertTrue(check.asked.contains { $0.place == "The manual's title" && $0.cells[0].text == "Camp Stove Manual" })

        // The real check, when this Mac has it: an ID number's shape in the title.
        guard let python = PythonTextCheck.venvPython(),
              FileManager.default.isExecutableFile(atPath: python.path) else { return }
        let real = ItemManuals(support: base, checker: PythonTextCheck(python: python, code: InventoryTests.repo))
        let sample = [String(200 + 19), "0" + String(4 + 5), String(9000 + 999)].joined(separator: "-")  // made up
        let withID = try made([.text(["Fine"])], name: "id.pdf", info: [kCGPDFContextTitle: "SSN " + sample])
        do {
            _ = try await real.add(pdf: withID, itemID: 9, itemName: "Lantern", isPrivate: false)
            XCTFail("added")
        } catch let refused as ItemManuals.Refused {
            XCTAssertTrue(refused.words.hasPrefix("The manual's title"), refused.words)
            XCTAssertFalse(refused.words.contains(sample))
        }
        XCTAssertNil(real.entry(itemID: 9))
    }

    /// Filled-in form fields and notes are skipped by every page-text reader, so they can't be checked: refused, as
    /// the packer leaves such a PDF out.
    func testFilledInFormsAndNotesAreRefused() async throws {
        let words = "It has filled-in form fields or notes, which can't be checked for ID numbers. Add a blank copy."
        XCTAssertEqual(ItemManuals.filledIn, words)
        let filled = try made([.text(["Warranty card"])], name: "form.pdf") { page in
            let field = PDFAnnotation(bounds: CGRect(x: 60, y: 300, width: 300, height: 30), forType: .widget,
                                      withProperties: nil)
            field.widgetFieldType = .text
            field.fieldName = "owner"
            field.widgetStringValue = "Filled in"
            page.addAnnotation(field)
        }
        let noted = try made([.text(["Warranty card"])], name: "note.pdf") { page in
            let note = PDFAnnotation(bounds: CGRect(x: 60, y: 300, width: 20, height: 20), forType: .text,
                                     withProperties: nil)
            note.contents = "A note"
            page.addAnnotation(note)
        }
        for pdf in [filled, noted] {
            do {
                _ = try await manuals.add(pdf: pdf, itemID: 7, itemName: "Camp stove", isPrivate: false)
                XCTFail("added \(pdf.lastPathComponent)")
            } catch let refused as ItemManuals.Refused {
                XCTAssertEqual(refused.words, words)
            }
            XCTAssertNil(manuals.entry(itemID: 7))
        }
        // a blank form is fine
        let blank = try made([.text(["Warranty card"])], name: "blank.pdf") { page in
            let field = PDFAnnotation(bounds: CGRect(x: 60, y: 300, width: 300, height: 30), forType: .widget,
                                      withProperties: nil)
            field.widgetFieldType = .text
            field.fieldName = "owner"
            page.addAnnotation(field)
        }
        _ = try await manuals.add(pdf: blank, itemID: 7, itemName: "Camp stove", isPrivate: false)
        XCTAssertNotNil(manuals.entry(itemID: 7))
    }

    /// When the ID check stops the manuals library, the report names the manual it stopped on (`stopped`, words
    /// only) and keeps the last delivered build's `in`: only those rows read as in the library.
    func testAStoppedBuildNamesItsManualOnly() async throws {
        var sha: [Int64: String] = [:]
        for (id, name) in [(Int64(7), "Stove"), (8, "Heater"), (9, "Lantern"), (10, "Radio")] {
            sha[id] = try await manuals.add(pdf: try made([.text([name])], name: "\(id).pdf"), itemID: id,
                                            itemName: name, isPrivate: false).sha256
        }
        let earlier = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        try report(#"{"built": "\#(earlier)", "in": {"9": "\#(sha[9]!)", "10": "stale"}, "left_out": {},"#
                   + #" "stopped": {"7": "page 3: an ID number's shape"}, "stopped_at": "\#(later)"}"#)
        XCTAssertEqual(manuals.state(itemID: 7), .stopped("page 3: an ID number's shape"))
        XCTAssertEqual(ItemManuals.stoppedWords("page 3: an ID number's shape"),
                       "The library build stopped on this manual (page 3: an ID number's shape); replace or remove it.")
        XCTAssertEqual(manuals.state(itemID: 8), .waiting, "not in the delivered build")
        XCTAssertEqual(manuals.state(itemID: 9), .ready, "in the delivered build, same file")
        XCTAssertEqual(manuals.state(itemID: 10), .waiting, "in the delivered build, but an older file")
        // the phones get a manual path for every row but the stopped (and left-out) ones
        XCTAssertEqual(manuals.forPhones(), [8, 9, 10])
        // a manual replaced after the stopped build is waiting again
        try report(#"{"built": "\#(earlier)", "in": {}, "left_out": {},"#
                   + #" "stopped": {"7": "title: an ID number's shape"}, "stopped_at": "\#(earlier)"}"#)
        XCTAssertEqual(manuals.state(itemID: 7), .waiting)
        XCTAssertEqual(manuals.forPhones(), [7, 8, 9, 10])
    }

    /// A left-out manual gets no path on the phones (it isn't in their library).
    func testALeftOutManualIsNotOnThePhones() async throws {
        for (id, name) in [(Int64(7), "Stove"), (8, "Heater")] {
            _ = try await manuals.add(pdf: try made([.text([name])], name: "\(id).pdf"), itemID: id, itemName: name,
                                      isPrivate: false)
        }
        XCTAssertEqual(manuals.forPhones(), [7, 8], "waiting ones go: the phone says where it is")
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        try report(#"{"built": "\#(later)", "in": {}, "left_out": {"7": "it holds a script"}}"#)
        XCTAssertEqual(manuals.forPhones(), [8])
    }

    /// The packer writes its time with the home's offset (Python's isoformat), not in UTC.
    func testAReportTimeWithAnOffsetIsRead() async throws {
        _ = try await manuals.add(pdf: try made([.text(["Stove"])]), itemID: 7, itemName: "Camp stove",
                                  isPrivate: false)
        let eastern = ISO8601DateFormatter()
        eastern.timeZone = TimeZone(secondsFromGMT: -4 * 3600)
        let later = eastern.string(from: Date().addingTimeInterval(60))
        XCTAssertTrue(later.hasSuffix("-04:00"), later)
        try report(#"{"built": "\#(later)", "in": {}, "left_out": {"7": "it holds a script"}}"#)
        XCTAssertEqual(manuals.state(itemID: 7), .leftOut("it holds a script"))
        let earlier = eastern.string(from: Date().addingTimeInterval(-3600))
        try report(#"{"built": "\#(earlier)", "in": {}, "left_out": {"7": "it holds a script"}}"#)
        XCTAssertEqual(manuals.state(itemID: 7), .waiting, "an hour before, in its own offset")
    }

    /// An add and a keep at the same time never lose each other's change to manuals.json.
    func testAddsAndKeepsAtOnceLoseNothing() async throws {
        let ids = Array(Int64(1)...24)
        var made: [Int64: URL] = [:]
        for id in ids { made[id] = try self.made([.text(["Item \(id)"])], name: "\(id).pdf") }
        let pdfs = made
        let shared = Dictionary(uniqueKeysWithValues: ids.map { ($0, "Renamed \($0)") })
        let manuals = ItemManuals(support: base, checker: PassCheck())  // FakeCheck records, so isn't for many at once
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { _ = try await manuals.add(pdf: pdfs[id]!, itemID: id, itemName: "Item \(id)",
                                                          isPrivate: false) }
                group.addTask { for _ in 0..<5 { try manuals.keep(shared: shared) } }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try manuals.entries().keys.sorted(), ids, "every add kept")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: manuals.folder.appendingPathComponent("item-\(id).pdf").path))
        }
    }
}

/// A check that keeps everything and records nothing, safe to ask from many tasks at once.
struct PassCheck: TextChecking {
    func check(_ rows: [CheckRow], file: URL?) async throws -> CheckAnswer { CheckAnswer(refused: []) }
}
