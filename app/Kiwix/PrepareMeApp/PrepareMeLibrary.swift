// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import BackgroundTasks
import CoreData
import Foundation
import PrepareMeShared
import UIKit
import WebKit

/// The phone's copy of the Mac's library (build plan phase 4): when it looks, and the glue between the Mac, the
/// downloader, the store on disk and Kiwix.
///
/// - It looks for something new when the app comes forward, every few minutes while it is open, when iOS gives it a
///   background refresh, and on Check now (owner, 2026-10-13: works whichever way the probe's check (b) comes out);
///   each check the Mac answers fetches the Mac's lists too, for the rally points (beta run 2, B2-01).
/// - It fetches what LibraryPlan says, one file at a time, on a background download that iOS carries on while the app
///   is away (LibraryDownloader).
/// - The copies on disk, their checks, the swap and the record are LibraryStore's (app/Service, tested on the Mac):
///   each copy is checked before use and kept under a name of its own in Application Support › PrepareMe › library
///   (never in Files, never backed up), so nothing ever replaces a file the reader has open (FINDINGS F-064). Front
///   pages of a replaced library reload at once (plan section 9, "Phase 4 must").
@MainActor
final class PrepareMeLibrary: ObservableObject {
    static let shared = PrepareMeLibrary()
    static let refreshTask = AppCopy.id + ".refresh"
    static let whileOpenEvery: TimeInterval = 3 * 60

    let store: LibraryStore
    @Published private(set) var lastProblem: MacLink.Problem?

    /// The last check with the Mac in Home Mac's words (beta run F03): answered (when), not found, removed, failed.
    var checkResult: HomeMacWords.CheckResult {
        switch lastProblem {
        case .none:
            return lastReached.map { .answered($0) } ?? .never
        case .notFound: return .notFound
        case .answered(401): return .removed
        case .some(let problem): return .failed(problem.words)
        }
    }

    /// When the Mac last answered this phone (its record's checkedAt, kept through restarts), or nil if never: Home
    /// Mac says it while the Mac isn't found (phase K's drills, finding 3)
    var lastReached: Date? { store.record.checkedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }
    @Published private(set) var busy = false
    @Published private(set) var progress: [String: Double] = [:]  // a manifest name → share downloaded
    @Published var offered: Manifest.Entry?  // the get-file sheet's file
    /// Phase M: base files this phone holds an older copy of and has no room to update (Today's warning), and the room
    /// files waiting for space, in order (Home Mac), as of the last check
    @Published private(set) var cantUpdate: [Manifest.Entry] = []
    @Published private(set) var waitingForRoom: [Manifest.Entry] = []

    private var timer: Timer?
    private var again = false  // a check asked for while one ran: run once more after it (review, M7)
    private var checkNowAsked = false  // Check now tapped: the next answered run's household look always fetches
    private var base: URL?  // the address the Mac last answered on
    private var roomNoted = Set<String>()  // files last noted as waiting for room: cleared when no longer so
    private var started = false  // this run of the app has opened the front page (owner, 2026-10-13)
    private var searchShown = false  // this run has drawn in Today's search bar (owner, 2026-10-15)
    private var freshTop: (webView: WKWebView, url: URL)?  // Today's front page reopened on its entry, put at its top once
    private var opening = true  // until this run's first reconcile: the held libraries may not be open in the reader
    private var turnedAway = Set<URL>()  // pages a tab asked for meanwhile

    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrepareMe")
    }

    private init() {
        let zimProblem: @Sendable (URL, Manifest.Entry) -> String? = { file, entry in
            guard let id = UUID(uuidString: entry.id) else { return "the Mac's list gives it no ID" }
            return ZimFileService.problem(withFileAt: file, expecting: id)
        }
        store = LibraryStore(root: Self.root, reader: KiwixReader(), zimProblem: zimProblem,
                             lastRefusal: UserDefaults.standard.string(forKey: "lastRefusal"))
        // Plan phase 10, after D7 (owner, 2026-10-15): the library in Files › On My iPhone › PrepareMe for the App
        // Store Kiwix as the backup reader (FilesShelf; links to the held copies, kept out of backups with them, since a
        // link is the same file and carries its flag). The folder itself is backed up, so Kiwix's session and anything
        // saved there stay in backups (review, 2026-10-15); the first build marked it, so the mark is taken off.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        LibraryStore.excludeFromBackup(documents, false)
        store.shelf = documents
        store.wording = .device(ThisDevice.word)  // "this iPad" in its notes on an iPad
    }

    var record: LibraryRecord { store.record }

    // MARK: When it looks

    /// At launch, before the first scene: the background refresh's handler (on the main queue, where its MainActor
    /// closure may run; review, I3) and the reader's two app settings.
    static func launch() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTask, using: .main) { task in
            MainActor.assumeIsolated {
                let work = Task { @MainActor in
                    await PrepareMeLibrary.shared.check()
                    // the inventory look check() starts isn't awaited, so iOS could suspend the app before it sends
                    // what waits: here it is, after any look already under way (offline fixes, task 1.2)
                    let inventory = PhoneInventoryModel.shared
                    while inventory.busy { try? await Task.sleep(for: .milliseconds(250)) }
                    await inventory.look()
                    task.setTaskCompleted(success: true)
                }
                task.expirationHandler = { work.cancel() }
                PrepareMeLibrary.scheduleRefresh()
            }
        }
        BrowserViewModel.keepsFoldsAsBuilt = true
        BrowserViewModel.missingLibrary = { url in PrepareMeLibrary.shared.offer(url) }
        BrowserViewModel.appLink = { url in PrepareMeTabs.openAppLink(url) }
        BrowserViewModel.startPage = { browser in  // Back with every page behind it gone: the tab's first page
            guard let tab = PrepareMeTab.reading.first(where: { PrepareMeTabs.shared.tabID($0) == browser.tabID })
            else { return nil }
            return await PrepareMeTabs.shared.startURL(tab)
        }
        PrepareMeOurHome.source = { (PrepareMeTabs.heldID(PrepareMeTabs.dailyFile), PhoneInventoryModel.shared.shown) }
        PrepareMeOurHome.held = { PrepareMeLibrary.shared.store.record.held }
        PrepareMeOurHome.refill(on: PhoneInventoryModel.shared.objectWillChange)
        BrowserViewModel.callNumbers = {  // both files: the second holds the numbers an older app couldn't take
            guard let id = PrepareMeTabs.heldID(PrepareMeTabs.dailyFile) else { return [] }
            let home = await ZimFileService.shared.getURLContent(zimFileID: id.uuidString, contentPath: CallLinks.homePath)
            let other = await ZimFileService.shared.getURLContent(zimFileID: id.uuidString, contentPath: CallLinks.otherPath)
            return (home.map { CallLinks.homeNumbers($0.data) } ?? []).union(other.map { CallLinks.otherNumbers($0.data) } ?? [])
        }
        BrowserViewModel.pageFinished = { webView in
            LiveConditions.shared.pageFinished(webView)
            StreetMapLinks.pageFinished(webView)  // plan phase 9: "Show on street map" on Find a map's maps
            PrepareMeLibrary.shared.showSearchOnce(webView)
            PrepareMeOurHome.fill(webView)  // Our Home pages' slots (Task 2.4)
            // whose phone this is, so a guide's Walk me through it opens the kids' version on a child's (step 10)
            webView.evaluateJavaScript(WalkthroughRole.script(child: PhoneInventoryModel.shared.isChild))
        }
        LibraryDownloader.shared.reconnect()
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func becameActive() {
        LocalNetworkPermission.ask()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.whileOpenEvery, repeats: true) { _ in
            Task { @MainActor in await PrepareMeLibrary.shared.check() }
        }
        Task {
            await store.reconcile()
            opening = false
            // Today's front page first, at a fresh start: Today's page turned away is not loaded as well, as two loads
            // racing in one tab once left it loading for good (the beta run's F69)
            let frontPageOpened = await openFrontPageOnStart()
            for tab in PrepareMeTab.reading where !(tab == .today && frontPageOpened) {  // each tab's page that was
                let browser = PrepareMeTabs.shared.browser(tab)  // turned away, now its library is open
                if let url = browser.webView.url ?? browser.url, turnedAway.contains(url) {
                    Self.loadAgain(url, in: browser.webView)
                } else if browser.webView.url == nil, browser.url == nil,
                          let start = await PrepareMeTabs.shared.startURL(tab) {
                    // a tab on screen at the start asked for its first page before its library was open, found none
                    // and showed the welcome for good (Guides and Find a map, 2026-11-15; openFirstPageIfEmpty)
                    browser.load(url: start)
                }
            }
            turnedAway = []
            UserDefaults.standard.set(store.lastRefusal, forKey: "lastRefusal")
            if let manifest = record.manifest { weighRoom(manifest) }  // Today's warning away from home too (review)
            await check()
        }
    }

    /// The daily library's front page, once each time the app starts fresh (owner, 2026-10-13: as the Mac's Kiwix
    /// (PrepareMe) opens on the dashboard). Coming back from another app leaves the page in use alone. Whether it
    /// loaded it.
    private func openFrontPageOnStart() async -> Bool {
        guard !started else { return false }
        started = true  // once a run, whatever it finds: a daily that arrives later opens itself (swapped)
        guard let daily = store.record.held.values.first(where: { $0.entry.name == "prepareme-daily.zim" }),
              let id = UUID(uuidString: daily.entry.id),
              let url = await ZimFileService.shared.getMainPageURL(zimFileID: id) else { return false }
        // Straight to the web view: Kiwix's load(url:) skips an address the web view already has, which a page turned
        // away at start leaves it on.
        let webView = PrepareMeTabs.shared.browser(.today).webView
        // loaded behind whatever tab is on screen: the last one, or a link's (task 3.4 ended Today at every start)
        if Self.loadAgain(url, in: webView) { freshTop = (webView, url) }  // at its top once loaded (showSearchOnce)
        return true
    }

    /// A page loaded into a tab at a start: on the tab's own entry when the tab was restored on that page (its load
    /// turned away while the libraries opened), since a plain load of it put a second entry of the same page behind
    /// it, so Back showed the same page again (owner's phone, 2026-10-21; BackSkipTests pins both on a real web view).
    /// Any other page is loaded as before. Whether it went to the entry: WebKit then puts the page back where it was
    /// scrolled, as on Back.
    @discardableResult
    private static func loadAgain(_ url: URL, in webView: WKWebView) -> Bool {
        if let item = webView.backForwardList.currentItem, item.url.updatedToZIMSheme() == url {
            webView.go(to: item)
            return true
        }
        webView.load(URLRequest(url: url))
        return false
    }

    /// Today's search bar, drawn in once a run when Today's first page has loaded, after an install too (owner,
    /// 2026-10-15: as it opened before; it tucks away on scrolling, as UIKit's navigation bar drawer does), unless the
    /// person has scrolled the page or left Today meanwhile.
    /// Today's front page reopened on its own entry at a fresh start comes back where it was scrolled, so once loaded it
    /// is put at its top first (F53: Today opens fresh; FreshStart), where the search bar can be drawn in.
    func showSearchOnce(_ webView: WKWebView) {
        let fresh = freshTop.map { $0.webView === webView && !PagePlace.isNewPage(from: $0.url, to: webView.url) } ?? false
        if freshTop?.webView === webView { freshTop = nil }  // its next page, whichever it is: once only
        let search = !searchShown && webView === PrepareMeTabs.shared.browser(.today).webView
        guard fresh || search else { return }
        if search { searchShown = true }
        Task {
            // WebKit sets the page's zoom as its layout settles, which nudges the page and tucks the search bar away
            // again (seen in the simulator, 2026-10-15): two frames drawn once the page's fonts are in come after it.
            _ = try? await webView.callAsyncJavaScript(
                "await document.fonts.ready; await new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)))",
                in: nil, contentWorld: .defaultClient)
            let scroll = webView.scrollView
            if fresh, !scroll.isTracking, !scroll.isDecelerating {  // the person hasn't taken hold of it meanwhile
                scroll.setContentOffset(
                    CGPoint(x: 0, y: FreshStart.topOffset(inset: scroll.adjustedContentInset.top)), animated: false)
            }
            guard search else { return }
            // No bar over the page (Today's room warning row, phase M): a pull would only leave a gap above it, so a
            // later page tries again once the row has gone
            guard scroll.adjustedContentInset.top > 0 else {
                searchShown = false
                return
            }
            guard PrepareMeTabs.shared.selected == .today, !scroll.isTracking, !scroll.isDecelerating,
                  FreshStart.atTop(offset: scroll.contentOffset.y, inset: scroll.adjustedContentInset.top),
                  let bar = Self.searchBar(over: webView) else { return }
            // Already drawn in, as iOS 27 opens the drawer when a page first loads (the bar 54 points tall, the inset
            // 170 with it): a pull would only leave an empty band of the bar's height above the page (seen in the
            // simulator, 2026-10-18). A tucked-away search bar is 0 points tall.
            guard bar.frame.height == 0 else { return }
            // The search bar is drawn in only when the page is pulled past its top, as a finger would (UIKit's
            // navigation bar drawer), so the page is put there: its top, and the search bar's height above it.
            let fits = bar.sizeThatFits(CGSize(width: webView.bounds.width, height: .greatestFiniteMagnitude)).height
            let height = fits > 0 ? fits : 56  // 56: an iPhone's, measured in the simulator
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top - height), animated: false)
        }
    }

    /// The search bar over a reading tab's page (`.searchable` puts a UISearchController on the navigation item); its
    /// height differs on an iPad and with larger text. Nil when it can't be found, or while the bars are tucked away
    /// (BarTuck), when it is 0 points tall too but a pull would only leave a gap.
    private static func searchBar(over view: UIView) -> UISearchBar? {
        var responder = view.next
        while let next = responder, (next as? UIViewController)?.navigationController == nil { responder = next.next }
        guard let navigation = (responder as? UIViewController)?.navigationController,
              !navigation.isNavigationBarHidden else { return nil }
        return navigation.viewControllers.reversed().lazy.compactMap { $0.navigationItem.searchController?.searchBar }
            .first
    }

    func wentToBackground() {
        timer?.invalidate()
        timer = nil
        Self.scheduleRefresh()
    }

    // MARK: The check

    /// Reads the Mac's manifest and starts the next download it calls for. A check asked for while one runs runs once
    /// more after it. `moment` is `.checkNow` for Home Mac's button, whose household look always fetches.
    func check(_ moment: HouseholdLook.Moment = .libraryCheck) async {
        if moment == .checkNow { checkNowAsked = true }  // kept for the run after this one, if one is under way
        guard !busy else {
            again = true
            return
        }
        busy = true
        defer { busy = false }
        repeat {
            again = false
            let look: HouseholdLook.Moment = checkNowAsked ? .checkNow : .libraryCheck
            checkNowAsked = false
            switch await MacLink.manifest() {
            case let .failure(problem):
                lastProblem = problem
            case let .success((manifest, base)):
                lastProblem = nil
                self.base = base
                store.read(manifest, at: Date())
                if store.recordWasUnreadable { await store.reconcile() }  // adopt the copies back, then tidy
                await store.letGoDropped()  // the Mac's Never and un-ticked files (family downloads plan, phase 3)
                // a download under way stops only when its file is no longer wanted at all, never for room (phase M):
                // its own bytes take the room it was given
                LibraryDownloader.shared.cancelUnless(offered: LibraryPlan.toFetch(manifest, record), base: base)
                startNext(manifest, base: base)
                await reportRoom(manifest)
                // the Mac's lists too, with the rally points, on every phone (beta run 2, B2-01): started, never awaited,
                // so Check now's "Checking…" and the background refresh don't wait on the outbox's sends, the inventory
                // or barcode lookups (checkpoint 1)
                Task { await PhoneInventoryModel.shared.lookIfDue(look) }
                // Essential Documents on an adult's phone (phase 3): asks for the key, sends its changes, mirrors the
                // Mac's store; started, never awaited, like the lists
                Task { await PhoneDocumentsModel.shared.sync(base: base) }
            }
        } while again
    }

    private func startNext(_ manifest: Manifest, base: URL) {
        let downloader = LibraryDownloader.shared
        // a map waiting for the charger never holds up a file that comes at once (offline fixes, phase 5)
        guard !downloader.isRunning || downloader.fetchingWaits, let code = MacLink.pairing else { return }
        // a note from an earlier check goes: the file may no longer need fetching (a list back to the copy held)
        for name in roomNoted { store.note(name, nil) }
        roomNoted = []
        let floor = LibraryPlan.floor(manifest.files)
        for entry in LibraryPlan.toFetch(manifest, record, room: Self.room()) {
            if entry.sha256 == downloader.fetching { return }  // the waiting map is still the next one due
            // a new file keeps the floor (family downloads plan, phase 4), a base file or an update the spare
            let bytes = LibraryPlan.need(entry, record, floor: floor)
            guard Self.availableBytes() >= bytes else {
                let need = StorageWords.size(bytes, rounding: .up)
                store.note(entry.name, "Waiting for room: this file needs \(need) free on this \(ThisDevice.word).")
                roomNoted.insert(entry.name)
                continue
            }
            store.note(entry.name, nil)
            let waits = LibraryPlan.waitsForPower(entry, record)
            if downloader.isRunning {
                guard !waits else { return }  // one waiting map at a time; it carries on
                let paused = downloader.fetching
                downloader.makeWay()
                if let name = manifest.files.first(where: { $0.sha256 == paused })?.name { progress[name] = nil }
            }
            downloader.start(entry, base: base, token: code.token, store: store, waits: waits)
            return
        }
    }

    /// Phase M: this phone's room, for the download rules (LibraryPlan.Room): free space for important use (what iOS can
    /// clear counted) and the device's capacity
    nonisolated static func room() -> LibraryPlan.Room {
        let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return LibraryPlan.Room(free: availableBytes(), capacity: Int64(values?.volumeTotalCapacity ?? 0))
    }

    /// Phase M: what waits for room and which base file can't come or update, kept for the screens, and the phone's room
    /// told to the Mac (Settings › Phones), with when this install stops opening (offline fixes, phase 2), whether
    /// Organic Maps is on it (hand-off plan, 3.2) and its build and channel (over-the-air plan, phase 2);
    /// a report the Mac didn't take goes again at the next check
    func reportRoom(_ manifest: Manifest) async {
        // rounded, and 0 and 0 until this device's owner says yes (Unlisted plan, phase 4, decision 6)
        let room = weighRoom(manifest), shared = PhoneStorage.shared(free: room.free, capacity: room.capacity,
                                                                     allowed: RoomSharing.allowed)
        let report = PhoneStorage(free: shared.free, capacity: shared.capacity, held: record.held.keys.sorted(),
                                  waiting: waitingForRoom.map(\.name), cantUpdate: cantUpdate.map(\.name),
                                  opensUntil: InstallInfo.expiry.map { ISO8601DateFormatter().string(from: $0) },
                                  organicMaps: OrganicMapsCheck.installed, build: InstallInfo.build,
                                  channel: InstallInfo.reported,
                                  update: UpdateSelfCheck.result, opening: OpeningSelfCheck.report)
        if await MacLink.post(report) { OpeningSelfCheck.taken(report.opening) }
    }

    /// The screens' lists from `manifest` and this phone's room now. The file being downloaded is in neither: the free
    /// space it has already taken is its own, not a lack of room (review).
    @discardableResult
    private func weighRoom(_ manifest: Manifest) -> LibraryPlan.Room {
        let room = Self.room()
        let fetching = LibraryDownloader.shared.fetching
        cantUpdate = LibraryPlan.cantUpdate(manifest, record, free: room.free).filter { $0.sha256 != fetching }
        waitingForRoom = LibraryPlan.waitingForRoom(manifest, record, room: room).filter { $0.sha256 != fetching }
        return room
    }

    nonisolated static func availableBytes() -> Int64 {
        #if targetEnvironment(simulator)
        // a session's simulator check only: PREPAREME_CHECK_FREE=<bytes> stands for a nearly full phone (the simulator
        // shares the Mac's disk; family downloads plan, phase 4's pictures)
        if let free = ProcessInfo.processInfo.environment["PREPAREME_CHECK_FREE"].flatMap(Int64.init) { return free }
        #endif
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: The downloader's news

    func downloadProgress(_ name: String, _ share: Double) {
        progress[name] = share
    }

    func downloadFailed(_ entry: Manifest.Entry, _ why: String) {
        progress[entry.name] = nil
        store.note(entry.name, why)
    }

    /// A finished download, already moved to `incoming`: the record names it, the downloader is let go for the next
    /// file, then the copy is checked and swapped in, and the next file starts.
    func downloaded(_ entry: Manifest.Entry) async {
        progress[entry.name] = nil
        store.handOver(entry)
        LibraryDownloader.shared.handedOver(entry)
        let time = BackgroundTime(named: "PrepareMe check")  // the system may pause the check; it carries on later
        await store.checkWaiting()
        time.end()
        UserDefaults.standard.set(store.lastRefusal, forKey: "lastRefusal")
        if let manifest = record.manifest, let code = MacLink.pairing, let base = base ?? MacLink.bases(code).first {
            startNext(manifest, base: base)  // the next file, without waiting for the next check
        }
        if let manifest = record.manifest { weighRoom(manifest) }  // the screens as they are now, not at the last check
    }

    // MARK: The buttons

    /// "Get this file": an optional map (or any file the phone doesn't hold) asked for, then the check.
    func get(_ entry: Manifest.Entry) {
        store.request(entry)
        Task { await check() }
    }

    /// Remove from this phone, from Downloads or Today's room warning: the screens' room weighed again at once, so
    /// Today's warning goes when the room is there (family downloads plan, phase 4), then a check, which at home
    /// starts the update that was waiting
    func remove(_ name: String) async {
        await store.remove(name)
        if let manifest = record.manifest { weighRoom(manifest) }
        await check()
    }

    /// "Try again" on a copy refused twice.
    func tryAgain(_ entry: Manifest.Entry) {
        store.forgetRefusal(entry)
        Task { await check() }
    }

    /// A link into a library this phone doesn't hold: the get-file sheet when the Mac's list has it.
    func offer(_ url: URL) -> Bool {
        guard let id = url.host else { return false }
        // Just after a start (an install, above all), a tab reopens its page before the library it's in is open in
        // the reader: no failure alert for a library this phone holds (2026-10-14: "Unable to load the page requested"
        // once after an install, everything fine after OK). The Today tab opens its page once the libraries are open
        // (openFrontPageOnStart); an empty tab opens its first page. A record still locked from a launch before the
        // first unlock after a restart holds nothing yet, so any page waits for the reconcile that reads it (owner's
        // phone, 2026-10-25: the same alert and a blank Today on the first start after a restart).
        if opening, store.recordLocked
            || record.held.values.contains(where: { $0.entry.id.caseInsensitiveCompare(id) == .orderedSame }) {
            turnedAway.insert(url)  // loaded again once the libraries are open
            return true
        }
        guard let entry = LibraryPlan.missing(id: id, record) else { return false }
        offered = entry
        return true
    }
}

/// A stretch of background time asked of the system, given back once, by `end()` or when the system says it is up.
@MainActor
final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(named name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }  // called on the main thread; given back before it returns
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
