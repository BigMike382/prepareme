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

import SwiftUI
import Defaults
import CoreData

/// This is macOS and iPad only specific, not used on iPhone
struct BrowserTab: View {
    @ObservedObject var browser: BrowserViewModel
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: LibraryViewModel
    @StateObject private var search = SearchViewModel()
#if PREPAREME_APP
    @ObservedObject private var libraryReturn = PrepareMeLibraryReturn.shared
#endif
    /// used on iPad
    private let didChangeTitle: ((NSManagedObjectID, String) -> Void)?
    
    init(tabID: NSManagedObjectID, didChangeTitle: ((NSManagedObjectID, String) -> Void)? = nil) {
        self.didChangeTitle = didChangeTitle
        self.browser = BrowserViewModel.getCached(tabID: tabID)
    }
    
    var body: some View {
        let model = if FeatureFlags.hasLibrary {
            CatalogLaunchViewModel(library: library, browser: browser)
        } else {
            NoCatalogLaunchViewModel(browser: browser)
        }
        Content(browser: browser, model: model, search: search)
            .environmentObject(search)
            .focusedSceneValue(\.isBrowserURLSet, browser.url != nil)
#if os(macOS)
            .focusedSceneValue(\.browserURL, browser.url)
#endif
#if os(macOS) && PREPAREME_APP
            // File › Print (Task 13.3; F48): on the tab itself, not the toolbar's button, which a search or the
            // toolbar's overflow takes away (the review); the page in the key window only
            .onReceive(NotificationCenter.default.publisher(for: .prepareMePrint)) { _ in
                guard let window = browser.webView.window, window === NSApp.keyWindow,
                      browser.webView.url != nil else { return }
                Task { [weak browser] in
                    await PrintButton.print(title: browser?.articleTitle, data: { try await browser?.paperPDF() })
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResizeNotification))) { note in
                (note.object as? NSWindow)?.toolbar?.items.forEach(Self.keepArrows)
            }
#endif
#if PREPAREME_APP
            // PrepareMe (Library plan, task 2.2): Back stays on at a collection's front page opened from a Library list
            .focusedSceneValue(\.canGoBack, browser.canGoBack || libraryReturn.applies(browser.url))
#else
            .focusedSceneValue(\.canGoBack, browser.canGoBack)
#endif
            .focusedSceneValue(\.canGoForward, browser.canGoForward)
            .modifier(ExternalLinkHandler(externalURL: $browser.externalURL))
            .searchable(
                text: $search.searchText,
                placement: Self.searchPlacement,
                prompt: LocalString.common_search
            )
#if PREPAREME_CHECK
            // The check build only (screenshots only): PREPAREME_CHECK_SEARCH=<made-up words> types them into the search
            // box once the libraries are open and meaning search's model has loaded, after PREPAREME_CHECK_APPEARANCE=
            // light, dark or red (the red night screen) as PrepareMeDocuments' hook chooses it
            .task {
                let check = ProcessInfo.processInfo.environment
                guard let words = check["PREPAREME_CHECK_SEARCH"] else { return }
                try? await Task.sleep(for: .seconds(6))
                #if os(macOS)
                if let appearance = check["PREPAREME_CHECK_APPEARANCE"] {
                    PrepareMeRedNight.shared.on = appearance == "red"  // kept in the check build's settings: off again
                }
                if let scheme = ["light": UserColorScheme.light, "dark": .dark][check["PREPAREME_CHECK_APPEARANCE"] ?? ""] {
                    UserDefaults.standard.set(scheme.rawValue, forKey: "userColorScheme")
                    NSApp.appearance = scheme.asNSAppearance
                }
                #endif
                search.searchText = words
            }
            // PREPAREME_CHECK_CLICK=<href> clicks the page's link to it 6 seconds after launch (WebKit reports a script's
            // click on a link as a click): Today's Inventory button (2026-10-28)
            .task {
                guard let href = ProcessInfo.processInfo.environment["PREPAREME_CHECK_CLICK"] else { return }
                try? await Task.sleep(for: .seconds(6))
                _ = try? await browser.webView.callAsyncJavaScript(
                    "for (const a of document.links) if (a.getAttribute('href') === href) { a.click(); break }",
                    arguments: ["href": href], contentWorld: .page)
            }
            #if os(macOS)
            // PREPAREME_CHECK_PAPER=<file> writes what File › Print would hand the print panel to that file, 10 seconds
            // after launch: no panel, nothing reaches a printer (games plan phase 5, 2026-11-14)
            .task {
                guard let file = ProcessInfo.processInfo.environment["PREPAREME_CHECK_PAPER"] else { return }
                try? await Task.sleep(for: .seconds(10))
                guard let data = try? await browser.paperPDF() else { return }
                try? data.write(to: URL(fileURLWithPath: file))
            }
            // PREPAREME_CHECK_WIDTH=<points,points,…> narrows the window through those widths 6 seconds after launch, a
            // quarter second apiece as a drag does, and PREPAREME_CHECK_TOOLBAR=<file> then writes its toolbar's items,
            // each shown or in the overflow menu, with the search box's width: the arrows-stay check (2026-10-29)
            .task {
                let check = ProcessInfo.processInfo.environment
                guard let widths = check["PREPAREME_CHECK_WIDTH"]?.split(separator: ",").compactMap({ Double($0) })
                else { return }
                try? await Task.sleep(for: .seconds(6))
                guard let window = browser.webView.window else { return }
                for width in widths {
                    var frame = window.frame
                    frame.size.width = width
                    window.setFrame(frame, display: true)
                    try? await Task.sleep(for: .seconds(0.25))
                }
                try? await Task.sleep(for: .seconds(2))
                // PREPAREME_CHECK_FIND=1 then presses Search the Library (⇧⌘F), its menu item, as the keys do
                if check["PREPAREME_CHECK_FIND"] != nil, let menu = NSApp.mainMenu {
                    NSApp.activate()  // its window in front first: the item is off while another app is in use
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .seconds(1))
                    func find(_ menu: NSMenu) -> (NSMenu, Int)? {
                        for (index, item) in menu.items.enumerated() {
                            if item.keyEquivalent.lowercased() == "f",
                               item.keyEquivalentModifierMask.contains([.command, .shift]) { return (menu, index) }
                            if let found = item.submenu.flatMap(find) { return found }
                        }
                        return nil
                    }
                    if let (menu, index) = find(menu) { menu.performActionForItem(at: index) }
                    try? await Task.sleep(for: .seconds(2))
                }
                guard let path = check["PREPAREME_CHECK_TOOLBAR"], let toolbar = window.toolbar else { return }
                let visible = Set((toolbar.visibleItems ?? []).map { ObjectIdentifier($0) })
                let lines = ["window \(Int(window.frame.width))"] + toolbar.items.map { item in
                    let shown = visible.contains(ObjectIdentifier(item)) ? "shown" : "overflow"
                    return "\(item.label.isEmpty ? item.itemIdentifier.rawValue : item.label) \(shown) "
                        + "priority \(item.visibilityPriority.rawValue) width \(Int(item.view?.frame.width ?? -1))"
                }
                try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
            #endif
#endif
            .onChange(of: scenePhase) { [weak browser] _, newValue in
                switch newValue {
                case .active:
                    browser?.refreshVideoState()
                case .inactive:
                    Task { [weak browser] in
                        await browser?.persistState()
                    }
                case .background:
                    break
                @unknown default:
                    break
                }
            }
            .modify { [weak browser] view in
#if os(macOS)
                if let browser {
                    view.navigationTitle(browser.articleTitle.isEmpty ? Brand.appName : browser.articleTitle)
                        .navigationSubtitle(browser.zimFileName)
                } else {
                    view
                }
#elseif os(iOS)
                view
#endif
            }
            .task { [weak browser] in
                await browser?.updateLastOpened()
            }
            .onChange(of: browser.articleTitle) { [weak browser] oldTitle, newTitle in
                guard let browser, newTitle != oldTitle else { return }
                didChangeTitle?(browser.tabID, newTitle)
            }
            .onDisappear { [weak browser] in
                browser?.pauseVideoWhenNotInPIP()
                Task { [weak browser] in
                    await browser?.persistState()
                }
            }
    }

#if os(macOS) && PREPAREME_APP
    // At the toolbar's end, as Mail's: it shrinks as the window narrows, then folds to a button, and the arrows stay
    // (owner, 2026-10-29). In the center SwiftUI holds the box at its last width, so the toolbar sent the arrows and
    // then the box itself to its » menu.
    private static let searchPlacement = SearchFieldPlacement.toolbar

    /// The arrows, kept before every other item as the window narrows
    private static func keepArrows(_ item: NSToolbarItem) {
        if [LocalString.common_button_go_back, LocalString.common_button_go_forward].contains(item.label) {
            item.visibilityPriority = .user
        }
    }
#else
    private static let searchPlacement = SearchFieldPlacement.toolbarPrincipal
#endif

    private struct Content<LaunchModel>: View where LaunchModel: LaunchProtocol {
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        let browser: BrowserViewModel
        @EnvironmentObject private var library: LibraryViewModel
        @EnvironmentObject private var navigation: NavigationViewModel
        @Environment(\.isSearching) private var isSearching
        @Environment(\.dismissSearch) private var dismissSearch
        @FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \ZimFile.size, ascending: false)],
            predicate: ZimFile.openedPredicate()
        ) private var zimFiles: FetchedResults<ZimFile>
        /// this is still hacky a bit, as the change from here re-validates the view
        /// which triggers the model to be revalidated
        @Default(.hasSeenCategories) private var hasSeenCategories
        @ObservedObject var model: LaunchModel
        @ObservedObject var search: SearchViewModel
        
        private var isSearchingState: Bool {
            isSearching || !search.searchText.isEmpty
        }
        
        var body: some View {
            // swiftlint:disable:next redundant_discardable_let
            let _ = model.updateWith(hasZimFiles: !zimFiles.isEmpty,
                                     hasSeenCategories: hasSeenCategories)
            GeometryReader { proxy in
                Group {
                    if !search.searchText.isEmpty {
                        SearchResults(viewModel: search)
                            .environment(\.horizontalSizeClass, proxy.size.width > 650 ? .regular : .compact)
                    } else {
                        switch model.state {
                        case .loadingData, .webPage:
                            ZStack {
                                LoadingDataView()
                                    .opacity(model.state == .loadingData ? 1.0 : 0.0)
                                WebView(browser: browser)
                                    .opacity(model.state == .loadingData ? 0.0 : 1.0)
                                    .ignoresSafeArea()
                                    .overlay {
                                        if case .webPage(let isLoading) = model.state, isLoading {
                                            LoadingProgressView()
                                                .background(Color.background)
                                        }
                                    }
#if os(macOS)
                                    .overlay(alignment: .bottomTrailing) {
                                        if !Brand.hideFindInPage {
                                            ContentSearchBar(
                                                model: ContentSearchViewModel(
                                                    findInWebPage: browser.webView.find(_:configuration:)
                                                )
                                            )
                                        }
                                    }
#endif
                            }
                        case .catalog(.fetching):
                            FetchingCatalogView()
                        case .catalog(.list):
                            LocalLibraryList(browser: browser)
                        case .catalog(.welcome(let welcomeViewState)):
                            WelcomeCatalog(viewState: welcomeViewState)
                        }
                    }
                }
            }
            .onChange(of: library.state) { _, state in
                guard state == .complete else { return }
                showTheLibrary()
            }
            .toolbar {
                if !isSearchingState {
#if os(macOS)
                    ToolbarItemGroup(placement: .navigation) {
                        NavigationButtons(
                            goBack: { [weak browser] in
#if PREPAREME_APP
                                if PrepareMeLibraryReturn.shared.goBack(at: browser?.url) { return }
#endif
                                browser?.webView.goBack()
                            },
                            goForward: { [weak browser] in
                                browser?.webView.goForward()
                            })
                    }
#elseif os(iOS)
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        NavigationButtons(
                            goBack: { [weak browser] in
#if PREPAREME_APP
                                if PrepareMeLibraryReturn.shared.goBack(at: browser?.url) { return }
#endif
                                browser?.webView.goBack()
                            },
                            goForward: { [weak browser] in
                                browser?.webView.goForward()
                            })
                    }
#endif
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !Brand.hideTOCButton {
                            OutlineButton(browser: browser)
                        }
#if os(iOS)
                        if !Brand.hideShareButton {
                            ExportButton(
                                articleTitle: browser.articleTitle,
                                webViewURL: browser.webView.url,
                                pageDataWithExtension: { [weak browser] in await browser?.pageDataWithExtension() },
                                isButtonDisabled: browser.zimFileName.isEmpty
                            )
                        }
#else
                        if !Brand.hideShareButton {
                            Menu {
                                ExportButton(
                                    relativeToView: browser.webView,
                                    articleTitle: browser.articleTitle,
                                    webViewURL: browser.webView.url,
                                    pageDataWithExtension: { [weak browser] in await browser?.pageDataWithExtension() },
                                    isButtonDisabled: browser.zimFileName.isEmpty,
                                    buttonLabel: LocalString.common_button_share_as_pdf
                                )
                                #if !PREPAREME_APP  // look 3, change 3: no Copy (of the page's address) in PrepareMe
                                if let url = browser.webView.url {
                                    Button(LocalString.common_button_copy) {
                                        CopyPaste.copyToPasteBoard(url: url)
                                    }
                                    .keyboardShortcut("c", modifiers: [.command, .shift])
                                }
                                #endif
                            } label: {
                                Label(LocalString.common_button_share, systemImage: "square.and.arrow.up")
                            }.disabled(browser.webView.url == nil)
                        }
                        if !Brand.hidePrintButton {
                            PrintButton(articleTitle: { [weak browser] in
                                browser?.articleTitle
                            }, browserDataAsPDF: { [weak browser] in
                                #if PREPAREME_APP
                                try await browser?.paperPDF()  // over letter pages, light (games plan phase 5)
                                #else
                                try await browser?.printablePDF()
                                #endif
                            })
                        }
#endif
                        BookmarkButton(articleBookmarked: browser.articleBookmarked,
                                       isButtonDisabled: browser.zimFileName.isEmpty,
                                       createBookmark: { [weak browser] in browser?.createBookmark() },
                                       deleteBookmark: { [weak browser] in browser?.deleteBookmark() })
#if os(iOS)
                        if !Brand.hideFindInPage {
                            ContentSearchButton(browser: browser)
                        }
#endif
                        // look 3, change 2: no Main Page on the Mac; clicking the sidebar row again opens it
                        #if !(PREPAREME_APP && os(macOS))
                        ArticleShortcutButtons(
                            loadMainArticle: { [weak browser] zimFileID in
                                browser?.loadMainArticle(zimFileID: zimFileID)
                            },
                            loadRandomArticle: { [weak browser] zimFileID in
                                browser?.loadRandomArticle(zimFileID: zimFileID)
                            })
                        #endif
                    }
                }
            }
        }

        private func showTheLibrary() {
            #if !(PREPAREME_APP && os(macOS)) // PrepareMe: the catalog is its own window (File › Get More Libraries…)
            guard model.state.shouldShowCatalog else { return }
            navigation.currentItem = .categories
            #endif
        }
    }
}
