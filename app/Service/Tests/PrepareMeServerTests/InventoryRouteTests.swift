import Foundation
@testable import PrepareMeServer
import PrepareMeShared
import XCTest

/// The inventory on the phones' service (plan phase 7, slice 5): the copy to every paired phone, edits only from a
/// phone that isn't read-only, saved whole into the inbox. A made-up folder in a fresh temporary folder.
final class InventoryRouteTests: XCTestCase {
    var root: URL!
    var inventory: URL!
    var tokens: TokenStore!
    var router: Router!
    var adult = "", childToken = ""
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-inventory-route-\(UUID())")
        inventory = root.appendingPathComponent("inventory")
        try FileManager.default.createDirectory(at: inventory, withIntermediateDirectories: true)
        tokens = TokenStore(url: root.appendingPathComponent("tokens.json"))
        adult = try tokens.add(now: now).token
        childToken = try tokens.add(now: now, readOnly: true).token
        router = Router(folder: root, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                        manifestOnly: true, inventory: inventory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func ask(_ method: String, _ path: String, _ token: String?, body: Data = Data()) -> Reply {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer " + token }
        return router.reply(to: HTTPRequest(method: method, path: path, headers: headers, body: body), now: now).0
    }

    func header(_ reply: Reply, _ name: String) -> String? {
        if case let .bytes(_, headers, _) = reply { return headers.first { $0.0 == name }?.1 }
        return nil
    }

    var inboxNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inventory.appendingPathComponent("inbox").path)) ?? [])
            .sorted()
    }

    func testTheCopyGoesToEveryPairedPhoneSayingWhetherItMayEdit() throws {
        XCTAssertEqual(ask("GET", "/inventory.json", adult).status, 404)  // none written yet
        try Data(#"{"made":"up"}"#.utf8).write(to: inventory.appendingPathComponent(PhoneInventory.fileName))
        let toAdult = ask("GET", "/inventory.json", adult), toChild = ask("GET", "/inventory.json", childToken)
        XCTAssertEqual(toAdult.status, 200)
        XCTAssertEqual(header(toAdult, "X-PrepareMe-Edits"), "yes")
        XCTAssertEqual(header(toChild, "X-PrepareMe-Edits"), "no")
        XCTAssertEqual(ask("GET", "/inventory.json", nil).status, 401)
    }

    /// Plan phase 8: the list a phone gets leaves out a download the Mac keeps for itself, and asking for it by name
    /// gets nothing.
    func testAPhoneIsNeverOfferedADownloadTheMacKeepsForItself() throws {
        func line(_ name: String, family: Bool) -> Manifest.Entry {
            Manifest.Entry(name: name, id: "0f1e2d3c-4b5a-4968-8776-00000000000\(family ? 1 : 2)", kind: "download",
                           size: 4, sha256: String(repeating: "a", count: 64), deliveredAt: "2026-10-14T12:00:00Z",
                           family: family, title: name)
        }
        let list = Manifest(writtenAt: "2026-10-14T12:00:00Z",
                            files: [line("family.zim", family: true), line("mine.zim", family: false)])
        try JSONEncoder().encode(list).write(to: root.appendingPathComponent("manifest.json"))
        for name in ["family.zim", "mine.zim"] { try Data("zim!".utf8).write(to: root.appendingPathComponent(name)) }
        guard case let .bytes(200, _, body) = ask("GET", "/manifest.json", childToken) else { return XCTFail("no list") }
        XCTAssertEqual(try Manifest.read(body).files.map(\.name), ["family.zim"])
        XCTAssertEqual(ask("GET", "/files/family.zim", childToken).status, 200)
        XCTAssertEqual(ask("GET", "/files/mine.zim", adult).status, 404)
    }

    func testEditsAreSavedWholeIntoTheInboxAndAChildsAreStampedAsAChilds() throws {
        // with the phone's own id, which reaches the Mac's inbox as sent (F-095)
        let edits = PhoneEdits(edits: [PhoneEdit(change: .adjust(row: 3, by: -1))], device: UUID().uuidString)
        let body = try JSONEncoder().encode(edits)
        // a child's phone's are taken since 2026-11-12 (it adds pins and removes its own): stamped by the service
        // from the pairing, whatever the phone said, so the Mac's rules refuse the rest (PhoneRules.childRefusal)
        var lying = edits
        lying.child = false
        XCTAssertEqual(ask("POST", HTTP.editsPath, childToken, body: try JSONEncoder().encode(lying)).status, 202)
        let inbox = inventory.appendingPathComponent("inbox")
        XCTAssertEqual(PhoneEdits.read(try Data(contentsOf: inbox.appendingPathComponent(inboxNames[0])))?.child, true)
        try FileManager.default.removeItem(at: inbox.appendingPathComponent(inboxNames[0]))
        var claiming = edits
        claiming.child = true  // and an adult's phone is never made a child's by what it sends
        XCTAssertEqual(ask("POST", HTTP.editsPath, adult, body: Data("nonsense".utf8)).status, 400)
        XCTAssertEqual(ask("POST", HTTP.editsPath, adult, body: try JSONEncoder().encode(claiming)).status, 202)
        XCTAssertEqual(inboxNames.count, 1)
        XCTAssertTrue(inboxNames[0].contains("-phone1-"))
        let saved = try Data(contentsOf: inventory.appendingPathComponent("inbox").appendingPathComponent(inboxNames[0]))
        XCTAssertEqual(PhoneEdits.read(saved), edits)
        XCTAssertEqual(ask("GET", HTTP.editsPath, adult).status, 405)
    }

    func testAFullInboxAnswersBusyAndTheEditsStayOnThePhone() throws {
        let inbox = inventory.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for n in 0..<Router.inboxMaxFiles {
            try Data().write(to: inbox.appendingPathComponent("\(n).json"))
        }
        let body = try JSONEncoder().encode(PhoneEdits(edits: [PhoneEdit(change: .adjust(row: 3, by: -1))]))
        XCTAssertEqual(ask("POST", HTTP.editsPath, adult, body: body).status, 503)
        XCTAssertEqual(inboxNames.count, Router.inboxMaxFiles)
    }

    func testAServiceWithoutTheInventoryHasNoSuchRoutes() {
        router = Router(folder: root, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")))
        XCTAssertEqual(ask("GET", "/inventory.json", adult).status, 404)
        XCTAssertEqual(ask("POST", HTTP.editsPath, adult, body: Data("{}".utf8)).status, 404)
    }

    func testOnlyTheEditsPathTakesALargerBody() {
        func head(_ path: String, _ length: Int) -> HeadParse {
            HTTP.parseHead(Data("POST \(path) HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8))
        }
        if case .refused(413) = head("/counts", 2048) {} else { XCTFail("counts over 1 KB") }
        if case .request = head(HTTP.editsPath, 200_000) {} else { XCTFail("edits under 256 KB") }
        if case .refused(413) = head(HTTP.editsPath, 300_000) {} else { XCTFail("edits over 256 KB") }
    }

    func testOlderPhoneListsReadAsAdultsPhones() throws {
        let older = #"{"phones":[{"added":"2026-10-13T00:00:00Z","label":"phone 1","sha256":"00"}]}"#
        try Data(older.utf8).write(to: root.appendingPathComponent("old.json"))
        XCTAssertNil(try TokenStore(url: root.appendingPathComponent("old.json")).phones().first?.readOnly)
    }
}
