import Foundation
import PrepareMeShared
import XCTest

/// The copy Add from Files and Add a travel map make (phase K, finding 12): which step failed, and the words the screen
/// gives each. Made-up files in a fresh temporary folder.
final class FileCopyTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-copy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func source(_ text: String) throws -> URL {
        let url = root.appendingPathComponent("source.zim")
        try Data(text.utf8).write(to: url)
        return url
    }

    func copy(_ source: URL, to target: URL, size: Int64, partial: URL? = nil, stopped: Bool = false,
              shares: inout [Double]) -> FileCopy.Failure? {
        var seen: [Double] = []
        let failure = FileCopy.copy(source, to: target, size: size,
                                    partial: partial ?? root.appendingPathComponent("copy.part"), pieceSize: 4,
                                    isStopped: { stopped }, progress: { seen.append($0) })
        shares = seen
        return failure
    }

    func testAWholeCopyIsRenamedIn() throws {
        let from = try source("twelve bytes")
        let target = root.appendingPathComponent("target.zim")
        var shares: [Double] = []
        XCTAssertNil(copy(from, to: target, size: 12, shares: &shares))
        XCTAssertEqual(try Data(contentsOf: target), Data("twelve bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy.part").path))
        XCTAssertEqual(shares.last, 1)
    }

    func testEachStepThatFailsIsNamed() throws {
        let target = root.appendingPathComponent("target.zim")
        var shares: [Double] = []
        // the folder's file can't be read
        XCTAssertEqual(copy(root.appendingPathComponent("missing.zim"), to: target, size: 12, shares: &shares),
                       .readFailed)
        // not the size it was listed at: it changed while it was copied
        let from = try source("twelve bytes")
        XCTAssertEqual(copy(from, to: target, size: 20, shares: &shares), .changed)
        XCTAssertEqual(copy(from, to: target, size: 5, shares: &shares), .changed)
        // the phone's side: no folder to save it in
        let nowhere = root.appendingPathComponent("gone/target.zim")
        XCTAssertEqual(copy(from, to: nowhere, size: 12, shares: &shares), .notSaved("No such file or directory"))
        XCTAssertEqual(copy(from, to: target, size: 12, partial: root.appendingPathComponent("gone/copy.part"),
                            shares: &shares), .notSaved("No such file or directory"))
        XCTAssertEqual(copy(from, to: target, size: 12, stopped: true, shares: &shares), .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing is left where the copy goes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy.part").path),
                       "nor a partial copy")
    }

    func testAFullDiskIsToldFromOtherWriteFailures() {
        XCTAssertEqual(FileCopy.failure(writing: POSIXError(.ENOSPC)), .full)
        XCTAssertEqual(FileCopy.failure(writing: POSIXError(.EDQUOT)), .full)
        XCTAssertEqual(FileCopy.failure(writing: CocoaError(.fileWriteOutOfSpace)), .full)
        XCTAssertEqual(FileCopy.failure(writing: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                         userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])),
                       .full)
        XCTAssertEqual(FileCopy.failure(writing: POSIXError(.EACCES)), .notSaved("Permission denied"))
        XCTAssertEqual(FileCopy.reason(POSIXError(.EIO)), "Input/output error")
    }

    func testTheWords() {
        XCTAssertEqual(FileCopy.words(.readFailed),
                       "Couldn't be read from the folder. If it is in iCloud Drive, the phone needs internet.")
        XCTAssertEqual(FileCopy.words(.readFailed, device: "iPad"),
                       "Couldn't be read from the folder. If it is in iCloud Drive, the iPad needs internet.")
        XCTAssertEqual(FileCopy.words(.changed), "The file changed while it was being copied. Try again.")
        XCTAssertEqual(FileCopy.words(.full), "Not enough room on this phone to finish the copy.")
        XCTAssertEqual(FileCopy.words(.full, device: "iPad"), "Not enough room on this iPad to finish the copy.")
        XCTAssertEqual(FileCopy.words(.notSaved("Permission denied")),
                       "Couldn't be saved on this phone: Permission denied.")
        XCTAssertEqual(FileCopy.words(.notSaved("Permission denied"), device: "iPad"),
                       "Couldn't be saved on this iPad: Permission denied.")
        XCTAssertEqual(FileCopy.words(.stopped), "Stopped; nothing changed.")
    }
}
