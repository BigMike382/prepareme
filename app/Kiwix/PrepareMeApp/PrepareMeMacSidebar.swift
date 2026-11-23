// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (Mac sidebar plan, part 2).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import AppKit
import Combine
import CoreData
import PrepareMeShared
import SwiftUI
import WebKit

/// The Mac's places, like the iPhone's tabs (owner, 2026-10-15): which sidebar row shows, and the Kiwix tab behind
/// each reader (Today, Guides and Maps), kept by address as the phone's are (PrepareMeKeptTabs, `prepareme.mac.tab.…`),
/// so each keeps its page and back history and closing the window deletes none of them.
///
/// - The row is kept in the defaults as JSON; one that can't be read is Today, and a category or sub-category the
///   guide list no longer has is Guides.
/// - `topics` is the daily library's `household/guide-topics.json`; nil when it is missing or refused, and the sidebar
///   then shows Guides and New only, never an empty Categories row.
/// - Search results, bookmarks and links from outside the page (one that starts the app, or asks for a new window) open
///   through `open`: a page of a map file on Maps, any other on Guides (the daily front page on Today), always in the
///   tab that then shows, never a hidden one. A link within a page stays in its tab.
@MainActor
final class PrepareMeMacTabs: ObservableObject {
    static let shared = PrepareMeMacTabs()
    static let rowKey = "prepareme.mac.row"
    static let mapsPaneKey = "prepareme.mac.mapsPane"  // Maps' Find a map or Street map side (MapsPane)
    static let readers: [MacRow.Reader] = [.today, .guides, .maps]

    @AppStorage(PrepareMeMacTabs.rowKey) var rowData = Data()
    @Published var row: MacRow {
        didSet { if row != oldValue, let data = try? JSONEncoder().encode(row) { rowData = data } }
    }
    /// A row chosen since launch (a pick in the list, a link or bookmark through `open`, a Go menu item), as
    /// against one the app set itself: the launch's dashboard (`showFront`) then leaves the row be (fix round 1).
    private(set) var chosenSinceLaunch = false
    @Published var topics: GuideTopics?
    /// The launch has opened the library's copies (RootView's first look, `copiesOpened`). Until then no reading tab
    /// is made: a tab's saved page restored before its file is open is refused, leaving it blank behind a failure
    /// alert, and `showFront` then finds the front page "already" there (blank-page fix, 2026-10-16).
    @Published private(set) var copiesOpen = false
    /// The main window, for the Go menu to bring forward (RootView's hosting window; nil before it first opens)
    #if PREPAREME_CHECK
    weak var window: NSWindow? {
        // the check's size as the window first opens, after RootView puts its saved frame back: a screen restored at
        // launch is drawn at that size, and the inventory's table takes its width once (the inventory fresh look);
        // PREPAREME_CHECK_COLUMNS_FRESH=1: the inventory's tables open as at the first launch, their hidden columns and
        // sort forgotten (a session can't reach the check build's settings: phase 0), before a restored table reads them
        didSet {
            guard oldValue == nil, window != nil else { return }
            if ProcessInfo.processInfo.environment["PREPAREME_CHECK_COLUMNS_FRESH"] == "1" {
                InventoryTableMemory().forgetAll()
            }
            Task { @MainActor in self.setCheckFrame() }
        }
    }
    #else
    weak var window: NSWindow?
    #endif
    /// The App's window opener, kept by the first window to open (the main one, Settings, Libraries or Bookmarks), so
    /// the Dock's icon can open the main window again while another one is on screen (AppDelegate)
    var openWindowAction: OpenWindowAction?
    private var watching: AnyCancellable?

    private init() {
        row = MacSidebar.restore(UserDefaults.standard.data(forKey: Self.rowKey)
            .flatMap { try? JSONDecoder().decode(MacRow.self, from: $0) } ?? .today,
            shelf: PrepareMeLibraryShelf.shared.current)
        // The list again whenever the daily library is replaced (the hourly job's rebuild). `$record` sends before the
        // record is stored, so the read waits its turn; the new copy is open in Kiwix by then (LibraryStore registers
        // it before it records it).
        watching = PrepareMeMac.shared.store.$record
            .map { $0.held[PrepareMeKeptTabs.dailyFile]?.entry.sha256 }
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in await self?.refreshTopics() } }
    }

    func copiesOpened() {
        if !copiesOpen { copiesOpen = true }
    }

    func tabID(_ reader: MacRow.Reader) -> NSManagedObjectID {
        PrepareMeKeptTabs.tabID(key: "prepareme.mac.tab.\(reader.rawValue)")
    }

    /// One of the three reading tabs: the window's close leaves these be (review focus 5).
    func isKept(_ id: NSManagedObjectID) -> Bool {
        Self.readers.contains { tabID($0) == id }
    }

    func browser(_ reader: MacRow.Reader) -> BrowserViewModel {
        BrowserViewModel.getCached(tabID: tabID(reader))
    }

    /// The reading tab's browser only if one is made already (the window's close pauses its video): never a new one,
    /// which before the copies are open would restore its page too soon (part 2 review, 3).
    func madeBrowser(_ reader: MacRow.Reader) -> BrowserViewModel? {
        BrowserViewModel.cachedIfMade(tabID: tabID(reader))
    }

    /// Until the launch has opened the library's copies (`copiesOpen`); at once when it has. A page loaded sooner is
    /// refused ("Unable to load") and its tab stays blank (part 2 review, 3: a zim: link that starts the app, or a
    /// Bookmarks pick in its first second).
    private func untilCopiesOpen() async {
        for await open in $copiesOpen.values where open { break }
    }

    /// The reading tab on screen: none on Inventory, nor on Maps' Street map side (so Back and Forward never turn the
    /// page of a tab out of sight).
    func readerOnScreen(mapsPane: String) -> MacRow.Reader? {
        row == .maps && mapsPane == MapsPane.street.rawValue ? nil : row.reader
    }

    /// The Go menu's items (Window's until 2026-11-14) and Go › Street Map: the row (Maps on its Street map side), in the main window brought
    /// forward, or a new one when it was closed.
    func showFromMenu(_ row: MacRow, streetMap: Bool = false, openWindow: OpenWindowAction) {
        if streetMap { UserDefaults.standard.set(MapsPane.street.rawValue, forKey: Self.mapsPaneKey) }
        chosenSinceLaunch = true
        forgetReturn()  // a pick, as a sidebar click is: Back no longer leads to a Library list (Go lists Guides too)
        raise(openWindow: openWindow)
        Task { await show(row) }
    }

    /// The app's own links in a page (phase 14, F57): a guide's On the map opens Maps on its Street map side, its In
    /// the house Inventory on the items its words name, and a link to the library's Inventory page Inventory itself
    /// (owner, 2026-10-28). Whether it was one.
    func openAppLink(_ url: URL) -> Bool {
        if MacRow.isInventoryPage(url) {
            chosenSinceLaunch = true
            Task { await show(.inventory) }
            return true
        }
        if let house = GuideLinks.houseLink(url) {
            InventoryModel.shared.requestedPick = .view(.guide(title: house.title, words: house.words))
            chosenSinceLaunch = true
            Task { await show(.inventory) }
            return true
        }
        if let page = HomeLinks.page(url) {  // a label's QR code or a Shortcut (Our Home, Task 2.6): Today, at its start
            chosenSinceLaunch = true
            Task {
                await untilCopiesOpen()
                guard let front = await Self.mainPage(PrepareMeKeptTabs.dailyFile) else { return }
                let here = MacRow.address(page, beside: front)
                let found = await ZimFileService.shared.getContentSize(url: here) != nil
                row = .today
                browser(.today).load(url: found ? here : MacRow.address(HomeLinks.section, beside: front))
            }
            return true
        }
        guard url.scheme == "prepareme", url.host == "streetmap" else { return false }
        UserDefaults.standard.set(MapsPane.street.rawValue, forKey: Self.mapsPaneKey)
        chosenSinceLaunch = true
        Task { await show(.maps) }
        return true
    }

    /// Help › PrepareMe Help (Task 13.3; F48): the help page beside the daily front page, in the main window.
    func showHelp(openWindow: OpenWindowAction) {
        Task {
            guard let front = await Self.mainPage(PrepareMeKeptTabs.dailyFile) else { return }
            openInMain(MacRow.address(PrepareMeHelp.page, beside: front), openWindow: openWindow)
        }
    }

    /// Go › Library Collections (R6.3; B2-24; owner, 2026-11-12; Window › Library until 2026-11-14): one of the collections besides the daily one at its front
    /// page, in the main window brought forward.
    func openLibrary(_ id: UUID, openWindow: OpenWindowAction) {
        forgetReturn()
        showFromMenu(.library(id: id), openWindow: openWindow)
    }

    /// The Library list a collection was opened from (Library plan, task 2.2): kept picked in the sidebar while the
    /// collection shows, and where Back from its front page goes (`PrepareMeLibraryReturn`).
    @Published private(set) var returnRow: MacRow?

    /// The row the sidebar shows picked: the Library list a collection came from, while it shows, and Our Home's
    /// own row while one of its pages shows (Our Home plan, Task 2.6; weak point 10, board 13).
    var sidebarRow: MacRow {
        if case .library = row, let returnRow { return returnRow }
        if homeShown { return .category(page: HomeLinks.section) }
        return row
    }

    /// Whether the reader on screen shows an Our Home page of the daily library (`watchHome`).
    @Published private(set) var homeShown = false
    private var homeWatch: AnyCancellable?

    func watchHome() {
        homeWatch = Publishers.CombineLatest3($row, browser(.today).$url, browser(.guides).$url)
            .receive(on: RunLoop.main)
            .sink { [weak self] row, today, guides in
                let shown = row.reader == .today ? today : row.reader == .guides ? guides : nil
                let daily = PrepareMeMac.shared.store.record.held[PrepareMeKeptTabs.dailyFile]
                    .flatMap { UUID(uuidString: $0.entry.id) }
                let on = HomeLinks.isHomePage(shown, dailyID: daily)
                if self?.homeShown != on { self?.homeShown = on }
            }
    }

    /// A collection opened from a Library list: its front page in the Guides tab, Back from there to `list`.
    func openCollection(_ id: UUID, from list: MacRow) {
        chosenSinceLaunch = true
        Task {
            guard let front = await ZimFileService.shared.getMainPageURL(zimFileID: id) else { return }
            returnRow = list
            PrepareMeLibraryReturn.shared.set(front: front) { [weak self] in
                guard let self else { return }
                let back = self.returnRow ?? .shelf
                self.forgetReturn()
                self.row = back
            }
            await show(.library(id: id))
        }
    }

    func forgetReturn() {
        returnRow = nil
        PrepareMeLibraryReturn.shared.clear()
    }

    /// The list Back leads to was deleted: Back leads to the row that stands in for it (phase 4 review).
    func moveReturn(to row: MacRow) {
        if returnRow != nil { returnRow = row }
    }

    /// The one main window brought forward (Mac sidebar plan, part 2: no New Tab or New Window), or opened again when
    /// it was closed; never a second one beside it.
    func raise(openWindow: OpenWindowAction) {
        NSApp.unhide(nil)
        NSApp.activate()
        if let window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "rootView")
        }
    }

    /// A page picked in a window of its own (Bookmarks, Get More Libraries…): it opens as `open` opens it, in the main
    /// window brought forward. Those windows' Kiwix views post Kiwix's openURL, which only the key window acts on.
    func openInMain(_ url: URL, openWindow: OpenWindowAction) {
        raise(openWindow: openWindow)
        open(url)
    }

    /// Selects `row` and shows it: a row with a page (Guides, New, a category, a sub-category at its heading) loads it
    /// into the Guides tab; Today and Maps keep the page they are on, opening their first page only when empty.
    func show(_ row: MacRow) async {
        self.row = row
        guard let reader = row.reader else { return }
        let browser = browser(reader)
        let target: URL?
        var ownPage = row.page(newPage: topics?.newPage ?? GuideTopics.newPage) != nil
        if case .library = row { ownPage = true }  // its front page, whatever the Guides tab shows
        if row == .games { ownPage = true }  // as a collection's (games plan phase 4)
        if ownPage || browser.url == nil {
            target = await firstPage(row)
        } else {
            target = nil
        }
        // a row picked meanwhile wins; a page already on screen isn't loaded again (its back history stays as it is)
        guard let target, self.row == row, browser.url != target else { return }
        browser.load(url: target)
    }

    /// A row's own page: its page beside the daily front page (Guides, New, a category, a sub-category at its
    /// anchor), an other library's front page, the daily front page (Today) or Find a map (Maps); nil for Inventory,
    /// or while the file isn't open.
    private func firstPage(_ row: MacRow) async -> URL? {
        if case let .library(id) = row { return await ZimFileService.shared.getMainPageURL(zimFileID: id) }
        if row == .games { return await Self.mainPage(MacLibraries.gamesFile) }
        if let page = row.page(newPage: topics?.newPage ?? GuideTopics.newPage) {
            return await Self.mainPage(PrepareMeKeptTabs.dailyFile).map { MacRow.address(page, beside: $0) }
        }
        switch row.reader {
        case .maps:  // Find a map, beside the overview's front page (phase L, finding 1)
            guard let main = await Self.mainPage(PrepareMeKeptTabs.overviewFile) else { return nil }
            return await PrepareMeKeptTabs.findAMap(beside: main)
        case .today: return await Self.mainPage(PrepareMeKeptTabs.dailyFile)
        case .guides, nil: return nil
        }
    }

    /// The row a click in the list picked, and when: a click on the row already picked doesn't change the list's
    /// selection, so the row's own tap (`tapped`) is what sees it, and this tells the two apart.
    private var picked: (row: MacRow, at: Date)?

    /// The list's selection set by a click or the keyboard: a new row shows (`show`); the row already picked, picked
    /// again (`repick`).
    func pick(_ row: MacRow) {
        picked = (row, Date())
        chosenSinceLaunch = true
        forgetReturn()  // a row picked: Back no longer leads to a Library list (its own list shows again if it's one)
        if row == self.row {
            Task { await repick(row) }
        } else {
            self.row = row
            Task { await show(row) }
        }
    }

    /// A row clicked (Task 6 review: a row whose page was already loaded did nothing). The list picks a new row before
    /// the click ends, so a click that just picked its row is left to `pick`; one on the row already picked is a pick
    /// again.
    func tapped(_ row: MacRow) {
        if let picked, picked.row == row, Date().timeIntervalSince(picked.at) < 1 {
            self.picked = nil
            return
        }
        // the Library list kept picked while one of its collections shows: the list again (the review, phase 5)
        if case .library = self.row, row == returnRow {
            pick(row)
            return
        }
        guard row == self.row else { return }
        if row == .inventory {  // Inventory's own row clicked while it shows: its home page again (phase 3)
            InventoryModel.shared.goHome()
            return
        }
        Task { await repick(row) }
    }

    /// A row picked again, as a tab picked again on the phone: its page from the top (a sub-category at its heading),
    /// loaded again when its tab has moved on from it. Maps on its Street map side and Inventory stay as they are.
    func repick(_ row: MacRow) async {
        guard let reader = row.reader,
              reader != .maps || UserDefaults.standard.string(forKey: Self.mapsPaneKey) != MapsPane.street.rawValue,
              let target = await firstPage(row), self.row == row else { return }
        let browser = browser(reader)
        // only a page the web view has shown is scrolled: one whose load was refused left it blank, so it loads again
        if let url = browser.url, Self.samePage(url, target), browser.webView.backForwardList.currentItem != nil {
            Self.scroll(browser.webView, to: target.fragment)
        } else {
            browser.load(url: target)
        }
    }

    /// Two addresses of one page, whatever heading each is at.
    static func samePage(_ one: URL, _ other: URL) -> Bool {
        func bare(_ url: URL) -> String? {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.fragment = nil
            return parts?.string
        }
        return bare(one) != nil && bare(one) == bare(other)
    }

    /// The page on screen to its top, or to the heading with this anchor; no new step in its back history.
    static func scroll(_ webView: WKWebView, to anchor: String?) {
        let script: String
        if let anchor, let data = try? JSONEncoder().encode(anchor), let quoted = String(data: data, encoding: .utf8) {
            script = "(document.getElementById(\(quoted)) || document.body).scrollIntoView(); void 0"
        } else {
            script = "window.scrollTo(0, 0); void 0"
        }
        webView.evaluateJavaScript(script)
    }

    /// After Kiwix deletes the tabs whose file has gone (`deleteTabsWithMissingZimFiles`, at each return to the
    /// window; Task 6 review): a reading tab it deleted is made again, empty, by `tabID`, the views showing one are
    /// rebuilt on the new tab (RootView takes each reader view's identity from `tabID`), and the row's page loads.
    /// `before` is the three tabs' IDs from before the deletion.
    func afterTabsDeleted(_ before: [NSManagedObjectID]) async {
        guard Self.readers.map({ tabID($0) }) != before else { return }
        objectWillChange.send()
        if let reader = row.reader, browser(reader).url == nil { await show(row) }
    }

    #if PREPAREME_CHECK
    /// "Menu › Item ⇧⌘N (off)", a line each, submenus indented: the check build's menu file
    static func menuLines(_ menu: NSMenu?, depth: Int = 0) -> [String] {
        guard let menu else { return [] }
        // as if opened: SwiftUI fills and enables a command menu's items as it opens (phase 1 fixes, finding 12)
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.delegate?.menuWillOpen?(menu)
        defer { menu.delegate?.menuDidClose?(menu) }
        menu.update()  // asks each item whether it's on now
        return menu.items.flatMap { item -> [String] in
            // a divider as a line of its own, so a check can see where they fall (menu bar plan, 2026-11-14)
            guard !item.isSeparatorItem else { return [String(repeating: "  ", count: depth) + "-"] }
            var keys = item.keyEquivalent.isEmpty ? "" : " "
            if !item.keyEquivalent.isEmpty {
                let mask = item.keyEquivalentModifierMask
                keys += (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "")
                    + (mask.contains(.shift) ? "⇧" : "")
                    + (mask.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
            }
            // ticked, and its tip, for the inventory's Columns and Print (phase 1 fixes, finding 12)
            let line = String(repeating: "  ", count: depth) + item.title + keys + (item.isEnabled ? "" : " (off)")
                + (item.state == .on ? " [ticked]" : "") + (item.toolTip.map { " — tip: \($0)" } ?? "")
            return [line] + menuLines(item.submenu, depth: depth + 1)
        }
    }
    #endif

    #if PREPAREME_CHECK
    /// PREPAREME_CHECK_WINDOW_HEIGHT and _WIDTH (in `showFront`), applied as the window opens and again at the launch's
    /// dashboard; a second call finds the size already set
    func setCheckFrame() {
        let env = ProcessInfo.processInfo.environment
        if let window, env["PREPAREME_CHECK_WINDOW_HEIGHT"] != nil || env["PREPAREME_CHECK_WINDOW_WIDTH"] != nil {
            var frame = window.frame
            if let height = env["PREPAREME_CHECK_WINDOW_HEIGHT"].flatMap(Double.init) {
                frame.origin.y += frame.height - height
                frame.size.height = height
            }
            if let width = env["PREPAREME_CHECK_WINDOW_WIDTH"].flatMap(Double.init) { frame.size.width = width }
            window.setFrame(frame, display: true)
        }
    }
    #endif

    /// The dashboard at launch (owner, 2026-10-07: the app opens on it): Today, on the daily front page; not when a
    /// row was set since launch (a bookmark picked from the menu after a login launch opens the first window, whose
    /// launch would otherwise put Today over it).
    func showFront(_ front: URL) {
        guard !chosenSinceLaunch else { return }
        #if PREPAREME_CHECK
        // PREPAREME_CHECK_APPEARANCE=light, dark or red (the red night screen) on any screen (look 3 phase 6; it had
        // taken effect only beside a search or on Documents), chosen as PrepareMeDocuments' hook chooses it
        // PREPAREME_CHECK_WINDOW_HEIGHT=<points>: the main window that tall (the smallest PrepareMe allows is 500);
        // PREPAREME_CHECK_WINDOW_WIDTH=<points>: that wide (library redesign plan 3.2's 900 and 1400)
        setCheckFrame()
        if let look = ProcessInfo.processInfo.environment["PREPAREME_CHECK_APPEARANCE"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))  // after UserColorSchemeStore's init clears the key
                PrepareMeRedNight.shared.on = look == "red"
                let scheme: UserColorScheme = look == "light" ? .light : .dark
                UserDefaults.standard.set(scheme.rawValue, forKey: "userColorScheme")
                NSApp.appearance = scheme.asNSAppearance
            }
        }
        // The check build only: PREPAREME_CHECK_MENUS=<file in the check home> writes the menu bar's items, each with
        // its keys and whether it's on, for a check that can't open menus (the Apple guidelines plan, phase 2)
        // PREPAREME_CHECK_TIMING=<file in the check home>: the inventory's table timed (PrepareMeCheckTiming.swift)
        if let path = ProcessInfo.processInfo.environment["PREPAREME_CHECK_TIMING"] { PrepareMeCheckTiming.start(path) }
        if let path = ProcessInfo.processInfo.environment["PREPAREME_CHECK_MENUS"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                // its window in front first: the menus act on the window in front, and dim with none (macOS may refuse
                // while another app is in use; then Inventory's items read off here though they work)
                NSApp.activate()
                let window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
                window?.makeKeyAndOrderFront(nil)
                // the inventory's table holding the keyboard, as after a click: its menu items read their state from it
                if let window, let table = InventoryDetail.itemsTableView(in: window) { window.makeFirstResponder(table) }
                try? await Task.sleep(for: .seconds(2))
                // whether the menus could read the window: dimmed items with it not key say nothing about the code
                let head = "app active \(NSApp.isActive), window key \(window?.isKeyWindow == true)"
                try? ([head] + Self.menuLines(NSApp.mainMenu)).joined(separator: "\n").write(toFile: path, atomically: true,
                                                                                             encoding: .utf8)
            }
        }
        // The check build only: PREPAREME_CHECK_ROW=printableReferences opens on that screen, for a check that can't
        // click (screenshots only; 2026-10-21)
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "printableReferences" {
            row = .printableReferences
            return
        }
        // the entry redesign's check: Inventory's home page since phase 3; inventoryCategory its first category's table
        // (PrepareMeInventoryView.checkPick)
        if ["inventory", "inventoryCategory"].contains(ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"]) {
            row = .inventory
            return
        }
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "upkeep" {  // the upkeep check's flag line
            row = .inventoryList(.upkeep)  // its sidebar row since phase 3
            return
        }
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "toBuy" {  // look 3 phase 8's under-the-bar check
            row = .inventoryList(.toBuy)
            return
        }
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "toDo" {  // phase 4 fix round 1: its title
            row = .inventoryList(.toDo)
            return
        }
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "allItems" {  // phase 3: All Items' own row
            row = .inventoryList(.all)
            return
        }
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "games" {  // games plan phase 4's check
            Task { await show(.games) }
            return
        }
        // PREPAREME_CHECK_GAME=<path in the games file>: that page, as a click on the Games list opens it, and
        // PREPAREME_CHECK_GAME_DONE=<seconds> presses Done that long after (full-screen play's checks, games 3b)
        if let path = ProcessInfo.processInfo.environment["PREPAREME_CHECK_GAME"], let id = PrepareMeGamePlay.gamesID,
           let url = URL(zimFileID: id.uuidString, contentPath: path) {
            open(url)
            if let wait = ProcessInfo.processInfo.environment["PREPAREME_CHECK_GAME_DONE"].flatMap(Double.init) {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(wait))
                    PrepareMeGamePlay.shared.done()
                }
            }
            return
        }
        // News's marks (news plan Task 3.4): PREPAREME_CHECK_ROW=news opens the News page; PREPAREME_CHECK_NEWS_MARK=<a
        // mark's link> follows it 8 seconds later, as a click would; PREPAREME_CHECK_NEWS_MENU=<story id> opens a
        // story's right-click menu then (the check build can't right-click); PREPAREME_CHECK_NEWS_END=1 scrolls to the
        // page's end
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "news" {
            Task {
                await show(.news)
                try? await Task.sleep(for: .seconds(8))
                let check = ProcessInfo.processInfo.environment
                if let link = check["PREPAREME_CHECK_NEWS_MARK"].flatMap(URL.init(string:)), let mark = NewsMark.parse(link) {
                    PrepareMeNewsMarks.shared.handle(mark, in: browser(.guides).webView)
                }
                if let story = check["PREPAREME_CHECK_NEWS_MENU"], let view = browser(.guides).webView as? PrepareMeWebView {
                    view.popUpMarks(for: story)
                }
                if check["PREPAREME_CHECK_NEWS_END"] == "1" {  // the page's end: the marks and News's answers
                    _ = try? await browser(.guides).webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)")
                }
            }
            return
        }
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "documents" {  // Essential Documents' check
            row = .documents
            return
        }
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "library",  // Other libraries' check
           let first = MacLibraries.others(PrepareMeMac.shared.store.record.held,
                                           dailyFile: PrepareMeKeptTabs.dailyFile).first {
            Task { await show(.library(id: first.id)) }
            return
        }
        // The Library's checks (plan task 2.2): PREPAREME_CHECK_LIBRARY_SAVE=1 saves the starting placement (past the
        // first-launch sheet); PREPAREME_CHECK_ROW=shelf, shelf-new, shelf-unsorted or shelf-<category id> opens that
        // list; PREPAREME_CHECK_LIBRARY_BACK=<category id> opens its first collection, then presses Back
        let check = ProcessInfo.processInfo.environment
        if check["PREPAREME_CHECK_LIBRARY_SAVE"] == "1", PrepareMeLibraryShelf.shared.shelf == nil {
            var saved = LibraryShelf.starting
            for item in PrepareMeLibraryShelf.shared.items {
                saved.placed[item.key] = LibraryShelf.starting.category(for: item.key) ?? "reference"
            }
            PrepareMeLibraryShelf.shared.save(saved)
        }
        // Library redesign 4.2: PREPAREME_CHECK_LIBRARY_SUBS=<category id>:<name>,<name> gives that category those
        // subcategories, and deals the made-up collections (PREPAREME_CHECK_LIBRARY_ITEMS) among it and them
        if let spec = check["PREPAREME_CHECK_LIBRARY_SUBS"], let colon = spec.firstIndex(of: ":") {
            let parent = String(spec[..<colon])
            var seeded = PrepareMeLibraryShelf.shared.current
            var ids: [String] = []
            for name in spec[spec.index(after: colon)...].split(separator: ",").map(String.init) {
                if let (next, id) = seeded.addingSub(name: name, to: parent) {
                    seeded = next
                    ids.append(id)
                } else if let have = seeded.children(of: parent).first(where: { $0.name == name }) {
                    ids.append(have.id)  // seeded on an earlier launch
                }
            }
            let places = [parent] + ids
            for (n, item) in PrepareMeLibraryShelf.shared.items.filter({ $0.key.hasPrefix("made-up-") }).enumerated() {
                seeded = seeded.moving(key: item.key, to: places[n % places.count])
            }
            PrepareMeLibraryShelf.shared.save(seeded)
        }
        // Phase 3's: PREPAREME_CHECK_DOWNLOAD_KEPT=<file name> asks Which category? as a kept download would;
        // PREPAREME_CHECK_LIBRARY_EDIT=rename-<id> or remove-<id> opens that sheet (the right-click can't be clicked)
        if let name = check["PREPAREME_CHECK_DOWNLOAD_KEPT"] {
            let key = LibraryShelf.key(fileName: name)
            let title = PrepareMeLibraryShelf.shared.items.first { $0.key == key }?.title ?? "Made-up download"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                PrepareMeLibraryShelf.shared.ask(name: name, title: title)
            }
        }
        if check["PREPAREME_CHECK_DOWNLOAD_ROWS"] == "1" {  // library redesign plan 1.2
            PrepareMeDownloadRowView.showSamples()
        }
        // Library redesign 5.4: PREPAREME_CHECK_CATALOG=<pane> opens Add to Library on that pane (otherSites, downloads)
        if let pane = check["PREPAREME_CHECK_CATALOG"] {
            UserDefaults.standard.set(pane, forKey: "prepareme.mac.catalogPane.v2")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                PrepareMeMacTabs.shared.openWindowAction?(id: "catalog")
            }
        }
        // ...and collection-<file name> asks Remove…'s confirm for that collection (2026-11-13)
        if let edit = check["PREPAREME_CHECK_LIBRARY_EDIT"] {
            let id = String(edit.drop { $0 != "-" }.dropFirst())
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if edit.hasPrefix("describe-") {  // describe-<file name>: Edit Description… (library redesign plan 2.5)
                    let key = LibraryShelf.key(fileName: id)
                    let title = PrepareMeLibraryShelf.shared.items.first { $0.key == key }?.title ?? id
                    PrepareMeLibraryShelf.shared.sheet = .describe(key: key, title: title)
                } else if edit.hasPrefix("newsub-") {  // library redesign 4.3: New Subcategory… on that category
                    PrepareMeLibraryShelf.shared.sheet = .newSub(parent: id)
                } else if edit.hasPrefix("collection-") {
                    PrepareMeLibraryShelf.shared.removing = PrepareMeMac.shared.store.record.held[id]?.entry
                } else {
                    PrepareMeLibraryShelf.shared.sheet = edit.hasPrefix("rename-") ? .rename(id: id) : .remove(id: id)
                }
            }
        }
        if let list = check["PREPAREME_CHECK_ROW"], list.hasPrefix("shelf") {
            let rest = list.dropFirst("shelf".count)
            row = rest.isEmpty ? .shelf : rest == "-new" ? .shelfNew : rest == "-unsorted" ? .shelfUnsorted
                : .shelfCategory(id: String(rest.dropFirst()))
            return
        }
        if let id = check["PREPAREME_CHECK_LIBRARY_BACK"] {
            let shelf = PrepareMeLibraryShelf.shared
            if let first = shelf.current.grouped(shelf.items).first(where: { $0.category.id == id })?.items.first {
                row = .shelfCategory(id: id)
                openCollection(first.id, from: .shelfCategory(id: id))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(15))  // time for a capture of the collection first
                    _ = PrepareMeLibraryReturn.shared.goBack(at: browser(.guides).url)
                }
                return
            }
        }
        // PREPAREME_CHECK_LINK=<prepareme:// link>: the link opened as from outside (Our Home, Task 2.6), as `open` with
        // the link would reach the installed PrepareMe instead of the check build
        if let link = ProcessInfo.processInfo.environment["PREPAREME_CHECK_LINK"].flatMap(URL.init(string:)) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                _ = openAppLink(link)
            }
            return
        }
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "householdPages" {  // the Cancel check
            row = .householdPages
            return
        }
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_ROW"] == "streetMap",  // the street map fixes' check
           let link = URL(string: "prepareme://streetmap"), openAppLink(link) {
            return
        }
        // PREPAREME_CHECK_SETTINGS=general, household, library, phones, backups or about opens that tab (2026-10-23);
        // household-words opens Household at Your words for where you live, as the editor's button does (Our Home 1.3)
        if var tab = ProcessInfo.processInfo.environment["PREPAREME_CHECK_SETTINGS"] {
            if tab == "household-words" { tab = "household"; HouseholdPagesModel.shared.showOwnWords = true }
            NotificationCenter.default.post(name: .prepareMeSettings, object: MacStatus.Tab(rawValue: tab) ?? .general)
        }
        #endif
        row = .today
        let browser = browser(.today)
        if browser.url?.zimFileID != front.zimFileID || browser.url?.contentPath != front.contentPath {
            browser.load(url: front)
        }
    }

    /// A link, a search result or a bookmark: its row (Maps for a page of a map file, Today for the daily front page,
    /// Guides for any other) is selected and the page loads in that row's tab, the one on screen, once the library's
    /// copies are open.
    func open(_ url: URL) {
        if openAppLink(url) { return }  // a search result or bookmark of the Inventory page: the Inventory screen
        chosenSinceLaunch = true
        Task { [weak self] in
            guard let self else { return }
            await untilCopiesOpen()
            let front = await Self.mainPage(PrepareMeKeptTabs.dailyFile)
            let isFront = front.map { url.zimFileID == $0.zimFileID && url.contentPath == $0.contentPath } ?? false
            let isMap = PrepareMeKeptTabs.isMapFile(url, held: PrepareMeMac.shared.store.record.held)
            let isGame = PrepareMeMac.shared.store.record.held[MacLibraries.gamesFile]
                .map { url.zimFileID?.uuidString == $0.entry.id.uppercased() } ?? false
            let row: MacRow = isFront ? .today : isGame ? .games : .forLink(isMapFile: isMap)
            self.row = row
            if row == .maps {  // a map page shows on Find a map, never behind the street map
                UserDefaults.standard.set(MapsPane.find.rawValue, forKey: Self.mapsPaneKey)
            }
            if let reader = row.reader { browser(reader).load(url: url) }
        }
    }

    /// The guide list from the daily library (at launch and whenever the library is replaced). While its copy isn't
    /// open in Kiwix yet, the list and the row are left as they are; once it is, a missing or refused list is nil,
    /// and a category row it no longer has falls back to Guides.
    func refreshTopics() async {
        var read: GuideTopics?
        if let held = PrepareMeMac.shared.store.record.held[PrepareMeKeptTabs.dailyFile],
           let id = UUID(uuidString: held.entry.id) {
            guard await ZimFileService.shared.getMainPageURL(zimFileID: id) != nil else { return }  // not open yet
            let content = await ZimFileService.shared.getURLContent(zimFileID: id.uuidString,
                                                                    contentPath: GuideTopics.path)
            read = content.flatMap { try? GuideTopics($0.data) }
        }
        if read != topics { topics = read }
        guard copiesOpen else { return }  // the launch's own call, once they are, shows the row (blank-page fix)
        if !Self.listed(row, in: topics) {
            await show(.guides)
        } else if let reader = row.reader, browser(reader).url == nil {
            await show(row)  // the library has just arrived: the row's first page
        }
    }

    /// Whether the list still has a category or sub-category row (any other row always stands).
    static func listed(_ row: MacRow, in topics: GuideTopics?) -> Bool {
        switch row {
        case let .category(page):
            return topics?.topics.contains { $0.page == page } ?? false
        case let .sub(page, anchor):
            return topics?.topics.contains { $0.page == page && $0.subs.contains { $0.anchor == anchor } } ?? false
        case let .library(id):  // a library since removed, or replaced by a copy with a new ID
            return PrepareMeMac.shared.store.record.held.values.contains { $0.entry.id == id.uuidString }
        case .games:  // the games file since removed: Guides
            return PrepareMeMac.shared.store.record.held[MacLibraries.gamesFile] != nil
        default:
            return true
        }
    }

    static func mainPage(_ name: String) async -> URL? {
        guard let held = PrepareMeMac.shared.store.record.held[name], let id = UUID(uuidString: held.entry.id) else {
            return nil
        }
        return await ZimFileService.shared.getMainPageURL(zimFileID: id)
    }
}

/// The sidebar's places (R6.1; mockup 6): Today; one Guides row whose click opens the guide list and whose arrow shows
/// New and then the categories (Our household, the groups, each with its sub-categories, and For adults); Maps;
/// Inventory; Essential Documents; News as a row of its own; and Printable References (Edit Household Pages is in the File menu). `MacSidebar` (app/Service) holds the order
/// and the words. No row's words start "Open". Under them, the Other libraries section (owner, 2026-10-25), a row for
/// each library the Mac holds besides the daily one; none while it holds none.
struct PrepareMeMacSidebar: View {
    @ObservedObject private var tabs = PrepareMeMacTabs.shared
    @ObservedObject private var store = PrepareMeMac.shared.store
    @AppStorage(MacSidebar.guidesOpenKey) private var guidesOpen = MacSidebar.guidesOpenAtStart
    @ObservedObject private var shelf = PrepareMeLibraryShelf.shared
    @AppStorage(MacSidebar.shelfOpenKey) private var libraryOpen = true
    @AppStorage(MacSidebar.shelfFoldsKey) private var shelfFolds = ""  // categories unfolded, by id
    @AppStorage(MacSidebar.inventoryOpenKey) private var inventoryOpen = true  // the inventory fresh look, phase 3
    @State private var openGroups: Set<String> = []  // the groups unfolded, by page

    var body: some View {
        Group {
            // MacSidebar's order (MacRowsTests pins it): what the sidebar shows is that table, row by row
            ForEach(MacSidebar.topLevel, id: \.self) { row in topRow(row) }
        }
        .listItemTint(PrepareMeColors.ink)
        .onChange(of: tabs.row, initial: true) { _, row in
            // a row inside Guides picked elsewhere (or kept from last time) shows inside the open list
            switch row {
            case .new, .category: guidesOpen = true
            case let .sub(page, _):
                guidesOpen = true
                openGroups.insert(page)
            case .shelfNew, .shelfCategory, .shelfUnsorted: libraryOpen = true
            case .inventoryList: inventoryOpen = true
            default: break
            }
        }
    }

    /// A top-level row: Guides folds MacSidebar.insideGuides (New, then the list's categories; none when the library
    /// has no list) under its own row, which opens the guide list; every other row is its label alone.
    @ViewBuilder private func topRow(_ row: MacRow) -> some View {
        if row == .guides {
            let topics = tabs.topics?.topics ?? []
            DisclosureGroup(isExpanded: $guidesOpen) {
                ForEach(MacSidebar.insideGuides(pages: topics.map(\.page)), id: \.self) { inside in
                    if inside == .new {
                        newRow
                    } else if case let .category(page) = inside, let topic = topics.first(where: { $0.page == page }) {
                        group(topic)
                    }
                }
            } label: {
                rowLabel(row)
            }
        } else if row == .shelf {
            if !shelf.items.isEmpty { libraryRow }  // none while the Mac holds nothing besides the daily library
        } else if row == .games {
            if store.record.held[MacLibraries.gamesFile] != nil { rowLabel(row) }  // none until the games file arrives
        } else if row == .inventory {
            // folding as Library does to its five lists (the inventory fresh look, phase 3; spec 5.1); its own row
            // opens the home page, and clicked again while it shows, goes back to it (`tapped`)
            DisclosureGroup(isExpanded: $inventoryOpen) {
                PrepareMeMacInventoryRows()
            } label: {
                Label(MacSidebar.title(row) ?? "", systemImage: Self.symbol(row)).tag(row).modifier(Repick(row: row))
            }
            // the rows' counts need the inventory read, which only Inventory's screen did until phase 3: once here, not
            // once a row as on the rows' ForEach (fix round 1, finding 10)
            .task { InventoryModel.shared.open() }
        } else {
            rowLabel(row)
        }
    }

    /// The Library (owner, 2026-11-12), folding as Guides does: New (with its count while it lists any), every category
    /// under its emoji (an empty one too, for its right-click), then Needs a category while any file has none. Its own row opens the whole list.
    @ViewBuilder private var libraryRow: some View {
        let current = shelf.current
        let fresh = LibraryShelf.newItems(shelf.items, now: Date()).count
        DisclosureGroup(isExpanded: $libraryOpen) {
            let new = Label(MacSidebar.title(.shelfNew) ?? "", systemImage: Self.symbol(.shelfNew))
            if fresh > 0 {
                new.badge(fresh).tag(MacRow.shelfNew).modifier(Repick(row: .shelfNew))
            } else {
                new.tag(MacRow.shelfNew).modifier(Repick(row: .shelfNew))
            }
            // every category, an empty one too, so it can be renamed or deleted (owner, 2026-11-12)
            ForEach(current.categories.filter { $0.parent == nil }) { category in
                shelfCategory(category, subs: current.children(of: category.id))
            }
            if !current.unsorted(shelf.items).isEmpty {
                shelfLabel(.shelfUnsorted)
            }
        } label: {
            shelfLabel(.shelf)
        }
        .onAppear { unfoldPicked() }
        .onChange(of: tabs.sidebarRow) { unfoldPicked() }
    }

    /// A Library category's row; one with subcategories folds them under it, one step in as Guides' are (library
    /// redesign plan 4.2), each opening its category's page at its heading.
    @ViewBuilder private func shelfCategory(_ category: LibraryShelf.Category, subs: [LibraryShelf.Category]) -> some View {
        let row = Label { Text(category.name) } icon: { Text(category.emoji).accessibilityHidden(true) }
            .tag(MacRow.shelfCategory(id: category.id))
            .modifier(Repick(row: .shelfCategory(id: category.id)))
            .contextMenu {  // the owner's edits, on the Mac only (Library plan 3.2)
                Button("New Subcategory…") { shelf.sheet = .newSub(parent: category.id) }  // library redesign 4.3
                Button("Rename…") { shelf.sheet = .rename(id: category.id) }
                Divider()
                PMMenuDelete("Delete…") { shelf.sheet = .remove(id: category.id) }
            }
        if subs.isEmpty {
            row
        } else {
            // open as the owner left it; picking one of its subcategories opens it (`unfoldPicked`), and it still closes
            DisclosureGroup(isExpanded: Binding(get: { MacSidebar.shelfFolds(shelfFolds).contains(category.id) },
                                                set: { open in fold(category.id, open: open) })) {
                ForEach(subs) { sub in
                    Text(sub.name)
                        .padding(.leading, Self.subIndent)
                        .tag(MacRow.shelfCategory(id: sub.id))
                        .modifier(Repick(row: .shelfCategory(id: sub.id)))
                        .contextMenu {
                            Button("Rename…") { shelf.sheet = .rename(id: sub.id) }
                            Divider()
                            PMMenuDelete("Delete…") { shelf.sheet = .remove(id: sub.id) }
                        }
                }
            } label: {
                row
            }
        }
    }

    private func fold(_ id: String, open: Bool) {
        var ids = MacSidebar.shelfFolds(shelfFolds).filter { $0 != id }
        if open { ids.append(id) }
        shelfFolds = MacSidebar.shelfFolds(ids)
    }

    /// A subcategory picked (in the sidebar, from a tile, or kept from the last launch) unfolds its category, so the
    /// pick shows; the sidebar's row, so opening one of its collections keeps it open (phase 4 review).
    private func unfoldPicked() {
        guard case let .shelfCategory(id) = tabs.sidebarRow,
              let parent = shelf.current.categories.first(where: { $0.id == id })?.parent,
              !MacSidebar.shelfFolds(shelfFolds).contains(parent) else { return }
        fold(parent, open: true)
    }

    /// Library's own row and Needs a category: no reader, but clicked while one of their collections shows they open
    /// their list again (`tapped`)
    private func shelfLabel(_ row: MacRow) -> some View {
        Label(MacSidebar.title(row) ?? "", systemImage: Self.symbol(row)).tag(row).modifier(Repick(row: row))
    }

    /// A top-level row's words (MacSidebar.title, which every top-level row has) and symbol. A row with a reader
    /// (Today, Guides, Maps, News) reloads its page when picked again (Repick); Inventory and Edit household pages are
    /// the app's own screens.
    @ViewBuilder private func rowLabel(_ row: MacRow) -> some View {
        let label = Label(MacSidebar.title(row) ?? "", systemImage: Self.symbol(row)).tag(row)
        if row.reader != nil {
            label.modifier(Repick(row: row))
        } else {
            label
        }
    }

    private static func symbol(_ row: MacRow) -> String {
        switch row {
        case .today: return "sun.max"
        case .guides: return "book"
        case .maps: return "map"
        case .inventory: return "shippingbox"
        case .news: return "newspaper"  // step 7; R6.1
        case .householdPages: return "house"  // phase C
        case .printableReferences: return "printer"  // the card and the binder (2026-10-21)
        case .documents: return "lock.doc"  // Essential Documents (2026-10-24)
        case .new: return "sparkles"
        case .category, .sub: return "folder"
        case .library, .shelf: return "books.vertical"
        case .games: return "gamecontroller"
        case .shelfNew: return "sparkles"
        case .shelfCategory: return "folder"
        case .shelfUnsorted: return "questionmark.folder"
        case .inventoryList(let list): return PrepareMeMacInventoryRows.symbol(list)
        }
    }

    @ViewBuilder private var newRow: some View {
        let count = tabs.topics?.newCount ?? 0
        let label = Label(MacSidebar.title(.new) ?? "", systemImage: Self.symbol(.new))
        if count > 0 {
            label.badge(count).tag(MacRow.new).modifier(Repick(row: .new))
        } else {
            label.tag(MacRow.new).modifier(Repick(row: .new))
        }
    }

    /// A group with sub-categories folds them under its own row (which opens its page); one without is a plain row.
    @ViewBuilder private func group(_ topic: GuideTopics.Topic) -> some View {
        if topic.subs.isEmpty {
            groupLabel(topic.name).tag(MacRow.category(page: topic.page))
                .modifier(Repick(row: .category(page: topic.page)))
        } else {
            DisclosureGroup(isExpanded: Binding(get: { openGroups.contains(topic.page) }, set: { open in
                if open { openGroups.insert(topic.page) } else { openGroups.remove(topic.page) }
            })) {
                ForEach(topic.subs, id: \.anchor) { sub in
                    Text(sub.name)
                        .padding(.leading, Self.subIndent)  // one step in from its group's words, not left of them
                        .tag(MacRow.sub(page: topic.page, anchor: sub.anchor))
                        .modifier(Repick(row: .sub(page: topic.page, anchor: sub.anchor)))
                }
            } label: {
                groupLabel(topic.name).tag(MacRow.category(page: topic.page))
                    .modifier(Repick(row: .category(page: topic.page)))
            }
        }
    }

    /// A group's row: its emoji before its name, as the guide list draws it (A4; owner, 2026-10-18), hidden from
    /// VoiceOver as the guide list hides it; a group without one (Other, For adults) keeps its symbol.
    @ViewBuilder private func groupLabel(_ name: String) -> some View {
        if let mark = MacLook.emoji(name) {
            Label { Text(name) } icon: { Text(mark).accessibilityHidden(true) }
        } else {
            Label(name, systemImage: MacLook.symbol(name))
        }
    }

    /// A sub-category's words start this far past the list's own indent: the group's icon is about 18 points wide plus
    /// its gap, and a step more puts them inside their group's words as the group's sit inside Guides.
    static let subIndent: CGFloat = 30

    /// A row's click, beside the list's own selection (which a click on the row already picked doesn't change): a
    /// reading row picked again goes back to its page's top, or a sub-category's heading (`PrepareMeMacTabs.tapped`).
    private struct Repick: ViewModifier {
        let row: MacRow

        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)  // the whole row, not only its words (fix round 1)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { PrepareMeMacTabs.shared.tapped(row) })
        }
    }
}

/// The five rows inside Inventory's fold (the inventory fresh look, phase 3; spec 5.1), each with its count as a badge
/// where it had one in the old list column (All Items, To Buy, Expiring Soon, To Do), above 0 and once the inventory
/// is read. Its own view, so the model's reads redraw these rows and not the whole sidebar.
struct PrepareMeMacInventoryRows: View {
    @ObservedObject private var model = InventoryModel.shared

    var body: some View {
        ForEach(MacSidebar.inventoryRows, id: \.self) { row in
            if case .inventoryList(let list) = row {
                let label = Label(MacSidebar.title(row) ?? "", systemImage: Self.symbol(list))
                if let count = count(list), count > 0 {
                    label.badge(count).tag(row)
                } else {
                    label.tag(row)
                }
            }
        }
    }

    /// The old list column's symbols for the same rows.
    static func symbol(_ list: MacInventoryList) -> String {
        switch list {
        case .all: "shippingbox"
        case .toBuy: "cart"
        case .expiringSoon: "calendar.badge.exclamationmark"
        case .toDo: "checklist"
        case .upkeep: "arrow.triangle.2.circlepath"
        }
    }

    /// nil until the inventory (or, for To Do, the lists) is read, and for Upkeep, which had no count.
    func count(_ list: MacInventoryList) -> Int? {
        guard case .ready(let inventory) = model.state else { return nil }
        switch list {
        case .all: return inventory.itemRows.count
        case .toBuy: return model.toBuy?.items.count
        case .expiringSoon: return inventory.items(in: .expiringSoon).count
        case .toDo: return inventory.lists?.rows(ListsLayout.todo).count
        case .upkeep: return nil
        }
    }
}

/// Maps, as the phone's Maps tab (plan phase 9): a Find a map | Street map switch, in the band at the window's top
/// since look 3 (Task 6.1; the phone's sits on its band too), over them. Find a map is the maps reader tab (`find`),
/// Street map the street map and its rally points and routes, toolbar included.
struct PrepareMeMacMaps<Find: View>: View {
    @AppStorage(PrepareMeMacTabs.mapsPaneKey) private var pane = MapsPane.find.rawValue
    @ViewBuilder let find: () -> Find

    var body: some View {
        Group {
            if pane == MapsPane.street.rawValue {
                PrepareMeStreetMapView().pmMacWindow()
            } else {
                find()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Maps", selection: $pane) {
                    Text("Find a map").tag(MapsPane.find.rawValue)
                    Text("Street map").tag(MapsPane.street.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// The window's warnings, at the sidebar's bottom, folded (owner, 2026-11-13: out of the bar across the window's top,
/// which reverses the 2026-10-22 choice): closed, it says Needs attention and how many problems; open, every line, and
/// Open Settings… on the Settings tab the first line is on (2026-10-23). The app's own line first, then any device's
/// update that lost something (the update self-check) or whose opening check found a problem, then the failure notice's (the banner's problems; owner,
/// 2026-10-27, by click), each once. Gone when there is no problem.
struct PrepareMeAttentionBar: View {
    @ObservedObject private var mac = PrepareMeMac.shared
    @ObservedObject private var sync = PrepareMeMac.shared.sync
    @ObservedObject private var store = PrepareMeMac.shared.store
    @ObservedObject private var inventory = InventoryModel.shared
    @ObservedObject private var backup = PrepareMeBackup.shared
    @ObservedObject private var conditions = PrepareMeStatus.shared
    @ObservedObject private var pairing = PhonePairing.shared
    @State private var open = false  // closed by default (owner, 2026-11-13)

    /// A line for each paired device whose last room report says its update lost something (the update self-check,
    /// owner, 2026-11-14), until its next build
    private var updates: [String] {
        (pairing.phones ?? []).compactMap { phone in
            let room = pairing.rooms[phone.label]
            let named = pairing.name(for: phone)
            return UpdateCheck.macLine(name: named.isEmpty ? phone.label : named, build: room?.build, room?.update)
        }
    }

    /// A line for each paired device whose last opening check found a problem (the opening self-check, Task 2.2), until
    /// a clean opening's report replaces it; the Devices card shows the same line
    private var openings: [String] {
        (pairing.phones ?? []).compactMap { phone in
            let named = pairing.name(for: phone)
            return OpeningCheck.macLine(name: named.isEmpty ? phone.label : named, pairing.rooms[phone.label]?.opening)
        }
    }

    /// The library's first problem, else a Keep Conditions Fresh for 6 Hours or Check Conditions Once that couldn't be
    /// sent (its line sat under the sidebar's buttons until phase 3; the review, 2026-10-22: a tooltip alone hid it).
    private var attention: (line: String, tab: MacStatus.Tab)? {
        library ?? (conditions.line == PrepareMeStatus.notSent ? (PrepareMeStatus.notSent, .library) : nil)
            ?? (updates + openings).first.map { ($0, .phones) } ?? mac.notice.first.map { ($0, .library) }
    }

    /// The first line, then the devices' update lines and the notice's others, each once, with the tab each is about
    private var all: [(line: String, tab: MacStatus.Tab)] {
        var seen = Set<String>()
        return ([attention].compactMap { $0 } + (updates + openings).map { ($0, .phones) } + mac.notice.map { ($0, .library) })
            .filter { seen.insert($0.line).inserted }
    }

    private var library: (line: String, tab: MacStatus.Tab)? {
        MacStatus.attentionLine(problem: sync.problem,
                                refusal: MacStatus.refusalLine(store.lastRefusal, store.record),
                                service: MacStatus.serviceProblem(mac.service), skipped: mac.skipped,
                                backup: BackupWords.attention(backup.status, upload: backup.upload),
                                drive: DriveBackup.attention(mac.drive.status, installed: mac.drive.installed,
                                                             now: Date()),
                                phones: inventory.phoneProblem)
    }

    var body: some View {
        if let attention {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    // each line opens Settings on the tab it is about (Mac Settings plan, 2026-11-14), drawn as
                    // PrepareMeStatusLines draws them
                    ForEach(all, id: \.line) { warning in
                        Button {
                            NotificationCenter.default.post(name: .prepareMeSettings, object: warning.tab)
                        } label: {
                            Text(warning.line)
                                .font(.pmNote)
                                .foregroundStyle(PMMessageKind.attention.color)
                                .multilineTextAlignment(.leading)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .help("Opens Settings on this warning's tab")
                    }
                    Button("Open Settings…") {
                        NotificationCenter.default.post(name: .prepareMeSettings, object: attention.tab)
                    }
                    .help("PrepareMe's settings, on the tab the first line is on")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                HStack(spacing: 8) {  // look 3's amber warning sign and words (spec section 10, rule 4)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PrepareMeColors.accent)
                        .accessibilityHidden(true)
                    Text("Needs attention").font(.pmHeadline).foregroundStyle(PrepareMeColors.caution)
                    Spacer()
                    Text("\(all.count)").font(.pmHeadline).monospacedDigit().foregroundStyle(PrepareMeColors.caution)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { open.toggle() } }  // the whole row opens it, not only the arrow
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Needs attention, \(all.count)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(PrepareMeColors.accentBg, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
            #if PREPAREME_CHECK
            .task {  // PREPAREME_CHECK_SHOW_ALL=1 opens it (screenshots only, no clicks)
                if ProcessInfo.processInfo.environment["PREPAREME_CHECK_SHOW_ALL"] != nil {
                    try? await Task.sleep(for: .seconds(2))
                    open = true
                }
            }
            #endif
        }
    }
}

/// A screen's own list column beside it (Household pages' pages, the street map's marks with no map yet; Inventory's
/// tables and views had one until the inventory fresh look's phase 3 gave it a home page): a toolbar button and View ›
/// Hide List hide it (the Apple guidelines plan, phase 7; owner, 2026-10-22, by click: no hiding by itself as the
/// window narrows). One setting for both screens.
struct ListColumnSplit<Column: View, Content: View>: View {
    @ViewBuilder let column: () -> Column
    @ViewBuilder let content: () -> Content
    @AppStorage(ListColumn.shownKey) private var shown = true

    var body: some View {
        HSplitView {
            if shown { column() }
            content()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { shown.toggle() } label: {  // a list's picture, not the sidebar button's beside it
                    Label(shown ? "Hide List" : "Show List", systemImage: "list.bullet")
                }
                .help(shown ? "Hide the list" : "Show the list")
            }
        }
        .focusedSceneValue(\.hasListColumn, true)
    }
}

enum ListColumn {
    static let shownKey = "prepareme.mac.listColumn"
}

private struct HasListColumnKey: FocusedValueKey { typealias Value = Bool }

/// File › Save (⌘S; look 3, change 18): the save of the screen showing, published by Printable References' card and
/// the household page editor with `focusedSceneValue`; nil on every other screen, where Save is dimmed.
struct MacSave {
    let enabled: Bool
    let run: () -> Void
}

private struct MacSaveKey: FocusedValueKey { typealias Value = MacSave }

extension FocusedValues {
    /// Whether the screen showing has a list column (nil on every other screen)
    var hasListColumn: Bool? {
        get { self[HasListColumnKey.self] }
        set { self[HasListColumnKey.self] = newValue }
    }
    var macSave: MacSave? {
        get { self[MacSaveKey.self] }
        set { self[MacSaveKey.self] = newValue }
    }
}

/// View › Hide List (⌃⌘L), beside Hide Sidebar; dimmed on a screen without a list column.
struct ListColumnCommands: Commands {
    @AppStorage(ListColumn.shownKey) private var shown = true
    @FocusedValue(\.hasListColumn) private var hasListColumn

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(shown ? "Hide List" : "Show List") { shown.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(hasListColumn != true)
        }
    }
}

/// Event mode's switch, first in the sidebar (the owner's choice, 2026-10-22: out of the sidebar's bottom); kept in
/// the lists, so it shows once they're read.
struct PrepareMeMacEventMode: View {
    @ObservedObject private var inventory = InventoryModel.shared
    @ObservedObject private var redNight = PrepareMeRedNight.shared

    var body: some View {
        if inventory.lists != nil {  // plan phase 7, part 2: the switch, kept in the lists
            HStack {
                Text("Event mode").font(.pmHeadline)
                Spacer()
                EventModePicker().fixedSize()
            }
        } else {  // look 3: grayed with why, never missing (spec section 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("Event mode").font(.pmHeadline)
                Text(StateWords.eventModeWaiting).font(.pmNote)
            }
            .foregroundStyle(redNight.on ? PrepareMeColors.ink : PrepareMeColors.text2)  // red night's layer: gray fell to 3.34:1
            .accessibilityElement(children: .combine)
        }
    }
}

/// Today's toolbar: Keep Conditions Fresh for 6 Hours, the View menu's first Conditions item (look 3, change 21);
/// its last answer in the tooltip.
private struct RefreshConditionsButton: View {
    @ObservedObject private var status = PrepareMeStatus.shared

    var body: some View {
        Button { PrepareMeRequests.pressFromMenu(.refresh) } label: {
            Label("Keep Conditions Fresh for 6 Hours", systemImage: "arrow.clockwise")
        }
        .help(status.line ?? "Ask the Mac's job for fresh weather, alerts and roads every 15 minutes for the next 6 hours")
    }
}

/// A reading row's page: its Kiwix tab. A page of a map file reached from Today or Guides (the front page's Maps
/// link, any map) moves to Maps, and this tab goes back to where it was, as on the phone.
struct PrepareMeMacReader: View {
    let reader: MacRow.Reader
    @ObservedObject private var browser: BrowserViewModel

    init(reader: MacRow.Reader) {
        self.reader = reader
        browser = PrepareMeMacTabs.shared.browser(reader)
    }

    var body: some View {
        BrowserTab(tabID: browser.tabID)
            .id(browser.tabID)
            .modifier(PrepareMeNewsMarksAsk())  // the News page's marks: Take Down…'s question, the missed sheet
            .toolbar {  // Today's own: the conditions, out of the sidebar (the Apple guidelines plan, phase 3)
                if reader == .today { ToolbarItem(placement: .primaryAction) { RefreshConditionsButton() } }
            }
            .onAppear { PrepareMeGamePlay.shared.watch(browser) }  // full-screen play follows the page on screen
            .onDisappear { PrepareMeGamePlay.shared.unwatch(browser) }
            .onChange(of: browser.url) { _, url in
                guard reader != .maps, let url,
                      PrepareMeKeptTabs.isMapFile(url, held: PrepareMeMac.shared.store.record.held) else { return }
                PrepareMeMacTabs.shared.open(url)
                browser.webView.goBack()
            }
    }
}
#endif
