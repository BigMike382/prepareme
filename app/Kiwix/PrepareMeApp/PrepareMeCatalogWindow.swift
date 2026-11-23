// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (Mac sidebar plan, part 2).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import AppKit
import CoreData
import Defaults
import PrepareMeShared
import SwiftUI

/// File › Get More Libraries… (spec, "What moves or goes"): Kiwix's online catalog, Categories and New, and PrepareMe's
/// own Downloads (plan phase 8), in a window of its own instead of the main window's sidebar. The downloads work
/// exactly as before: a file's Download button still goes to `MacDownloads`; only where the catalog opens changed.
///
/// - The App hands it its own `LibraryViewModel` (the main window's) and the focus ⇧⌘F sets while this window is key;
///   the window brings a `NavigationViewModel` of its own (so nothing here touches the main window's tabs) and the
///   database's context.
/// - A file's Open main page opens in the main window (`PrepareMeOpensInMain`).
struct PrepareMeCatalogWindow: View {
    enum Pane: String, Hashable { case categories, new, otherSites, downloads }  // Other Sites: plan 5.4

    @ObservedObject var library: LibraryViewModel  // the App's own, as the main window's (fix round 1)
    var isSearchFocused: FocusState<Bool>.Binding  // ⇧⌘F while this window is key (Search the Library; 13.5)
    @StateObject private var navigation = NavigationViewModel()
    /// The catalog's download: Kiwix writes it to the database in one batch, which a list already on screen never
    /// hears of, so the first download showed "No ZIM file" until the window was reopened (seen on screen,
    /// 2026-10-16). A download that wrote new data stamps `libraryLastRefresh`, and that draws the panes again
    /// (`drawn`). Not the refresh's state: a "nothing new" answer finishes without the stamp, so a drawn pane's own
    /// refresh would start again at once, without end (review, 2026-10-16). A search typed meanwhile starts over.
    @Default(.libraryLastRefresh) private var lastRefresh
    @State private var drawn = 0
    /// Opens on Downloads (Task 13.4; F49; owner, 2026-10-18, by click): it had opened on Wikipedia's tiles, which the
    /// household decided against. A new key, so every Mac opens on the new default once, whatever it last showed.
    @AppStorage("prepareme.mac.catalogPane.v2") private var pane = Pane.downloads
    @State private var selectedLanguage: String = Defaults[.libraryLanguageCodes].first ?? "eng"
    @Default(.libraryLanguageCodes) private var languages

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Pane?>(get: { pane }, set: { if let picked = $0 { pane = picked } })) {
                Label(MenuItem.categories.name, systemImage: MenuItem.categories.icon).tag(Pane.categories)
                Label(MenuItem.new.name, systemImage: MenuItem.new.icon).tag(Pane.new)
                Label("Other Sites", systemImage: "globe").tag(Pane.otherSites)
                DownloadsRow().tag(Pane.downloads)
            }
            .font(.pmBody)
            .frame(minWidth: 180)
        } detail: {
            Group {
                switch pane {
                case .categories:  // as Kiwix's own sidebar row showed it, its language switch included
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
                case .new:
                    DetailSidePanel(content: { ZimFilesNew(dismiss: nil) })
                        .modifier(SearchFocused(isSearchFocused: isSearchFocused))
                case .otherSites:  // single items from the trusted list (library redesign plan 5.4)
                    PrepareMeOtherSitesView().pmMacWindow()
                case .downloads:  // no file to pick here, so no side panel: as the main window showed it until now
                    PrepareMeDownloadsView().pmMacWindow()
                }
            }
            .pmTint()
            .id(drawn)
        }
        .onChange(of: lastRefresh) { drawn += 1 }
        .onChange(of: languages) {
            if languages.count == 1, let only = languages.first {
                selectedLanguage = only
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .environment(\.managedObjectContext, Database.shared.viewContext)
        .environmentObject(library)
        .environmentObject(navigation)
        .modifier(PrepareMeOpensInMain())
        .withHostingWindow { Self.window = $0 }
    }

    /// This window, for the App's ⇧⌘F to tell when it is the key one (nil until it first opens)
    static weak var window: NSWindow?

    /// ⇧⌘F while this window is key: its toolbar's search field (Categories' or New's `.searchable`) takes the typing.
    /// The focus the App hands in alone never reached that field (seen on screen, 2026-10-16), so AppKit is asked
    /// directly: the toolbar's search item, else any search field in the window.
    static func focusSearch(in window: NSWindow) {
        if let item = window.toolbar?.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
        } else if let field = searchField(in: window.contentView?.superview) {
            window.makeFirstResponder(field)
        }
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }
}

/// Bookmarks › Show Bookmarks (⌥⌘B): Kiwix's bookmarks in a window of their own; one picked opens in the main window,
/// on its row's reading tab (`PrepareMeMacTabs.open`: Maps for a page of a map file, Guides for any other).
struct PrepareMeBookmarksWindow: View {
    @StateObject private var navigation = NavigationViewModel()

    var body: some View {
        NavigationStack {
            Bookmarks()
        }
        .pmTint()
        .frame(minWidth: 420, minHeight: 360)
        .environment(\.managedObjectContext, Database.shared.viewContext)
        .environmentObject(navigation)
        .modifier(PrepareMeOpensInMain())
    }
}

/// A window of its own (Bookmarks, Get More Libraries…) whose Kiwix views post Kiwix's openURL: the main window acts on
/// it only while it is the key window, so this window, while key, opens the page in the main window instead.
struct PrepareMeOpensInMain: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .openURL)) { notification in
            guard controlActiveState == .key, let url = notification.userInfo?["url"] as? URL else { return }
            PrepareMeMacTabs.shared.openInMain(url, openWindow: openWindow)
        }
    }
}

/// Go › Library Collections (R6.3; B2-24; Window › Library until the menu bar plan, owner 2026-11-14): the libraries
/// the Mac holds besides the daily one, each opening at its front page in the main window. Greyed while there are none.
struct PrepareMeOtherLibrariesMenu: View {
    let openWindow: OpenWindowAction
    @ObservedObject private var store = PrepareMeMac.shared.store

    var body: some View {
        let others = MacLibraries.others(store.record.held, dailyFile: PrepareMeKeptTabs.dailyFile)
        Menu(MacLibraries.collectionsTitle) {
            ForEach(others, id: \.id) { library in
                Button(library.title) {
                    PrepareMeMacTabs.shared.openLibrary(library.id, openWindow: openWindow)
                }
            }
        }
        .disabled(others.isEmpty)
    }
}

/// The Go menu's screens (menu bar plan, owner 2026-11-14; Window listed five of them until then): every sidebar row
/// in the sidebar's order, ⌘1 to ⌘9, each bringing the main window forward on it, or a new one when it was closed
/// (F48); then Street Map (⇧⌘M; street map fixes plan, task 5.1), Maps on its Street map side, and the collections.
/// A row the sidebar isn't showing (Games with no games file, Library with nothing besides the daily library) is
/// dimmed, never hidden, so a key always means the same screen.
struct PrepareMeGoRows: View {
    let openWindow: OpenWindowAction
    @ObservedObject private var store = PrepareMeMac.shared.store

    var body: some View {
        let held = store.record.held
        let noCollections = MacLibraries.others(held, dailyFile: PrepareMeKeptTabs.dailyFile).isEmpty
        ForEach(MacSidebar.topLevel, id: \.self) { row in
            let off = row == .games ? held[MacLibraries.gamesFile] == nil : row == .shelf && noCollections
            let item = Button(MacSidebar.title(row) ?? "") {
                PrepareMeMacTabs.shared.showFromMenu(row, openWindow: openWindow)
            }
            .disabled(off)
            if let key = MacSidebar.goKey(row) {
                item.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
            } else {
                item
            }
        }
        Divider()
        Button("Street Map") {  // one name, as the phones say it (Task 13.6; F52)
            PrepareMeMacTabs.shared.showFromMenu(.maps, streetMap: true, openWindow: openWindow)
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        PrepareMeOtherLibrariesMenu(openWindow: openWindow)
    }
}

/// The Bookmarks menu (spec, "Bookmarks"): Add Bookmark or Remove Bookmark (⌘D), the reading tab on screen's bookmark
/// added or removed as the toolbar's star (Kiwix's BookmarkButton) does, in its words (look 3, change 20), so it has nothing to do on Inventory or the street map;
/// then Show Bookmarks (⌥⌘B); then, after a divider, the saved pages by title, newest first, the first
/// `SavedPages.shown` of them (the rest in the Bookmarks window). A page picked opens as the window's picks do
/// (`PrepareMeMacTabs.openInMain`), so the sidebar shows the row it belongs to.
struct PrepareMeBookmarkCommands: View {
    let openWindow: OpenWindowAction
    @ObservedObject private var tabs = PrepareMeMacTabs.shared
    @ObservedObject private var saved = SavedPages.shared
    @AppStorage(PrepareMeMacTabs.mapsPaneKey) private var mapsPane = MapsPane.find.rawValue

    var body: some View {
        if tabs.copiesOpen, let reader = tabs.readerOnScreen(mapsPane: mapsPane) {  // no tab before (blank-page fix)
            BookmarkThisPage(browser: tabs.browser(reader))
                .id(tabs.tabID(reader))
        } else {
            Button(LocalString.common_dialog_button_add_bookmark) {}
                .keyboardShortcut("d")
                .disabled(true)
        }
        Button("Show Bookmarks") { openWindow(id: "bookmarks") }
            .keyboardShortcut("b", modifiers: [.command, .option])
        if !saved.pages.isEmpty {
            Divider()
            ForEach(Array(saved.pages.enumerated()), id: \.offset) { _, page in  // two may share an address
                Button(page.title) { tabs.openInMain(page.url, openWindow: openWindow) }
            }
        }
    }

    /// The tab's own item, watching its page: Remove Bookmark while the page is bookmarked; off while the tab has no page.
    private struct BookmarkThisPage: View {
        @ObservedObject var browser: BrowserViewModel

        var body: some View {
            Button(browser.articleBookmarked ? LocalString.common_dialog_button_remove_bookmark
                                             : LocalString.common_dialog_button_add_bookmark) {
                if browser.articleBookmarked { browser.deleteBookmark() } else { browser.createBookmark() }
            }
            .keyboardShortcut("d")
            .disabled(browser.zimFileName.isEmpty)
        }
    }
}

/// The Bookmarks menu's saved pages: Kiwix's bookmarks as its Bookmarks view lists them (newest first, none of a file
/// that has gone), the first `shown`, read again whenever the database's main context changes (a bookmark added or
/// removed from the menu, the toolbar's star or the Bookmarks window). A menu can't hold a `@FetchRequest`: its views
/// get no managed object context.
///
/// Fix round 2 (a crash at every launch): the menu is built with the App's first body, before anything has made
/// Kiwix's database, and `Bookmark.fetchRequest()` built then can't name its entity (Core Data raises an Objective-C
/// exception, which `try?` doesn't catch). So nothing is read while the menu is built: the first read waits a turn of
/// the main loop, touches the database first, and names the entity from the store's own model, reading nothing (the
/// menu shows only its two commands) while there is no store or no such entity.
@MainActor
final class SavedPages: ObservableObject {
    static let shared = SavedPages()
    static let shown = 20

    struct Page: Equatable {
        let title: String
        let url: URL
    }

    @Published private(set) var pages: [Page] = []
    private var watching: NSObjectProtocol?

    private init() {
        Task { @MainActor [weak self] in self?.start() }  // after the App's body is built, never during it
    }

    private func start() {
        guard watching == nil else { return }
        let context = Database.shared.viewContext
        watching = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextObjectsDidChange,
                                                          object: context, queue: .main) { _ in
            Task { @MainActor in SavedPages.shared.read() }
        }
        read()
    }

    private func read() {
        let context = Database.shared.viewContext
        guard let coordinator = context.persistentStoreCoordinator, !coordinator.persistentStores.isEmpty,
              let entity = coordinator.managedObjectModel.entitiesByName["Bookmark"] else { return }
        let request = NSFetchRequest<Bookmark>()
        request.entity = entity
        request.predicate = NSPredicate(format: "zimFile.isMissing == false")
        request.sortDescriptors = [NSSortDescriptor(key: "created", ascending: false)]
        request.fetchLimit = Self.shown
        let read = ((try? context.fetch(request)) ?? []).map {
            Page(title: $0.title.isEmpty ? $0.articleURL.lastPathComponent : $0.title, url: $0.articleURL)
        }
        if read != pages { pages = read }
    }
}
/// The sidebar's Downloads row, with a spinner and how many are under way (library redesign plan 1.2): a view of its own,
/// so only it redraws as a download moves, not the whole window.
private struct DownloadsRow: View {
    @ObservedObject private var downloads = MacDownloads.shared

    var body: some View {
        HStack {
            Label(MenuItem.downloads.name, systemImage: MenuItem.downloads.icon)
            Spacer()
            let underWay = downloads.running.count + downloads.queued.count
            if underWay > 0 {
                ProgressView().controlSize(.small)
                Text("\(underWay)").foregroundStyle(PrepareMeColors.text2)
            }
        }
    }
}
#endif
