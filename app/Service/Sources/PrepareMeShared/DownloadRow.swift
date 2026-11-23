import Foundation

/// What a catalog row shows where its Download button was (library redesign plan, Task 1.1; owner, 2026-11-13: a
/// click answers on the row, not only in the Downloads list).
public enum DownloadRow: Equatable {
    case ready
    case running(done: Int64, total: Int64, secondsLeft: Int?)
    case waiting(behind: String)
    case kept(place: String?)
    case paused  // stopped part-way: a part is on disk, and the button resumes it (phase 1 review)

    /// Running wins over queued, so a second click on a running row never shows it as waiting behind itself.
    public static func state(source: String, running: [String: (done: Int64, total: Int64, started: Date, from: Int64)],
                             queued: [String], runningTitle: String?, keptSources: Set<String>, place: String?,
                             now: Date, pausedSources: Set<String> = []) -> DownloadRow {
        if let r = running[source] {
            let elapsed = now.timeIntervalSince(r.started)
            var left: Int?
            // `from` is what was on disk when this run began: a resumed file counts only what came since
            if elapsed >= 5, r.done > r.from {  // no guess before there is a rate to guess from
                let rate = Double(r.done - r.from) / elapsed
                left = Int((Double(max(r.total - r.done, 0)) / rate).rounded(.up))
            }
            return .running(done: r.done, total: r.total, secondsLeft: left)
        }
        if queued.contains(source) { return .waiting(behind: runningTitle ?? "the one before it") }
        if keptSources.contains(source) { return .kept(place: place) }
        if pausedSources.contains(source) { return .paused }
        return .ready
    }

    public var words: String {
        switch self {
        case .ready:
            return "Download"
        case let .running(done, total, left):
            guard total > 0 else { return "Downloading" }  // before the first report: no "0 KB of 0 KB"
            let sizes = "Downloading · \(StorageWords.size(done)) of \(StorageWords.size(total))"
            guard let left else { return sizes }
            let minutes = max(1, (left + 30) / 60)
            return sizes + " · about \(minutes) minute\(minutes == 1 ? "" : "s") left"
        case let .waiting(behind):
            return "Waiting · starts when \(behind) finishes"
        case let .kept(place):
            return place.map { "✓ On this Mac · in \($0)" } ?? "✓ On this Mac"
        case .paused:
            return "Resume"
        }
    }
}

/// Lets a download's progress through at most twice a second, and always its last chunk (phase 1 review: every network
/// chunk had redrawn the catalog window). Called from the download's own thread.
public final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let every: TimeInterval
    private var last = Date.distantPast

    public init(every: TimeInterval = 0.5) { self.every = every }

    public func pass(done: Int64, total: Int64, now: Date = Date()) -> Bool {
        lock.withLock {
            guard done >= total || now.timeIntervalSince(last) >= every else { return false }
            last = now
            return true
        }
    }
}
