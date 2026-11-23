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

#if os(iOS)
import Defaults
import Combine
import SwiftUI
import UserNotifications
import os
#if PREPAREME_APP
import PrepareMeShared
#endif

@main
struct Kiwix: App {
    
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LibraryViewModel()
    @StateObject private var selection = SelectedZimFileViewModel()
    @StateObject private var navigation = NavigationViewModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var colorSchemeStore = UserColorSchemeStore()
    @Default(.savedMenuNavigation) private var savedMenuSelection: MenuItem?
    
    init() {
        #if PREPAREME_APP
        MacLink.forgetAfterReinstall()  // before anything reads the pairing or sets a setting (beta run 2, B2-19)
        #endif
        Task {
            await WebContentBlocker.compilePolicy()
        }
        Task(priority: .utility) {
            await Diagnostics.start()
        }
        UNUserNotificationCenter.current().delegate = appDelegate
        #if PREPAREME_APP
        // PrepareMe app (plan phase 4): the library comes from the home Mac, never Kiwix's online catalog
        PrepareMeLibrary.launch()
        PrepareMeRedNight.shared.start()  // phase D: the red night screen, if this device has it on
        PrepareMeMeaningModel.start()  // meaning search, once its model has loaded (2026-10-28 plan, phase 3)
        OpeningDiagnostics.start()  // Apple's crash and freeze counts into the opening check's tally (phase 4)
        LibraryProcess.shared.state = .complete
        Defaults[.hasSeenCategories] = true
        // look 3 change 5: Settings no longer offers these two; a device that changed them goes back
        Defaults[.externalLinkLoadingPolicy] = .alwaysAsk
        Defaults[.searchResultSnippetMode] = .matches
        #endif
        // MARK: - migrations
        if !ProcessInfo.processInfo.arguments.contains("testing") {
            _ = MigrationService().migrateAll()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootViewiOS()
                .ignoresSafeArea()
                .environment(\.managedObjectContext, Database.shared.viewContext)
                .environmentObject(library)
                .environmentObject(selection)
                .environmentObject(navigation)
                .environmentObject(colorSchemeStore)
                .modifier(AlertHandler())
                .modifier(QuestionHandler())
                .modifier(OpenFileHandler())
                .modifier(FileExportHandler())
                .modifier(SaveContentHandler())
                .onChange(of: scenePhase) { _, newValue in
                    switch newValue {
                    case .inactive:
                        try? Database.shared.viewContext.save()
                    case .active:
                        #if PREPAREME_APP
                        UpdateSelfCheck.opened() // from what is on the device, before anything is fetched
                        #endif
                        if FeatureFlags.hasLibrary {
                            Task {
                                #if PREPAREME_APP
                                // the sample opened again at the app's new folder, or put away, before Kiwix checks
                                // its files (Unlisted plan, phase 4); once a launch
                                await PrepareMeSample.shared.settleOnce()
                                #endif
                                await LibraryOperations.reValidate()
                                #if PREPAREME_APP
                                OpeningSelfCheck.opened() // its own task, once the library is open; never awaited
                                #endif
                                await navigation.deleteTabsWithMissingZimFiles()
                                // PrepareMe: a library replaced while the app was away shows on its front pages, as
                                // the Mac does on a click to its window (reValidate opens a replaced file again)
                                await BrowserViewModel.reloadFrontPages(of: LibraryOperations.refreshReopened())
                                #if PREPAREME_APP
                                PrepareMeLibrary.shared.becameActive() // the home Mac, not the online catalog
                                LiveConditions.shared.becameActive() // the conditions feeds, read while open
                                PhoneInventoryModel.shared.becameActive() // waiting changes tried while open (12.3)
                                InstallNotices.schedule() // the install's end, set again at each open (layer 3)
                                // the inventory too, so a bin label scanned with the Camera finds its bin (phase 7)
                                Task { await PhoneInventoryModel.shared.look() }
                                #else
                                await library.start(isUserInitiated: false)
                                #endif
                                await Hotspot.shared.appDidBecomeActive()
                            }
                        } else {
                            Task {
                                await Hotspot.shared.appDidBecomeActive()
                            }
                        }
                    case .background:
                        #if PREPAREME_APP
                        PrepareMeLibrary.shared.wentToBackground()
                        LiveConditions.shared.wentToBackground()
                        PhoneInventoryModel.shared.wentToBackground()
                        UpdateSelfCheck.wentToBackground()
                        OpeningSelfCheck.wentToBackground()
                        #endif
                    @unknown default:
                        break
                    }
                }
                .onOpenURL { url in
                    if url.isFileURL {
                        let deepLinkId = UUID()
                        DeepLinkService.shared.startFor(uuid: deepLinkId)
                        NotificationCenter.openFiles([url], context: .file(deepLinkId: deepLinkId))
                    } else if url.isZIMURL {
                        NotificationCenter.openURL(url)
                    }
                    #if PREPAREME_APP
                    PrepareMeTabs.openAppLink(url)  // the street map's own link (plan phase 9)
                    if let place = Barcode.place(in: url.absoluteString) {  // a bin label (plan phase 7, slice 6)
                        PhoneInventoryModel.shared.openedPlace = place
                        Task { await PhoneInventoryModel.shared.look() }  // a bin added since the last look
                    }
                    #endif
                }
                .task {
                    switch AppType.current {
                    case .kiwix:
                        await LibraryOperations.reValidate()
                        #if PREPAREME_APP
                        navigation.currentItem = .tab(objectID: PrepareMeTabs.shared.tabID(.today))
                        #else
                        if !DeepLinkService.shared.isRunning() {
                            if navigation.currentItem == .loading, let savedMenuSelection {
                                navigation.currentItem = savedMenuSelection.navigationItem
                            } else {
                                navigation.navigateToMostRecentTab()
                            }
                        }
                        #endif
                        #if !PREPAREME_APP  // PrepareMe marks only its own library out of backups (LibraryStore);
                        LibraryOperations.applyFileBackupSetting()  // this would mark a ZIM file saved there too
                        #endif
                        DownloadService.shared.restartHeartbeatIfNeeded()
                    case let .branded(zimFileURL):
                        await LibraryOperations.open(url: zimFileURL)
                        await ZimMigration.forCustomApps()
                        navigation.navigateToMostRecentTab()
                    }
                }
                .onAppear {
                    colorSchemeStore.update()
                }
                #if !PREPAREME_APP // Kiwix's donation code isn't in PrepareMe (Unlisted plan, phase 4; audit P2d)
                .modifier(DonationViewModifier())
                #endif
                #if PREPAREME_APP
                .modifier(PrepareMeSheets())
                .pmTint()  // look 3: PrepareMe's teal (the ink in red night), never system blue; it had been the ink (A9)
                #endif
        }
        .commands {
            #if !PREPAREME_APP
            CommandGroup(replacing: .undoRedo) {
                NavigationCommands(goBack: {
                    NotificationCenter.default.post(name: .goBack, object: nil)
                }, goForward: {
                    NotificationCenter.default.post(name: .goForward, object: nil)
                })
            }
            #endif
            #if PREPAREME_APP
            CommandGroup(after: .toolbar) {  // under View, where the iPad's menu bar looks (Task 10.6; F60)
                // Back and Forward here, so Edit keeps Undo and Redo; a tab each, ⌘1 to ⌘5, and ⌘F for its search
                // (Apple's menu bar and keyboard pages; the audit, 2026-10-22)
                NavigationCommands(goBack: {
                    NotificationCenter.default.post(name: .goBack, object: nil)
                }, goForward: {
                    NotificationCenter.default.post(name: .goForward, object: nil)
                })
                Divider()
                PrepareMeTabCommands()
                Divider()
                PageZoomCommands()
                Divider()
                RedNightSwitch()  // phase D
            }
            CommandGroup(replacing: .help) {  // the iPad's Help menu (Task 13.3; F48, F60)
                Button(PrepareMeHelp.menuTitle) { PrepareMeTabs.shared.openHelp() }
                    .keyboardShortcut("?", modifiers: .command)
            }
            #else
            CommandGroup(replacing: .textFormatting) {
                PageZoomCommands()
            }
            #endif
        }
    }

    private class AppDelegate: NSObject, UIApplicationDelegate, @MainActor UNUserNotificationCenterDelegate {
        
        /// Storing background download completion handler sent to application delegate
        func application(_ application: UIApplication,
                         handleEventsForBackgroundURLSession identifier: String,
                         completionHandler: @escaping () -> Void) {
            #if PREPAREME_APP
            // the home Mac's library downloads (plan phase 4), and its optional maps' (offline fixes, phase 5)
            if [LibraryDownloader.identifier, LibraryDownloader.optionalIdentifier].contains(identifier) {
                LibraryDownloader.shared.finishEvents(identifier, completionHandler)
                LibraryDownloader.shared.reconnect()
                return
            }
            #endif
            DownloadService.shared.sessionDelegate.backgroundCompletionHandler = completionHandler
        }

        /// Handling file download complete notification
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            Task { @MainActor in
                #if PREPAREME_APP
                // the install's end (over-the-air plan, layer 3) opens Home Mac, where its line and Update are
                if InstallNotices.isNotice(response.notification.request.identifier) {
                    PrepareMeTabs.shared.openHomeMac()
                    completionHandler()
                    return
                }
                // an expiry reminder opens Inventory on Expiring soon (Task 12.6; F38): it had opened nothing
                if ExpiryReminders.isReminder(response.notification.request.identifier) {
                    PhoneInventoryModel.shared.openedPlace = nil  // a bin's sheet would hide it (the review)
                    PrepareMeTabs.shared.selected = .inventory
                    PhoneInventoryModel.shared.openExpiring = true
                    completionHandler()
                    return
                }
                #endif
                if let zimFileID = UUID(uuidString: response.notification.request.identifier),
                   let mainPageURL = await ZimFileService.shared.getMainPageURL(zimFileID: zimFileID) {
                    NotificationCenter.openURL(mainPageURL, inNewTab: true)
                }
                completionHandler()
            }
        }
        // PrepareMe: no memory warning handler; it split a tab from its page (BrowserViewModel, where purgeCache was)
    }
}

#endif
