import CryptoKit
import Foundation
import Security

/// SHA-256 of a file read in 4 MB pieces, so a 1 GB file never sits in memory.
public enum FileCheck {
    public enum Verdict: Equatable, Sendable {
        case ok
        case wrongSize(actual: Int64)
        case wrongHash
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 4 << 20), !piece.isEmpty {
            hasher.update(data: piece)
        }
        return Hex.string(hasher.finalize())
    }

    /// Whether the file at `url` is the one the manifest describes: its size first (cheap), then its SHA-256.
    public static func verify(_ url: URL, size: Int64, sha256 expected: String) throws -> Verdict {
        let actual = Int64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? -1)
        guard actual == size else { return .wrongSize(actual: actual) }
        return try sha256(of: url) == expected ? .ok : .wrongHash
    }
}

/// The certificate pin: the SHA-256 of the Mac's certificate as DER, which the pairing code carries. The phone trusts
/// a connection only when the server's leaf certificate has exactly that fingerprint; the name in it isn't read.
public enum Pin {
    public static func fingerprint(of certificate: SecCertificate) -> String {
        Hex.string(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
    }

    public static func matches(_ trust: SecTrust, pin: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return false
        }
        return fingerprint(of: leaf) == pin
    }
}

/// A file saved whole, even through a power cut (CLAUDE.md, "A file the project reads back is saved whole"), the way
/// packer.durable.replace does it: written under a temporary name in the same folder, forced to the disk with
/// F_FULLFSYNC (a plain fsync on a disk that refuses it), swapped in, and the folder flushed. Owner-only (0600).
/// Each save first sweeps the file's own temporary copies a stopped save left (phase K's drills, finding 5).
public enum DurableFile {
    /// A temporary copy older than this is a stopped save's, never one still being written
    public static let leftoverAge: TimeInterval = 60

    public static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        sweep(for: url)
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var done = false
        defer {
            if !done { unlink(temporary.path) }
        }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let wrote = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    guard wrote > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += wrote
                }
            }
            try flush(fd)
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        done = true
        flushFolder(folder)
    }

    /// Removes `url`'s own temporary copies (".<name>.tmp-…", plain files) over `leftoverAge` old: a save stopped by a
    /// power cut or a kill. Never another file's, nor one a save is still writing; errors are let go (the next save
    /// tries again), as packer.durable.sweep does.
    public static func sweep(for url: URL, now: Date = Date()) {
        let folder = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent).tmp-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let path = folder.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) > leftoverAge { unlink(path) }
        }
    }

    /// The file's data out of the drive's cache.
    public static func flush(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The folder's change out of the drive's cache; one that can't be flushed is let go, as packer.durable does.
    public static func flushFolder(_ folder: URL) {
        let fd = open(folder.path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
        close(fd)
    }
}

/// The account's own home folder, from the user database: never `$HOME`, and never the folder a sandbox gives an app or
/// its background part (homeDirectoryForCurrentUser answers that one there). The Mac app and its service read the
/// PrepareMe folders under the real home through their sandbox exceptions (plan phase 6).
public enum RealHome {
    public static var url: URL? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
}
