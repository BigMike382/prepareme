// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household's Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import Foundation

/// PrepareMe: while the app runs, checks every library's file every 30 seconds, the same way bringing the window to
/// the front does, so a replaced library shows with no click (the hourly dashboard included). A plain timer rather
/// than file events: iCloud can change a file without one, and a check this size costs next to nothing.
@MainActor
enum PrepareMeRefresh {
    static let interval: Duration = .seconds(30)
    private static var started = false
    private static var showedFrontPage = false

    /// The dashboard's address, once per launch (owner, 2026-10-07: the app opens on it), or nil
    static func frontPageAtLaunch() async -> URL? {
        guard started, !showedFrontPage else { return nil }
        showedFrontPage = true
        #if PREPAREME_APP // the daily library by its name in the folder's list, as the phone app finds it
        guard let daily = PrepareMeMac.shared.store.record.held["prepareme-daily.zim"],
              let id = UUID(uuidString: daily.entry.id) else { return nil }
        return await ZimFileService.shared.getMainPageURL(zimFileID: id)
        #else
        // the daily library, whose front page is the household's dashboard
        return await ZimFileService.shared.getMainPageURL(zimFileID: PrepareMeSearchOrder.dailyID)
        #endif
    }

    /// The first look, which every caller of `start` waits for, so the front page is opened only after it
    private static var first: Task<Void, Never>?

    static func start() async {
        // Kiwix's own tests run inside the app: no folder question or timer there (they'd wait on the question)
        guard !ProcessInfo.processInfo.arguments.contains("testing") else { return }
        if let first { // PrepareMe (plan phase 6): started at launch already; the window waits for the first look
            await first.value
            return
        }
        started = true
        let look = Task { @MainActor in
            #if PREPAREME_APP
            // PrepareMe (plan phase 6): the packer's local folder through PrepareMeMac, never iCloud's folders
            #if PREPAREME_CHECK
            PrepareMeRequests.homeOverride = PrepareMeHome.url // a session's check build: its scratch folder
            #endif
            PrepareMeMac.shared.launch()
            await PrepareMeMac.shared.prepare() // the copies it holds, open: the front page waits for no new copy
            #else
            PrepareMeFolder.prepare()
            await refresh()
            #endif
        }
        first = look
        await look.value
        Task { @MainActor in
            #if PREPAREME_APP
            await refresh() // the first look at the folder, after the front page has opened
            #endif
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await refresh()
            }
        }
    }

    /// A look now, once the checks have started (the window coming forward)
    static func nudge() async {
        guard started else { return }
        await refresh()
    }

    static func refresh() async {
        #if PREPAREME_APP
        let report = await PrepareMeMac.shared.check()
        #else
        let report = await PrepareMeFolder.openAll()
        #endif
        await LibraryOperations.reValidate()
        let reopened = await LibraryOperations.refreshReopened()
        await BrowserViewModel.reloadFrontPages(of: reopened)
        note(report, reopened: reopened.count)
        PrepareMeStatus.shared.update() // the job's answer to the sidebar's buttons
    }

    // MARK: - The record of checks

    private static var lastNoted = Date.distantPast
    private static var lastSkipped: [String] = []

    /// One line in Application Support › PrepareMe › checks.log (inside the app's container) when a check opened,
    /// reopened or skipped something different from last time, and every 10 minutes regardless, so a gap shows when
    /// the checks stopped. Over 1 MB, the file becomes checks.old.log and a new one starts.
    private static func note(_ report: PrepareMeFolder.Report, reopened: Int) {
        let changed = !report.opened.isEmpty || reopened > 0 || report.skipped != lastSkipped
        guard changed || Date.now.timeIntervalSince(lastNoted) >= 600 else { return }
        lastNoted = .now
        lastSkipped = report.skipped
        let clock = ISO8601DateFormatter()
        clock.timeZone = .current
        var line = "\(clock.string(from: .now)) \(report.folders.joined(separator: ", "))"
        if !report.opened.isEmpty { line += "; opened \(report.opened.joined(separator: ", "))" }
        if reopened > 0 { line += "; reopened \(reopened) replaced file(s)" }
        if !report.skipped.isEmpty { line += "; skipped \(report.skipped.joined(separator: "; "))" }
        if !changed { line += "; nothing to do" }
        #if PREPAREME_CHECK
        guard let base = PrepareMeHome.url else { return } // a session's check build: beside its scratch folder
        #else
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        #endif
        let folder = base.appending(path: "PrepareMe")
        let log = folder.appending(path: "checks.log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let size = try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            let old = folder.appending(path: "checks.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: log, to: old)
        }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: log)
        }
    }
}
#endif
