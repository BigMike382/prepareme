import Foundation
import Network
@testable import PrepareMeServer
import PrepareMeShared
import XCTest

/// The real service on 127.0.0.1 with a real identity made in a temporary folder, reached by URLSession with the
/// certificate pinned as the phone pins it. Never the owner's service folder, never the network.
final class LiveServerTests: XCTestCase {
    var folder: URL!
    var server: FileServer!
    var fingerprint = ""
    var token = ""
    var base: URL!
    let lines = Lines()
    let awake = FakeAwake()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-live-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Identity.make(in: folder)
        try start(from: folder)
    }

    /// Serves with the identity in `identityFolder`, from `folder`'s files and tokens.
    func start(from identityFolder: URL) throws {
        let (identity, pin) = try Identity.load(from: identityFolder)
        fingerprint = pin
        let tokens = TokenStore(url: folder.appendingPathComponent("tokens.json"))
        token = try tokens.add(now: Date()).token
        let served = folder.appendingPathComponent("files")
        try ProbeFile.swap(folder: served, id: "probe-test-id", bytes: 3 << 20)
        let router = Router(folder: served, tokens: tokens,
                            counts: CountsStore(url: folder.appendingPathComponent("jobs/probe-counts.json")))
        let lines = self.lines
        server = FileServer(router: router, identity: identity, port: 0, loopbackOnly: true, log: { lines.add($0) })
        server.headTimeout = 1
        server.awake = awake  // never the Mac's own sleep setting in a test
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

    func get(_ path: String, token: String?, headers: [String: String] = [:], pin: String? = nil)
        async throws -> (Int, Data)
    {
        var request = URLRequest(url: base.appendingPathComponent(path))
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = URLSession(configuration: .ephemeral, delegate: Pinned(pin: pin ?? fingerprint),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    func send(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:])
        async throws -> (HTTPURLResponse, Data)
    {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = URLSession(configuration: .ephemeral, delegate: Pinned(pin: fingerprint), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (response as! HTTPURLResponse, data)
    }

    func testAnIdentityOpensslMadeStillServesToAPhonePinningIt() async throws {
        server.stop()
        try start(from: IdentityTests.opensslIdentity)
        XCTAssertEqual(fingerprint, IdentityTests.opensslFingerprint)
        let (status, data) = try await get("manifest.json", token: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try Manifest.read(data).files.map(\.name), [ProbeFile.name])
    }

    func testThePairedPhoneGetsTheManifestAndItsEntryIsTheServedFile() async throws {
        let (status, data) = try await get("manifest.json", token: token)
        XCTAssertEqual(status, 200)
        let manifest = try Manifest.read(data)
        XCTAssertEqual(manifest.files.map(\.name), [ProbeFile.name])
        let (fileStatus, file) = try await get("files/\(ProbeFile.name)", token: token)
        XCTAssertEqual(fileStatus, 200)
        let saved = folder.appendingPathComponent("downloaded")
        try file.write(to: saved)
        XCTAssertEqual(try FileCheck.verify(saved, size: manifest.files[0].size, sha256: manifest.files[0].sha256),
                       .ok)
    }

    /// A raw TCP connection to the test server that never says hello.
    func rawConnection() -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(server.boundPort!).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        var wait = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Seconds until the server closes `fd` (6 or more: it didn't), and whether it sent anything first.
    func secondsUntilClosed(_ fd: Int32) -> (TimeInterval, Bool) {
        let began = Date()
        var byte: UInt8 = 0
        let got = recv(fd, &byte, 1, 0)
        return (Date().timeIntervalSince(began), got > 0)
    }

    func testAConnectionThatNeverStartsTLSIsClosedAfterTheHeadTimeout() throws {
        let fd = rawConnection()
        defer { close(fd) }
        let (seconds, sent) = secondsUntilClosed(fd)
        XCTAssertFalse(sent, "the server sent something to a client that never said hello")
        XCTAssertLessThan(seconds, 5, "still open: the head timeout didn't close it")
    }

    func testOneAddressGetsAtMostEightOpenConnectionsAndTheyAreFreed() async throws {
        let held = (0..<FileServer.maxPerPeer).map { _ in rawConnection() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let ninth = rawConnection()
        let (seconds, _) = secondsUntilClosed(ninth)
        close(ninth)
        XCTAssertLessThan(seconds, 0.9, "the ninth from one address was let in")
        for fd in held { close(fd) }
        try await Task.sleep(nanoseconds: 2_500_000_000)  // past the head timeout: all eight freed
        let (status, _) = try await get("manifest.json", token: token)
        XCTAssertEqual(status, 200)
    }

    /// This process's sockets on the server's port: the listener plus every accepted one still held.
    func serverSockets() -> Int {
        (Int32(0)..<4096).filter { fd in
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return false }
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            return named == 0 && UInt16(bigEndian: address.sin_port) == server.boundPort
        }.count
    }

    /// The Mac app's "does port 8744 answer" check connects and hangs up at once, every minute: on macOS 27.2 each
    /// one's socket stayed held until the service quit (F-104).
    func testAClientThatHangsUpAtOnceLeavesNoSocketHeld() async throws {
        for _ in 0..<20 {
            let fd = rawConnection()
            try await Task.sleep(nanoseconds: 50_000_000)
            close(fd)
        }
        try await Task.sleep(nanoseconds: 2_500_000_000)  // past the head timeout
        XCTAssertEqual(serverSockets(), 1, "only the listener should be left")
    }

    func testAPhoneThatStopsReadingAFileIsClosedAfterTheStallTimeout() throws {
        let server = server!, token = token
        server.stallTimeout = 1
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, .main)
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.boundPort!)!,
                                  using: NWParameters(tls: tls))
        defer { client.cancel() }
        let sent = expectation(description: "request sent")
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let head = "GET /files/\(ProbeFile.name) HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(token)\r\n\r\n"
            client.send(content: Data(head.utf8), completion: .contentProcessed { _ in sent.fulfill() })
        }
        client.start(queue: DispatchQueue(label: "test.client"))  // and never reads: the reply stalls
        wait(for: [sent], timeout: 5)
        let open = expectation(description: "the stalled reply was closed")
        @Sendable func poll() {
            if server.queue.sync(execute: { server.live.isEmpty }) {
                open.fulfill()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: poll)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3, execute: poll)
        wait(for: [open], timeout: 6)
    }

    func testStoppingTheServerClosesItsOpenConnections() throws {
        let fd = rawConnection()
        defer { close(fd) }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(server.queue.sync { server.live.isEmpty })
        server.stop()
        let (seconds, _) = secondsUntilClosed(fd)
        XCTAssertLessThan(seconds, 0.9, "a connection outlived the server's stop")
    }

    func testTheLogSaysWhenAFileWasSentWholeAndWhenOneWasCutOff() async throws {
        let (status, _) = try await get("files/\(ProbeFile.name)", token: token)
        XCTAssertEqual(status, 200)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(lines.all.contains("phone 1: a file sent whole, \(3 << 20) bytes"),
                      lines.all.joined(separator: "\n"))
        server.stallTimeout = 1
        let stalled = expectation(description: "a reply that stopped moving was closed")
        let client = stalledClient(fulfilling: stalled)
        defer { client.cancel() }
        await fulfillment(of: [stalled], timeout: 8)
        let cut = lines.all.contains { $0.hasPrefix("phone 1: a file cut off after ") && $0.hasSuffix(" MB of 3 MB") }
        XCTAssertTrue(cut, lines.all.joined(separator: "\n"))
    }

    /// A phone that asks for the file over TLS and never reads it; `done` is fulfilled once the server closes it.
    func stalledClient(fulfilling done: XCTestExpectation) -> NWConnection {
        let server = server!, token = token, lines = lines
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, ok in ok(true) }, .main)
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.boundPort!)!,
                                  using: NWParameters(tls: tls))
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let head = "GET /files/\(ProbeFile.name) HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(token)\r\n\r\n"
            client.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        }
        client.start(queue: DispatchQueue(label: "test.stalled"))
        @Sendable func poll() {
            let closed = server.queue.sync(execute: { server.live.isEmpty })
            if closed && lines.all.contains(where: { $0.contains("cut off") }) {
                done.fulfill()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: poll)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: poll)
        return client
    }

    func testTheMacStaysAwakeOnlyWhileAFileIsBeingSent() async throws {
        let (status, _) = try await get("manifest.json", token: token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(awake.events, [])  // a list isn't a transfer
        let (fileStatus, _) = try await get("files/\(ProbeFile.name)", token: token)
        XCTAssertEqual(fileStatus, 200)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(awake.events, ["hold", "release"])
        server.stallTimeout = 1
        let stalled = expectation(description: "a reply that stopped moving was closed")
        let client = stalledClient(fulfilling: stalled)
        defer { client.cancel() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(awake.events, ["hold", "release", "hold"])  // held while the stalled reply is open
        await fulfillment(of: [stalled], timeout: 8)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(awake.events, ["hold", "release", "hold", "release"])  // and let go when it is closed
    }

    func testTwoFilesAtOnceHoldTheMacAwakeOnce() async throws {
        let url = base.appendingPathComponent("files/\(ProbeFile.name)")
        let (token, pin) = (token, fingerprint)
        async let one = Self.status(url, token: token, pin: pin)
        async let two = Self.status(url, token: token, pin: pin)
        let (a, b) = try await (one, two)
        XCTAssertEqual([a, b], [200, 200])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(awake.events.filter { $0 == "hold" }.count, awake.events.filter { $0 == "release" }.count)
        XCTAssertEqual(awake.events.last, "release")
        XCTAssertFalse(awake.events.isEmpty)
    }

    static func status(_ url: URL, token: String, pin: String) async throws -> Int {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral, delegate: Pinned(pin: pin), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }

    func testNoTokenAndAWrongTokenGetNothing() async throws {
        let (none, noneBody) = try await get("manifest.json", token: nil)
        XCTAssertEqual(none, 401)
        XCTAssertTrue(noneBody.isEmpty)
        let (wrong, wrongBody) = try await get("files/\(ProbeFile.name)", token: Token.make())
        XCTAssertEqual(wrong, 401)
        XCTAssertTrue(wrongBody.isEmpty)
    }

    func testAnotherCertificateIsRefusedByThePin() async throws {
        do {
            _ = try await get("manifest.json", token: token, pin: String(repeating: "0", count: 64))
            XCTFail("a certificate that isn't the pinned one was trusted")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
    }

    func testARangeComesBackAsItsBytes() async throws {
        let (_, whole) = try await get("files/\(ProbeFile.name)", token: token)
        let (status, part) = try await get("files/\(ProbeFile.name)", token: token, headers: ["Range": "bytes=10-19"])
        XCTAssertEqual(status, 206)
        XCTAssertEqual(part, whole.subdata(in: 10..<20))
    }

    func testACountsReportPostedOverTLSIsAccepted() async throws {
        let report = CountsReport(at: CountsReport.minute(Date()), counts: AlertCounts(alerts: 1, events: 1, noVTEC: 0))
        let (response, _) = try await send("POST", "counts", body: report.encoded())
        XCTAssertEqual(response.statusCode, 204)
    }

    func testARangeWithTheETagFromTheFirstGetResumesAsAPart() async throws {
        let (first, whole) = try await send("GET", "files/\(ProbeFile.name)")
        let tag = try XCTUnwrap(first.value(forHTTPHeaderField: "ETag"))
        let (second, part) = try await send("GET", "files/\(ProbeFile.name)",
                                            headers: ["Range": "bytes=100-199", "If-Range": tag])
        XCTAssertEqual(second.statusCode, 206)
        XCTAssertEqual(part, whole.subdata(in: 100..<200))
    }
}

/// The phone's pin: trust the server only when its leaf certificate's SHA-256 is the paired one.
final class Pinned: NSObject, URLSessionDelegate {
    let pin: String

    init(pin: String) {
        self.pin = pin
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, Pin.matches(trust, pin: pin) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// The server's log lines, kept for the tests to read.
/// Records the server's asks to keep the Mac awake, in order.
final class FakeAwake: KeepAwake, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []

    func hold() { lock.withLock { kept.append("hold") } }
    func release() { lock.withLock { kept.append("release") } }
    var events: [String] { lock.withLock { kept } }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []

    func add(_ line: String) {
        lock.withLock { kept.append(line) }
    }

    var all: [String] { lock.withLock { kept } }
}
