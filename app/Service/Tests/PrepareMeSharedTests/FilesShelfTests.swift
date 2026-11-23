import Foundation
@testable import PrepareMeShared
import XCTest

/// The library in Files for the App Store Kiwix (plan phase 10, after D7): each held ZIM file under its manifest name,
/// a hard link to the held copy, swapped in one step on an update, removed when no longer held; only its own links are
/// ever removed, wherever they were moved in the folder (review, 2026-10-15). Made-up files only.
final class FilesShelfTests: XCTestCase {
    var base: URL!
    var library: URL { base.appendingPathComponent("library") }
    var shelf: URL { base.appendingPathComponent("Documents") }

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID())")
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    func entry(_ name: String, kind: String = "library") -> Manifest.Entry {
        Manifest.Entry(name: name, id: UUID().uuidString.lowercased(), kind: kind, size: 3, sha256: String(repeating: "a", count: 64),
                       deliveredAt: "2026-10-15T00:00:00Z")
    }

    func held(_ name: String, file: String, kind: String = "library", text: String) throws -> HeldFile {
        try Data(text.utf8).write(to: library.appendingPathComponent(file))
        return HeldFile(entry: entry(name, kind: kind), file: file)
    }

    func sync(_ files: [String: HeldFile]) -> (linked: [String], removed: [String]) {
        FilesShelf.sync(files, library: library, folder: shelf)
    }

    func shown() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: shelf.path).sorted()
    }

    func testHeldLibrariesShowUnderTheirNamesAsLinksAndUpdatesSwapInOneStep() throws {
        var files = ["prepareme-daily.zim": try held("prepareme-daily.zim", file: "daily-1.zim", text: "one"),
                     "prepareme-street-map.pmtiles": try held("prepareme-street-map.pmtiles", file: "map-1.pmtiles",
                                                             kind: "map", text: "map")]
        let first = sync(files)
        XCTAssertEqual(first.linked, ["prepareme-daily.zim"], "the street map is no reader's")
        let daily = shelf.appendingPathComponent("prepareme-daily.zim")
        XCTAssertEqual(FilesShelf.inode(daily), FilesShelf.inode(library.appendingPathComponent("daily-1.zim")),
                       "a link, not a copy")
        XCTAssertEqual(sync(files).linked, [], "nothing to do the second time")

        files["prepareme-daily.zim"] = try held("prepareme-daily.zim", file: "daily-2.zim", text: "two")
        XCTAssertEqual(sync(files).linked, ["prepareme-daily.zim"])
        XCTAssertEqual(try String(contentsOf: daily, encoding: .utf8), "two")
        XCTAssertEqual(try shown(), ["prepareme-daily.zim"], "no part-made link left over")

        files["prepareme-daily.zim"] = nil
        XCTAssertEqual(sync(files).removed, ["prepareme-daily.zim"])
        XCTAssertEqual(try shown(), [])
    }

    func testSomeonesOwnFilesAreLeftAloneZimOrNot() throws {
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: shelf.appendingPathComponent("wikipedia.zim"))
        try Data("mine".utf8).write(to: shelf.appendingPathComponent("notes.txt"))
        var files = ["prepareme-daily.zim": try held("prepareme-daily.zim", file: "daily-1.zim", text: "one")]
        sync(files)
        files["prepareme-daily.zim"] = nil
        XCTAssertEqual(sync(files).removed, ["prepareme-daily.zim"])
        XCTAssertEqual(try shown(), ["notes.txt", "wikipedia.zim"], "a file someone saved there is theirs")
    }

    func testACopyMadeInFilesIsTheirsThoughItCarriesTheTag() throws {
        let files = ["prepareme-daily.zim": try held("prepareme-daily.zim", file: "daily-1.zim", text: "one")]
        sync(files)
        let copy = shelf.appendingPathComponent("prepareme-daily copy.zim")
        try FileManager.default.copyItem(at: shelf.appendingPathComponent("prepareme-daily.zim"), to: copy)
        XCTAssertGreaterThan(getxattr(copy.path, FilesShelf.tag, nil, 0, 0, 0), 0, "a copy keeps the tag")
        XCTAssertEqual(sync(files).removed, [], "but it is another file: theirs")
        XCTAssertEqual(try shown(), ["prepareme-daily copy.zim", "prepareme-daily.zim"])
    }

    func testALinkMovedOrRenamedIsClearedSoItHoldsNoOldCopy() throws {
        var files = ["prepareme-daily.zim": try held("prepareme-daily.zim", file: "daily-1.zim", text: "one"),
                     "prepareme-reference.zim": try held("prepareme-reference.zim", file: "ref-1.zim", text: "ref")]
        sync(files)
        let fm = FileManager.default
        try fm.createDirectory(at: shelf.appendingPathComponent("Saved"), withIntermediateDirectories: true)
        try fm.moveItem(at: shelf.appendingPathComponent("prepareme-daily.zim"),
                        to: shelf.appendingPathComponent("Saved/prepareme-daily.zim"))
        try fm.moveItem(at: shelf.appendingPathComponent("prepareme-reference.zim"),
                        to: shelf.appendingPathComponent("reference copy"))
        let moved = sync(files)
        XCTAssertEqual(moved.linked, ["prepareme-daily.zim", "prepareme-reference.zim"], "shown again in place")
        XCTAssertEqual(moved.removed, ["Saved/prepareme-daily.zim", "reference copy"], "never a second copy, same ID")
        XCTAssertEqual(try shown(), ["Saved", "prepareme-daily.zim", "prepareme-reference.zim"])

        try fm.linkItem(at: shelf.appendingPathComponent("prepareme-daily.zim"),
                        to: shelf.appendingPathComponent("Saved/old daily"))  // as a move would leave it
        files["prepareme-daily.zim"] = try held("prepareme-daily.zim", file: "daily-2.zim", text: "two")
        try fm.removeItem(at: library.appendingPathComponent("daily-1.zim"))  // the store deletes the old copy
        XCTAssertEqual(sync(files).removed, ["Saved/old daily"], "the old copy's last link: its blocks go")
        XCTAssertEqual(try shown(), ["Saved", "prepareme-daily.zim", "prepareme-reference.zim"])
    }

    func testAStoppedUpdatesPartIsClearedAndABadNameIsNeverUsed() throws {
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: shelf.appendingPathComponent(".prepareme-daily.zim.link"))
        let files = ["../escape.zim": try held("../escape.zim", file: "e.zim", text: "e")]
        XCTAssertEqual(sync(files).linked, [])
        XCTAssertEqual(try shown(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("escape.zim").path))
    }
}
