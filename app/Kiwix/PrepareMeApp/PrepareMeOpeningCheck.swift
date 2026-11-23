// This file is part of PrepareMe, a local build of Kiwix for one household's phones (opening self-check, phase 1).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import Foundation
import MetricKit
import PrepareMeShared

/// The opening self-check on a phone or iPad (OpeningCheck; owner, by click, 2026-11-14:
/// docs/plans/2026-11-14-opening-self-check.md). At the first activation of each launch, and at an activation once the
/// last finished check is over 12 hours old, seven quick probes run off the main actor, after the reader has opened the
/// library again. Phase 1 is quiet: nothing waits on them, and the result shows only under Home Mac › This install
/// and on the Mac's Devices card, through the room report. A failed check never keeps a tab from opening.
@MainActor
enum OpeningSelfCheck {
    nonisolated static let reportKey = "PrepareMe.openingReport"
    static let runningKey = "PrepareMe.openingCheckRunning"
    static let finishedKey = "PrepareMe.openingCheckFinished"
    static let again: TimeInterval = 12 * 3600
    nonisolated static let searchWord = "water"  // a fixed word, never one anyone typed
    private static var ranThisLaunch = false
    private static var inFlight = false

    /// The last result and the tally since the Mac last took one; nil before the first check
    static var report: OpeningCheck.Report? { decode(UserDefaults.standard.data(forKey: reportKey)) }

    nonisolated static func decode(_ data: Data?) -> OpeningCheck.Report? {
        data.flatMap { try? JSONDecoder().decode(OpeningCheck.Report.self, from: $0) }
    }

    /// At an activation, once the reader has opened the library again. Never awaited: it returns at once.
    static func opened() {
        let defaults = UserDefaults.standard
        if inFlight {  // back in front while the checks still run: a crash from here on is a stop again
            defaults.set(true, forKey: runningKey)
            return
        }
        let finished = defaults.double(forKey: finishedKey)
        let store = PrepareMeLibrary.shared.store
        // a device never paired, or holding no library yet, has nothing to check and shows nothing
        guard MacLink.pairing != nil, !store.record.held.isEmpty,
              !ranThisLaunch || Date().timeIntervalSince1970 - finished >= again else { return }
        ranThisLaunch = true
        if defaults.bool(forKey: runningKey) {  // the last opening's checks never finished: none run this time
            defaults.set(false, forKey: runningKey)
            keep(OpeningCheck.Result(build: InstallInfo.build ?? "", lines: [], stopped: true))
            return
        }
        defaults.set(true, forKey: runningKey)
        inFlight = true
        let documents = PhoneDocumentsModel.root?.appendingPathComponent("files", isDirectory: true)
        let probes = probes(record: store.record, folder: store.libraryFolder,
                            dailyName: PrepareMeTabs.dailyFile, inventory: PhoneInventoryModel.cacheURL,
                            documents: documents, built: InstallInfo.built)
        let build = InstallInfo.build ?? ""
        Task.detached(priority: .utility) {
            _ = await OpeningCheck.run(probes, build: build, cap: OpeningCheck.cap) { whole in
                Task { @MainActor in
                    UserDefaults.standard.set(false, forKey: runningKey)
                    inFlight = false
                    keep(whole)
                }
            }
        }
    }

    /// Going to the background: a check iOS ends while PrepareMe is away is not a stop (only one that brings the app
    /// down in front is)
    static func wentToBackground() {
        if inFlight { UserDefaults.standard.set(false, forKey: runningKey) }
    }

    /// The Mac took `sent`: its tally is zeroed but for Apple's counts that came since, unless an opening since has
    /// added to it (then it goes again whole: counted twice at worst; the Mac's record is for trends)
    static func taken(_ sent: OpeningCheck.Report?) {
        guard let sent, var now = report, let left = now.tally.left(after: sent.tally) else { return }
        now.tally = left
        save(now)
    }

    /// Phase 4: Apple's crash and hang counts, added to the tally the next room report sends
    static func diagnosed(crashes: Int, hangs: Int) {
        save(OpeningCheck.diagnosed(report, build: InstallInfo.build ?? "", crashes: crashes, hangs: hangs))
    }

    private static func keep(_ result: OpeningCheck.Result) {
        var tally = report?.tally ?? OpeningCheck.Tally()
        tally.add(result)
        save(OpeningCheck.Report(last: result, tally: tally))
        if !result.stopped { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: finishedKey) }
    }

    private static func save(_ report: OpeningCheck.Report) {
        if let data = try? JSONEncoder().encode(report) { UserDefaults.standard.set(data, forKey: reportKey) }
    }

    // MARK: The probes

    /// The daily library opened by the reader and its front page's bytes read, not empty
    @ZimActor static func readFront(_ id: UUID) -> Bool {
        let reader = ZimFileService.shared
        _ = reader.openArchive(zimFileID: id)
        guard let page = reader.getMainPageURL(zimFileID: id), let content = reader.getURLContent(url: page) else {
            return false
        }
        return !content.data.isEmpty
    }

    /// Blocking work on a queue of its own, never Swift's shared threads: a probe abandoned at the limit while stuck in
    /// a read or a search holds none of the threads the rest of the app runs on
    nonisolated static func blocking(_ work: @escaping @Sendable () -> OpeningCheck.State) async -> OpeningCheck.State {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async { done.resume(returning: work()) }
        }
    }

    /// A file's size from a stat, never a read; nil when it isn't there
    nonisolated static func size(_ file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
    }

    /// The probes, from what was read on the main actor; each runs off it, on the check's own threads
    nonisolated static func probes(record: LibraryRecord, folder: URL, dailyName: String, inventory: URL,
                                   documents: URL?, built: Date?) -> [OpeningCheck.Probe] {
        let replacing = Set(record.checking.map(\.name))  // a copy downloaded and not yet checked or swapped in
        let current = record.held.values.filter { !replacing.contains($0.entry.name) }
        let daily = record.held[dailyName]  // found by its name, as Today is, never by the real library's fixed ID
        let dailyID = daily.flatMap { replacing.contains($0.entry.name) ? nil : UUID(uuidString: $0.entry.id) }
        let word = searchWord
        return [
            .init(kind: "daily") {
                guard let dailyID else { return .skipped }
                return await readFront(dailyID) ? .ok : .failed
            },
            .init(kind: "files") {
                guard !current.isEmpty else { return .skipped }
                return await blocking {
                    current.allSatisfy { size(folder.appendingPathComponent($0.file)) == $0.entry.size } ? .ok : .failed
                }
            },
            .init(kind: "search") {
                guard let dailyID else { return .skipped }
                _ = await ZimFileService.shared.openArchive(zimFileID: dailyID)  // as the Guides search does first
                return await blocking {
                    let search = SearchOperation.prepareMe(typed: word, zimFileIDs: [dailyID], spelling: nil)
                    search.main()  // as the Guides search's queue runs it
                    if case let .results(found) = search.searchResultItems, !found.isEmpty { return .ok }
                    return .failed
                }
            },
            .init(kind: "inventory") {
                await blocking {
                    guard let data = try? Data(contentsOf: inventory) else { return .skipped }
                    return (try? JSONDecoder().decode(PhoneInventoryCache.self, from: data)) == nil ? .failed : .ok
                }
            },
            .init(kind: "documents") {  // counted and sized only: no file is opened and no key touched
                guard let documents,
                      let names = try? FileManager.default.contentsOfDirectory(atPath: documents.path),
                      case let sealed = names.filter({ $0.hasSuffix(".pmdoc") }), !sealed.isEmpty else { return .skipped }
                return await blocking {
                    sealed.allSatisfy { (size(documents.appendingPathComponent($0)) ?? 0) > 0 } ? .ok : .failed
                }
            },
            .init(kind: "room") {  // never the maps' reserve: free space under it is normal on a full phone
                guard let size = daily?.entry.size else { return .skipped }
                return LibraryPlan.hasRoom(for: size, available: PrepareMeLibrary.availableBytes()) ? .ok : .failed
            },
            .init(kind: "clock") {
                guard let built else { return .skipped }
                return Date() < built ? .failed : .ok
            },
            .init(kind: "deep") { .skipped },  // phase 3
        ]
    }
}

/// Phase 4 (decision 4a): Apple's crash and freeze reports, counted and nothing else. Each delivery adds its number of
/// crash and hang diagnostics to the opening check's tally; no other field of a report is read, kept, logged or sent,
/// because a report can carry an error message and an error message can carry text from the screen. The older
/// MetricKit form, because the newer one (`MetricManager`) needs iOS 27 and this app opens on iOS 17.6.
/// MetricKit calls in on a background queue, so the class is nonisolated and hands only the two counts to the main
/// actor, where the report is kept.
nonisolated final class OpeningDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {  // no state
    static let shared = OpeningDiagnostics()  // held here: the manager isn't documented to keep it alive

    @MainActor static func start() { MXMetricManager.shared.add(shared) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashes = payloads.reduce(0) { $0 + ($1.crashDiagnostics?.count ?? 0) }
        let hangs = payloads.reduce(0) { $0 + ($1.hangDiagnostics?.count ?? 0) }
        Task { @MainActor in OpeningSelfCheck.diagnosed(crashes: crashes, hangs: hangs) }
    }
}
#endif
