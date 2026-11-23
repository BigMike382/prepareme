import Foundation
@testable import PrepareMeServer
import PrepareMeShared
import XCTest

/// Concept-doc plan, phase M: each phone tells the Mac its room (`POST /storage`), kept by its label in the pairing
/// folder; and the owner's Always or Never per file per phone reaches only that phone's list. Made-up files in a fresh
/// temporary folder, no network.
final class PhoneRoomTests: XCTestCase {
    var root: URL!
    var served: URL!
    var pairing: URL!
    var tokens: TokenStore!
    var router: Router!
    var first = "", second = ""
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-room-\(UUID())")
        served = root.appendingPathComponent("delivery")
        pairing = root.appendingPathComponent("pairing")
        for dir in [served!, pairing!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        tokens = TokenStore(url: root.appendingPathComponent("tokens.json"))
        first = try tokens.add(now: now).token
        second = try tokens.add(now: now, readOnly: true).token
        router = Router(folder: served, tokens: tokens, counts: CountsStore(url: root.appendingPathComponent("c.json")),
                        manifestOnly: true, pairing: pairing)
        let files = [("prepareme-daily.zim", "base"), ("prepareme-maps-roads.zim", "room")].map { name, fetch in
            Manifest.Entry(name: name, id: UUID().uuidString, kind: "library", size: 10,
                           sha256: String(repeating: "a", count: 64), deliveredAt: "2026-10-18T12:00:00-04:00",
                           fetch: fetch)
        }
        var listed = Manifest(writtenAt: "x", files: files)
        listed.choices = ["prepareme-maps-roads.zim": "always"]  // planted in the delivery list: never served
        try listed.encoded().write(to: served.appendingPathComponent("manifest.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func send(_ method: String, _ path: String, token: String?, body: Data = Data()) -> Reply {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer " + token }
        return router.reply(to: HTTPRequest(method: method, path: path, headers: headers, body: body), now: now).0
    }

    func served(_ token: String) throws -> Manifest {
        guard case let .bytes(_, _, body) = send("GET", "/manifest.json", token: token) else { throw POSIXError(.EIO) }
        return try Manifest.read(body)
    }

    func testAPairedPhonesReportIsKeptByItsLabel() throws {
        let report = PhoneStorage(free: 20_000_000_000, capacity: 128_000_000_000, held: ["prepareme-daily.zim"],
                                  waiting: ["prepareme-maps-roads.zim"], cantUpdate: [])
        XCTAssertEqual(send("POST", "/storage", token: first, body: try JSONEncoder().encode(report)).status, 204)
        let kept = PhoneStorage.readAll(try Data(contentsOf: pairing.appendingPathComponent(PhoneStorage.fileName)))
        XCTAssertEqual(kept.keys.sorted(), ["phone 1"])
        XCTAssertEqual(kept["phone 1"]?.waiting, ["prepareme-maps-roads.zim"])
        XCTAssertNotNil(kept["phone 1"]?.at)
        let added = try XCTUnwrap(tokens.phones().first { $0.label == "phone 1" }).added
        XCTAssertEqual(kept["phone 1"]?.paired, added)
        XCTAssertNotNil(PhoneStorage.current(kept, label: "phone 1", paired: added))
        XCTAssertNil(PhoneStorage.current(kept, label: "phone 1", paired: "another pairing"))
    }

    /// Offline fixes, phase 2: the install's date goes through the service whole, and a report without it still reads
    func testTheInstallsDateIsKeptAndAnOlderPhonesReportStillReads() throws {
        var report = PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [])
        report.opensUntil = "2027-10-01T12:00:00Z"
        XCTAssertEqual(send("POST", "/storage", token: first, body: try JSONEncoder().encode(report)).status, 204)
        let kept = PhoneStorage.readAll(try Data(contentsOf: pairing.appendingPathComponent(PhoneStorage.fileName)))
        XCTAssertEqual(kept["phone 1"]?.opensUntil, "2027-10-01T12:00:00Z")
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("\"opens_until\""))
        let older = Data(#"{"free":1,"capacity":2,"held":[],"waiting":[],"cant_update":[]}"#.utf8)
        XCTAssertNil(try PhoneStorage.read(older).opensUntil)
        XCTAssertNil(try PhoneStorage.read(older).organicMaps)
        XCTAssertNil(try PhoneStorage.read(older).organicMapsLine, "an older app's phone: the Mac shows nothing")
    }

    /// Hand-off plan, 3.2: whether Organic Maps is on the phone goes through the service whole, under its own key, and
    /// only a phone without it gets the Phones list's amber line
    func testOrganicMapsGoesThroughAndOnlyMissingGetsALine() throws {
        var report = PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [], organicMaps: false)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("\"organic_maps\":false"))
        XCTAssertEqual(send("POST", "/storage", token: first, body: try JSONEncoder().encode(report)).status, 204)
        let kept = PhoneStorage.readAll(try Data(contentsOf: pairing.appendingPathComponent(PhoneStorage.fileName)))
        XCTAssertEqual(kept["phone 1"]?.organicMaps, false)
        XCTAssertEqual(kept["phone 1"]?.organicMapsLine, "Organic Maps: not installed")
        report.organicMaps = true
        XCTAssertNil(report.organicMapsLine)
    }

    func testAPhoneUnseenForAWeekGetsItsLine() {
        var report = PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [])
        XCTAssertNil(report.unseenLine(now: now))
        report.at = ISO8601DateFormatter().string(from: now.addingTimeInterval(-6.9 * 86400))
        XCTAssertNil(report.unseenLine(now: now))
        report.at = ISO8601DateFormatter().string(from: now.addingTimeInterval(-7.1 * 86400))
        let line = try? XCTUnwrap(report.unseenLine(now: now))
        XCTAssertTrue(line?.hasPrefix("Not heard from in 7 days (last ") == true, line ?? "")
    }

    func testTheInstallsLineTurnsAmberWithin60Days() throws {
        var report = PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [])
        XCTAssertNil(report.installLine(now: now))
        report.opensUntil = ISO8601DateFormatter().string(from: now.addingTimeInterval(183.5 * 86400))
        let far = try XCTUnwrap(report.installLine(now: now))
        XCTAssertFalse(far.caution)
        XCTAssertEqual(far.text, "Its install opens until \(ISO8601DateFormatter().date(from: report.opensUntil!)!.formatted(date: .long, time: .omitted)).")
        // the cable clock: six months left is amber, with what to do
        report.opensUntil = ISO8601DateFormatter().string(from: now.addingTimeInterval(150.5 * 86400))
        let renew = try XCTUnwrap(report.installLine(now: now))
        XCTAssertTrue(renew.caution)
        XCTAssertTrue(renew.text.hasSuffix(" (150 days): plug it into the Mac and install again to start a new year."),
                      renew.text)
        report.opensUntil = ISO8601DateFormatter().string(from: now.addingTimeInterval(61.5 * 86400))
        XCTAssertTrue(try XCTUnwrap(report.installLine(now: now)).text.hasSuffix(" (61 days): plug it into the Mac and install again to start a new year."))
        report.opensUntil = ISO8601DateFormatter().string(from: now.addingTimeInterval(59.5 * 86400))
        let near = try XCTUnwrap(report.installLine(now: now))
        XCTAssertTrue(near.caution)
        XCTAssertTrue(near.text.hasSuffix(" (59 days): reinstall it from the Mac."), near.text)
    }

    /// Review: a phone holding everything sends a report well over the 1 KB other posts may carry; only /storage may
    func testAFullPhonesReportFitsThroughTheRequestParserAndOthersStillDont() throws {
        let names = (1...40).map { "prepareme-maps-topo-today-\($0)-a-long-made-up-name.zim" }
        let body = try JSONEncoder().encode(PhoneStorage(free: 123_456_789_012, capacity: 512_000_000_000, held: names,
                                                         waiting: names, cantUpdate: []))
        XCTAssertGreaterThan(body.count, 4096)
        func head(_ path: String, _ length: Int) -> Data {
            Data("POST \(path) HTTP/1.1\r\nHost: x\r\nContent-Length: \(length)\r\n\r\n".utf8)
        }
        guard case .request = HTTP.parseHead(head(HTTP.storagePath, body.count)) else { return XCTFail("refused") }
        XCTAssertEqual(HTTP.parseHead(head(HTTP.storagePath, PhoneStorage.maxBytes + 1)), .refused(413))
        XCTAssertEqual(HTTP.parseHead(head("/counts", body.count)), .refused(413))
        XCTAssertEqual(send("POST", "/storage", token: first, body: body).status, 204)
    }

    /// Review: labels are reused (a new phone takes the lowest free one), so a removed phone's report and choices must
    /// never reach the next phone given its label
    func testANewPhoneOnAReusedLabelGetsNoneOfTheRemovedPhonesChoices() throws {
        let report = try JSONEncoder().encode(PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: []))
        XCTAssertEqual(send("POST", "/storage", token: first, body: report).status, 204)
        let old = try XCTUnwrap(tokens.phones().first { $0.label == "phone 1" }).added
        let all = ["phone 1": PhoneChoices.Entry(paired: old, files: ["prepareme-maps-roads.zim": "always"])]
        try PhoneChoices.encoded(all).write(to: pairing.appendingPathComponent(PhoneChoices.fileName))
        XCTAssertEqual(try served(first).choices, ["prepareme-maps-roads.zim": "always"])
        XCTAssertTrue(try tokens.remove(label: "phone 1"))
        let reused = try tokens.add(now: now.addingTimeInterval(60))
        XCTAssertEqual(reused.label, "phone 1")
        XCTAssertNil(try served(reused.token).choices)
        let kept = PhoneStorage.readAll(try Data(contentsOf: pairing.appendingPathComponent(PhoneStorage.fileName)))
        let added = try XCTUnwrap(tokens.phones().first { $0.label == "phone 1" }).added
        XCTAssertNil(PhoneStorage.current(kept, label: "phone 1", paired: added))
    }

    func testAReportWithNoTokenADamagedOneOrABadNameIsRefused() throws {
        let good = try JSONEncoder().encode(PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: []))
        XCTAssertEqual(send("POST", "/storage", token: nil, body: good).status, 401)
        XCTAssertEqual(send("POST", "/storage", token: first, body: Data("not json".utf8)).status, 400)
        let bad = try JSONEncoder().encode(PhoneStorage(free: 1, capacity: 2, held: ["../x"], waiting: [], cantUpdate: []))
        XCTAssertEqual(send("POST", "/storage", token: first, body: bad).status, 400)
        let negative = try JSONEncoder().encode(PhoneStorage(free: -1, capacity: 2, held: [], waiting: [], cantUpdate: []))
        XCTAssertEqual(send("POST", "/storage", token: first, body: negative).status, 400)
        XCTAssertEqual(send("GET", "/storage", token: first).status, 405)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairing.appendingPathComponent(PhoneStorage.fileName).path))
    }

    func testEachPhoneGetsOnlyItsOwnChoicesAndNeverOnABaseFile() throws {
        XCTAssertNil(try served(first).choices)  // the delivery list's own choices are never served
        let added = Dictionary(uniqueKeysWithValues: try tokens.phones().map { ($0.label, $0.added) })
        let all = ["phone 1": PhoneChoices.Entry(paired: added["phone 1"]!, files: [
                       "prepareme-maps-roads.zim": "never", "prepareme-daily.zim": "never", "gone.zim": "always"]),
                   "phone 2": PhoneChoices.Entry(paired: added["phone 2"]!, files: [
                       "prepareme-maps-roads.zim": "always", "prepareme-daily.zim": "sometimes"])]
        try PhoneChoices.encoded(all).write(to: pairing.appendingPathComponent(PhoneChoices.fileName))
        XCTAssertEqual(try served(first).choices, ["prepareme-maps-roads.zim": "never"])
        XCTAssertEqual(try served(second).choices, ["prepareme-maps-roads.zim": "always"])
        try Data("damaged".utf8).write(to: pairing.appendingPathComponent(PhoneChoices.fileName))
        XCTAssertNil(try served(first).choices)
    }

    /// Owner, 2026-11-15: every phone skips the older topo, a child's phone every map after the topo overview, and an
    /// adult's every today's topo band but the one nearest home, which it takes always; each unless the Mac set that
    /// phone's choice. The base and the overview come by room as before
    func testAChildsPhoneStopsAfterTheOverviewAndNoPhoneTakesTheOlderTopo() throws {
        let map = { (name: String, fetch: String, order: Int?) in
            Manifest.Entry(name: name, id: UUID().uuidString, kind: "map", size: 10,
                           sha256: String(repeating: "a", count: 64), deliveredAt: "2026-10-18T12:00:00-04:00",
                           fetch: fetch, order: order)
        }
        let listed = Manifest(writtenAt: "x", files: [
            map("prepareme-maps-home-topo.zim", "base", nil), map("prepareme-maps-roads.zim", "room", 1),
            map("prepareme-maps-topo-overview.zim", "room", 4), map("prepareme-maps-border-north.zim", "room", 5),
            map("prepareme-maps-topo-today-3.zim", "room", 101), map("prepareme-maps-topo-today-4.zim", "room", 102),
            map("prepareme-maps-topo-older-1.zim", "room", 201)])
        try listed.encoded().write(to: served.appendingPathComponent("manifest.json"))
        // the adult's: today's band nearest home (first in the order) always, the other bands and the older topo never
        XCTAssertEqual(try served(first).choices, ["prepareme-maps-topo-today-3.zim": "always",
                                                   "prepareme-maps-topo-today-4.zim": "never",
                                                   "prepareme-maps-topo-older-1.zim": "never"])
        XCTAssertEqual(try served(second).choices, ["prepareme-maps-border-north.zim": "never",
                                                    "prepareme-maps-topo-today-3.zim": "never",
                                                    "prepareme-maps-topo-today-4.zim": "never",
                                                    "prepareme-maps-topo-older-1.zim": "never"])
        let added = Dictionary(uniqueKeysWithValues: try tokens.phones().map { ($0.label, $0.added) })
        let all = ["phone 1": PhoneChoices.Entry(paired: added["phone 1"]!, files: ["prepareme-maps-topo-older-1.zim": "always"]),
                   "phone 2": PhoneChoices.Entry(paired: added["phone 2"]!, files: ["prepareme-maps-border-north.zim": "always"])]
        try PhoneChoices.encoded(all).write(to: pairing.appendingPathComponent(PhoneChoices.fileName))
        XCTAssertEqual(try served(first).choices?["prepareme-maps-topo-older-1.zim"], "always")
        XCTAssertEqual(try served(second).choices?["prepareme-maps-border-north.zim"], "always")
        XCTAssertEqual(try served(second).choices?["prepareme-maps-topo-today-3.zim"], "never")
    }

    /// Library plan, task 1.3: the Mac's shelf rides to every phone in the list it reads; none, or a damaged one, and
    /// the list is served all the same with no shelf (the phone then shows the starting placement)
    func testPhonesGetTheMacsLibraryShelf() throws {
        XCTAssertNil(try served(first).shelf)
        var shelf = LibraryShelf.starting
        shelf.placed["phet_en_all"] = "reference"
        try shelf.encoded().write(to: pairing.appendingPathComponent(LibraryShelf.fileName))
        XCTAssertEqual(try served(first).shelf, shelf)
        XCTAssertEqual(try served(second).shelf, shelf)
        try Data("damaged".utf8).write(to: pairing.appendingPathComponent(LibraryShelf.fileName))
        XCTAssertNil(try served(first).shelf)
    }

    func testAListFromBeforeTheShelfStillReads() throws {
        let old = Data(#"{"written_at":"2026-10-01T00:00:00Z","files":[]}"#.utf8)
        XCTAssertNil(try Manifest.read(old).shelf)
    }

    /// Phase K, finding 16: a download the Mac keeps for itself (`family: false`, or none given) is never named to a
    /// phone, not even through a choice the owner set on it for that phone
    func testAFamilyFalseDownloadIsNeverInAPhonesChoices() throws {
        let entry = { (name: String, family: Bool?) in
            Manifest.Entry(name: name, id: UUID().uuidString, kind: "download", size: 10,
                           sha256: String(repeating: "b", count: 64), deliveredAt: "2026-10-18T12:00:00-04:00",
                           family: family, fetch: "room")
        }
        var listed = try Manifest.read(Data(contentsOf: served.appendingPathComponent("manifest.json")))
        listed.files += [entry("made-up-macs-own.pdf", false), entry("made-up-unmarked.pdf", nil),
                         entry("made-up-family.pdf", true)]
        try listed.encoded().write(to: served.appendingPathComponent("manifest.json"))
        let added = try XCTUnwrap(tokens.phones().first { $0.label == "phone 1" }).added
        let all = ["phone 1": PhoneChoices.Entry(paired: added, files: [
            "made-up-macs-own.pdf": "always", "made-up-unmarked.pdf": "always", "made-up-family.pdf": "always"])]
        try PhoneChoices.encoded(all).write(to: pairing.appendingPathComponent(PhoneChoices.fileName))
        let manifest = try served(first)
        XCTAssertEqual(manifest.choices, ["made-up-family.pdf": "always"])
        XCTAssertEqual(manifest.files.map(\.name).filter { $0.hasPrefix("made-up-") }, ["made-up-family.pdf"])
        try Data("made up".utf8).write(to: served.appendingPathComponent("made-up-macs-own.pdf"))
        XCTAssertEqual(send("GET", "/files/made-up-macs-own.pdf", token: first).status, 404)
    }

    /// Family downloads plan, phase 3: a file the Mac set to Never ("hide") for one device is out of that device's list
    /// and its shelf lines, answered 404 to it and named in its `drop`; the other device is untouched; a base file is
    /// never hidden, and a stored "never" is still served as "never" (Offered)
    func testANeverFileIsWithheldFromThatDeviceOnly() throws {
        var listed = try Manifest.read(Data(contentsOf: served.appendingPathComponent("manifest.json")))
        listed.files.append(Manifest.Entry(name: "made-up-family.zim", id: UUID().uuidString, kind: "download",
                                           size: 10, sha256: String(repeating: "b", count: 64),
                                           deliveredAt: "2026-10-18T12:00:00-04:00", family: true))
        try listed.encoded().write(to: served.appendingPathComponent("manifest.json"))
        try Data("made up".utf8).write(to: served.appendingPathComponent("prepareme-maps-roads.zim"))
        var shelf = LibraryShelf.starting
        shelf.placed = ["prepareme-maps-roads": "reference", "made-up-family": "skills"]
        shelf.descriptions = ["prepareme-maps-roads": "Made-up roads."]
        try shelf.encoded().write(to: pairing.appendingPathComponent(LibraryShelf.fileName))
        let added = try XCTUnwrap(tokens.phones().first { $0.label == "phone 1" }).added
        let all = ["phone 1": PhoneChoices.Entry(paired: added, files: [
            "prepareme-maps-roads.zim": PhoneChoices.hide, "prepareme-daily.zim": PhoneChoices.hide,
            "made-up-family.zim": PhoneChoices.never])]
        try PhoneChoices.encoded(all).write(to: pairing.appendingPathComponent(PhoneChoices.fileName))

        let mine = try served(first)
        XCTAssertEqual(mine.files.map(\.name), ["prepareme-daily.zim", "made-up-family.zim"])
        XCTAssertEqual(mine.drop, ["prepareme-maps-roads.zim"])
        XCTAssertEqual(mine.choices, ["made-up-family.zim": "never"])
        XCTAssertEqual(mine.shelf?.placed, ["made-up-family": "skills"])
        XCTAssertEqual(mine.shelf?.descriptions, [:])
        XCTAssertEqual(send("GET", "/files/prepareme-maps-roads.zim", token: first).status, 404)
        XCTAssertEqual(send("GET", "/files/prepareme-daily.zim", token: first).status, 404, "not in the folder")

        let theirs = try served(second)
        XCTAssertEqual(theirs.files.map(\.name), ["prepareme-daily.zim", "prepareme-maps-roads.zim", "made-up-family.zim"])
        XCTAssertNil(theirs.drop)
        XCTAssertEqual(theirs.shelf, shelf)
        XCTAssertEqual(send("GET", "/files/prepareme-maps-roads.zim", token: second).status, 200)
    }

    /// A download the Mac keeps for itself and never ticked For the family is not in a phone's `drop`, so its shelf
    /// line and description must be stripped all the same: a phone is never told the name of a file it isn't sent
    func testAFamilyFalseDownloadsShelfLinesNeverReachAPhone() throws {
        var listed = try Manifest.read(Data(contentsOf: served.appendingPathComponent("manifest.json")))
        listed.files.append(Manifest.Entry(name: "made-up-macs-own_2026-10.zim", id: UUID().uuidString,
                                           kind: "download", size: 10, sha256: String(repeating: "b", count: 64),
                                           deliveredAt: "2026-10-18T12:00:00-04:00", family: false))
        try listed.encoded().write(to: served.appendingPathComponent("manifest.json"))
        var shelf = LibraryShelf.starting
        shelf.placed["made-up-macs-own"] = "skills"
        shelf.placed["prepareme-maps-roads"] = "reference"
        shelf.descriptions = ["made-up-macs-own": "Made-up Mac only.", "prepareme-maps-roads": "Made-up roads."]
        try shelf.encoded().write(to: pairing.appendingPathComponent(LibraryShelf.fileName))

        let mine = try served(first)
        XCTAssertNil(mine.drop)
        XCTAssertNil(mine.shelf?.placed["made-up-macs-own"])
        XCTAssertNil(mine.shelf?.descriptions["made-up-macs-own"])
        XCTAssertEqual(mine.shelf?.placed["prepareme-maps-roads"], "reference")
        XCTAssertEqual(mine.shelf?.descriptions["prepareme-maps-roads"], "Made-up roads.")
    }

    /// Family downloads plan, phase 3, decision 3: a family download un-ticked on the Mac is in every device's `drop`
    /// until it is ticked again or gone from the Mac; a download kept for the Mac alone and never ticked is never named
    func testAnUntickedFamilyDownloadIsInEveryDevicesDropUntilTickedAgainOrGone() throws {
        let entry = { (name: String, family: Bool) in
            Manifest.Entry(name: name, id: UUID().uuidString, kind: "download", size: 10,
                           sha256: String(repeating: "b", count: 64), deliveredAt: "2026-10-18T12:00:00-04:00",
                           family: family)
        }
        let original = try Manifest.read(Data(contentsOf: served.appendingPathComponent("manifest.json")))
        func deliver(_ extra: [Manifest.Entry]) throws {
            var listed = original
            listed.files += extra
            try listed.encoded().write(to: served.appendingPathComponent("manifest.json"))
        }
        try PhoneChoices.withdraw("made-up-kept.zim", true, in: pairing)
        try deliver([entry("made-up-kept.zim", false), entry("made-up-macs-own.zim", false)])
        XCTAssertEqual(try served(first).drop, ["made-up-kept.zim"])
        XCTAssertEqual(try served(second).drop, ["made-up-kept.zim"])
        XCTAssertFalse(try served(first).files.contains { $0.name.hasPrefix("made-up-") })

        try deliver([entry("made-up-kept.zim", true)])  // ticked again (the Mac app also clears the mark)
        XCTAssertNil(try served(first).drop)
        try deliver([])  // gone from the Mac: the devices keep their copies
        XCTAssertNil(try served(first).drop)
        try PhoneChoices.withdraw("made-up-kept.zim", false, in: pairing)
        XCTAssertEqual(try Data(contentsOf: pairing.appendingPathComponent(PhoneChoices.withdrawnName)),
                       Data("[]".utf8))
    }

    /// Audit P2h: the list served to a phone says its format; one from the packer alone never did
    func testTheServedListSaysItsFormat() throws {
        XCTAssertEqual(try served(first).format, FileFormat.current)
        XCTAssertNil(try Manifest.read(Data(contentsOf: served.appendingPathComponent("manifest.json"))).format)
    }

    /// A list from before phase 3 reads with no `drop`, and a phone from before skips the key
    func testAListFromBeforeTheDropStillReads() throws {
        XCTAssertNil(try Manifest.read(Data(#"{"written_at":"2026-10-01T00:00:00Z","files":[]}"#.utf8)).drop)
        struct Before: Decodable { let files: [Manifest.Entry] }  // an old phone's decoder knows no drop
        var listed = Manifest(writtenAt: "x", files: [])
        listed.drop = ["made-up.zim"]
        XCTAssertNoThrow(try JSONDecoder().decode(Before.self, from: listed.encoded()))
    }
}
