import CryptoKit
import Foundation
@testable import PrepareMeShared
import XCTest

/// Essential Documents' store (docs/documents.md), on fake files these tests make: never a real document.
final class DocumentStoreTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("documents-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func fake(_ name: String, bytes: Int, seed: UInt8 = 7, in sub: String = "in") throws -> URL {
        let dir = folder.appendingPathComponent(sub, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var data = Data(count: bytes)
        for i in 0..<bytes { data[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed)) }
        try data.write(to: url)
        return url
    }

    var store: DocumentStore { DocumentStore(root: folder.appendingPathComponent("documents"), key: key) }
    let key = SymmetricKey(size: .bits256)

    func testEveryTypeComesBackByteForByteWithItsFingerprint() throws {
        var index = DocumentIndex()
        for ext in DocumentTypes.extensions {
            let source = try fake("Fake \(ext.uppercased()) Sample.\(ext)", bytes: 3000 + ext.count)
            let doc = try store.add(source, to: nil, in: &index)
            XCTAssertEqual(doc.sha256, try FileCheck.sha256(of: source), ext)
            XCTAssertEqual(try store.data(of: doc), try Data(contentsOf: source), ext)
            XCTAssertEqual(doc.name, "Fake \(ext.uppercased()) Sample", "the name kept as written")
        }
        try store.save(index)
        XCTAssertEqual(try store.load(), index)
        XCTAssertEqual(store.verifyAll(index).matching, DocumentTypes.extensions.count)
    }

    func testABigFileGoesInPiecesAndEdgesOfAPieceRoundTrip() throws {
        var index = DocumentIndex()
        for size in [0, 1, DocumentCipher.pieceSize - 1, DocumentCipher.pieceSize, DocumentCipher.pieceSize * 3 + 5] {
            let source = try fake("size-\(size).pdf", bytes: size)
            let doc = try store.add(source, to: nil, in: &index)
            XCTAssertEqual(doc.size, Int64(size))
            XCTAssertEqual(try store.data(of: doc), try Data(contentsOf: source))
        }
    }

    func testNothingStoredSaysWhatItHolds() throws {
        var index = DocumentIndex()
        let source = try fake("Passport scan.pdf", bytes: 5000)
        try Data("%PDF-1.7 Passport FAKE-SAMPLE".utf8).write(to: source)
        try store.add(source, to: index.newFolder("IDs", in: nil), in: &index)
        try store.save(index)
        let names = try FileManager.default.subpathsOfDirectory(atPath: store.root.path)
        XCTAssertFalse(names.contains { $0.localizedCaseInsensitiveContains("passport") || $0.contains("IDs") })
        for name in names {
            var isDir: ObjCBool = false
            let path = store.root.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            for word in ["Passport", "PDF", "IDs", "FAKE-SAMPLE"] {
                XCTAssertNil(bytes.range(of: Data(word.utf8)), "\(name) holds \(word) in the clear")
            }
        }
        XCTAssertTrue(names.contains(".metadata_never_index"), "Spotlight told to keep out")
    }

    func testAChangedByteACutFileOrAnotherKeyRefusesToOpen() throws {
        var index = DocumentIndex()
        let doc = try store.add(try fake("a.pdf", bytes: DocumentCipher.pieceSize + 10), to: nil, in: &index)
        let stored = store.root.appendingPathComponent("files").appendingPathComponent(doc.file)
        let good = try Data(contentsOf: stored)

        var flipped = good
        flipped[flipped.count / 2] ^= 1
        try flipped.write(to: stored)
        XCTAssertThrowsError(try store.data(of: doc))

        try good.prefix(good.count - 40).write(to: stored)
        XCTAssertThrowsError(try store.data(of: doc))

        try good.write(to: stored)
        XCTAssertThrowsError(try DocumentStore(root: store.root, key: SymmetricKey(size: .bits256)).data(of: doc))
        XCTAssertEqual(try store.data(of: doc).count, DocumentCipher.pieceSize + 10, "the good copy still opens")
    }

    func testAPieceFromAnotherFileOrAFileSwappedInRefuses() throws {
        var index = DocumentIndex()
        let a = try store.add(try fake("a.pdf", bytes: 100, seed: 1), to: nil, in: &index)
        let b = try store.add(try fake("b.pdf", bytes: 100, seed: 2), to: nil, in: &index)
        let files = store.root.appendingPathComponent("files")
        let bBytes = try Data(contentsOf: files.appendingPathComponent(b.file))
        try bBytes.write(to: files.appendingPathComponent(a.file))
        XCTAssertThrowsError(try store.data(of: a), "b's file under a's name fails a's fingerprint")
    }

    func testRefusals() throws {
        var index = DocumentIndex()
        XCTAssertThrowsError(try store.add(try fake("tool.exe", bytes: 10), to: nil, in: &index)) {
            XCTAssertEqual($0 as? DocumentRefusal, .notAType)
        }
        let package = folder.appendingPathComponent("Budget.numbers", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.add(package, to: nil, in: &index)) {
            XCTAssertEqual($0 as? DocumentRefusal, .package)
        }
        XCTAssertTrue(index.documents.isEmpty)
        XCTAssertEqual(DocumentsWords.refused(.notAType), "That file isn't a type PrepareMe keeps.")
    }

    func testAddAFolderKeepsItsFoldersAndTwiceChangesNothing() throws {
        _ = try fake("Policy.pdf", bytes: 400, seed: 1, in: "pick/Insurance")
        _ = try fake("Card.png", bytes: 300, seed: 2, in: "pick/Insurance/Auto")
        _ = try fake("Deed.pdf", bytes: 500, seed: 3, in: "pick/Property")
        _ = try fake("Loose.txt", bytes: 20, seed: 4, in: "pick")
        _ = try fake("notes.exe", bytes: 20, seed: 5, in: "pick")
        _ = try fake(".DS_Store", bytes: 20, seed: 6, in: "pick")
        var index = DocumentIndex()
        let pick = folder.appendingPathComponent("pick")
        let report = store.addFolder(pick, to: nil, in: &index)
        XCTAssertEqual(report.added, 4)
        XCTAssertEqual(report.foldersMade, 3)
        XCTAssertEqual(report.refused, [.notAType: 1])
        XCTAssertEqual(index.folders(in: nil).map(\.name), ["Insurance", "Property"])
        let insurance = try XCTUnwrap(index.folders(in: nil).first)
        XCTAssertEqual(index.folders(in: insurance.id).map(\.name), ["Auto"])
        XCTAssertEqual(index.documents(in: nil).map(\.name), ["Loose"])
        XCTAssertEqual(DocumentsWords.report(report),
                       "Added 4 documents and 3 folders. 1 file isn't a type PrepareMe keeps.")

        let again = store.addFolder(pick, to: nil, in: &index)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.alreadyHere, 4)
        XCTAssertEqual(index.folders.count, 3)
        XCTAssertEqual(DocumentsWords.report(again),
                       "Added 0 documents. 4 were already here. 1 file isn't a type PrepareMe keeps.")
    }

    func testFoldersRenameMoveAndNeverIntoThemselves() {
        var index = DocumentIndex()
        let a = index.newFolder("Insurance", in: nil)
        let b = index.newFolder("Auto", in: a)
        let c = index.newFolder("Old", in: b)
        XCTAssertFalse(index.move(folder: a, to: c), "not into a folder inside it")
        XCTAssertFalse(index.move(folder: a, to: a))
        XCTAssertTrue(index.move(folder: c, to: nil))
        index.rename(folder: b, to: "Cars")
        XCTAssertEqual(index.folders(in: a).map(\.name), ["Cars"])
        XCTAssertEqual(index.folders(in: nil).map(\.name), ["Insurance", "Old"])
        XCTAssertEqual(index.newFolder("Insurance", in: nil), a, "a second folder of the same name isn't made")
    }

    func testRecentlyDeletedThirtyDaysThenGoneForGood() throws {
        var index = DocumentIndex()
        let ids = index.newFolder("IDs", in: nil)
        let inner = index.newFolder("Kids", in: ids)
        let one = try store.add(try fake("one.pdf", bytes: 10, seed: 1), to: inner, in: &index)
        let two = try store.add(try fake("two.pdf", bytes: 10, seed: 2), to: nil, in: &index)
        XCTAssertEqual(index.documentCount(inFolder: ids), 1)
        XCTAssertEqual(DocumentsWords.deleteFolderMessage(documents: 1),
                       "It and the 1 document in it go to Recently Deleted for 30 days, then they're gone for good.")

        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        index.delete(folder: ids, now: day0)
        index.delete(document: two.id, now: day0.addingTimeInterval(86_400))
        XCTAssertEqual(index.live.count, 0)
        XCTAssertEqual(index.recentlyDeleted.folders.map(\.name), ["IDs"], "Kids goes with its folder")
        XCTAssertEqual(index.recentlyDeleted.documents.map(\.id), [two.id])

        index.putBack(document: one.id)
        XCTAssertNil(index.documents.first { $0.id == one.id }?.folder, "back at the top: its folder is still deleted")
        index.delete(document: one.id, now: day0)

        XCTAssertTrue(index.purgeExpired(now: day0.addingTimeInterval(29 * 86_400)).isEmpty)
        let gone = index.purgeExpired(now: day0.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(gone, [one.file])
        XCTAssertEqual(Set(index.purged), [ids, inner, one.id], "remembered, so a restore never brings them back")
        XCTAssertEqual(index.documents.map(\.id), [two.id], "deleted a day later, it has a day left")
        store.remove(files: gone)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.root.appendingPathComponent("files").appendingPathComponent(one.file).path))
    }

    func testSendsAreRecordedInTheIndexOnly() throws {
        var index = DocumentIndex()
        let doc = try store.add(try fake("p.pdf", bytes: 10), to: nil, in: &index)
        let send = DocumentSend(date: Date(timeIntervalSince1970: 0), device: "Test Mac", how: DocumentSendWay.airDrop.rawValue)
        index.recordSend(send, for: doc.id)
        try store.save(index)
        XCTAssertEqual(try store.load().documents.first?.sends, [send])
    }

    func testScratchCopiesAreWiped() throws {
        let copy = try DocumentScratch.copy(Data("x".utf8), named: "A/B.pdf", in: folder)
        XCTAssertEqual(copy.lastPathComponent, "A-B.pdf")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int, 0o600)
        DocumentScratch.wipe(in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentScratch.folder(in: folder).path))
    }

    func testTheKeyFileOpensOnlyWithItsLock() throws {
        let lock = P256.KeyAgreement.PrivateKey()
        let household = SymmetricKey(size: .bits256)
        let file = try DocumentKeyFile.seal(household, to: lock.publicKey, lockData: Data("lock".utf8))
        let opened = try file.open { try lock.sharedSecretFromKeyAgreement(with: $0) }
        XCTAssertEqual(opened, household)
        let other = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try file.open { try other.sharedSecretFromKeyAgreement(with: $0) })
        let raw = household.withUnsafeBytes { Data($0) }
        XCTAssertNil(try JSONEncoder().encode(file).range(of: raw), "the key never in the clear")
    }

    /// The Secure Enclave's own half, without the Touch ID check (a test can't touch the sensor): this Mac's
    /// Secure Enclave seals and opens; a copy of the file on another device can't.
    func testTheSecureEnclaveSealsAndOpens() throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave here")
        let lock = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        let household = SymmetricKey(size: .bits256)
        let file = try DocumentKeyFile.seal(household, to: lock.publicKey, lockData: lock.dataRepresentation)
        let back = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: file.lock)
        XCTAssertEqual(try file.open { try back.sharedSecretFromKeyAgreement(with: $0) }, household)
    }

    /// The real lock's rule lets the key agree ("ock") once the person is present; without `.privateKeyUsage` it
    /// named no key use, and Touch ID passed while the key refused (the owner's Mac, 2026-10-25). The rule's printed
    /// form is the one the system log shows.
    func testTheLockMayAgreeOnceThePersonIsPresent() throws {
        let rule = String(describing: try DocumentKey.Lock.access())
        XCTAssertTrue(rule.contains("ock(cpo(DeviceOwnerAuthentication))"), rule)
    }

    func testIdleLockAfterTwoMinutes() {
        let then = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(DocumentsWords.shouldLock(lastActive: then, now: then.addingTimeInterval(119)))
        XCTAssertTrue(DocumentsWords.shouldLock(lastActive: then, now: then.addingTimeInterval(120)))
    }

    func testWords() {
        XCTAssertEqual(DocumentsWords.footer(count: 42), "42 documents, all on this Mac")
        XCTAssertEqual(DocumentsWords.footer(count: 1, device: "phone"), "1 document, all on this phone")
        XCTAssertEqual(DocumentsWords.unlockButton(biometry: "Touch ID"), "Unlock with Touch ID")
        XCTAssertEqual(DocumentsWords.sendTitle("Home policy", .airDrop), "Send “Home policy” by AirDrop?")
        XCTAssertEqual(MacSidebar.title(.documents), DocumentsWords.title)
        XCTAssertEqual(MacSidebar.topLevel.firstIndex(of: .documents), MacSidebar.topLevel.firstIndex(of: .inventory)! + 1,
                       "right under Inventory, never at the sidebar's foot")
    }

    /// Nothing in Essential Documents' code writes a log, so no name, page or preview can reach one (the design's
    /// "a test checks the log words").
    func testNoLogLinesInEssentialDocuments() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files = try FileManager.default.contentsOfDirectory(
            at: repo.appendingPathComponent("app/Service/Sources/PrepareMeShared/Documents"), includingPropertiesForKeys: nil)
        files += try FileManager.default.contentsOfDirectory(
            at: repo.appendingPathComponent("app/Kiwix/PrepareMeApp"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("PrepareMeDocuments") }
        XCTAssertGreaterThan(files.count, 4)
        let log = try NSRegularExpression(pattern: "(^|[^.\\w])(print|debugPrint|dump)\\(|Logger\\(|os_log|NSLog")
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(log.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                         "\(file.lastPathComponent) writes a log line")
        }
    }
}
