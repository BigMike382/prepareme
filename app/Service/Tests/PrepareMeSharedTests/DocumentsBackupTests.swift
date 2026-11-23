import CryptoKit
import Foundation
@testable import PrepareMeShared
import XCTest

/// Essential Documents' backups (phase 4): the recovery password's spare, the iCloud copy, and Test a restore. Made-up
/// documents in fresh temporary folders.
final class DocumentsBackupTests: XCTestCase {
    var folder: URL!
    var mac: URL!
    var backup: URL!
    let key = SymmetricKey(size: .bits256)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-docs-backup-\(UUID())")
        mac = folder.appendingPathComponent("mac")
        backup = folder.appendingPathComponent("Backups/Documents")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    func macStore(spare password: String? = "abcdef-ghjkmn-pqrstu-vwxyz2") throws -> (DocumentStore, DocumentIndex) {
        let store = DocumentStore(root: mac, key: key)
        var index = DocumentIndex()
        let ids = index.newFolder("IDs", in: nil, now: now)
        try store.add(Data("made-up passport".utf8), named: "Passport (FAKE)", type: "jpg", to: ids, in: &index, now: now)
        try store.add(Data(repeating: 7, count: DocumentCipher.pieceSize + 10), named: "Deed (FAKE)", type: "pdf",
                      to: nil, in: &index, now: now)
        try store.save(index)
        if let password { try DocumentSpare.make(key, password: password).write(in: mac) }
        return (store, index)
    }

    func backUp() throws -> DocumentBackup.Outcome {
        DocumentBackup.copy(from: mac, to: backup, list: try DocumentList.refresh(root: mac))
    }

    // MARK: The spare

    func testARecoveryPasswordIsTwentyFourUnmistakableLettersInGroups() {
        let password = DocumentSpare.newPassword()
        XCTAssertEqual(password.count, 27)
        XCTAssertEqual(password.split(separator: "-").map(\.count), [6, 6, 6, 6])
        XCTAssertTrue(password.replacingOccurrences(of: "-", with: "").allSatisfy(DocumentSpare.alphabet.contains))
        for confusable in "0o1li" { XCTAssertFalse(DocumentSpare.alphabet.contains(confusable)) }
        XCTAssertNotEqual(DocumentSpare.newPassword(), DocumentSpare.newPassword())
    }

    func testTheSpareOpensWithThePasswordHoweverItWasPasted() throws {
        let password = DocumentSpare.newPassword()
        let spare = try DocumentSpare.make(key, password: password)
        let pasted = " " + password.uppercased().replacingOccurrences(of: "-", with: " ") + "\n"
        XCTAssertEqual(try spare.open(password: pasted).withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try spare.open(password: DocumentSpare.newPassword()))
        XCTAssertThrowsError(try spare.open(password: String(password.dropLast())))
    }

    func testTheSpareHoldsNoPlainKeyOrPasswordAndAChangedByteRefuses() throws {
        let password = DocumentSpare.newPassword()
        var spare = try DocumentSpare.make(key, password: password)
        try spare.write(in: mac)
        let written = try Data(contentsOf: mac.appendingPathComponent(DocumentSpare.fileName))
        XCTAssertNil(written.range(of: key.withUnsafeBytes { Data($0) }))
        XCTAssertNil(written.range(of: Data(DocumentSpare.normalized(password).utf8)))
        var sealed = spare.sealed
        sealed[sealed.count - 1] ^= 1
        spare = DocumentSpare(salt: spare.salt, sealed: sealed, keyID: spare.keyID)
        XCTAssertThrowsError(try spare.open(password: password))
    }

    // MARK: The iCloud copy

    func testTheCopyHoldsTheEncryptedStoreAndTheSpareButNotThisMacsKey() throws {
        try macStore()
        FileManager.default.createFile(atPath: mac.appendingPathComponent("household.key").path, contents: Data("k".utf8))
        XCTAssertEqual(try backUp(), .copied(files: 2, documents: 2))
        XCTAssertNotNil(DocumentSpare.read(in: backup))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("household.key").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent(DocumentList.fileName).path))
        let theirs = try DocumentStore(root: backup, key: key).load()
        XCTAssertEqual(theirs.documents.count, 2)
        XCTAssertEqual(try backUp(), .copied(files: 0, documents: 2))  // nothing new: nothing copied again
    }

    func testAPurgedFileLeavesTheCopyOnlyAfterTheNewIndexIsThere() throws {
        let (store, start) = try macStore()
        try backUp()
        var index = start
        let gone = index.documents[0]
        index.delete(document: gone.id, now: now.addingTimeInterval(-40 * 86_400))
        let files = index.purgeExpired(now: now)
        try store.save(index)
        store.remove(files: files)
        // relisted as the unlocked Mac app does, naming the purged file as removed on purpose (audit G2)
        let list = try DocumentList.refresh(root: mac, stamp: (store.keyID, index.removedFiles ?? []))
        XCTAssertEqual(DocumentBackup.copy(from: mac, to: backup, list: list), .copied(files: 0, documents: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("files/\(gone.file)").path))
        XCTAssertEqual(try DocumentStore(root: backup, key: key).load().purged, [gone.id])
    }

    func testNoCopyWithoutASpareAndNeverOverACopyOfAnotherKey() throws {
        try macStore(spare: nil)
        XCTAssertEqual(try backUp(), .noSpare)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        try DocumentSpare.make(SymmetricKey(size: .bits256), password: "x").write(in: backup)  // a new Mac's other key
        try DocumentSpare.make(key, password: "y").write(in: mac)
        XCTAssertEqual(try backUp(), .otherKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent(DocumentList.indexName).path))
        XCTAssertEqual(DocumentBackup.copy(from: mac, to: backup, list: nil), .noStore)
    }

    func testAFileICloudKeepsOffTheMacIsNotCopiedAgainNorRemoved() throws {
        try macStore()
        try backUp()
        let files = backup.appendingPathComponent("files")
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: files.path).sorted().first)
        try FileManager.default.moveItem(at: files.appendingPathComponent(name), to: files.appendingPathComponent(".\(name).icloud"))
        XCTAssertEqual(try backUp(), .copied(files: 0, documents: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.appendingPathComponent(".\(name).icloud").path))
    }

    func testAFileThatChangedOnTheWayIsRefusedAndTheOldCopyKept() throws {
        try macStore()
        let list = try XCTUnwrap(DocumentList.refresh(root: mac))
        let entry = list.files[0]
        let bad = DocumentList(index: list.index, files: [DocumentList.Entry(name: entry.name, size: entry.size + 1,
                                                                              sha256: String(repeating: "0", count: 64))])
        XCTAssertEqual(DocumentBackup.copy(from: mac, to: backup, list: bad), .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("files/\(entry.name)").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent(DocumentList.indexName).path))
    }

    func testAFailureKeepsTheLastGoodCopysDate() throws {
        DocumentBackup.writeStatus(.noSpare, in: mac, now: now)  // the first try, with nothing before it
        XCTAssertEqual(DocumentBackup.readStatus(in: mac), DocumentBackup.Status(at: now, problem: "noSpare"))
        DocumentBackup.writeStatus(.copied(files: 2, documents: 2), in: mac, now: now)
        DocumentBackup.writeStatus(.failed, in: mac, now: now.addingTimeInterval(600))
        XCTAssertEqual(DocumentBackup.readStatus(in: mac), DocumentBackup.Status(at: now, files: 2, problem: "failed"))
        DocumentBackup.writeStatus(.copied(files: 0, documents: 3), in: mac, now: now.addingTimeInterval(900))
        XCTAssertEqual(DocumentBackup.readStatus(in: mac), DocumentBackup.Status(at: now.addingTimeInterval(900), files: 3))
    }

    // MARK: Test a restore

    func testARestoreTestOpensEveryDocumentWithThePasswordAlone() throws {
        let password = DocumentSpare.newPassword()
        try macStore(spare: password)
        try backUp()
        XCTAssertEqual(DocumentRestoreTest.run(copy: backup, password: password), .passed(documents: 2))
        XCTAssertEqual(DocumentRestoreTest.run(copy: backup, password: DocumentSpare.newPassword()), .wrongPassword)
        XCTAssertEqual(DocumentRestoreTest.run(copy: mac.appendingPathComponent("nowhere"), password: password), .noSpare)
    }

    func testARestoreTestCatchesADamagedFileAndSaysWhatsStillInICloud() throws {
        let password = DocumentSpare.newPassword()
        try macStore(spare: password)
        try backUp()
        let files = backup.appendingPathComponent("files")
        let names = try FileManager.default.contentsOfDirectory(atPath: files.path).sorted()
        let handle = try FileHandle(forUpdating: files.appendingPathComponent(names[0]))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()
        XCTAssertEqual(DocumentRestoreTest.run(copy: backup, password: password), .mismatched(matching: 1, all: 2))
        try FileManager.default.moveItem(at: files.appendingPathComponent(names[1]),
                                         to: files.appendingPathComponent(".\(names[1]).icloud"))
        XCTAssertEqual(DocumentRestoreTest.run(copy: backup, password: password), .notDownloaded(1))
    }

    func testOnlyARealTestIsRecorded() throws {
        DocumentRestoreTest.record(.wrongPassword, from: "iCloud", in: mac, now: now)
        XCTAssertNil(DocumentRestoreTest.read(in: mac))
        DocumentRestoreTest.record(.passed(documents: 2), from: "iCloud", in: mac, now: now)
        XCTAssertEqual(DocumentRestoreTest.read(in: mac),
                       DocumentRestoreTest.Record(at: now, from: "iCloud", passed: true, documents: 2))
    }

    // MARK: The words

    func testTheBackupLinesAskForThePasswordFirstAndTheTestUntilItPasses() {
        let none = DocumentsWords.backupLines(nil, test: nil, hasSpare: false)
        XCTAssertTrue(none[0].text.contains("make a recovery password first"))
        XCTAssertTrue(none[0].caution)
        XCTAssertTrue(none[1].text.contains("keep the plain originals"))
        let good = DocumentsWords.backupLines(DocumentBackup.Status(at: now, files: 2),
                                              test: DocumentRestoreTest.Record(at: now, from: "iCloud", passed: true,
                                                                               documents: 2),
                                              hasSpare: true, now: now)
        XCTAssertTrue(good[0].text.hasPrefix("Essential Documents: copied to Household Private › Backups › Documents"))
        XCTAssertFalse(good[0].caution)
        XCTAssertTrue(good[1].text.hasPrefix("Last Test a restore: passed"))
        XCTAssertEqual(DocumentsWords.restoreLine(.passed(documents: 2), from: "iCloud copy"),
                       "Test a restore passed: all 2 documents in the iCloud copy opened with the recovery password, every "
                       + "fingerprint matching.")
    }
}
