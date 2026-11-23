// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 6).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import AppKit
import Defaults
import Foundation
import Network
import PrepareMeShared
import ServiceManagement
import SwiftUI

/// The Mac's PrepareMe (build plan phase 6): Kiwix for Mac reading the packer's local folder, with the phones' file
/// service inside it.
///
/// - The library: FolderSync clones each file the folder's list names into the app's own storage (its container's
///   Application Support › PrepareMe › library) and LibraryStore checks it before Kiwix opens it, so a file the packer
///   replaces is never read mid-swap (FINDINGS F-064). It looks at launch, every 30 seconds (PrepareMeRefresh) and when
///   the window comes forward. Nothing opens from Files, a second copy of a library can't sneak in (F-043).
/// - The phones' service: `prepareme-service library --agent` inside the app (Contents/Library/LaunchAgents), registered
///   with SMAppService at each launch, so macOS keeps it running whether the window is open, the app quit or crashed
///   (owner's choice C, 2026-10-13).
/// - The app opens at login (registered once, at its first launch; Settings › General turns it off) and keeps running
///   with its window closed (App_macOS's delegate), so its library stays checked.
/// - The status lines: the library's, the service's (does port 8744 answer here), the hourly job's skips and the iCloud
///   backup's (PrepareMeBackup, concept-doc plan phase A) and the USB drive backup's (DriveBackup, 2026-10-22: the
///   scheduler's usb-backup job copies; the app reads its status and touches its request file), each on its Settings
///   tab (Library, Phones, Backups, with Back up to iCloud now and Back up to the drive now); the window's warnings box
///   shows the first problem among them.
@MainActor
final class PrepareMeMac: ObservableObject {
    static let shared = PrepareMeMac()
    static let serviceAgent = "com.bigmike382.prepareme.service.plist"
    static let loginKey = "openAtLoginRegistered"

    let store: LibraryStore
    let sync: FolderSync
    @Published private(set) var service: MacStatus.Service = .notChecked
    @Published private(set) var skipped: String?
    @Published private(set) var notice: [String] = []  // the hourly failure notice's open lines (jobs/notice.json)
    @Published private(set) var stopDates: Data?  // the hourly check's dates (jobs/dates.json; over-the-air phase 3)
    @Published private(set) var lastSwapped: [String] = []
    @Published private(set) var drive = DriveSeen()
    private var drivePoll: Task<Void, Never>?
    private var reconciled = false
    private var silentChecks = 0  // checks in a row that found PrepareMe's own service registered but not answering
    private var registeredAgain: Date?  // when the service was last registered afresh for that
    private var tail: Task<PrepareMeFolder.Report, Never>?  // checks run one after another, each reporting its own

    /// The container's own Application Support › PrepareMe: the copies and their record, never in the shared folders.
    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrepareMe")
    }

    /// Application Support › PrepareMe under the account's real home (or a session's check folder, PrepareMeHome).
    nonisolated static var folders: URL? {
        PrepareMeHome.url?.appendingPathComponent("Library/Application Support/PrepareMe")
    }

    private init() {
        let zimProblem: @Sendable (URL, Manifest.Entry) -> String? = { file, entry in
            guard let id = UUID(uuidString: entry.id) else { return "the folder's list gives it no ID" }
            return ZimFileService.problem(withFileAt: file, expecting: id)
        }
        store = LibraryStore(root: Self.root, reader: KiwixReader(), zimProblem: zimProblem,
                             lastRefusal: UserDefaults.standard.string(forKey: "lastRefusal"))
        let folder = Self.folders?.appendingPathComponent("delivery") ?? URL(fileURLWithPath: "/nonexistent")
        sync = FolderSync(store: store, folder: folder)
    }

    // MARK: Launch

    /// Once per launch, before the first window's checks: the login item (first launch only) and the service.
    func launch() {
        BrowserViewModel.keepsFoldsAsBuilt = true
        BrowserViewModel.appLink = { url in PrepareMeMacTabs.shared.openAppLink(url) }  // phase 14 (F57)
        PrepareMeOurHome.source = {  // the phones' copy file it writes, so the Mac shows what a phone would (Task 2.4)
            (PrepareMeMac.shared.store.record.held[PrepareMeKeptTabs.dailyFile].flatMap { UUID(uuidString: $0.entry.id) },
             InventoryModel.folder.flatMap(PhoneInventory.read(in:)))
        }
        PrepareMeOurHome.held = { PrepareMeMac.shared.store.record.held }
        PrepareMeMacTabs.shared.watchHome()
        BrowserViewModel.pageFinished = { webView in  // Our Home pages, and the News page's marks (finding 7)
            PrepareMeOurHome.fill(webView)
            PrepareMeNewsMarks.shared.fillAnswers(webView)
        }
        MacLocation.shared.start()  // the hourly job's "where the laptop is" (2026-10-28)
        PrepareMePlayers.shared.launch()  // the devices' copy of the player list (players plan, stage 2)
        guard !PrepareMeHome.isCheck else { return }  // a session's check build registers nothing with macOS
        if !UserDefaults.standard.bool(forKey: Self.loginKey), (try? SMAppService.mainApp.register()) != nil {
            UserDefaults.standard.set(true, forKey: Self.loginKey)  // only once it worked: a failure is tried again
        }
        startService()
    }

    /// Registers the phones' service with macOS. A service already registered is left as it is (registering again would
    /// restart it under a phone's download).
    func startService() {
        guard !PrepareMeHome.isCheck else { return }
        let agent = SMAppService.agent(plistName: Self.serviceAgent)
        guard agent.status != .enabled, agent.status != .requiresApproval else { return }
        do {
            try agent.register()
        } catch {
            service = .notStarted(code: (error as NSError).code)
        }
    }

    // MARK: The check

    /// The library folder looked at (copies made, checked and swapped in), then the status lines. A check asked for
    /// while one runs waits for it, then looks again.
    func check() async -> PrepareMeFolder.Report {
        let previous = tail
        let next = Task { @MainActor in
            _ = await previous?.value
            return await checkNow()
        }
        tail = next
        return await next.value
    }

    /// The record and the copies agree, and Kiwix holds every copy kept, before the first look (once a launch)
    func prepare() async {
        guard !reconciled else { return }
        reconciled = true
        await store.reconcile()
    }

    private func checkNow() async -> PrepareMeFolder.Report {
        await prepare()
        let before = store.record.held.mapValues(\.entry.sha256)
        await sync.check()
        UserDefaults.standard.set(store.lastRefusal, forKey: "lastRefusal")
        let after = store.record.held.mapValues(\.entry.sha256)
        lastSwapped = after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
        await refreshStatus()
        Task { await PrepareMeBackup.shared.check() }  // the iCloud backup (phase A), if one is due; never waited for
        DocumentsModel.shared.relist()  // the adults' phones' list of Essential Documents, current (no key needed)
        var report = PrepareMeFolder.Report()
        report.folders = [sync.problem == nil ? "library folder ok" : "library folder's list can't be read"]
        report.opened = lastSwapped
        report.skipped = store.notes.filter { $0.value != "Checking the new copy…" }
            .map { "\($0.key): \($0.value)" }.sorted()
        return report
    }

    func refreshStatus() async {
        skipped = MacStatus.skippedLine(dashboardRecord: read("jobs/dashboard.json"))
        notice = MacStatus.noticeLines(read("jobs/notice.json"))
        PhonePairing.shared.refresh()  // the phones' room reports, for the warnings box's update lines
        stopDates = read("jobs/\(StopDates.fileName)")
        readDrive()
        let answering = await Self.answers(port: PrepareMeHome.servicePort)
        if PrepareMeHome.isCheck {
            service = answering ? .running : .notAnswering
            return
        }
        let agent = SMAppService.agent(plistName: Self.serviceAgent)
        if agent.status == .notRegistered || agent.status == .notFound {
            startService()  // not registered (say, unregistered while the app ran): registered now
        }
        switch agent.status {
        case .requiresApproval: service = .needsApproval
        case .enabled:
            service = answering ? .running : .notAnswering
            silentChecks = answering ? 0 : silentChecks + 1
            if silentChecks >= 2 { await registerAgain(agent) }
        default:
            if case .notStarted = service { return }  // keep the code from the failed register
            service = answering ? .otherOnPort : .notAnswering  // never "running in PrepareMe" when it isn't ours
        }
    }

    /// PrepareMe's own service registered but silent for two checks (macOS can stop running it after the app is signed
    /// anew, say with Developer ID): registered afresh, at most once an hour. Nothing is being sent while it is silent.
    private func registerAgain(_ agent: SMAppService) async {
        if let last = registeredAgain, Date().timeIntervalSince(last) < 3600 { return }
        registeredAgain = Date()
        silentChecks = 0
        try? await agent.unregister()
        do {
            try agent.register()
        } catch {
            service = .notStarted(code: (error as NSError).code)
        }
    }

    /// The USB drive backup as its job last left it (DriveBackup): its status file, whether the job is installed and
    /// the last press of Back up to the drive now
    struct DriveSeen: Equatable {
        var status: DriveBackup?
        var installed: Date?
        var pressed: Int64?
    }

    func readDrive() {
        guard let requests = Self.folders?.appendingPathComponent("requests") else { return }
        drive = DriveSeen(status: DriveBackup.read(in: requests),
                          installed: DriveBackup.installedAt(read("jobs/installed.json")),
                          pressed: DriveBackup.pressed(requests.appendingPathComponent(DriveBackup.requestName)))
    }

    /// Back up to the drive now: touches the job's request file (launchd starts the job when it changes; the app never
    /// copies or opens the drive itself), then reads the status every 5 seconds for 2 minutes so the line follows.
    func backUpToDrive() {
        guard let requests = Self.folders?.appendingPathComponent("requests") else { return }
        try? PrepareMeRequests.touch(DriveBackup.requestName, in: requests)
        readDrive()
        drivePoll?.cancel()
        drivePoll = Task { [weak self] in
            for _ in 0..<24 {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.readDrive()
            }
        }
    }

    /// A file under the shared Application Support › PrepareMe, or nil
    private func read(_ path: String) -> Data? {
        guard let base = Self.folders else { return nil }
        return try? Data(contentsOf: base.appendingPathComponent(path))
    }

    /// Whether something accepts a connection on 127.0.0.1 at `port` within 3 seconds (the service's TLS isn't
    /// started: a plain connection is enough to know it is listening).
    nonisolated static func answers(port: UInt16) async -> Bool {
        await withCheckedContinuation { done in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = OnceFlag()
            let finish: @Sendable (Bool) -> Void = { answer in
                guard once.take() else { return }
                connection.cancel()
                done.resume(returning: answer)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(false) }
        }
    }

    // MARK: Settings

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        guard !PrepareMeHome.isCheck else { return }  // a session's check build registers nothing with macOS
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }
}

/// True the first time `take` is called, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}

/// Where the shared PrepareMe folders are: under the account's real home, or, in a session's check build only
/// (PREPAREME_CHECK, kiwix-mac/build.sh --app-mac-check), under the scratch folder it was opened with
/// (PREPAREME_CHECK_HOME), with the service looked for on that check's loopback port.
enum PrepareMeHome {
    #if PREPAREME_CHECK
    static let isCheck = true
    static let servicePort: UInt16 = 8799
    static var url: URL? {
        ProcessInfo.processInfo.environment["PREPAREME_CHECK_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    #else
    static let isCheck = false
    static let servicePort: UInt16 = 8744
    static var url: URL? { RealHome.url }
    #endif
}

/// A new tab with no library yet: where the library comes from, never Kiwix's catalog (WelcomeCatalog).
struct PrepareMeWelcome: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("PrepareMe").font(.pmLargeTitle)
            Text("PrepareMe builds the library on this Mac: the guides once a week, the day's conditions through "
                 + "the day. Its settings (PrepareMe › Settings…, then Library) say how far it has got.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding()
    }
}

/// Settings' General tab (owner, 2026-10-23: the PrepareMe tab split in four, Reading folded in): open at login with a
/// way to the Login Items pane, then Reading's page zoom, Kiwix's own words (its Theme stays out: PrepareMe follows the
/// Mac's Light or Dark; look 3, change 5: an outside link always asks and search previews are always on).
struct PrepareMeGeneralSettings: View {
    @ObservedObject private var mac = PrepareMeMac.shared
    @Default(.webViewPageZoom) private var webViewPageZoom

    var body: some View {
        PMForm {
            Section {
                Toggle("Open PrepareMe when you log in", isOn: Binding(get: { mac.opensAtLogin },
                                                                     set: { mac.setOpensAtLogin($0) })).pmSwitch()
                Text("PrepareMe keeps running with its window closed, so its library stays checked. The devices' "
                     + "service runs on its own, whether PrepareMe is open or not.")
                    .font(.pmNote)
                    .foregroundStyle(PrepareMeColors.text2)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.pmAction()
                Text("If Devices says its service waits for your OK, switch PrepareMe on in Login Items.")  // 2026-11-14
                    .font(.pmNote)
                    .foregroundStyle(PrepareMeColors.text2)
            }
            Section(pmTitle: LocalString.reading_settings_tab_reading) {
                LabeledContent(LocalString.reading_settings_zoom_title) {
                    HStack {
                        Stepper(webViewPageZoom.formatted(.percent), value: $webViewPageZoom, in: 0.5...2, step: 0.05)
                        Button(LocalString.reading_settings_zoom_reset_button) { webViewPageZoom = 1 }
                            .disabled(webViewPageZoom == 1)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings' Updates tab (`MacStatus.Tab.library`): the library's lines, each file's note, the last refused copy and the
/// hourly job's skips, then the failure notice's lines under Needs attention (the banner's "Open PrepareMe on the Mac to
/// see what."), then the dates that can stop PrepareMe (moved from Devices, owner 2026-11-14, by click).
struct PrepareMeLibrarySettings: View {
    @ObservedObject private var mac = PrepareMeMac.shared
    @ObservedObject private var sync = PrepareMeMac.shared.sync
    @ObservedObject private var store = PrepareMeMac.shared.store

    var body: some View {
        PMForm {
            Section(pmTitle: "Library status") { PrepareMeStatusLines(lines: lines) }
            if !mac.notice.isEmpty {
                Section(pmTitle: "Needs attention") { PrepareMeStatusLines(lines: mac.notice, kind: .attention) }
            }
            StopDatesSection()
        }
        .formStyle(.grouped)
    }

    private var lines: [String] {
        var lines: [String] = []
        if let problem = sync.problem {
            lines.append(problem)
        } else if let copying = sync.copying {
            lines.append("Copying and checking \(copying.done + 1) of \(copying.total)")
        } else if let looked = sync.lookedAt {
            lines.append(MacStatus.libraryLine(store.record, checked: Self.clock(looked)))
        }
        for (name, note) in store.notes.sorted(by: { $0.key < $1.key }) {
            lines.append(name == "*" ? note : "\(name): \(note)")
        }
        if let refusal = MacStatus.refusalLine(store.lastRefusal, store.record) { lines.append(refusal) }  // F43
        if let skipped = mac.skipped { lines.append(skipped) }
        return lines
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Settings' Devices tab (Phones until 2026-11-14, owner: iPads pair too): Add a device and the paired devices' cards.
/// The devices' service's line sits beside the Paired devices heading; a problem with it, or "Devices' changes are
/// waiting…" when the inventory's ID check couldn't run, is a section of its own, in amber, first (owner, 2026-11-14).
struct PrepareMePhonesSettings: View {
    @ObservedObject private var mac = PrepareMeMac.shared
    @ObservedObject private var inventory = InventoryModel.shared

    var body: some View {
        PMForm {
            let problems = [MacStatus.serviceProblem(mac.service), inventory.phoneProblem].compactMap { $0 }
            if !problems.isEmpty {
                Section(pmTitle: "Devices' status") { PrepareMeStatusLines(lines: problems, kind: .attention) }
            }
            // Add a device and a card for each paired device (plan phase 10's window)
            PrepareMePairingView(status: problems.isEmpty ? MacStatus.serviceLine(mac.service) : nil)
        }
        .formStyle(.grouped)
    }
}

/// Dates that can stop PrepareMe (over-the-air plan, phase 3, layer 5): each device's end, then every date the hourly
/// check reads and the membership renewal the owner types in its own row; amber within 60 days, as the sidebar's
/// warning, or six months for a cable device and the kept installer (the cable clock). On Settings › Updates since 2026-11-14 (owner, by click).
struct StopDatesSection: View {
    @ObservedObject private var mac = PrepareMeMac.shared
    @ObservedObject private var pairing = PhonePairing.shared

    var body: some View {
        let devices = (pairing.phones ?? []).map { phone in
            (name: pairing.name(for: phone).isEmpty ? phone.label : pairing.name(for: phone), report: pairing.rooms[phone.label])
        }
        Section(pmTitle: "Dates that can stop PrepareMe") {
            Text("When one of these dates passes, part of PrepareMe can stop working until it's renewed. Amber means "
                 + "\(StopDates.warnDays) days or fewer are left, or six months for a cable install.")
                .foregroundStyle(PrepareMeColors.text2)
                .fixedSize(horizontal: false, vertical: true)
            // a table, soonest first, undated rows last (owner, 2026-11-14, by click). Rows, not a Grid: a Grid widened
            // the date column for the undated rows' words and cut the names off. What takes the room left and wraps.
            VStack(alignment: .leading, spacing: 6) {
                tableRow(Text("What"), right: HStack {
                    Text("Date")
                    Spacer()
                    Text("Days left")
                })
                .foregroundStyle(PrepareMeColors.text2)
                Divider()
                ForEach(StopDates.soonestFirst(StopDates.rows(devices: devices, renewal: pairing.renewal,
                                                              jobs: mac.stopDates)), id: \.what) { row in
                    let tone = row.caution ? PrepareMeColors.caution : PrepareMeColors.ink
                    if row.what == StopDates.renewalWhat {  // its date box in its row (owner, 2026-11-14)
                        tableRow(Text(row.what), right: HStack {
                            DatePicker("Membership renews on", selection: Binding(get: { pairing.renewal ?? Date() },
                                                                                   set: { pairing.setRenewal($0) }),
                                       displayedComponents: .date)
                                .labelsHidden()
                            Spacer()
                            Text(row.days.map { "\($0)" } ?? row.when).monospacedDigit().foregroundStyle(tone)
                        })
                    } else if let on = row.on, let days = row.days {
                        tableRow(Text(row.what), right: HStack {
                            Text(on.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Text("\(days)").monospacedDigit()
                        }.foregroundStyle(tone))
                    } else {
                        tableRow(Text(row.what), right: Text(row.when)
                            .foregroundStyle(row.caution ? PrepareMeColors.caution : PrepareMeColors.text2))
                    }
                }
            }
            .padding(.vertical, 4)
            if pairing.problem == PhonePairing.renewalProblem {
                Text(PhonePairing.renewalProblem).font(.pmNote).foregroundStyle(PrepareMeColors.red)
            }
        }
    }
}

extension StopDatesSection {
    /// One line of the Dates table: what, then the date and days left in a column of their own width
    private func tableRow(_ what: Text, right: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            what.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            right.fixedSize(horizontal: false, vertical: true).frame(width: 230, alignment: .leading)
        }
    }
}

/// Settings' Backups tab: each backup's lines with its own button under them.
struct PrepareMeBackupSettings: View {
    @ObservedObject private var mac = PrepareMeMac.shared
    @ObservedObject private var backup = PrepareMeBackup.shared

    var body: some View {
        PMForm {
            Section(pmTitle: "iCloud") {
                PrepareMeStatusLines(lines: backup.lines)
                Button("Back up to iCloud now") { Task { await backup.check(now: true) } }  // the iCloud backup (phase A)
                    .pmAction()
            }
            Section(pmTitle: "USB drive") {
                PrepareMeStatusLines(lines: DriveBackup.lines(mac.drive.status, installed: mac.drive.installed,
                                                              pressed: mac.drive.pressed, now: Date()))
                Button("Back up to the drive now") { mac.backUpToDrive() }  // the USB drive backup's job (2026-10-22)
                    .pmAction()
            }
            DocumentsBackupSection()  // Essential Documents' iCloud copy and Test a restore (phase 4)
        }
        .formStyle(.grouped)
    }
}

/// A tab's status lines, in the notes' grey, each as long as it needs.
struct PrepareMeStatusLines: View {
    let lines: [String]
    var kind: PMMessageKind = .info  // problems in amber, as the bar (spec section 10, rule 3)

    var body: some View {
        ForEach(lines, id: \.self) { line in
            Text(line)
                .font(.pmNote)
                .foregroundStyle(kind.color)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Keeps the Settings window on screen. Its tabs differ in height (until 2026-10-23 Reading 200, PrepareMe 620) and macOS keeps the
/// window's top where it was when the tab changes, so PrepareMe opened after Reading ran off the bottom of a laptop's
/// screen (on-screen look, 2026-10-16). Each time the window grows, this moves it up just far enough to show its
/// bottom, never past the menu bar; the pane's own height is unchanged, and its form scrolls on a screen too short.
@MainActor
final class PrepareMeSettingsFit {
    static let shared = PrepareMeSettingsFit()
    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?

    /// The Household, Updates and Devices tabs' height: 620, or less on a screen too short for it (`chrome` covers the title and tab bars)
    static var paneHeight: CGFloat {
        let chrome: CGFloat = 140
        return min(620, max(300, (NSScreen.main?.visibleFrame.height ?? 900) - chrome))
    }

    /// Hands the Settings window to `watch` once the view is in it (Kiwix's withHostingWindow asks once, often before
    /// the view has a window, and then never again)
    struct Finder: NSViewRepresentable {
        final class View: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                PrepareMeSettingsFit.shared.watch(window)
            }
        }

        func makeNSView(context: Context) -> View { View() }
        func updateNSView(_ nsView: View, context: Context) {}
    }

    func watch(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.window = window
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                          queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window { Self.fit(window) }
            }
        }
        Self.fit(window)
    }

    static func fit(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = MacLook.onScreen(window.frame, in: visible)
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }
}

extension Notification.Name {
    /// Settings, asked for from inside the main window (the warnings box's Open Settings…), on the tab its object names
    static let prepareMeSettings = Notification.Name("PrepareMeSettings")
    /// File › Print: the page in the key window prints (Task 13.3; F48)
    static let prepareMePrint = Notification.Name("PrepareMePrint")
    /// Edit › Find's three items (the Apple guidelines plan, phase 2): the page's find bar, or Inventory's search box
    static let prepareMeFind = Notification.Name("PrepareMeFind")
    static let prepareMeFindNext = Notification.Name("PrepareMeFindNext")
    static let prepareMeFindPrevious = Notification.Name("PrepareMeFindPrevious")
}

/// Opens Settings when the main window asks (`prepareMeSettings`, its object the `MacStatus.Tab`; Library if none), as
/// Kiwix's own OpeningSettingsModifier opens its Hotspot tab: `select` picks the tab, which is the App's to hold.
struct PrepareMeOpeningSettings: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    let select: (MacStatus.Tab) -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .prepareMeSettings)) { note in
            select(note.object as? MacStatus.Tab ?? .library)
            openSettings()
        }
    }
}
#endif
