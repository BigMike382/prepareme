// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

import Combine
import CoreKiwix
import Defaults
import SwiftUI
import UserNotifications
#if PREPAREME_APP
import PrepareMeShared  // PrepareMeHelp (Task 13.3)
#endif

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        #if PREPAREME_APP
        return false // PrepareMe (plan phase 6): keeps running with its window closed, so its library stays checked
        #else
        if SessionRestore.shared.isRestoring {
            return false
        }
        return true
        #endif
    }
    func applicationWillTerminate(_ notification: Notification) {
        SessionRestore.shared.saveWindows()
        #if PREPAREME_APP
        // a save no longer writes the phones' copy (its 10-second loop does): one made just before Quit still goes out
        InventoryModel.shared.writePhoneCopy()
        #endif
    }
    #if PREPAREME_APP
    /// A household page's edits not saved ask before quitting (the audit, 2026-10-22, finding 3).
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        HouseholdPagesModel.shared.askBeforeQuit()
    }
    /// PrepareMe (plan phase 6): the checks and the service start at launch, window or not (a login launch may open
    /// none); the first window's own call then waits for the first look
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await PrepareMeRefresh.start() }
        Task { @MainActor in InventoryModel.shared.startPhones() }  // plan phase 7: the phones' inventory edits
        PrepareMeMeaningModel.start()  // meaning search, once its model has loaded (2026-10-28 plan, phase 3)
    }
    /// One main window (Mac sidebar plan, part 2): the Dock's icon brings a minimized one back rather than a second,
    /// and opens a closed one again whatever else is on screen: with Settings, Libraries or Bookmarks open, macOS left
    /// it closed (seen on screen, 2026-10-16)
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let tabs = PrepareMeMacTabs.shared
        if let window = tabs.window, window.isVisible { return true }
        if let open = tabs.openWindowAction {
            tabs.raise(openWindow: open)
            return false
        }
        if !flag, let window = tabs.window, window.isMiniaturized {
            window.deminiaturize(nil)
            return false
        }
        return true
    }
    #endif
}

enum SettingsTab: Int {
    case reading
    case catalog
    case hotspot
    case about
    case diagnostics
    case downloads
}

@main
struct Kiwix: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) var openWindow
    @StateObject private var libraryRefreshViewModel = LibraryViewModel()
    private let notificationCenterDelegate = NotificationCenterDelegate()
    #if !PREPAREME_APP  // Kiwix's donation code isn't in PrepareMe (Unlisted plan, phase 4; audit P2d)
    private var amountSelected = PassthroughSubject<SelectedAmount?, Never>()
    #endif
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isSettingsSearchFocused: Bool
    #if PREPAREME_APP
    @FocusState private var isCatalogSearchFocused: Bool  // the Libraries window's search (fix round 1)
    @FocusedValue(\.streetMapMenu) private var streetMap  // File › Print… prints the household map there (task 5.1)
    @FocusedValue(\.documentsMenu) private var documents  // and the open document there (2026-10-24)
    @FocusedValue(\.macSave) private var macSave  // File › Save, the front screen's (look 3, change 18)
    #endif
    @FocusedValue(\.browserURL) var browserURL
    @StateObject private var colorSchemeStore = UserColorSchemeStore()
    @State private var settingsTab: Int = SettingsTab.reading.rawValue
    #if PREPAREME_APP  // PrepareMe's own five tabs (owner, 2026-10-23), opening on General
    @State private var prepareMeTab: MacStatus.Tab = .general
    #endif
    @ObservedObject private var sessionRestore = SessionRestore.shared

    #if PREPAREME_APP
    static let searchTitle = "Search the Library"
    #else
    static let searchTitle = LocalString.common_search
    #endif

    init() {
        UNUserNotificationCenter.current().delegate = notificationCenterDelegate
        Task {
            await WebContentBlocker.compilePolicy()            
        }
        Task(priority: .utility) {
            await Diagnostics.start()
            #if !PREPAREME_APP // PrepareMe (plan phase 6): the library comes from the packer's folder, never the catalog
            if FeatureFlags.hasLibrary {
                await LibraryViewModel().start(isUserInitiated: false)
            }
            #endif
        }
        #if PREPAREME_APP
        LibraryProcess.shared.state = .complete
        Defaults[.hasSeenCategories] = true
        // look 3 change 5: General no longer offers these two; a Mac that changed them goes back
        Defaults[.externalLinkLoadingPolicy] = .alwaysAsk
        Defaults[.searchResultSnippetMode] = .matches
        // One main window (Mac sidebar plan, part 2): no window tabs, so no tab bar's + and no Show Tab Bar
        NSWindow.allowsAutomaticWindowTabbing = false
        PrepareMeRedNight.shared.start()  // phase D: the red night screen, if this Mac has it on
        #endif
    }
    
    #if PREPAREME_APP
    /// The App's window opener for the Dock's icon (AppDelegate), kept by whichever window opens first: a login launch
    /// may show Settings, Libraries or Bookmarks before the main window ever has (part 2 review, 2026-10-16)
    private func keepWindowOpener() {
        if PrepareMeMacTabs.shared.openWindowAction == nil { PrepareMeMacTabs.shared.openWindowAction = openWindow }
    }
    #endif

    private func selectHotspotTab() {
        settingsTab = SettingsTab.hotspot.rawValue
    }

    var body: some Scene {
        WindowGroup(id: "rootView", for: WindowState.self) { (windowState: Binding<WindowState?>) in
            RootView(isSearchFocused: $isSearchFocused, openedWithWindowState: windowState.wrappedValue)
                .environment(\.managedObjectContext, Database.shared.viewContext)
                .environmentObject(libraryRefreshViewModel)
                .task { colorSchemeStore.update() }
                .modifier(OpeningSettingsModifier(updateTabSelection: selectHotspotTab))
                #if PREPAREME_APP // the warnings box opens Settings on its first line's tab (owner, 2026-10-23)
                .modifier(PrepareMeOpeningSettings { prepareMeTab = $0 })
                #endif
        }.commands {
            SidebarCommands()
            CommandGroup(replacing: .importExport) {
                #if !PREPAREME_APP // PrepareMe opens nothing from Files (plan phase 6; FINDINGS F-043)
                OpenFileButton(context: .command) { Text(LocalString.app_macos_commands_open_file) }
                #endif
            }
            CommandGroup(replacing: .newItem) {
                #if PREPAREME_APP
                // PrepareMe (Mac sidebar plan, part 2): one main window, so no New Tab (⌘T) or New Window. File starts
                // with what the Library menu held until the menu bar plan (owner, 2026-11-14): Kiwix's catalog, in its
                // own window (owner, 2026-11-12: was Get More Libraries…), and the household pages' editor (out of the
                // sidebar and the Window menu, owner 2026-10-26; to File by the owner's click, 2026-11-14)
                Button("Add to Library…") { openWindow(id: "catalog") }
                Button("Edit Our Home") {
                    PrepareMeMacTabs.shared.showFromMenu(.householdPages, openWindow: openWindow)
                }
                #else
                Button(LocalString.app_macos_commands_new) {
                    guard let currentWindow = NSApp.keyWindow,
                          let controller = currentWindow.windowController else { return }
                    controller.newWindowForTab(nil)
                    guard let newWindow = NSApp.keyWindow, currentWindow != newWindow else { return }
                    currentWindow.addTabbedWindow(newWindow, ordered: .above)
                }.keyboardShortcut("t")
                Divider()
                #endif
            }
            CommandGroup(after: .toolbar) {
                #if !PREPAREME_APP  // PrepareMe's Back and Forward are in Go (menu bar plan, owner 2026-11-14)
                NavigationCommands(goBack: {
                    NotificationCenter.default.post(name: .goBack, object: nil)
                }, goForward: {
                    NotificationCenter.default.post(name: .goForward, object: nil)
                })
                Divider()
                #endif
                PageZoomCommands()
                Divider()
                #if PREPAREME_APP
                RedNightSwitch()  // phase D
                Divider()
                // Conditions, out of the Library menu (menu bar plan, owner 2026-11-14): a refresh, beside the view's
                // other switches; Today's toolbar has the same two
                Button("Keep Conditions Fresh for 6 Hours") { PrepareMeRequests.pressFromMenu(.refresh) }  // look 3, change 21 (owner, 2026-11-11)
                Button("Check Conditions Once") { PrepareMeRequests.pressFromMenu(.checkOnce) }
                Divider()
                #endif
                #if !PREPAREME_APP
                // PrepareMe (Mac sidebar plan, part 2): no Kiwix sidebar rows to pick, and no earlier windows to open
                // again beside the one main window
                SidebarNavigationCommands()
                Divider()
                Button(LocalString.app_macos_navigation_button_restore_previous_session) {
                    sessionRestore.restore(using: { windowState in
                        openWindow(id: "rootView", value: windowState)
                    })
                }
                .disabled(sessionRestore.canRestore == false)
                Divider()
                #endif
            }
            #if !PREPAREME_APP  // look 3, change 3: no Edit › Copy URL in PrepareMe
            CommandGroup(after: .pasteboard) {
                Button(LocalString.library_zim_file_context_copy_url) {
                    if let browserURL {
                        CopyPaste.copyToPasteBoard(url: browserURL)
                    }
                }
                .disabled(browserURL == nil)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                    
            }
            #endif
            CommandGroup(after: .textEditing) {
                #if PREPAREME_APP
                // Edit › Find (the Apple guidelines plan, phase 2): ⌘F finds in the page shown, or in Inventory's search
                // box; ⌘G and ⇧⌘G step through the page's matches. The page's find bar and Inventory listen for these.
                Menu("Find") {
                    Button("Find…") { NotificationCenter.default.post(name: .prepareMeFind, object: nil) }
                        .keyboardShortcut("f", modifiers: .command)
                    Button("Find Next") { NotificationCenter.default.post(name: .prepareMeFindNext, object: nil) }
                        .keyboardShortcut("g", modifiers: .command)
                    Button("Find Previous") { NotificationCenter.default.post(name: .prepareMeFindPrevious, object: nil) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
                #endif
                // PrepareMe: ⌘F finds in the page, as in Safari (owner, 2026-10-18, by click: Task 13.5, F50); this
                // searches the library, or the Libraries window's or Settings' list, on ⇧⌘F
                Button(Self.searchTitle) {
                    // make sure we pick up the right window to search in
                    let keyWindowId = NSApplication.shared.keyWindow?.identifier?.rawValue.lowercased()
                    if keyWindowId?.contains("settings") == true, settingsTab == SettingsTab.catalog.rawValue {
                        isSettingsSearchFocused = true
                    } else {
                        #if PREPAREME_APP
                        if let key = NSApp.keyWindow, key === PrepareMeCatalogWindow.window
                            || keyWindowId?.contains("catalog") == true {
                            isCatalogSearchFocused = true  // File › Get More Libraries…'s window (fix round 1)
                            PrepareMeCatalogWindow.focusSearch(in: key)  // what reaches its field (2026-10-16)
                            return
                        }
                        #endif
                        isSearchFocused = true
                    }
                }
                #if PREPAREME_APP
                .keyboardShortcut("f", modifiers: [.command, .shift])
                #else
                .keyboardShortcut("f", modifiers: [.command])
                #endif
            }
            #if PREPAREME_APP
            // File › Save (look 3, change 18): the front screen's save, Printable References' card or the household
            // page; after the system's group, so Close stays and comes first, as in Apple's File menu (review)
            CommandGroup(after: .saveItem) {
                Button("Save") { macSave?.run() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(macSave?.enabled != true)
                Divider()  // the backups, out of the Library menu (menu bar plan, owner 2026-11-14)
                Button("Back Up to iCloud Now") { Task { await PrepareMeBackup.shared.check(now: true) } }  // the iCloud backup
                Button("Back Up to the Drive Now") { PrepareMeMac.shared.backUpToDrive() }  // the USB drive's job
            }
            // File › Print, for the page shown (Task 13.3; F48: File had no Print)
            CommandGroup(replacing: .printItem) {
                Button("Page Setup…") { NSApp.runPageLayout(nil) }  // kept: replacing the group had taken it (review)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                // the page shown, or the household map while the street map shows (task 5.1); not Inventory (review)
                Button("Print…") {
                    if let streetMap { streetMap.print() }
                    else if let picked = documents?.picked { documents?.model.send(picked, .print) }
                    else { NotificationCenter.default.post(name: .prepareMePrint, object: nil) }
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(streetMap.map { !$0.browsing || !$0.canPrint }
                          ?? documents.map { !$0.canZoom } ?? (browserURL == nil))
            }
            // File › Import from iPhone or iPad: Continuity Camera's Scan Documents and Take Photo, taken by Essential
            // Documents while it's open (2026-10-24)
            ImportFromDevicesCommands()
            // Help › PrepareMe Help: the help page in the library (Task 13.3; F48, the owner's words)
            CommandGroup(replacing: .help) {
                Button(PrepareMeHelp.menuTitle) { PrepareMeMacTabs.shared.showHelp(openWindow: openWindow) }
                .keyboardShortcut("?", modifiers: .command)
            }
            #else
            CommandGroup(replacing: .help) {}
            #endif
            #if PREPAREME_APP
            // Go (menu bar plan, owner 2026-11-14): Back and Forward out of View, then every sidebar row, ⌘1 to ⌘9,
            // which Window listed five of until then; each item brings its place forward
            CommandMenu("Go") {
                NavigationCommands(goBack: {
                    NotificationCenter.default.post(name: .goBack, object: nil)
                }, goForward: {
                    NotificationCenter.default.post(name: .goForward, object: nil)
                })
                Divider()
                PrepareMeGoRows(openWindow: openWindow)
            }
            InventoryMenu()
            DocumentsMenu()  // Essential Documents (2026-10-24)
            StreetMapMenu()  // street map fixes plan, task 5.1
            ListColumnCommands()  // View › Hide List (the Apple guidelines plan, phase 7)
            CommandMenu("Bookmarks") {  // the Mac sidebar plan, part 2: Bookmarks out of the sidebar
                PrepareMeBookmarkCommands(openWindow: openWindow)
            }
            // Window holds only windows: its list of screens is the Go menu, and Settings… (⌘,) › Devices is the
            // devices' one way in (menu bar plan, owner 2026-11-14)
            #endif
        }

        Settings {
            #if PREPAREME_APP
            // PrepareMe's tabs (owner, 2026-10-23; Household added 2026-11-14): Reading folded into General,
            // Diagnostics into About. Every tab 760 wide (Mac sidebar plan, part 2): switching tabs changes the window's
            // height but not its width, so opened on Reading at 550 the PrepareMe tab was cut off on both sides (owner,
            // 2026-10-16, a screenshot)
            TabView(selection: $prepareMeTab) {
                PrepareMeGeneralSettings()
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(MacStatus.Tab.general)
                    .frame(height: 410)
                PrepareMeHouseholdSettings()  // owner, 2026-11-14, by click: was Inventory's Settings row
                    .tabItem { Label("Household", systemImage: "person.2") }
                    .tag(MacStatus.Tab.household)
                    .frame(height: PrepareMeSettingsFit.paneHeight)
                PrepareMePlayersSettings()  // players plan, stage 2: only the Mac makes players (choice A8)
                    .tabItem { Label("Players", systemImage: "person.crop.circle") }
                    .tag(MacStatus.Tab.players)
                    .frame(height: min(520, PrepareMeSettingsFit.paneHeight))
                PrepareMeLibrarySettings()
                    .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }  // owner, 2026-11-12: was Library
                    .tag(MacStatus.Tab.library)
                    .frame(height: PrepareMeSettingsFit.paneHeight)  // the dates table moved here (owner, 2026-11-14)
                PrepareMePhonesSettings()
                    .tabItem { Label("Devices", systemImage: "ipad.and.iphone") }
                    .tag(MacStatus.Tab.phones)
                    .frame(height: PrepareMeSettingsFit.paneHeight)
                PrepareMeBackupSettings()
                    .tabItem { Label("Backups", systemImage: "externaldrive") }
                    .tag(MacStatus.Tab.backups)
                    .frame(height: min(560, PrepareMeSettingsFit.paneHeight))  // all three backups in sight (2026-11-14)
                About()
                    .environment(\.managedObjectContext, Database.shared.viewContext)  // its diagnostic report
                    .tag(MacStatus.Tab.about)
                    .frame(height: min(560, PrepareMeSettingsFit.paneHeight))  // its licenses and report folded (2026-11-14)
            }
            .pmMacWindow()
            .pmMacBand()  // look 3: the picked pane in the band (plan Task 6.2)
            .onAppear { keepWindowOpener() }  // the Dock's icon, after a login launch with no main window
            .frame(width: 760)
            .background(PrepareMeSettingsFit.Finder())  // a taller tab never runs off the screen
            #else
            TabView(selection: $settingsTab) {
                ReadingSettings()
                    .environmentObject(colorSchemeStore)
                    .tag(SettingsTab.reading.rawValue)
                    .frame(height: 200)
                if FeatureFlags.hasLibrary {
                    LibrarySettings(isSearchFocused: _isSettingsSearchFocused)
                        .environmentObject(libraryRefreshViewModel)
                        .tag(SettingsTab.catalog.rawValue)
                        .frame(height: 800)
                }
//                enable as part of: https://github.com/kiwix/kiwix-apple/issues/1549
//                DownloadsMacOsSettings()
//                    .tag(SettingsTab.downloads.rawValue)
                HotspotSettings()
                    .tag(SettingsTab.hotspot.rawValue)
                    .frame(height: 140)
                About()
                    .tag(SettingsTab.about.rawValue)
                    .frame(height: 480)
                if FeatureFlags.hasLibrary {
                    DiagnosticsView()
                        .environment(\.managedObjectContext, Database.shared.viewContext)
                        .tag(SettingsTab.diagnostics.rawValue)
                        .frame(height: 220)
                }
            }
            .frame(width: 550)
            #endif
        }
        .handlesExternalEvents(matching: [])
        // PrepareMe (Mac sidebar plan, part 2): no Inventory, Street map or Phones windows; the first two are the main
        // window's rows, Phones is Settings' Phones tab
        #if PREPAREME_APP
        // File › Get More Libraries… and Bookmarks › Show Bookmarks, each one window that the menu brings forward
        Window("Add to Library", id: "catalog") {
            PrepareMeCatalogWindow(library: libraryRefreshViewModel, isSearchFocused: $isCatalogSearchFocused)
                .pmMacBand()  // look 3 (plan Task 6.1)
                .onAppear { keepWindowOpener() }
        }
        .commandsRemoved()
        .defaultSize(width: 1100, height: 700)
        .handlesExternalEvents(matching: [])

        Window("Bookmarks", id: "bookmarks") {
            PrepareMeBookmarksWindow()
                .pmMacBand()  // look 3 (plan Task 6.1)
                .onAppear { keepWindowOpener() }
        }
        .commandsRemoved()
        .defaultSize(width: 560, height: 600)
        .handlesExternalEvents(matching: [])
        #endif

        #if !PREPAREME_APP // Kiwix's donation code isn't in PrepareMe (Unlisted plan, phase 4; audit P2d)
        Window(LocalString.payment_donate_title, id: "donation") {
            NavigationStack {
                DonationForm()
                    .onReceive(NotificationCenter.default.publisher(for: .donationResult)) { notification in
                        guard let finalResult = notification.userInfo?["result"] as? Payment.FinalResult else {
                            return
                        }
                        switch finalResult {
                        case .thankYou:
                            openWindow(id: "donation-thank-you")
                        case .error:
                            openWindow(id: "donation-error")
                        case .errorAlreadyHasSubscription:
                            openWindow(id: "donation-error-already-has-subscription")
                        }
                    }
            }
            .frame(minWidth: 438, minHeight: 440)
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()
        .defaultSize(width: 438, height: 440)
        .restorationBehaviourDisabled()
        .handlesExternalEvents(matching: [])

        Window("", id: "donation-thank-you") {
            PaymentResultPopUp(state: .thankYou)
                .padding()
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()
        .defaultSize(width: 320, height: 198)
        .restorationBehaviourDisabled()
        .handlesExternalEvents(matching: [])

        Window("", id: "donation-error") {
            PaymentResultPopUp(state: .error)
                .padding()
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()
        .defaultSize(width: 320, height: 198)
        .restorationBehaviourDisabled()
        .handlesExternalEvents(matching: [])
        
        Window("", id: "donation-error-already-has-subscription") {
            PaymentResultPopUp(state: .errorAlreadyHasSubscription)
                .padding()
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()
        .defaultSize(width: 320, height: 198)
        .restorationBehaviourDisabled()
        .handlesExternalEvents(matching: [])
        #endif
    }
}

#endif
