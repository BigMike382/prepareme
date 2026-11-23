import CryptoKit
import Foundation

/// The insurance move (Essential Documents plan, phase 2; the owner's rulings of 2026-10-24): every photo of the
/// inventory's insurance record, byte for byte, into Insurance › Insurance record, a folder for each item, with the
/// insurance PDF beside them as "Insurance record" (its first pages are the list and the total).
///
/// - The inventory file is only read, never written: the old place keeps working, and Purchased, Price and Serial
///   number stay on their items (the Recalls list reads the serials). The move finishes, the photos taken out of the
///   inventory, only after phase 4's restore test passes: nothing here takes anything out.
/// - Run again on every unlock, it brings in only what's new: each photo, item folder, the record's folder and the PDF
///   is remembered in the index by its own key, so one deleted in Essential Documents is never brought back (ruling C).
///   A newer PDF replaces the copy's contents.
/// - Its report holds counts, item numbers and fingerprints, never a name or a value.
public enum InsuranceMove {
    public static let topFolder = "Insurance", recordFolder = "Insurance record", pdfName = "Insurance record"

    public struct Item: Sendable {
        public let id: Int64
        public let name: String
        public let photos: [InventoryPhoto]
    }

    /// What the inventory holds: the items with a record or photos, their photos oldest first, the insurance PDF, and
    /// one fingerprint over every Purchased, Price and Serial number value.
    public struct Source: Sendable {
        public let started: Bool  // the record has been started (its columns are there)
        public let items: [Item]
        public let pdf: Data?
        public let fields: String
    }

    public static func source(_ file: InventoryFile, pdf: Data?) throws -> Source {
        let inventory = try Inventory(file: file)
        let counts = try file.photoCounts().byItem
        let insured = Set(inventory.items(in: .insured).map(\.id))
        let items = try inventory.itemRows.filter { insured.contains($0.id) || counts[$0.id] != nil }
            .sorted { $0.id < $1.id }
            .map { Item(id: $0.id, name: inventory.name(ofItem: $0), photos: try file.photos(of: $0.id)) }
        return Source(started: inventory.hasInsuranceRecord, items: items, pdf: pdf, fields: fields(inventory))
    }

    /// One SHA-256 over every item's Purchased, Price and Serial number, by item number: the same before and after
    /// shows the move changed none of them.
    static func fields(_ inventory: Inventory) -> String {
        let columns = [Insurance.purchased, Insurance.price, Insurance.serial].map { inventory.items.column($0) }
        var hash = SHA256()
        for row in inventory.itemRows.sorted(by: { $0.id < $1.id }) {
            let values = columns.map { column in column.map { row[$0] } ?? .null }
            guard values.contains(where: { $0 != .null }) else { continue }
            hash.update(data: Data("\(row.id)\t\(values.map(spelled).joined(separator: "\t"))\n".utf8))
        }
        return Hex.string(hash.finalize())
    }

    private static func spelled(_ value: SQLValue) -> String {
        switch value {
        case .null: ""
        case .int(let number): "i\(number)"
        case .real(let number): "r\(number)"
        case .text(let text): "t\(text)"
        case .blob(let data): "b" + Hex.string(SHA256.hash(data: data))
        }
    }

    static func photoKey(_ id: Int64) -> String { "photo:\(id)" }
    static func itemKey(_ id: Int64) -> String { "item:\(id)" }
    public static let recordKey = "record"
    static let pdfKey = "pdf"

    public struct Brought: Equatable, Sendable {
        public var photos = 0, folders = 0, refused = 0
        public var pdf = false  // added or replaced
        public var recordDeleted = false  // the Insurance record folder was deleted here: nothing more is brought in
        public var changed: Bool { photos > 0 || folders > 0 || pdf }

        public init(photos: Int = 0, folders: Int = 0, refused: Int = 0, pdf: Bool = false, recordDeleted: Bool = false) {
            self.photos = photos
            self.folders = folders
            self.refused = refused
            self.pdf = pdf
            self.recordDeleted = recordDeleted
        }
    }

    /// Brings in what isn't here yet. The index isn't saved here: the caller saves it, then removes `oldFiles`.
    public static func bring(_ source: Source, store: DocumentStore, index: inout DocumentIndex, now: Date = Date())
        -> (brought: Brought, oldFiles: [String]) {
        var brought = Brought(), oldFiles: [String] = []
        var keys = index.brought ?? [:]
        defer { index.brought = keys }
        func live(_ id: UUID?) -> Bool { index.folder(id) != nil && !index.isDeleted(folder: id) }

        let record: UUID
        if let known = keys[recordKey] {
            guard live(known) else {
                brought.recordDeleted = true
                return (brought, oldFiles)
            }
            record = known
        } else {
            let before = index.folders.count
            record = index.newFolder(recordFolder, in: index.newFolder(topFolder, in: nil, now: now), now: now)
            brought.folders += index.folders.count - before
            keys[recordKey] = record
        }

        if let pdf = source.pdf {
            let sha = Hex.string(SHA256.hash(data: pdf))
            if let known = keys[pdfKey] {
                if let doc = index.documents.first(where: { $0.id == known }), !index.isDeleted(doc), doc.sha256 != sha {
                    if let old = try? store.replace(known, with: pdf, in: &index) {
                        oldFiles.append(old)
                        brought.pdf = true
                    } else {
                        brought.refused += 1
                    }
                }
            } else if let doc = try? store.add(pdf, named: pdfName, type: "pdf", to: record, in: &index, now: now) {
                keys[pdfKey] = doc.id
                brought.pdf = true
            } else {
                brought.refused += 1
            }
        }

        for item in source.items where !item.photos.isEmpty {
            let folder: UUID
            if let known = keys[itemKey(item.id)] {
                guard live(known) else { continue }
                folder = known
            } else {
                let base = item.name.isEmpty ? "Item \(item.id)" : item.name
                let taken = Set(index.folders(in: record).map(\.name))
                var name = base, number = 1
                while taken.contains(name) {
                    number += 1
                    name = "\(base) (\(number))"
                }
                folder = index.newFolder(name, in: record, now: now)
                brought.folders += 1
                keys[itemKey(item.id)] = folder
            }
            for photo in item.photos where keys[photoKey(photo.id)] == nil {
                let taken = Set(index.documents.filter { $0.folder == folder }.map(\.name))
                let name = (1...).lazy.map { "Photo \($0)" }.first { !taken.contains($0) }!
                if let doc = try? store.add(photo.jpeg, named: name, type: "jpg", to: folder, in: &index, now: now) {
                    keys[photoKey(photo.id)] = doc.id
                    brought.photos += 1
                } else {
                    brought.refused += 1
                }
            }
        }
        return (brought, oldFiles)
    }

    /// One thing in the inventory and its copy here: the copy's fingerprint read back from the stored file, nil when
    /// there's no copy, `deleted` when it was deleted here.
    public struct Pair: Equatable, Sendable {
        public let what: String
        public let inventory: String
        public let documents: String?
        public let deleted: Bool
        public var matches: Bool { documents == inventory }
    }

    public struct Report: Equatable, Sendable {
        public var started = false
        public var items = 0
        public var photosByItem: [(item: Int64, count: Int)] = []
        public var pairs: [Pair] = []
        public var fieldsBefore = "", fieldsAfter = ""
        public var recordDeleted = false
        public var everyPairMatches: Bool { !pairs.isEmpty && pairs.allSatisfy(\.matches) && fieldsBefore == fieldsAfter }

        public static func == (a: Report, b: Report) -> Bool {
            a.started == b.started && a.items == b.items && a.pairs == b.pairs && a.fieldsBefore == b.fieldsBefore
                && a.fieldsAfter == b.fieldsAfter && a.recordDeleted == b.recordDeleted
                && a.photosByItem.map(\.item) == b.photosByItem.map(\.item)
                && a.photosByItem.map(\.count) == b.photosByItem.map(\.count)
        }
    }

    /// Every photo and the PDF against its copy, each copy decrypted and fingerprinted again; `after` is the
    /// inventory read again once the move is done, for the fields' fingerprint.
    public static func report(_ source: Source, after: Source, store: DocumentStore, index: DocumentIndex) -> Report {
        var report = Report(started: source.started, items: source.items.count, fieldsBefore: source.fields,
                            fieldsAfter: after.fields)
        let keys = index.brought ?? [:]
        report.recordDeleted = keys[recordKey].map { index.folder($0) == nil || index.isDeleted(folder: $0) } ?? false
        func pair(_ what: String, _ data: Data, _ key: String) -> Pair {
            let doc = keys[key].flatMap { id in index.documents.first { $0.id == id } }
            let copy = doc.flatMap { index.isDeleted($0) ? nil : try? store.data(of: $0) }
                .map { Hex.string(SHA256.hash(data: $0)) }
            return Pair(what: what, inventory: Hex.string(SHA256.hash(data: data)), documents: copy,
                        deleted: doc.map(index.isDeleted) ?? (keys[key] != nil))
        }
        for item in source.items where !item.photos.isEmpty {
            report.photosByItem.append((item.id, item.photos.count))
            for (n, photo) in item.photos.enumerated() {
                report.pairs.append(pair("Item \(item.id), photo \(n + 1)", photo.jpeg, photoKey(photo.id)))
            }
        }
        if let pdf = source.pdf { report.pairs.append(pair("Insurance PDF", pdf, pdfKey)) }
        return report
    }

    /// The report as the owner reads it: counts, item numbers and fingerprints only.
    public static func lines(_ report: Report) -> [String] {
        guard report.started || !report.pairs.isEmpty else { return [DocumentsWords.noInsuranceRecord] }
        let bad = report.pairs.filter { !$0.matches }.count
        var lines = [report.everyPairMatches
            ? "Every pair matches: the insurance record is in Essential Documents."
            : "Not moved: \(bad) of \(report.pairs.count) pairs don't match."]
        if report.recordDeleted {
            lines.append("The Insurance record folder was deleted here, so nothing more is brought in.")
        }
        let photos = report.photosByItem.reduce(0) { $0 + $1.count }
        lines.append("Items with a record or photos: \(report.items)")
        lines.append("Photos: \(photos) in all"
                     + (report.photosByItem.isEmpty ? "" : "; by item: "
                        + report.photosByItem.map { "item \($0.item) \($0.count)" }.joined(separator: ", ")))
        // each fingerprint whole on a line of its own, so two can be compared by eye
        for pair in report.pairs {
            let why = pair.documents == nil ? (pair.deleted ? " (deleted here)" : " (no copy)") : ""
            lines.append("\(pair.what): " + (pair.matches ? "match" : "NO MATCH\(why)"))
            lines.append("  inventory            \(pair.inventory)")
            lines.append("  Essential Documents  \(pair.documents ?? "-")")
        }
        lines.append("Purchased, Price and Serial number: "
                     + (report.fieldsBefore == report.fieldsAfter ? "unchanged" : "CHANGED"))
        lines.append("  before               \(report.fieldsBefore)")
        lines.append("  after                \(report.fieldsAfter)")
        return lines
    }
}
