import CryptoKit
import Foundation

/// Essential Documents' encryption (docs/documents.md): AES-256-GCM in 1 MB pieces, so a file of any size is never
/// held whole while it's stored. A file is "PMD1" and a random 16-byte file ID, then each piece as a last-piece flag,
/// its sealed length and the sealed piece (nonce, ciphertext, tag). Each piece's file ID, number and flag are sealed
/// in with it, so a changed byte, a piece moved, swapped from another file or cut off refuses to open rather than
/// reading wrong. Apple's CryptoKit only.
public enum DocumentCipher {
    public enum Failure: Error, Equatable {
        case notADocument, damaged, cutShort
    }

    static let magic = Data("PMD1".utf8)
    public static let pieceSize = 1 << 20

    /// Encrypts `source` into `destination`, saved whole (written beside it, forced to the disk, swapped in), and
    /// returns the plain file's SHA-256 and size as read.
    @discardableResult
    public static func encrypt(from source: URL, to destination: URL, key: SymmetricKey) throws
        -> (sha256: String, size: Int64) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        try DurableStream.write(to: destination) { output in
            try seal(next: {
                let piece = try input.read(upToCount: pieceSize) ?? Data()
                hasher.update(data: piece)
                size += Int64(piece.count)
                return piece
            }, into: output, key: key)
        }
        return (Hex.string(hasher.finalize()), size)
    }

    /// Encrypts `data` (the index) into `destination`, saved whole.
    public static func encrypt(_ data: Data, to destination: URL, key: SymmetricKey) throws {
        var offset = 0
        try DurableStream.write(to: destination) { output in
            try seal(next: {
                let end = min(offset + pieceSize, data.count)
                defer { offset = end }
                return data.subdata(in: offset..<end)
            }, into: output, key: key)
        }
    }

    /// Each plain piece of `url` in order, every one checked; throws on the first that doesn't open.
    public static func forEachPiece(of url: URL, key: SymmetricKey, _ body: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard let head = try input.read(upToCount: 20), head.count == 20, head.prefix(4) == magic else {
            throw Failure.notADocument
        }
        let fileID = head.suffix(16)
        var index: UInt64 = 0
        while true {
            guard let frame = try input.read(upToCount: 5), !frame.isEmpty else { throw Failure.cutShort }
            guard frame.count == 5 else { throw Failure.cutShort }
            let last = frame[frame.startIndex] == 1
            let length = frame.suffix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length >= 28, length <= pieceSize + 28,
                  let sealed = try input.read(upToCount: length), sealed.count == length else { throw Failure.cutShort }
            let plain: Data
            do {
                plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key,
                                         authenticating: aad(fileID, index, last))
            } catch {
                throw Failure.damaged
            }
            try body(plain)
            index += 1
            if last {
                guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw Failure.damaged }
                return
            }
        }
    }

    /// The whole plain file, checked.
    public static func decrypt(_ url: URL, key: SymmetricKey) throws -> Data {
        var data = Data()
        try forEachPiece(of: url, key: key) { data.append($0) }
        return data
    }

    /// The plain file's SHA-256 and size, read back from the stored copy without holding it whole.
    public static func plainFingerprint(of url: URL, key: SymmetricKey) throws -> (sha256: String, size: Int64) {
        var hasher = SHA256()
        var size: Int64 = 0
        try forEachPiece(of: url, key: key) { piece in
            hasher.update(data: piece)
            size += Int64(piece.count)
        }
        return (Hex.string(hasher.finalize()), size)
    }

    private static func seal(next: () throws -> Data, into output: FileHandle, key: SymmetricKey) throws {
        let fileID = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }  // 16 random bytes
        try output.write(contentsOf: magic + fileID)
        var piece = try next()
        var index: UInt64 = 0
        while true {
            let following = piece.count < pieceSize ? Data() : try next()
            let last = following.isEmpty
            guard let sealed = try AES.GCM.seal(piece, using: key, authenticating: aad(fileID, index, last)).combined
            else { throw Failure.damaged }
            let length = UInt32(sealed.count)
            let frame = Data([last ? 1 : 0, UInt8(length >> 24), UInt8(length >> 16 & 0xff),
                              UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
            try output.write(contentsOf: frame + sealed)
            if last { return }
            piece = following
            index += 1
        }
    }

    private static func aad(_ fileID: Data, _ index: UInt64, _ last: Bool) -> Data {
        var data = Data(fileID)
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(index >> UInt64(shift) & 0xff)) }
        data.append(last ? 1 : 0)
        return data
    }
}

/// A file written piece by piece and saved whole, as `DurableFile.write` saves one held in memory: a temporary copy
/// beside it (owner-only), forced to the disk, swapped in, the folder flushed; a stopped save's leftovers swept first.
enum DurableStream {
    static func write(to url: URL, _ body: (FileHandle) throws -> Void) throws {
        let folder = url.deletingLastPathComponent()
        DurableFile.sweep(for: url)
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            try body(handle)
            try DurableFile.flush(fd)
        } catch {
            close(fd)
            unlink(temporary.path)
            throw error
        }
        close(fd)
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        DurableFile.flushFolder(folder)
    }
}
