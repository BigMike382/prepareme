import Foundation
@testable import PrepareMeServer
import PrepareMeShared
import Testing

/// Unlisted plan, phase 4 (decision 4): the library service hands the Mac app's barcode keys to an adult's paired
/// device at `/lookup-keys.json`; a child's device, an unpaired one and the probe's service get none. Made-up keys,
/// a fresh temporary folder, no network.
@Suite struct LookupKeysRouteTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-keys-\(UUID())")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func router(_ keys: LookupKeys?, manifestOnly: Bool = true) throws -> (Router, adult: String, child: String) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tokens = TokenStore(url: root.appendingPathComponent("tokens-\(UUID()).json"))
        let adult = try tokens.add(now: now).token
        let child = try tokens.add(now: now, readOnly: true).token
        return (Router(folder: root, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                       manifestOnly: manifestOnly, lookupKeys: keys), adult, child)
    }

    func ask(_ router: Router, _ token: String?, method: String = "GET") -> Reply {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer " + token }
        return router.reply(to: HTTPRequest(method: method, path: LookupKeys.path, headers: headers, body: Data()),
                            now: now).0
    }

    @Test func anAdultsDeviceGetsTheKeysNeverCached() throws {
        let (router, adult, _) = try router(LookupKeys(usda: "madeUpUsda1", upcdb: "madeUpUpc2"))
        guard case let .bytes(status, headers, body) = ask(router, adult) else { Issue.record("no bytes"); return }
        #expect(status == 200)
        #expect(headers.contains { $0 == ("Cache-Control", "no-store") })
        #expect(try LookupKeys.read(body) == LookupKeys(usda: "madeUpUsda1", upcdb: "madeUpUpc2"))
    }

    @Test func noKeysIsAnEmptyAnswerSoTheDeviceLetsGoOfItsOwn() throws {
        let (router, adult, _) = try router(nil)
        guard case let .bytes(status, _, body) = ask(router, adult) else { Issue.record("no bytes"); return }
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self) == "{}")
    }

    @Test func aChildsAnUnpairedDeviceAndOtherMethodsGetNothing() throws {
        let (router, _, child) = try router(LookupKeys(usda: "madeUpUsda1"))
        #expect(ask(router, child).status == 403)
        #expect(ask(router, nil).status == 401)
        #expect(ask(router, "not a token").status == 401)
        let (again, adult, _) = try self.router(LookupKeys(usda: "madeUpUsda1"))
        #expect(ask(again, adult, method: "POST").status == 405)
        let (probe, probeAdult, _) = try self.router(LookupKeys(usda: "madeUpUsda1"), manifestOnly: false)
        #expect(ask(probe, probeAdult).status == 404, "the probe's service never has them")
    }

    @Test func theKeysShapes() throws {
        #expect(LookupKeys(usda: "DEMO_KEY", upcdb: "$(PREPAREME_UPCDB_KEY)") == LookupKeys())
        #expect(LookupKeys(usda: " abc123 \n").usda == "abc123")
        #expect(LookupKeys(usda: "made up").usda == nil)
        #expect(LookupKeys(info: [ProductLookup.keyEntry: "abc", ProductLookup.upcdbKeyEntry: ""]) == LookupKeys(usda: "abc"))
        #expect(try LookupKeys.read(Data(#"{"usda":"a b","upcdb":"ok9","later":"x"}"#.utf8)) == LookupKeys(upcdb: "ok9"))
        #expect(throws: (any Error).self) { try LookupKeys.read(Data("[]".utf8)) }
    }
}
