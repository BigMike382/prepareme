import CoreImage
import Foundation
@testable import PrepareMeServer
@testable import PrepareMeShared
import XCTest

/// Plan phase 10: pairing from the Mac app. The app's side (PairingDesk) and the service's (PairingClerk) meet in a
/// fresh temporary folder, with a made-up fingerprint and host, as they meet in Application Support › PrepareMe ›
/// pairing.
final class PairingClerkTests: XCTestCase {
    var folder: URL!
    var desk: PairingDesk!
    var tokens: TokenStore!
    var lines: [String] = []
    let fingerprint = String(repeating: "b", count: 64)
    let now = Date(timeIntervalSince1970: 1_791_800_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-pairing-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        desk = PairingDesk(folder: folder.appendingPathComponent("pairing"))
        tokens = TokenStore(url: folder.appendingPathComponent("service/tokens.json"))
        try FileManager.default.createDirectory(at: tokens.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        lines = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func clerk(host: String? = "Made-Up-Mac.local") -> PairingClerk {
        PairingClerk(desk: desk, tokens: tokens, fingerprint: fingerprint, port: 8799, host: { host },
                     ip: { "192.168.1.20" })
    }

    func tick(_ clerk: PairingClerk? = nil, at: Date? = nil) {
        (clerk ?? self.clerk()).tick(now: at ?? now) { lines.append($0) }
    }

    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: desk.folder.path)) ?? []).sorted()
    }

    func testAnAdultsPhoneIsPairedAndItsCodeLetsThatPhoneIn() throws {
        let ask = try desk.askToPair(readOnly: false, now: now)
        XCTAssertNil(desk.answer(to: ask), "no answer before the service has looked")
        tick()
        guard case let .paired(paired) = desk.answer(to: ask) else { return XCTFail("not paired") }
        XCTAssertEqual(paired.label, "phone 1")
        XCTAssertFalse(paired.readOnly)
        let code = try PairingCode.read(paired.code)
        XCTAssertEqual(code.host, "Made-Up-Mac.local")
        XCTAssertEqual(code.ip, "192.168.1.20")
        XCTAssertEqual(code.port, 8799)
        XCTAssertEqual(code.fp, fingerprint)
        let phone = try XCTUnwrap(tokens.phone(for: code.token))
        XCTAssertEqual(phone.label, "phone 1")
        XCTAssertNil(phone.readOnly)
        XCTAssertEqual(phone.added, paired.added)
        XCTAssertEqual(files(), [PairingDesk.phonesName], "the request and the reply are both gone")
        XCTAssertEqual(lines, ["phone 1 paired from PrepareMe on the Mac"])
    }

    /// Unlisted plan, phase 3: a test service's clerk marks its codes; the family's Mac's never does.
    func testOnlyATestServicesClerkMarksItsCodes() throws {
        for test in [false, true] {
            let ask = try desk.askToPair(readOnly: false, now: now)
            tick(PairingClerk(desk: desk, tokens: tokens, fingerprint: fingerprint, port: 8799, test: test,
                              host: { "Made-Up-Mac.local" }, ip: { "192.168.1.20" }))
            guard case let .paired(paired) = desk.answer(to: ask) else { return XCTFail("not paired") }
            XCTAssertEqual(try PairingCode.read(paired.code).isTest, test)
        }
        let ask = try desk.askToPair(readOnly: false, now: now)
        tick()
        guard case let .paired(paired) = desk.answer(to: ask) else { return XCTFail("not paired") }
        XCTAssertFalse(try PairingCode.read(paired.code).isTest)
    }

    /// A phone shows as waiting for its first visit until its code first comes back to the service; one paired before
    /// visits were kept counts as visited (remaining-findings plan, Task 13.2; F42: Done without a scan had left an
    /// unused phone listed as paired).
    func testANewPhoneWaitsUntilItsFirstVisit() throws {
        let ask = try desk.askToPair(readOnly: false, now: now)
        tick()
        guard case let .paired(paired) = desk.answer(to: ask) else { return XCTFail("not paired") }
        XCTAssertEqual(desk.phones()?.map(\.waiting), [true], "listed, waiting")
        let token = try PairingCode.read(paired.code).token
        let phone = try XCTUnwrap(tokens.phone(for: token))
        try tokens.visited(phone)
        XCTAssertEqual(tokens.phone(for: token)?.waiting, nil, "visited")
        tick()
        XCTAssertEqual(desk.phones()?.map(\.waiting), [false])
        try tokens.visited(try XCTUnwrap(tokens.phone(for: token)))  // a second visit writes nothing new
        let older = #"{"phones":[{"label":"phone 9","sha256":"00","added":"2026-10-01T00:00:00Z"}]}"#
        try Data(older.utf8).write(to: tokens.url)
        tick()
        XCTAssertEqual(desk.phones()?.map(\.waiting), [false], "paired before visits were kept")
    }

    func testAChildsPhoneIsReadOnly() throws {
        let ask = try desk.askToPair(readOnly: true, now: now)
        tick()
        guard case let .paired(paired) = desk.answer(to: ask) else { return XCTFail("not paired") }
        XCTAssertTrue(paired.readOnly)
        XCTAssertEqual(tokens.phone(for: try PairingCode.read(paired.code).token)?.readOnly, true)
        XCTAssertEqual(desk.phones(), [PairingDesk.Phone(label: "phone 1", added: paired.added, readOnly: true,
                                                       waiting: true)])  // until its first visit (13.2)
    }

    /// The code holds the token, so the reply on disk holds neither readably, and only the asking key opens it.
    func testTheReplyOnDiskHoldsNoCodeAndOnlyTheAskingKeyOpensIt() throws {
        let ask = try desk.askToPair(readOnly: false, now: now)
        tick()
        let reply = desk.folder.appendingPathComponent("reply-\(ask.id).json")
        let onDisk = try Data(contentsOf: reply)
        let other = PairingDesk.Ask(id: ask.id, key: .init())
        XCTAssertEqual(desk.answer(to: other), .problem("the phones' service's answer couldn't be opened"))
        try onDisk.write(to: reply)
        guard case let .paired(paired) = desk.answer(to: ask) else { return XCTFail("not paired") }
        let token = try PairingCode.read(paired.code).token
        let text = String(decoding: onDisk, as: UTF8.self)
        XCTAssertFalse(text.contains(token))
        XCTAssertFalse(text.contains(fingerprint))
        XCTAssertFalse(text.contains("Made-Up-Mac"))
        // and a reply moved onto another request doesn't open either: the request's ID is part of the key
        let moved = PairingDesk.Ask(id: UUID().uuidString.lowercased(), key: ask.key)
        try onDisk.write(to: desk.folder.appendingPathComponent("reply-\(moved.id).json"))
        XCTAssertEqual(desk.answer(to: moved), .problem("the phones' service's answer couldn't be opened"))
    }

    func testARequestIsTakenOnce() throws {
        _ = try desk.askToPair(readOnly: false, now: now)
        tick()
        tick()
        XCTAssertEqual(try tokens.phones().count, 1)
    }

    func testAnOldRequestPairsNothing() throws {
        let ask = try desk.askToPair(readOnly: false, now: now.addingTimeInterval(-PairingDesk.requestMaxAge - 1))
        tick()
        XCTAssertNil(desk.answer(to: ask))
        XCTAssertEqual(try tokens.phones(), [])
        XCTAssertEqual(files(), [PairingDesk.phonesName], "the request is gone")
    }

    func testAWithdrawnRequestPairsNothing() throws {
        let ask = try desk.askToPair(readOnly: false, now: now)
        desk.withdraw(ask)
        tick()
        XCTAssertEqual(try tokens.phones(), [])
    }

    func testNoNetworkNameMeansNoPhone() throws {
        let ask = try desk.askToPair(readOnly: false, now: now)
        tick(clerk(host: nil))
        XCTAssertEqual(desk.answer(to: ask), .problem("the Mac's network name couldn't be read"))
        XCTAssertEqual(try tokens.phones(), [])
    }

    func testAKeyThatCantBeUsedLeavesNoPhone() throws {
        try desk.post(.init(v: 1, kind: .pair, at: PairingDesk.time(now), readOnly: false, key: "bm90IGEga2V5"),  // gitleaks:allow
                      id: "0f8f7a3c-1d2e-4b5a-9c8d-7e6f5a4b3c2d")
        tick()
        let ask = PairingDesk.Ask(id: "0f8f7a3c-1d2e-4b5a-9c8d-7e6f5a4b3c2d", key: nil)
        XCTAssertEqual(desk.answer(to: ask), .problem("the request's key couldn't be used"))
        XCTAssertEqual(try tokens.phones(), [])
    }

    func testUnpairingRemovesOnlyThePhoneWithThatLabelAndTime() throws {
        _ = try tokens.add(now: now)
        _ = try tokens.add(now: now, readOnly: true)
        tick()
        let listed = try XCTUnwrap(desk.phones())
        XCTAssertEqual(listed.map(\.label), ["phone 1", "phone 2"])
        // a list read before "phone 1" was removed and paired again can't remove the new one
        var stale = listed[0]
        stale.added = PairingDesk.time(now.addingTimeInterval(-86400))
        let wrong = try desk.askToUnpair(stale, now: now)
        tick()
        XCTAssertEqual(desk.answer(to: wrong), .removed(false))
        let right = try desk.askToUnpair(listed[0], now: now)
        tick()
        XCTAssertEqual(desk.answer(to: right), .removed(true))
        XCTAssertEqual(try tokens.phones().map(\.label), ["phone 2"])
        XCTAssertEqual(desk.phones()?.map(\.label), ["phone 2"])
        XCTAssertEqual(lines, ["phone 1 unpaired from PrepareMe on the Mac"])
    }

    /// The app's list never carries a token's hash, and follows a pairing made in Terminal.
    func testThePhoneListHoldsNoHashAndFollowsTheServicesList() throws {
        tick()
        XCTAssertEqual(desk.phones(), [], "the service is running and no phone is paired")
        _ = try tokens.add(now: now)
        tick()
        let text = try String(contentsOf: desk.folder.appendingPathComponent(PairingDesk.phonesName), encoding: .utf8)
        XCTAssertFalse(text.contains("sha256"))
        XCTAssertFalse(text.contains(try tokens.phones()[0].sha256))
        XCTAssertEqual(desk.phones()?.map(\.label), ["phone 1"])
    }

    func testAReplyLeftUnreadIsRemovedAfterFiveMinutes() throws {
        _ = try desk.askToPair(readOnly: false, now: now)
        tick()
        XCTAssertEqual(files().filter { $0.hasPrefix("reply-") }.count, 1)
        let reply = desk.folder.appendingPathComponent(files().first { $0.hasPrefix("reply-") }!)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-PairingDesk.replyMaxAge - 1)],
                                              ofItemAtPath: reply.path)
        tick()
        XCTAssertEqual(files().filter { $0.hasPrefix("reply-") }, [])
    }

    func testTheFolderIsTheAccountsAloneAndOddNamesAreLeftAlone() throws {
        tick()
        let mode = try FileManager.default.attributesOfItem(atPath: desk.folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        XCTAssertNil(PairingDesk.id(in: "request-../x.json", prefix: "request"))
        XCTAssertNil(PairingDesk.id(in: "request-0F8F7A3C-1D2E-4B5A-9C8D-7E6F5A4B3C2D.json", prefix: "request"))
        XCTAssertNil(PairingDesk.id(in: ".request-0f8f7a3c-1d2e-4b5a-9c8d-7e6f5a4b3c2d.json.tmp-1", prefix: "request"))
        XCTAssertEqual(PairingDesk.id(in: "request-0f8f7a3c-1d2e-4b5a-9c8d-7e6f5a4b3c2d.json", prefix: "request"),
                       "0f8f7a3c-1d2e-4b5a-9c8d-7e6f5a4b3c2d")
    }

    /// The picture on the Mac's screen reads back as the code, the way a phone's camera reads it.
    func testThePictureReadsBackAsTheCode() throws {
        let text = try PairingCode(host: "Made-Up-Mac.local", ip: "192.168.1.20", port: 8744, fp: fingerprint,
                                   token: Token.make()).text()
        let image = try XCTUnwrap(PairingPicture.image(text))
        XCTAssertEqual(image.width, image.height)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(found, [text])
    }
}
