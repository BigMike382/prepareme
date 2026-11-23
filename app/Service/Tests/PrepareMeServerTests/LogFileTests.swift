import Foundation
@testable import PrepareMeServer
import PrepareMeShared
import XCTest

/// The service's own log when PrepareMe runs it (plan phase 6): macOS lets a sandboxed app's background part name no
/// output file, so it writes its lines itself. Made-up folders only.
final class LogFileTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-log-\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testLinesAreAddedInOrderAndTheFolderIsMade() throws {
        let log = LogFile(url: folder.appendingPathComponent("logs/service.log"))
        log.add("one")
        log.add("two")
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertEqual(text, "one\ntwo\n")
    }

    func testAFullLogBecomesTheOldOneAndANewOneStarts() throws {
        let log = LogFile(url: folder.appendingPathComponent("service.log"), limit: 10)
        log.add("0123456789")
        log.add("next")
        XCTAssertEqual(try String(contentsOf: log.url, encoding: .utf8), "next\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("service.old.log"), encoding: .utf8),
                       "0123456789\n")
    }

    func testTheRealHomeIsTheAccountsNotTheEnvironments() {
        XCTAssertEqual(RealHome.url?.standardizedFileURL, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
        XCTAssertTrue(RealHome.url?.path.hasPrefix("/Users/") ?? false)
    }
}
