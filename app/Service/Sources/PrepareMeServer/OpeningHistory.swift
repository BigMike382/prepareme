import Foundation
import PrepareMeShared

/// The opening self-check's running record (docs/plans/2026-11-14-opening-self-check.md, Task 2.1): one JSON line per
/// room report whose tally has openings, in the pairing folder beside `phones-storage.json`, which keeps only each
/// phone's latest (which the hourly notice reads). `learn/openings.py`, the weekly scoreboard, reads this. Fixed kinds,
/// counts, milliseconds, a build and the phone's label only (the service's "phone 1", never a typed name). The
/// service's replies run on one queue, so two reports never rewrite it at once.
enum OpeningHistory {
    static let fileName = "opening-checks.jsonl"
    static let most = 5_000  // lines kept, the newest

    /// Adds the report's tally as one line, sorted keys; nothing when it holds no opening, crash or hang (a phone that
    /// crashed before any check ran still sends its crash count: phase 4). Throws when the record can't be read or
    /// saved: the caller lets that go, so the room report is still taken.
    /// shortcut: a tally the Mac took but the phone never heard back about is sent again and counted twice, and a
    /// tally that spans an update (crashes included) is counted under the last opening's build; the record is for
    /// trends, not billing.
    static func append(_ report: OpeningCheck.Report, phone label: String, at: Date, in folder: URL) throws {
        let tally = report.tally
        guard tally.hasCounts else { return }
        let row: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: at), "phone": label, "build": report.last.build,
            "openings": tally.openings, "failed": tally.failed, "late": tally.late, "stopped": tally.stopped,
            "slowest_ms": tally.slowestMs, "crashes": tally.crashes.map { $0 as Any } ?? NSNull(),
            "hangs": tally.hangs.map { $0 as Any } ?? NSNull(),
        ]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self)
        let file = folder.appendingPathComponent(fileName)
        // a record that is there but can't be opened is never written over
        let kept = FileManager.default.fileExists(atPath: file.path)
            ? String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n").map(String.init) : []
        let lines = (kept + [line]).suffix(most)
        try DurableFile.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: file)
    }
}
