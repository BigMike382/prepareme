import Foundation

/// The Mac app's status lines from the jobs' records (plan phase 6), in fixed words and counts only, never a record's
/// own text. Kept here, apart from the app, so `swift test` holds them.
public enum MacStatus {
    /// scheduler/notice.py's SKIP_RUNS: starts in a row before the hourly job's skips are a problem (an hour of starts)
    public static let skipRuns = 4
    /// scheduler/notice.py's SKIP_WHY, word for word (dashboard/tests pins them), and SKIP_WHY_OTHER for any other
    public static let skipWhy = ["uncommitted": "a change to PrepareMe's code on this Mac isn't finished",
                                 "not main": "PrepareMe's folder on this Mac is set to a test version",
                                 "no code check": "the Mac couldn't check PrepareMe's code"]
    public static let skipWhyOther = "it couldn't run"

    /// "Not refreshing: …" when the hourly job's last record (jobs/dashboard.json) has skipped `skipRuns` starts or
    /// more in a row for its code; nil otherwise, or when the record is missing or not as written.
    public static func skippedLine(dashboardRecord data: Data?) -> String? {
        guard let data, let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streak = record["skip_streak"] as? NSNumber, CFGetTypeID(streak) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(streak), streak.intValue >= skipRuns else { return nil }
        let reason = (record["extra"] as? [String: Any])?["skipped"] as? String
        let why = reason.flatMap { skipWhy[$0] } ?? skipWhyOther
        return "Not refreshing: the hourly conditions job has skipped its last \(streak.intValue) starts (\(why))."
    }

    /// The failure notice's open lines (jobs/notice.json's `lines`, scheduler/notice.py: its own fixed words, counts,
    /// dates and guide titles, the one record whose text is shown as written; owner, 2026-10-27, by click), in its order;
    /// none when the file is missing or not as written.
    public static func noticeLines(_ data: Data?) -> [String] {
        guard let data, let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = record["lines"] as? [Any] else { return [] }
        return lines.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    public enum Service: Equatable, Sendable {
        case notChecked, running, needsApproval, notAnswering, otherOnPort
        case notStarted(code: Int)
    }

    public static func serviceLine(_ state: Service) -> String? {
        switch state {
        case .notChecked: return nil
        case .running: return "Devices' service: running"
        case .needsApproval:
            return "Devices' service waits for your OK: System Settings › General › Login Items & Extensions"
        case .notAnswering:
            return "Devices' service isn't answering; devices can't get new files. Quit and reopen PrepareMe; if it "
                + "stays, restart the Mac."
        case .otherOnPort:
            return "Devices' service: another program on this Mac is answering in its place; devices may not get "
                + "new files"
        case let .notStarted(code):
            return "Devices' service couldn't be started (macOS error \(code)); devices can't get new files"
        }
    }

    /// The service's line for the sidebar's attention line: nil while all is well (not checked yet, or running in
    /// PrepareMe), so the bottom of the sidebar stays empty then; otherwise `serviceLine`'s words (Mac sidebar plan,
    /// part 2).
    public static func serviceProblem(_ state: Service) -> String? {
        switch state {
        case .notChecked, .running: return nil
        default: return serviceLine(state)
        }
    }

    /// The Library section's first line once the folder has been read: how many of the files the Mac keeps are the
    /// list's current copies. A file whose newer copy was refused (the Mac keeps the older one) isn't counted current.
    public static func libraryLine(_ record: LibraryRecord, checked: String, now: Date = Date(),
                                   timeZone: TimeZone = .current) -> String {
        let manifest = record.manifest ?? Manifest(writtenAt: "", files: [])
        let wanted = manifest.files.filter {
            LibraryPlan.wanted($0, record, everyKind: true) && !LibraryPlan.idTaken($0, manifest, record)
        }
        let current = wanted.filter { LibraryPlan.isCurrent($0, record) }.count
        if current == wanted.count {
            // "up to date" only meant the copies match, so an old library read as current (beta run 2, B2-20): say what
            // the copies match and when the guides were made (the oldest library date in the list)
            func day(_ entry: Manifest.Entry) -> String? {
                entry.libraryAsOf.flatMap { HomeMacWords.day($0, now: now, timeZone: timeZone) }
            }
            let libraries = wanted.filter { $0.kind == "library" }
            let oldest = libraries.compactMap { entry in
                entry.libraryAsOf.flatMap { HomeMacWords.parse($0, timeZone: timeZone) }.map { ($0, entry) }
            }.min { $0.0 < $1.0 }?.1
            let guides = libraries.first { $0.name == "prepareme-daily.zim"  /* the guides and today's page */ }
            let made: String? = guides.flatMap(day).map { "the guides were made \($0)" }
                ?? oldest.flatMap(day).map { "the oldest library was made \($0)" }
            return "\(current) \(current == 1 ? "file" : "files") the same as the devices' copies"
                + (made.map { "; \($0)" } ?? "") + ", checked \(checked)"
        }
        return "\(current) of \(wanted.count) files current, checked \(checked)"
    }

    /// The last refused copy's line while a refusal still stands: some copy the folder still offers is on record as
    /// refused (`record.refusals`; LibraryPlan.forgetOldRefusals trims it to those, and a copy put in place or Try
    /// again clears its own). Nil once none does, so the sidebar's attention line goes away when the refusal is over,
    /// and Settings' line with it (Task 9.3, F43; until then Settings kept it as history).
    public static func standingRefusal(_ lastRefusal: String?, _ record: LibraryRecord) -> String? {
        record.refusals.isEmpty ? nil : lastRefusal
    }

    /// Settings' Library status line for a refusal: the sidebar's rule (`standingRefusal`), so a refusal over, or one
    /// for a file the folder no longer offers, leaves Settings too (remaining-findings plan, Task 9.3; F43).
    public static func refusalLine(_ lastRefusal: String?, _ record: LibraryRecord) -> String? {
        standingRefusal(lastRefusal, record).map { "Last copy refused by its checks: \($0)" }
    }

    /// The one line at the bottom of the sidebar, only when something matters (spec, "Status: one line, only when it
    /// matters"): the first that isn't nil or empty, in this order. `problem` is the library's problem
    /// (`sync.problem`), `refusal` the last refused copy while it stands (`standingRefusal`), `service` the phones'
    /// service's problem line (`serviceProblem`, nil while it is well), `skipped` the hourly job's skipped starts
    /// (`skippedLine`), `backup` the iCloud backup's (`BackupWords.attention`, concept-doc plan phase A), `drive` the USB
    /// drive backup's (`DriveBackup.attention`, 2026-10-22) and, last (owner, 2026-10-16), `phones` the phones'
    /// inventory problem (`InventoryModel.phoneProblem`). Nil when all are clear.
    public static func attention(problem: String?, refusal: String?, service: String?, skipped: String?,
                                 backup: String? = nil, drive: String? = nil, phones: String?) -> String? {
        attentionLine(problem: problem, refusal: refusal, service: service, skipped: skipped, backup: backup,
                      drive: drive, phones: phones)?.line
    }

    /// Settings' tabs (owner, 2026-10-23; Household added 2026-11-14), in the window's order; the raw values are the
    /// check build's PREPAREME_CHECK_SETTINGS words (`library` is Updates, `phones` is Devices).
    public enum Tab: String, CaseIterable, Sendable { case general, household, players, library, phones, backups, about }

    /// `attention`'s line with the Settings tab it is on, which the warnings box's Open Settings… opens.
    public static func attentionLine(problem: String?, refusal: String?, service: String?, skipped: String?,
                                     backup: String? = nil, drive: String? = nil,
                                     phones: String?) -> (line: String, tab: Tab)? {
        let lines: [(String?, Tab)] = [(problem, .library), (refusal, .library), (service, .phones),
                                       (skipped, .library), (backup, .backups), (drive, .backups), (phones, .phones)]
        return lines.lazy.compactMap { line, tab in line.flatMap { $0.isEmpty ? nil : ($0, tab) } }.first
    }
}
