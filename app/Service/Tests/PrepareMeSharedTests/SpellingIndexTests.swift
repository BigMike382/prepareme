import Foundation
import PrepareMeShared
import XCTest

/// Kiwix keeps its spelling index for a library under the library's ID alone (libkiwix 14.2.1's SpellingsDB:
/// "<id>.spellingsdb.v0.1" in the app's caches), and PrepareMe's libraries keep their ID from copy to copy, so a new
/// copy's words would never reach it: the index is dropped when a copy is swapped in or removed (phase 3, Task 3.2).
final class SpellingIndexTests: XCTestCase {
    var caches: URL!

    override func setUpWithError() throws {
        caches = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: caches)
    }

    func make(_ name: String) throws {
        let folder = caches.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("postlist.glass"))
    }

    func testForgetDropsThatLibrarysIndexItsHalfBuiltOneAndItsFailedMark() throws {
        try make("0f1e2d3c-4b5a-4968-8776-6554433221b1.spellingsdb.v0.1")
        try make("0f1e2d3c-4b5a-4968-8776-6554433221b1.spellingsdb.v0.1.tmp")
        try make("0f1e2d3c-4b5a-4968-8776-6554433221c1.spellingsdb.v0.1")
        try Data().write(to: caches.appendingPathComponent("0f1e2d3c-4b5a-4968-8776-6554433221b1.spellingsdb.v0.1.failed"))
        SpellingIndex.forget("0F1E2D3C-4B5A-4968-8776-6554433221B1", in: caches)  // Kiwix names it in lower case
        let left = try FileManager.default.contentsOfDirectory(atPath: caches.path)
        XCTAssertEqual(left, ["0f1e2d3c-4b5a-4968-8776-6554433221c1.spellingsdb.v0.1"], "another library's stays")
    }

    func testForgetWithNothingThereIsFine() {
        SpellingIndex.forget("0f1e2d3c-4b5a-4968-8776-6554433221b1", in: caches)
        SpellingIndex.forget("0f1e2d3c-4b5a-4968-8776-6554433221b1", in: caches.appendingPathComponent("gone"))
    }
}
