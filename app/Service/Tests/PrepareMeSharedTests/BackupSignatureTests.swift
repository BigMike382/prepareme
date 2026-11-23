import CryptoKit
import Foundation
import PrepareMeShared
import XCTest

/// The backup's signed list (concept-doc plan, phase B; owner, 2026-10-18: "Signed by the Mac"): manifest.json in the
/// backup folder carries a signature by the Mac app's own key and that key's public half, so a phone that learned the
/// key over the paired Wi-Fi channel knows the list came from its Mac. Made-up keys and lists only.
final class BackupSignatureTests: XCTestCase {
    let key = P256.Signing.PrivateKey()

    func entry(_ name: String = "prepareme-daily.zim", sha: Character = "a") -> Manifest.Entry {
        Manifest.Entry(name: name, id: "0f1e2d3c-4b5a-4968-8776-6554433221a1", kind: "library", size: 10,
                       sha256: String(repeating: sha, count: 64), deliveredAt: "2026-10-18T12:00:00-04:00")
    }

    func signed(_ manifest: Manifest) throws -> Data {
        try BackupSignature.sign(manifest, with: key)
    }

    func testASignedListVerifiesWithItsKeyAndStillReadsAsAList() throws {
        let manifest = Manifest(writtenAt: "2026-10-18T12:00:00-04:00", files: [entry()])
        let data = try signed(manifest)
        XCTAssertEqual(try Manifest.read(data), manifest)  // phase A's readers ignore the signature
        let read = try BackupSignature.read(data)
        XCTAssertEqual(read.manifest, manifest)
        XCTAssertEqual(read.verdict, .signed(key: BackupSignature.publicKey(of: key)))
    }

    func testAChangedListFailsItsSignature() throws {
        let data = try signed(Manifest(writtenAt: "2026-10-18T12:00:00-04:00", files: [entry()]))
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: String(repeating: "a", count: 64), with: String(repeating: "b", count: 64))
        XCTAssertEqual(try BackupSignature.read(Data(text.utf8)).verdict, .badSignature)
    }

    func testAListSignedByAnotherKeyNamesThatKey() throws {
        let other = P256.Signing.PrivateKey()
        let data = try BackupSignature.sign(Manifest(writtenAt: "x", files: [entry()]), with: other)
        let verdict = try BackupSignature.read(data).verdict
        XCTAssertEqual(verdict, .signed(key: BackupSignature.publicKey(of: other)))
        XCTAssertNotEqual(verdict, .signed(key: BackupSignature.publicKey(of: key)))
    }

    func testASwappedKeyOrSignatureFails() throws {
        let data = try signed(Manifest(writtenAt: "x", files: [entry()]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["key"] = BackupSignature.publicKey(of: P256.Signing.PrivateKey())
        XCTAssertEqual(try BackupSignature.read(JSONSerialization.data(withJSONObject: object)).verdict, .badSignature)
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["signature"] = "not a signature"
        XCTAssertEqual(try BackupSignature.read(JSONSerialization.data(withJSONObject: object)).verdict, .badSignature)
    }

    func testAListWithEveryOptionalFieldVerifies() throws {
        var full = entry()
        full.family = true
        full.title = "Wikipédia — 100 / ünïcode"
        full.libraryAsOf = "2026-10-18T12:00-04:00"
        full.sourcesChecked = "2026-10-18T12:00:00-04:00"
        let manifest = Manifest(writtenAt: "x", files: [full, entry("roads.zim")])
        XCTAssertEqual(try BackupSignature.read(signed(manifest)).verdict, .signed(key: BackupSignature.publicKey(of: key)))
    }

    /// Review of tasks 1 to 3: the signature covers the exact bytes the Mac wrote, never a re-encoding, so a phone on
    /// another OS version checks what was signed; those bytes' list must be the list read
    func testTheSignedBytesMustHoldTheListRead() throws {
        let data = try signed(Manifest(writtenAt: "x", files: [entry()]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["written_at"] = "changed at the top only"
        XCTAssertEqual(try BackupSignature.read(JSONSerialization.data(withJSONObject: object)).verdict, .badSignature)
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["signed"] = nil
        XCTAssertEqual(try BackupSignature.read(JSONSerialization.data(withJSONObject: object)).verdict, .badSignature)
    }

    func testAnUnsignedListSaysSo() throws {
        let data = try Manifest(writtenAt: "x", files: [entry()]).encoded()
        XCTAssertEqual(try BackupSignature.read(data).verdict, .unsigned)
    }

    func testADamagedListIsRefusedWhole() {
        XCTAssertThrowsError(try BackupSignature.read(Data("not json".utf8)))
        XCTAssertThrowsError(try BackupSignature.read(Data(#"{"written_at":"x","files":[{"name":"../x"}]}"#.utf8)))
    }

    func testAnExtraFieldChangesNothingRead() throws {
        let manifest = Manifest(writtenAt: "x", files: [entry()])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: signed(manifest)) as? [String: Any])
        object["planted"] = "ignored"
        let read = try BackupSignature.read(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(read.manifest, manifest)
        XCTAssertEqual(read.verdict, .signed(key: BackupSignature.publicKey(of: key)))
    }

    func testTheKeyIsMadeOnceAndKeptWhole() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-key-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("backup-signing.key")
        let first = try BackupSignature.loadOrMakeKey(at: file)
        let again = try BackupSignature.loadOrMakeKey(at: file)
        XCTAssertEqual(first.rawRepresentation, again.rawRepresentation)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0)  // the owner's only
        try Data("damaged".utf8).write(to: file)
        XCTAssertThrowsError(try BackupSignature.loadOrMakeKey(at: file))  // never quietly replaced
    }

    func testThePublicHalfFileRoundTrips() throws {
        let data = try BackupSignature.publicKeyFile(of: key)
        XCTAssertEqual(BackupSignature.readPublicKeyFile(data), BackupSignature.publicKey(of: key))
        XCTAssertNil(BackupSignature.readPublicKeyFile(Data("{}".utf8)))
        XCTAssertNil(BackupSignature.readPublicKeyFile(Data(#"{"key":"not base64 of a key"}"#.utf8)))
    }

    // MARK: Phase A's run signs what it writes

    func testTheBackupRunSignsBothItsLists() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-signed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("library")
        let folder = base.appendingPathComponent("PrepareMe Backup")
        let mirror = base.appendingPathComponent("backup/manifest.json")
        for dir in [source, folder] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let data = Data("daily".utf8)
        try data.write(to: source.appendingPathComponent("held-daily"))
        let daily = Manifest.Entry(name: "prepareme-daily.zim", id: "0f1e2d3c-4b5a-4968-8776-6554433221a1",
                                   kind: "library", size: Int64(data.count),
                                   sha256: try FileCheck.sha256(of: source.appendingPathComponent("held-daily")),
                                   deliveredAt: "2026-10-18T12:00:00-04:00")
        let plan = Backup.plan(delivery: Manifest(writtenAt: "x", files: [daily]),
                               held: ["prepareme-daily.zim": HeldFile(entry: daily, file: "held-daily")],
                               backup: nil, present: [:])
        let key = key
        try Backup.run(plan, source: source, folder: folder, mirror: mirror, writtenAt: "y",
                       signer: { try BackupSignature.sign($0, with: key) })
        let written = try BackupSignature.read(Data(contentsOf: folder.appendingPathComponent(Backup.manifestName)))
        XCTAssertEqual(written.verdict, .signed(key: BackupSignature.publicKey(of: key)))
        XCTAssertEqual(written.manifest.files, [daily])
        XCTAssertEqual(try BackupSignature.read(Data(contentsOf: mirror)).verdict, written.verdict)
    }
}
