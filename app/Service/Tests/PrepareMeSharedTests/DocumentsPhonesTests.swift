import CryptoKit
import Foundation
import LocalAuthentication
@testable import PrepareMeShared
import XCTest

/// Essential Documents on the adults' phones (phase 3): the Mac's list, a phone's mirror of it, the phone's changes
/// through the Mac's inbox, and the key's handoff. Made-up documents in fresh temporary folders, one household key.
final class DocumentsPhonesTests: XCTestCase {
    var folder: URL!
    var mac: URL!
    var phone: URL!
    let key = SymmetricKey(size: .bits256)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-docs-phones-\(UUID())")
        mac = folder.appendingPathComponent("mac")
        phone = folder.appendingPathComponent("phone")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The Mac's store with a folder and three made-up documents, saved and listed.
    @discardableResult
    func macStore() throws -> (DocumentStore, DocumentIndex) {
        let store = DocumentStore(root: mac, key: key)
        var index = DocumentIndex()
        let ids = index.newFolder("IDs", in: nil, now: now)
        try store.add(Data("made-up passport".utf8), named: "Passport (FAKE)", type: "jpg", to: ids, in: &index, now: now)
        try store.add(Data(repeating: 7, count: DocumentCipher.pieceSize + 10), named: "Deed (FAKE)", type: "pdf",
                      to: nil, in: &index, now: now)
        try store.add(Data("made-up notes".utf8), named: "Notes (FAKE)", type: "txt", to: nil, in: &index, now: now)
        try store.save(index)
        try DocumentList.refresh(root: mac)
        return (store, index)
    }

    func macList() throws -> DocumentList {
        try DocumentList.read(Data(contentsOf: mac.appendingPathComponent(DocumentList.fileName)))
    }

    /// What a phone's fetch does: each entry copied to a temporary place, then taken in; then finished.
    func mirror(keep: Set<String> = []) throws {
        let list = try macList()
        var held = DocumentMirror.held(in: phone)
        for entry in DocumentMirror.toFetch(list, held: held, root: phone) {
            let from = entry.name == DocumentList.indexName ? mac.appendingPathComponent(entry.name)
                : mac.appendingPathComponent("files").appendingPathComponent(entry.name)
            let fetched = folder.appendingPathComponent("fetched-\(UUID())")
            try FileManager.default.copyItem(at: from, to: fetched)
            try DocumentMirror.take(fetched, as: entry, root: phone, held: &held)
        }
        try DocumentMirror.finish(list, root: phone, held: &held, keep: keep)
    }

    // MARK: The list

    func testTheListNamesTheIndexAndEveryStoredFileByItsEncryptedFingerprint() throws {
        try macStore()
        let list = try macList()
        XCTAssertEqual(list.files.count, 3)
        XCTAssertEqual(list.index.name, "index.pmdoc")
        XCTAssertEqual(list.index.sha256, try FileCheck.sha256(of: mac.appendingPathComponent("index.pmdoc")))
        for entry in list.files {
            let url = mac.appendingPathComponent("files").appendingPathComponent(entry.name)
            XCTAssertEqual(entry.sha256, try FileCheck.sha256(of: url))
            XCTAssertEqual(entry.size, DocumentList.size(of: url))
        }
        // nothing that names a document: the key file, a half-written copy and a stray name are left out
        let text = String(decoding: try Data(contentsOf: mac.appendingPathComponent(DocumentList.fileName)), as: UTF8.self)
        XCTAssertFalse(text.contains("FAKE"))
        XCTAssertFalse(text.contains("household.key"))
        try Data("x".utf8).write(to: mac.appendingPathComponent("files/.a.pmdoc.tmp-1"))
        try Data("x".utf8).write(to: mac.appendingPathComponent("files/stray.pmdoc"))
        XCTAssertEqual(try DocumentList.make(root: mac)?.files.count, 3)
    }

    func testAStoreWithNoIndexHasNoListAndAnUnchangedListIsntWrittenAgain() throws {
        XCTAssertNil(try DocumentList.make(root: mac))
        XCTAssertNil(try DocumentList.refresh(root: mac))
        try macStore()
        let url = mac.appendingPathComponent(DocumentList.fileName)
        let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        try DocumentList.refresh(root: mac)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, written)
    }

    func testAListedFileWithTheSameNameAndSizeIsntReadAgain() throws {
        try macStore()
        var list = try macList()
        let first = list.files[0]
        list.files[0] = DocumentList.Entry(name: first.name, size: first.size, sha256: String(repeating: "a", count: 64))
        XCTAssertEqual(try DocumentList.make(root: mac, previous: list)?.files[0].sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(try DocumentList.make(root: mac)?.files[0].sha256, first.sha256)
    }

    func testAListThatIsntOneIsRefused() throws {
        try macStore()
        let good = try macList()
        var bad = good
        bad.files.append(DocumentList.Entry(name: "../household.key", size: 1, sha256: good.index.sha256))
        XCTAssertThrowsError(try DocumentList.read(DocumentList.encoded(bad)))
        bad = good
        bad.files.append(good.files[0])  // twice
        XCTAssertThrowsError(try DocumentList.read(DocumentList.encoded(bad)))
        bad = good
        bad.index = DocumentList.Entry(name: "household.key", size: 1, sha256: good.index.sha256)
        XCTAssertThrowsError(try DocumentList.read(DocumentList.encoded(bad)))
        XCTAssertThrowsError(try DocumentList.read(Data("{}".utf8)))
    }

    // MARK: The phone's mirror

    func testAPhoneMirrorsTheStoreAndOpensEveryDocumentByteForByte() throws {
        let (store, index) = try macStore()
        try mirror()
        let copy = DocumentStore(root: phone, key: key)
        let mirrored = try copy.load()
        XCTAssertEqual(mirrored, index)
        for document in index.documents { XCTAssertEqual(try copy.data(of: document), try store.data(of: document)) }
        let standing = DocumentMirror.standing(try macList(), held: DocumentMirror.held(in: phone), root: phone)
        XCTAssertEqual(standing.matching, 3)
        XCTAssertEqual(standing.all, 3)
        XCTAssertTrue(standing.index)
        XCTAssertTrue(DocumentMirror.toFetch(try macList(), held: DocumentMirror.held(in: phone), root: phone).isEmpty)
    }

    func testAFileGoneFromThePhoneIsCountedMissingUntilItIsFetchedAgain() throws {
        _ = try macStore()
        try mirror()
        let list = try macList()
        let gone = phone.appendingPathComponent("files").appendingPathComponent(list.files[0].name)
        try FileManager.default.removeItem(at: gone)
        let standing = DocumentMirror.standing(list, held: DocumentMirror.held(in: phone), root: phone)
        XCTAssertEqual(standing.matching, 2)  // the ledger still says 3: the disk wins
        XCTAssertEqual(DocumentMirror.toFetch(list, held: DocumentMirror.held(in: phone), root: phone).map(\.name),
                       [list.files[0].name])
        try mirror()
        XCTAssertEqual(DocumentMirror.standing(list, held: DocumentMirror.held(in: phone), root: phone).matching, 3)
    }

    func testAChangeOnTheMacReachesThePhoneAndAGoneFileIsRemovedThere() throws {
        var (store, index) = try macStore()
        try mirror()
        let gone = index.documents.first { $0.name == "Notes (FAKE)" }!
        index.delete(document: gone.id, now: now)
        let files = index.purgeExpired(now: now.addingTimeInterval(31 * 86_400))
        try store.add(Data("made-up will".utf8), named: "Will (FAKE)", type: "pdf", to: nil, in: &index, now: now)
        try store.save(index)
        store.remove(files: files)
        try DocumentList.refresh(root: mac)
        XCTAssertEqual(DocumentMirror.toFetch(try macList(), held: DocumentMirror.held(in: phone), root: phone).count, 2)
        try mirror()
        XCTAssertEqual(try DocumentStore(root: phone, key: key).load(), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.appendingPathComponent("files/\(gone.file)").path))
    }

    func testAFileThatDoesntMatchTheListIsntKeptAndTheIndexWaitsForEveryFile() throws {
        try macStore()
        let list = try macList()
        var held = DocumentMirror.held(in: phone)
        let wrong = folder.appendingPathComponent("wrong")
        try Data("not it".utf8).write(to: wrong)
        XCTAssertThrowsError(try DocumentMirror.take(wrong, as: list.files[0], root: phone, held: &held))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrong.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.appendingPathComponent("files/\(list.files[0].name)").path))
        XCTAssertThrowsError(try DocumentMirror.finish(list, root: phone, held: &held, keep: []))  // nothing came yet
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.appendingPathComponent("index.pmdoc").path))
    }

    func testThePhonesOwnAddsArentRemovedByTheMirror() throws {
        try macStore()
        var phoneIndex = DocumentIndex()
        let own = try DocumentStore(root: phone, key: key).add(Data("phone scan".utf8), named: "Scan (FAKE)", type: "pdf",
                                                               to: nil, in: &phoneIndex, now: now)
        try mirror(keep: [own.file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: phone.appendingPathComponent("files/\(own.file)").path))
        try mirror()  // once the Mac has it, or it's given up, it goes like any other
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.appendingPathComponent("files/\(own.file)").path))
    }

    // MARK: Changes

    func testEveryKindOfChangeAppliesOnceAndAGoneOneChangesNothing() throws {
        var index = DocumentIndex()
        let folder = DocumentFolder(id: UUID(), name: "Medical", parent: nil, created: now, deleted: nil)
        let doc = StoredDocument(id: UUID(), name: "Card", folder: folder.id, file: "a.pmdoc", type: "pdf", size: 1,
                                 sha256: String(repeating: "0", count: 64), added: now)
        let add = DocumentChange(.add(document: doc), at: now)
        XCTAssertTrue(index.apply(DocumentChange(.newFolder(folder: folder), at: now)))
        XCTAssertTrue(index.apply(add))
        XCTAssertFalse(index.apply(add))  // once, by its id
        XCTAssertEqual(index.documents.count, 1)
        index.apply(DocumentChange(.renameDocument(id: doc.id, name: "Vaccination card"), at: now))
        index.apply(DocumentChange(.renameFolder(id: folder.id, name: "Health"), at: now))
        index.apply(DocumentChange(.moveDocument(id: doc.id, folder: nil), at: now))
        XCTAssertEqual(index.documents[0].name, "Vaccination card")
        XCTAssertNil(index.documents[0].folder)
        XCTAssertEqual(index.folders[0].name, "Health")
        let send = DocumentSend(date: now, device: "iPhone", how: "Print")
        index.apply(DocumentChange(.send(id: doc.id, send: send), at: now))
        XCTAssertEqual(index.documents[0].sends, [send])
        index.apply(DocumentChange(.deleteDocument(id: doc.id), at: now))
        XCTAssertEqual(index.documents[0].deleted, now)
        index.apply(DocumentChange(.putBackDocument(id: doc.id), at: now))
        XCTAssertNil(index.documents[0].deleted)
        index.apply(DocumentChange(.deleteFolder(id: folder.id), at: now))
        XCTAssertTrue(index.isDeleted(folder: folder.id))
        index.apply(DocumentChange(.putBackFolder(id: folder.id), at: now))
        XCTAssertFalse(index.isDeleted(folder: folder.id))
        // a change to something not here changes nothing, and counts as applied
        let stray = DocumentChange(.renameDocument(id: UUID(), name: "x"), at: now)
        let before = index.documents
        XCTAssertTrue(index.apply(stray))
        XCTAssertEqual(index.documents, before)
        XCTAssertEqual(index.applied?.count, 11)
    }

    func testADeletedForGoodIdIsNeverBroughtBackAndAMissingFolderMeansTheTopLevel() throws {
        var index = DocumentIndex()
        let doc = StoredDocument(id: UUID(), name: "Old", folder: UUID(), file: "a.pmdoc", type: "pdf", size: 1,
                                 sha256: String(repeating: "0", count: 64), added: now)
        index.purged = [doc.id]
        index.apply(DocumentChange(.add(document: doc), at: now))
        XCTAssertTrue(index.documents.isEmpty)
        var other = doc
        other = StoredDocument(id: UUID(), name: "New", folder: UUID(), file: "b.pmdoc", type: "pdf", size: 1,
                               sha256: doc.sha256, added: now)
        index.apply(DocumentChange(.add(document: other), at: now))
        XCTAssertNil(index.documents[0].folder)
    }

    func testAPhoneShowsItsChangesOnTopUntilTheMacHasAppliedThem() throws {
        let (_, index) = try macStore()
        let rename = DocumentChange(.renameDocument(id: index.documents[0].id, name: "Renamed on the phone"), at: now)
        let shown = index.overlaid([rename])
        XCTAssertEqual(shown.documents[0].name, "Renamed on the phone")
        XCTAssertEqual(shown.applied, index.applied)  // the Mac's record, not the phone's guess
        XCTAssertEqual(DocumentOutbox.waiting([rename], against: index), [rename])
        var applied = index
        applied.apply(rename)
        XCTAssertEqual(DocumentOutbox.waiting([rename], against: applied), [])
    }

    func testTheOutboxIsKeptEncrypted() throws {
        let change = DocumentChange(.renameFolder(id: UUID(), name: "Secret folder name"), at: now)
        try DocumentOutbox.write([change], in: phone, key: key)
        let raw = try Data(contentsOf: phone.appendingPathComponent(DocumentOutbox.fileName))
        XCTAssertNil(raw.range(of: Data("Secret".utf8)))
        XCTAssertEqual(DocumentOutbox.read(in: phone, key: key), [change])
        XCTAssertEqual(DocumentOutbox.read(in: phone, key: SymmetricKey(size: .bits256)), [])
        try DocumentOutbox.write([], in: phone, key: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.appendingPathComponent(DocumentOutbox.fileName).path))
    }

    func testAnOutboxTooBigForTheServiceIsRefusedAndTheOldOneKept() throws {
        let one = DocumentChange(.renameFolder(id: UUID(), name: "Kept"), at: now)
        try DocumentOutbox.write([one], in: phone, key: key)
        let many = (0..<4000).map { DocumentChange(.renameFolder(id: UUID(), name: "Folder \($0)"), at: now) }
        XCTAssertThrowsError(try DocumentOutbox.write(many, in: phone, key: key))
        XCTAssertEqual(DocumentOutbox.read(in: phone, key: key), [one])
    }

    func testTheLedgerKeepsOnlyWhatStillWaitsAndNoNames() throws {
        var phoneIndex = DocumentIndex()
        let doc = try DocumentStore(root: phone, key: key).add(Data("scan".utf8), named: "Secret scan", type: "pdf",
                                                               to: nil, in: &phoneIndex, now: now)
        let add = DocumentChange(.add(document: doc), at: now)
        let rename = DocumentChange(.renameDocument(id: doc.id, name: "Secret name"), at: now)
        var ledger = DocumentOutbox.Ledger().settled([add, rename])
        ledger.posted = "abc"
        try ledger.write(in: phone)
        let raw = try Data(contentsOf: phone.appendingPathComponent(DocumentOutbox.Ledger.fileName))
        XCTAssertNil(raw.range(of: Data("Secret".utf8)))
        XCTAssertEqual(DocumentOutbox.Ledger.read(in: phone), ledger)
        XCTAssertEqual(ledger.files, [doc.file])
        XCTAssertEqual(ledger.settled([rename]).files, [])  // the add applied: its file is the Mac's now
        XCTAssertEqual(ledger.settled([rename]).posted, "abc")
        XCTAssertNil(ledger.settled([]).posted)
    }

    /// Audit D5: the line under Documents counts the ledger's files, the adds the Mac hasn't taken.
    func testDocumentsOnlyHereAreCountedAndSaidPlainly() {
        XCTAssertEqual(DocumentsWords.onlyHere(1, device: "phone"),
                       "1 document is only on this phone until it reaches the Mac.")
        XCTAssertEqual(DocumentsWords.onlyHere(2, device: "iPad"),
                       "2 documents are only on this iPad until it reaches the Mac.")
    }

    func testThePhonesOwnAddOnceListedIsntFetchedBack() throws {
        try macStore()
        try mirror()
        var phoneIndex = DocumentIndex()
        let doc = try DocumentStore(root: phone, key: key).add(Data("phone scan".utf8), named: "Scan", type: "pdf",
                                                               to: nil, in: &phoneIndex, now: now)
        // the Mac took it in under the same name
        try FileManager.default.copyItem(at: phone.appendingPathComponent("files/\(doc.file)"),
                                         to: mac.appendingPathComponent("files/\(doc.file)"))
        try DocumentList.refresh(root: mac)
        let list = try macList()
        var held = DocumentMirror.held(in: phone)
        try DocumentMirror.adopt(list, own: [doc.file], root: phone, held: &held)
        XCTAssertFalse(DocumentMirror.toFetch(list, held: held, root: phone).contains { $0.name == doc.file })
    }

    // MARK: The Mac's inbox

    /// A phone's add: the file made in the phone's store, copied (whole or `cut` bytes short) into the Mac's inbox
    /// with the phone's outbox.
    func phoneAdds(_ data: Data, named name: String, then more: [DocumentChange.Kind] = [], cut: Int = 0,
                   outboxKey: SymmetricKey? = nil) throws -> StoredDocument {
        var phoneIndex = DocumentIndex()
        let doc = try DocumentStore(root: phone, key: key).add(data, named: name, type: "pdf", to: nil, in: &phoneIndex,
                                                               now: now)
        let inbox = mac.appendingPathComponent(DocumentInbox.folderName)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var bytes = try Data(contentsOf: phone.appendingPathComponent("files/\(doc.file)"))
        bytes.removeLast(cut)
        try bytes.write(to: inbox.appendingPathComponent(doc.file))
        let changes = [DocumentChange(.add(document: doc), at: now)]
            + more.enumerated().map { DocumentChange($1, at: now.addingTimeInterval(Double($0 + 1))) }
        let encoder = JSONEncoder()
        try DocumentCipher.encrypt(encoder.encode(changes), to: inbox.appendingPathComponent("changes-1-phone1-x.pmdoc"),
                                   key: outboxKey ?? key)
        return doc
    }

    func testThePhonesAddReachesTheMacByteForByteOnce() throws {
        var (store, index) = try macStore()
        let doc = try phoneAdds(Data("phone's scan".utf8), named: "Scan (FAKE)")
        var (result, done) = DocumentInbox.apply(store: store, index: &index)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(try store.data(of: index.documents.first { $0.id == doc.id }!), Data("phone's scan".utf8))
        try store.save(index)
        DocumentInbox.tidy(done, inbox: mac.appendingPathComponent(DocumentInbox.folderName))
        XCTAssertEqual(DocumentInbox.waitingOutboxes(root: mac), 0)
        (result, done) = DocumentInbox.apply(store: store, index: &index)
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(index.documents.filter { $0.id == doc.id }.count, 1)
    }

    func testAnAddStillUploadingWaitsAndSoDoesEverythingAfterIt() throws {
        var (store, index) = try macStore()
        let other = index.documents[0]
        let doc = try phoneAdds(Data(repeating: 3, count: 5000), named: "Big (FAKE)",
                                then: [.renameDocument(id: other.id, name: "After the add")], cut: 100)
        let (result, done) = DocumentInbox.apply(store: store, index: &index)
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.waiting, 2)
        XCTAssertTrue(done.isEmpty)  // the outbox stays for next time
        XCTAssertFalse(index.documents.contains { $0.id == doc.id })
        XCTAssertNotEqual(index.documents[0].name, "After the add")
    }

    func testAnOutboxFromAnotherKeyOrAFileThatDoesntMatchIsRefused() throws {
        var (store, index) = try macStore()
        _ = try phoneAdds(Data("x".utf8), named: "Stranger", outboxKey: SymmetricKey(size: .bits256))
        var (result, done) = DocumentInbox.apply(store: store, index: &index)
        XCTAssertEqual(result.refused, 1)
        XCTAssertEqual(done.count, 1)
        DocumentInbox.tidy(done, inbox: mac.appendingPathComponent(DocumentInbox.folderName))

        // the file swapped for one of the household's, but not the one the add describes
        let doc = try phoneAdds(Data("the real one".utf8), named: "Swap")
        let inbox = mac.appendingPathComponent(DocumentInbox.folderName)
        try DocumentCipher.encrypt(Data("another".utf8), to: inbox.appendingPathComponent(doc.file), key: key)
        (result, done) = DocumentInbox.apply(store: store, index: &index)
        XCTAssertEqual(result.refused, 1)
        XCTAssertFalse(index.documents.contains { $0.id == doc.id })
        XCTAssertTrue(index.applied?.count == 1)  // never asked again
    }

    // MARK: The key's handoff

    func testTheGiftOpensOnlyWithThePhonesLockAndOnlyForThatPairing() throws {
        let lock = P256.KeyAgreement.PrivateKey()  // the phone's (a Secure Enclave key there)
        let ask = try DocumentHandoff.Request.read(JSONEncoder().encode(DocumentHandoff.Request(key: lock.publicKey.rawRepresentation)))
        let gift = try DocumentHandoff.seal(key, for: ask, label: "phone 2", paired: "2026-10-24T10:00:00Z", now: now)
        let file = DocumentKeyFile(lock: Data(), ephemeral: gift.ephemeral, sealed: gift.sealed)
        let opened = try file.open { try lock.sharedSecretFromKeyAgreement(with: $0) }
        XCTAssertEqual(opened.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        let stranger = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try file.open { try stranger.sharedSecretFromKeyAgreement(with: $0) })
        let all = ["phone 2": gift]
        XCTAssertEqual(DocumentHandoff.gift(all, label: "phone 2", paired: "2026-10-24T10:00:00Z"), gift)
        XCTAssertNil(DocumentHandoff.gift(all, label: "phone 2", paired: "2026-10-25T10:00:00Z"))  // a new phone 2
        XCTAssertNil(DocumentHandoff.gift(all, label: "phone 3", paired: "2026-10-24T10:00:00Z"))
        // what the phone is served carries no pairing stamp
        let served = String(decoding: try DocumentHandoff.encoded(DocumentHandoff.Served(gift)), as: UTF8.self)
        XCTAssertFalse(served.contains("paired"))
    }

    /// A phone's key file or gift that can't hold the key is `broken` (set aside, asked for again); a lock that
    /// merely won't agree, like a cancelled Face ID, isn't. None of these asks for Face ID: each fails before it would.
    func testABrokenKeyIsSetAsideAndThePhoneAsksAgainWithANewLock() throws {
        let lock = P256.KeyAgreement.PrivateKey()
        let ask = DocumentHandoff.Request(key: lock.publicKey.rawRepresentation)
        let gift = try DocumentHandoff.seal(key, for: ask, label: "phone 2", paired: "2026-10-24T10:00:00Z", now: now)
        let file = DocumentKeyFile(lock: Data(), ephemeral: gift.ephemeral, sealed: gift.sealed)
        let stranger = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try file.open { try stranger.sharedSecretFromKeyAgreement(with: $0) }) {
            XCTAssertEqual($0 as? DocumentKey.Failure, .broken)
        }
        XCTAssertThrowsError(try file.open { _ in throw CocoaError(.userCancelled) }) {
            XCTAssertNil($0 as? DocumentKey.Failure)  // a cancel stays a cancel
        }
        // a damaged key file
        try Data("not a key".utf8).write(to: DocumentKey.url(in: phone))
        XCTAssertThrowsError(try DocumentKey.open(in: phone, context: LAContext())) {
            XCTAssertEqual($0 as? DocumentKey.Failure, .broken)
        }
        // a gift for another lock than the one this phone asked with
        let pending = DocumentKey.Pending(lock: stranger.rawRepresentation, key: stranger.publicKey.rawRepresentation)
        try JSONEncoder().encode(pending).write(to: DocumentKey.pendingURL(in: phone))
        XCTAssertThrowsError(try DocumentKey.receive(DocumentHandoff.Served(gift), in: phone, context: LAContext())) {
            XCTAssertEqual($0 as? DocumentKey.Failure, .broken)
        }
        // set aside, never deleted, with the lock it asked with: the next check asks with a new lock
        try DocumentKey.setAside(DocumentKey.url(in: phone), in: phone)
        XCTAssertFalse(DocumentKey.exists(in: phone))
        XCTAssertFalse(DocumentKey.asked(in: phone))
        XCTAssertEqual(try Data(contentsOf: DocumentKey.url(in: phone).appendingPathExtension("set-aside")),
                       Data("not a key".utf8))
        // the Mac counts it given only when the gift fits the lock it asks with now
        XCTAssertTrue(DocumentHandoff.given(gift, ask: ask))
        XCTAssertTrue(DocumentHandoff.given(gift, ask: nil))
        XCTAssertFalse(DocumentHandoff.given(gift, ask: DocumentHandoff.Request(key: stranger.publicKey.rawRepresentation)))
        XCTAssertFalse(DocumentHandoff.given(nil, ask: ask))
    }

    /// The phone's step after `GET key`: a gift for its own lock is kept; none yet, or one for a lock it set aside,
    /// means ask again (the stuck phone this fixed); a child's phone never makes a lock.
    func testAPhoneKeepsOnlyAGiftForItsOwnLockAndOtherwiseAsksAgain() throws {
        let mine = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let old = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        func served(_ key: Data) throws -> Data {
            try DocumentHandoff.encoded(DocumentHandoff.Served(DocumentHandoff.seal(
                self.key, for: DocumentHandoff.Request(key: key), label: "phone 2", paired: "2026-10-24T10:00:00Z")))
        }
        XCTAssertEqual(DocumentHandoff.keyStep(status: 200, served: try served(mine), lock: { mine }), .keep)
        XCTAssertEqual(DocumentHandoff.keyStep(status: 200, served: try served(old), lock: { mine }), .ask)
        XCTAssertEqual(DocumentHandoff.keyStep(status: 200, served: Data("not a gift".utf8), lock: { mine }), .ask)
        XCTAssertEqual(DocumentHandoff.keyStep(status: 404, served: Data(), lock: { mine }), .ask)
        XCTAssertEqual(DocumentHandoff.keyStep(status: 200, served: try served(mine), lock: { nil }), .stop)
        var made = false
        XCTAssertEqual(DocumentHandoff.keyStep(status: 403, served: Data(), lock: { made = true; return mine }), .stop)
        XCTAssertFalse(made)
    }

    func testAnAskThatIsntAKeyIsRefused() throws {
        XCTAssertThrowsError(try DocumentHandoff.Request.read(Data(#"{"key":"AAAA"}"#.utf8)))
        XCTAssertThrowsError(try DocumentHandoff.Request.read(Data(repeating: 32, count: 2000)))
    }

    func testAPhonesReportIsCountsOnlyAndChecked() throws {
        let good = try DocumentsPhoneReport.read(Data(#"{"matching":3,"all":4,"index":true,"waiting":1,"at":"x"}"#.utf8))
        XCTAssertEqual(good.matching, 3)
        XCTAssertNil(good.at)  // the service stamps it
        XCTAssertFalse(good.inStep)
        XCTAssertThrowsError(try DocumentsPhoneReport.read(Data(#"{"matching":5,"all":4,"index":true,"waiting":0}"#.utf8)))
        XCTAssertThrowsError(try DocumentsPhoneReport.read(Data(#"{"matching":-1,"all":4,"index":true,"waiting":0}"#.utf8)))
    }

    func testAPhase2IndexStillReads() throws {
        let old = Data(#"{"folders":[],"documents":[],"purged":[],"brought":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(DocumentIndex.self, from: old).applied)
    }
}
