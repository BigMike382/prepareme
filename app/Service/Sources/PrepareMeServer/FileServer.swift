import Foundation
import IOKit.pwr_mgt
import Network
import PrepareMeShared
import Security

/// The service on the network (plan section 9): TLS 1.2 or later on Network.framework with the Mac's own identity,
/// IPv4 only, advertised over Bonjour as `_prepareme._tcp`. A connection from outside IPv4's private ranges is closed
/// before its TLS handshake starts (TCP has been accepted by then). Each connection carries one request, whose head
/// must arrive within `headTimeout` seconds of the connection, handshake included; at most `maxLive` are open at once
/// and `maxPerPeer` from one address, so one device on the Wi-Fi can't use up the service or crowd out the phones
/// (phase 1 review, item 3). While any file is being sent the Mac doesn't go to sleep on its own (`awake`; owner,
/// 2026-10-13, plan phase 6): a lid closed or Sleep chosen still sleeps it.
public final class FileServer: @unchecked Sendable {
    public static let bonjourType = "_prepareme._tcp"
    public static let bonjourName = "PrepareMe"

    let router: Router
    let identity: SecIdentity
    let port: NWEndpoint.Port
    let advertise: Bool
    let loopbackOnly: Bool
    let log: @Sendable (String) -> Void
    let queue = DispatchQueue(label: "prepareme.service")
    public var headTimeout: TimeInterval = 15
    /// A reply that makes no progress for this long (a phone that stopped reading) is closed, so it can't hold one of
    /// the `maxLive` places for good.
    public var stallTimeout: TimeInterval = 60
    private var listener: NWListener?
    var live: [ObjectIdentifier: Exchange] = [:]  // the open exchanges, touched only on `queue`
    /// What keeps the Mac awake during a transfer; the tests pass a fake. Set before `start`.
    public var awake: any KeepAwake = IdleSleepGuard()
    private var transfers = 0  // files being sent now, touched only on `queue`
    public static let maxLive = 64
    public static let maxPerPeer = 8  // so one device on the Wi-Fi can't crowd the phones out

    /// `port` 0 takes any free port (`boundPort` says which). `loopbackOnly` listens on 127.0.0.1 alone and never
    /// advertises: the tests' server, which the Mac's firewall never sees.
    public init(router: Router, identity: SecIdentity, port: UInt16, advertise: Bool = true, loopbackOnly: Bool = false,
                log: @escaping @Sendable (String) -> Void) {
        self.router = router
        self.identity = identity
        self.port = NWEndpoint.Port(rawValue: port)!
        self.advertise = advertise && !loopbackOnly
        self.loopbackOnly = loopbackOnly
        self.log = log
    }

    public enum StartProblem: Error, Sendable {
        case noIdentity, failed(String)
    }

    /// Starts listening and calls `ready` once with nil, or with what stopped it.
    public func start(ready: @escaping @Sendable (StartProblem?) -> Void) throws {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else { throw StartProblem.noIdentity }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: port)
        }
        if advertise {
            listener.service = NWListener.Service(name: Self.bonjourName, type: Self.bonjourType)
        }
        let once = Once()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: once.run { ready(nil) }
            case let .failed(error):
                once.run { ready(.failed(String(describing: error))) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Stops listening and closes every open connection. Never called from the server's own queue.
    public func stop() {
        listener?.cancel()
        listener = nil
        queue.sync { for exchange in live.values { exchange.close() } }
    }

    public var boundPort: UInt16? { listener?.port?.rawValue }

    /// A file reply began (on `queue`): the first one asks the Mac to stay awake.
    func transferStarted() {
        transfers += 1
        if transfers == 1 { awake.hold() }
    }

    /// A file reply's exchange ended, however it ended (on `queue`): the last one lets the Mac sleep again.
    func transferEnded() {
        transfers -= 1
        if transfers == 0 { awake.release() }
    }

    func accept(_ connection: NWConnection) {
        guard Self.isPrivatePeer(connection.endpoint) else {
            connection.cancel()  // nothing at all: no TLS, no status
            log("refused a connection from outside the home network")
            return
        }
        let peer = Self.peer(connection.endpoint)
        guard live.count < Self.maxLive, live.values.filter({ $0.peer == peer }).count < Self.maxPerPeer else {
            connection.cancel()  // freed as this returns: nothing holds it
            log("refused a connection: too many open")
            return
        }
        Exchange(connection: connection, server: self, peer: peer).begin()
    }

    static func peer(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "" }
        return "\(host)"
    }

    static func isPrivatePeer(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint, case let .ipv4(address) = host else { return false }
        return PrivateAddress.isPrivateIPv4([UInt8](address.rawValue))
    }
}

/// Keeps the Mac from going to sleep on its own while held; `hold` and `release` alternate, starting with `hold`.
public protocol KeepAwake: AnyObject, Sendable {
    func hold()
    func release()
}

/// The system's own: a power assertion that stops idle sleep only (never a lid closed, Sleep chosen or the display
/// going dark), named so `pmset -g assertions` says why.
public final class IdleSleepGuard: KeepAwake, @unchecked Sendable {
    public static let reason = "PrepareMe: a phone is getting a library file"
    private let lock = NSLock()
    private var id = IOPMAssertionID(0)
    private var held = false

    public init() {}

    public func hold() {
        lock.withLock {
            guard !held else { return }
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.reason as CFString,
                                               &id) == kIOReturnSuccess
        }
    }

    public func release() {
        lock.withLock {
            guard held else { return }
            IOPMAssertionRelease(id)
            held = false
        }
    }
}

/// Runs a closure once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// One connection's request and reply. The server's `live` table is its only owner: every closure here holds it weakly,
/// so once it is taken out of the table (`drop`, after the connection is cancelled or fails) it and its connection are
/// freed. That matters: Network.framework let go of a socket still in its TLS handshake only when the connection object
/// itself was freed, not on cancel (phase 1 review, item 3; FINDINGS F-061), so a connection kept alive by its own
/// timer held its socket for minutes.
final class Exchange: @unchecked Sendable {
    let connection: NWConnection
    unowned let server: FileServer
    let peer: String
    var buffer = Data()
    var answered = false  // set once the request is read: the head timeout no longer applies
    var dropped = false
    var holdsAwake = false  // a file reply began: the server's transfer count holds this one until `drop`
    var progressed = Date()  // when the reply last moved: its head or a piece sent
    var sending: (who: String, total: UInt64, sent: UInt64)?  // a file being sent, for the log's last line about it
    static let piece = 1 << 20

    init(connection: NWConnection, server: FileServer, peer: String) {
        self.connection = connection
        self.server = server
        self.peer = peer
    }

    /// On the server's queue.
    func begin() {
        server.live[ObjectIdentifier(self)] = self
        server.queue.asyncAfter(deadline: .now() + server.headTimeout) { [weak self] in
            guard let self, !answered else { return }
            close()  // no request within the time: closed, whatever stage the handshake is at
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive()
            case .failed: self?.close()  // cancelled too: on macOS 27.2 a failed one only freed kept its socket (F-104)
            case .cancelled: self?.drop()
            default: break
            }
        }
        connection.start(queue: server.queue)
    }

    func close() {
        if let cut = sending {  // a file reply ended before its last byte: the phone went away, stalled or failed
            server.log("\(cut.who): a file cut off after \(cut.sent >> 20) MB of \(cut.total >> 20) MB")
            sending = nil
        }
        connection.cancel()
        drop()
    }

    /// Out of the live table, on the next turn of the queue so no callback of this connection is still running.
    func drop() {
        guard !dropped else { return }
        dropped = true
        if holdsAwake {
            holdsAwake = false
            server.transferEnded()
        }
        let id = ObjectIdentifier(self)
        server.queue.async { [server] in server.live[id] = nil }
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, !dropped else { return }
            if let data { buffer.append(data) }
            switch HTTP.parseHead(buffer) {
            case .needMore:
                if complete || error != nil { close() } else { receive() }
            case let .refused(status):
                finish(Router.empty(status), label: nil, path: "?")
            case let .request(request, bodyLength, headLength):
                // The large bodies (a phone's inventory edits, its room report) wait for no one: no paired phone's
                // token, no body
                if [HTTP.editsPath, HTTP.storagePath].contains(request.path), server.router.phone(request) == nil {
                    finish(Router.empty(401), label: nil, path: request.path)
                    return
                }
                let have = buffer.count - headLength
                if have < bodyLength {
                    if complete || error != nil { close() } else { receive() }
                    return
                }
                var whole = request
                whole.body = buffer.subdata(in: (buffer.startIndex + headLength)..<(buffer.startIndex + headLength
                                                                                    + bodyLength))
                let (reply, label) = server.router.reply(to: whole, now: Date())
                finish(reply, label: label, path: request.path)
            }
        }
    }

    func finish(_ reply: Reply, label: String?, path: String) {
        answered = true
        let who = label ?? "no paired phone"
        let named = ["/manifest.json", "/counts", "/inventory.json", HTTP.editsPath]  // never a file's or an edit's text
        let what = path.hasPrefix("/files/") ? "a file" : (named.contains(path) ? path : "?")
        switch reply {
        case let .bytes(status, headers, body):
            server.log("\(who): \(what) -> \(status)")
            connection.send(content: HTTP.head(status, headers) + body, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close() })
        case let .file(status, headers, handle, offset, length, bend):
            server.log("\(who): \(what) -> \(status), \(length) bytes"
                       + (bend == nil ? "" : ", one byte bent (the damaged-copy test)"))
            sending = (who, length, 0)
            holdsAwake = true
            server.transferStarted()
            progressed = Date()
            watch(handle)
            connection.send(content: HTTP.head(status, headers), completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { return Self.shut(handle, self) }
                do {
                    try handle.seek(toOffset: offset)
                    stream(handle, left: length, at: offset, bend: bend)
                } catch {
                    Self.shut(handle, self)
                }
            })
        }
    }

    /// The file in 1 MB pieces, each sent when the last has gone, so a slow phone never makes the Mac read ahead. `at`
    /// is the next piece's offset in the file; the byte at `bend`, if any, goes out changed (BendOnce).
    func stream(_ handle: FileHandle, left: UInt64, at: UInt64, bend: UInt64?) {
        guard left > 0 else {
            if let done = sending {  // every byte handed to the network: the phone's own log says if it arrived
                server.log("\(done.who): a file sent whole, \(done.total) bytes")
                sending = nil
            }
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in
                Self.shut(handle, self)
            })
            return
        }
        let size = Int(min(UInt64(Self.piece), left))
        guard var piece = try? handle.read(upToCount: size), !piece.isEmpty else { return Self.shut(handle, self) }
        if let bend, bend >= at, bend - at < UInt64(piece.count) {
            let index = piece.startIndex + Int(bend - at)
            piece[index] ^= 0xFF
        }
        connection.send(content: piece, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return Self.shut(handle, self) }
            progressed = Date()
            sending?.sent += UInt64(piece.count)
            stream(handle, left: left - UInt64(piece.count), at: at + UInt64(piece.count), bend: bend)
        })
    }

    /// Every half `stallTimeout`, while the file is being sent: a reply that hasn't moved for `stallTimeout` is closed.
    func watch(_ handle: FileHandle) {
        server.queue.asyncAfter(deadline: .now() + server.stallTimeout / 2) { [weak self] in
            guard let self, !dropped else { return }
            if Date().timeIntervalSince(progressed) >= server.stallTimeout {
                server.log("closed a reply that stopped moving")
                Self.shut(handle, self)
            } else {
                watch(handle)
            }
        }
    }

    /// The file closed and the connection with it (when the exchange is still there).
    static func shut(_ handle: FileHandle, _ exchange: Exchange?) {
        try? handle.close()
        exchange?.close()
    }
}
