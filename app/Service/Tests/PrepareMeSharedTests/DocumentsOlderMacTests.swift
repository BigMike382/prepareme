import CryptoKit
import Foundation
import Testing
@testable import PrepareMeShared

/// Audit G2 (docs/plans/2026-11-22-documents-older-mac-guard.md): a Mac set up again, from an older copy of Essential
/// Documents or under a new key, never makes an adult's phone or the iCloud copy delete documents. Made-up documents
/// in fresh temporary folders.
final class DocumentsOlderMacTests {
    let folder: URL
    let mac: URL
    let phone: URL
    let backup: URL
    let key = SymmetricKey(size: .bits256)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-docs-older-\(UUID())")
        mac = folder.appendingPathComponent("mac")
        phone = folder.appendingPathComponent("phone")
        backup = folder.appendingPathComponent("Backups/Documents")
        for url in [mac, phone] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// The Mac's store with `count` made-up documents, saved and listed while unlocked.
    @discardableResult
    func macStore(_ count: Int = 3, key: SymmetricKey? = nil) throws -> (DocumentStore, DocumentIndex) {
        let store = DocumentStore(root: mac, key: key ?? self.key)
        var index = DocumentIndex()
        for number in 1...count {
            try store.add(Data("made-up paper \(number)".utf8), named: "Paper \(number) (FAKE)", type: "txt", to: nil,
                          in: &index, now: now)
        }
        try save(store, index)
        return (store, index)
    }

    /// What the Mac app does after a change while unlocked: save, remove the files it took out, then relist with the
    /// store's stamp.
    func save(_ store: DocumentStore, _ index: DocumentIndex, removing files: [String] = []) throws {
        try store.save(index)
        store.remove(files: files)
        try DocumentList.refresh(root: mac, stamp: (store.keyID, index.removedFiles ?? []))
    }

    func addOne(_ store: DocumentStore, _ index: inout DocumentIndex, _ name: String) throws {
        try store.add(Data("made-up \(name)".utf8), named: "\(name) (FAKE)", type: "txt", to: nil, in: &index, now: now)
        try save(store, index)
    }

    func macList() throws -> DocumentList {
        try DocumentList.read(Data(contentsOf: mac.appendingPathComponent(DocumentList.fileName)))
    }

    /// The phone's check at home: the list judged first; refused, it is recorded and nothing else happens.
    @discardableResult
    func mirror(keep: Set<String> = []) throws -> DocumentMirror.Refusal? {
        let list = try macList()
        var held = DocumentMirror.held(in: phone)
        let refusal = DocumentMirror.judge(list, held: held, yield: DocumentMirror.yielded(in: phone))
        try DocumentMirror.record(refusal, root: phone, held: &held)
        if let refusal { return refusal }
        for entry in DocumentMirror.toFetch(list, held: held, root: phone) {
            let from = entry.name == DocumentList.indexName ? mac.appendingPathComponent(entry.name)
                : mac.appendingPathComponent("files").appendingPathComponent(entry.name)
            let fetched = folder.appendingPathComponent("fetched-\(UUID())")
            try FileManager.default.copyItem(at: from, to: fetched)
            try DocumentMirror.take(fetched, as: entry, root: phone, held: &held)
        }
        try DocumentMirror.finish(list, root: phone, held: &held, keep: keep)
        return nil
    }

    /// The phone's stored files and its index's fingerprint: what must not change when a list is refused.
    func phoneState() throws -> (files: [String], index: String) {
        let files = try FileManager.default.contentsOfDirectory(atPath: phone.appendingPathComponent("files").path)
        return (files.sorted(), try FileCheck.sha256(of: phone.appendingPathComponent(DocumentList.indexName)))
    }

    /// The Mac's whole store folder set aside, as a USB copy would hold it, and later put back in its place.
    func setAside(_ name: String) throws -> URL {
        let copy = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: mac, to: copy)
        return copy
    }

    func putBack(_ copy: URL) throws {
        try FileManager.default.removeItem(at: mac)
        try FileManager.default.copyItem(at: copy, to: mac)
        try DocumentList.refresh(root: mac)  // PrepareMe's start-up relist, with no key
    }

    // MARK: A new key

    @Test func aNewStoreUnderANewKeyWithTheSamePairingLeavesThePhonesCopy() throws {
        try macStore()
        #expect(try mirror() == nil)
        let before = try phoneState()
        #expect(before.files.count == 3)
        try FileManager.default.removeItem(at: mac)  // a rebuilt Mac: the store started fresh, the pairing kept
        try macStore(1, key: SymmetricKey(size: .bits256))
        let refusal = try #require(try mirror())
        #expect(refusal.reason == .otherKey)
        #expect(try phoneState() == before)
        #expect(DocumentMirror.held(in: phone).refused == refusal)
        // finish enforces it too
        var held = DocumentMirror.held(in: phone)
        #expect(throws: DocumentMirror.Problem.refused) {
            try DocumentMirror.finish(try self.macList(), root: self.phone, held: &held, keep: [])
        }
        #expect(try phoneState() == before)
    }

    @Test func aPhoneLastInStepWithAnOlderMacAppRefusesANewKeyToo() throws {
        let store = DocumentStore(root: mac, key: key)
        var index = DocumentIndex()
        try store.add(Data("made-up".utf8), named: "Paper (FAKE)", type: "txt", to: nil, in: &index, now: now)
        try store.save(index)
        try DocumentList.refresh(root: mac)  // an older Mac app's list: no stamp
        #expect(try mirror() == nil)
        #expect(DocumentMirror.held(in: phone).keyID == nil)
        let before = try phoneState()
        try FileManager.default.removeItem(at: mac)
        try macStore(2, key: SymmetricKey(size: .bits256))
        let refusal = try #require(try mirror())
        #expect(refusal.reason == .missing)  // it can't tell the key apart yet; its files are all gone from the list
        #expect(DocumentsWords.offersMacsCopy(refusal, ownKeyID: store.keyID) == false)
        #expect(DocumentsWords.keptOwnCopy(refusal, ownKeyID: store.keyID, device: "iPhone").contains("different key"))
        #expect(try phoneState() == before)
    }

    // MARK: An older copy

    @Test func anOlderCopyIsRefusedEvenAfterTheMacHasMadeMoreChanges() throws {
        var (store, index) = try macStore()
        let older = try setAside("older")
        try addOne(store, &index, "Newest")
        #expect(try mirror() == nil)
        let before = try phoneState()
        #expect(before.files.count == 4)
        try putBack(older)
        #expect(try macList().keyID == store.keyID)  // the copy's own list still describes its index
        let refusal = try #require(try mirror())
        #expect(refusal == DocumentMirror.Refusal(.missing, files: 1, keyID: store.keyID))
        #expect(try phoneState() == before)
        // the rebuilt Mac goes on being used: more saves than the phone ever saw, still refused
        index = try store.load()
        for number in 1...5 { try addOne(store, &index, "Later \(number)") }
        #expect(try mirror()?.files == 1)
        #expect(try phoneState() == before)
    }

    @Test func onceTheMacHasEveryFileAgainTheNextListIsTaken() throws {
        var (store, index) = try macStore()
        let older = try setAside("older")
        try addOne(store, &index, "Newest")
        let newer = try setAside("newer")
        try mirror()
        try putBack(older)
        #expect(try mirror() != nil)
        try putBack(newer)  // the owner put the newer copy back on the Mac
        // a list that passes clears the warning even before its files have all come
        var held = DocumentMirror.held(in: phone)
        try DocumentMirror.record(DocumentMirror.judge(try macList(), held: held), root: phone, held: &held)
        #expect(DocumentMirror.held(in: phone).refused == nil)
        #expect(try mirror() == nil)
        #expect(try phoneState().files.count == 4)
    }

    @Test func anOlderMacHoldingAnOlderInsurancePDFOfTheSameDocumentIsRefused() throws {
        var (store, index) = try macStore()
        let older = try setAside("older")
        let old = try #require(try store.replace(index.documents[0].id, with: Data("newer record".utf8), in: &index))
        try save(store, index, removing: [old])
        #expect(try macList().removed == [old])
        #expect(try mirror() == nil)
        let before = try phoneState()
        try putBack(older)  // the Mac still has the document, with its older file
        #expect(try mirror()?.files == 1)
        #expect(try phoneState() == before)
    }

    // MARK: Normal mirroring still works

    @Test func aNewerListStillMirrorsAndRemovesWhatTheMacRemovedOnPurpose() throws {
        var (store, index) = try macStore(4)
        try mirror()
        // one document purged from Recently Deleted, another's insurance PDF replaced, one added
        let purged = index.documents[0]
        index.delete(document: purged.id, now: now)
        let gone = index.purgeExpired(now: now.addingTimeInterval(31 * 86_400))
        #expect(gone == [purged.file])
        let replaced = try #require(try store.replace(index.documents[0].id, with: Data("newer".utf8), in: &index))
        try store.add(Data("made-up new".utf8), named: "New (FAKE)", type: "txt", to: nil, in: &index, now: now)
        try save(store, index, removing: gone + [replaced])
        #expect(Set(try macList().removed ?? []) == [purged.file, replaced])
        #expect(try mirror() == nil)
        let files = Set(try phoneState().files)
        #expect(files == Set(try macList().files.map(\.name)))
        #expect(!files.contains(purged.file) && !files.contains(replaced))
        #expect(try DocumentStore(root: phone, key: key).load() == index)
        #expect(DocumentMirror.held(in: phone).keyID == store.keyID)
    }

    @Test func thePhonesOwnAddsWaitingForTheMacAreStillKept() throws {
        try macStore()
        try mirror()
        let own = UUID().uuidString.lowercased() + ".pmdoc"
        try Data("waiting".utf8).write(to: phone.appendingPathComponent("files").appendingPathComponent(own))
        #expect(try mirror(keep: [own]) == nil)
        #expect(try phoneState().files.contains(own))
    }

    // MARK: Lists without a stamp

    @Test func anOlderMacAppsListsAreTakenAsBeforeUntilThePhoneHasSeenAStamp() throws {
        let store = DocumentStore(root: mac, key: key)
        var index = DocumentIndex()
        for number in 1...2 {
            try store.add(Data("\(number)".utf8), named: "\(number) (FAKE)", type: "txt", to: nil, in: &index, now: now)
        }
        try store.save(index)
        try DocumentList.refresh(root: mac)
        try mirror()
        // the older Mac app purges a document: its list has no stamp, and the phone follows it as it did before G2
        index.delete(document: index.documents[0].id, now: now)
        let gone = index.purgeExpired(now: now.addingTimeInterval(31 * 86_400))
        try store.save(index)
        store.remove(files: gone)
        try DocumentList.refresh(root: mac)
        #expect(try mirror() == nil)
        #expect(try phoneState().files.count == 1)
    }

    @Test func afterAStampAListWithoutOneIsRefusedOnlyWhenItWouldRemoveAFile() throws {
        var (store, index) = try macStore()
        try mirror()
        // the same store, its index swapped while PrepareMe was closed (no stamp until the next unlock), nothing lost
        let unchanged = try setAside("unchanged")
        try store.save(index)
        try DocumentList.refresh(root: mac)
        #expect(try macList().keyID == nil)
        #expect(try mirror() == nil)
        #expect(DocumentMirror.held(in: phone).keyID == store.keyID)  // never forgotten
        // a store swapped in that lacks a file the phone has: refused, and it says the Mac must be unlocked
        try addOne(store, &index, "Newest")
        try mirror()
        try putBack(unchanged)
        try store.save(store.load())  // swapped again: its list's stamp no longer describes the index
        try DocumentList.refresh(root: mac)
        let refusal = try #require(try mirror())
        #expect(refusal.reason == .unstamped)
        #expect(DocumentsWords.keptOwnCopy(refusal, ownKeyID: store.keyID, device: "iPad")
            .contains("haven't been unlocked"))
    }

    @Test func aKeylessRelistKeepsTheStampOnlyForTheSameIndex() throws {
        let (store, index) = try macStore()
        let stamped = try macList()
        #expect(stamped.keyID == store.keyID && stamped.keyID?.count == 32)
        try DocumentList.refresh(root: mac)
        #expect(try macList() == stamped)
        try store.save(index)  // a new encryption: a new index file
        try DocumentList.refresh(root: mac)
        #expect(try macList().keyID == nil)
        #expect(try macList().removed == nil)
    }

    // MARK: Old and new apps together

    /// The list as a phone app from before G2 decodes it.
    struct OlderList: Decodable {
        var version: Int
        var index: DocumentList.Entry
        var files: [DocumentList.Entry]
    }

    @Test func anOlderPhoneAppStillReadsTheNewListAndTheNewAppReadsAnOldOne() throws {
        var (store, index) = try macStore()
        let old = try store.replace(index.documents[0].id, with: Data("newer".utf8), in: &index)
        try save(store, index)
        let data = try Data(contentsOf: mac.appendingPathComponent(DocumentList.fileName))
        let older = try JSONDecoder().decode(OlderList.self, from: data)
        #expect(older.version == 1)
        #expect(older.files == (try macList().files))
        #expect(try macList().removed == [try #require(old)])
        var plain = try macList()
        (plain.keyID, plain.removed) = (nil, nil)
        let text = String(decoding: try DocumentList.encoded(plain), as: UTF8.self)
        #expect(!text.contains("keyID") && !text.contains("removed"))
        #expect(try DocumentList.read(Data(text.utf8)) == plain)
    }

    @Test func aListWithABadStampIsRefused() throws {
        try macStore()
        var bad = try macList()
        bad.keyID = "not a fingerprint"
        #expect(throws: DocumentList.Problem.unreadable) { try DocumentList.read(DocumentList.encoded(bad)) }
        bad = try macList()
        bad.removed = ["../household.key"]
        #expect(throws: DocumentList.Problem.unreadable) { try DocumentList.read(DocumentList.encoded(bad)) }
    }

    @Test func aPhoneSendsHomeOnlyToAMacWhoseListItWouldTake() throws {
        // a Mac with no documents yet serves no list: a phone that never mirrored still sends its first add
        #expect(DocumentMirror.maySend(nil, held: DocumentMirror.held(in: phone)))
        var (store, index) = try macStore()
        let older = try setAside("older")
        #expect(DocumentMirror.maySend(try macList(), held: DocumentMirror.held(in: phone)))
        try addOne(store, &index, "Newest")
        try mirror()
        #expect(DocumentMirror.maySend(try macList(), held: DocumentMirror.held(in: phone)))
        #expect(!DocumentMirror.maySend(nil, held: DocumentMirror.held(in: phone)))  // its Mac lost the store: wait
        try putBack(older)
        #expect(!DocumentMirror.maySend(try macList(), held: DocumentMirror.held(in: phone)))
    }

    // MARK: Use the Mac's Copy

    @Test func useTheMacsCopyLetsTheNextListThroughForThatKeyOnly() throws {
        var (store, index) = try macStore()
        let older = try setAside("older")
        try addOne(store, &index, "Newest")
        try mirror()
        try putBack(older)
        let refusal = try #require(try mirror())
        #expect(DocumentsWords.offersMacsCopy(refusal, ownKeyID: store.keyID))
        #expect(!DocumentsWords.offersMacsCopy(refusal, ownKeyID: nil))  // only while Documents is open
        try DocumentMirror.yield(to: String(repeating: "0", count: 32), root: phone)
        #expect(try mirror() != nil)  // another key's choice lets nothing through
        try DocumentMirror.yield(to: try #require(refusal.keyID), root: phone)
        #expect(try mirror() == nil)
        #expect(try phoneState().files.count == 3)
        #expect(DocumentMirror.yielded(in: phone) == nil)  // used once
        #expect(DocumentMirror.held(in: phone).refused == nil)
    }

    // MARK: The iCloud copy

    func backUp() throws -> DocumentBackup.Outcome {
        DocumentBackup.copy(from: mac, to: backup, list: try macList())
    }

    @Test func theICloudCopyHoldsBackFromAnOlderCopyAndStillFollowsRealRemovals() throws {
        var (store, index) = try macStore()
        try store.writeSpare(password: DocumentSpare.newPassword())
        let older = try setAside("older")
        try addOne(store, &index, "Newest")
        #expect(try backUp() == .copied(files: 4, documents: 4))
        let files = backup.appendingPathComponent("files")
        let before = try FileManager.default.contentsOfDirectory(atPath: files.path).sorted()
        let indexBefore = try FileCheck.sha256(of: backup.appendingPathComponent(DocumentList.indexName))
        try putBack(older)
        #expect(try backUp() == .older(files: 1))
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.path).sorted() == before)
        #expect(try FileCheck.sha256(of: backup.appendingPathComponent(DocumentList.indexName)) == indexBefore)
        DocumentBackup.writeStatus(.older(files: 1), in: mac, now: now)
        let lines = DocumentsWords.backupLines(DocumentBackup.readStatus(in: mac), test: nil, hasSpare: true, now: now)
        #expect(lines[0].text == "Essential Documents: not copied: " + DocumentsWords.backupOlder)
        #expect(lines[0].caution)
        // a real purge on the store as it now is still reaches a copy made from it
        try FileManager.default.removeItem(at: backup)
        index = try store.load()
        try save(store, index)
        #expect(try backUp() == .copied(files: 3, documents: 3))
        index.delete(document: index.documents[0].id, now: now)
        let gone = index.purgeExpired(now: now.addingTimeInterval(31 * 86_400))
        try save(store, index, removing: gone)
        #expect(try backUp() == .copied(files: 0, documents: 2))
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.path).count == 2)
    }
}
