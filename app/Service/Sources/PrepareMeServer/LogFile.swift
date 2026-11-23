import Foundation

/// A log the service writes itself, a line at a time (plan phase 6): when PrepareMe runs it, macOS won't let a
/// sandboxed app's background part name an output file for launchd to fill. Over `limit` bytes, the file becomes
/// `<name>.old.log` (one kept) and a new one starts, as the Mac app's checks.log does.
public final class LogFile: @unchecked Sendable {
    public let url: URL
    let limit: Int
    private let lock = NSLock()

    public init(url: URL, limit: Int = 1_000_000) {
        self.url = url
        self.limit = limit
    }

    public func add(_ line: String) {
        lock.withLock {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= limit {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
