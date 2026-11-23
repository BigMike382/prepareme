// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household's Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import AppKit
import CoreData

/// PrepareMe: every library in the household's PrepareMe folder opens by itself, as File › Open would, so a new
/// library (the map volumes) needs no hand work. A copy with the same ID anywhere else never keeps its place: the
/// folder's file always wins (owner, 2026-10-07; FINDINGS F-043). macOS's sandbox lets the app into the folder only
/// once the owner has picked it, so it asks once and keeps a bookmark. The optional map files have a folder of their
/// own beside it, PrepareMe Optional Maps, read the same way (owner, 2026-10-12: Files' Keep Downloaded on PrepareMe
/// pins its subfolders too, so they can't sit inside it); until that one is picked, PrepareMe works as before.
@MainActor
enum PrepareMeFolder {
    struct Place {
        let name: String        // the folder's name in iCloud Drive
        let bookmarkKey: String
    }
    static let places = [Place(name: "PrepareMe", bookmarkKey: "prepareMeFolderBookmark"),
                         Place(name: "PrepareMe Optional Maps", bookmarkKey: "prepareMeOptionalFolderBookmark")]
    private static let datalessFlag: UInt32 = 0x40000000 // SF_DATALESS: the file's data is only in iCloud

    private static var folders: [String: URL] = [:] // place name → the folder picked for it
    private static var known: [String: (stamp: String, id: UUID)] = [:] // file path → what it held when last read

    /// At launch, for each place: the saved folder, or ask for it (again, with a note, if a rebuild lost access to
    /// it). A place not picked is asked for again at the next launch.
    static func prepare() {
        for place in places { prepare(place) }
    }

    private static func prepare(_ place: Place) {
        if let data = UserDefaults.standard.data(forKey: place.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                  bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                if url.lastPathComponent == place.name {
                    if stale { save(url, place) }
                    folders[place.name] = url
                    return
                }
                url.stopAccessingSecurityScopedResource() // a wrong folder saved for it (2026-10-12: PrepareMe twice)
                UserDefaults.standard.removeObject(forKey: place.bookmarkKey)
                ask(place, note: "The folder saved for \(place.name) was \(url.lastPathComponent). ")
                return
            }
            UserDefaults.standard.removeObject(forKey: place.bookmarkKey)
            ask(place, note: "Kiwix (PrepareMe) can no longer reach the \(place.name) folder (this happens after it is "
                + "rebuilt). ")
            return
        }
        ask(place, note: "")
    }

    private static func ask(_ place: Place, note: String) {
        let panel = NSOpenPanel()
        panel.message = note + "Choose the \(place.name) folder in iCloud Drive. Kiwix (PrepareMe) will then open "
            + "every library in it by itself."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let home = getpwuid(getuid())?.pointee.pw_dir { // the real home, not the app's container
            panel.directoryURL = URL(fileURLWithPath: String(cString: home))
                .appending(path: "Library/Mobile Documents/com~apple~CloudDocs/\(place.name)")
        }
        panel.title = "Choose the \(place.name) folder"
        guard panel.runModal() == .OK, let url = panel.url, url.startAccessingSecurityScopedResource() else { return }
        // Only a folder of that name: each question looks alike, and one answered with the other folder read it twice
        guard url.lastPathComponent == place.name else {
            url.stopAccessingSecurityScopedResource()
            ask(place, note: "That was the \(url.lastPathComponent) folder. ")
            return
        }
        save(url, place)
        folders[place.name] = url
    }

    private static func save(_ url: URL, _ place: Place) {
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: place.bookmarkKey)
        }
    }

    /// What one check did, for the record (PrepareMeRefresh.note)
    struct Report {
        var folders: [String] = [] // "folder ok", "optional folder not chosen", in places' order
        var opened: [String] = []
        var skipped: [String] = [] // "name: why"
    }

    /// Opens each library in the folders that isn't open from there yet. A file only in iCloud waits until it is
    /// downloaded, since opening it would hold everything up while it downloads. Two files with one ID (which the
    /// packer refuses to deliver) never take turns: the first one read this check wins and the other is skipped.
    static func openAll() async -> Report {
        var report = Report()
        var seenIDs: [UUID: String] = [:]
        for place in places {
            let label = place.name == places[0].name ? "folder" : "optional folder"
            guard let folder = folders[place.name] else {
                report.folders.append("\(label) not chosen")
                continue
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
                report.folders.append("\(label) can't be read")
                continue
            }
            report.folders.append("\(label) ok")
            for name in names.sorted() where name.lowercased().hasSuffix(".zim") {
                await open(folder.appending(path: name), name: name, seenIDs: &seenIDs, report: &report)
            }
        }
        return report
    }

    private static func open(_ url: URL, name: String, seenIDs: inout [UUID: String], report: inout Report) async {
        guard let stamp = stamp(url) else {
            report.skipped.append("\(name): only in iCloud or unreadable")
            return
        }
        let zimFileID: UUID
        if let seen = known[url.path], seen.stamp == stamp {
            zimFileID = seen.id
        } else {
            guard let read = readID(url) else {
                report.skipped.append("\(name): its header can't be read")
                return
            }
            zimFileID = read
            known[url.path] = (stamp, read)
        }
        if let first = seenIDs[zimFileID] {
            report.skipped.append("\(name): same ID as \(first)")
            return
        }
        seenIDs[zimFileID] = name
        let current = await ZimFileService.shared.getFileURL(zimFileID: zimFileID)
        if current?.standardizedFileURL.path == url.standardizedFileURL.path { return }
        let isNew = record(zimFileID) == nil
        if await LibraryOperations.open(url: url) == nil {
            report.skipped.append("\(name): Kiwix couldn't open it")
            return
        }
        report.opened.append(name)
        if isNew, PrepareMeLibraries.leftOutOfSearch.contains(zimFileID), let zimFile = record(zimFileID) {
            zimFile.includedInSearch = false
            try? Database.shared.viewContext.save()
        }
    }

    private static func record(_ zimFileID: UUID) -> ZimFile? {
        let request = ZimFile.fetchRequest(predicate: NSPredicate(format: "fileID == %@", zimFileID as CVarArg))
        request.fetchLimit = 1
        return try? Database.shared.viewContext.fetch(request).first
    }

    /// The file's inode, size and modification time, or nil if it can't be read or is only in iCloud.
    private static func stamp(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_flags & datalessFlag == 0 else { return nil }
        return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    /// The library's ID from its header (bytes 8-24), read without opening the whole file.
    private static func readID(_ url: URL) -> UUID? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 24), header.count == 24 else { return nil }
        let bytes = [UInt8](header[8..<24])
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
#endif
