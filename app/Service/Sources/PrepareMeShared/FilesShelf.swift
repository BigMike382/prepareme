import Foundation

/// The library in Files, for the App Store Kiwix as the backup reader (plan phase 10; switched on once iCloud delivery
/// stopped, D7, owner 2026-10-15). Each library file the phone holds also shows under its manifest name
/// ("prepareme-daily.zim") in the app's Documents folder, which Files lists as On My iPhone › PrepareMe:
///
/// - A hard link to the held copy, never a copy: the same blocks, so it costs no space, and the held copy is never
///   changed in place (LibraryStore writes each update under a name of its own), so the link never shows a half-written
///   file. Kept out of backups with the held copy (one file, one flag).
/// - An update is a new link under a hidden name, then a rename over the old name in one step, so Kiwix finds either
///   the old file or the new one, never none; Kiwix sees the update when it opens the library again (FINDINGS F-043).
/// - Only ZIM files: the street map (PMTiles) is no reader's.
/// - Only its own links are ever removed (review, 2026-10-15): the folder is writable in Files, so a file someone saves
///   there is theirs, ZIM or not. Each held copy carries a tag naming its own file number before it is linked, and a
///   link is the same file, so it carries the tag wherever it goes; a copy made in Files has the tag but another file
///   number, so it stays theirs. A link moved into a subfolder or renamed is removed too: left there, it would keep an
///   old library's blocks on disk after every update, and show Kiwix a second copy under the same ID (F-043).
public enum FilesShelf {
    /// The extended attribute that marks a held copy, and so each of its links, as the shelf's.
    static let tag = "com.bigmike382.prepareme.shelf"

    /// Make `folder` show exactly the held ZIM files of `held` (their copies in `library`), and clear every link of its
    /// own left anywhere else in it. Returns what changed, for the log: names linked and paths (within `folder`)
    /// removed.
    @discardableResult
    public static func sync(_ held: [String: HeldFile], library: URL, folder: URL) -> (linked: [String], removed: [String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var linked: [String] = [], removed: [String] = []
        var shown = Set<String>()
        for (name, file) in held where !file.entry.isStreetMap && name.hasSuffix(".zim") && !name.hasPrefix(".")
            && !name.contains("/") {
            let source = library.appendingPathComponent(file.file), target = folder.appendingPathComponent(name)
            guard let want = inode(source) else { continue }
            shown.insert(name)
            if !isOurs(source) { mark(source, want) }
            if inode(target) == want { continue }
            let part = folder.appendingPathComponent(".\(name).link")
            try? fm.removeItem(at: part)
            do {
                try fm.linkItem(at: source, to: part)
                guard rename(part.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
                linked.append(name)
            } catch {
                try? fm.removeItem(at: part)
            }
        }
        for path in (try? fm.subpathsOfDirectory(atPath: folder.path)) ?? [] {  // never follows a symbolic link
            let url = folder.appendingPathComponent(path)
            if !path.contains("/"), path.hasPrefix("."), path.hasSuffix(".link") {
                try? fm.removeItem(at: url)  // a link a stopped update left behind
                continue
            }
            // A held name stays, even when its update failed: it is linked again next time.
            guard !shown.contains(path), isOurs(url), (try? fm.removeItem(at: url)) != nil else { continue }
            removed.append(path)
        }
        return (linked.sorted(), removed.sorted())
    }

    /// A plain file's number; nil for anything else (a folder, a symbolic link) or one that isn't there.
    static func inode(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// Whether `url` is one of the shelf's files: tagged with its own file number.
    static func isOurs(_ url: URL) -> Bool {
        guard let inode = inode(url) else { return false }
        var value = [UInt8](repeating: 0, count: 32)
        let count = getxattr(url.path, tag, &value, value.count, 0, XATTR_NOFOLLOW)
        return count > 0 && String(decoding: value[..<count], as: UTF8.self) == String(inode)
    }

    private static func mark(_ url: URL, _ inode: UInt64) {
        let value = Array(String(inode).utf8)
        _ = setxattr(url.path, tag, value, value.count, 0, XATTR_NOFOLLOW)
    }
}
