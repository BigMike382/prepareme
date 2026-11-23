import CoreImage
import CryptoKit
import Foundation

/// Plan phase 10: pairing a phone from PrepareMe on the Mac, in place of `prepareme-service pair`. The app's sandbox
/// never reaches the service's own folder (its identity and phone list), so the app asks the phones' service through a
/// folder both may use, Application Support › PrepareMe › pairing, and the service answers there:
/// - `request-<id>.json`: pair one more phone (an adult's, or a read-only child's) or unpair one, named by its label
///   and when it was paired (a label is reused once its phone is gone). A pairing request carries a one-time
///   Curve25519 public key whose private half the app holds in memory only.
/// - `reply-<id>.json`: the answer. A pairing's code holds the phone's token, so it is sealed to that key (ChaChaPoly
///   under HKDF-SHA256 of the key agreement): what lands on disk can't be opened once the app lets the key go, and the
///   code is never saved readable.
/// - `phones.json`: the paired phones (label, when, read-only), written by the service whenever its list changes;
///   never a token or its hash.
/// The service takes each request once (removed before it acts), ignores one over 2 minutes old and removes a reply
/// left over 5 minutes. Who can ask: PrepareMe, and the account's own unsandboxed programs, which could write the
/// service's phone list directly anyway; no other sandboxed app, no other account (the folder is 0700) and nothing on
/// the network.
public struct PairingDesk: Sendable {
    public static let folderName = "pairing"
    public static let phonesName = "phones.json"
    public static let requestMaxAge: TimeInterval = 120
    public static let replyMaxAge: TimeInterval = 300
    public static let requestMaxBytes = 4096
    static let info = Data("PrepareMe pairing v1".utf8)

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public struct Request: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case pair, unpair }
        public var v: Int
        public var kind: Kind
        public var at: String
        public var readOnly: Bool?
        /// Pairing only: the app's one-time public key, raw and base64.
        public var key: String?
        /// Unpairing only: which phone.
        public var label: String?
        public var added: String?
    }

    public struct Reply: Codable, Equatable, Sendable {
        public var v: Int
        /// Pairing: the service's one-time public key and the sealed `Paired`, both base64.
        public var key: String?
        public var sealed: String?
        /// Unpairing: whether the phone was found and removed.
        public var removed: Bool?
        /// In fixed words, when nothing was done.
        public var problem: String?

        public init(key: String? = nil, sealed: String? = nil, removed: Bool? = nil, problem: String? = nil) {
            self.v = 1
            self.key = key
            self.sealed = sealed
            self.removed = removed
            self.problem = problem
        }
    }

    /// What a sealed pairing reply opens to: the code's text (PairingCode) and the phone it was made for.
    public struct Paired: Codable, Equatable, Sendable {
        public var code: String
        public var label: String
        public var added: String
        public var readOnly: Bool

        public init(code: String, label: String, added: String, readOnly: Bool) {
            self.code = code
            self.label = label
            self.added = added
            self.readOnly = readOnly
        }
    }

    /// One paired phone as `phones.json` lists it.
    public struct Phone: Codable, Equatable, Hashable, Sendable {
        public var label: String
        public var added: String
        public var readOnly: Bool
        /// Paired but not yet visited (Task 13.2; F42): the Mac lists it as waiting for its first visit. False in a
        /// list written before visits were kept.
        public var waiting: Bool

        public init(label: String, added: String, readOnly: Bool, waiting: Bool = false) {
            self.label = label
            self.added = added
            self.readOnly = readOnly
            self.waiting = waiting
        }

        public init(from decoder: Decoder) throws {
            let found = try decoder.container(keyedBy: CodingKeys.self)
            label = try found.decode(String.self, forKey: .label)
            added = try found.decode(String.self, forKey: .added)
            readOnly = try found.decode(Bool.self, forKey: .readOnly)
            waiting = try found.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
        }
    }

    public struct PhoneList: Codable, Equatable, Sendable {
        public var phones: [Phone]

        public init(phones: [Phone]) {
            self.phones = phones
        }
    }

    /// A request waiting for its answer: its ID and, for a pairing, the private key that opens the answer, held in
    /// memory only.
    public struct Ask: Sendable {
        public let id: String
        let key: Curve25519.KeyAgreement.PrivateKey?
    }

    public enum Answer: Equatable, Sendable {
        case paired(Paired)
        case removed(Bool)
        case problem(String)
    }

    // MARK: The app's side

    public func askToPair(readOnly: Bool, now: Date = Date()) throws -> Ask {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let ask = Ask(id: UUID().uuidString.lowercased(), key: key)
        try post(Request(v: 1, kind: .pair, at: Self.time(now), readOnly: readOnly,
                         key: key.publicKey.rawRepresentation.base64EncodedString()), id: ask.id)
        return ask
    }

    public func askToUnpair(_ phone: Phone, now: Date = Date()) throws -> Ask {
        let ask = Ask(id: UUID().uuidString.lowercased(), key: nil)
        try post(Request(v: 1, kind: .unpair, at: Self.time(now), label: phone.label, added: phone.added), id: ask.id)
        return ask
    }

    /// The service's answer, taken (its file removed) once it is there; nil while it isn't.
    public func answer(to ask: Ask) -> Answer? {
        let url = folder.appendingPathComponent("reply-\(ask.id).json")
        guard Self.isRegularFile(url), let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.v == 1 else {
            return .problem("the phones' service's answer couldn't be read")
        }
        if let problem = reply.problem { return .problem(problem) }
        if let removed = reply.removed { return .removed(removed) }
        guard let key = ask.key, let paired = try? Self.open(reply, with: key, id: ask.id) else {
            return .problem("the phones' service's answer couldn't be opened")
        }
        return .paired(paired)
    }

    /// The request taken back when no answer came (the service wasn't running): it won't be acted on later.
    public func withdraw(_ ask: Ask) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("request-\(ask.id).json"))
    }

    /// The paired phones as the service last listed them; nil before it has (or when the list can't be read).
    public func phones() -> [Phone]? {
        let url = folder.appendingPathComponent(Self.phonesName)
        guard Self.isRegularFile(url), let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(PhoneList.self, from: data) else { return nil }
        return list.phones
    }

    func post(_ request: Request, id: String) throws {
        try Self.makeFolder(folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFile.write(encoder.encode(request), to: folder.appendingPathComponent("request-\(id).json"))
    }

    // MARK: Sealing

    /// The reply that carries `paired` to the holder of `publicKey` (raw, base64) for request `id`.
    public static func seal(_ paired: Paired, to publicKey: String, id: String) throws -> Reply {
        guard let raw = Data(base64Encoded: publicKey) else { throw CryptoKitError.incorrectKeySize }
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let key = try symmetricKey(mine.sharedSecretFromKeyAgreement(with: theirs), id: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let box = try ChaChaPoly.seal(encoder.encode(paired), using: key)
        return Reply(key: mine.publicKey.rawRepresentation.base64EncodedString(),
                     sealed: box.combined.base64EncodedString())
    }

    static func open(_ reply: Reply, with key: Curve25519.KeyAgreement.PrivateKey, id: String) throws -> Paired {
        guard let theirs = reply.key.flatMap({ Data(base64Encoded: $0) }),
              let sealed = reply.sealed.flatMap({ Data(base64Encoded: $0) }) else { throw CryptoKitError.incorrectKeySize }
        let shared = try key.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs))
        let plain = try ChaChaPoly.open(.init(combined: sealed), using: symmetricKey(shared, id: id))
        return try JSONDecoder().decode(Paired.self, from: plain)
    }

    /// The request's ID is the salt, so a reply can't be moved onto another request.
    static func symmetricKey(_ shared: SharedSecret, id: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(id.utf8), sharedInfo: info, outputByteCount: 32)
    }

    // MARK: Shared helpers

    public static func makeFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// The request ID in a `request-<id>.json` or `reply-<id>.json` name: a lowercase UUID, or nil.
    public static func id(in name: String, prefix: String) -> String? {
        guard name.hasPrefix(prefix + "-"), name.hasSuffix(".json") else { return nil }
        let id = String(name.dropFirst(prefix.count + 1).dropLast(".json".count))
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { return nil }
        return id
    }

    /// A plain file, not a link or a folder.
    public static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}

/// The pairing code as a picture for a screen: black modules on white, with the four-module quiet zone the QR
/// standard asks for, each module `scale` pixels square and never smoothed, so a phone's camera reads it at a glance.
public enum PairingPicture {
    public static func image(_ text: String, scale: Int = 10) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let quiet = 4.0
        let white = CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -quiet, dy: -quiet))
        let framed = code.composited(over: white)
            .transformed(by: CGAffineTransform(translationX: quiet, y: quiet))
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return CIContext().createCGImage(framed, from: framed.extent)
    }
}

/// The Mac's words for its paired phones (remaining-findings plan, Task 13.2; F42; owner, 2026-10-18, by click: a new
/// phone waits until it has paired).
public enum PairingWords {
    public static let namePrompt = "Name this device"
    public static let waiting = "waiting for its first visit"
    /// A child's device on Settings › Devices (family downloads plan, phase 2: no longer "changes nothing")
    public static let childDevice = "Reads the library, downloads what you offer and adds its own pins. Never Essential "
        + "Documents."

    /// A phone's line under its name box (owner, 2026-11-14: one card per phone): whose, its label, and that it
    /// hasn't visited yet. When it was paired is under More details.
    public static func kind(label: String, readOnly: Bool, waiting: Bool) -> String {
        let kind = readOnly ? "Child's device" : "Adult's device"
        return waiting ? "\(kind) (\(label)), \(Self.waiting)" : "\(kind) (\(label))"
    }

    /// Add a device's "Paired before?" (family downloads plan, phase 6, decision 7: the owner picks it)
    public static let pairedBefore = "A device paired again takes its old name and Files… choices. Its old pairing is "
        + "removed once it visits."

    /// The code's window, when the new pairing takes the place of one
    public static func takesThePlace(of old: String) -> String {
        "It takes the name and Files… choices of \(old), which is removed once this one visits."
    }
}
