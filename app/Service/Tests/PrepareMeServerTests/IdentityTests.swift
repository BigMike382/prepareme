import CryptoKit
import Foundation
@testable import PrepareMeServer
import Security
import Testing
import X509

/// The Mac's identity, made and loaded in a temporary folder only, never the owner's service folder. Swift Testing
/// (docs/app.md): each test has its own folder, and the openssl fixture is only read, so they may run in parallel.
final class IdentityTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-identity-test-\(UUID())")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func eachLoadProblemSaysWhatIsWrongAndOnlyAMissingIdentityAsksForInit() throws {
        #expect(throws: Identity.Problem.missing) { try Identity.load(from: self.folder) }
        #expect(Identity.Problem.missing.line == "run `prepareme-service init` first")
        try Identity.make(in: folder, days: 1)
        let (p12, pass) = Identity.files(in: folder)
        let bundle = try Data(contentsOf: p12)
        try FileManager.default.removeItem(at: pass)
        #expect(throws: Identity.Problem.unreadable) { try Identity.load(from: self.folder) }
        #expect(Identity.Problem.unreadable.line == "the Mac's identity is in the service folder but "
            + "couldn't be read; nothing changed, and `init` won't replace it (that would unpair every phone)")
        try Data("not its pass".utf8).write(to: pass)
        #expect(try Data(contentsOf: p12) == bundle)
        let problem = #expect(throws: Identity.Problem.self) { try Identity.load(from: self.folder) }
        guard case let .notImported(status) = problem else { Issue.record("\(String(describing: problem))"); return }
        #expect(status != errSecSuccess)  // a wrong pass is refused outright
        #expect(problem?.line == "the Mac's identity is in the service folder but macOS "
            + "won't load it (status \(status)); nothing changed, and `init` won't replace it (that would unpair "
            + "every phone)")
    }

    @Test func aMadeIdentityLoadsWithItsFingerprint() throws {
        try Identity.make(in: folder, days: 1)
        let first = try Identity.load(from: folder).fingerprint
        #expect(first.count == 64)
        #expect(try Identity.load(from: folder).fingerprint == first)
        #expect(throws: Identity.Problem.exists) { try Identity.make(in: self.folder) }
    }

    @Test func aMadeCertificateIsTheOneOpensslMade() throws {
        // `openssl req -new -x509 -days N -sha256 -subj "/CN=PrepareMe Mac"` (LibreSSL 3.3.6): version 1, no
        // extensions, the subject its own issuer, ECDSA with SHA-256 over a P-256 key, valid from now for N days.
        let before = Date()
        try Identity.make(in: folder, days: 3650)
        var secCertificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(try Identity.load(from: folder).identity, &secCertificate) == errSecSuccess)
        let certificate = try Certificate(try #require(secCertificate))
        #expect(certificate.version == .v1)
        #expect(certificate.subject == (try DistinguishedName { CommonName("PrepareMe Mac") }))
        #expect(certificate.issuer == certificate.subject)
        #expect(certificate.signatureAlgorithm == .ecdsaWithSHA256)
        #expect(Array(certificate.extensions).isEmpty)
        #expect(P256.Signing.PublicKey(certificate.publicKey) != nil)
        #expect(certificate.publicKey.isValidSignature(certificate.signature, for: certificate))
        #expect(abs(certificate.notValidBefore.timeIntervalSince(before)) < 2)
        #expect(abs(certificate.notValidAfter.timeIntervalSince(certificate.notValidBefore) - 3650 * 86_400) < 1)
    }

    /// An identity made by the old `make` (/usr/bin/openssl, LibreSSL 3.3.6, 2026-10-28) with a made-up pass: the
    /// shape of the one in the owner's service folder, which is never remade and must keep loading.
    static let opensslIdentity = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/openssl-identity")
    static let opensslFingerprint = "2a6825ac1e09173d6f752fd5ba2ce37a81be981af1da7481e3a03e99637e9f2b"  // by openssl

    @Test func anIdentityOpensslMadeStillLoadsWithTheSameFingerprint() throws {
        #expect(try Identity.load(from: Self.opensslIdentity).fingerprint == Self.opensslFingerprint)
        #expect(throws: Identity.Problem.exists) { try Identity.make(in: Self.opensslIdentity) }
    }
}
