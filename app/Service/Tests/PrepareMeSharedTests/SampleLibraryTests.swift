import Foundation
@testable import PrepareMeShared
import XCTest

/// The sample library's rules (Unlisted plan, phase 4): offered only on a device never paired that holds no library,
/// opened again whole after an update or put away, never half; its ID the maker's; its inventory the phones' format.
final class SampleLibraryTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../..").standardizedFileURL

    func testOfferedOnlyUnpairedWithNoLibraryAndAllFiles() {
        XCTAssertTrue(SampleLibrary.offered(hasFiles: true, paired: false, held: 0))
        XCTAssertFalse(SampleLibrary.offered(hasFiles: true, paired: true, held: 0), "a paired device: the family's")
        XCTAssertFalse(SampleLibrary.offered(hasFiles: true, paired: false, held: 1), "a library arrived (Add from Files)")
        XCTAssertFalse(SampleLibrary.offered(hasFiles: false, paired: false, held: 0), "a build without the sample")
    }

    /// The lead's check (2026-11-22): tried, never paired, then updated: whole again, or put away; never half-open.
    func testAtLaunchOpensAgainOrPutsAway() {
        XCTAssertEqual(SampleLibrary.atLaunch(wasOn: true, hasFiles: true, paired: false, held: 0), .open)
        XCTAssertEqual(SampleLibrary.atLaunch(wasOn: true, hasFiles: false, paired: false, held: 0), .putAway)
        XCTAssertEqual(SampleLibrary.atLaunch(wasOn: true, hasFiles: true, paired: true, held: 0), .putAway)
        XCTAssertEqual(SampleLibrary.atLaunch(wasOn: true, hasFiles: true, paired: false, held: 2), .putAway)
        XCTAssertEqual(SampleLibrary.atLaunch(wasOn: false, hasFiles: true, paired: false, held: 0), .nothing)
    }

    /// The lead's review (2026-11-22): pairing and Add from Files put the sample away on every device, so one that never
    /// opened it loses nothing of its own (its map position, switches, Maps side, searches).
    func testPutAwayRemovesTheDevicesOwnSettingsOnlyWhenTheSampleWasOpen() {
        XCTAssertEqual(SampleLibrary.removedAtPutAway(wasOn: false), [], "never opened: nothing of the device's removed")
        let removed = SampleLibrary.removedAtPutAway(wasOn: true)
        XCTAssertEqual(Set(removed), Set(SampleLibrary.leftoverKeys + [SampleLibrary.onKey]))
        XCTAssertTrue(removed.contains("streetMapCamera"))
        XCTAssertTrue(removed.contains("recentSearchTexts"))
    }

    func testTheIDIsTheMakersAndNoVolumes() throws {
        let maker = try String(contentsOf: Self.repo.appendingPathComponent("packer/sample.py"), encoding: .utf8)
        XCTAssertTrue(maker.contains("uuid.uuid5(uuid.NAMESPACE_URL, \"PrepareMe sample\")"))
        let volumes = try String(contentsOf: Self.repo.appendingPathComponent("packer/volumes.toml"), encoding: .utf8)
        XCTAssertFalse(volumes.lowercased().contains(SampleLibrary.id))
        XCTAssertNotNil(UUID(uuidString: SampleLibrary.id))
        for name in SampleLibrary.files { XCTAssertFalse(name.hasPrefix("prepareme"), name) }
    }

    func testTheInventoryReadsAndAMissingOneIsNone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(SampleLibrary.readInventory(in: folder))
        XCTAssertFalse(SampleLibrary.hasFiles(in: folder))
        try FileManager.default.copyItem(at: Self.repo.appendingPathComponent("packer/sample/sample-inventory.json"),
                                         to: folder.appendingPathComponent(SampleLibrary.inventory))
        XCTAssertEqual(SampleLibrary.readInventory(in: folder)?.items.count, 30)
        try Data("{".utf8).write(to: folder.appendingPathComponent(SampleLibrary.inventory))
        XCTAssertNil(SampleLibrary.readInventory(in: folder), "damaged: not opened at all")
    }
}
