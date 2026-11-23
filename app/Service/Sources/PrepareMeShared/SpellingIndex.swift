import Foundation

/// Kiwix's spelling index for a library (libkiwix 14.2.1's SpellingsDB, built in the app's caches the first time a
/// library is searched with spelling help on) is named by the library's ID alone: "<id>.spellingsdb.v0.1", the ID in
/// lower case. PrepareMe's libraries keep their ID from copy to copy (packer/volumes.toml), so a new copy's words would
/// never reach the index: it is dropped when a copy is swapped in or removed, and Kiwix builds it again at the next
/// search (phase 3, Task 3.2).
public enum SpellingIndex {
    public static func forget(_ id: String, in caches: URL) {
        let name = id.lowercased() + ".spellingsdb.v0.1"
        for file in [name, name + ".tmp", name + ".failed"] {  // .failed: ZimService.mm's mark of a build that failed
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(file))
        }
    }
}
