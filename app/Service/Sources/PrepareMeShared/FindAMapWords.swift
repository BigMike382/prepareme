import Foundation

/// Find a map's empty screen on the phone (beta run 3, B3-02; owner, 2026-10-21, choice a): the topo overview is the
/// file Find a map reads. While it waits for room under the phone's reserve (`LibraryPlan.waitingForRoom`) the screen
/// says so and an adult can get it now, as Home Mac's Get this file does; for every other empty case the old words.
public enum FindAMapWords {
    /// The old words: the overview isn't here and isn't held back for room (still coming, set to Never, no list yet).
    public static let fromTheMac = "The maps come from the Mac with the library. Downloads shows how far it has "
        + "got."

    /// The topo overview's entry when it is among the files waiting for room; nil for any other case.
    public static func waitingOverview(_ waiting: [Manifest.Entry], overviewFile: String) -> Manifest.Entry? {
        waiting.first { $0.name == overviewFile }
    }

    /// What an adult's phone reads while the overview waits (`size` through `StorageWords`, `device` from ThisDevice).
    public static func waitingForRoom(size: String, device: String) -> String {
        "The map overview is waiting for room on this \(device) (\(size)). Download it, or free up space."
    }

    /// Home Mac's name for the same ask (look 3 change 20: one name per command).
    public static let getThisFile = "Download"

    /// After Get this file, and while the overview downloads by itself (the owner's click, 2026-10-21): the screen said the
    /// old words until the file landed.
    public static func getting(device: String) -> String {
        "Getting the map overview now. Find a map opens here once it's on this \(device)."
    }

    /// Whether the overview is on its way: asked for (Get this file, `LibraryRecord.requested`) or downloading (the
    /// library's `progress`). A removed file is no longer asked for (`LibraryStore.remove`).
    public static func isGetting(requested: Set<String>, downloading: [String: Double], overviewFile: String) -> Bool {
        requested.contains(overviewFile) || downloading[overviewFile] != nil
    }
}
