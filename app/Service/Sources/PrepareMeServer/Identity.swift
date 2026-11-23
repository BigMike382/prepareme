import CommonCrypto
import CryptoKit
import Foundation
import PrepareMeShared
import Security
import SwiftASN1
import X509

/// The Mac's TLS identity: a P-256 key and a self-signed certificate, kept as a PKCS#12 file readable by the owner
/// only (`identity.p12`, its passphrase in `identity.pass`), in the service's folder in Application Support. It is
/// loaded into memory only (kSecImportToMemoryOnly, macOS 15), never into the login Keychain, so a rebuilt service is
/// never asked for Keychain access (phase 1 ruling; plan section 9 said the Keychain). Phones pin the certificate's
/// SHA-256, so a new identity means pairing every phone again. Made in Swift since 2026-10-28 (CryptoKit's key,
/// swift-certificates' certificate); identities made before then by /usr/bin/openssl load exactly as they did.
public enum Identity {
    public enum Problem: Error, Equatable, Sendable {
        case exists, missing, unreadable, notImported(OSStatus)

        /// The service's line when `load` fails, in fixed words. Only a missing identity asks for `init`: `init`
        /// refuses to replace one that is there, since that would unpair every phone.
        public var line: String {
            let kept = "nothing changed, and `init` won't replace it (that would unpair every phone)"
            switch self {
            case .exists: return "the identity couldn't be made: \(self)"  // `make`'s, never `load`'s
            case .missing: return "run `prepareme-service init` first"
            case .unreadable: return "the Mac's identity is in the service folder but couldn't be read; \(kept)"
            case let .notImported(status):
                return "the Mac's identity is in the service folder but macOS won't load it (status \(status)); \(kept)"
            }
        }
    }

    public static func files(in folder: URL) -> (p12: URL, pass: URL) {
        (folder.appendingPathComponent("identity.p12"), folder.appendingPathComponent("identity.pass"))
    }

    /// Makes the identity in `folder`; refuses when one is there, since replacing it unpairs every phone. The
    /// certificate is what `openssl req -x509 -sha256 -subj "/CN=PrepareMe Mac"` made before: version 1, no
    /// extensions, ECDSA with SHA-256, valid from now for `days`.
    public static func make(in folder: URL, days: Int = 3650) throws {
        let (p12, passFile) = files(in: folder)
        guard !FileManager.default.fileExists(atPath: p12.path) else { throw Problem.exists }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("PrepareMe Mac") }
        let now = Date()
        let certificate = try Certificate(
            version: .v1, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: now, notValidAfter: now.addingTimeInterval(TimeInterval(days) * 86_400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256, extensions: Certificate.Extensions(),
            issuerPrivateKey: .init(key))
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let pass = Token.make()
        let data = try PKCS12.bundle(key: key.derRepresentation, certificate: serializer.serializedBytes, pass: pass)
        _ = try importIdentity(data, pass: pass)  // read back the way `load` will, before anything is kept
        try DurableFile.write(Data(pass.utf8), to: passFile)
        try DurableFile.write(data, to: p12)
    }

    /// The identity and its certificate's SHA-256, loaded into this process's memory only.
    public static func load(from folder: URL) throws -> (identity: SecIdentity, fingerprint: String) {
        let (p12, passFile) = files(in: folder)
        guard FileManager.default.fileExists(atPath: p12.path) else { throw Problem.missing }  // as `make` checks
        guard let data = try? Data(contentsOf: p12), let pass = try? String(contentsOf: passFile, encoding: .utf8)
        else { throw Problem.unreadable }
        let identity = try importIdentity(data, pass: pass)
        var certificate: SecCertificate?
        let copied = SecIdentityCopyCertificate(identity, &certificate)
        guard copied == errSecSuccess, let certificate else { throw Problem.notImported(copied) }
        return (identity, Pin.fingerprint(of: certificate))
    }

    /// The bundle's identity, in memory only. `notImported` carries SecPKCS12Import's status: errSecSuccess there
    /// means it read the bundle and found no identity in it.
    static func importIdentity(_ data: Data, pass: String) throws -> SecIdentity {
        var found: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: pass,
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &found)
        guard status == errSecSuccess, let items = found as? [[String: Any]], let first = items.first,
              let value = first[kSecImportItemIdentity as String] else { throw Problem.notImported(status) }
        return value as! SecIdentity
    }
}

/// Writes a PKCS#12 bundle (RFC 7292) of one key and its certificate with the algorithms OpenSSL 3's `pkcs12 -export`
/// uses: the key's PKCS#8 in a shrouded key bag under PBES2 (PBKDF2 with HMAC-SHA256, AES-256-CBC; RFC 9579 for the
/// password's bytes) and an HMAC-SHA256 MAC over all. The certificate's bag is plain (it is public; OpenSSL encrypts
/// it too). Both bags carry the certificate's SHA-1 as their local key ID, which pairs the key with its certificate.
/// swift-certificates writes certificates, not PKCS#12, and Security exports one only from a keychain.
enum PKCS12 {
    static let iterations = 2048  // openssl's
    static let data: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 1]
    static let shroudedKeyBag: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 12, 10, 1, 2]
    static let certBag: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 12, 10, 1, 3]
    static let x509Certificate: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 9, 22, 1]
    static let localKeyID: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 9, 21]
    static let pbes2: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 5, 13]
    static let pbkdf2: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 5, 12]
    static let hmacWithSHA256: ASN1ObjectIdentifier = [1, 2, 840, 113549, 2, 9]
    static let aes256CBC: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 1, 42]
    static let sha256: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 2, 1]

    struct Failed: Error {}

    static func bundle(key pkcs8: Data, certificate: [UInt8], pass: String) throws -> Data {
        let keyID = Array(Insecure.SHA1.hash(data: certificate))
        let salt = random(8), iv = random(16), macSalt = random(8)
        let encrypted = try aes256CBC(Array(pkcs8), key: pbkdf2(pass, salt: salt), iv: iv)
        let contents = try der { coder in  // SafeContents
            try sequence(&coder) { coder in
                try bag(&coder, shroudedKeyBag, keyID: keyID) { coder in  // EncryptedPrivateKeyInfo
                    try sequence(&coder) { coder in
                        try sequence(&coder) { coder in
                            try coder.serialize(pbes2)
                            try sequence(&coder) { coder in
                                try sequence(&coder) { coder in
                                    try coder.serialize(pbkdf2)
                                    try sequence(&coder) { coder in
                                        try coder.serialize(ASN1OctetString(contentBytes: salt[...]))
                                        try coder.serialize(iterations)
                                        try algorithm(&coder, hmacWithSHA256)
                                    }
                                }
                                try sequence(&coder) { coder in
                                    try coder.serialize(aes256CBC)
                                    try coder.serialize(ASN1OctetString(contentBytes: iv[...]))
                                }
                            }
                        }
                        try coder.serialize(ASN1OctetString(contentBytes: encrypted[...]))
                    }
                }
                try bag(&coder, certBag, keyID: keyID) { coder in
                    try sequence(&coder) { coder in
                        try coder.serialize(x509Certificate)
                        try coder.serialize(ASN1OctetString(contentBytes: certificate[...]),
                                            explicitlyTaggedWithTagNumber: 0, tagClass: .contextSpecific)
                    }
                }
            }
        }
        let safe = try der { coder in try sequence(&coder) { coder in try content(&coder, contents) } }
        let macSecret = SymmetricKey(data: macKey(pass, salt: macSalt))
        let mac = Array(HMAC<SHA256>.authenticationCode(for: safe, using: macSecret))
        return try Data(der { coder in  // PFX
            try sequence(&coder) { coder in
                try coder.serialize(3)
                try content(&coder, safe)
                try sequence(&coder) { coder in
                    try sequence(&coder) { coder in
                        try algorithm(&coder, sha256)
                        try coder.serialize(ASN1OctetString(contentBytes: mac[...]))
                    }
                    try coder.serialize(ASN1OctetString(contentBytes: macSalt[...]))
                    try coder.serialize(iterations)
                }
            }
        })
    }

    static func der(_ body: (inout DER.Serializer) throws -> Void) rethrows -> [UInt8] {
        var coder = DER.Serializer()
        try body(&coder)
        return coder.serializedBytes
    }

    static func sequence(_ coder: inout DER.Serializer, _ body: (inout DER.Serializer) throws -> Void) rethrows {
        try coder.appendConstructedNode(identifier: .sequence, body)
    }

    static func algorithm(_ coder: inout DER.Serializer, _ id: ASN1ObjectIdentifier) throws {
        try sequence(&coder) { coder in
            try coder.serialize(id)
            try coder.serialize(ASN1Null())
        }
    }

    /// A ContentInfo of type data holding `bytes`.
    static func content(_ coder: inout DER.Serializer, _ bytes: [UInt8]) throws {
        try sequence(&coder) { coder in
            try coder.serialize(data)
            try coder.serialize(ASN1OctetString(contentBytes: bytes[...]), explicitlyTaggedWithTagNumber: 0,
                                tagClass: .contextSpecific)
        }
    }

    /// A SafeBag with its value and its local key ID, the attribute that pairs the key with its certificate.
    static func bag(_ coder: inout DER.Serializer, _ id: ASN1ObjectIdentifier, keyID: [UInt8],
                    _ value: (inout DER.Serializer) throws -> Void) throws {
        try sequence(&coder) { coder in
            try coder.serialize(id)
            try coder.serialize(explicitlyTaggedWithTagNumber: 0, tagClass: .contextSpecific, value)
            try coder.appendConstructedNode(identifier: .set) { coder in
                try sequence(&coder) { coder in
                    try coder.serialize(localKeyID)
                    try coder.appendConstructedNode(identifier: .set) { coder in
                        try coder.serialize(ASN1OctetString(contentBytes: keyID[...]))
                    }
                }
            }
        }
    }

    /// The MAC's key: RFC 7292 appendix B.2 with SHA-256 and ID 3. One 32-byte block is the whole key, so B.2's
    /// step that feeds a block back into I never runs.
    static func macKey(_ pass: String, salt: [UInt8]) -> [UInt8] {
        let v = 64
        let bmp: [UInt8] = pass.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } + [0, 0]
        func stretched(_ bytes: [UInt8]) -> [UInt8] {
            (0..<(v * ((bytes.count + v - 1) / v))).map { bytes[$0 % bytes.count] }
        }
        var block = Array(SHA256.hash(data: [UInt8](repeating: 3, count: v) + stretched(salt) + stretched(bmp)))
        for _ in 1..<iterations { block = Array(SHA256.hash(data: block)) }
        return block
    }

    static func pbkdf2(_ pass: String, salt: [UInt8]) throws -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass, pass.utf8.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                          &key, key.count)
        guard status == kCCSuccess else { throw Failed() }
        return key
    }

    static func aes256CBC(_ plain: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, plain, plain.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw Failed() }
        return Array(out[..<moved])
    }

    static func random(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in generator.next() }
    }
}
