import AppKit
import CryptoKit
import Foundation
import ImageIO
@testable import PrepareMeServer
import PrepareMeShared
import UniformTypeIdentifiers
import XCTest

/// Essential Documents' evidence (phase 5): made-up documents of every type PrepareMe keeps, in their real formats,
/// through the whole road: Add Folder of Documents… on the Mac, the key handed to an adult's phone and the store mirrored to it
/// over the service's own routes, the phone's own adds back to the Mac, the iCloud copy and the drive's copy, and a
/// new Mac opening each copy with the recovery password alone. Every document's SHA-256 is matched against the
/// original file's at each stop. Fresh temporary folders, never a real document.
final class DocumentsEvidenceTests: XCTestCase {
    var root: URL!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-documents-evidence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Made-up documents, one of every type, in their own formats

    func image(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in stride(from: 0, to: width, by: 8) {  // stripes, so no two formats compress alike
            context.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 8, height: height))
        }
        return context.makeImage()!
    }

    func writeImage(_ url: URL, _ type: UTType, width: Int = 600, height: Int = 400) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image(width, height), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), url.lastPathComponent)
    }

    func writePDF(_ url: URL, title: String, pages: Int) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            let line = NSAttributedString(string: "\(title), page \(page) of \(pages). FAKE SAMPLE: made up for a check.",
                                          attributes: [.font: NSFont.systemFont(ofSize: 18)])
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    func writeText(_ url: URL, as type: NSAttributedString.DocumentType) throws {
        let text = NSAttributedString(string: "FAKE SAMPLE \(url.lastPathComponent): made up for a check.\n")
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            .write(to: url)
    }

    /// The spreadsheet and iWork types: zip archives PrepareMe keeps as bytes (it never reads inside one).
    func writeArchive(_ url: URL, seed: UInt8) throws {
        var data = Data([0x50, 0x4B, 0x03, 0x04])
        data.append(contentsOf: (0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ Int(seed)) })
        try data.write(to: url)
    }

    /// The made-up folder the owner would pick in Add Folder of Documents…: every extension `DocumentTypes` keeps, in folders two
    /// deep, one photo big enough to span several encrypted pieces. Returns each file's path inside it and SHA-256.
    func makeDocuments() throws -> (folder: URL, originals: [String: String]) {
        let folder = root.appendingPathComponent("fake-documents").resolvingSymlinksInPath()
        let ids = folder.appendingPathComponent("IDs (FAKE)"), auto = folder.appendingPathComponent("Insurance (FAKE)/Auto")
        for dir in [ids, auto, folder.appendingPathComponent("Money (FAKE)")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func at(_ path: String) -> URL { folder.appendingPathComponent(path) }
        writePDF(at("Deed (FAKE).pdf"), title: "Deed", pages: 3)
        writePDF(at("Insurance (FAKE)/Auto/Insurance cards (FAKE).pdf"), title: "Insurance card", pages: 2)
        try writeImage(at("IDs (FAKE)/Passport page (FAKE).jpg"), .jpeg)
        try writeImage(at("IDs (FAKE)/License front (FAKE).jpeg"), .jpeg, width: 500)
        try writeImage(at("IDs (FAKE)/License back (FAKE).png"), .png)
        try writeImage(at("Insurance (FAKE)/Kitchen photo (FAKE).heic"), .heic)
        // ImageIO writes HEIF only as HEIC, the same container a .heif file holds
        try writeImage(at("Insurance (FAKE)/Garage photo (FAKE).heif"), .heic, width: 640)
        try writeImage(at("Insurance (FAKE)/Scanner page (FAKE).tif"), .tiff, width: 320)
        // uncompressed, about 4.8 MB: five encrypted pieces
        let big = at("Insurance (FAKE)/Roof photo (FAKE).tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(big as CFURL, UTType.tiff.identifier as CFString,
                                                                        1, nil))
        CGImageDestinationAddImage(destination, image(1600, 1000),
                                   [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try Data("FAKE SAMPLE bank contacts: made up for a check.\n".utf8).write(to: at("Money (FAKE)/Bank contacts (FAKE).txt"))
        try writeText(at("Money (FAKE)/Will summary (FAKE).rtf"), as: .rtf)
        try writeText(at("Money (FAKE)/Letter (FAKE).doc"), as: .docFormat)
        try writeText(at("Money (FAKE)/Letter (FAKE).docx"), as: .officeOpenXML)
        for (name, seed) in [("Budget (FAKE).xls", 1), ("Budget (FAKE).xlsx", 2), ("Household plan (FAKE).pages", 3),
                             ("Supplies (FAKE).numbers", 4)] {
            try writeArchive(at("Money (FAKE)/\(name)"), seed: UInt8(seed))
        }
        var originals: [String: String] = [:]
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)!
            where DocumentTypes.kind(forExtension: url.pathExtension) != nil {
            originals[String(url.resolvingSymlinksInPath().path.dropFirst(folder.path.count + 1))] = try FileCheck.sha256(of: url)
        }
        XCTAssertEqual(Set(originals.keys.map { ($0 as NSString).pathExtension.lowercased() }), Set(DocumentTypes.extensions),
                       "one of every type")
        XCTAssertGreaterThan(try XCTUnwrap(DocumentList.size(of: big)), Int64(DocumentCipher.pieceSize * 4))
        return (folder, originals)
    }

    /// Each document's path as Add Folder of Documents… kept it ("Money (FAKE)/Letter (FAKE).docx") and its plain SHA-256, read
    /// back and decrypted from `store`.
    func fingerprints(_ store: DocumentStore) throws -> [String: String] {
        let index = try store.load()
        func path(_ folder: UUID?) -> String {
            guard let folder = index.folder(folder) else { return "" }
            return path(folder.parent) + folder.name + "/"
        }
        var found: [String: String] = [:]
        for document in index.documents where !index.isDeleted(document) {
            found[path(document.folder) + document.name + "." + document.type] = Hex.string(SHA256.hash(data: try store.data(of: document)))
        }
        return found
    }

    // MARK: The phone, over the service's routes

    func ask(_ router: Router, _ method: String, _ path: String, _ token: String, body: Data = Data()) throws -> Data {
        let reply = router.reply(to: HTTPRequest(method: method, path: path, headers: ["authorization": "Bearer " + token],
                                                 body: body), now: now).0
        switch reply {
        case let .bytes(status, _, body):
            XCTAssertLessThan(status, 300, path)
            return body
        case let .file(status, _, handle, offset, length, _):
            defer { try? handle.close() }
            XCTAssertEqual(status, 200, path)
            try handle.seek(toOffset: offset)
            return try XCTUnwrap(handle.read(upToCount: Int(length)))
        }
    }

    /// One check at home: the list, each file the phone lacks into a temporary file, checked and kept, the index last.
    func phoneCheck(_ router: Router, _ token: String, phone: URL) throws {
        let list = try DocumentList.read(ask(router, "GET", "/documents/list.json", token))
        var held = DocumentMirror.held(in: phone)
        for entry in DocumentMirror.toFetch(list, held: held, root: phone) {
            let fetched = phone.appendingPathComponent("fetching-\(UUID())")
            try ask(router, "GET", "/documents/files/\(entry.name)", token).write(to: fetched)
            try DocumentMirror.take(fetched, as: entry, root: phone, held: &held)
        }
        try DocumentMirror.finish(list, root: phone, held: &held, keep: [])
    }

    // MARK: The road

    func testEveryTypeKeepsItsFingerprintThroughImportSyncBackupAndRestore() throws {
        let (folder, originals) = try makeDocuments()
        let mac = root.appendingPathComponent("mac/documents"), pairing = root.appendingPathComponent("pairing")
        try FileManager.default.createDirectory(at: pairing, withIntermediateDirectories: true)

        // 1. The Mac: Add Folder of Documents…, every file read back against its original before it's kept
        let key = SymmetricKey(size: .bits256)
        let store = DocumentStore(root: mac, key: key)
        var index = DocumentIndex()
        let report = store.addFolder(folder, to: nil, in: &index, now: now)
        XCTAssertEqual(report.added, originals.count)
        XCTAssertTrue(report.refused.isEmpty)
        try store.save(index)
        try DocumentList.refresh(root: mac)
        XCTAssertEqual(try fingerprints(store), originals, "on the Mac")
        XCTAssertEqual(store.addFolder(folder, to: nil, in: &index, now: now).alreadyHere, originals.count, "twice: nothing new")

        // 2. An adult's phone: asks with its own lock, the owner gives it the key, it mirrors the store
        let tokens = TokenStore(url: root.appendingPathComponent("tokens.json"))
        let token = try tokens.add(now: now).token, phone = try XCTUnwrap(tokens.phone(for: token))
        let router = Router(folder: root, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                            manifestOnly: true, pairing: pairing, documents: mac)
        let lock = P256.KeyAgreement.PrivateKey()
        _ = try ask(router, "POST", "/documents/key-request", token,
                    body: JSONEncoder().encode(DocumentHandoff.Request(key: lock.publicKey.rawRepresentation)))
        let request = try XCTUnwrap(DocumentHandoff.request(
            DocumentHandoff.readRequests(try Data(contentsOf: pairing.appendingPathComponent(DocumentHandoff.requestsName))),
            label: phone.label, paired: phone.added))
        try DocumentHandoff.encoded([phone.label: DocumentHandoff.seal(key, for: request, label: phone.label,
                                                                       paired: phone.added, now: now)])
            .write(to: pairing.appendingPathComponent(DocumentHandoff.giftsName))
        let served = try JSONDecoder().decode(DocumentHandoff.Served.self, from: ask(router, "GET", "/documents/key", token))
        let phoneKey = try DocumentKeyFile(lock: Data(), ephemeral: served.ephemeral, sealed: served.sealed)
            .open { try lock.sharedSecretFromKeyAgreement(with: $0) }
        let phoneRoot = root.appendingPathComponent("phone/documents")
        try DocumentStore.prepare(phoneRoot)
        try phoneCheck(router, token, phone: phoneRoot)
        let phoneStore = DocumentStore(root: phoneRoot, key: phoneKey)
        XCTAssertEqual(try fingerprints(phoneStore), originals, "on the phone")

        // 3. The phone's own add (a scan) goes to the Mac in pieces with its outbox, and comes back to it listed
        let scan = Data((0..<(DocumentInbox.maxPiece + 999)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var phoneIndex = try phoneStore.load()
        let added = try phoneStore.add(scan, named: "Scan from the phone (FAKE)", type: "pdf", to: nil, in: &phoneIndex,
                                       now: now)
        let sealed = try Data(contentsOf: phoneRoot.appendingPathComponent("files/\(added.file)"))
        for offset in stride(from: 0, to: sealed.count, by: DocumentInbox.maxPiece) {
            _ = try ask(router, "POST", "/documents/upload/\(added.file)/\(offset)", token,
                        body: sealed.subdata(in: offset..<min(offset + DocumentInbox.maxPiece, sealed.count)))
        }
        try DocumentOutbox.write([DocumentChange(.add(document: added), at: now)], in: phoneRoot, key: phoneKey)
        _ = try ask(router, "POST", "/documents/changes", token,
                    body: Data(contentsOf: phoneRoot.appendingPathComponent(DocumentOutbox.fileName)))
        let (result, done) = DocumentInbox.apply(store: store, index: &index)
        XCTAssertEqual(result.applied, 1)
        try store.save(index)
        DocumentInbox.tidy(done, inbox: mac.appendingPathComponent(DocumentInbox.folderName))
        try DocumentList.refresh(root: mac)
        var everything = originals
        everything["Scan from the phone (FAKE).pdf"] = Hex.string(SHA256.hash(data: scan))
        XCTAssertEqual(try fingerprints(store), everything, "the phone's add on the Mac")
        try phoneCheck(router, token, phone: phoneRoot)
        XCTAssertEqual(try fingerprints(phoneStore), everything, "and the phone has the Mac's index with it")

        // 4. The backups: the recovery password's spare, the iCloud copy, and the drive's copy of the whole store
        let password = DocumentSpare.newPassword()
        try store.writeSpare(password: password)
        let iCloud = root.appendingPathComponent("Household Private/Backups/Documents")
        XCTAssertEqual(DocumentBackup.copy(from: mac, to: iCloud, list: try DocumentList.refresh(root: mac)),
                       .copied(files: everything.count, documents: everything.count))
        let drive = root.appendingPathComponent("PrepareMe USB Backup/PrepareMe/documents")
        try FileManager.default.createDirectory(at: drive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: mac, to: drive)  // the nightly image holds the store as it is

        // 5. A new Mac: each copy opened with the recovery password alone, every document read back
        for (name, copy) in [("the iCloud copy", iCloud), ("the drive's copy", drive)] {
            XCTAssertEqual(DocumentRestoreTest.run(copy: copy, password: password), .passed(documents: everything.count), name)
            let opened = try XCTUnwrap(DocumentSpare.read(in: copy)).open(password: password)
            XCTAssertEqual(try fingerprints(DocumentStore(root: copy, key: opened)), everything, name)
            XCTAssertEqual(DocumentRestoreTest.run(copy: copy, password: DocumentSpare.newPassword()), .wrongPassword, name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: iCloud.appendingPathComponent("household.key").path))
    }
}
