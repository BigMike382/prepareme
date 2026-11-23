import Foundation
@testable import PrepareMeServer
import PrepareMeShared
import XCTest

/// The router answering requests directly, no network: a made-up served folder in a fresh temporary folder.
final class RouterTests: XCTestCase {
    var root: URL!
    var served: URL!
    var tokens: TokenStore!
    var counts: CountsStore!
    var router: Router!
    var token = ""
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-router-\(UUID())")
        served = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        tokens = TokenStore(url: root.appendingPathComponent("tokens.json"))
        token = try tokens.add(now: now).token
        counts = CountsStore(url: root.appendingPathComponent("probe-counts.json"))
        router = Router(folder: served, tokens: tokens, counts: counts)
        try ProbeFile.swap(folder: served, id: "probe-test", bytes: 1000, now: now)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func request(_ path: String, token: String? = nil, headers: [String: String] = [:]) -> HTTPRequest {
        request("GET", path, token: token, headers: headers)
    }

    func request(_ method: String, _ path: String, token: String? = nil, headers: [String: String] = [:],
                 body: Data = Data()) -> HTTPRequest {
        var all = headers
        if let token { all["authorization"] = "Bearer " + token }
        return HTTPRequest(method: method, path: path, headers: all, body: body)
    }

    func reply(_ request: HTTPRequest) -> Reply {
        router.reply(to: request, now: now).0
    }

    func header(_ reply: Reply, _ name: String) -> String? {
        let headers: [(String, String)]
        switch reply {
        case let .bytes(_, found, _), let .file(_, found, _, _, _, _): headers = found
        }
        return headers.first { $0.0 == name }?.1
    }

    func closing(_ reply: Reply) -> Reply {
        if case let .file(_, _, handle, _, _, _) = reply { try? handle.close() }
        return reply
    }

    func file(_ headers: [String: String] = [:]) -> Reply {
        closing(reply(request("/files/\(ProbeFile.name)", token: token, headers: headers)))
    }

    func testTheManifestComesBackWithTheFilesOwnBytes() throws {
        let answer = reply(request("/manifest.json", token: token))
        guard case let .bytes(200, _, body) = answer else { return XCTFail("not 200 bytes") }
        XCTAssertEqual(body, try Data(contentsOf: served.appendingPathComponent("manifest.json")))
        XCTAssertEqual(header(answer, "Content-Length"), String(body.count))
    }

    func testAFileComesBackWholeWithItsLengthAndETag() throws {
        let answer = file()
        guard case let .file(200, _, _, offset, length, _) = answer else { return XCTFail("not a 200 file") }
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(length, 1000)
        XCTAssertEqual(header(answer, "Content-Length"), "1000")
        XCTAssertNotNil(header(answer, "ETag"))
    }

    func testARangeComesBackAs206WithItsContentRange() {
        let answer = file(["range": "bytes=10-19"])
        guard case let .file(206, _, _, offset, length, _) = answer else { return XCTFail("not a 206 file") }
        XCTAssertEqual(offset, 10)
        XCTAssertEqual(length, 10)
        XCTAssertEqual(header(answer, "Content-Range"), "bytes 10-19/1000")
        XCTAssertEqual(header(answer, "Content-Length"), "10")
    }

    func testARangePastTheEndIs416() {
        let answer = file(["range": "bytes=5000-"])
        XCTAssertEqual(answer.status, 416)
        XCTAssertEqual(header(answer, "Content-Range"), "bytes */1000")
    }

    func testAnIfRangeThatIsNotTheETagGetsTheWholeFileAndOneThatIsGetsThePart() throws {
        let tag = try XCTUnwrap(header(file(), "ETag"))
        XCTAssertEqual(file(["range": "bytes=10-19", "if-range": "\"other\""]).status, 200)
        XCTAssertEqual(file(["range": "bytes=10-19", "if-range": tag]).status, 206)
    }

    func testPathsThatCouldReachOutsideTheFolderOrAreNotFilesAre404() throws {
        try Data("x".utf8).write(to: served.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: served.appendingPathComponent("link.bin"),
                                                   withDestinationURL: root.appendingPathComponent("tokens.json"))
        for path in ["/files/../tokens.json", "/files/.hidden", "/files/manifest.json", "/files/missing",
                     "/files/link.bin", "/files/"] {
            XCTAssertEqual(closing(reply(request(path, token: token))).status, 404, path)
        }
    }

    func testAGoodCountsReportIs204AndIsKeptUnderThePhonesLabel() throws {
        let report = CountsReport(at: "2026-10-12T21:07Z", counts: AlertCounts(alerts: 1, events: 1, noVTEC: 0))
        let answer = reply(request("POST", "/counts", token: token, body: try report.encoded()))
        XCTAssertEqual(answer.status, 204)
        let kept = try XCTUnwrap(counts.readings()["phone 1"])
        XCTAssertEqual(kept.map(\.at), ["2026-10-12T21:07Z"])
        XCTAssertEqual(kept.first?.alerts, 1)
    }

    func testABadCountsReportIs400AndKeepsNothing() {
        let answer = reply(request("POST", "/counts", token: token, body: Data("{\"at\":1}".utf8)))
        XCTAssertEqual(answer.status, 400)
        XCTAssertTrue(counts.readings().isEmpty)
    }

    func testTheWrongMethodIs405AndAnUnknownPathIs404() {
        XCTAssertEqual(reply(request("GET", "/counts", token: token)).status, 405)
        XCTAssertEqual(reply(request("POST", "/manifest.json", token: token)).status, 405)
        XCTAssertEqual(reply(request("POST", "/files/\(ProbeFile.name)", token: token)).status, 405)
        XCTAssertEqual(reply(request("GET", "/nothing", token: token)).status, 404)
    }

    func testEveryEndpointIs401WithoutAGoodToken() throws {
        let removed = try tokens.add(now: now)
        XCTAssertTrue(try tokens.remove(label: removed.label))
        let paths = [("GET", "/manifest.json"), ("GET", "/files/\(ProbeFile.name)"), ("POST", "/counts"),
                     ("GET", "/nothing"), ("GET", "/files/../tokens.json")]
        let credentials: [String?] = [nil, "Bearer ", "Bearer " + Token.make(), "Basic " + token,
                                      "Bearer " + removed.token, token]
        for (method, path) in paths {
            for credential in credentials {
                var headers: [String: String] = [:]
                if let credential { headers["authorization"] = credential }
                let answer = closing(reply(HTTPRequest(method: method, path: path, headers: headers)))
                XCTAssertEqual(answer.status, 401, "\(method) \(path) \(credential ?? "none")")
            }
        }
    }

    func testAnUnknownPathIs404WithATokenAndTheLabelIsReturned() {
        let (answer, label) = router.reply(to: request("/nothing", token: token), now: now)
        XCTAssertEqual(answer.status, 404)
        XCTAssertEqual(label, "phone 1")
    }

    /// A phone's first request with its code ends its wait (Task 13.2; F42; the phase 13 review: the clerk's test had
    /// called the store directly).
    func testARequestEndsAPhonesWait() throws {
        XCTAssertEqual(try tokens.phones().map(\.waiting), [true])
        _ = router.reply(to: request("/manifest.json", token: token), now: now)
        XCTAssertEqual(try tokens.phones().map(\.waiting), [nil])
        _ = router.reply(to: request("/manifest.json", token: "not-a-phone"), now: now)
        XCTAssertEqual(try tokens.phones().count, 1)
    }

    /// Unlisted plan, phase 3: the family's Mac's service refuses PrepareMe Dev before looking at its token, so a Dev
    /// copy holding a real token is never counted as a visit; a test service serves it; the family's app (no header)
    /// is served as ever.
    func testOnlyATestServiceServesPrepareMeDev() throws {
        let dev = [DevCopy.header.lowercased(): DevCopy.value]
        let refusal = reply(request("/manifest.json", token: token, headers: dev))
        guard case let .bytes(status, _, body) = refusal else { return XCTFail("not a status") }
        XCTAssertEqual(status, 403)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual(header(refusal, DevCopy.refusedHeader), DevCopy.value)
        XCTAssertNil(router.reply(to: request("/manifest.json", token: token, headers: dev), now: now).1)  // no label
        XCTAssertEqual(try tokens.phones().map(\.waiting), [true])  // not a visit
        guard case let .bytes(family, _, _) = reply(request("/manifest.json", token: token)) else { return XCTFail() }
        XCTAssertEqual(family, 200)

        let test = Router(folder: served, tokens: tokens, counts: counts, servesDev: true)
        guard case let .bytes(served, _, _) = test.reply(to: request("/manifest.json", token: token, headers: dev),
                                                         now: now).0 else { return XCTFail("not a status") }
        XCTAssertEqual(served, 200)
    }

    /// Writers at the same moment never undo each other: a visit from the request queue while phones are paired and
    /// removed (the phase 13 review: tokens.json had no lock, and a lost write could drop a new phone or bring a
    /// removed one back).
    func testWritesAtTheSameMomentKeepEachOther() throws {
        let second = try tokens.add(now: now).token
        let added = DispatchQueue(label: "added"), visits = DispatchQueue(label: "visits")
        let group = DispatchGroup()
        for _ in 0..<20 {
            added.async(group: group) { _ = try? self.tokens.add(now: self.now) }
            visits.async(group: group) {
                if let phone = self.tokens.phone(for: second) { try? self.tokens.visited(phone) }
            }
        }
        group.wait()
        XCTAssertEqual(try tokens.phones().count, 22, "every phone paired is still there")
        XCTAssertNil(tokens.phone(for: second)?.waiting, "and the visit held")
    }
}
