// This file is part of PrepareMe, a local build of Kiwix for one household (2026-11-12).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
import Testing
@testable import Kiwix

/// PrepareMe (2026-11-12): PrepareMe on the Mac aborted two seconds into every launch after the owner downloaded ten
/// Kiwix libraries. libkiwix adds each page title whole as one spelling word, and a title over the 255 bytes Xapian
/// allows a key throws Xapian::InvalidArgumentError at the commit: neither std::exception nor Xapian::DatabaseError, the
/// two the app caught, so it reached Swift and stopped the app. The made-up library is kiwix-mac/make_fixtures.py's
/// app-long-title.
@Suite(.serialized) struct PrepareMeSpellingFailureTests {
    private let longTitleID = UUID(uuidString: "0f1e2d3c-4b5a-4968-8776-6554433221a6")!

    @Test func aLibraryWhoseSpellingHelpCantBeBuiltLeavesSearchWorking() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let spelling = folder.appending(path: "spelling")
        try FileManager.default.createDirectory(at: spelling, withIntermediateDirectories: true)
        let service = ZimService.__sharedInstance()
        defer {
            service.__close(longTitleID)
            try? FileManager.default.removeItem(at: folder)
        }
        let fixture = try #require(Bundle(for: PrepareMeAppTests.self).url(forResource: "prepareme-app-long-title",
                                                                          withExtension: "zim"),
                                   "run kiwix-mac/build.sh --test, which builds the test libraries")
        let library = folder.appending(path: "long-title.zim")
        try FileManager.default.copyItem(at: fixture, to: library)
        service.__store(library, with: longTitleID)
        #expect(service.__open(longTitleID) != nil)

        // as the app does at launch and at each search (SearchViewModel, on its spelling queue): neither may stop it
        service.__createSpellingIndex(longTitleID, cachePath: spelling.path())
        service.__createSpellingIndex(longTitleID, cachePath: spelling.path())
        #expect(service.spellingsDB(for: longTitleID, cachePath: spelling.path()) == nil)
        // remembered for later launches (2026-11-14, F-115): each retry was about a minute of a large library's build
        #expect(FileManager.default.fileExists(atPath: spelling.appending(path: Self.failedMark(longTitleID)).path()))

        let search = SearchOperation.prepareMe(typed: "floodwater", zimFileIDs: [longTitleID], spelling: spelling)
        search.main()
        #expect((search.__results.array as? [SearchResult] ?? []).map(\.title).contains("Floodwater short page"))
        let missed = SearchOperation.prepareMe(typed: "floodwatr", zimFileIDs: [longTitleID], spelling: spelling)
        missed.main()  // a misspelling asks for the spelling help, which is skipped: no "Did you mean", no stop
    }

    /// A library whose build failed on an earlier launch (its mark in the caches) isn't built again; a new copy of it
    /// drops the mark with its index (SpellingIndex.forget), so that copy is tried
    @Test func aLibraryMarkedFailedIsntBuiltAgain() throws {
        // the encyclopedia library under its own ID: no other test asks it for spelling help, which the mark turns off
        // for this run (ZimService's spellingFailedIDs)
        let id = UUID(uuidString: "0f1e2d3c-4b5a-4968-8776-6554433221a5")!
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let spelling = folder.appending(path: "spelling")
        try FileManager.default.createDirectory(at: spelling, withIntermediateDirectories: true)
        let service = ZimService.__sharedInstance()
        defer {
            service.__close(id)
            try? FileManager.default.removeItem(at: folder)
        }
        let fixture = try #require(Bundle(for: PrepareMeAppTests.self).url(forResource: "prepareme-app-encyclopedia",
                                                                          withExtension: "zim"),
                                   "run kiwix-mac/build.sh --test, which builds the test libraries")
        let library = folder.appending(path: "encyclopedia.zim")
        try FileManager.default.copyItem(at: fixture, to: library)
        service.__store(library, with: id)
        #expect(service.__open(id) != nil)
        try Data().write(to: spelling.appending(path: Self.failedMark(id)))

        service.__createSpellingIndex(id, cachePath: spelling.path())
        let index = id.uuidString.lowercased() + ".spellingsdb.v0.1"
        #expect(!FileManager.default.fileExists(atPath: spelling.appending(path: index).path()))
        #expect(service.spellingsDB(for: id, cachePath: spelling.path()) == nil)
    }

    static func failedMark(_ id: UUID) -> String { id.uuidString.lowercased() + ".spellingsdb.v0.1.failed" }
}
