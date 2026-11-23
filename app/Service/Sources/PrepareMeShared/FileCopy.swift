import Foundation

/// The copy Add from Files and Add a travel map make from a picked folder (phase K, finding 12): run inside the app's
/// coordinated read (PrepareMeAddFromFiles.swift, `coordinatedCopy`, which has iCloud bring the file to the phone
/// first), kept here so `swift test` holds which step failed and the words for each. Before, every failure was worded
/// as "the phone needs internet", a full phone included.
public enum FileCopy {
    /// Which step of a copy failed
    public enum Failure: Error, Equatable, Sendable {
        /// The folder's file couldn't be read (iCloud couldn't bring it, a drive pulled out)
        case readFailed
        /// Read to its end, but not the size the folder's list gives: it changed while it was copied
        case changed
        /// No room left on the phone
        case full
        /// The phone couldn't write or keep its copy, for this reason
        case notSaved(String)
        case stopped
    }

    /// `source` copied to `target` in pieces, through `partial` (removed first, and again when the copy fails), then
    /// renamed in; nil when every byte of `size` was read and written and the copy is in place. A read that fails
    /// part-way is never taken for the end of the file. Blocking: run off the main thread.
    public static func copy(_ source: URL, to target: URL, size: Int64, partial: URL, pieceSize: Int = 4 << 20,
                            isStopped: () -> Bool, progress: (Double) -> Void) -> Failure? {
        try? FileManager.default.removeItem(at: partial)
        guard !isStopped() else { return .stopped }
        guard let input = try? FileHandle(forReadingFrom: source) else { return .readFailed }
        defer { try? input.close() }
        let fd = open(partial.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return failure(writing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let failed = pieces(input, to: output, size: size, pieceSize: pieceSize, isStopped: isStopped,
                            progress: progress)
        try? output.close()
        if failed == nil, rename(partial.path, target.path) == 0 { return nil }
        let result = failed ?? failure(writing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        try? FileManager.default.removeItem(at: partial)
        return result
    }

    private static func pieces(_ input: FileHandle, to output: FileHandle, size: Int64, pieceSize: Int,
                               isStopped: () -> Bool, progress: (Double) -> Void) -> Failure? {
        var copied: Int64 = 0
        while true {
            let piece: Data
            do {
                guard let read = try input.read(upToCount: pieceSize), !read.isEmpty else { break }
                piece = read
            } catch {
                return .readFailed
            }
            guard !isStopped() else { return .stopped }
            do {
                try output.write(contentsOf: piece)
            } catch {
                return failure(writing: error)
            }
            copied += Int64(piece.count)
            progress(size > 0 ? Double(copied) / Double(size) : 1)
        }
        do {
            try output.synchronize()
        } catch {
            return failure(writing: error)
        }
        return copied == size ? nil : .changed
    }

    /// A write that failed: a full phone (or a full allowance) told from every other reason
    public static func failure(writing error: Error) -> Failure {
        isFull(error as NSError) ? .full : .notSaved(reason(error))
    }

    private static func isFull(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) || error.code == Int(EDQUOT) { return true }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isFull) ?? false
    }

    /// An error's reason in a few words, for a line that names it ("Permission denied"): the system's own words for
    /// a POSIX error, else its description, without a closing period
    public static func reason(_ error: Error) -> String {
        let error = error as NSError
        let posix = error.domain == NSPOSIXErrorDomain ? error
            : (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0 : nil }
        var words = posix.map { String(cString: strerror(Int32($0.code))) } ?? error.localizedDescription
        while words.hasSuffix(".") { words.removeLast() }
        return words
    }

    /// The words Add from Files gives under a file whose copy failed (the plan's table, approved 2026-10-20)
    public static func words(_ failure: Failure, device: String = "phone") -> String {
        switch failure {
        case .readFailed:
            return "Couldn't be read from the folder. If it is in iCloud Drive, the \(device) needs internet."
        case .changed: return "The file changed while it was being copied. Try again."
        case .full: return "Not enough room on this \(device) to finish the copy."
        case let .notSaved(reason): return "Couldn't be saved on this \(device): \(reason)."
        case .stopped: return "Stopped; nothing changed."
        }
    }
}
