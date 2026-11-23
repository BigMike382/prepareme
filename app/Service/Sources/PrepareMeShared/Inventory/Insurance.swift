import Foundation
#if canImport(Vision)
import ImageIO
import Vision
#endif

/// The insurance record (plan phase 7, slice 7), on the Mac only: a purchase date, a price and photos for the items
/// worth a claim.
///
/// - Purchased (a date) and Price (a number: dollars and cents, no $, up to 1,000,000; owner, 2026-10-13) are Inventory
///   columns the app adds on the owner's first use. With the Mac only tick they are the Mac only columns: never in the
///   phones' copy, never changed by a phone. The lists job reads neither, so the library page never shows them.
/// - Serial number (text; step 6, part 1, owner 2026-10-17: "Serial numbers are not ID numbers and are required for
///   recalls, insurance etc.") is a third Mac only column, added with the others (or alone to a record started before
///   it). The ID check reads it with long numbers allowed, as Model and Price; an ID number's shape is still refused.
/// - Photos live in the file's own PrepareMe_Photos table (JPEG, made small by the app), so they go into the nightly
///   backups with the rest of the file and never anywhere else. The lists job never reads that table.
/// - A photo's text is read on the Mac (Vision, no network) and goes through the same ID check as a cell, so a photo is
///   refused for anything a cell would be (an ID number's shape, a labeled account, code or PIN), except a dollar
///   amount: a receipt's prices are the record's proof (owner, 2026-10-14). With no text reader the photo is refused,
///   never kept unchecked. Vision misses small or slanted print, so this check is weaker than a typed cell's.
public enum Insurance {
    public static let purchased = "Purchased", price = "Price", serial = "Serial number"
    public static let largestPrice = 1_000_000.0
    public static let photosPerItem = 12
    public static let largestPhoto = 3_000_000  // bytes of JPEG; the app makes them far smaller (PrepareMeInsurance)
    public static let allPhotos = 300_000_000  // bytes of every photo together: 14 nightly backups each carry them

    /// A Price the record keeps: blank, or 0 to 1,000,000 in whole cents.
    public static func goodPrice(_ value: SQLValue) -> Bool {
        let found: Double
        switch value {
        case .null: return true
        case .int(let whole): found = Double(whole)
        case .real(let number): found = number
        default: return false
        }
        return found >= 0 && found <= largestPrice && abs(found * 100 - (found * 100).rounded()) < 1e-6
    }
}

extension InventoryWords {
    public static let badPrice = "Price: dollars and cents (like 1249.99), up to 1,000,000, with no $ sign."
    public static let tooManyPhotos = "An item keeps at most 12 photos; remove one first."
    public static let photosFull = "The photos have reached 300 MB together, the most the backups carry; remove some first."
    public static let notAPhoto = "That isn't a photo the record can keep (a JPEG under 3 MB)."
    public static let unreadablePhoto = "This Mac couldn't read the photo's text for the ID check, so it wasn't kept."
}

extension Inventory {
    /// The labels of the columns no phone ever sees or changes: Mac only (Private), Purchased, Price and Serial number.
    /// One list for every gate: the phones' copy leaves these columns out and the backup refuses a copy carrying one.
    public static let macOnlyLabels = [Label.privateRow, Insurance.purchased, Insurance.price, Insurance.serial]

    /// The columns labeled `macOnlyLabels`. Every column with one of those labels counts, not only a single one, so two
    /// of a name never send a serial, a price or a Mac only tick to a phone (the audit, 2026-10-22, 2).
    public var macOnlyColumns: Set<String> {
        Set(items.columns.filter { column in Self.macOnlyLabels.contains { InventoryFile.same(column.label, $0) } }
            .map(\.colId))
    }

    /// Whether a record started before serial numbers (step 6) still lacks its Serial number column.
    public var needsSerialColumn: Bool { hasInsuranceRecord && items.column(Insurance.serial) == nil }

    /// Every item's Price together (the insurance record's total).
    public var insuredTotal: Double {
        guard let column = items.column(Insurance.price) else { return 0 }
        return itemRows.reduce(0) { $0 + ($1[column].number ?? 0) }
    }

    /// Whether the insurance record has been started (both its columns are there).
    public var hasInsuranceRecord: Bool {
        items.column(Insurance.purchased) != nil && items.column(Insurance.price) != nil
    }

    /// The Price cells of `values` that aren't dollars and cents in range; nil when all are good.
    func priceProblem(_ tableName: String, _ values: [String: SQLValue]) -> String? {
        guard tableName == "Inventory", let column = items.column(Insurance.price), let value = values[column.colId],
              !Insurance.goodPrice(value) else { return nil }
        return InventoryWords.badPrice
    }
}

public struct InventoryPhoto: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let item: Int64
    public let added: String  // ISO 8601
    public let jpeg: Data
}

extension InventoryFile {
    static let photosTable = "PrepareMe_Photos"

    private func hasPhotos() throws -> Bool {
        try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(Self.photosTable)])
            .isEmpty
    }

    /// An item's photos, oldest first.
    public func photos(of item: Int64) throws -> [InventoryPhoto] {
        guard try hasPhotos() else { return [] }
        return try db.query("SELECT id, item, added, jpeg FROM \"\(Self.photosTable)\" WHERE item = ? ORDER BY id",
                            [.int(item)]).compactMap(Self.photo)
    }

    /// Each item's photo count, and every photo's bytes together.
    public func photoCounts() throws -> (byItem: [Int64: Int], bytes: Int) {
        guard try hasPhotos() else { return ([:], 0) }
        var counts: [Int64: Int] = [:]
        for row in try db.query("SELECT item, count(*) FROM \"\(Self.photosTable)\" GROUP BY item") {
            if let item = row[0].whole, let count = row[1].whole { counts[item] = Int(count) }
        }
        let bytes = try db.query("SELECT coalesce(sum(length(jpeg)), 0) FROM \"\(Self.photosTable)\"")
            .first?.first?.whole ?? 0
        return (counts, Int(bytes))
    }

    /// Keep a photo (at `id` when one is put back); its id.
    @discardableResult
    public func addPhoto(item: Int64, jpeg: Data, id: Int64? = nil, added: String? = nil) throws -> Int64 {
        guard !readOnly else { throw InventoryFileError.readOnly }
        return try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS "\(Self.photosTable)" (id INTEGER PRIMARY KEY, item INTEGER NOT NULL, \
                added TEXT NOT NULL, jpeg BLOB NOT NULL)
                """)
            let last = try db.query("SELECT max(id) FROM \"\(Self.photosTable)\"").first?.first?.whole ?? 0
            let next = id ?? last + 1
            try db.execute("INSERT INTO \"\(Self.photosTable)\" (id, item, added, jpeg) VALUES (?, ?, ?, ?)",
                           [.int(next), .int(item), .text(added ?? ISO8601DateFormatter().string(from: Date())),
                            .blob(jpeg)])
            return next
        }
    }

    /// One photo by its id, whatever item it belongs to.
    public func photo(_ id: Int64) throws -> InventoryPhoto? {
        guard try hasPhotos() else { return nil }
        return try db.query("SELECT id, item, added, jpeg FROM \"\(Self.photosTable)\" WHERE id = ?", [.int(id)])
            .first.flatMap(Self.photo)
    }

    /// Remove a photo; what it was, or nil when there was none.
    @discardableResult
    public func removePhoto(_ id: Int64) throws -> InventoryPhoto? {
        guard !readOnly else { throw InventoryFileError.readOnly }
        guard try hasPhotos(), let found = try db.query(
            "SELECT id, item, added, jpeg FROM \"\(Self.photosTable)\" WHERE id = ?", [.int(id)]).first.flatMap(Self.photo)
        else { return nil }
        try db.transaction { try db.execute("DELETE FROM \"\(Self.photosTable)\" WHERE id = ?", [.int(id)]) }
        return found
    }

    /// Add the record's columns to Inventory (each only if missing); whether any was added.
    @discardableResult
    public func startInsuranceRecord() throws -> Bool {
        let date = try ensureColumn("Inventory", colId: "Purchased", label: Insurance.purchased, type: "Date")
        let price = try ensureColumn("Inventory", colId: "Price", label: Insurance.price, type: "Numeric",
                                     widgetOptions: #"{"decimals":2,"maxDecimals":2}"#)
        let serial = try ensureColumn("Inventory", colId: "Serial", label: Insurance.serial, type: "Text")
        return date || price || serial
    }

    private static func photo(_ row: [SQLValue]) -> InventoryPhoto? {
        guard let id = row[0].whole, let item = row[1].whole, case .text(let added) = row[2],
              case .blob(let jpeg) = row[3] else { return nil }
        return InventoryPhoto(id: id, item: item, added: added, jpeg: jpeg)
    }
}

/// A photo's text, read on this Mac with no network, for the ID check.
public enum PhotoText {
    /// Whether `data` is a JPEG of the size the record keeps.
    public static func isJPEG(_ data: Data) -> Bool {
        data.count > 4 && data.count <= Insurance.largestPhoto && data.prefix(3) == Data([0xFF, 0xD8, 0xFF])
    }

    /// Every line of text Vision finds, top to bottom; nil when it can't read the photo.
    public static func read(_ jpeg: Data) async -> String? {
        #if canImport(Vision)
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return await read(image: image)
        #else
        return nil
        #endif
    }

    #if canImport(Vision)
    /// Every line of text Vision finds in a picture, top to bottom; nil when it can't read it. Also reads a manual's
    /// picture-only pages (ItemManuals).
    public static func read(image: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false  // digits as printed, not "corrected" into words
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return nil
            }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
    #endif
}
