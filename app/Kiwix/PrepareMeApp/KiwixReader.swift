// This file is part of PrepareMe, a local build of Kiwix for one household's phones and Mac (build plan phases 4, 6).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import CoreData
import Foundation
import PrepareMeShared

/// Kiwix as the store's reader, on the phone and the Mac: a copy is registered by LibraryOperations.open (which stores
/// its path for the library's ID, so an open archive is opened again from the new path), and a swap reloads the
/// library's front pages.
@MainActor
final class KiwixReader: LibraryReader {
    func register(_ file: URL) async -> Bool {
        await LibraryOperations.open(url: file) != nil
    }

    func registeredPath(of id: String) async -> String? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return await ZimFileService.shared.getFileURL(zimFileID: uuid)?.path
    }

    func knows(_ id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return Self.record(uuid) != nil
    }

    func swapped(_ entry: Manifest.Entry, wasNew: Bool) async {
        guard let id = UUID(uuidString: entry.id) else { return }
        Self.forgetSpellings(entry.id)  // the new copy's words, at the next search
        if wasNew, PrepareMeLibraries.leftOutOfSearch.contains(id), let record = Self.record(id) {
            record.includedInSearch = false
            try? Database.shared.viewContext.save()
        }
        await BrowserViewModel.reloadFrontPages(of: LibraryOperations.refreshReopened())
        if wasNew, entry.kind == "library", entry.name == "prepareme-daily.zim",
           let url = await ZimFileService.shared.getMainPageURL(zimFileID: id) {
            // the daily library's front page, the first time it arrives: on the phone into Today's own tab, never the tab
            // on screen, so Guides still opens on its guide list (remaining-findings plan, Task 10.1; F15)
            #if os(iOS)
            PrepareMeTabs.shared.browser(.today).load(url: url)
            #else
            NotificationCenter.openURL(url)
            #endif
        }
    }

    func remove(_ id: String) async {
        guard let uuid = UUID(uuidString: id) else { return }
        await LibraryOperations.unlink(zimFileID: uuid)  // closed, its tabs and bookmarks gone; the store deletes the copy
        Self.forgetSpellings(id)
    }

    /// Kiwix's spelling index for the library, named by its ID alone, so it never sees a new copy's words (SpellingIndex)
    static func forgetSpellings(_ id: String) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        SpellingIndex.forget(id, in: caches)
    }

    static func record(_ id: UUID) -> ZimFile? {
        let request = ZimFile.fetchRequest(fileID: id)
        request.fetchLimit = 1
        return try? Database.shared.viewContext.fetch(request).first
    }
}
