import CryptoKit
import Foundation
import PrepareMeShared
import XCTest

/// The manifest, file names, pairing codes, tokens and private addresses, which every phone and the Mac must agree on.
final class ManifestAndPairingTests: XCTestCase {
    let sha = String(repeating: "a", count: 64)

    func entry(name: String = "a.zim", kind: String = "library", size: Int64 = 5, sha256: String? = nil)
        -> Manifest.Entry
    {
        Manifest.Entry(name: name, id: "id-1", kind: kind, size: size, sha256: sha256 ?? sha,
                       deliveredAt: "2026-10-12T00:00:00Z")
    }

    func read(_ entries: [Manifest.Entry]) throws -> Manifest {
        try Manifest.read(Manifest(writtenAt: "2026-10-12T00:00:00Z", files: entries).encoded())
    }

    func testAGoodManifestRoundTripsThroughEncodedAndRead() throws {
        let original = Manifest(writtenAt: "2026-10-12T00:00:00Z", files: [
            entry(), Manifest.Entry(name: "b.zim", id: "id-2", kind: "map", size: 0, sha256: sha,
                                    deliveredAt: "x", libraryAsOf: "y", sourcesChecked: "z"),
        ])
        XCTAssertEqual(try Manifest.read(original.encoded()), original)
    }

    /// Plan phase 2: the packer writes the manifest (packer/manifest.py); this is one it wrote, kept the same as the
    /// packer's output by packer/tests/test_manifest.py, with made-up IDs and contents.
    func testAManifestThePackerWroteIsRead() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/packer-manifest.json")
        let manifest = try Manifest.read(Data(contentsOf: fixture))
        XCTAssertEqual(manifest.writtenAt, "2026-10-13T09:30:00+00:00")
        XCTAssertEqual(manifest.files.map(\.name),
                       ["prepareme-daily.zim", "prepareme-maps-roads.zim", "prepareme-maps-today-1.zim",
                        "family_en_2026-08.zim", "mac_en_2026-08.zim"])
        XCTAssertEqual(manifest.files.map(\.kind), ["library", "map-core", "map-optional", "download", "download"])
        XCTAssertEqual(manifest.files.map(\.forPhones), [true, true, true, true, false])  // plan phase 8
        XCTAssertEqual(manifest.files[3].title, "Made-up family_en_2026-08")
        XCTAssertNil(manifest.files[0].family)
        let contents = ["made-up daily library", "made-up roads map", "made-up topo map"]
        for (entry, text) in zip(manifest.files, contents) {
            XCTAssertEqual(entry.size, Int64(text.utf8.count), entry.name)
            XCTAssertEqual(entry.sha256, Hex.string(SHA256.hash(data: Data(text.utf8))), entry.name)
            XCTAssertEqual(entry.deliveredAt, "2026-10-13T05:30:00-04:00")
        }
        XCTAssertEqual(manifest.files[0].libraryAsOf, "2026-10-12T21:00-04:00")
        XCTAssertEqual(manifest.files[0].sourcesChecked, "2026-10-11T21:00:00-04:00")
        XCTAssertNil(manifest.files[1].libraryAsOf, "null in the packer's file")
        XCTAssertNil(manifest.files[2].sourcesChecked)
        XCTAssertEqual(manifest.files.map(\.fetch), ["base", "room", "room", nil, nil])  // phase M: downloads on request
        XCTAssertEqual(manifest.files.map(\.order), [nil, 1, 300, nil, nil])
        // library redesign plan 2.3: a line's card facts, nil where the packer had none
        XCTAssertEqual(manifest.files[3].about, "Made-up water documents.")
        XCTAssertEqual(manifest.files[3].inside, "3 documents, including A, B and C")
        XCTAssertEqual(manifest.files[3].source, "Kiwix · example.org")
        XCTAssertNil(manifest.files[4].about)
    }

    /// Library redesign plan 2.3: a manifest from before the card decodes, its four new fields nil.
    func testEntryDecodesWithoutNewFields() throws {
        let json = #"{"written_at":"x","files":[{"name":"a.zim","id":"i","kind":"library","size":5,"sha256":"\#(sha)","delivered_at":"d"}]}"#
        let found = try Manifest.read(Data(json.utf8)).files[0]
        XCTAssertNil(found.about)
        XCTAssertNil(found.inside)
        XCTAssertNil(found.source)
        XCTAssertNil(found.origin)
    }

    /// The Mac's service re-encodes the manifest for the phones, so a field missing from `Entry` would never reach one.
    func testEntryRoundTripsNewFields() throws {
        var card = entry(kind: "download")
        card.about = "Water treatment documents."
        card.inside = "7 documents, including A, B and C"
        card.source = "cdc.gov"
        card.origin = "outside"
        XCTAssertEqual(try read([card]).files[0], card)
    }

    func testABadNameRefusesTheWholeManifest() {
        for name in ["a/b.zim", "../x", ".hidden", ""] {
            XCTAssertThrowsError(try read([entry(), entry(name: name)]), name) { error in
                XCTAssertEqual(error as? Manifest.Problem, .badName(name))
            }
        }
    }

    func testAnUnknownKindANegativeSizeAndABadHashAreRefused() {
        XCTAssertThrowsError(try read([entry(kind: "bogus")])) { XCTAssertEqual($0 as? Manifest.Problem, .badKind) }
        XCTAssertThrowsError(try read([entry(size: -1)])) { XCTAssertEqual($0 as? Manifest.Problem, .badSize) }
        for bad in [String(repeating: "A", count: 64), String(repeating: "a", count: 63), ""] {
            XCTAssertThrowsError(try read([entry(sha256: bad)])) {
                XCTAssertEqual($0 as? Manifest.Problem, .badHash)
            }
        }
    }

    func testTwoEntriesWithOneNameAreRefused() {
        XCTAssertThrowsError(try read([entry(), entry()])) {
            XCTAssertEqual($0 as? Manifest.Problem, .twoWithOneName)
        }
    }

    func testPlainFileNamesAllowTwoHundredCharactersAndNoMore() {
        XCTAssertFalse(FileName.isPlain(""))
        XCTAssertTrue(FileName.isPlain(String(repeating: "a", count: 200)))
        XCTAssertFalse(FileName.isPlain(String(repeating: "a", count: 201)))
        XCTAssertTrue(FileName.isPlain("a-b_c.1.zim"))
        XCTAssertFalse(FileName.isPlain("a b"))
        XCTAssertFalse(FileName.isPlain("é.zim"))
    }

    func json(_ changes: [String: Any?] = [:]) -> String {
        var object: [String: Any] = ["v": 1, "host": "mac-1.local", "ip": "192.168.1.5", "port": 8443,
                                     "fp": sha, "token": Token.make()]
        for (key, value) in changes { object[key] = value ?? NSNull() }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testAGoodPairingCodeRoundTripsThroughText() throws {
        let code = PairingCode(host: "mac-1.local", ip: "10.0.0.2", port: 8443, fp: sha, token: Token.make())
        XCTAssertEqual(try PairingCode.read(code.text()), code)
        XCTAssertEqual(try PairingCode.read("  " + code.text() + "\n"), code)
        let curled = try code.text().replacingOccurrences(of: "\"", with: "\u{201C}")  // typed or passed through Notes (F46)
        XCTAssertEqual(try PairingCode.read(curled), code)
    }

    func testPairingCodesThatCouldPointElsewhereAreRefused() {
        func problem(_ text: String) -> PairingCode.Problem? {
            do { _ = try PairingCode.read(text); return nil } catch { return error as? PairingCode.Problem }
        }
        XCTAssertNil(problem(json()))
        XCTAssertEqual(problem("not json"), .notACode)
        XCTAssertEqual(problem(json(["v": 3])), .badVersion)  // 2 is a test service's (Unlisted plan, phase 3)
        XCTAssertEqual(problem(json(["host": "mac-1"])), .badHost)
        XCTAssertEqual(problem(json(["host": "-x.local"])), .badHost)
        XCTAssertEqual(problem(json(["host": "a b.local"])), .badHost)
        XCTAssertEqual(problem(json(["ip": "8.8.8.8"])), .badAddress)
        XCTAssertEqual(problem(json(["port": 0])), .badPort)
        XCTAssertEqual(problem(json(["port": 70000])), .badPort)
        XCTAssertEqual(problem(json(["fp": "xyz"])), .badFingerprint)
        XCTAssertEqual(problem(json(["token": String(repeating: "a", count: 42)])), .badToken)
        XCTAssertEqual(problem(json(["token": String(repeating: "a", count: 42) + "+"])), .badToken)
        XCTAssertEqual(problem(json(["token": String(repeating: "a", count: 42) + "/"])), .badToken)
    }

    /// Unlisted plan, phase 3: a test service's code is version 2 and reads back as one; the family's Mac's code is
    /// exactly version 1 with no new key, so its text is as before.
    func testOnlyATestServicesCodeIsVersionTwo() throws {
        let family = PairingCode(host: "mac-1.local", ip: "10.0.0.2", port: 8744, fp: sha, token: Token.make())
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(family.text().utf8)) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["v", "host", "ip", "port", "fp", "token"])
        XCTAssertTrue(try family.text().contains("\"v\":1"))
        XCTAssertFalse(try PairingCode.read(family.text()).isTest)
        let test = PairingCode(host: "mac-1.local", ip: "10.0.0.2", port: 8799, fp: sha, token: Token.make(), test: true)
        XCTAssertTrue(try test.text().contains("\"v\":2"))
        XCTAssertTrue(try PairingCode.read(test.text()).isTest)
        XCTAssertFalse(try PairingCode.read(json([:])).isTest)
        XCTAssertThrowsError(try PairingCode.read(json(["v": 3])))
    }

    /// The reason for version 2: the family's app already on every device must refuse a test code, so a test service
    /// reachable on the home network can never replace its pairing. Its reader (Pairing.swift on main before phase 3,
    /// copied here as it was) decodes the six keys, ignoring any other, and refuses anything but version 1.
    func testTheInstalledFamilyAppsReaderRefusesATestCodeAndTakesTheMacs() throws {
        struct InstalledCode: Decodable { var v: Int; var host: String; var ip: String?; var port: Int; var fp: String
                                          var token: String }
        func installedReaderKeeps(_ text: String) -> Bool {
            guard let code = try? JSONDecoder().decode(InstalledCode.self, from: Data(text.utf8)) else { return false }
            return code.v == 1
        }
        let test = PairingCode(host: "mac-1.local", ip: "10.0.0.2", port: 8799, fp: sha, token: Token.make(), test: true)
        XCTAssertFalse(installedReaderKeeps(try test.text()))
        let family = PairingCode(host: "mac-1.local", ip: "10.0.0.2", port: 8744, fp: sha, token: Token.make())
        XCTAssertTrue(installedReaderKeeps(try family.text()))
    }

    /// Who keeps which code: PrepareMe Dev only a test service's, anywhere; the family's PrepareMe the family's Mac's
    /// anywhere, and a test service's only in a simulator (the owner's choice with the phase 3 plan, 2026-11-22).
    func testPrepareMeDevKeepsOnlyTestCodesAndTheFamilysAppOnlyTheMacsOnADevice() {
        let family = PairingCode(host: "mac-1.local", ip: "10.0.0.2", port: 8744, fp: sha, token: Token.make())
        let test = PairingCode(host: "mac-1.local", ip: "10.0.0.2", port: 8799, fp: sha, token: Token.make(), test: true)
        for simulator in [false, true] {
            XCTAssertFalse(family.keptBy(dev: true, simulator: simulator))
            XCTAssertTrue(test.keptBy(dev: true, simulator: simulator))
            XCTAssertTrue(family.keptBy(dev: false, simulator: simulator))
        }
        XCTAssertFalse(test.keptBy(dev: false, simulator: false))
        XCTAssertTrue(test.keptBy(dev: false, simulator: true))
    }

    func testACodeWithoutAnIPAddressIsAccepted() throws {
        XCTAssertNil(try PairingCode.read(json(["ip": nil])).ip)
    }

    func testTokensAre43WellFormedCharactersAndDiffer() {
        let first = Token.make(), second = Token.make()
        XCTAssertEqual(first.count, 43)
        XCTAssertTrue(Token.isWellFormed(first))
        XCTAssertNotEqual(first, second)
    }

    func testPrivateAddressesAreOnlyTheHomeRanges() {
        for yes in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.1.1", "127.0.0.1"] {
            XCTAssertTrue(PrivateAddress.isPrivateIPv4(yes), yes)
        }
        for no in ["172.15.0.1", "172.32.0.1", "8.8.8.8", "192.169.0.1", "010.0.0.1", "256.1.1.1", "1.2.3", "::1",
                   "fe80::1", ""] {
            XCTAssertFalse(PrivateAddress.isPrivateIPv4(no), no)
        }
    }
}
