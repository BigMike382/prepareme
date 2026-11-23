import CryptoKit
import Foundation
@testable import PrepareMeServer
import PrepareMeShared
import XCTest

/// Essential Documents on the phones' service (phase 3): an adult's phone asks with its lock, gets the store only once
/// the owner has given it the key, and sends its encrypted changes into the inbox; a child's phone gets nothing. A
/// made-up store in a fresh temporary folder.
final class DocumentsRouteTests: XCTestCase {
    var root: URL!
    var documents: URL!
    var pairing: URL!
    var tokens: TokenStore!
    var router: Router!
    var adult = "", childToken = "", other = ""
    var adultPhone: TokenStore.Phone!
    let key = SymmetricKey(size: .bits256)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-documents-route-\(UUID())")
        documents = root.appendingPathComponent("documents")
        pairing = root.appendingPathComponent("pairing")
        try FileManager.default.createDirectory(at: pairing, withIntermediateDirectories: true)
        tokens = TokenStore(url: root.appendingPathComponent("tokens.json"))
        adult = try tokens.add(now: now).token
        childToken = try tokens.add(now: now, readOnly: true).token
        other = try tokens.add(now: now).token
        adultPhone = tokens.phone(for: adult)
        router = Router(folder: root, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                        manifestOnly: true, pairing: pairing, documents: documents)
        let store = DocumentStore(root: documents, key: key)
        var index = DocumentIndex()
        try store.add(Data("made-up deed".utf8), named: "Deed (FAKE)", type: "pdf", to: nil, in: &index, now: now)
        try store.save(index)
        try Data("sealed elsewhere".utf8).write(to: documents.appendingPathComponent("household.key"))
        try DocumentList.refresh(root: documents)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func ask(_ method: String, _ path: String, _ token: String?, body: Data = Data(),
             headers: [String: String] = [:]) -> Reply {
        var all = headers
        if let token { all["authorization"] = "Bearer " + token }
        let reply = router.reply(to: HTTPRequest(method: method, path: path, headers: all, body: body), now: now).0
        if case let .file(_, _, handle, _, _, _) = reply { try? handle.close() }
        return reply
    }

    func body(_ reply: Reply) -> Data {
        if case let .bytes(_, _, body) = reply { return body }
        return Data()
    }

    func header(_ reply: Reply, _ name: String) -> String? {
        switch reply {
        case let .bytes(_, headers, _), let .file(_, headers, _, _, _, _): headers.first { $0.0 == name }?.1
        }
    }

    var lock = P256.KeyAgreement.PrivateKey()

    func askForTheKey(_ token: String) -> Reply {
        let request = DocumentHandoff.Request(key: lock.publicKey.rawRepresentation)
        return ask("POST", "/documents/key-request", token, body: try! JSONEncoder().encode(request))
    }

    /// The owner's Give This Phone Essential Documents, as the Mac app writes it.
    func give(_ phone: TokenStore.Phone) throws {
        let requests = DocumentHandoff.readRequests(try? Data(contentsOf: pairing.appendingPathComponent(DocumentHandoff.requestsName)))
        let request = try XCTUnwrap(DocumentHandoff.request(requests, label: phone.label, paired: phone.added))
        let gift = try DocumentHandoff.seal(key, for: request, label: phone.label, paired: phone.added, now: now)
        try DocumentHandoff.encoded([phone.label: gift]).write(to: pairing.appendingPathComponent(DocumentHandoff.giftsName))
    }

    func testNothingReachesAPhoneUntilTheOwnerGivesIt() throws {
        for path in ["/documents/list.json", "/documents/files/index.pmdoc"] {
            XCTAssertEqual(ask("GET", path, adult).status, 403)
        }
        XCTAssertEqual(ask("GET", "/documents/key", adult).status, 404)
        XCTAssertEqual(askForTheKey(adult).status, 204)
        XCTAssertEqual(ask("GET", "/documents/key", adult).status, 404)  // asked, not yet given
        try give(adultPhone)
        let served = try JSONDecoder().decode(DocumentHandoff.Served.self, from: body(ask("GET", "/documents/key", adult)))
        let file = DocumentKeyFile(lock: Data(), ephemeral: served.ephemeral, sealed: served.sealed)
        let opened = try file.open { try lock.sharedSecretFromKeyAgreement(with: $0) }
        XCTAssertEqual(opened.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        XCTAssertEqual(ask("GET", "/documents/list.json", adult).status, 200)
        // another adult's phone, not given it, still gets nothing
        XCTAssertEqual(ask("GET", "/documents/list.json", other).status, 403)
        XCTAssertEqual(ask("GET", "/documents/key", other).status, 404)
    }

    func testAChildsPhoneGetsNothingAndNoPhoneWithoutAToken() throws {
        for path in ["/documents/list.json", "/documents/key", "/documents/files/index.pmdoc"] {
            XCTAssertEqual(ask("GET", path, childToken).status, 403)
            XCTAssertEqual(ask("GET", path, nil).status, 401)
        }
        XCTAssertEqual(askForTheKey(childToken).status, 403)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairing.appendingPathComponent(DocumentHandoff.requestsName).path))
    }

    /// Family downloads plan, phase 2: with the file gates gone from a child's device, the Mac still gives it nothing of
    /// Essential Documents: no word of them in its list, an inventory answer saying it may not edit (an adult's phone's
    /// Documents tab comes only from that), none of the store's files through /files/, and 403 for /documents/….
    func testAChildsDeviceStillGetsNoEssentialDocumentsAfterTheFileGatesCameOff() throws {
        let inventory = root.appendingPathComponent("inventory")
        try FileManager.default.createDirectory(at: inventory, withIntermediateDirectories: true)
        try Data(#"{"made":"up"}"#.utf8).write(to: inventory.appendingPathComponent(PhoneInventory.fileName))
        let family = Manifest.Entry(name: "family.zim", id: "0f1e2d3c-4b5a-4968-8776-000000000001", kind: "download",
                                    size: 4, sha256: String(repeating: "a", count: 64),
                                    deliveredAt: "2026-10-14T12:00:00Z", family: true, title: "Family")
        try JSONEncoder().encode(Manifest(writtenAt: "2026-10-14T12:00:00Z", files: [family]))
            .write(to: root.appendingPathComponent("manifest.json"))
        router = Router(folder: root, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                        manifestOnly: true, inventory: inventory, pairing: pairing, documents: documents)

        let list = body(ask("GET", "/manifest.json", childToken))
        XCTAssertEqual(try Manifest.read(list).files.map(\.name), ["family.zim"])
        XCTAssertFalse(String(decoding: list, as: UTF8.self).lowercased().contains("document"))
        XCTAssertEqual(header(ask("GET", "/inventory.json", childToken), "X-PrepareMe-Edits"), "no")
        XCTAssertEqual(header(ask("GET", "/inventory.json", adult), "X-PrepareMe-Edits"), "yes")
        for name in ["index.pmdoc", "list.json", "household.key", "documents"] {
            XCTAssertEqual(ask("GET", "/files/\(name)", childToken).status, 404, name)
        }
        for path in ["/documents/list.json", "/documents/key", "/documents/files/index.pmdoc", "/documents/inbox"] {
            XCTAssertEqual(ask("GET", path, childToken).status, 403, path)
        }
        XCTAssertEqual(askForTheKey(childToken).status, 403)
    }

    func testTheAskIsKeptStampedWithThePairingAndABadOneIsRefused() throws {
        XCTAssertEqual(askForTheKey(adult).status, 204)
        let kept = DocumentHandoff.readRequests(try Data(contentsOf: pairing.appendingPathComponent(DocumentHandoff.requestsName)))
        XCTAssertEqual(kept[adultPhone.label]?.key, lock.publicKey.rawRepresentation)
        XCTAssertEqual(kept[adultPhone.label]?.paired, adultPhone.added)
        XCTAssertEqual(ask("POST", "/documents/key-request", adult, body: Data("{}".utf8)).status, 400)
        XCTAssertEqual(ask("GET", "/documents/key-request", adult).status, 405)
    }

    func testOnlyWhatTheListNamesIsServedNeverTheKeyFile() throws {
        XCTAssertEqual(askForTheKey(adult).status, 204)
        try give(adultPhone)
        let list = try DocumentList.read(body(ask("GET", "/documents/list.json", adult)))
        let index = ask("GET", "/documents/files/index.pmdoc", adult)
        XCTAssertEqual(index.status, 200)
        XCTAssertEqual(header(index, "Content-Length"), String(list.index.size))
        let first = ask("GET", "/documents/files/\(list.files[0].name)", adult, headers: ["range": "bytes=0-9"])
        XCTAssertEqual(first.status, 206)
        for name in ["household.key", "list.json", "../household.key", "\(UUID().uuidString.lowercased()).pmdoc"] {
            XCTAssertEqual(ask("GET", "/documents/files/\(name)", adult).status, 404, name)
        }
    }

    func testChangesAndUploadsGoIntoTheInboxInOrder() throws {
        XCTAssertEqual(askForTheKey(adult).status, 204)
        try give(adultPhone)
        XCTAssertEqual(ask("POST", "/documents/changes", adult, body: Data("sealed outbox".utf8)).status, 202)
        let inbox = documents.appendingPathComponent(DocumentInbox.folderName)
        XCTAssertEqual(DocumentInbox.waitingOutboxes(root: documents), 1)
        let name = UUID().uuidString.lowercased() + ".pmdoc"
        XCTAssertEqual(header(ask("GET", "/documents/upload/\(name)", adult), HTTP.haveHeader), "0")
        let first = ask("POST", "/documents/upload/\(name)/0", adult, body: Data("abc".utf8))
        XCTAssertEqual(first.status, 204)
        XCTAssertEqual(header(first, HTTP.haveHeader), "3")
        let wrong = ask("POST", "/documents/upload/\(name)/0", adult, body: Data("abc".utf8))  // sent again
        XCTAssertEqual(wrong.status, 409)
        XCTAssertEqual(header(wrong, HTTP.haveHeader), "3")
        XCTAssertEqual(ask("POST", "/documents/upload/\(name)/3", adult, body: Data("def".utf8)).status, 204)
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent(name)), Data("abcdef".utf8))
        XCTAssertEqual(ask("POST", "/documents/upload/not-a-name/0", adult, body: Data("x".utf8)).status, 404)
        XCTAssertEqual(ask("POST", "/documents/upload/\(name)/x", adult, body: Data("x".utf8)).status, 400)
        // a phone not given the key sends nothing
        XCTAssertEqual(ask("POST", "/documents/changes", other, body: Data("x".utf8)).status, 403)
    }

    func testThePhonesStandingIsKeptByLabelAndPairing() throws {
        XCTAssertEqual(askForTheKey(adult).status, 204)
        try give(adultPhone)
        let report = Data(#"{"matching":1,"all":1,"index":true,"waiting":0}"#.utf8)
        XCTAssertEqual(ask("POST", "/documents/status", adult, body: report).status, 204)
        let all = DocumentsPhoneReport.readAll(try Data(contentsOf: pairing.appendingPathComponent(DocumentHandoff.statusName)))
        XCTAssertEqual(all[adultPhone.label]?.paired, adultPhone.added)
        XCTAssertEqual(all[adultPhone.label]?.inStep, true)
        XCTAssertEqual(ask("POST", "/documents/status", adult, body: Data("{}".utf8)).status, 400)
    }

    func testTheBodyLimitsOfTheDocumentsPaths() {
        func head(_ path: String, _ length: Int) -> HeadParse {
            HTTP.parseHead(Data("POST \(path) HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8))
        }
        if case .refused = head("/documents/changes", DocumentOutbox.maxBytes) { XCTFail("an outbox fits") }
        XCTAssertEqual(head("/documents/changes", DocumentOutbox.maxBytes + 1), .refused(413))
        if case .refused = head("/documents/upload/a/0", DocumentInbox.maxPiece) { XCTFail("a piece fits") }
        XCTAssertEqual(head("/documents/upload/a/0", DocumentInbox.maxPiece + 1), .refused(413))
        XCTAssertEqual(head("/documents/status", 1025), .refused(413))
    }
}
