import Foundation

/// The format of the files the Mac writes for the phones (audit P2h): the list of files its service serves, the
/// backup's list and the phones' inventory copy each carry it as `format`. A field an older app skips leaves it alone;
/// a change an older app would read wrongly raises it, and an app that meets a higher number than its own keeps what it
/// holds, takes nothing from that file and asks to be updated. A file from before the number (none written) is 1.
public enum FileFormat {
    /// The newest format this build reads, and the one it writes.
    public static let current = 1

    public static func isNewer(_ format: Int?) -> Bool { (format ?? 1) > current }

    /// Said where the Mac's list of files is: "this iPad" on an iPad.
    public static func newerFiles(device: String) -> String {
        "The Mac has a newer PrepareMe. Update PrepareMe on this \(device) to get the newest files."
    }

    /// Said on Inventory, the copy held kept as it is.
    public static func newerInventory(device: String) -> String {
        "The Mac has a newer PrepareMe. Update PrepareMe on this \(device) to see the newest inventory."
    }
}
