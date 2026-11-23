import CryptoKit
import Foundation

/// The backup's signed list (concept-doc plan, phase B; owner, 2026-10-18: "Signed by the Mac";
/// docs/plans/2026-10-18-phase-b-add-from-files.md). The Mac app signs each manifest.json it writes into PrepareMe
/// Backup with a P-256 key of its own, made once and kept in its sandbox. The signature, the exact bytes it covers and
/// the key's public half sit in the same file as three more fields (`signature`, `signed`, `key`), so the list and its
/// signature are written whole at once.
/// A phone learns the public half only over the paired, pinned Wi-Fi channel (the service's `backup_key`), and trusts a
/// list in a folder only when it is signed by that key; anything else needs an adult's word.
///
/// - The signature covers the exact bytes in `signed` (base64), never a re-encoding, so a phone on another OS version
///   checks the same bytes the Mac signed (review of tasks 1 to 3). The list those bytes hold must equal the list at the
///   top of the file, which is what every reader uses; a field nothing reads (one added later, or planted) changes
///   nothing a phone uses.
/// - `Manifest.read` ignores the two fields, so phase A's readers read a signed list as before.
public enum BackupSignature {
    public enum Verdict: Equatable, Sendable {
        /// Signed, and the signature holds for this public key (base64 of its raw form)
        case signed(key: String)
        case unsigned
        /// A signature that doesn't hold: the list changed after signing, or the fields were swapped
        case badSignature
    }

    public struct Read: Sendable {
        public var manifest: Manifest
        public var verdict: Verdict
    }

    /// The bytes of manifest.json for `manifest`, signed by `key`
    public static func sign(_ manifest: Manifest, with key: P256.Signing.PrivateKey) throws -> Data {
        let body = try manifest.encoded()
        let signature = try key.signature(for: body)
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object["signed"] = body.base64EncodedString()
        object["signature"] = signature.derRepresentation.base64EncodedString()
        object["key"] = publicKey(of: key)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// The list in `data` (every entry checked, as `Manifest.read` does: a damaged list throws) and whether it is signed
    public static func read(_ data: Data) throws -> Read {
        let manifest = try Manifest.read(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let signature = object["signature"] as? String, key = object["key"] as? String, signed = object["signed"] as? String
        guard signature != nil || key != nil || signed != nil else { return Read(manifest: manifest, verdict: .unsigned) }
        guard let signature, let key, let signed, let der = Data(base64Encoded: signature),
              let raw = Data(base64Encoded: key), let body = Data(base64Encoded: signed),
              let publicKey = try? P256.Signing.PublicKey(rawRepresentation: raw),
              let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: der),
              publicKey.isValidSignature(ecdsa, for: body),
              let bodyManifest = try? Manifest.read(body), bodyManifest == manifest else {
            return Read(manifest: manifest, verdict: .badSignature)
        }
        return Read(manifest: manifest, verdict: .signed(key: key))
    }

    /// A key's public half as the lists and the phones carry it: base64 of its raw form
    public static func publicKey(of key: P256.Signing.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// The Mac's signing key from `file`, made and saved whole (owner-only) the first time. A file that is there but
    /// can't be read as a key throws: it is never quietly replaced, which would leave every phone's key out of date.
    public static func loadOrMakeKey(at file: URL) throws -> P256.Signing.PrivateKey {
        if FileManager.default.fileExists(atPath: file.path) {
            return try P256.Signing.PrivateKey(rawRepresentation: Data(contentsOf: file))
        }
        let key = P256.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFile.write(key.rawRepresentation, to: file)
        return key
    }

    /// backup-key.json, the public half the app leaves in the pairing folder for the phones' service to hand out
    public static let publicKeyFileName = "backup-key.json"

    public static func publicKeyFile(of key: P256.Signing.PrivateKey) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["key": publicKey(of: key)], options: [.sortedKeys])
    }

    /// The public half from backup-key.json, or nil when it is missing, damaged or not a P-256 key
    public static func readPublicKeyFile(_ data: Data?) -> String? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String, let raw = Data(base64Encoded: key),
              (try? P256.Signing.PublicKey(rawRepresentation: raw)) != nil else { return nil }
        return key
    }
}
