import Foundation
@testable import PrepareMeShared
import XCTest

/// Barcodes and bin labels (plan phase 7, slice 6). Made-up codes only; the card-number one is Visa's published test
/// number, in pieces (guard/tests/samples.py).
final class BarcodeTests: XCTestCase {
    func testOnlyARealProductCodeIsKept() {
        XCTAssertEqual(Barcode.valid(["4006", "3813", "3393", "1"].joined()), ["4006", "3813", "3393", "1"].joined())  // EAN-13, check digit 1
        XCTAssertEqual(Barcode.valid(["0360", "0029", "1452"].joined()), "0" + ["0360", "0029", "1452"].joined())  // UPC-A, kept as the camera reads it
        XCTAssertEqual(Barcode.valid("9638-5074"), ["9638", "5074"].joined())  // EAN-8, dash dropped
        XCTAssertNil(Barcode.valid(["4006", "3813", "3393", "2"].joined()))  // wrong check digit
        XCTAssertNil(Barcode.valid(["1234", "5678", "9"].joined()))  // 9 digits: no product code is
        XCTAssertNil(Barcode.valid("40063813339A1"))
        XCTAssertNil(Barcode.valid(""))
        XCTAssertNil(Barcode.valid(String(repeating: "0", count: 12)), "all 0s: a services' junk record, no product")
    }

    /// One product, one stored form, however it was scanned (review, 2026-10-14).
    func testOneProductIsKeptInOneForm() {
        let upcA = ["0421", "0000", "5264"].joined()  // a UPC-A as a USB scanner types it
        let ean13 = "0" + upcA  // the same code as the phone's camera reads it
        XCTAssertEqual(Barcode.valid(upcA), ean13)
        XCTAssertEqual(Barcode.valid(ean13), ean13)
        XCTAssertEqual(Barcode.valid("0" + ean13), ean13)  // GTIN-14 with a 0 in front
        XCTAssertEqual(Barcode.valid(["0425", "2614"].joined()), ean13)  // its UPC-E, expanded
        XCTAssertEqual(Barcode.expanded(["0425", "2614"].joined()), upcA)
        XCTAssertNil(Barcode.valid(["0425", "2615"].joined()))  // neither a good EAN-8 nor a good UPC-E
        XCTAssertEqual(Barcode.valid(["9638", "5074"].joined()), ["9638", "5074"].joined())  // a good EAN-8 stays one
        let gtin14 = ["1400", "6381", "3339", "38"].joined()  // indicator 1: its own code, kept whole
        XCTAssertEqual(Barcode.valid(gtin14), gtin14)
    }

    func testACardNumberIsNeverABarcodeEvenWithAGoodCheckDigit() {
        // 16 digits: no GTIN has that length, whatever its digits
        let card = ["4111", "1111", "1111", "1111"].joined()
        XCTAssertNil(Barcode.valid(card))
    }

    func testABinLabelNamesOnlyItsPlace() {
        XCTAssertEqual(Barcode.placeURL(12).absoluteString, "prepareme://place/12")
        XCTAssertEqual(Barcode.place(in: "prepareme://place/12"), 12)
        XCTAssertNil(Barcode.place(in: "prepareme://place/0"))
        XCTAssertNil(Barcode.place(in: "https://place/12"))
        XCTAssertNil(Barcode.place(in: "prepareme://item/12"))
        XCTAssertNil(Barcode.place(in: ["4006", "3813", "3393", "1"].joined()))
    }

    func testCodesAreKeptInTheFilesOwnTable() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-codes-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("PrepareMe Inventory.grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        let file = try InventoryFile(url: url)
        XCTAssertEqual(try file.barcodes(), [:])
        XCTAssertNil(try file.link(["4006", "3813", "3393", "1"].joined(), to: 3))
        XCTAssertEqual(try file.link(["4006", "3813", "3393", "1"].joined(), to: 5), 3, "a code names one item; linking again moves it")
        XCTAssertEqual(try file.barcodes(), [["4006", "3813", "3393", "1"].joined(): 5])
        XCTAssertEqual(try file.unlink(["4006", "3813", "3393", "1"].joined()), 5)
        XCTAssertEqual(try file.barcodes(), [:])
    }
}

/// Barcodes through the editor (slice 6): checked, linked, undone; a new item with its code in one save; on the phones'
/// copy only for items that aren't Private.
@MainActor
final class BarcodeEditorTests: XCTestCase {
    var base: URL!
    var check: FakeCheck!
    var editor: InventoryEditor!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-codes-editor-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("PrepareMe Inventory.grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        check = FakeCheck()
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: check)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testALinkIsCheckedKeptAndUndone() async throws {
        let outcome = try await editor.apply(.linkBarcode(code: "4006-381333931", row: 3))
        guard case .done(let undo, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(check.asked.last, CheckRow(place: "Barcodes", cells: [
            CheckCell(label: "Barcode", text: ["4006", "3813", "3393", "1"].joined(), longNumbersOK: true)]))
        XCTAssertEqual(try editor.file.barcodes(), [["4006", "3813", "3393", "1"].joined(): 3])
        _ = try await editor.apply(undo)
        XCTAssertEqual(try editor.file.barcodes(), [:])
        let refused = try await editor.apply(.linkBarcode(code: ["4006", "3813", "3393", "2"].joined(), row: 3))
        XCTAssertEqual(refused, .refused(InventoryWords.notABarcode))
    }

    func testANewItemWithItsCodeIsOneSave() async throws {
        let item = editor.inventory.items.column("Item")!.colId
        let outcome = try await editor.apply(.addItem(values: [item: .text("Lantern")], barcode: ["0360", "0029", "1452"].joined()))
        guard case .done(let undo, let row) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try editor.file.barcodes(), ["0" + ["0360", "0029", "1452"].joined(): row])
        _ = try await editor.apply(undo)
        XCTAssertNil(editor.inventory.itemRows.first { $0.id == row })
    }

    func testANewItemNeverTakesADeletedOnesCodes() async throws {
        let item = editor.inventory.items.column("Item")!.colId
        guard case .done(_, let first) = try await editor.apply(.addItem(values: [item: .text("Lantern")],
                                                                          barcode: ["0360", "0029", "1452"].joined())) else {
            return XCTFail("not added")
        }
        _ = try await editor.apply(.delete(table: "Inventory", row: first))
        guard case .done(_, let second) = try await editor.apply(.add(table: "Inventory",
                                                                       values: [item: .text("Rope")])) else {
            return XCTFail("not added")
        }
        // the number never comes back (entry fixes plan, Task 1.9, 2026-10-23), and the rope has no code
        XCTAssertEqual(second, first + 1)
        XCTAssertFalse(try editor.file.barcodes().values.contains(second))
    }

    func testMovingACodeIsUndoneToItsItem() async throws {
        try editor.file.link("0" + ["0360", "0029", "1452"].joined(), to: 3)
        guard case .done(let undo, _) = try await editor.apply(.linkBarcode(code: ["0360", "0029", "1452"].joined(), row: 1)) else {
            return XCTFail("not linked")
        }
        XCTAssertEqual(try editor.file.barcodes(), ["0" + ["0360", "0029", "1452"].joined(): 1])
        _ = try await editor.apply(undo)
        XCTAssertEqual(try editor.file.barcodes(), ["0" + ["0360", "0029", "1452"].joined(): 3])
    }

    /// Undo puts a code back only while nothing has changed it since (review, 2026-10-14).
    func testUndoNeverOverwritesALaterLink() async throws {
        let code = "0" + ["0360", "0029", "1452"].joined()
        guard case .done(let undo, _) = try await editor.apply(.linkBarcode(code: code, row: 3)) else {
            return XCTFail("not linked")
        }
        try editor.file.link(code, to: 1)  // a phone moved it since
        let undone = try await editor.apply(undo)
        XCTAssertEqual(undone, .refused(InventoryWords.changedSince))
        let removed = try await editor.apply(.unlinkBarcode(code: code, row: 3))  // the Mac's Remove on item 3
        XCTAssertEqual(removed, .refused(InventoryWords.changedSince))
        XCTAssertEqual(try editor.file.barcodes(), [code: 1])
        guard case .done(let back, _) = try await editor.apply(.unlinkBarcode(code: code, row: 1)) else {
            return XCTFail("not removed")
        }
        try editor.file.link(code, to: 5)  // linked again elsewhere since
        let relinked = try await editor.apply(back)
        XCTAssertEqual(relinked, .refused(InventoryWords.changedSince))
        XCTAssertEqual(try editor.file.barcodes(), [code: 5])
    }

    /// A phone never takes a code from a Private item: it can't see that item's codes, so it sees the code as new.
    func testAPhoneNeverTakesAPrivateItemsCode() async throws {
        let code = "0" + ["0360", "0029", "1452"].joined()
        try editor.file.link(code, to: 2)  // the made-up heater, Private
        try editor.reload()
        let item = editor.inventory.items.column("Item")!.colId
        XCTAssertEqual(PhoneRules.refusal(.linkBarcode(code: code, row: 3), editor.inventory),
                       PhoneRules.codeElsewhereLink, "a link: nothing to edit again")
        XCTAssertEqual(PhoneRules.codeElsewhereLink, "That barcode is on another item, so it wasn't added to this one.")
        XCTAssertEqual(PhoneRules.refusal(.addItem(values: [item: .text("Jugs")], barcode: ["0360", "0029", "1452"].joined()), editor.inventory),
                       PhoneRules.codeElsewhere)
        XCTAssertNil(PhoneRules.refusal(.linkBarcode(code: ["4006", "3813", "3393", "1"].joined(), row: 3),
                                        editor.inventory))
    }

    /// Entry fixes, phase 4: the refusal never says the item went, nor that it's Private; Edit again drops the code.
    func testAPrivateCodeRefusalIsNeutralAndEditAgainDropsIt() {
        let words = PhoneEditRules.refusalLine(message: PhoneRules.codeElsewhere, item: "Jugs", what: "Added Jugs")
        XCTAssertEqual(words, "That barcode is on another item, so this wasn't kept. Edit again keeps it without the "
                       + "barcode.")
        XCTAssertFalse(words.localizedCaseInsensitiveContains("private"))
        XCTAssertFalse(words.localizedCaseInsensitiveContains("removed"))
        let code = ["0360", "0029", "1452"].joined()
        let refused = PhoneOutbox.Refusal(id: "a", what: "Added Jugs", message: PhoneRules.codeElsewhere)
        XCTAssertNil(refused.keptBarcode(code))
        XCTAssertEqual(PhoneOutbox.Refusal(id: "b", what: "x", message: "Year: must be four digits.").keptBarcode(code),
                       code, "any other refusal keeps it")
    }

    func testThePhonesNeverGetAPrivateItemsCode() async throws {
        try editor.file.link(["4006", "3813", "3393", "1"].joined(), to: 2)  // the made-up heater, Private
        try editor.file.link("0" + ["0360", "0029", "1452"].joined(), to: 3)
        try editor.reload()
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:],
                                       barcodes: try editor.file.barcodes())
        XCTAssertEqual(copy.barcodes, ["0" + ["0360", "0029", "1452"].joined(): 3])
        XCTAssertEqual(PhoneRules.refusal(.linkBarcode(code: ["0360", "0029", "1452"].joined(), row: 2), editor.inventory),
                       PhoneRules.privateRow)  // the item linked to is the Private one: as any row that's gone
    }

    func testAPhonesWaitingLinkFindsTheItemAtOnce() {
        var outbox = PhoneOutbox()
        outbox.add(.linkBarcode(code: ["0360", "0029", "1452"].joined(), row: 3), what: "x")
        let copy = PhoneInventory(writtenAt: "", columns: [], items: [], places: [], categories: [], headsUpDays: 60,
                                  toBuy: [], results: [:])
        XCTAssertEqual(outbox.view(copy).barcodes, ["0" + ["0360", "0029", "1452"].joined(): 3])
    }

    /// The real check: a code with a good barcode check digit that also has a card number's shape is never kept.
    func testACodeShapedLikeACardIsRefusedByTheRealCheck() async throws {
        guard let python = PythonTextCheck.venvPython(),
              FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("no venv") }
        let real = try InventoryEditor(file: editor.file, checker: PythonTextCheck(python: python,
                                                                                   code: InventoryTests.repo))
        let code = ["4100", "0000", "01093"].joined()  // made up, in pieces: a valid EAN-13 the guard reads as a card
        XCTAssertNotNil(Barcode.valid(code))
        let outcome = try await real.apply(.linkBarcode(code: code, row: 3))
        guard case .refused(let why) = outcome else { return XCTFail("kept: \(outcome)") }
        XCTAssertFalse(why.contains(code))
        XCTAssertEqual(try editor.file.barcodes(), [:])
    }
}
