import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import PrepareMeShared
import UniformTypeIdentifiers
import XCTest

/// The insurance record (plan phase 7, slice 7): Purchased and Price on the Mac only, prices in dollars and cents,
/// photos kept in the file and read for the ID check. Made-up values only; the ID-shaped sample is assembled from pieces
/// (guard/tests/samples.py), so no file holds it whole.
@MainActor
final class InsuranceTests: XCTestCase {
    var base: URL!
    var check: FakeCheck!
    var editor: InventoryEditor!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-insurance-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("PrepareMe Inventory.grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        check = FakeCheck()
        editor = try InventoryEditor(file: try InventoryFile(url: url), checker: check)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// A JPEG of `lines` in large black type on white, as a photo of a label or receipt would read.
    static func photo(_ lines: [String]) -> Data {
        let size = CGSize(width: 1200, height: 200 + 120 * lines.count)
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
        for (n, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 60, y: size.height - 140 - CGFloat(n) * 120)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8]
                                   as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func start() async throws {
        let outcome = try await editor.apply(.startInsurance)
        guard case .done = outcome else { return XCTFail("\(outcome)") }
    }

    func testStartingTheRecordAddsADateAndAPriceColumnOnce() async throws {
        XCTAssertFalse(editor.inventory.hasInsuranceRecord)
        try await start()
        XCTAssertTrue(editor.inventory.hasInsuranceRecord)
        XCTAssertEqual(editor.inventory.items.column(Insurance.purchased)?.kind, .date)
        XCTAssertEqual(editor.inventory.items.column(Insurance.price)?.kind, .numeric)
        XCTAssertEqual(editor.inventory.items.column(Insurance.serial)?.kind, .text, "step 6: serial numbers, Mac only")
        XCTAssertFalse(editor.inventory.needsSerialColumn)
        let count = editor.inventory.items.columns.count
        try await start()
        XCTAssertEqual(editor.inventory.items.columns.count, count)
    }

    func testAPriceIsDollarsAndCentsUpToAMillion() async throws {
        try await start()
        let price = editor.inventory.items.column(Insurance.price)!.colId
        for bad: SQLValue in [.real(-1), .real(1249.999), .real(1_000_000.01), .text("450")] {
            let outcome = try await editor.apply(.set(table: "Inventory", row: 3, colId: price, value: bad))
            XCTAssertEqual(outcome, .refused(InventoryWords.badPrice), "\(bad)")
        }
        let outcome = try await editor.apply(.set(table: "Inventory", row: 3, colId: price, value: .real(1249.99)))
        guard case .done = outcome else { return XCTFail("\(outcome)") }
        // The price is checked in its row, long numbers allowed, so a cash note and its amount are read together.
        let row = try XCTUnwrap(check.asked.last)
        XCTAssertEqual(row.place, "Inventory row 3")
        XCTAssertTrue(row.cells.contains(CheckCell(label: Insurance.price, text: "1249.99", longNumbersOK: true)))
    }

    func testThePhonesNeverSeeOrChangeTheRecord() async throws {
        try await start()
        let inventory = editor.inventory
        let price = inventory.items.column(Insurance.price)!.colId
        let purchased = inventory.items.column(Insurance.purchased)!.colId
        _ = try await editor.apply(.set(table: "Inventory", row: 3, colId: price, value: .real(450)))
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertFalse(copy.columns.contains { [price, purchased].contains($0.colId) })
        XCTAssertFalse(copy.items.contains { $0.values[price] != nil || $0.values[purchased] != nil })
        for change: InventoryChange in [
            .set(table: "Inventory", row: 3, colId: price, value: .real(1)),
            .add(table: "Inventory", values: [purchased: .real(0)]),
            .startInsurance, .addPhoto(row: 3, jpeg: Data()), .removePhoto(id: 1, row: 3),
            .putBackPhoto(id: 1, row: 3, added: "", jpeg: Data()),
        ] {
            XCTAssertEqual(PhoneRules.refusal(change, editor.inventory), PhoneRules.notFromAPhone, "\(change)")
        }
    }

    /// Step 6, part 1 (owner, 2026-10-17: serial numbers aren't ID numbers, and recalls and insurance need them): a
    /// serial is kept on the Mac, read by the ID check with long numbers allowed (an ID number's shape still refused),
    /// never in a phone's copy or changed by a phone, and shown beside its item's recall.
    func testASerialIsKeptOnTheMacOnly() async throws {
        try await start()
        let serial = editor.inventory.items.column(Insurance.serial)!.colId
        let made = "SAMPLE-ZX4410B-0099887766"  // made up
        let outcome = try await editor.apply(.set(table: "Inventory", row: 3, colId: serial, value: .text(made)))
        guard case .done = outcome else { return XCTFail("\(outcome)") }
        let row = try XCTUnwrap(check.asked.last)
        XCTAssertTrue(row.cells.contains(CheckCell(label: Insurance.serial, text: made, longNumbersOK: true)))
        XCTAssertTrue(editor.inventory.macOnlyColumns.contains(serial))
        XCTAssertEqual(editor.inventory.items(in: .insured).map(\.id), [3], "a serial alone puts it in the record")
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertFalse(copy.columns.contains { $0.colId == serial })
        let sent = String(decoding: try JSONEncoder().encode(copy), as: UTF8.self)
        XCTAssertFalse(sent.contains("ZX4410B-0099887766"), "no phone copy holds a serial")
        for change: InventoryChange in [.set(table: "Inventory", row: 3, colId: serial, value: .text("SAMPLE-1")),
                                        .add(table: "Inventory", values: [serial: .text("SAMPLE-2")])] {
            XCTAssertEqual(PhoneRules.refusal(change, editor.inventory), PhoneRules.notFromAPhone, "\(change)")
        }
        let item = editor.inventory.name(ofItem: try XCTUnwrap(editor.inventory.itemRows.first { $0.id == 3 }))
        let recall = ListRow(pos: 0, cells: ["Item": .text(item), "ID": .text("R-1")])
        XCTAssertEqual(RecallList.serials(recall, in: editor.inventory), [made])
        let macOnly = ListRow(pos: 0, cells: ["Item": .text("Mac-only item, inventory row 3"), "ID": .text("R-2")])
        XCTAssertEqual(RecallList.serials(macOnly, in: editor.inventory), [made])
        XCTAssertEqual(RecallList.serialLine([made]), "Serial number: \(made)")
        XCTAssertEqual(RecallList.serialLine(["A1", "B2"]), "Serial numbers: A1, B2")
        XCTAssertNil(RecallList.serialLine([]))
        XCTAssertEqual(RecallList.serials(ListRow(pos: 0, cells: ["Item": .text("Nothing of ours")]), in: editor.inventory),
                       [])
        // A Mac-only row names the item's place in the list, which moves up when a row above it is deleted (review)
        let first = try XCTUnwrap(editor.inventory.itemRows.first).id
        _ = try await editor.apply(.delete(table: "Inventory", row: first))
        let moved = ListRow(pos: 0, cells: ["Item": .text("Mac-only item, inventory row 2"), "ID": .text("R-3")])
        XCTAssertEqual(RecallList.serials(moved, in: editor.inventory), [made], "row id 3 is now the list's second")
    }

    /// A record started before step 6 has Purchased and Price but no Serial number: the Mac offers to add it, and
    /// starting again adds only that column.
    func testARecordStartedBeforeSerialsGetsItsColumn() async throws {
        let file = editor.file
        _ = try file.ensureColumn("Inventory", colId: "Purchased", label: Insurance.purchased, type: "Date")
        _ = try file.ensureColumn("Inventory", colId: "Price", label: Insurance.price, type: "Numeric")
        try editor.reload()
        XCTAssertTrue(editor.inventory.hasInsuranceRecord)
        XCTAssertTrue(editor.inventory.needsSerialColumn)
        try await start()
        XCTAssertFalse(editor.inventory.needsSerialColumn)
    }

    /// An owner's own column stored as "Serial" under another label doesn't stop the record (its column gets a free
    /// stored name), and two columns labeled Serial number both stay off the phones (the review).
    func testSerialColumnsWhateverTheirStoredNames() async throws {
        _ = try editor.file.ensureColumn("Inventory", colId: "Serial", label: "Old tag", type: "Text")
        try editor.reload()
        try await start()
        let column = try XCTUnwrap(editor.inventory.items.column(Insurance.serial))
        XCTAssertEqual(column.colId, "Serial_2")
        _ = try editor.file.ensureColumn("Inventory", colId: "SerialNumber", label: "Other", type: "Text")
        try editor.file.db.execute("UPDATE _grist_Tables_column SET label = ? WHERE colId = ?",
                                   [.text("serial number "), .text("SerialNumber")])
        try editor.reload()
        XCTAssertTrue(editor.inventory.macOnlyColumns.isSuperset(of: ["Serial_2", "SerialNumber"]))
    }

    /// Two columns labeled Mac only (an old Grist file's, say): a row ticked in either stays off the phones, and both
    /// columns do too (the audit, 2026-10-22, finding 2: a doubled label had sent every Private row).
    func testTwoMacOnlyColumnsBothKeepARowOffThePhones() throws {
        let first = try XCTUnwrap(editor.inventory.items.column(Inventory.Label.privateRow)).colId
        _ = try editor.file.ensureColumn("Inventory", colId: "MacOnly2", label: "Other", type: "Bool")
        try editor.file.db.execute("UPDATE _grist_Tables_column SET label = ? WHERE colId = ?",
                                   [.text("mac only "), .text("MacOnly2")])
        try editor.file.db.execute("UPDATE Inventory SET \(first) = 0, MacOnly2 = 0")
        try editor.file.db.execute("UPDATE Inventory SET MacOnly2 = 1 WHERE id = 3")
        try editor.reload()
        let inventory = editor.inventory
        XCTAssertNil(inventory.items.column(Inventory.Label.privateRow), "the doubled label")
        XCTAssertTrue(inventory.isPrivate(try XCTUnwrap(inventory.itemRows.first { $0.id == 3 })))
        XCTAssertTrue(inventory.macOnlyColumns.isSuperset(of: [first, "MacOnly2"]))
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        XCTAssertFalse(copy.items.contains { $0.id == 3 })
        XCTAssertFalse(copy.columns.contains { [first, "MacOnly2"].contains($0.colId) })
    }

    func testAPhotoIsReadCheckedKeptAndUndone() async throws {
        let jpeg = Self.photo(["LANTERN 400"])
        let outcome = try await editor.apply(.addPhoto(row: 3, jpeg: jpeg))
        guard case .done(let undo, _) = outcome else { return XCTFail("\(outcome)") }
        let asked = try XCTUnwrap(check.asked.last)
        XCTAssertEqual(asked.place, "Inventory row 3, a photo")
        XCTAssertTrue(asked.cells[0].longNumbersOK)
        XCTAssertTrue(asked.cells[0].text.contains("LANTERN"), "the photo's text reached the check")
        let kept = try editor.file.photos(of: 3)
        XCTAssertEqual(kept.map(\.jpeg), [jpeg])

        guard case .done(let putBack, _) = try await editor.apply(undo) else { return XCTFail("not removed") }
        XCTAssertEqual(try editor.file.photos(of: 3), [])
        _ = try await editor.apply(putBack)
        XCTAssertEqual(try editor.file.photos(of: 3), kept)  // the same photo, its number and time
    }

    func testANewItemNeverShowsADeletedOnesPhotos() async throws {
        let item = editor.inventory.items.column("Item")!.colId
        guard case .done(_, let first) = try await editor.apply(.add(table: "Inventory", values: [item: .text("Saw")]))
        else { return XCTFail("not added") }
        try editor.file.addPhoto(item: first, jpeg: Self.photo(["SAW"]))
        _ = try await editor.apply(.delete(table: "Inventory", row: first))
        guard case .done(_, let second) = try await editor.apply(.add(table: "Inventory", values: [item: .text("Rope")]))
        else { return XCTFail("not added") }
        XCTAssertEqual(second, first + 1, "never the deleted saw's number (Task 1.9, 2026-10-23)")
        XCTAssertEqual(try editor.file.photos(of: second), [])
    }

    func testAnOpenDropsADeletedItemsPhotosAndCodes() async throws {
        try editor.file.addPhoto(item: 3, jpeg: Self.photo(["BOX"]))
        try editor.file.link(["4006", "3813", "3393", "1"].joined(), to: 3)
        try editor.file.addPhoto(item: 1, jpeg: Self.photo(["KEEP"]))
        _ = try await editor.apply(.delete(table: "Inventory", row: 3))
        XCTAssertEqual(try editor.file.photos(of: 3).count, 1, "kept while Undo could bring the item back")
        let reopened = try InventoryEditor(file: editor.file, checker: check)
        XCTAssertEqual(try reopened.file.photos(of: 3), [])
        XCTAssertEqual(try reopened.file.barcodes(), [:])
        XCTAssertEqual(try reopened.file.photos(of: 1).count, 1)
    }

    func testAPhotoIsRemovedOnlyFromItsOwnItem() async throws {
        let id = try editor.file.addPhoto(item: 3, jpeg: Self.photo(["BOX"]))
        let wrong = try await editor.apply(.removePhoto(id: id, row: 1))
        XCTAssertEqual(wrong, .refused(InventoryWords.changedSince))
        XCTAssertEqual(try editor.file.photos(of: 3).count, 1)
    }

    func testAPhotoTheCheckRefusesIsNeverKept() async throws {
        let outcome = try await editor.apply(.addPhoto(row: 3, jpeg: Self.photo(["REFUSE"])))
        guard case .refused = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try editor.file.photos(of: 3), [])
    }

    func testOnlyAJPEGIsKeptAndAnItemKeepsAtMostTwelve() async throws {
        let notAPhoto = try await editor.apply(.addPhoto(row: 3, jpeg: Data("not a photo".utf8)))
        XCTAssertEqual(notAPhoto, .refused(InventoryWords.notAPhoto))
        let jpeg = Self.photo(["BOX"])
        for _ in 0..<Insurance.photosPerItem { try editor.file.addPhoto(item: 3, jpeg: jpeg) }
        let thirteenth = try await editor.apply(.addPhoto(row: 3, jpeg: jpeg))
        XCTAssertEqual(thirteenth, .refused(InventoryWords.tooManyPhotos))
        let nowhere = try await editor.apply(.addPhoto(row: 99, jpeg: jpeg))
        XCTAssertEqual(nowhere, .refused(InventoryWords.noRow))
    }

    /// The real check, end to end: the record's columns leave the file readable by the lists job, and a photo showing
    /// an ID number's shape is refused without the number in the answer.
    func testTheRealCheck() async throws {
        guard let python = PythonTextCheck.venvPython(),
              FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("no venv") }
        let real = try InventoryEditor(file: editor.file, checker: PythonTextCheck(python: python,
                                                                                   code: InventoryTests.repo))
        guard case .done = try await real.apply(.startInsurance) else { return XCTFail("not started") }
        let price = real.inventory.items.column(Insurance.price)!.colId
        let purchased = real.inventory.items.column(Insurance.purchased)!.colId
        guard case .done = try await real.apply(.set(table: "Inventory", row: 3, colId: price, value: .real(1249.99))),
              case .done = try await real.apply(.set(table: "Inventory", row: 3, colId: purchased,
                                                     value: .real(1_760_313_600)))  // 2025-10-13
        else { return XCTFail("the record's cells were refused") }

        let made = [String(200 + 19), "0" + String(4 + 5), String(9000 + 999)].joined(separator: "-")  // made up
        let outcome = try await real.apply(.addPhoto(row: 3, jpeg: Self.photo(["SSN " + made])))
        guard case .refused(let why) = outcome else { return XCTFail("kept: \(outcome)") }
        XCTAssertTrue(why.hasPrefix("Inventory row 3, a photo, Photo text:"), "the ID check's own refusal")
        XCTAssertFalse(why.contains(made))
        XCTAssertEqual(try editor.file.photos(of: 3), [])
        // A receipt's prices are fine in a photo (owner, 2026-10-14) ...
        guard case .done = try await real.apply(.addPhoto(row: 3, jpeg: Self.photo([
            "GENERATOR 7500W", "SUBTOTAL $1,249.99", "CASH TEND 1300.00"]))) else {
            return XCTFail("a receipt was refused")
        }
        // ... while an item that is cash, with its price, is a cash amount read across the row.
        let item = real.inventory.items.column("Item")!.colId
        let cash = try await real.apply(.add(table: "Inventory", values: [item: .text("Emergency cash"),
                                                                          price: .real(2000)]))
        guard case .refused(let words) = cash else { return XCTFail("kept: \(cash)") }
        XCTAssertTrue(words.contains("cash amount"))
    }
}
