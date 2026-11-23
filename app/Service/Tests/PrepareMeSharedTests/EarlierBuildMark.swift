import Foundation

/// The "don't back up" flag as an earlier build left it on a device (audit D1): already on the file, at rest, written
/// the way the system writes it. A test must not make it with `setResourceValues` and clear it a few milliseconds
/// later: on a busy Mac that removal is lost about 1 time in 200 (measured 2026-11-22, 16 processes at once; a flag at
/// rest was cleared every time in 48,000 tries). On a device the flag was set by an earlier build, launches ago.
enum EarlierBuild {
    static func leaveBackupMark(on url: URL) throws {
        let value = try PropertyListSerialization.data(fromPropertyList: "com.apple.backupd", format: .binary, options: 0)
        let done = value.withUnsafeBytes {
            setxattr(url.path, "com.apple.metadata:com_apple_backup_excludeItem", $0.baseAddress, value.count, 0, 0)
        }
        guard done == 0 else { throw CocoaError(.fileWriteUnknown) }
        let seen = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard seen.isExcludedFromBackup == true else { throw CocoaError(.fileWriteUnknown) }  // the system reads it as marked
    }
}
