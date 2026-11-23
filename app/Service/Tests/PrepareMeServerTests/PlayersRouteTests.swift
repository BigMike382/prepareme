import Foundation
@testable import PrepareMeServer
@testable import PrepareMeShared
import XCTest

/// The player list on the devices' service (players plan, stage 2): `GET /players.json` to every paired device, a
/// child's too, under the same token as the inventory, read only, within `PlayerList`'s limits. The home-network
/// limit is the connection's, the same for every route (`FileServer.accept`, `HTTPTests`); here the live run reads
/// the service's whole log for the made-up nicknames. A made-up folder in a fresh temporary folder.
final class PlayersRouteTests: XCTestCase {
    var root: URL!
    var inventory: URL!
    var tokens: TokenStore!
    var router: Router!
    var adult = "", child = ""
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Made-up nicknames, assembled from pieces (as `PlayersTests`).
    let names = ["Wil" + "low", "Ce" + "dar", "As" + "pen"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-players-route-\(UUID())")
        inventory = root.appendingPathComponent("inventory")
        try FileManager.default.createDirectory(at: inventory, withIntermediateDirectories: true)
        tokens = TokenStore(url: root.appendingPathComponent("tokens.json"))
        adult = try tokens.add(now: now).token
        child = try tokens.add(now: now, readOnly: true).token
        router = Router(folder: root, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                        manifestOnly: true, inventory: inventory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func household() throws -> PlayerList {
        var list = PlayerList()
        try list.add(names[0], color: .violet)
        try list.add(names[1], color: .brown)
        try list.add(names[2], color: .slate)
        try list.retire(3)
        return list
    }

    func ask(_ method: String, _ path: String, _ token: String?) -> Reply {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer " + token }
        return router.reply(to: HTTPRequest(method: method, path: path, headers: headers, body: Data()), now: now).0
    }

    func body(_ reply: Reply) -> Data? {
        if case let .bytes(_, _, data) = reply { return data }
        return nil
    }

    func testEveryPairedDeviceGetsTheListAChildsToo() throws {
        XCTAssertEqual(ask("GET", "/players.json", adult).status, 404)  // the Mac hasn't written its copy yet
        let list = try household()
        try list.save(inventory, as: PlayerList.phoneFileName)
        for token in [adult, child] {
            let reply = ask("GET", "/players.json", token)
            XCTAssertEqual(reply.status, 200)
            XCTAssertEqual(PlayerList.read(body(reply)), list)
        }
        XCTAssertEqual(ask("GET", "/players.json", nil).status, 401)
        XCTAssertEqual(ask("GET", "/players.json", "a-token-no-device-holds").status, 401)
        _ = try tokens.remove(label: tokens.phones()[1].label)  // a device the Mac no longer knows
        XCTAssertEqual(ask("GET", "/players.json", child).status, 401)
        XCTAssertEqual(ask("POST", "/players.json", adult).status, 405, "read only: nothing from a device to the Mac")
        XCTAssertEqual(ask("PUT", "/players.json", adult).status, 405)
    }

    func testACopyOutsideTheLimitsIsNeverServed() throws {
        let url = inventory.appendingPathComponent(PlayerList.phoneFileName)
        let good = try household().encoded()
        try (good + Data(repeating: 0x20, count: PlayerList.fileLimit)).write(to: url)
        XCTAssertEqual(ask("GET", "/players.json", adult).status, 500, "over the size limit")
        try Data("damaged".utf8).write(to: url)
        XCTAssertEqual(ask("GET", "/players.json", adult).status, 500)
        try Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "violet", with: "red").utf8).write(to: url)
        XCTAssertEqual(ask("GET", "/players.json", adult).status, 500, "a color that isn't a player's")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(ask("GET", "/players.json", adult).status, 404, "a folder by that name is no copy")
    }

    func testAServiceWithNoInventoryFolderServesNoList() throws {
        let bare = Router(folder: root, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c2.json")),
                          manifestOnly: true)
        let request = HTTPRequest(method: "GET", path: "/players.json", headers: ["authorization": "Bearer " + adult],
                                  body: Data())
        XCTAssertEqual(bare.reply(to: request, now: now).0.status, 404)
    }

    /// The real service on 127.0.0.1 over TLS, as a device asks: the list arrives whole, and no nickname reaches
    /// the service's log, from either device or a refused ask.
    func testTheLiveServiceLogsNoNickname() async throws {
        let list = try household()
        try list.save(inventory, as: PlayerList.phoneFileName)
        try Identity.make(in: root)
        let (identity, pin) = try Identity.load(from: root)
        let lines = LogLines()
        let server = FileServer(router: router, identity: identity, port: 0, loopbackOnly: true, log: lines.add)
        let started = expectation(description: "listening")
        try server.start { problem in
            XCTAssertNil(problem)
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 10)
        defer { server.stop() }
        let base = URL(string: "https://127.0.0.1:\(server.boundPort!)")!
        let session = URLSession(configuration: .ephemeral, delegate: Pinned(pin: pin), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for token in [adult, child, "a-token-no-device-holds"] {
            var request = URLRequest(url: base.appendingPathComponent("players.json"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as! HTTPURLResponse).statusCode
            XCTAssertEqual(status, token.hasPrefix("a-token") ? 401 : 200)
            if status == 200 { XCTAssertEqual(PlayerList.read(data), list) }
        }
        try await Task.sleep(for: .milliseconds(300))  // the log's last lines
        let log = lines.all.joined(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.all.count, 3, "the log was read: \(log)")  // a line a request
        for name in names { XCTAssertFalse(log.localizedCaseInsensitiveContains(name)) }
    }
}

/// The service's log lines, as its `log` closure hands them over (from its own queue).
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
