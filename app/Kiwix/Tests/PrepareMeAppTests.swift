// This file is part of PrepareMe, a local build of Kiwix for one household (build plan phase 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import XCTest
@testable import Kiwix

/// PrepareMe phone app (build plan phase 4): what the app's downloader relies on in the reader, on the made-up
/// libraries kiwix-mac/make_fixtures.py builds. The app keeps each copy of a library under a name of its own and points
/// the reader at the new copy's path (PrepareMeLibrary.install), so nothing ever replaces a file the reader has open
/// (FINDINGS F-064); it checks every copy first (ZimFileService.problem); and pages link between files.
/// `kiwix-mac/build.sh --tsan` runs these under Thread Sanitizer too.
final class PrepareMeAppTests: XCTestCase {
    private let reopenID = UUID(uuidString: "0f1e2d3c-4b5a-4968-8776-655443322110")!
    private let linksID = UUID(uuidString: "0f1e2d3c-4b5a-4968-8776-6554433221a1")!
    private let mapsID = UUID(uuidString: "0f1e2d3c-4b5a-4968-8776-6554433221a2")!
    private let absentID = UUID(uuidString: "0f1e2d3c-4b5a-4968-8776-6554433221a3")!
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "zim"),
                      "run kiwix-mac/build.sh --test, which builds the test libraries")
    }

    private func copy(_ name: String, as file: String) throws -> URL {
        let target = folder.appending(path: file)
        try FileManager.default.copyItem(at: fixture(name), to: target)
        return target
    }

    private func page(_ service: ZimService, _ id: UUID, _ path: String) -> String {
        guard let content = service.__getContent(id, contentPath: path, start: 0, end: 0),
              let data = content["data"] as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func frontPage(_ service: ZimService, _ id: UUID) -> String {
        service.__getMainPagePath(id).map { page(service, id, $0) } ?? ""
    }

    /// The clip as a video player reads it: by the file's path and the item's offset in it (getDirectAccess).
    private func clipByPath(_ service: ZimService, _ id: UUID) throws -> (path: String, offset: UInt64, bytes: Data) {
        let access = try XCTUnwrap(service.__getDirectAccess(id, contentPath: "media/clip.mp4"), "stored uncompressed")
        let path = try XCTUnwrap(access["path"] as? String)
        let offset = try XCTUnwrap(access["offset"] as? NSNumber).uint64Value
        return (path, offset, try read(path, offset))
    }

    private func read(_ path: String, _ offset: UInt64, _ count: Int = 300_000) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    /// The app's swap, a hundred times while searches run: each copy arrives under its own name, the reader is pointed
    /// at it (as LibraryOperations.open does through ZimService.store), and the old copy is deleted after. A video read
    /// by path and offset before the swap still reads the old copy's bytes, never the new copy's at the old offsets.
    func testEachNewCopyUnderItsOwnNameIsSwappedInWhileSearchesAndAVideoRun() throws {
        let service = ZimService.__sharedInstance()
        var current = try copy("prepareme-reopen-A", as: "library.0.zim")
        service.__store(current, with: reopenID)
        XCTAssertNotNil(service.__open(reopenID))
        defer { service.__close(reopenID) }
        _ = service.__takeReopenedIDs()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1 // one search at a time, as Kiwix runs them
        var searches: [SearchOperation] = []
        for _ in 0..<400 {
            let search = SearchOperation(searchText: "zebrafish", zimFileIDs: [reopenID], withSpellingCacheDir: nil)
            searches.append(search)
            queue.addOperation(search)
        }

        for round in 1...100 {
            let version = round.isMultiple(of: 2) ? "A" : "B"
            let old = version == "A" ? "B" : "A"
            let playing = try clipByPath(service, reopenID)
            XCTAssertEqual(Set(playing.bytes), [UInt8(ascii: old == "A" ? "A" : "B")], "round \(round)")
            let next = try copy("prepareme-reopen-\(version)", as: "library.\(round).zim")
            service.__store(next, with: reopenID)
            XCTAssertTrue(frontPage(service, reopenID).contains("Version \(version)"), "round \(round)")
            XCTAssertEqual(service.__takeReopenedIDs() as? [UUID], [reopenID], "round \(round)")
            let after = try read(playing.path, playing.offset)
            XCTAssertEqual(after, playing.bytes, "round \(round): the old path still holds the old copy")
            XCTAssertEqual(Set(try clipByPath(service, reopenID).bytes), [UInt8(ascii: version == "A" ? "A" : "B")],
                           "round \(round): the next read is the new copy's")
            try FileManager.default.removeItem(at: current)
            current = next
        }

        queue.waitUntilAllOperationsAreFinished()
        XCTAssertEqual(searches.filter { $0.__results.count == 0 }.count, 0, "searches that found nothing")
    }

    /// The checks a downloaded copy passes before it is used: the library's ID and the ZIM file's own checksum.
    func testTheChecksRefuseADamagedCopyAnotherIDAndAFileThatIsntALibrary() throws {
        XCTAssertNil(ZimFileService.problem(withFileAt: try fixture("prepareme-reopen-A"), expecting: reopenID))
        XCTAssertEqual(ZimFileService.problem(withFileAt: try fixture("prepareme-reopen-other-id"),
                                              expecting: reopenID), "it carries another library's ID")

        let damaged = try copy("prepareme-reopen-A", as: "damaged.zim")
        let handle = try FileHandle(forUpdating: damaged)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size / 2)
        let byte = try XCTUnwrap(handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: size / 2)
        try handle.write(contentsOf: Data([byte ^ 0xFF]))
        try handle.close()
        XCTAssertEqual(ZimFileService.problem(withFileAt: damaged, expecting: reopenID),
                       "its own checksum doesn't match its contents")

        let text = folder.appending(path: "not-a-library.zim")
        try Data("not a library".utf8).write(to: text)
        XCTAssertEqual(ZimFileService.problem(withFileAt: text, expecting: reopenID), "it can't be opened as a library")
    }

    /// Byte ranges of a video, as WebKit asks for them, and the same bytes by path and offset.
    func testAVideoIsReadInRangesAndByPathAndOffset() throws {
        let service = ZimService.__sharedInstance()
        service.__store(try copy("prepareme-app-links", as: "links.zim"), with: linksID)
        XCTAssertNotNil(service.__open(linksID))
        defer { service.__close(linksID) }
        let whole = Data((0..<300_000).map { UInt8(($0 * 7) % 256) })
        XCTAssertEqual(service.__getContentSize(linksID, contentPath: "media/clip.mp4"), 300_000)
        for (start, end) in [(0, 1023), (1000, 199_999), (299_000, 299_999)] {
            let part = try XCTUnwrap(service.__getContent(linksID, contentPath: "media/clip.mp4",
                                                          start: UInt(start), end: UInt(end)))
            XCTAssertEqual(part["data"] as? Data, whole[start...end], "\(start)-\(end)")
            XCTAssertEqual((part["end"] as? NSNumber)?.intValue, end)
        }
        XCTAssertEqual(try clipByPath(service, linksID).bytes, whole)
    }

    /// A page links into another library by its ID; with that library on the phone the link has a page, and without it
    /// it has none, which is when the app offers "Get this file" (BrowserViewModel.missingLibrary).
    func testLinksBetweenFilesResolveOnlyToALibraryThePhoneHolds() async throws {
        let service = ZimService.__sharedInstance()
        service.__store(try copy("prepareme-app-links", as: "links.zim"), with: linksID)
        service.__store(try copy("prepareme-app-maps", as: "maps.zim"), with: mapsID)
        defer {
            service.__close(linksID)
            service.__close(mapsID)
        }
        let front = frontPage(service, linksID)
        let toMaps = "zim://\(mapsID.uuidString.lowercased())/maps.html"
        let toAbsent = "zim://\(absentID.uuidString.lowercased())/absent.html"
        XCTAssertTrue(front.contains(toMaps))
        XCTAssertTrue(front.contains(toAbsent))
        let held = await ZimFileService.shared.getContentSize(url: try XCTUnwrap(URL(string: toMaps)))
        XCTAssertNotNil(held)
        XCTAssertTrue(page(service, mapsID, "maps.html").contains("Find a map test page"))
        let absent = await ZimFileService.shared.getContentSize(url: try XCTUnwrap(URL(string: toAbsent)))
        XCTAssertNil(absent, "no page: the get-file sheet's case")
    }

    /// A page the packer keeps out of full-text search (its front page and guide list, F-011) stays out on the phone;
    /// the same word on an ordinary page is found.
    func testAPageKeptOutOfSearchIsntFound() throws {
        let service = ZimService.__sharedInstance()
        service.__store(try copy("prepareme-app-links", as: "links.zim"), with: linksID)
        XCTAssertNotNil(service.__open(linksID))
        defer { service.__close(linksID) }
        let search = SearchOperation(searchText: "quokka", zimFileIDs: [linksID], withSpellingCacheDir: nil)
        search.main()
        let paths = (search.__results.array as? [SearchResult] ?? []).map(\.url.path)
        XCTAssertTrue(paths.contains("/found.html"), "\(paths)")
        XCTAssertFalse(paths.contains("/kept.html"), "\(paths)")
    }

    /// Games plan phase 2: every library answer carries the page's own block, whole or in part (a game's large file is
    /// read in ranges), so a page loaded before the launch's rule list still reaches only the library
    func testEveryLibraryAnswerCarriesTheContentSecurityPolicy() throws {
        let url = try XCTUnwrap(URL(string: "zim://0f1e2d3c-4b5a-4968-8776-6554433221b1/index.html"))
        let meta = URLContentMetaData(mime: "text/html", size: 100, zimTitle: "SAMPLE", lastModified: nil)
        for range in [nil, ClosedRange<UInt>(uncheckedBounds: (0, 9))] {
            let response = try XCTUnwrap(HTTPSuccess.response(url: url, metaData: meta, requestedRange: range))
            let csp = try XCTUnwrap(response.value(forHTTPHeaderField: "Content-Security-Policy"))
            XCTAssertTrue(csp.hasPrefix("default-src zim: blob: data: "), csp)
            XCTAssertFalse(csp.contains("http"), "no web address is ever allowed: \(csp)")
        }
    }

    /// The reader's two app settings are the app's alone: Kiwix and the Mac's Kiwix (PrepareMe) keep opening every fold
    /// and showing their own alert for a missing page.
    @MainActor
    func testTheAppsSettingsAreOffUnlessTheAppSetsThem() {
        XCTAssertFalse(BrowserViewModel.keepsFoldsAsBuilt)
        XCTAssertNil(BrowserViewModel.missingLibrary)
    }
}
