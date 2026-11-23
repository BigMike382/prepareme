import Foundation
import PrepareMeShared
import XCTest

/// The folder-reading steps Add from Files and Add a travel map share (phase K, finding 23): the list read, parsed and
/// set against the folder's files, refused three ways, and the words both screens say. Made-up folders only.
final class FolderReadTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("folder-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    struct Parsed: Equatable { let text: String }
    struct Bad: Error {}

    func parse(_ data: Data) throws -> Parsed {
        guard let text = String(data: data, encoding: .utf8), text != "bad" else { throw Bad() }
        return Parsed(text: text)
    }

    func testTheWordsAreTheScreensOwn() {
        XCTAssertEqual(FolderRead.notLetIn, "PrepareMe wasn't let into that folder. Pick it again.")
        XCTAssertEqual(FolderRead.reading, "Reading the folder's list…")
        XCTAssertEqual(FolderRead.stopped, "Stopped; nothing changed.")
        XCTAssertEqual(FolderRead.stopped, FileCopy.words(.stopped))
    }

    func testAFolderWithItsListGivesTheListAndItsFiles() throws {
        try Data("good".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("12345".utf8).write(to: folder.appendingPathComponent("a.zim"))
        try Data().write(to: folder.appendingPathComponent(".b.zim.icloud"))
        let found = FolderRead.list(in: folder, named: "manifest.json", parse: parse)
        guard case let .success((list, present)) = found else { return XCTFail("\(found)") }
        XCTAssertEqual(list, Parsed(text: "good"))
        XCTAssertEqual(present["a.zim"], 5)
        XCTAssertEqual(present["b.zim"], FolderOffer.inICloud)
    }

    func testNoListIsSaidAsNoList() {
        guard case .failure(.noList) = FolderRead.list(in: folder, named: "manifest.json", parse: parse) else {
            return XCTFail("not noList")
        }
    }

    func testAListThatCantBeReadIsUnreadableNotMissing() throws {
        try Data("good".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        let found = FolderRead.list(in: folder, named: "manifest.json", read: { _ in nil }, parse: parse)
        guard case .failure(.unreadable) = found else { return XCTFail("\(found)") }
    }

    func testAListThatDoesntParseIsDamaged() throws {
        try Data("bad".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        guard case .failure(.damaged) = FolderRead.list(in: folder, named: "manifest.json", parse: parse) else {
            return XCTFail("not damaged")
        }
    }

    func testAFolderThatCantBeListedIsUnreadableNeverEmpty() {
        let gone = folder.appendingPathComponent("gone")
        let found = FolderRead.list(in: gone, named: "manifest.json", read: { _ in Data("good".utf8) }, parse: parse)
        guard case .failure(.unreadable) = found else { return XCTFail("\(found)") }
    }

    func testEachRefusalTakesItsScreensWords() {
        func said(_ refusal: FolderRead.Refusal) -> String {
            refusal.words(noList: "no list", damaged: "damaged", unreadable: "unreadable", device: "iPad")
        }
        XCTAssertEqual(said(.noList), "no list")
        XCTAssertEqual(said(.damaged), "damaged")
        XCTAssertEqual(said(.unreadable), "unreadable")
        XCTAssertEqual(said(.newer), FileFormat.newerFiles(device: "iPad"))  // audit P2h
    }
}
