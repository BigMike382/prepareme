import Foundation
import PrepareMeShared
import XCTest

/// The USB drive backup's lines (2026-10-22, docs/usb-backup.md), from the job's status file: its shape is the shared
/// fixture, which usbbackup/tests checks the job writes.
final class DriveBackupTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/usb-backup-status.json")
    let zone = TimeZone(identifier: "America/New_York")!
    let installed = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00-04:00")!
    let now = ISO8601DateFormatter().date(from: "2026-10-22T15:58:00-04:00")!

    func status(_ changes: [String: Any?] = [:]) throws -> DriveBackup {
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as! [String: Any]
        for (key, value) in changes { object[key] = value }
        return try JSONDecoder().decode(DriveBackup.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testTheSharedFixtureReads() throws {
        let found = try XCTUnwrap(DriveBackup.read(in: Self.fixture.deletingLastPathComponent()
            .appendingPathComponent("missing")) ?? status())
        XCTAssertEqual(found.good?.files, 117_688)
        XCTAssertEqual(found.last?.exit, 2)
        XCTAssertEqual(found.taken, 1_792_696_200_000_000_000)
        XCTAssertNil(found.running)
    }

    func testAGoodBackupThenALaterTryThatDidnt() throws {
        XCTAssertEqual(DriveBackup.lines(try status(), installed: installed, pressed: 1_792_696_200_000_000_000,
                                         now: now, timeZone: zone),
                       ["Backed up to the USB drive 12 hours ago: 117,688 files, 139.4 GB",
                        "Tried 48 minutes ago, not backed up: the USB drive isn't plugged in."])
    }

    func testATryBeforeTheLastGoodBackupIsntSaid() throws {
        let last: [String: Any] = ["exit": 1, "finished": "2026-10-22T03:00:00-04:00", "summary": "made up",
                                   "started": "2026-10-22T03:00:00-04:00"]
        XCTAssertEqual(DriveBackup.lines(try status(["last": last]), installed: installed, pressed: nil, now: now,
                                         timeZone: zone),
                       ["Backed up to the USB drive 12 hours ago: 117,688 files, 139.4 GB"])
    }

    func testAGoodBackupWhoseGoBagCopyWasntMadeSaysWhy() throws {
        func last(_ summary: String) -> [String: Any] {
            ["exit": 0, "finished": "2026-10-22T03:50:00-04:00", "started": "2026-10-22T03:45:00-04:00",
             "summary": summary]
        }
        let skipped = last("backed up to the USB drive; the go-bag copy isn't up to date: the PrepareMe Backup folder isn't "
            + "on this Mac")
        XCTAssertEqual(DriveBackup.lines(try status(["last": skipped]), installed: installed, pressed: nil, now: now,
                                         timeZone: zone).last,
                       "The go-bag copy on the drive isn't up to date: the PrepareMe Backup folder isn't on this Mac.")
        let done = last("backed up to the USB drive; the go-bag copy is current")
        XCTAssertEqual(DriveBackup.lines(try status(["last": done]), installed: installed, pressed: nil, now: now,
                                         timeZone: zone).count, 1)
    }

    func testRunningAndWaiting() throws {
        let running: [String: Any] = ["started": "2026-10-22T15:50:00-04:00", "pressed": NSNull(), "waiting": false]
        XCTAssertEqual(DriveBackup.lines(try status(["running": running]), installed: installed, pressed: nil,
                                         now: now, timeZone: zone).last,
                       "Backing up to the USB drive now (started 3:50 PM)")
        let waiting: [String: Any] = ["started": "2026-10-22T15:50:00-04:00", "waiting": true]
        XCTAssertEqual(DriveBackup.lines(try status(["running": waiting]), installed: installed, pressed: nil,
                                         now: now, timeZone: zone).last,
                       "Backing up to the USB drive: waiting for another PrepareMe job to finish")
    }

    func testAPressNotYetTaken() throws {
        let pressed = Int64(now.timeIntervalSince1970 - 10) * 1_000_000_000
        XCTAssertEqual(DriveBackup.lines(try status(), installed: installed, pressed: pressed, now: now,
                                         timeZone: zone).last,
                       "Back up to the drive now asked; the backup job is starting")
        let late = Int64(now.timeIntervalSince1970 - 120) * 1_000_000_000
        XCTAssertEqual(DriveBackup.lines(try status(), installed: installed, pressed: late, now: now,
                                         timeZone: zone).last,
                       "Back up to the drive now asked at 3:56 PM, but the backup job hasn't started (System Settings › "
                       + "General › Login Items: its switch must be on)")
    }

    func testNotInstalledAndNeverBackedUp() throws {
        XCTAssertEqual(DriveBackup.lines(nil, installed: nil, pressed: nil, now: now),
                       ["The USB drive backup isn't set up yet: its job is installed with one Terminal command "
                        + "(docs/owner-checks.md, section 8)."])
        XCTAssertEqual(DriveBackup.lines(nil, installed: installed, pressed: nil, now: now),
                       ["Not backed up to the USB drive yet."])
    }

    func testInstalledAtFromTheSchedulersFile() {
        let data = Data(#"{"usb-backup": {"at": "2026-10-22T12:00:00-04:00", "python": "/p"}, "paper": {}}"#.utf8)
        XCTAssertEqual(DriveBackup.installedAt(data), installed)
        XCTAssertNil(DriveBackup.installedAt(Data(#"{"paper": {}}"#.utf8)))
        XCTAssertNil(DriveBackup.installedAt(nil))
        XCTAssertEqual(DriveBackup.installedAt(Data(#"{"usb-backup": {}}"#.utf8)), .distantFuture)
    }

    func testTheSidebarSpeaksAfterSevenDays() throws {
        let week = now.addingTimeInterval(7 * 86400)
        XCTAssertNil(DriveBackup.attention(try status(), installed: installed, now: now))
        XCTAssertNil(DriveBackup.attention(try status(), installed: nil, now: week))
        XCTAssertNil(DriveBackup.attention(try status(), installed: installed, now: week.addingTimeInterval(-86400)))
        XCTAssertEqual(DriveBackup.attention(try status(), installed: installed, now: week),
                       "Not backed up to the USB drive for 7 days: plug in the drive, or press Back up to the drive now.")
        XCTAssertEqual(DriveBackup.attention(nil, installed: installed, now: week),
                       "Not backed up to the USB drive for 7 days: plug in the drive, or press Back up to the drive now.")
    }

    func testThePressTimeIsTheFilesInNanoseconds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = folder.appendingPathComponent(DriveBackup.requestName)
        XCTAssertNil(DriveBackup.pressed(request))
        try Data().write(to: request)
        let seconds = try XCTUnwrap(try request.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate).timeIntervalSince1970
        let pressed = try XCTUnwrap(DriveBackup.pressed(request))
        XCTAssertEqual(Double(pressed) / 1e9, seconds, accuracy: 0.001)
    }
}
