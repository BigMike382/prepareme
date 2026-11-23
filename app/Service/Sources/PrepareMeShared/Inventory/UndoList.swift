import Foundation

/// Quick add's Undo list on the phone (whole-plan review): an Undo that waited for a send of its scan and timed out
/// puts the scan back where it was, by when it was made, not at the end, so a scan made or undone during the wait
/// never changes which one the next Undo takes back (the latest).
public enum UndoList {
    public static func putBack<Entry>(_ entry: Entry, into log: inout [Entry], madeAt: (Entry) -> Double) {
        let at = log.firstIndex { madeAt($0) > madeAt(entry) } ?? log.endIndex
        log.insert(entry, at: at)
    }
}
