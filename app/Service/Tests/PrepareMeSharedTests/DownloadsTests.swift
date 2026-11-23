import Foundation
@testable import PrepareMeShared
import XCTest

/// Phase 8's checked downloads: the Metalink read on its real shape (made-up values), and the downloads record.
final class DownloadsTests: XCTestCase {
    static let sha = String(repeating: "ab", count: 32)

    /// The shape Kiwix's mirror serves (2026-10-14): md5, sha-1 and sha-256 for the file, per-piece sha-1s inside
    /// <pieces>, and mirrors by priority. Every value here is made up.
    static func metalink(sha256: String = sha, size: String = "333429922", name: String = "wikipedia_en_100_2026-08.zim",
                         extraFile: Bool = false) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <generator>made up</generator>
          <!-- Found 12 mirrors -->
          <file name="\(name)">
            <size>\(size)</size>
            <hash type="md5">\(String(repeating: "1", count: 32))</hash>
            <hash type="sha-1">\(String(repeating: "2", count: 40))</hash>
            <hash type="sha-256">\(sha256)</hash>
            <pieces length="4194304" type="sha-1">
              <hash>\(String(repeating: "3", count: 40))</hash>
              <hash>\(String(repeating: "4", count: 40))</hash>
            </pieces>
            <url location="us" priority="2">https://two.example.org/zim/\(name)</url>
            <url location="us" priority="1">https://one.example.org/zim/\(name)</url>
            <url location="de" priority="3">http://plain.example.org/zim/\(name)</url>
          </file>
          \(extraFile ? "<file name=\"other.zim\"><size>5</size><hash type=\"sha-256\">\(String(repeating: "cd", count: 32))</hash></file>" : "")
        </metalink>
        """.utf8)
    }

    func testTheFilesSizeHashAndMirrorsAreRead() throws {
        let found = try Metalink.parse(Self.metalink(extraFile: true))
        XCTAssertEqual(found.name, "wikipedia_en_100_2026-08.zim")
        XCTAssertEqual(found.size, 333_429_922)
        XCTAssertEqual(found.sha256, Self.sha)  // never a piece's hash, never the second file's
        XCTAssertEqual(found.urls.map(\.host), ["one.example.org", "two.example.org"])  // by priority, https only
    }

    func testAMetalinkMissingWhatTheCheckNeedsIsRefused() {
        XCTAssertThrowsError(try Metalink.parse(Self.metalink(sha256: "nothex"))) {
            XCTAssertEqual($0 as? Metalink.Problem, .noHash)
        }
        XCTAssertThrowsError(try Metalink.parse(Self.metalink(size: "0"))) {
            XCTAssertEqual($0 as? Metalink.Problem, .noSize)
        }
        XCTAssertThrowsError(try Metalink.parse(Self.metalink(name: "../evil.zim"))) {
            XCTAssertEqual($0 as? Metalink.Problem, .badName)
        }
        XCTAssertThrowsError(try Metalink.parse(Data("<html>an error page</html>".utf8)))
        XCTAssertThrowsError(try Metalink.parse(Data("not xml".utf8)))
    }

    func testTheRecordIsWrittenWholeAndReadBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-downloads-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(DownloadsRecord.read(folder), DownloadsRecord())
        let record = DownloadsRecord(files: [.init(name: "a.zim", title: "A", size: 5, sha256: Self.sha,
                                                   source: "https://one.example.org/a.zim.meta4", family: true,
                                                   keptAt: "2026-10-14T12:00:00Z")])
        try record.write(folder)
        XCTAssertEqual(DownloadsRecord.read(folder), record)
        let text = try String(contentsOf: folder.appendingPathComponent(DownloadsRecord.fileName), encoding: .utf8)
        XCTAssertTrue(text.contains("\"kept_at\""))  // the packer reads these keys (packer/downloads.py)
    }
}
