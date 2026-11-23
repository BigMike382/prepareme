import Foundation
import PrepareMeShared
import XCTest

/// File checking and durable writing, in a fresh temporary folder each time.
final class FileTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-shared-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testTheSHA256OfAFileHoldingAbcIsTheKnownValue() throws {
        let url = folder.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try FileCheck.sha256(of: url), abc)
    }

    func testVerifyTellsWrongSizeFromWrongHashFromOK() throws {
        let url = folder.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try FileCheck.verify(url, size: 3, sha256: abc), .ok)
        XCTAssertEqual(try FileCheck.verify(url, size: 4, sha256: abc), .wrongSize(actual: 3))
        XCTAssertEqual(try FileCheck.verify(url, size: 3, sha256: String(repeating: "0", count: 64)), .wrongHash)
    }

    func testDurableWriteMakesAnOwnerOnlyFileAndReplacesAnExistingOne() throws {
        let url = folder.appendingPathComponent("saved.json")
        try DurableFile.write(Data("one".utf8), to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try DurableFile.write(Data("two".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("two".utf8))
    }

    /// Phase K's drills, finding 5: a save stopped by a power cut leaves its temporary copy; the next save removes its
    /// own over a minute old, never a fresh one (a save still writing) or another file's
    func testDurableWriteSweepsAStoppedSavesLeftover() throws {
        let url = folder.appendingPathComponent("record.json")
        let old = folder.appendingPathComponent(".record.json.tmp-killed1")
        let fresh = folder.appendingPathComponent(".record.json.tmp-writing")
        let other = folder.appendingPathComponent(".other.json.tmp-killed2")
        for leftover in [old, fresh, other] {
            try Data("made-up partial save".utf8).write(to: leftover)
        }
        for leftover in [old, other] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)],
                                                  ofItemAtPath: leftover.path)
        }
        try DurableFile.write(Data("one".utf8), to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(try Data(contentsOf: url), Data("one".utf8))
    }

    func testDurableWriteLeavesNoTemporaryFileBehind() throws {
        let url = folder.appendingPathComponent("saved.json")
        try DurableFile.write(Data("one".utf8), to: url)
        try DurableFile.write(Data("two".utf8), to: url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["saved.json"])
    }
}
