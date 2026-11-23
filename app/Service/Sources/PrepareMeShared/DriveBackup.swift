import Foundation

/// The USB drive backup (2026-10-22, docs/usb-backup.md) as the Mac app shows it: the scheduler's `usb-backup` job
/// (usbbackup/job.py) copies PrepareMe's folder and Household Private into the password-locked image on the owner's
/// drive and writes its status file in the requests folder; the app only reads that, reads jobs/installed.json for
/// whether the job is installed, and touches the request file for Back up to the drive now. The job's `summary` is its
/// own fixed words (counts and sizes, never a file's name), shown as it gives them. Its shape is pinned by
/// `Fixtures/usb-backup-status.json`, which usbbackup/tests reads too.
public struct DriveBackup: Decodable, Equatable, Sendable {
    public struct Running: Decodable, Equatable, Sendable {
        public let started: String
        public let pressed: Int64?
        public let waiting: Bool?
    }

    public struct Last: Decodable, Equatable, Sendable {
        public let finished: String
        public let exit: Int
        public let summary: String
        public let pressed: Int64?
    }

    public struct Good: Decodable, Equatable, Sendable {
        public let finished: String
        public let files: Int
        public let bytes: Int64
    }

    public let taken: Int64?
    public let running: Running?
    public let last: Last?
    public let good: Good?

    /// usbbackup/job.py's STATUS and REQUEST (the scheduler's USB_BACKUP_REQUEST), and its job's name
    public static let statusName = "usb-backup-status.json"
    public static let requestName = "usb-backup"
    public static let job = "usb-backup"
    /// usbbackup/job.py's PLAIN_SKIPPED ahead of its reason: a good backup whose go-bag copy (iCloud Drive › PrepareMe
    /// Backup, plain on the drive's top level; offline fixes, task 5.1) wasn't made or is missing files iCloud
    /// hasn't put on the Mac (2026-10-24: "wasn't made" read as nothing copied)
    public static let plainSkipped = "; the go-bag copy isn't up to date: "
    /// Days with no good backup before the sidebar and the notice speak up (scheduler/notice.py's USB_DAYS)
    public static let behindDays = 7
    /// Seconds after a press with no sign of the job before the line says it hasn't started
    public static let startWait: TimeInterval = 60

    /// The status file in `requests`; nil when it is missing or not as the job writes it.
    public static func read(in requests: URL) -> DriveBackup? {
        guard let data = try? Data(contentsOf: requests.appendingPathComponent(statusName)) else { return nil }
        return try? JSONDecoder().decode(DriveBackup.self, from: data)
    }

    /// When `python -m scheduler install usb-backup` ran, from jobs/installed.json; nil when it hasn't.
    public static func installedAt(_ installed: Data?) -> Date? {
        guard let installed, let found = try? JSONSerialization.jsonObject(with: installed) as? [String: Any],
              let entry = found[job] as? [String: Any] else { return nil }
        return (entry["at"] as? String).flatMap(parse) ?? .distantFuture  // no time: installed, never behind
    }

    /// The request file's time in nanoseconds, as the job reads it (st_mtime_ns); nil when there is none.
    public static func pressed(_ request: URL) -> Int64? {
        var info = stat()
        guard lstat(request.path, &info) == 0 else { return nil }
        return Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    static func parse(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    /// "3:50 PM", with a plain space (the system's own time style puts a narrow one before PM)
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "h:mm a"
        return format.string(from: date)
    }

    /// Settings' Backups tab's lines: the last good backup, a later try that didn't back up, or what is happening now.
    public static func lines(_ status: DriveBackup?, installed: Date?, pressed: Int64?, now: Date,
                             timeZone: TimeZone = .current) -> [String] {
        guard installed != nil else {
            return ["The USB drive backup isn't set up yet: its job is installed with one Terminal command "
                + "(docs/owner-checks.md, section 8)."]
        }
        var lines: [String] = []
        let good = status?.good.flatMap { good in parse(good.finished).map { (good, $0) } }
        if let (good, at) = good {
            lines.append("Backed up to the USB drive \(BackupWords.ago(at, now: now)): "
                + "\(good.files.formatted()) files, \(StorageWords.size(good.bytes))")
        } else {
            lines.append("Not backed up to the USB drive yet.")
        }
        if let running = status?.running {
            lines.append(running.waiting == true
                ? "Backing up to the USB drive: waiting for another PrepareMe job to finish"
                : "Backing up to the USB drive now"
                    + (parse(running.started).map { " (started \(clock($0, timeZone: timeZone)))" } ?? ""))
        } else if let pressed, pressed > (status?.taken ?? 0) {
            let at = Date(timeIntervalSince1970: TimeInterval(pressed) / 1_000_000_000)
            lines.append(now.timeIntervalSince(at) < startWait
                ? "Back up to the drive now asked; the backup job is starting"
                : "Back up to the drive now asked at \(clock(at, timeZone: timeZone)), but the backup job hasn't started "
                    + "(System Settings › General › Login Items: its switch must be on)")
        } else if let last = status?.last, last.exit != 0, let at = parse(last.finished),
                  good.map({ at > $0.1 }) ?? true {
            lines.append("Tried \(BackupWords.ago(at, now: now)), \(last.summary).")
        } else if let last = status?.last, last.exit == 0, let reason = last.summary.range(of: plainSkipped) {
            lines.append("The go-bag copy on the drive isn't up to date: \(last.summary[reason.upperBound...]).")
        }
        return lines
    }

    /// The sidebar's attention line: installed, and no good backup for `behindDays` (since the install when there is
    /// none); nil otherwise.
    public static func attention(_ status: DriveBackup?, installed: Date?, now: Date) -> String? {
        guard let installed else { return nil }
        let since = status?.good.flatMap { parse($0.finished) } ?? installed
        let days = Int(now.timeIntervalSince(since) / 86400)
        guard days >= behindDays else { return nil }
        return "Not backed up to the USB drive for \(days) days: plug in the drive, or press Back up to the drive now."
    }
}
