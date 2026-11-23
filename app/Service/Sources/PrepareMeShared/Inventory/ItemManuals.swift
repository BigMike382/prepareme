import CryptoKit
import Foundation
#if canImport(PDFKit) && canImport(Vision)
import CoreGraphics
import PDFKit
#endif

/// Equipment manuals (top-ten plan, phase 7): an item's manual, added on the Mac, goes to every device in its own
/// library ("PrepareMe: equipment manuals", built by the packer from the folder this keeps).
///
/// - The folder is Application Support › PrepareMe › item-manuals, written by the Mac app only: each manual whole as
///   `item-<row id>.pdf`, and `manuals.json`, `{"<row id>": {"file": …, "item": <the item's name>, "sha256": …}}`,
///   rewritten whole through a temporary name and a swap.
/// - Before a manual is copied in, every page is read (PDFKit's text; a page that is only a picture, such as a wiring
///   diagram, or that draws a large picture beside its text, read with Vision on this Mac too, as insurance photos
///   are) and goes through the lists job's ID check, page by page; a hit refuses the manual, naming the page and the
///   kind, never the text. A manual with no text at all (a scan, or words drawn as shapes) is read with Vision page by
///   page and listed with `"pictures": true`, which the packer takes as checked (owner, 2026-10-30; until then it was
///   refused, owner 2026-10-18); one in which Vision finds no words either is refused. A check that can't run keeps
///   nothing.
/// - A Private (Mac only) item gets no manual: the library reaches every phone. An item that turns Private or is
///   deleted has its manual dropped (`keep`).
/// - The packer's report sits beside the folder, never in it (so writing it never changes the volume's inputs):
///   `item-manuals-report.json`, `{"built": …, "in": {"<row id>": <sha256>}, "left_out": {"<row id>": <reason>}}`;
///   when the ID check stopped the volume, it keeps the last delivered build's `in` and `left_out` and adds
///   `"stopped": {"<row id>": "page N: <kind>"}` and `"stopped_at"` (review fixes, 2026-10-18).
/// - manuals.json is read, changed and written in one step under one lock (`listLock`), after every wait (reading
///   the PDF, Vision, the check), so an add, a remove and a `keep` never lose each other's change. A manuals.json that
///   is there but can't be read stops all three, changing nothing (`Unreadable`).
public struct ItemManuals: Sendable {
    public static let folderName = "item-manuals"
    public static let listName = "manuals.json"
    public static let reportName = "item-manuals-report.json"
    /// The manuals library (packer/volumes.toml's `prepareme-item-manuals`); its id is pinned there.
    public static let volumeID = "22a5a8ba-c510-4af3-a781-5f93fd1acddd"
    public static let volumeFile = "prepareme-item-manuals.zim"

    public static let privateItem = "A Mac-only item's manual would reach every phone."
    public static let scanned = "No words could be read on any page, even as pictures, so it can't be checked for ID "
        + "numbers. Look for another copy of the manual."
    public static let notAPDF = "That file isn't a PDF PrepareMe can read."
    public static let locked = "That PDF is locked with a password, so it can't be checked for ID numbers."
    public static let filledIn = "It has filled-in form fields or notes, which can't be checked for ID numbers. "
        + "Add a blank copy."
    public static let notOnThisDevice = "The manual comes from the Mac with the library. Downloads shows how far it "
        + "has got."

    public static func unreadablePage(_ page: Int) -> String {
        "This Mac couldn't read page \(page)'s pictures for the ID check, so the manual wasn't added."
    }

    /// A manual's file in the folder, and its path in the manuals library.
    public static func contentPath(itemID: Int64) -> String { "item-\(itemID).pdf" }

    public struct Entry: Codable, Equatable, Sendable {
        public let file: String
        public let item: String
        public let sha256: String
        /// true when the PDF had no text and every page was read with Vision (absent otherwise)
        public let pictures: Bool?

        public init(file: String, item: String, sha256: String, pictures: Bool? = nil) {
            self.file = file
            self.item = item
            self.sha256 = sha256
            self.pictures = pictures
        }
    }

    /// A manual that wasn't added, in fixed words (never the text it found).
    public struct Refused: Error, Equatable, CustomStringConvertible, Sendable {
        public let words: String
        public var description: String { words }
    }

    /// manuals.json is there but can't be read: nothing is changed, so a damaged list never becomes an empty one that
    /// the next add writes over every other manual's line (phase K finding 6). `reason` in fixed words.
    public struct Unreadable: Error, Equatable, CustomStringConvertible, Sendable {
        public let reason: String
        public var description: String {
            "The list of equipment manuals can't be read, so nothing was changed: \(reason)."
        }
        public static let cantOpen = Unreadable(reason: "the file couldn't be opened")
        public static let notTheForm = Unreadable(reason: "it isn't in the list's form")
    }

    /// Where an item's manual stands: none; added and waiting for the next library build; in the library; or left
    /// out by the packer, with its reason.
    public enum State: Equatable, Sendable {
        case none, waiting, ready
        case leftOut(String)
        /// The ID check stopped the library's last build on this manual: the report's words ("page 3: <kind>").
        case stopped(String)
    }

    /// A stopped row's line in the item form.
    public static func stoppedWords(_ found: String) -> String {
        "The library build stopped on this manual (\(found)); replace or remove it."
    }

    struct Report: Decodable {
        let built: String?
        let included: [String: String]?
        let leftOut: [String: String]?
        let stopped: [String: String]?
        let stoppedAt: String?

        enum CodingKeys: String, CodingKey {
            case built, included = "in", leftOut = "left_out", stopped, stoppedAt = "stopped_at"
        }
    }

    /// One lock for every change to manuals.json in this app, so a read, change and write is never split.
    private static let listLock = NSLock()

    public let support: URL  // Application Support › PrepareMe
    let checker: (any TextChecking)?

    public init(support: URL, checker: (any TextChecking)? = nil) {
        self.support = support
        self.checker = checker
    }

    public var folder: URL { support.appendingPathComponent(Self.folderName, isDirectory: true) }
    var listURL: URL { folder.appendingPathComponent(Self.listName) }
    public var reportURL: URL { support.appendingPathComponent(Self.reportName) }

    /// Every manual listed, by item row id: none when the list is missing (no manual added yet); Unreadable when it is
    /// there but can't be read, or any line's key isn't a row id as `write` writes it, so a damaged list is never taken
    /// for an empty one.
    public func entries() throws -> [Int64: Entry] {
        let data: Data
        do {
            data = try Data(contentsOf: listURL)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            throw Unreadable.cantOpen
        }
        guard let found = try? JSONDecoder().decode([String: Entry].self, from: data) else { throw Unreadable.notTheForm }
        var all: [Int64: Entry] = [:]
        for (key, value) in found {
            guard let id = Int64(key), String(id) == key else { throw Unreadable.notTheForm }
            all[id] = value
        }
        return all
    }

    public func entry(itemID: Int64) -> Entry? { (try? entries())?[itemID] }

    private func write(_ entries: [Int64: Entry]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let keyed = Dictionary(uniqueKeysWithValues: entries.map { (String($0.key), $0.value) })
        try DurableFile.write(try encoder.encode(keyed), to: listURL)
    }

    /// Forget an item's manual: off the list first, then its file. An unreadable list changes nothing (Unreadable).
    public func remove(itemID: Int64) throws {
        try Self.listLock.withLock {
            var all = try entries()
            if let gone = all.removeValue(forKey: itemID) {
                try write(all)
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(gone.file))
            }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(Self.contentPath(itemID: itemID)))
        }
    }

    /// Keep only the manuals of `shared` (the items that reach the phones, by row id, with their names): a Private or
    /// deleted item's is dropped, and a renamed item's line takes its new name. Writes only when something changed; an
    /// unreadable list changes nothing (Unreadable).
    public func keep(shared: [Int64: String]) throws {
        try Self.listLock.withLock {
            let all = try entries()
            guard !all.isEmpty else { return }
            var kept: [Int64: Entry] = [:]
            for (id, entry) in all {
                guard let name = shared[id] else { continue }
                kept[id] = entry.item == name ? entry
                    : Entry(file: entry.file, item: name, sha256: entry.sha256, pictures: entry.pictures)
            }
            guard kept != all else { return }
            try write(kept)
            for (id, entry) in all where kept[id] == nil {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.file))
            }
        }
    }

    /// Where an item's manual stands against the packer's last report. A report written before the manual was last
    /// added says nothing about it yet. A stopped build names its manual until a later report or a newer file; the
    /// other rows stand on the last delivered build, so only a row `in` it with this very file is ready.
    public func state(itemID: Int64) -> State {
        guard let entry = entry(itemID: itemID) else { return .none }
        return Self.state(entry, key: String(itemID), report: report(), folder: folder)
    }

    /// The items whose manual the phones' copy names: every one listed but a left-out or stopped one (its library
    /// won't hold it). A waiting one goes, so the phone can say where it has got to.
    public func forPhones() -> Set<Int64> {
        let report = report()
        return Set(((try? entries()) ?? [:]).compactMap { id, entry in
            switch Self.state(entry, key: String(id), report: report, folder: folder) {
            case .leftOut, .stopped: nil
            default: id
            }
        })
    }

    func report() -> Report? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        return try? JSONDecoder().decode(Report.self, from: data)
    }

    static func state(_ entry: Entry, key: String, report: Report?, folder: URL) -> State {
        guard let report else { return .waiting }
        let added = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(entry.file).path))?[
            .modificationDate] as? Date
        if let found = report.stopped?[key] {
            // a file written after the stopped build is a new one; with no readable stopped_at, still shown
            let replaced = report.stoppedAt.flatMap(Self.date).flatMap { at in added.map { at < $0 } } ?? false
            if !replaced { return .stopped(found) }
        }
        if report.included?[key] == entry.sha256 { return .ready }
        if let reason = report.leftOut?[key], let built = report.built.flatMap(Self.date), let added, built >= added {
            return .leftOut(reason)
        }
        return .waiting
    }

    static func date(_ text: String) -> Date? {
        if let found = ISO8601DateFormatter().date(from: text) { return found }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    #if canImport(PDFKit) && canImport(Vision)
    /// Pages sent to the check at a time, so a long manual never meets the check's time limit in one go.
    static let pagesPerCheck = 25

    /// Check `pdf` and copy it in as the item's manual (replacing any before it); its line in manuals.json. Throws
    /// Refused (in fixed words), CheckUnavailable or Unreadable (the list), keeping nothing.
    public func add(pdf: URL, itemID: Int64, itemName: String, isPrivate: Bool) async throws -> Entry {
        guard !isPrivate else { throw Refused(words: Self.privateItem) }
        guard let checker else { throw CheckUnavailable(why: "no ID check was given") }
        _ = try entries()  // an unreadable list refuses before the check's wait (and again under the lock)
        guard let data = try? Data(contentsOf: pdf) else { throw Refused(words: Self.notAPDF) }
        let read = try await Self.contents(data)  // what is checked is what is copied: the same bytes
        // the details first (the packer reads the title), then the pages
        if !read.details.isEmpty, let refused = try await checker.check(read.details, file: nil).refusal {
            throw Refused(words: refused)
        }
        let texts = read.pages
        for start in stride(from: 0, to: texts.count, by: Self.pagesPerCheck) {
            let rows = texts[start..<min(start + Self.pagesPerCheck, texts.count)].enumerated().map { n, text in
                Self.pageRow(text, page: start + n + 1)
            }
            if let refused = try await checker.check(rows, file: nil).refusal { throw Refused(words: refused) }
        }
        // every wait is over: the copy and the list change in one step, under the list's lock
        let file = Self.contentPath(itemID: itemID)
        let entry = Entry(file: file, item: itemName, sha256: Self.sha256(data), pictures: read.pictures ? true : nil)
        try Self.listLock.withLock {
            var all = try entries()  // before anything is written: an unreadable list changes nothing
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try DurableFile.write(data, to: folder.appendingPathComponent(file))
            all[itemID] = entry
            try write(all)
        }
        return entry
    }

    /// A page's text through the ID check, as an insurance photo's is: long numbers (part and model numbers, the
    /// maker's phone line) and prices allowed, and a code's numbers too (a radio's tone and code tables read like a
    /// combination: owner, 2026-10-18); an ID number's shape and a labeled password, PIN or combination refused. Its
    /// refusal names the page only.
    static func pageRow(_ text: String, page: Int) -> CheckRow {
        CheckRow(place: "The manual, page \(page)", cells: [
            CheckCell(label: "text", text: text, longNumbersOK: true, amountsOK: true, codesOK: true)])
    }

    /// The document details the check reads, by their plain names (the packer titles the manual by its Title).
    static let detailNames: [(PDFDocumentAttribute, String)] = [
        (.titleAttribute, "title"), (.subjectAttribute, "subject"), (.authorAttribute, "author"),
        (.keywordsAttribute, "keywords"), (.creatorAttribute, "creator")]

    /// A detail's text through the same check as a page's; its refusal names the detail only.
    static func detailRow(_ text: String, name: String) -> CheckRow {
        CheckRow(place: "The manual's \(name)", cells: [
            CheckCell(label: "text", text: text, longNumbersOK: true, amountsOK: true)])
    }

    /// The details a check reads in `attributes` (keywords may come as a list), the empty ones left out.
    static func detailRows(_ attributes: [AnyHashable: Any]?) -> [CheckRow] {
        detailNames.compactMap { key, name in
            let value = attributes?[key] ?? attributes?[key.rawValue]
            let text = ((value as? [Any]).map { $0.map { "\($0)" }.joined(separator: ", ") } ?? value.map { "\($0)" } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : detailRow(text, name: name)
        }
    }

    /// Whether any page holds a filled-in form field or an annotation with note text, which no page-text reader
    /// sees (packer.pdfs.notes_in: a field's value other than Off or No, or any annotation's Contents).
    static func hasFilledInOrNotes(_ document: PDFDocument) -> Bool {
        for n in 0..<document.pageCount {
            for annotation in document.page(at: n)?.annotations ?? [] {
                if let note = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    return true
                }
                guard annotation.type == "Widget" else { continue }
                let value = annotation.value(forAnnotationKey: .widgetValue).map { "\($0)" } ?? ""
                let shown = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !shown.isEmpty, !["Off", "/Off", "No", "/No"].contains(shown) { return true }
            }
        }
        return false
    }

    struct Contents {
        let pages: [String]
        let details: [CheckRow]
        var pictures = false  // no page had text: every page is Vision's
    }

    /// Pixels from which a picture on a page that also has text is read with Vision too (a 200 by 200 picture): a
    /// photo of a rating plate or a label can carry an ID number the page's text doesn't (phase K finding 4). Smaller
    /// ones (icons, bullets) are left to the page's text.
    static let largePicture = 200 * 200

    /// Each page's text, in order: PDFKit's, with what Vision reads in the page's picture added for a page that draws
    /// a large picture (`largePicture`), or Vision's alone for a page with no text; and the document's details.
    /// With no text on any page (a scan, or words drawn as shapes), every page is Vision's. Refused when it isn't a PDF,
    /// is locked, has filled-in fields or notes, a page's pictures can't be read, or Vision finds no words on any page.
    static func contents(_ data: Data) async throws -> Contents {
        typealias Page = (text: String?, picture: Bool)
        let read = await Task.detached(priority: .userInitiated) { () -> Result<([Page], [CheckRow]), Refused> in
            guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                return .failure(Refused(words: notAPDF))
            }
            if document.isLocked { return .failure(Refused(words: locked)) }
            if hasFilledInOrNotes(document) { return .failure(Refused(words: filledIn)) }
            return .success(((0..<document.pageCount).map { n in
                let page = document.page(at: n)
                let text = page?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (text.isEmpty ? nil : text, page?.pageRef.map(hasLargePicture) ?? false)
            }, detailRows(document.documentAttributes)))
        }.value
        let (found, details) = try read.get()
        var texts: [String] = []
        for (n, page) in found.enumerated() {
            if let text = page.text, !page.picture {
                texts.append(text)
                continue
            }
            guard let image = await pageImage(data, page: n), let seen = await PhotoText.read(image: image) else {
                throw Refused(words: unreadablePage(n + 1))
            }
            texts.append([page.text, seen].compactMap { $0 }.joined(separator: "\n"))
        }
        let pictures = !found.contains(where: { $0.text != nil })
        if pictures, !texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw Refused(words: scanned)
        }
        return Contents(pages: texts, details: details, pictures: pictures)
    }

    /// Whether `page` draws an image of at least `largePicture` pixels: one in its resources (or the page tree's it
    /// inherits), or in a form's within them, a few levels down.
    static func hasLargePicture(_ page: CGPDFPage) -> Bool {
        var node = page.dictionary
        for _ in 0..<32 {  // the page, then its parents, for the nearest Resources
            guard let current = node else { return false }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources) {
                return holdsLargePicture(resources, depth: 0)
            }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        return false
    }

    static func holdsLargePicture(_ resources: CGPDFDictionaryRef?, depth: Int) -> Bool {
        var objects: CGPDFDictionaryRef?
        guard depth < 4, let resources, CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects
        else { return false }
        var large = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let info = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetName(info, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(info, "Width", &width), CGPDFDictionaryGetInteger(info, "Height", &height),
                   width > 0, height > 0, Double(width) * Double(height) >= Double(largePicture) {
                    large = true
                }
            case "Form":
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(info, "Resources", &inner), holdsLargePicture(inner, depth: depth + 1) {
                    large = true
                }
            default:
                break
            }
            return !large  // stop at the first
        }, nil)
        return large
    }

    /// A page drawn as a picture on white, about 150 dots to the inch (at most 3,000 on its long side), for Vision.
    static func pageImage(_ data: Data, page: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let document = PDFDocument(data: data), let page = document.page(at: page)?.pageRef else { return nil }
            let box = page.getBoxRect(.cropBox)
            guard box.width > 0, box.height > 0 else { return nil }
            let scale = min(150.0 / 72.0, 3000 / max(box.width, box.height))
            let width = Int(box.width * scale), height = Int(box.height * scale)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            return context.makeImage()
        }.value
    }
    #endif
}
