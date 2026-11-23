import Foundation
import PrepareMeShared

/// The library service's side of pairing from the Mac app (plan phase 10; PairingDesk): every second it takes the
/// app's requests from the pairing folder, pairs or unpairs a phone in the service's own phone list (TokenStore, hashes
/// only) and answers each, and keeps `phones.json` there in step with that list. The identity never leaves the
/// service: the app gets only the code, sealed to its own one-time key. Lines go to the service's log, labels only.
public struct PairingClerk: Sendable {
    public let desk: PairingDesk
    public let tokens: TokenStore
    public let fingerprint: String
    public let port: Int
    /// A test service's clerk (Unlisted plan, phase 3): its codes are version 2, the test mark.
    public let test: Bool
    /// The code's address: the Mac's private IPv4 address, or 127.0.0.1 for a loopback test service.
    public let ip: @Sendable () -> String?
    public let host: @Sendable () -> String?

    public init(desk: PairingDesk, tokens: TokenStore, fingerprint: String, port: Int, test: Bool = false,
                host: @escaping @Sendable () -> String?, ip: @escaping @Sendable () -> String?) {
        self.desk = desk
        self.tokens = tokens
        self.fingerprint = fingerprint
        self.port = port
        self.test = test
        self.host = host
        self.ip = ip
    }

    public func tick(now: Date, log: (String) -> Void) {
        let folder = desk.folder
        do {
            try PairingDesk.makeFolder(folder)
        } catch {
            return  // said once by the caller's start; nothing to read or write without it
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() {
            if let id = PairingDesk.id(in: name, prefix: "request") {
                take(id, at: folder.appendingPathComponent(name), now: now, log: log)
            } else if PairingDesk.id(in: name, prefix: "reply") != nil {
                let url = folder.appendingPathComponent(name)
                let made = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                if let made, now.timeIntervalSince(made) > PairingDesk.replyMaxAge {
                    try? FileManager.default.removeItem(at: url)  // the app never came for it; sealed, but not kept
                }
            }
        }
        listPhones()
    }

    /// One request: removed first, so it is acted on once, then answered unless it was too old or not one.
    func take(_ id: String, at url: URL, now: Date, log: (String) -> Void) {
        guard PairingDesk.isRegularFile(url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size <= PairingDesk.requestMaxBytes, let data = try? Data(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard (try? FileManager.default.removeItem(at: url)) != nil else { return }
        guard let request = try? JSONDecoder().decode(PairingDesk.Request.self, from: data), request.v == 1 else {
            return
        }
        guard let at = ISO8601DateFormatter().date(from: request.at),
              now.timeIntervalSince(at) <= PairingDesk.requestMaxAge, at.timeIntervalSince(now) <= 60 else {
            log("a pairing request from the Mac app was too old; nothing changed")
            return
        }
        let reply: PairingDesk.Reply
        switch request.kind {
        case .pair: reply = pair(request, id: id, now: now, log: log)
        case .unpair: reply = unpair(request, log: log)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? DurableFile.write(encoder.encode(reply), to: desk.folder.appendingPathComponent("reply-\(id).json"))
    }

    func pair(_ request: PairingDesk.Request, id: String, now: Date, log: (String) -> Void) -> PairingDesk.Reply {
        guard let key = request.key else { return .init(problem: "the request had no key") }
        guard let host = host() else { return .init(problem: "the Mac's network name couldn't be read") }
        let readOnly = request.readOnly == true
        do {
            let (label, token) = try tokens.add(now: now, readOnly: readOnly)
            let code = try PairingCode(host: host, ip: ip(), port: port, fp: fingerprint, token: token,
                                       test: test).text()
            let paired = PairingDesk.Paired(code: code, label: label, added: ISO.now(now), readOnly: readOnly)
            do {
                let reply = try PairingDesk.seal(paired, to: key, id: id)
                log("\(label) paired from PrepareMe on the Mac" + (readOnly ? " (read-only)" : ""))
                return reply
            } catch {
                _ = try? tokens.remove(label: label)  // a code no one can open is a phone no one holds
                return .init(problem: "the request's key couldn't be used")
            }
        } catch {
            return .init(problem: "the phone list couldn't be saved")
        }
    }

    /// Only the phone with that label and pairing time: a list the app read before a label was reused can't remove
    /// the new phone.
    func unpair(_ request: PairingDesk.Request, log: (String) -> Void) -> PairingDesk.Reply {
        guard let label = request.label, let added = request.added else { return .init(problem: "no phone was named") }
        guard let phones = try? tokens.phones() else { return .init(problem: "the phone list couldn't be read") }
        guard phones.contains(where: { $0.label == label && $0.added == added }) else { return .init(removed: false) }
        do {
            let removed = try tokens.remove(label: label)
            if removed { log("\(label) unpaired from PrepareMe on the Mac") }
            return .init(removed: removed)
        } catch {
            return .init(problem: "the phone list couldn't be saved")
        }
    }

    /// `phones.json` written again only when the service's list differs from it (a pairing in Terminal shows too).
    func listPhones() {
        guard let phones = try? tokens.phones() else { return }
        let listed = phones.map { PairingDesk.Phone(label: $0.label, added: $0.added, readOnly: $0.readOnly == true,
                                                    waiting: $0.waiting == true) }
        guard desk.phones() != listed else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? DurableFile.write(encoder.encode(PairingDesk.PhoneList(phones: listed)),
                               to: desk.folder.appendingPathComponent(PairingDesk.phonesName))
    }
}
