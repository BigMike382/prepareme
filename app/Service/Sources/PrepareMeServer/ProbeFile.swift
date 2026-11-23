import CryptoKit
import Foundation
import PrepareMeShared

/// The probe's made-up library (plan phase 1): random bytes under one fixed name, `probe-test.bin`, never a real
/// library and never a live ID. Its ID is a made-up one kept in the service's folder (`probe-id`). A swap writes the
/// new file under a temporary name, forces it to the disk, swaps it in, then writes the manifest whole. A phone that
/// read the old manifest just before can still fetch the new file and find its SHA-256 wrong; it refuses it once and
/// tries again (the probe's Downloader.refuse). A phone downloading the old file keeps reading it: the open file
/// outlives its name. Two swaps never overlap: each holds `.swap.lock` in the folder (a dot name is never served).
public enum ProbeFile {
    public static let name = "probe-test.bin"

    public enum SwapProblem: Error, Sendable {
        case anotherSwapRunning
    }

    public struct Made: Sendable {
        public var size: Int64
        public var sha256: String
        public var damaged: Bool
    }

    /// The made-up ID: "probe-" and a random UUID, made once.
    public static func id(in serviceFolder: URL) throws -> String {
        let url = serviceFolder.appendingPathComponent("probe-id")
        if let found = try? String(contentsOf: url, encoding: .utf8), found.hasPrefix("probe-") { return found }
        let made = "probe-" + UUID().uuidString.lowercased()
        try DurableFile.write(Data(made.utf8), to: url)
        return made
    }

    /// A new file of `bytes` random bytes and its manifest. `damaged` changes one byte in the middle after its SHA-256
    /// is taken, so the manifest describes the right file and the served one is one byte off (check d).
    @discardableResult
    public static func swap(folder: URL, id: String, bytes: Int64, damaged: Bool = false, now: Date = Date())
        throws -> Made
    {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = open(folder.appendingPathComponent(".swap.lock").path, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SwapProblem.anotherSwapRunning }
        let target = folder.appendingPathComponent(name)
        let temporary = folder.appendingPathComponent(".\(name).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forUpdating: temporary) else {
            throw POSIXError(.EIO)
        }
        var hasher = SHA256()
        var generator = SystemRandomNumberGenerator()
        var left = bytes
        do {
            defer { try? handle.close() }
            while left > 0 {
                let count = Int(min(left, 4 << 20))
                var piece = [UInt8](repeating: 0, count: count)
                piece.withUnsafeMutableBytes { raw in
                    var at = 0
                    while at + 8 <= count {
                        raw.storeBytes(of: generator.next() as UInt64, toByteOffset: at, as: UInt64.self)
                        at += 8
                    }
                    while at < count {
                        raw[at] = UInt8(truncatingIfNeeded: generator.next() as UInt64)
                        at += 1
                    }
                }
                hasher.update(data: piece)
                try handle.write(contentsOf: piece)
                left -= Int64(count)
            }
            if damaged, bytes > 0 {
                try handle.seek(toOffset: UInt64(bytes / 2))
                let original = try handle.read(upToCount: 1) ?? Data([0])
                try handle.seek(toOffset: UInt64(bytes / 2))
                try handle.write(contentsOf: Data([original[0] ^ 0xFF]))
            }
            try DurableFile.flush(handle.fileDescriptor)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        DurableFile.flushFolder(folder)
        let sha = Hex.string(hasher.finalize())
        let stamp = ISO.now(now)
        let manifest = Manifest(writtenAt: stamp, files: [
            Manifest.Entry(name: name, id: id, kind: "library", size: bytes, sha256: sha, deliveredAt: stamp),
        ])
        try DurableFile.write(manifest.encoded(), to: folder.appendingPathComponent("manifest.json"))
        return Made(size: bytes, sha256: sha, damaged: damaged)
    }

    /// When the served manifest was written; nil when there is none or it can't be read.
    public static func writtenAt(folder: URL) -> Date? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? Manifest.read(data) else { return nil }
        return ISO8601DateFormatter().date(from: manifest.writtenAt)
    }
}
