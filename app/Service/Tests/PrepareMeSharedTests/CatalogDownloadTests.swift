import CryptoKit
import Foundation
@testable import PrepareMeShared
import XCTest

/// A stand-in for Kiwix's mirrors: each URL's answer set by the test, Range requests honoured, and a download cut off
/// part-way once when asked.
final class MirrorStub: URLProtocol, @unchecked Sendable {
    struct Answer {
        var status = 200
        var body = Data()
        var cutAfter: Int?  // send this many bytes, then fail (once)
        var announced: Int?  // a Content-Length that isn't the body's
        var headers: [String: String] = [:]  // more of the answer's headers (Content-Type, Content-Encoding)
        var ignoresRange = false  // answers 200 with the body whatever was asked (a portal page)
    }

    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var ranges: [String] = []
    nonisolated(unsafe) static var encodings: [String?] = []  // each request's Accept-Encoding

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url!.absoluteString
        Self.encodings.append(request.value(forHTTPHeaderField: "Accept-Encoding"))
        guard var answer = Self.answers[key] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var status = answer.status
        var body = answer.body
        if let range = request.value(forHTTPHeaderField: "Range"), status == 200, !answer.ignoresRange,
           let from = Int(range.dropFirst("bytes=".count).dropLast()) {
            Self.ranges.append(range)
            status = from >= body.count ? 416 : 206
            body = from >= body.count ? Data() : body.subdata(in: from..<body.count)
        }
        let length = answer.announced ?? body.count
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: (length < 0 ? [:] : ["Content-Length": "\(length)"])
                                           .merging(answer.headers) { _, more in more })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let cut = answer.cutAfter {
            client?.urlProtocol(self, didLoad: body.prefix(cut))
            answer.cutAfter = nil
            Self.answers[key] = answer
            // the connection drops a moment later, as a real one does, not in the same instant as the bytes
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [client] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CatalogDownloadTests: XCTestCase {
    var folder: URL!
    var session: URLSession!
    let body = Data((0..<3_000_000).map { UInt8($0 % 251) })  // made up, over a 1 MB write
    let meta = URL(string: "https://catalog.example.org/sample.zim.meta4")!
    let one = "https://one.example.org/zim/sample.zim"
    let two = "https://two.example.org/zim/sample.zim"

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-catalog-\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MirrorStub.self]
        session = URLSession(configuration: configuration)
        MirrorStub.ranges = []
        MirrorStub.answers = [meta.absoluteString: .init(body: metalink())]
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func metalink(sha: String? = nil) -> Data {
        let hash = sha ?? Hex.string(SHA256.hash(data: body))
        return DownloadsTests.metalink(sha256: hash, size: "\(body.count)", name: "sample.zim")
            .replacingMirrors(with: [one, two])
    }

    func run(free: Int64? = 1 << 40) async throws -> DownloadsRecord.File {
        try await CatalogDownload.run(metalink: meta, title: "Sample", family: true, folder: folder, session: session,
                                      freeSpace: { _ in free })
    }

    func testAFileIsCheckedThenKeptAndRecorded() async throws {
        MirrorStub.answers[one] = .init(body: body)
        let kept = try await run()
        XCTAssertEqual(kept.size, Int64(body.count))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("sample.zim")), body)
        XCTAssertEqual(DownloadsRecord.read(folder).files, [kept])
        XCTAssertFalse(FileManager.default.fileExists(atPath: CatalogDownload.partURL("sample.zim", in: folder).path))
    }

    func testACutDownloadResumesWhereItStopped() async throws {
        MirrorStub.answers[one] = .init(body: body, cutAfter: 1_200_000)
        MirrorStub.answers[two] = .init(status: 500)
        do {
            _ = try await run()
            XCTFail("a cut download was kept")
        } catch {}
        XCTAssertEqual(DownloadsRecord.read(folder).files, [])
        let part = CatalogDownload.partURL("sample.zim", in: folder)
        let half = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(half, 0)
        _ = try await run()  // the second time asks only for the rest
        XCTAssertEqual(MirrorStub.ranges.last, "bytes=\(half)-")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("sample.zim")), body)
    }

    func testADamagedDownloadIsDeletedAndNothingKept() async throws {
        var damaged = body
        damaged[100] ^= 0xFF  // one byte off
        MirrorStub.answers[one] = .init(body: damaged)
        do {
            _ = try await run()
            XCTFail("kept")
        } catch let failure as CatalogDownload.Failure {
            XCTAssertEqual(failure, .damaged)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testTheNextMirrorIsTriedAndAnErrorPageIsNeverWritten() async throws {
        MirrorStub.answers[one] = .init(body: Data("<html>busy</html>".utf8))  // 200, but not the file
        MirrorStub.answers[two] = .init(body: body)
        _ = try await run()
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("sample.zim")), body)
    }

    func testNoRoomIsSaidBeforeAnythingIsFetched() async throws {
        MirrorStub.answers[one] = .init(body: body)
        do {
            _ = try await run(free: 1000)
            XCTFail("fetched")
        } catch let failure as CatalogDownload.Failure {
            guard case .noRoom = failure else { return XCTFail("\(failure)") }
        }
        // the plan's sizes (phase L, finding 8), the needed one rounded up so the two never read the same
        XCTAssertEqual(CatalogDownload.Failure.noRoom(needed: 2_400_000_001, free: 2_400_000_000).description,
                       "There isn't room: it needs 2.5 GB and this Mac has 2.4 GB free.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sample.zim").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CatalogDownload.partURL("sample.zim", in: folder).path))
    }

    func testARemovedDownloadLeavesTheRecordFirst() async throws {
        MirrorStub.answers[one] = .init(body: body)
        _ = try await run()
        let here: URL = folder
        try await MainActor.run { try CatalogDownload.remove("sample.zim", from: here) }
        XCTAssertEqual(DownloadsRecord.read(folder).files, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sample.zim").path))
    }

    /// Phase 8 review, 4: longer than the file is refused at once, part deleted, no other mirror tried.
    func testAFileLongerThanItsDescriptionIsRefusedAtOnce() async throws {
        MirrorStub.answers[one] = .init(body: body + Data(repeating: 7, count: 2_000_000), announced: -1)
        MirrorStub.answers[two] = .init(body: body)
        do {
            _ = try await run()
            XCTFail("kept")
        } catch let failure as CatalogDownload.Failure {
            XCTAssertEqual(failure, .damaged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: CatalogDownload.partURL("sample.zim", in: folder).path))
    }

    /// Phase 8 review, 5: a record that can't be read is never written over with an empty one.
    func testAnUnreadableRecordIsNeverWrittenOver() async throws {
        MirrorStub.answers[one] = .init(body: body)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = folder.appendingPathComponent(DownloadsRecord.fileName)
        try Data("{not json".utf8).write(to: record)
        do {
            _ = try await run()
            XCTFail("kept")
        } catch let failure as CatalogDownload.Failure {
            XCTAssertEqual(failure, .recordUnreadable)
        }
        XCTAssertEqual(try Data(contentsOf: record), Data("{not json".utf8))
        do {
            let here: URL = folder
            try await MainActor.run { try CatalogDownload.remove("x.zim", from: here) }
            XCTFail("written")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: record), Data("{not json".utf8))
    }

    func testRoomThatCantBeReadStopsTheDownload() async throws {
        MirrorStub.answers[one] = .init(body: body)
        do {
            _ = try await run(free: nil)
            XCTFail("fetched")
        } catch let failure as CatalogDownload.Failure {
            XCTAssertEqual(failure, .roomUnknown)
        }
    }

    func testOnlyWiFiOrWired() {
        let configuration = CatalogDownload.session().configuration
        XCTAssertFalse(configuration.allowsCellularAccess)
        XCTAssertFalse(configuration.allowsExpensiveNetworkAccess)  // an iPhone hotspot
        XCTAssertFalse(configuration.allowsConstrainedNetworkAccess)  // Low Data Mode
    }

    // MARK: Other Sites (library redesign, Task 5.2): a vetted list entry's PDF, checked against its size and SHA-256

    let pdfURL = "https://www.fema.gov/sample/handbook.pdf"

    func outsideEntry(sha: String? = nil, size: Int? = nil) -> OutsideList.Entry {
        OutsideList.Entry(key: "sample-handbook", title: "SAMPLE Handbook", description: "A made-up handbook.",
                          page: "https://www.fema.gov/sample", url: pdfURL, host: "www.fema.gov",
                          license: "Public domain", size: Int64(size ?? body.count),
                          sha256: sha ?? Hex.string(SHA256.hash(data: body)), kind: "pdf", category: "",
                          vetted: "2026-11-13")
    }

    func runOutside(_ entry: OutsideList.Entry) async throws -> OutsideRecord.File {
        try await CatalogDownload.runOutside(entry, family: false, folder: folder, session: session,
                                             freeSpace: { _ in 1 << 40 })
    }

    var keptPDF: URL { folder.appendingPathComponent("outside/sample-handbook.pdf") }

    func testOutsideKeptWhenMatching() async throws {
        MirrorStub.answers[pdfURL] = .init(body: body)
        let kept = try await runOutside(outsideEntry())
        XCTAssertEqual(try Data(contentsOf: keptPDF), body)
        XCTAssertEqual(OutsideRecord.read(folder).files, [kept])
        XCTAssertEqual([kept.key, kept.title, "\(kept.size)", "\(kept.family)"],
                       ["sample-handbook", "SAMPLE Handbook", "\(body.count)", "false"])
        XCTAssertEqual(DownloadsRecord.read(folder).files, [], "the Kiwix record is untouched")
        do {
            _ = try await runOutside(outsideEntry())
            XCTFail("kept twice")
        } catch let failure as CatalogDownload.Failure {
            XCTAssertEqual(failure, .alreadyKept)
        }
    }

    func testOutsideChangedAtSourceRefusedAndDeleted() async throws {
        var changed = body
        changed[100] ^= 0xFF  // same size, one byte off
        for answer in [MirrorStub.Answer(body: changed), MirrorStub.Answer(body: body + Data([1, 2, 3]))] {
            MirrorStub.answers[pdfURL] = answer
            do {
                _ = try await runOutside(outsideEntry())
                XCTFail("a changed file was kept")
            } catch let failure as CatalogDownload.Failure {
                XCTAssertEqual(failure, .changedAtSource(host: "www.fema.gov"))
                XCTAssertEqual(failure.description, "The file at www.fema.gov has changed since it was checked; it "
                               + "waits for a session to check it again.")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: keptPDF.path))
            let part = CatalogDownload.partURL("sample-handbook.pdf", in: folder.appendingPathComponent("outside"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "nothing unvetted stays on disk")
            XCTAssertEqual(OutsideRecord.read(folder).files, [])
        }
    }

    func testOutsideRevettedReplacesTheOldLine() async throws {
        MirrorStub.answers[pdfURL] = .init(body: body)
        _ = try await runOutside(outsideEntry())
        let newer = body + Data([9, 9, 9])  // the site changed its file and a session checked it again, same key
        MirrorStub.answers[pdfURL] = .init(body: newer)
        let kept = try await runOutside(outsideEntry(sha: Hex.string(SHA256.hash(data: newer)), size: newer.count))
        XCTAssertEqual(OutsideRecord.read(folder).files, [kept], "one line, the re-checked file's")
        XCTAssertEqual(kept.sha256, Hex.string(SHA256.hash(data: newer)))
        XCTAssertEqual(try Data(contentsOf: keptPDF), newer)
    }

    func testOutsideAsksForTheFileUncompressed() async throws {
        MirrorStub.answers[pdfURL] = .init(body: body)
        MirrorStub.encodings = []
        _ = try await runOutside(outsideEntry())
        XCTAssertEqual(MirrorStub.encodings.last, "identity", "a compressed answer's length is never the vetted size")
    }

    func testOutsideAnswerThatIsntThePDFKeepsThePart() async throws {
        MirrorStub.answers[pdfURL] = .init(body: body, cutAfter: 1_200_000)
        _ = try? await runOutside(outsideEntry())
        let part = CatalogDownload.partURL("sample-handbook.pdf", in: folder.appendingPathComponent("outside"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path), "a cut keeps what came")
        let portal = MirrorStub.Answer(body: Data("<html>Sign in to the guest Wi-Fi</html>".utf8),
                                       headers: ["Content-Type": "text/html"], ignoresRange: true)
        let compressed = MirrorStub.Answer(body: Data(repeating: 1, count: 500),
                                           headers: ["Content-Type": "application/pdf", "Content-Encoding": "gzip"],
                                           ignoresRange: true)
        for answer in [portal, compressed] {
            MirrorStub.answers[pdfURL] = answer
            do {
                _ = try await runOutside(outsideEntry())
                XCTFail("kept something that isn't the PDF")
            } catch let failure as CatalogDownload.Failure {
                XCTAssertNotEqual(failure, .changedAtSource(host: "www.fema.gov"), "not the site's doing")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: part.path), "the partial download stays")
        }
    }

    func testOutsideRemoveDropsRecordAndFile() async throws {
        MirrorStub.answers[pdfURL] = .init(body: body)
        _ = try await runOutside(outsideEntry())
        let folder = self.folder!
        try await MainActor.run { try CatalogDownload.removeOutside("sample-handbook", from: folder) }
        XCTAssertEqual(OutsideRecord.read(folder).files, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: keptPDF.path))
    }

    /// Phase 5 review, minors: a resumed outside download asks for the rest; a body with no length that runs past the
    /// vetted size is the site's changed file; an http address is refused before anything is asked.
    func testOutsideCutDownloadResumesWithARange() async throws {
        MirrorStub.answers[pdfURL] = .init(body: body, cutAfter: 1_200_000)
        _ = try? await runOutside(outsideEntry())
        let part = CatalogDownload.partURL("sample-handbook.pdf", in: folder.appendingPathComponent("outside"))
        let half = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(half, 0)
        _ = try await runOutside(outsideEntry())
        XCTAssertEqual(MirrorStub.ranges.last, "bytes=\(half)-", "answered 206 with the rest")
        XCTAssertEqual(try Data(contentsOf: keptPDF), body)
    }

    func testOutsideBodyWithNoLengthPastTheSizeIsChanged() async throws {
        MirrorStub.answers[pdfURL] = .init(body: body + Data(repeating: 7, count: 500_000), announced: -1)
        do {
            _ = try await runOutside(outsideEntry())
            XCTFail("kept")
        } catch let failure as CatalogDownload.Failure {
            XCTAssertEqual(failure, .changedAtSource(host: "www.fema.gov"))
        }
        let part = CatalogDownload.partURL("sample-handbook.pdf", in: folder.appendingPathComponent("outside"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    func testOutsideHttpEntryRefusedBeforeAsking() async throws {
        var entry = outsideEntry()
        entry.url = entry.url.replacingOccurrences(of: "https://", with: "http://")
        MirrorStub.answers[entry.url] = .init(body: body)
        MirrorStub.encodings = []
        do {
            _ = try await runOutside(entry)
            XCTFail("kept")
        } catch let failure as CatalogDownload.Failure {
            XCTAssertEqual(failure, .changedAtSource(host: "www.fema.gov"))
        }
        XCTAssertEqual(MirrorStub.encodings, [], "nothing was asked")
    }

    /// Phase 5 review, minor: Remove of an Other Sites item whose record can't be read says so, and never falls to the
    /// Kiwix record's remove.
    func testRemoveKeptRoutesOutsideAndRefusesAnUnreadableRecord() async throws {
        MirrorStub.answers[pdfURL] = .init(body: body)
        _ = try await runOutside(outsideEntry())
        let folder = self.folder!
        let saved = try Data(contentsOf: folder.appendingPathComponent(OutsideRecord.fileName))
        try Data("not json".utf8).write(to: folder.appendingPathComponent(OutsideRecord.fileName))
        do {
            try await MainActor.run { try CatalogDownload.removeKept("outside-sample-handbook.zim", from: folder) }
            XCTFail("removed with an unreadable record")
        } catch let failure as CatalogDownload.Failure {
            XCTAssertEqual(failure, .recordUnreadable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptPDF.path), "nothing changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(DownloadsRecord.fileName).path),
                       "the Kiwix record wasn't written")
        try saved.write(to: folder.appendingPathComponent(OutsideRecord.fileName))
        try await MainActor.run { try CatalogDownload.removeKept("outside-sample-handbook.zim", from: folder) }
        XCTAssertEqual(OutsideRecord.read(folder).files, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: keptPDF.path))
    }

    func testOutsideRecordFieldNames() throws {
        let record = OutsideRecord(files: [.init(key: "k", title: "T", size: 1, sha256: String(repeating: "a", count: 64),
                                                 family: true, keptAt: "2026-11-13T00:00:00Z")])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try record.write(folder)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("outside.json")))
        let line = ((raw as? [String: Any])?["files"] as? [[String: Any]])?.first
        XCTAssertEqual(Set(line?.keys.map { $0 } ?? []), ["key", "title", "size", "sha256", "family", "kept_at"])
        XCTAssertEqual(OutsideRecord.packedName("sample-handbook"), "outside-sample-handbook.zim")
        XCTAssertEqual(OutsideRecord.key(packedName: "outside-sample-handbook.zim"), "sample-handbook")
        XCTAssertNil(OutsideRecord.key(packedName: "wikipedia_en_all.zim"))
    }
}

extension Data {
    /// The made-up Metalink with its mirrors replaced by `urls` (priority by order).
    func replacingMirrors(with urls: [String]) -> Data {
        var text = String(decoding: self, as: UTF8.self)
        let lines = text.components(separatedBy: "\n").filter { !$0.contains("<url ") }
        text = lines.joined(separator: "\n")
        let mirrors = urls.enumerated().map { "<url priority=\"\($0.offset + 1)\">\($0.element)</url>" }
            .joined(separator: "\n")
        return Data(text.replacingOccurrences(of: "</pieces>", with: "</pieces>\n" + mirrors).utf8)
    }
}
