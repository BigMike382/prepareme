import Foundation
import PrepareMeShared
import XCTest

/// Beta run 2, B2-19 (choice a): the pairing lives in the Keychain, which iOS keeps when PrepareMe is deleted, so a
/// marker kept with the app's own data says whether this install has run before. A first launch with no app data
/// forgets the pairing; a phone that ran an earlier build (its data there, no marker yet) keeps it.
final class InstallMarkerTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var folder: URL!

    override func setUp() {
        suite = "InstallMarkerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    /// A stand-in Keychain: the pairing held until `forget` runs.
    final class Keychain {
        var held = true
        var state: InstallMarker.Pairing { held ? .held : .none }
    }

    func settle(_ keychain: Keychain, pairing: InstallMarker.Pairing? = nil) -> InstallMarker.Step {
        InstallMarker.settle(defaults: defaults, domain: suite, earlierFolders: [folder],
                             pairing: pairing ?? keychain.state) {
            keychain.held = false
        }
    }

    func testAFirstLaunchWithNoAppDataFindsNoPairing() {
        let keychain = Keychain()  // left by an install that was deleted
        XCTAssertEqual(settle(keychain), .forgetAndMark)
        XCTAssertFalse(keychain.held)
        XCTAssertTrue(InstallMarker.isMarked(defaults))
    }

    /// Kiwix's Defaults library registers a key's default when it is first touched: a registered (not saved) value is
    /// no sign of an earlier build, so a fresh install still forgets.
    func testARegisteredDefaultIsNoSignOfAnEarlierBuild() {
        defaults.register(defaults: ["hasSeenCategories": false])
        let keychain = Keychain()
        XCTAssertEqual(settle(keychain), .forgetAndMark)
        XCTAssertFalse(keychain.held)
    }

    func testAnUpgradeFromAnEarlierBuildKeepsItsPairing() {
        defaults.set(true, forKey: "hasSeenCategories")  // every earlier build sets it at each launch (phase 4 on)
        let keychain = Keychain()
        XCTAssertEqual(settle(keychain), .keepAndMark)
        XCTAssertTrue(keychain.held)
        XCTAssertTrue(InstallMarker.isMarked(defaults))
        XCTAssertEqual(settle(keychain), .keep)  // and from then on, the marker says so
        XCTAssertTrue(keychain.held)
    }

    func testAnUpgradeWithTheLibraryFolderKeepsItsPairing() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keychain = Keychain()
        XCTAssertEqual(settle(keychain), .keepAndMark)
        XCTAssertTrue(keychain.held)
    }

    func testAMarkedInstallKeepsItsPairing() {
        InstallMarker.mark(defaults)
        let keychain = Keychain()
        XCTAssertEqual(settle(keychain), .keep)
        XCTAssertTrue(keychain.held)
    }

    /// Launched before the first unlock (the Keychain can't be read, nor the app's settings): decide nothing, so a
    /// paired phone is never unpaired for a settings file it couldn't read yet.
    func testBeforeTheFirstUnlockNothingIsDecided() {
        let keychain = Keychain()
        XCTAssertEqual(settle(keychain, pairing: .locked), .wait)
        XCTAssertTrue(keychain.held)
        XCTAssertFalse(InstallMarker.isMarked(defaults))
    }

    func testTheRule() {
        XCTAssertEqual(InstallMarker.step(marked: true, earlierData: false, pairing: .locked), .keep)
        XCTAssertEqual(InstallMarker.step(marked: false, earlierData: true, pairing: .locked), .wait)
        XCTAssertEqual(InstallMarker.step(marked: false, earlierData: true, pairing: .held), .keepAndMark)
        XCTAssertEqual(InstallMarker.step(marked: false, earlierData: false, pairing: .none), .forgetAndMark)
        XCTAssertEqual(InstallMarker.step(marked: false, earlierData: false, pairing: .held), .forgetAndMark)
    }
}
