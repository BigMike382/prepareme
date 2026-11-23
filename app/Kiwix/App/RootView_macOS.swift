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

#if os(macOS)
import SwiftUI
#if !PREPAREME_APP // Kiwix's donation code isn't in PrepareMe (Unlisted plan, phase 4; audit P2d)
import PassKit
#endif
import Defaults
#if PREPAREME_APP
import PrepareMeShared // MacRow (Mac sidebar plan, part 2)
#endif

// swiftlint:disable:next type_body_length
struct RootView: View {
    @Environment(\.openWindow) var openWindow
    @Environment(\.controlActiveState) var controlActiveState
    @StateObject private var navigation = NavigationViewModel()
    @SceneStorage("org.kiwix.macos.root.menuitem") private var currentNavItem: MenuItem?
    @StateObject private var windowTracker = WindowTracker()
    #if !PREPAREME_APP
    @State private var paymentButtonLabel: PaymentButtonType?
    #endif
    var isSearchFocused: FocusState<Bool>.Binding
    @StateObject private var selection = SelectedZimFileViewModel()
    // Open file alerts
    @State private var isOpenFileAlertPresented = false
    @State private var openFileAlert: OpenFileAlert?
    #if !PREPAREME_APP // PrepareMe: the catalog's language is its own window's (PrepareMeCatalogWindow)
    @State private var selectedLanguage: String = Defaults[.libraryLanguageCodes].first ?? "eng"
    @Default(.libraryLanguageCodes) private var languages
    #endif
    let openedWithWindowState: WindowState?
    #if PREPAREME_APP
    @ObservedObject private var macTabs = PrepareMeMacTabs.shared  // the sidebar's rows (Mac sidebar plan, part 2)
    @AppStorage(PrepareMeMacTabs.mapsPaneKey) private var mapsPane = MapsPane.find.rawValue  // Maps' side on screen
    @ObservedObject private var play = PrepareMeGamePlay.shared  // a game page on screen: full window (games 3b)
    @State private var columnsBeforePlay = NavigationSplitViewVisibility.automatic
    #endif
    @State private var columns = NavigationSplitViewVisibility.automatic  // PrepareMe: the sidebar hides for a game
    
    #if !PREPAREME_APP // PrepareMe's rows are its own (PrepareMeMacSidebar); its catalog is File › Get More Libraries…
    private let primaryItems: [MenuItem] = [.bookmarks]
    // No Hotspot. Kiwix (PrepareMe) shows only what works offline (owner, 2026-10-07): no Categories, Downloads or New.
    private let libraryItems: [MenuItem] = [.opened]
    #endif
    private let openURL = NotificationCenter.default.publisher(for: .openURL)
    private let appTerminates = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
    private let tabCloses = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
    private let goBackPublisher = NotificationCenter.default.publisher(for: .goBack)
    private let goForwardPublisher = NotificationCenter.default.publisher(for: .goForward)
    /// Close other tabs then the ones received
    private let keepOnlyTabs = NotificationCenter.default.publisher(for: .keepOnlyTabs)
    // in essence it's the "zim://" value
    private static let zimURL: String = "\(KiwixURLSchemeHandler.ZIMScheme)://"
    #if PREPAREME_APP
    /// PrepareMe (part 2 review, 5): the sidebar in the window's text style, and the detail wide enough for the street map's list
    /// and map (240 + 360) and Inventory's table and home page (360 at least), so the main window never squeezes their columns. 250 fits a
    /// sub-category's name of 20 characters (packer's TOPIC_NAME_LIMIT) on one line (owner, 2026-10-16).
    private static let sidebarMinWidth: CGFloat = 250
    private static let detailMinWidth: CGFloat = 600
    #endif

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            #if PREPAREME_APP
            // PrepareMe (Mac sidebar plan, part 2): the iPhone's places as rows (PrepareMeMacSidebar), not Kiwix's tab,
            // bookmarks and library rows; a row is picked at once and its page loads after
            List(selection: Binding<MacRow?>(get: { macTabs.sidebarRow }, set: { picked in
                if let picked { macTabs.pick(picked) }  // a new row shows; the row already picked, picked again (part 2)
            })) {
                PrepareMeMacEventMode()  // first, never at the bottom (the Apple guidelines plan, phase 3)
                PrepareMeMacSidebar()
            }
            .font(.pmBody)  // the whole sidebar in the window's text style
            .pmMacSidebar()  // look 3: the band, its lines and the wordmark (plan Task 6.1)
            .safeAreaInset(edge: .bottom, spacing: 0) { PrepareMeAttentionBar() }  // the warnings, folded (owner, 2026-11-13)
            .frame(minWidth: Self.sidebarMinWidth)  // no donation button: PrepareMe's Info.plist hides it
            #else
            List(selection: $currentNavItem) {
                ForEach(
                    [MenuItem.tab(objectID: navigation.currentTabId)] + primaryItems,
                    id: \.self
                ) { menuItem in
                    Label(menuItem.name, systemImage: menuItem.icon)
                }
                if FeatureFlags.hasLibrary {
                    Section {
                        ForEach(libraryItems, id: \.self) { menuItem in // PrepareMe: no Hotspot
                            Label(menuItem.name, systemImage: menuItem.icon)
                        }
                    } header: {
                        Text(LocalString.app_macos_navigation_button_library)
                    }
                    PrepareMeRequestsSection() // PrepareMe: the two buttons and the status line
                } else {
                    Label(MenuItem.hotspot.name, systemImage: MenuItem.hotspot.icon).id(MenuItem.hotspot)
                }
            }
            .frame(minWidth: 160)
            .safeAreaInset(edge: .bottom) {
                if paymentButtonLabel != nil && Brand.hideDonation != true {
                    SupportKiwixButton {
                        openWindow(id: "donation")
                    }
                }
            }
            #endif
        } detail: {
            Group {
            #if PREPAREME_APP
            // PrepareMe (Mac sidebar plan, part 2): a reading row's own kept tab, Maps with its Street map side beside
            // it; Inventory its editor, its window gone. A reading tab waits for the launch to open the library's
            // copies, as Kiwix's own `.loading` did (blank-page fix, 2026-10-16): a tab restored sooner asks for its
            // page before the file is open, which is refused, and the page stays blank behind a failure alert.
            if macTabs.row.reader != nil, !macTabs.copiesOpen {
                LoadingDataView()
            } else if macTabs.row == .maps {
                PrepareMeMacMaps {
                    PrepareMeMacReader(reader: .maps)
                        .id(macTabs.tabID(.maps))  // its tab's ID: a tab Kiwix deleted and made again is a new view
                        .modifier(SearchFocused(isSearchFocused: isSearchFocused))
                }
            } else if let reader = macTabs.row.reader {
                PrepareMeMacReader(reader: reader)
                    .id(macTabs.tabID(reader))
                    .modifier(SearchFocused(isSearchFocused: isSearchFocused))
            } else if let rows = PrepareMeMacLibrary.rows(macTabs.row) {
                PrepareMeMacLibrary(rows: rows)  // the Library's lists (owner, 2026-11-12)
                    .id(rows)  // each list opens at its top, or its subcategory's heading (phase 4 review)
                    .pmMacWindow()
                    .navigationTitle(PrepareMeMacLibrary.title(macTabs.row))
            } else if [.householdPages, .documents, .printableReferences].contains(macTabs.row) {
                Group {
                    switch macTabs.row {
                    case .householdPages: PrepareMeHouseholdPagesView()  // concept-doc plan, phase C
                    case .documents: PrepareMeDocumentsView()  // Essential Documents (2026-10-24)
                    default: PrepareMePrintableReferencesView()  // the card and the binder (2026-10-21)
                    }
                }
                .pmMacWindow()
                .navigationTitle(MacSidebar.title(macTabs.row) ?? "")  // its name in the band (look 3, Task 6.1)
            } else {
                PrepareMeInventoryView(row: macTabs.row).pmMacWindow()  // Inventory or a row under it (phase 3)
            }
            #else
            switch navigation.currentItem {
            case .loading:
                LoadingDataView()
            case .tab(let tabID):
                BrowserTab(tabID: tabID)
                    .modifier(SearchFocused(isSearchFocused: isSearchFocused))
            case .bookmarks:
                Bookmarks()
                    .modifier(SearchFocused(isSearchFocused: isSearchFocused))
            case .opened:
                ZimFilesMultiOpened()
            case .categories:
                DetailSidePanel(content: {
                    ZimFilesCategories(languageCode: $selectedLanguage, dismiss: nil)
                        .toolbar {
                            if $languages.count > 1 {
                                ToolbarItem(placement: .secondaryAction) {
                                    ToggleAroundLanguageButton(items: $languages, selection: $selectedLanguage)
                                }
                            }
                        }
                })
                    .modifier(SearchFocused(isSearchFocused: isSearchFocused))
            case .downloads:
                DetailSidePanel(content: { ZimFilesDownloads(dismiss: nil) })
            case .new:
                DetailSidePanel(content: { ZimFilesNew(dismiss: nil) })
                    .modifier(SearchFocused(isSearchFocused: isSearchFocused))
            case .hotspot:
                HotspotZimFilesSelection()
            default:
                EmptyView()
            }
            #endif
            }
            #if PREPAREME_APP
            .modifier(LibrarySetupOnce())  // the Library's first-launch sheet (owner, 2026-11-12)
            .modifier(LibraryEditSheets())  // its Which category?, Rename… and Remove… (Library plan, phase 3)
            .pmTint()  // look 3: PrepareMe's teal (it had been the ink, A9), the detail only, so the sidebar's
                       // selected row keeps the Mac's own highlight (owner, 2026-10-15), on the band since phase 6
            .pmMacBand()  // the window's top as the band, its title and buttons on it (plan Task 6.1)
            .frame(minWidth: Self.detailMinWidth)  // the street map's and Inventory's two columns (part 2 review, 5)
            .overlay(alignment: .topLeading) { if play.playing { PrepareMeGameDone().padding(8) } }  // games 3b
            #endif
        }
        #if !PREPAREME_APP
        .onChange(of: languages) {
            if languages.count == 1 {
                selectedLanguage = languages.first!
            }
        }
        #endif
        #if PREPAREME_APP
        .frame(minWidth: Self.sidebarMinWidth + Self.detailMinWidth + 10, minHeight: 500)  // with the sidebar showing
        // full-screen play (games 3b): a game page takes the whole window, the sidebar and toolbar back as they were
        .toolbar(play.playing ? .hidden : .automatic, for: .windowToolbar)
        .onChange(of: play.playing) { _, playing in
            if playing { columnsBeforePlay = columns }
            columns = playing ? .detailOnly : columnsBeforePlay
        }
        #if PREPAREME_CHECK
        // PREPAREME_CHECK_SIDEBAR=show: the sidebar open whatever the check build last saved (phase 3's captures)
        .task {
            if ProcessInfo.processInfo.environment["PREPAREME_CHECK_SIDEBAR"] == "show" {
                try? await Task.sleep(for: .seconds(1))
                columns = .all
            }
        }
        #endif
        #else
        .frame(minWidth: 650, minHeight: 500)
        #endif
        .focusedSceneValue(\.navigationItem, $navigation.currentItem)
        .modifier(AlertHandler())
        .modifier(QuestionHandler())
        .modifier(OpenFileHandler())
        .modifier(SaveContentHandler())
        .environmentObject(navigation)
        .onChange(of: currentNavItem) { _, newValue in
            navigation.currentItem = newValue?.navigationItem
            saveSelectionInSession()
        }
        .onChange(of: navigation.currentItem) { _, newValue in
            guard let newValue else { return }
            let navItem = MenuItem(from: newValue)
            if currentNavItem != navItem {
                currentNavItem = navItem
            }
        }
        #if PREPAREME_APP
        .onChange(of: macTabs.row, initial: true) { _, _ in
            // PrepareMe (Mac sidebar plan, part 2): Kiwix's current tab is the reading tab on screen, as on the phone,
            // and none on Inventory or the street map (so Back and Forward never turn the page of a tab out of sight)
            let reader = macTabs.readerOnScreen(mapsPane: mapsPane)
            navigation.currentItem = reader.map { .tab(objectID: macTabs.tabID($0)) }
        }
        .onChange(of: mapsPane) { _, pane in
            navigation.currentItem = macTabs.readerOnScreen(mapsPane: pane).map { .tab(objectID: macTabs.tabID($0)) }
        }
        #endif
        .onOpenURL { (url: URL) in
            /// if the app was just started via URL or file (wasn't open before)
            /// we want to load the content in the first window
            /// otherwise in a new tab (but within the currently active window)
            let isAppStart: Bool = NSApplication.shared.windows.count == 1
            #if PREPAREME_APP // PrepareMe opens nothing from Files (plan phase 6; FINDINGS F-043): its folder only
            if url.isFileURL { return }
            if url.scheme == "prepareme" { // its own links from outside: prepareme://home/<page> (Our Home, Task 2.6)
                _ = macTabs.openAppLink(url)
                return
            }
            if url.isZIMURL { // and a zim: link in its reading tabs, never a new tab (Mac sidebar plan, part 2)
                macTabs.open(url)
                return
            }
            #endif
            if url.isFileURL {
                // from opening an external file
                let browser = BrowserViewModel.getCached(tabID: navigation.currentTabId)
                if isAppStart {
                    browser.forceLoadingState()
                }
                Task { // open the ZIM file
                    if let metadata: ZimFileMetaStruct = await LibraryOperations.open(url: url),
                       let mainPageURL: URL = await ZimFileService.shared.getMainPageURL(zimFileID: metadata.fileID) {
                        if isAppStart {
                            browser.load(url: mainPageURL)
                        } else {
                            browser.createNewWindow(with: mainPageURL)
                        }
                    } else {
                        await browser.clear()
                        isOpenFileAlertPresented = true
                        openFileAlert = OpenFileAlert.unableToOpen(filenames: [url.lastPathComponent])
                    }
                }
            } else if url.isZIMURL {
                // from deeplinks
                if isAppStart {
                    let browser = BrowserViewModel.getCached(tabID: navigation.currentTabId)
                    browser.load(url: url)
                } else {
                    Task { @MainActor in
                        // we want to open the deeplink a new tab (in the currently active window)
                        // at this point though, the latest tab is active, that received the deeplink handling
                        // therefore we do need to wait 1 UI cycle, to finish the original
                        // deeplink handling (hence the Task { @MainActor solution)
                        // This way we can activate the newly opened tab with the deeplink content in it
                        let browser = BrowserViewModel.getCached(tabID: navigation.currentTabId)
                        browser.createNewWindow(with: url)
                    }
                }
            }
        }
        .alert(LocalString.file_import_alert_no_open_title,
               isPresented: $isOpenFileAlertPresented, presenting: openFileAlert) { _ in
        } message: { alert in
            switch alert {
            case .unableToOpen(let filenames):
                let name = ListFormatter.localizedString(byJoining: filenames)
                Text(LocalString.file_import_alert_no_open_message(withArgs: name))
            }
        }
        .onReceive(openURL) { notification in
            guard let url = notification.userInfo?["url"] as? URL else {
                return
            }
            guard controlActiveState == .key else { return }
            #if PREPAREME_APP
            // PrepareMe (Mac sidebar plan, part 2): a link, a search result or a bookmark selects its row (Maps for a
            // map file, else Guides) and loads there, in the tab then on screen (review focus 4)
            macTabs.open(url)
            #else
            let tabID = navigation.currentTabId
            currentNavItem = .tab(objectID: tabID)
            BrowserViewModel.getCached(tabID: tabID).load(url: url)
            #endif
        }
        .onReceive(tabCloses) { publisher in
            // closing one window either by CMD+W || red(X) close button
            guard windowTracker.current == publisher.object as? NSWindow else {
                // when exiting full screen video, we get the same notification
                // but that's not comming from our window
                return
            }
            defer {
                windowTracker.current = nil // remove the reference to this window, see guard above
            }
            
            guard !navigation.isTerminating else {
                // tab closed by app termination
                return
            }
            #if PREPAREME_APP
            // PrepareMe (Mac sidebar plan, part 2; review focus 5): the three reading tabs are kept, so the window
            // reopened finds the same three, never new ones piling up. Only a tab of Kiwix's own would be deleted.
            if let reader = macTabs.row.reader { macTabs.madeBrowser(reader)?.pauseVideoWhenNotInPIP() }
            guard case .tab(let tabID) = navigation.currentItem, !macTabs.isKept(tabID) else {
                if let window = windowTracker.current { SessionRestore.shared.didClose(window: window) }
                return
            }
            #else
            let tabID = navigation.currentTabId
            #endif
            let browser = BrowserViewModel.getCached(tabID: tabID)
            // tab closed by user
            browser.pauseVideoWhenNotInPIP()
            let currentWindow = windowTracker.current
            Task { [weak navigation] in
                await navigation?.deleteTab(tabID: tabID)
                if let currentWindow {
                    SessionRestore.shared.didClose(window: currentWindow)
                }
            }
        }
        .onReceive(keepOnlyTabs) { notification in
            guard let tabsToKeep = notification.userInfo?["tabIds"] as? Set<NSManagedObjectID> else {
                return
            }
            navigation.keepOnlyTabsBy(tabIds: tabsToKeep)
        }
        .onReceive(appTerminates) { _ in
            // CMD+Q -> Quit Kiwix, this also closes the last window
            navigation.isTerminating = true
        }.onReceive(goForwardPublisher) { _ in
            guard case .tab(let tabID) = navigation.currentItem else {
                return
            }
            BrowserViewModel.getCached(tabID: tabID).webView.goForward()
        }.onReceive(goBackPublisher) { [weak navigation] _ in
            #if PREPAREME_APP
            if let reader = macTabs.row.reader,  // Go › Back at a collection's front page: its Library list
               PrepareMeLibraryReturn.shared.goBack(at: macTabs.browser(reader).url) { return }
            #endif
            guard case .tab(let tabID) = navigation?.currentItem else {
                return
            }
            BrowserViewModel.getCached(tabID: tabID).webView.goBack()
        }.task {
            switch AppType.current {
            case .kiwix:
                await LibraryOperations.reValidate()
                #if PREPAREME_APP
                restoreWindow() // PrepareMe (Mac sidebar plan, part 2): its rows are its own, never a new Kiwix tab
                #else
                restoreNavigationState()
                #endif
                // PrepareMe: never in the tests, whose unsigned host isn't sandboxed: listing ~/Documents there waits on
                // macOS's Documents prompt, asked again whenever the build changes (the Thread Sanitizer one hung)
                if !ProcessInfo.processInfo.arguments.contains("testing") {
                    LibraryOperations.applyFileBackupSetting()
                }
                DownloadService.shared.restartHeartbeatIfNeeded()
                await PrepareMeRefresh.start() // PrepareMe
                #if PREPAREME_APP
                macTabs.copiesOpened() // the reading tabs may now be restored (blank-page fix)
                await macTabs.refreshTopics() // the guide list, once the library's copies are open
                if let front = await PrepareMeRefresh.frontPageAtLaunch() { // open on the dashboard, in Today's tab
                    macTabs.showFront(front)
                }
                #else
                if let front = await PrepareMeRefresh.frontPageAtLaunch() { // PrepareMe: open on the dashboard
                    let tabID = navigation.currentTabId
                    currentNavItem = .tab(objectID: tabID)
                    let browser = BrowserViewModel.getCached(tabID: tabID)
                    if browser.url?.zimFileID != front.zimFileID || browser.url?.contentPath != front.contentPath {
                        browser.load(url: front)
                    }
                }
                #endif
            case let .branded(zimFileURL):
                await LibraryOperations.open(url: zimFileURL)
                await ZimMigration.forCustomApps()
                restoreNavigationState()
            }
            // MARK: - payment button init
            #if !PREPAREME_APP
            if Brand.hideDonation == false {
                paymentButtonLabel = await Payment.paymentButtonTypeAsync()
            }
            #endif
            
            // MARK: - migrations
            if !ProcessInfo.processInfo.arguments.contains("testing") {
                _ = MigrationService().migrateAll()
            }
        }
        // Handle re-appearance and marking missing zim files
        .onChange(of: controlActiveState) { _, newState in
            switch newState {
            case .key:
                if FeatureFlags.hasLibrary {
                    Task {
                        await LibraryOperations.reValidate()
                        #if PREPAREME_APP
                        let kept = PrepareMeMacTabs.readers.map { macTabs.tabID($0) }
                        #endif
                        await navigation.deleteTabsWithMissingZimFiles()
                        #if PREPAREME_APP
                        // PrepareMe (Task 6 review): a reading tab Kiwix deleted is made again and shown, and Kiwix's
                        // current tab is the one on screen again (Kiwix moves it to its most recent tab), so Back and
                        // Forward never act on a destroyed or hidden tab
                        await macTabs.afterTabsDeleted(kept)
                        let onScreen = macTabs.readerOnScreen(mapsPane: mapsPane).map {
                            NavigationItem.tab(objectID: macTabs.tabID($0))
                        }
                        if navigation.currentItem != onScreen { navigation.currentItem = onScreen }
                        #endif
                        await BrowserViewModel.reloadFrontPages(of: LibraryOperations.refreshReopened()) // PrepareMe
                        #if PREPAREME_APP
                        await PrepareMeRefresh.nudge() // PrepareMe (plan phase 6): a look at the library folder too
                        #endif
                    }
                }
            case .active, .inactive:
                break
            @unknown default:
                break
            }
        }
        // special hook to trigger the zim file search in the nav bar, when a web view is opened
        // and the cmd+f is triggering the search in page
        .onReceive(NotificationCenter.default.publisher(for: .zimSearch)) { _ in
            isSearchFocused.wrappedValue = true
        }
        .withHostingWindow { [weak windowTracker] hostWindow in
            #if PREPAREME_APP
            // One main window (part 2 review, 4): a second that macOS brings back beside it (window restoration of the
            // older app's ⌘T or New Window) closes at once, before it is tracked or its state restored
            if let main = PrepareMeMacTabs.shared.window, let hostWindow, main !== hostWindow,
               main.isVisible || main.isMiniaturized {
                Task { @MainActor in hostWindow.close() }
                return
            }
            #endif
            windowTracker?.current = hostWindow
            #if PREPAREME_APP
            PrepareMeMacTabs.shared.window = hostWindow  // for the Go menu to bring forward (part 2)
            PrepareMeMacTabs.shared.openWindowAction = openWindow  // for the Dock's icon (AppDelegate)
            #endif
            restoreWindow()
            saveSelectionInSession()
        }
        .handlesExternalEvents(
            preferring: Set([Self.zimURL]),
            allowing: Set([Self.zimURL, "file:///"])
        )
    }
    
    private func restoreNavigationState() {
        if let openedWithWindowState {
            if let restoredURL = URL(string: openedWithWindowState.menuItemId) {
                currentNavItem = MenuItem(rawValue: restoredURL.absoluteString)
                Log.SessionRestore.debug("restored on demand")
            }
            restoreWindow()
        }
        if currentNavItem == nil {
            // only set it if we are not restoring any previous state at start
            currentNavItem = .tab(objectID: navigation.currentTabId)
        }
    }
    
    private func restoreWindow() {
        guard let window = windowTracker.current, let savedState = openedWithWindowState else {
            return
        }
        // restore the window's identifier
        window.setAccessibilityIdentifier(savedState.identifier)
        window.setFrame(savedState.frame, display: true)
        
        // arrange the tabs
        if let tabIndex = savedState.tabIndex, tabIndex > 0 {
            let previousTabId = savedState.otherTabIds[tabIndex - 1]
            if let previousTab = NSApplication.shared.windows.first(where: { window in
                return window.accessibilityIdentifier() == previousTabId
            }) {
                previousTab.addTabbedWindow(window, ordered: .above)
            }
        }
        
        // once we created all tabs for this window tabgroup
        if savedState.isLastTab {
            // select the right tab
            if let selectedTabId = savedState.selectedTabId {
                window.tabGroup?.selectedWindow = NSApplication.shared.windows.first(where: { window in
                    window.accessibilityIdentifier() == selectedTabId
                })
            }
            // select the right window
            if let keyWindowId = savedState.keyWindowId {
                let nsWindow = NSApplication.shared.windows.first { $0.accessibilityIdentifier() == keyWindowId }
                nsWindow?.makeKey()
            }
        }
    }
    
    private func saveSelectionInSession() {
        guard let currentWindow = windowTracker.current, let currentNavItem else {
            return
        }
        SessionRestore.shared.didChangeMenuItem(currentNavItem, inWindow: currentWindow)
    }
}

#endif
