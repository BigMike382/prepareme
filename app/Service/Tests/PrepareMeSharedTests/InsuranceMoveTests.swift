import CoreText
import CryptoKit
import Foundation
@testable import PrepareMeShared
import XCTest

/// The insurance move (Essential Documents plan, phase 2) on a copy of the made-up rehearsal inventory, with made-up
/// photos and a made-up PDF: never the real inventory or a real document.
@MainActor
final class InsuranceMoveTests: XCTestCase {
    var base: URL!
    var editor: InventoryEditor!
    let key = SymmetricKey(size: .bits256)
    var store: DocumentStore { DocumentStore(root: base.appendingPathComponent("documents"), key: key) }
    var gristURL: URL { base.appendingPathComponent("PrepareMe Inventory.grist") }
    let pdf = Data("%PDF-1.4 made-up insurance record, version 1".utf8)

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-insurance-move-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: gristURL)
        editor = try InventoryEditor(file: try InventoryFile(url: gristURL), checker: FakeCheck())
        guard case .done = try await editor.apply(.startInsurance) else { return XCTFail("record not started") }
        let price = editor.inventory.items.column(Insurance.price)!.colId
        guard case .done = try await editor.apply(.set(table: "Inventory", row: 3, colId: price, value: .real(1249.99)))
        else { return XCTFail("price not set") }
        try editor.file.addPhoto(item: 3, jpeg: InsuranceTests.photo(["RECEIPT"]))
        try editor.file.addPhoto(item: 3, jpeg: InsuranceTests.photo(["LABEL"]))
        try editor.file.addPhoto(item: 1, jpeg: InsuranceTests.photo(["FRONT"]))  // photos, no price: still moved
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// The inventory as the Mac app reads it for the move: a connection of its own, read-only.
    func source(pdf: Data? = nil) throws -> InsuranceMove.Source {
        try InsuranceMove.source(try InventoryFile(url: gristURL, readOnly: true), pdf: pdf ?? self.pdf)
    }

    func move(_ index: inout DocumentIndex, pdf: Data? = nil) throws -> InsuranceMove.Brought {
        let (brought, old) = InsuranceMove.bring(try source(pdf: pdf), store: store, index: &index)
        try store.save(index)
        store.remove(files: old)
        index = try store.load()
        return brought
    }

    func name(_ item: Int64) -> String { editor.inventory.name(ofItem: editor.inventory.itemRows.first { $0.id == item }!) }

    func testEveryPhotoAndThePDFComeInByteForByteAndTheInventoryIsUntouched() throws {
        let before = try FileCheck.sha256(of: gristURL)
        var index = DocumentIndex()
        let brought = try move(&index)
        XCTAssertEqual(brought, InsuranceMove.Brought(photos: 3, folders: 4, refused: 0, pdf: true))
        XCTAssertEqual(try FileCheck.sha256(of: gristURL), before, "the old place is only read")

        let top = try XCTUnwrap(index.folders(in: nil).first { $0.name == "Insurance" })
        let record = try XCTUnwrap(index.folders(in: top.id).first { $0.name == "Insurance record" })
        XCTAssertEqual(index.folders(in: record.id).map(\.name).sorted(), [name(1), name(3)].sorted())
        let pdfCopy = try XCTUnwrap(index.documents(in: record.id).first)
        XCTAssertEqual(pdfCopy.fileName, "Insurance record.pdf")
        XCTAssertEqual(try store.data(of: pdfCopy), pdf)
        let three = try XCTUnwrap(index.folders(in: record.id).first { $0.name == name(3) })
        let copies = index.documents(in: three.id).sorted { $0.name < $1.name }
        XCTAssertEqual(copies.map(\.fileName), ["Photo 1.jpg", "Photo 2.jpg"])
        XCTAssertEqual(try copies.map { try store.data(of: $0) }, try editor.file.photos(of: 3).map(\.jpeg))

        let report = InsuranceMove.report(try source(), after: try source(), store: store, index: index)
        XCTAssertTrue(report.everyPairMatches)
        XCTAssertEqual(report.items, 2)
        XCTAssertEqual(report.pairs.count, 4, "three photos and the PDF")
        let lines = InsuranceMove.lines(report)
        XCTAssertEqual(lines.first, "Every pair matches: the insurance record is in Essential Documents.")
        XCTAssertTrue(lines.contains("Photos: 3 in all; by item: item 1 1, item 3 2"))
        XCTAssertEqual(lines.filter { $0.hasSuffix(": match") }.count, 4)
        XCTAssertTrue(lines.contains("Purchased, Price and Serial number: unchanged"))
        XCTAssertEqual(Set(lines.filter { $0.hasPrefix("  ") }.map(\.count)), [87],
                       "each fingerprint whole on its own line, the same width, to fit the report sheet")
        for item in [Int64(1), 3] {
            XCTAssertFalse(lines.joined().contains(name(item)), "the report names no item, only its number")
        }
    }

    func testRunningAgainBringsOnlyWhatsNewAndANewerPDFReplacesTheCopy() throws {
        var index = DocumentIndex()
        _ = try move(&index)
        XCTAssertFalse(try move(&index).changed, "every unlock runs it: a second run changes nothing")
        let count = index.documents.count

        try editor.file.addPhoto(item: 3, jpeg: InsuranceTests.photo(["SERIAL PLATE"]))
        let pdfID = index.brought!["pdf"]!
        index.recordSend(DocumentSend(date: Date(), device: "Mac", how: "Print"), for: pdfID)
        let newer = Data("%PDF-1.4 made-up insurance record, version 2".utf8)
        let brought = try move(&index, pdf: newer)
        XCTAssertEqual(brought.photos, 1)
        XCTAssertTrue(brought.pdf)
        XCTAssertEqual(index.documents.count, count + 1, "the PDF replaced, not doubled")
        let copy = try XCTUnwrap(index.documents.first { $0.id == pdfID })
        XCTAssertEqual(try store.data(of: copy), newer)
        XCTAssertEqual(copy.sends.count, 1, "its Info keeps its sends")
        let stored = try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("files").path)
        XCTAssertEqual(stored.count, index.documents.count, "the old PDF's stored file removed")
        let three = index.brought!["item:3"]!
        XCTAssertEqual(index.documents(in: three).map(\.name).sorted(), ["Photo 1", "Photo 2", "Photo 3"])
        let report = InsuranceMove.report(try source(pdf: newer), after: try source(pdf: newer), store: store,
                                          index: index)
        XCTAssertTrue(report.everyPairMatches)
    }

    func testDeletedHereStaysDeletedEvenAfterThe30Days() throws {
        var index = DocumentIndex()
        _ = try move(&index)
        let three = index.brought!["item:3"]!
        let first = index.documents(in: three).first { $0.name == "Photo 1" }!
        index.delete(document: first.id)
        XCTAssertFalse(try move(&index).changed, "a photo deleted here isn't brought back")
        let report = InsuranceMove.report(try source(), after: try source(), store: store, index: index)
        XCTAssertFalse(report.everyPairMatches)
        XCTAssertTrue(InsuranceMove.lines(report).contains("Item 3, photo 1: NO MATCH (deleted here)"))

        let one = index.brought!["item:1"]!
        index.delete(folder: one)
        _ = index.purgeExpired(now: Date().addingTimeInterval(31 * 86_400))
        try editor.file.addPhoto(item: 1, jpeg: InsuranceTests.photo(["BACK"]))
        XCTAssertFalse(try move(&index).changed, "an item's folder purged here takes its new photos with it")

        index.delete(folder: index.brought!["record"]!)
        try editor.file.addPhoto(item: 3, jpeg: InsuranceTests.photo(["NEW"]))
        let brought = try move(&index)
        XCTAssertTrue(brought.recordDeleted)
        XCTAssertFalse(brought.changed)
        let after = InsuranceMove.report(try source(), after: try source(), store: store, index: index)
        XCTAssertTrue(InsuranceMove.lines(after).contains(
            "The Insurance record folder was deleted here, so nothing more is brought in."))
    }

    func testTheOwnersOwnInsuranceFolderIsUsedAndANameAlreadyThereGetsANumber() throws {
        var index = DocumentIndex()
        let mine = index.newFolder("Insurance", in: nil)
        let record = index.newFolder("Insurance record", in: mine)
        index.newFolder(name(3), in: record)  // the owner's own folder of that name, from Add Folder of Documents…
        _ = try move(&index)
        XCTAssertEqual(index.folders(in: nil).filter { $0.name == "Insurance" }.count, 1)
        XCTAssertEqual(index.brought!["record"], record)
        XCTAssertEqual(index.folder(index.brought!["item:3"]!)?.name, "\(name(3)) (2)")
    }

    func testTheFieldsFingerprintSeesAChangedValue() async throws {
        let before = try source().fields
        XCTAssertEqual(try source().fields, before)
        let serial = editor.inventory.items.column(Insurance.serial)!.colId
        guard case .done = try await editor.apply(.set(table: "Inventory", row: 3, colId: serial, value: .text("SN-A1")))
        else { return XCTFail("serial not set") }
        XCTAssertNotEqual(try source().fields, before)
    }

    func testAnInventoryWithNoRecordSaysSo() throws {
        let plain = base.appendingPathComponent("plain.grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: plain)
        let source = try InsuranceMove.source(try InventoryFile(url: plain, readOnly: true), pdf: nil)
        let report = InsuranceMove.report(source, after: source, store: store, index: DocumentIndex())
        XCTAssertEqual(InsuranceMove.lines(report), [DocumentsWords.noInsuranceRecord])
    }

    func testAPhase1IndexStillOpens() throws {
        var old = DocumentIndex()
        old.newFolder("IDs", in: nil)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "brought")
        let back = try JSONDecoder().decode(DocumentIndex.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.folders.map(\.name), ["IDs"])
        XCTAssertNil(back.brought)
    }

    /// `PREPAREME_INSURANCE_CHECK_INVENTORY=<a check home's inventory folder, under /private/tmp> swift test --filter
    /// InsuranceMoveTests/testWriteTheCheckInventory` puts this test's made-up inventory there, with its record and
    /// photos and a made-up insurance PDF, for the check build's Bring In the Insurance Record.
    func testWriteTheCheckInventory() throws {
        guard let path = ProcessInfo.processInfo.environment["PREPAREME_INSURANCE_CHECK_INVENTORY"] else { return }
        let out = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        // resolvingSymlinksInPath gives /private/tmp as /tmp
        guard ["/private/tmp/", "/tmp/"].contains(where: out.path.hasPrefix) else {
            return XCTFail("only a scratch folder under /private/tmp")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let grist = out.appendingPathComponent("PrepareMe Inventory.grist")
        try? FileManager.default.removeItem(at: grist)
        try FileManager.default.copyItem(at: gristURL, to: grist)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for page in 1...2 {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let text = NSAttributedString(string: "Insurance record (made up for a check), page \(page) of 2",
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 60, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: out.appendingPathComponent("insurance.pdf"))
    }

    func testTheUnlockLineIsCountsOnly() {
        XCTAssertNil(DocumentsWords.broughtLine(InsuranceMove.Brought()))
        XCTAssertEqual(DocumentsWords.broughtLine(InsuranceMove.Brought(photos: 2, pdf: true)),
                       "Brought in 2 new insurance photos and the newer insurance PDF.")
        XCTAssertNil(DocumentsWords.broughtLine(InsuranceMove.Brought(pdf: true)), "the PDF is written at every start")
        XCTAssertEqual(DocumentsWords.broughtLine(InsuranceMove.Brought(photos: 1)), "Brought in 1 new insurance photo.")
        XCTAssertEqual(DocumentsWords.broughtLine(InsuranceMove.Brought(refused: 1)),
                       "1 part of the insurance record couldn't be brought in. Bring In the Insurance Record shows which.")
    }
}
