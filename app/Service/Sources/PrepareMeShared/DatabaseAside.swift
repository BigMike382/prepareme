import Foundation

/// The reader's own small database (Kiwix's open tabs and bookmarks) when it won't open (audit D4): a damaged one is
/// moved aside with the date and the app starts with a fresh one, never stopping at every launch. One that can't be
/// read now (still locked after a restart) isn't damaged and is never moved. The layout is never changed in place.
public enum DatabaseAside {
    /// Whether the store at `url` can be read now: false only when it is there and can't be opened for reading.
    public static func readable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    /// The store and its two companions (`-wal`, `-shm`) renamed `<stem>-unreadable-<date and time>.<ext>…` beside
    /// it (`-1`, `-2` if taken). Whether the store is out of the way: true when it was moved or wasn't there. A
    /// companion that can't be moved is deleted, so a fresh store never meets the old one's journal.
    public static func move(_ url: URL, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        let stamp = ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withFullDate, .withTime])
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        guard let name = (0..<100).lazy.map({ "\(stem)-unreadable-\(stamp)\($0 == 0 ? "" : "-\($0)")\(ext)" })
            .first(where: { !fm.fileExists(atPath: folder.appendingPathComponent($0).path) }),
            (try? fm.moveItem(at: url, to: folder.appendingPathComponent(name))) != nil else { return false }
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: companion.path) else { continue }
            if (try? fm.moveItem(at: companion, to: folder.appendingPathComponent(name + suffix))) == nil {
                try? fm.removeItem(at: companion)
            }
        }
        return true
    }
}
