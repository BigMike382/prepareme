import Foundation

/// Barcodes and bin labels (plan phase 7, slice 6).
///
/// - A product's barcode is kept only when it is a real one: 8, 12, 13 or 14 digits (EAN-8, UPC-A, EAN-13, GTIN-14)
///   whose last digit is the GTIN check digit of the rest. Even then it goes through the lists job's ID check like any
///   cell (as Model does, long numbers allowed), so a code that also reads as a card number is refused, never kept as
///   a barcode. Codes live in the inventory file's own PrepareMe_Barcodes table (code → item), which no reader of the
///   lists ever reads and the library page never shows; the phones get them in their copy, without Private items.
/// - A bin's label carries a QR code of `prepareme://place/<its row id>`: nothing of the household in it, and a phone
///   that scans it (in the app, or with the Camera) opens that place.
public enum Barcode {
    public static let lengths: Set<Int> = [8, 12, 13, 14]

    /// The code in the one form it is kept in, when it is a valid GTIN (spaces and dashes a scanner or a person may add
    /// are left out); nil otherwise. One product reads the same however it was scanned (review, 2026-10-14): a UPC-A
    /// (12 digits, as a USB scanner types it) is kept as the EAN-13 the phone's camera reads (a 0 in front), a GTIN-14
    /// with a 0 in front as that EAN-13, and an 8-digit UPC-E, when it isn't a good EAN-8, as its full UPC-A.
    public static func valid(_ text: String) -> String? {
        let digits = text.filter { !$0.isWhitespace && $0 != "-" }
        guard lengths.contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              digits.contains(where: { $0 != "0" }) else { return nil }  // all 0s: a junk answer, no product
        if digits.count == 8 {
            if checks(digits) { return digits }
            return expanded(digits).flatMap { checks($0) ? "0" + $0 : nil }
        }
        guard checks(digits) else { return nil }
        if digits.count == 12 { return "0" + digits }
        if digits.count == 14, digits.first == "0" { return String(digits.dropFirst()) }
        return digits
    }

    /// Whether the last digit is the GTIN check digit of the rest.
    static func checks(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        let body = values.dropLast()
        // From the right of the body, weights 3, 1, 3, 1 …
        let sum = body.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 3 : 1) }
        return (10 - sum % 10) % 10 == values.last
    }

    /// An 8-digit UPC-E (number system 0 or 1, six digits, the full code's check digit) as its 12-digit UPC-A.
    static func expanded(_ code: String) -> String? {
        let d = code.map(String.init)
        guard d.count == 8, d[0] == "0" || d[0] == "1" else { return nil }
        let middle: String = switch d[6] {
        case "0", "1", "2": d[1] + d[2] + d[6] + "0000" + d[3] + d[4] + d[5]
        case "3": d[1] + d[2] + d[3] + "00000" + d[4] + d[5]
        case "4": d[1] + d[2] + d[3] + d[4] + "00000" + d[5]
        default: d[1] + d[2] + d[3] + d[4] + d[5] + "0000" + d[6]
        }
        return d[0] + middle + d[7]
    }

    /// A bin label's QR code: prepareme://place/<id>.
    public static let placeScheme = "prepareme"

    public static func placeURL(_ id: Int64) -> URL {
        URL(string: "\(placeScheme)://place/\(id)")!
    }

    /// The place a label's QR code names, or nil for any other text.
    public static func place(in text: String) -> Int64? {
        guard let url = URL(string: text), url.scheme == placeScheme, url.host == "place",
              url.pathComponents.count == 2, let id = Int64(url.pathComponents[1]), id > 0 else { return nil }
        return id
    }
}

extension InventoryFile {
    static let barcodesTable = "PrepareMe_Barcodes"

    public func ensureBarcodes() throws {
        guard !readOnly else { throw InventoryFileError.readOnly }
        try db.execute("CREATE TABLE IF NOT EXISTS \"\(Self.barcodesTable)\" (code TEXT PRIMARY KEY, item INTEGER NOT NULL)")
    }

    /// Every code and the item it names.
    public func barcodes() throws -> [String: Int64] {
        guard try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                            [.text(Self.barcodesTable)]).isEmpty else { return [:] }
        var found: [String: Int64] = [:]
        for row in try db.query("SELECT code, item FROM \"\(Self.barcodesTable)\"") {
            if let code = Self.text(row[0]), let item = row[1].whole { found[code] = item }
        }
        return found
    }

    /// Link a code to an item (a code names one item; linking it again moves it); the item it named before, or nil.
    @discardableResult
    public func link(_ code: String, to item: Int64) throws -> Int64? {
        try ensureBarcodes()
        return try db.transaction {
            let before = try db.query("SELECT item FROM \"\(Self.barcodesTable)\" WHERE code = ?", [.text(code)])
                .first?.first?.whole
            try db.execute("INSERT OR REPLACE INTO \"\(Self.barcodesTable)\" (code, item) VALUES (?, ?)",
                           [.text(code), .int(item)])
            return before
        }
    }

    /// Drop every code and photo tied to an item number, inside the caller's transaction: a new item takes the number
    /// of a deleted last one (max + 1), and must never open from that item's codes or show its photos.
    func forgetItem(_ item: Int64) throws {
        for table in [Self.barcodesTable, Self.photosTable] where try hasTable(table) {
            try db.execute("DELETE FROM \"\(table)\" WHERE item = ?", [.int(item)])
        }
    }

    /// Drop the codes and photos of items no longer in the file (kept while an undo could still put the item back;
    /// the editor drops them when it opens the file, as no undo outlives that). Whether any were dropped.
    @discardableResult
    public func dropLeftovers() throws -> Bool {
        guard !readOnly else { throw InventoryFileError.readOnly }
        let items = try table("Inventory")
        var dropped = false
        try db.transaction {
            for table in [Self.barcodesTable, Self.photosTable] where try hasTable(table) {
                let found = try db.query("SELECT count(*) FROM \"\(table)\" WHERE item NOT IN "
                                         + "(SELECT id FROM \(SQLite.quoted(items.tableId)))").first?.first?.whole ?? 0
                guard found > 0 else { continue }
                try db.execute("DELETE FROM \"\(table)\" WHERE item NOT IN (SELECT id FROM \(SQLite.quoted(items.tableId)))")
                dropped = true
            }
        }
        return dropped
    }

    /// Unlink a code; the item it named, or nil when it named none.
    @discardableResult
    public func unlink(_ code: String) throws -> Int64? {
        guard !readOnly else { throw InventoryFileError.readOnly }
        let found = try barcodes()[code]
        guard found != nil else { return nil }
        try db.transaction { try db.execute("DELETE FROM \"\(Self.barcodesTable)\" WHERE code = ?", [.text(code)]) }
        return found
    }
}
