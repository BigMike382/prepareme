import Foundation
@testable import PrepareMeServer
import PrepareMeShared
import XCTest

/// The token store, the counts store and the probe file, each in a fresh temporary folder.
final class StoreAndProbeTests: XCTestCase {
    var folder: URL!
    let now = Date(timeIntervalSince1970: 1_791_800_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-stores-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testPhonesAreLabeledInOrderAndARemovedLabelIsReused() throws {
        let store = TokenStore(url: folder.appendingPathComponent("tokens.json"))
        XCTAssertEqual(try store.add(now: now).label, "phone 1")
        XCTAssertEqual(try store.add(now: now).label, "phone 2")
        XCTAssertTrue(try store.remove(label: "phone 1"))
        XCTAssertEqual(try store.add(now: now).label, "phone 1")
    }

    func testTheTokenFileNeverHoldsATokenAndEachTokenFindsItsPhone() throws {
        let url = folder.appendingPathComponent("tokens.json")
        let store = TokenStore(url: url)
        let first = try store.add(now: now), second = try store.add(now: now)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(first.token))
        XCTAssertFalse(text.contains(second.token))
        XCTAssertEqual(store.label(for: first.token), "phone 1")
        XCTAssertEqual(store.label(for: second.token), "phone 2")
        XCTAssertNil(store.label(for: "short"))
        XCTAssertNil(store.label(for: Token.make()))
    }

    func testRemovingAnUnknownLabelChangesNothing() throws {
        let store = TokenStore(url: folder.appendingPathComponent("tokens.json"))
        _ = try store.add(now: now)
        XCTAssertFalse(try store.remove(label: "phone 9"))
        XCTAssertEqual(try store.phones().count, 1)
    }

    func report(_ at: String, alerts: Int = 0) -> CountsReport {
        CountsReport(at: at, counts: AlertCounts(alerts: alerts, events: 0, noVTEC: 0))
    }

    func testASecondReportForTheSameMinuteReplacesTheFirst() throws {
        let store = CountsStore(url: folder.appendingPathComponent("c.json"))
        try store.add(report("2026-10-12T21:07Z", alerts: 1), from: "phone 1", now: now)
        try store.add(report("2026-10-12T21:07Z", alerts: 5), from: "phone 1", now: now)
        let kept = try XCTUnwrap(store.readings()["phone 1"])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].alerts, 5)
    }

    func testReadingsComeBackSortedByTimeAndPhonesStayApart() throws {
        let store = CountsStore(url: folder.appendingPathComponent("c.json"))
        try store.add(report("2026-10-12T21:09Z"), from: "phone 1", now: now)
        try store.add(report("2026-10-12T21:07Z"), from: "phone 1", now: now)
        try store.add(report("2026-10-12T21:08Z"), from: "phone 2", now: now)
        let all = store.readings()
        XCTAssertEqual(all["phone 1"]?.map(\.at), ["2026-10-12T21:07Z", "2026-10-12T21:09Z"])
        XCTAssertEqual(all["phone 2"]?.map(\.at), ["2026-10-12T21:08Z"])
    }

    func testAReadingOlderThanThirtyDaysIsDroppedAtTheNextAdd() throws {
        let store = CountsStore(url: folder.appendingPathComponent("c.json"))
        try store.add(report(CountsReport.minute(now)), from: "phone 1", now: now)
        let later = now.addingTimeInterval(31 * 86400)
        try store.add(report(CountsReport.minute(later)), from: "phone 1", now: later)
        XCTAssertEqual(store.readings()["phone 1"]?.map(\.at), [CountsReport.minute(later)])
    }

    func testASwappedProbeFileMatchesItsManifestEntry() throws {
        let made = try ProbeFile.swap(folder: folder, id: "probe-x", bytes: 1000, now: now)
        let manifest = try Manifest.read(Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        let entry = try XCTUnwrap(manifest.files.first)
        XCTAssertEqual(entry.name, ProbeFile.name)
        XCTAssertEqual(entry.sha256, made.sha256)
        XCTAssertEqual(entry.size, 1000)
        XCTAssertEqual(try FileCheck.verify(folder.appendingPathComponent(ProbeFile.name), size: entry.size,
                                            sha256: entry.sha256), .ok)
    }

    func testASwapWhileAnotherHoldsTheLockChangesNothing() throws {
        try ProbeFile.swap(folder: folder, id: "probe-x", bytes: 100, now: now)
        let before = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        let held = open(folder.appendingPathComponent(".swap.lock").path, O_RDWR)
        defer { close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try ProbeFile.swap(folder: folder, id: "probe-x", bytes: 100, now: now))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("manifest.json")), before)
    }

    func testADamagedProbeFileHasTheRightSizeButTheWrongHash() throws {
        let made = try ProbeFile.swap(folder: folder, id: "probe-x", bytes: 1000, damaged: true, now: now)
        XCTAssertTrue(made.damaged)
        XCTAssertEqual(try FileCheck.verify(folder.appendingPathComponent(ProbeFile.name), size: 1000,
                                            sha256: made.sha256), .wrongHash)
    }

    func testTheProbeIDIsStableAndAnotherSwapMakesANewFile() throws {
        let first = try ProbeFile.id(in: folder)
        XCTAssertTrue(first.hasPrefix("probe-"))
        XCTAssertEqual(try ProbeFile.id(in: folder), first)
        let one = try ProbeFile.swap(folder: folder, id: first, bytes: 1000, now: now)
        let two = try ProbeFile.swap(folder: folder, id: first, bytes: 1000, now: now)
        XCTAssertNotEqual(one.sha256, two.sha256)
    }

    func testTheManifestWriteTimeReadsBack() throws {
        XCTAssertNil(ProbeFile.writtenAt(folder: folder))
        try ProbeFile.swap(folder: folder, id: "probe-x", bytes: 10, now: now)
        XCTAssertEqual(ProbeFile.writtenAt(folder: folder), now)
    }
}
