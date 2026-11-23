import CryptoKit
import Foundation
@testable import PrepareMeServer
import PrepareMeShared
import XCTest

/// The library service of plan phase 4 (`prepareme-service library`): the router serves only the files its folder's
/// manifest names (phase 2's deferred minor), and the bend-once switch changes one byte of one reply, never the file.
/// Made-up files in a fresh temporary folder, no network.
final class LibraryModeTests: XCTestCase {
    var root: URL!
    var served: URL!
    var tokens: TokenStore!
    var bend: BendOnce!
    var router: Router!
    var token = ""
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let bytes = Data((0..<1000).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-library-\(UUID())")
        served = root.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        tokens = TokenStore(url: root.appendingPathComponent("tokens.json"))
        token = try tokens.add(now: now).token
        bend = BendOnce(url: root.appendingPathComponent(BendOnce.name))
        router = Router(folder: served, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                        manifestOnly: true, bend: bend)
        try bytes.write(to: served.appendingPathComponent("listed.zim"))
        try bytes.write(to: served.appendingPathComponent("not-listed.zim"))
        try writeManifest(["listed.zim"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func writeManifest(_ names: [String]) throws {
        let files = names.map {
            Manifest.Entry(name: $0, id: "0f1e2d3c-4b5a-4968-8776-655443322110", kind: "library", size: 1000,
                           sha256: String(repeating: "a", count: 64), deliveredAt: "2026-10-13T12:00:00-04:00")
        }
        try Manifest(writtenAt: "2026-10-13T12:00:00-04:00", files: files).encoded()
            .write(to: served.appendingPathComponent("manifest.json"))
    }

    func get(_ name: String, headers: [String: String] = [:]) -> Reply {
        var all = headers
        all["authorization"] = "Bearer " + token
        let answer = router.reply(to: HTTPRequest(method: "GET", path: "/files/\(name)", headers: all), now: now).0
        if case let .file(_, _, handle, _, _, _) = answer { try? handle.close() }
        return answer
    }

    func bent(_ reply: Reply) -> UInt64? {
        guard case let .file(_, _, _, _, _, bend) = reply else { return nil }
        return bend
    }

    func servedList() throws -> Manifest {
        let reply = router.reply(to: HTTPRequest(method: "GET", path: "/manifest.json",
                                                 headers: ["authorization": "Bearer " + token]), now: now).0
        guard case let .bytes(_, _, body) = reply else { throw POSIXError(.EIO) }
        return try Manifest.read(body)
    }

    /// Concept-doc plan, phase B: the Mac app's backup key reaches a paired phone inside the list it is served, from
    /// backup-key.json only; a missing or damaged file gives none, and a key in the delivery list itself is dropped.
    func testTheServedListCarriesTheBackupKeyFromItsFileOnly() throws {
        let keyFile = root.appendingPathComponent(BackupSignature.publicKeyFileName)
        router = Router(folder: served, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                        manifestOnly: true, backupKey: keyFile)
        XCTAssertNil(try servedList().backupKey)
        let key = P256.Signing.PrivateKey()
        try BackupSignature.publicKeyFile(of: key).write(to: keyFile)
        XCTAssertEqual(try servedList().backupKey, BackupSignature.publicKey(of: key))
        try Data("damaged".utf8).write(to: keyFile)
        XCTAssertNil(try servedList().backupKey)
        var planted = try Manifest.read(Data(contentsOf: served.appendingPathComponent("manifest.json")))
        planted.backupKey = BackupSignature.publicKey(of: P256.Signing.PrivateKey())
        try planted.encoded().write(to: served.appendingPathComponent("manifest.json"))
        XCTAssertNil(try servedList().backupKey)
    }

    func testOnlyAFileTheManifestNamesIsServed() {
        XCTAssertEqual(get("listed.zim").status, 200)
        XCTAssertEqual(get("not-listed.zim").status, 404, "in the folder but not in the manifest")
    }

    func testNoFileIsServedWhenTheManifestCantBeRead() throws {
        try Data("{".utf8).write(to: served.appendingPathComponent("manifest.json"))
        XCTAssertEqual(get("listed.zim").status, 404)
        try FileManager.default.removeItem(at: served.appendingPathComponent("manifest.json"))
        XCTAssertEqual(get("listed.zim").status, 404)
    }

    func testAManifestChangeCountsAtTheNextRequest() throws {
        try writeManifest(["not-listed.zim"])
        XCTAssertEqual(get("listed.zim").status, 404)
        XCTAssertEqual(get("not-listed.zim").status, 200)
    }

    func testTheLibraryTakesNoCounts() throws {  // phone counts go to the probe's service only
        let report = CountsReport(at: "2026-10-12T21:07Z", counts: AlertCounts(alerts: 1, events: 1, noVTEC: 0))
        let answer = router.reply(to: HTTPRequest(method: "POST", path: "/counts",
                                                  headers: ["authorization": "Bearer " + token],
                                                  body: try report.encoded()), now: now).0
        XCTAssertEqual(answer.status, 404)
    }

    func testTheProbesRouterStillServesAnyPlainName() throws {
        let probe = Router(folder: served, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c")))
        let answer = probe.reply(to: HTTPRequest(method: "GET", path: "/files/not-listed.zim",
                                                 headers: ["authorization": "Bearer " + token]), now: now).0
        if case let .file(_, _, handle, _, _, _) = answer { try? handle.close() }
        XCTAssertEqual(answer.status, 200)
    }

    func testBendOnceMarksTheMiddleByteOfTheNextWholeReplyThenIsGone() throws {
        XCTAssertNil(bent(get("listed.zim")), "nothing asked: nothing bent")
        try bend.request("listed.zim")
        XCTAssertEqual(bent(get("listed.zim")), 500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bend.url.path), "used once")
        XCTAssertNil(bent(get("listed.zim")))
        XCTAssertEqual(try Data(contentsOf: served.appendingPathComponent("listed.zim")), bytes,
                       "the file is unchanged")
    }

    func testBendOnceWaitsForAReplyThatCarriesTheMiddleByte() throws {
        try bend.request("listed.zim")
        XCTAssertNil(bent(get("listed.zim", headers: ["range": "bytes=600-"])), "a part without the middle")
        XCTAssertNil(bent(get("not-listed.zim")))
        XCTAssertEqual(bent(get("listed.zim", headers: ["range": "bytes=0-599"])), 500)
    }

    func testBendOnceRefusesANameThatIsntPlain() {
        XCTAssertThrowsError(try bend.request("../tokens.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bend.url.path))
    }
}

/// The bend through the real service on 127.0.0.1: one download arrives one byte off, across a piece boundary of the
/// stream, and the next is the file again.
final class LibraryLiveTests: XCTestCase {
    var folder: URL!
    var server: FileServer!
    var fingerprint = ""
    var token = ""
    var base: URL!
    var bend: BendOnce!
    var original = Data()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-library-live-\(UUID())")
        let served = folder.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try Identity.make(in: folder)
        let (identity, pin) = try Identity.load(from: folder)
        fingerprint = pin
        let tokens = TokenStore(url: folder.appendingPathComponent("tokens.json"))
        token = try tokens.add(now: Date()).token
        original = Data((0..<(3 << 20)).map { UInt8($0 % 253) })  // three pieces; the middle byte starts the second
        try original.write(to: served.appendingPathComponent("made-up.zim"))
        let entry = Manifest.Entry(name: "made-up.zim", id: "0f1e2d3c-4b5a-4968-8776-655443322110", kind: "library",
                                   size: Int64(original.count), sha256: try FileCheck.sha256(of:
                                       served.appendingPathComponent("made-up.zim")),
                                   deliveredAt: "2026-10-13T12:00:00-04:00")
        try Manifest(writtenAt: "2026-10-13T12:00:00-04:00", files: [entry]).encoded()
            .write(to: served.appendingPathComponent("manifest.json"))
        bend = BendOnce(url: folder.appendingPathComponent(BendOnce.name))
        let counts = CountsStore(url: folder.appendingPathComponent("c"))
        let router = Router(folder: served, tokens: tokens, counts: counts, manifestOnly: true, bend: bend)
        server = FileServer(router: router, identity: identity, port: 0, loopbackOnly: true, log: { _ in })
        let started = expectation(description: "listening")
        try server.start { problem in
            XCTAssertNil(problem)
            started.fulfill()
        }
        wait(for: [started], timeout: 10)
        base = URL(string: "https://127.0.0.1:\(server.boundPort!)")!
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func download() async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent("files/made-up.zim"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral, delegate: Pinned(pin: fingerprint), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        return data
    }

    func testOneDownloadIsOneByteOffAndTheNextIsTheFile() async throws {
        try bend.request("made-up.zim")
        let damaged = try await download()
        XCTAssertEqual(damaged.count, original.count)
        let differing = zip(damaged, original).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        XCTAssertEqual(differing, [original.count / 2])
        let next = try await download()
        XCTAssertEqual(next, original)
    }
}
