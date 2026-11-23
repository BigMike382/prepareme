import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The household key that opens Essential Documents, kept on each device locked by that device's Secure Enclave
/// (docs/documents.md). The design named a Keychain item; on the Mac that kind of Keychain item needs a provisioning
/// profile the Mac app doesn't have (it failed with -34018, 2026-10-24), so the key is sealed instead to a Secure
/// Enclave key made with `.privateKeyUsage` and `.userPresence`: only this device's Secure Enclave can use it, and only after Touch ID,
/// Face ID, an Apple Watch or the password. The file below is useless anywhere else, and without that check.
public struct DocumentKeyFile: Codable, Equatable, Sendable {
    public var version = 1
    public let lock: Data  // the Secure Enclave key's own sealed form: only this device's Secure Enclave can use it
    public let ephemeral: Data  // the one-off public key the household key was sealed with
    public let sealed: Data  // the household key, AES-GCM

    static let info = Data("PrepareMe Essential Documents key 1".utf8)

    public init(lock: Data, ephemeral: Data, sealed: Data) {
        self.lock = lock
        self.ephemeral = ephemeral
        self.sealed = sealed
    }

    /// Seals `key` to the lock's public key: a one-off key pair, the agreed secret through HKDF, AES-GCM.
    public static func seal(_ key: SymmetricKey, to lock: P256.KeyAgreement.PublicKey, lockData: Data) throws -> Self {
        let oneOff = P256.KeyAgreement.PrivateKey()
        let wrapping = try oneOff.sharedSecretFromKeyAgreement(with: lock)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: oneOff.publicKey.rawRepresentation, sharedInfo: info,
                                     outputByteCount: 32)
        let raw = key.withUnsafeBytes { Data($0) }
        guard let sealed = try AES.GCM.seal(raw, using: wrapping).combined else { throw DocumentCipher.Failure.damaged }
        return DocumentKeyFile(lock: lockData, ephemeral: oneOff.publicKey.rawRepresentation, sealed: sealed)
    }

    /// Opens the household key with the lock's half of the agreement (the Secure Enclave's, which asks first). A
    /// file that can't hold the key throws `DocumentKey.Failure.broken`; the agreement's own errors (a cancel) pass.
    public func open(agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> SymmetricKey {
        guard let oneOff = try? P256.KeyAgreement.PublicKey(rawRepresentation: ephemeral),
              let box = try? AES.GCM.SealedBox(combined: sealed) else { throw DocumentKey.Failure.broken }
        let wrapping = try agree(oneOff).hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral, sharedInfo: Self.info,
                                                                 outputByteCount: 32)
        guard let raw = try? AES.GCM.open(box, using: wrapping) else { throw DocumentKey.Failure.broken }
        return SymmetricKey(data: raw)
    }
}

public enum DocumentKey {
    public enum Failure: Error, Equatable {
        case noSecureEnclave
        /// The key file, or a phone's gift, can't hold the key: damaged, or sealed to another lock. Only the file's
        /// own contents say so, never a cancelled Face ID, Touch ID or password.
        case broken
    }

    public static func url(in root: URL) -> URL { root.appendingPathComponent("household.key") }

    public static func exists(in root: URL) -> Bool { FileManager.default.fileExists(atPath: url(in: root).path) }

    /// The first unlock on this device: a new household key, sealed to a new Secure Enclave key that needs the
    /// owner's presence, saved whole. (Phase 3 gives the phones the Mac's key over the paired link instead; phase 4
    /// keeps its spare.)
    public static func create(in root: URL, context: LAContext) throws -> SymmetricKey {
        let lock = try Lock.make(context: context)
        let key = SymmetricKey(size: .bits256)
        let file = try DocumentKeyFile.seal(key, to: lock.publicKey, lockData: lock.data)
        _ = try file.open { try Lock.agree(lock.data, context: context, with: $0) }  // asks now, and proves it opens
        try DocumentStore.prepare(root)
        try DurableFile.write(JSONEncoder().encode(file), to: url(in: root))
        return key
    }

    /// The household key from the spare (phase 4: a new Mac, or one whose key file won't open), sealed to a new Secure
    /// Enclave key on this device in place of the old key file. Asks once, as `create` does. Never on the main thread.
    public static func adopt(_ key: SymmetricKey, in root: URL, context: LAContext) throws {
        let lock = try Lock.make(context: context)
        let file = try DocumentKeyFile.seal(key, to: lock.publicKey, lockData: lock.data)
        _ = try file.open { try Lock.agree(lock.data, context: context, with: $0) }
        try DocumentStore.prepare(root)
        try DurableFile.write(JSONEncoder().encode(file), to: url(in: root))
    }

    /// Opens the household key; the Secure Enclave asks for Touch ID, Face ID or the password with `context`'s
    /// reason. Blocks while it asks: never on the main thread.
    public static func open(in root: URL, context: LAContext) throws -> SymmetricKey {
        let file: DocumentKeyFile = try read(url(in: root))
        return try file.open { try Lock.agree(file.lock, context: context, with: $0) }
    }

    /// A key file, a pending lock or a gift, decoded; one that's missing or won't decode is `broken`.
    public static func read<T: Decodable>(_ url: URL) throws -> T {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw Failure.broken
        }
        return value
    }

    /// A phone's key file or gift that's `broken`: moved aside (never deleted) with the lock it asked with, so the
    /// phone's next check at home asks the Mac again with a new lock and the owner gives it again.
    public static func setAside(_ file: URL, in root: URL) throws {
        let aside = file.appendingPathExtension("set-aside")
        try? FileManager.default.removeItem(at: aside)
        try FileManager.default.moveItem(at: file, to: aside)
        try? FileManager.default.removeItem(at: pendingURL(in: root))
    }

    // A phone's side of the handoff (phase 3: DocumentHandoff)

    static func pendingURL(in root: URL) -> URL { root.appendingPathComponent("lock.pending") }

    struct Pending: Codable {
        var lock: Data
        var key: Data  // its public half, raw
    }

    /// The public half of this phone's lock, to ask the Mac with: made once (no prompt) and kept until the Mac's gift
    /// comes, so asking again asks with the same lock.
    public static func lockToAsk(in root: URL) throws -> Data {
        if let data = try? Data(contentsOf: pendingURL(in: root)),
           let pending = try? JSONDecoder().decode(Pending.self, from: data) { return pending.key }
        let lock = try Lock.make(context: LAContext())
        let pending = Pending(lock: lock.data, key: lock.publicKey.rawRepresentation)
        try DocumentStore.prepare(root)
        try DurableFile.write(JSONEncoder().encode(pending), to: pendingURL(in: root))
        return pending.key
    }

    /// The Mac's gift, sealed to the lock this phone asked with, kept as this phone's household key once it opens:
    /// the Secure Enclave asks with `context` first. A gift for another lock is refused and nothing changes. Blocks
    /// while it asks: never on the main thread.
    public static func receive(_ served: DocumentHandoff.Served, in root: URL, context: LAContext) throws -> SymmetricKey {
        let pending: Pending = try read(pendingURL(in: root))
        guard served.key == pending.key else { throw Failure.broken }
        let file = DocumentKeyFile(lock: pending.lock, ephemeral: served.ephemeral, sealed: served.sealed)
        let key = try file.open { try Lock.agree(pending.lock, context: context, with: $0) }
        try DurableFile.write(JSONEncoder().encode(file), to: url(in: root))
        try? FileManager.default.removeItem(at: pendingURL(in: root))
        return key
    }

    /// Whether this phone has asked and waits for the Mac's gift.
    public static func asked(in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: pendingURL(in: root).path)
    }

    /// The Secure Enclave key that locks the household key: made with `Lock.access()`, used only after the person's
    /// presence. The iOS simulator has no Secure Enclave, so there (and only there: made-up documents only) a plain key
    /// stands in, with the same presence prompt asked first.
    enum Lock {
        static func make(context: LAContext) throws -> (data: Data, publicKey: P256.KeyAgreement.PublicKey) {
            #if targetEnvironment(simulator)
            let lock = P256.KeyAgreement.PrivateKey()
            return (lock.rawRepresentation, lock.publicKey)
            #else
            guard SecureEnclave.isAvailable else { throw Failure.noSecureEnclave }
            let lock = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access(),
                                                                      authenticationContext: context)
            return (lock.dataRepresentation, lock.publicKey)
            #endif
        }

        /// The lock's rule: `.privateKeyUsage` lets the key be used at all once the person is present. With
        /// `.userPresence` alone Touch ID passed and the key still refused ("ACL operation is not allowed: 'ock'",
        /// the owner's Mac, 2026-10-25).
        static func access() throws -> SecAccessControl {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                               [.privateKeyUsage, .userPresence], &error) else {
                throw error!.takeRetainedValue() as Error
            }
            return access
        }

        static func agree(_ data: Data, context: LAContext, with other: P256.KeyAgreement.PublicKey) throws
            -> SharedSecret {
            #if targetEnvironment(simulator)
            let asked = DispatchSemaphore(value: 0)
            var passed = false
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: DocumentsWords.unlockReason) { ok, _ in
                passed = ok
                asked.signal()
            }
            asked.wait()
            guard passed else { throw CocoaError(.userCancelled) }
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: data).sharedSecretFromKeyAgreement(with: other)
            #else
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data, authenticationContext: context)
                .sharedSecretFromKeyAgreement(with: other)
            #endif
        }
    }
}
