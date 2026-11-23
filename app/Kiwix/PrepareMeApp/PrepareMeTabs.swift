// This file is part of PrepareMe, a local build of Kiwix for one household's phones (the phone's tab bar, owner
// 2026-10-14) and Mac (its kept tabs, Mac sidebar plan, part 2).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Combine
import CoreData
import Foundation
import PrepareMeShared
import SwiftUI

/// The Kiwix tabs (Core Data `Tab`s) PrepareMe keeps for its reading places, on the phone (PrepareMeTabs) and on the
/// Mac (PrepareMeMacTabs, Mac sidebar plan, part 2), each kept by its address in the defaults under a key of its own,
/// so a place keeps its page and its back history. One that has gone (Kiwix drops a tab whose file was removed) is made
/// again, empty.
@MainActor
enum PrepareMeKeptTabs {
    static let dailyFile = "prepareme-daily.zim"
    static let overviewFile = "prepareme-maps-topo-overview.zim"  // Find a map beside its front page (map_pages P7)
    static let guidesPage = "guides.html"  // packer GUIDES_PAGE, beside the daily front page

    /// Maps' first page on the Mac and the phone (phase L, finding 1): Find a map beside the topo overview's front
    /// page `main` (a title and two links), or that front page when the file holds no Find a map (TopoIndex.firstPage).
    static func findAMap(beside main: URL) async -> URL {
        await TopoIndex.firstPage(beside: main) { await ZimFileService.shared.getContentSize(url: $0) != nil }
    }

    private static var ids: [String: NSManagedObjectID] = [:]

    static func tabID(key: String) -> NSManagedObjectID {
        let context = Database.shared.viewContext
        if let known = ids[key], (try? context.existingObject(with: known)) != nil { return known }
        if let address = UserDefaults.standard.url(forKey: key),
           let id = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: address),
           (try? context.existingObject(with: id)) != nil {
            ids[key] = id
            return id
        }
        let made = NavigationViewModel.makeTab(context: context)
        UserDefaults.standard.set(made.objectID.uriRepresentation(), forKey: key)
        ids[key] = made.objectID
        return made.objectID
    }

    /// Whether a page is in one of the map files (they open on Maps): its library ID is a held `prepareme-maps…` file's.
    static func isMapFile(_ url: URL, held: [String: HeldFile]) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return held.values.contains { $0.entry.name.hasPrefix("prepareme-maps") && $0.entry.id.lowercased() == host }
    }

    /// An item's manual (PhoneInventory.Row.manual, top-ten plan, phase 7) in the manuals library this device holds,
    /// opened in Guides; nil while that library, or the copy of it holding this manual, isn't here yet.
    static func manualURL(_ path: String, held: [String: HeldFile]) async -> URL? {
        guard let library = held.values.first(where: { $0.entry.id.lowercased() == ItemManuals.volumeID }),
              let url = URL(zimFileID: library.entry.id, contentPath: path),
              await ZimFileService.shared.getContentSize(url: url) != nil else { return nil }
        return url
    }

    /// The daily library's guide links (phase 14, F57; GuideLinks), for an item's "How to use it"; nil while this
    /// device hasn't opened the daily library, or its list is missing or refused.
    static func guideLinks(held: [String: HeldFile]) async -> GuideLinks? {
        guard let id = held[dailyFile].flatMap({ UUID(uuidString: $0.entry.id) }),
              let content = await ZimFileService.shared.getURLContent(zimFileID: id.uuidString,
                                                                      contentPath: GuideLinks.path)
        else { return nil }
        return try? GuideLinks(content.data)
    }

    /// A guide's page in the daily library, opened in Guides.
    static func guideURL(_ page: String, held: [String: HeldFile]) -> URL? {
        held[dailyFile].flatMap { URL(zimFileID: $0.entry.id, contentPath: page) }
    }

    /// The daily library's calculator links (step 8b; CalculatorLinks), for the Calculators line at the top of an
    /// inventory category; nil while this device hasn't opened the daily library, or its list is missing or refused.
    static func calculatorLinks(held: [String: HeldFile]) async -> CalculatorLinks? {
        guard let id = held[dailyFile].flatMap({ UUID(uuidString: $0.entry.id) }),
              let content = await ZimFileService.shared.getURLContent(zimFileID: id.uuidString,
                                                                      contentPath: CalculatorLinks.path)
        else { return nil }
        return try? CalculatorLinks(content.data)
    }

    /// A calculator's page in the daily library with the lists job's figures in its `#` part, which stays on this
    /// device (the page's own script reads it), opened in Guides.
    static func calculatorURL(_ link: CalculatorLinks.Line.Link, held: [String: HeldFile]) -> URL? {
        guard let page = guideURL(link.calculator.page, held: held) else { return nil }
        return link.fragment.isEmpty ? page : URL(string: page.absoluteString + "#" + link.fragment)
    }
}

/// The Calculators line at the top of an inventory category (step 8b; CalculatorLinks): each calculator opens its page
/// filled in from the lists job's count, and the notes under it say when that count was made and, when a propane or
/// gasoline row was left out for its unit, that only pounds or gallons are included. On the phone a section of buttons, as How to use it; on the Mac a line of links
/// above the table. The caller reads the links (PrepareMeKeptTabs.calculatorLinks) where a task always runs.
struct CalculatorsLine: View {
    let line: CalculatorLinks.Line
    let held: [String: HeldFile]
    let open: (URL) -> Void

    var body: some View {
        #if os(iOS)
        Section(pmTitle: CalculatorLinks.line) {
            ForEach(line.links, id: \.calculator.page) { link in
                if let url = PrepareMeKeptTabs.calculatorURL(link, held: held) {
                    Button { open(url) } label: { Label(link.calculator.name, systemImage: "function") }
                        .pmAction()
                }
            }
            ForEach(line.notes, id: \.self) { Text($0).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
        }
        #else
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("\(CalculatorLinks.line): ").foregroundStyle(PrepareMeColors.text2)
                ForEach(Array(line.links.enumerated()), id: \.element.calculator.page) { n, link in
                    if let url = PrepareMeKeptTabs.calculatorURL(link, held: held) {
                        Button { open(url) } label: { Text(link.calculator.name).underline() }  // reads as a link
                            .buttonStyle(.link)
                            .foregroundStyle(PrepareMeColors.ink)
                            .help("Open the calculator in Guides")
                    } else {
                        Text(link.calculator.name)  // the daily library isn't open here yet
                    }
                    if n < line.links.count - 1 { Text(", ").foregroundStyle(PrepareMeColors.text2) }
                }
            }
            ForEach(line.notes, id: \.self) { Text($0).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #endif
    }
}

/// An item's "How to use it" (phase 14, F57): a button for each guide whose words its name holds, on the phone's item
/// page and the Mac's item form. The caller reads the links (PrepareMeKeptTabs.guideLinks) where a task always runs.
struct HowToUseButtons: View {
    let guides: [GuideLinks.Guide]
    let held: [String: HeldFile]
    let open: (URL) -> Void

    var body: some View {
        ForEach(guides, id: \.page) { guide in
            if let url = PrepareMeKeptTabs.guideURL(guide.page, held: held) {
                Button { open(url) } label: {
                    Label("\(GuideLinks.howToUse): \(guide.title)", systemImage: "book.pages")
                }
                .pmAction()
            }
        }
    }
}

#if os(iOS)
/// The phone's five places (owner, 2026-10-14: a tab bar always at the bottom, every main place one tap; one page a
/// tab, no Kiwix tab switcher). Today, Guides and Maps each read in a Kiwix tab of their own, so each keeps its page and
/// its back history when you switch away; Inventory and Home Mac are PrepareMe's own screens. An adult's phone or iPad
/// has Documents too (Essential Documents, owner 2026-10-24): on an iPhone in Home Mac's place, Home Mac then a button
/// at the top right of each tab; on an iPad a sixth tab.
enum PrepareMeTab: String, CaseIterable, Hashable {
    case today, guides, maps, inventory, documents, homeMac

    static let reading: [PrepareMeTab] = [.today, .guides, .maps]

    /// The tab's name, for the tab bar and the iPad's View menu alike.
    var title: String {
        switch self {
        case .today: "Today"
        case .guides: "Guides"
        case .maps: "Maps"
        case .inventory: "Inventory"
        case .documents: "Documents"
        case .homeMac: "Downloads"
        }
    }

    /// Home Mac as a button in each tab's bar, not a tab: an adult's iPhone.
    @MainActor static var homeMacInBar: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && PhoneDocumentsModel.shared.adult
    }

    /// The tabs in the bar, in its order.
    @MainActor static var shown: [PrepareMeTab] {
        allCases.filter { tab in
            switch tab {
            case .documents: PhoneDocumentsModel.shared.adult
            case .homeMac: !homeMacInBar
            default: true
            }
        }
    }
}

/// The iPad's View menu: a tab each, ⌘1 to ⌘5 (⌘6 with Documents) in the tab bar's order, Find in Page ⌘F and Search ⇧⌘F as on the Mac
/// (F50; the audit, 2026-10-22, and its review). Holding ⌘ lists them.
struct PrepareMeTabCommands: View {
    @ObservedObject private var tabs = PrepareMeTabs.shared

    var body: some View {
        ForEach(Array(PrepareMeTab.shown.enumerated()), id: \.offset) { n, tab in
            Button(tab.title) { tabs.selected = tab }
                .keyboardShortcut(KeyEquivalent(Character(String(n + 1))), modifiers: .command)
        }
        Button("Find in Page") {  // the find bar the page menu's own item opens (ContentSearchButton)
            let page = tabs.browser(tabs.selected).webView
            page.isFindInteractionEnabled = true
            page.findInteraction?.presentFindNavigator(showingReplace: false)
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(!PrepareMeTab.reading.contains(tabs.selected) || PrepareMeTabs.onStreetMap)
        Button("Search") { tabs.searchRequest = tabs.selected }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(![.today, .guides].contains(tabs.selected))  // the two with a search box (Maps has none)
    }
}

/// Which tab shows, and the Kiwix tab (a Core Data `Tab`) behind each reading tab, kept by its address in the
/// defaults. One that has gone (Kiwix drops a tab whose file was removed) is made again, empty.
@MainActor
final class PrepareMeTabs: ObservableObject {
    static let shared = PrepareMeTabs()

    /// The tab last on screen, so the app reopens where it was left (the street map fixes plan, task 3.4): a street
    /// map left open is there again after the phone drops the app. A link that opens the app picks its own.
    @Published var selected = PrepareMeTab(rawValue: UserDefaults.standard.string(forKey: "prepareme.lastTab") ?? "")
        ?? .today {
        didSet {
            UserDefaults.standard.set(selected.rawValue, forKey: "prepareme.lastTab")
            if selected == .maps, oldValue != .maps { reopenMaps() }  // opening Maps, never while it is shown
        }
    }
    /// A big iPhone's Search above the tab bar asks the tab on screen to open its search (Task 10.7; F33, F67), and each
    /// reading tab says whether its search is open, so the button hides while it is.
    @Published var searchRequest: PrepareMeTab?
    /// Home Mac's sheet, from the button in each tab's bar (an adult's iPhone).
    @Published var homeMacSheet = false

    /// "Open Home Mac": its sheet where Home Mac is a button, else its tab (HomeMacRoute; look 3 phase 0, question 7).
    func openHomeMac() {
        switch HomeMacRoute.opens(inBar: PrepareMeTab.homeMacInBar) {
        case .sheet: homeMacSheet = true
        case .tab: selected = .homeMac
        }
    }
    @Published var searching: [PrepareMeTab: Bool] = [:]
    static let searchAtBottom = OneHand.searchAtBottom(  // the screen's long side, whichever way the phone is held
        phone: UIDevice.current.userInterfaceIdiom == .phone,
        screenHeight: max(UIScreen.main.bounds.height, UIScreen.main.bounds.width))

    /// Asks the reading tab's page to show its bar and Back, Search and the menus (WebViewController takes it).
    static func showBars(of browser: BrowserViewModel) {
        NotificationCenter.default.post(name: showBarsNotice, object: browser.webView)
    }
    static let showBarsNotice = Notification.Name("prepareme.showBars")

    /// Whether Maps is on its Street map side, where the reading tab's page is hidden behind the map.
    static var onStreetMap: Bool {
        shared.selected == .maps && mapsSide == .street
    }

    /// The side Maps is on: the one picked, else the street map on a child's phone and Find a map on an adult's
    /// (MapsFirstSide; beta run 2, B2-22).
    static var mapsSide: MapsSide { shared.mapsSide }

    /// Settled the first time Maps is looked at in a launch, never swapped under the person after (MapsSideState).
    var mapsSide: MapsSide {
        if let side = mapsState.side { return side }  // settled: the stored side and the role aren't read again
        return mapsState.resolve(stored: UserDefaults.standard.string(forKey: "prepareme.mapsPane"),
                                 isChild: PhoneInventoryModel.shared.isChild)
    }
    private var mapsState = MapsSideState()

    /// Maps is being opened: if the role arrived since its side was settled (a phone paired before the Mac said whose
    /// it is), the side follows it now (MapsSideState.reopen; B3-04).
    private func reopenMaps() {
        let stored = UserDefaults.standard.string(forKey: "prepareme.mapsPane")
        if mapsState.reopen(stored: stored, isChild: PhoneInventoryModel.shared.isChild) { mapsSideChanged += 1 }
    }
    @Published private(set) var mapsSideChanged = 0  // redraws the Maps tab when a side is picked

    /// A side picked, or a page opened in Maps: kept for the run, and stored for an adult's next launch (a child's
    /// stored side is ignored at launch, so a topo map opened from a link never keeps Maps off the street map).
    func setMapsSide(_ side: MapsSide) {
        mapsState.pick(side)
        UserDefaults.standard.set(side.rawValue, forKey: "prepareme.mapsPane")
        mapsSideChanged += 1
    }

    static func searchPrompt(_ tab: PrepareMeTab) -> String { tab == .guides ? "Search guides" : "Search" }

    /// Whether the Search above the tab bar shows: a big iPhone, on Today or Guides, its search not already open.
    var showsBottomSearch: Bool {
        Self.searchAtBottom && [.today, .guides].contains(selected) && searching[selected] != true
    }
    /// An area the street map should show next (west, south, east, north): a topo map's "Show on street map".
    @Published var streetMapFit: [Double]?
    /// The Library's collections (Library plan, phase 4): every held file besides the daily library, made again only
    /// when the record changes (review, 2026-10-15: never in a redraw of the bar).
    @Published private(set) var libraryItems: [LibraryShelf.Item] = []
    /// The family downloads the Mac offers that this device doesn't hold (family downloads plan, phase 5): the
    /// Library's Not downloaded cards, kept apart so the ••• menu's Library opens only held files.
    @Published private(set) var offerItems: [LibraryShelf.Item] = []
    /// Offers already seen on Downloads or the Ready to download list, by file name: the rest are the Downloads
    /// tab's and bar button's count.
    @Published private(set) var seenOffers = Set(UserDefaults.standard.stringArray(forKey: PrepareMeTabs.seenOffersKey) ?? [])
    /// The offers on screen when the Ready to download bar was put away: it comes back when another is offered.
    @Published private(set) var putAwayOffers = Set(UserDefaults.standard.stringArray(forKey: PrepareMeTabs.putAwayKey) ?? [])
    static let seenOffersKey = "prepareme.library.seenOffers", putAwayKey = "prepareme.library.putAwayOffers"

    var unseenOffers: Int { offerItems.count { !seenOffers.contains($0.offer?.name ?? "") } }
    var readyBarShown: Bool { offerItems.contains { !putAwayOffers.contains($0.offer?.name ?? "") } }
    /// Every collection the Library lists: the held ones and the offers.
    var shelfItems: [LibraryShelf.Item] { libraryItems + offerItems }

    func markOffersSeen() {
        let names = Set(offerItems.compactMap(\.offer?.name))
        guard !names.isSubset(of: seenOffers) else { return }
        seenOffers = names  // names no longer offered fall out, so one offered again counts again
        UserDefaults.standard.set(Array(names), forKey: Self.seenOffersKey)
    }

    func putAwayReady() {
        putAwayOffers = Set(offerItems.compactMap(\.offer?.name))
        UserDefaults.standard.set(Array(putAwayOffers), forKey: Self.putAwayKey)
    }
    /// The Mac's categories, from the last list read (`Manifest.shelf`); the starting set until a Mac sends one.
    @Published private(set) var shelf = LibraryShelf.starting
    /// Guides on its Library side (owner, 2026-10-25, by click; renamed 2026-11-12): for the run; a page opened in
    /// Guides, a collection picked or the Guides tab tapped again goes back to its Guides side.
    @Published var guidesOnLibrary = false
    /// The Library side's pushed list (a category, New or Needs a category); emptied when a collection opens, and given
    /// back by Back from its front page (`PrepareMeLibraryReturn`).
    @Published var libraryPath: [PrepareMeLibraryPage.Rows] = []
    /// The Guides tab's switch (games plan phase 4, owner 2026-11-14): Guides, the Library while the phone holds any
    /// collection, and Games while it holds the games file (`MacLibraries.gamesFile`), whose front page opens in the
    /// Guides tab; its Back is the page's own, to the page before.
    enum GuidesSide: Hashable { case guides, library, games }
    /// Games picked, until its front page is on screen (the switch doesn't snap back to Guides while it loads).
    @Published var gamesOpening = false

    static var gamesID: UUID? { heldID(MacLibraries.gamesFile) }
    static func isGame(_ url: URL?) -> Bool {
        guard let id = gamesID, let file = url?.zimFileID else { return false }
        return file == id
    }

    func guidesSide(at url: URL?) -> GuidesSide {
        guidesOnLibrary ? .library : gamesOpening || Self.isGame(url) ? .games : .guides
    }

    func setGuidesSide(_ side: GuidesSide) {
        let browser = browser(.guides), onGame = Self.isGame(browser.url)
        gamesOpening = false
        switch side {
        case .library:
            guidesOnLibrary = true
        case .guides:  // from a game: the guide list
            guidesOnLibrary = false
            guard onGame else { return }
            Task { if let start = await startURL(.guides) { browser.load(url: start) } }
        case .games:  // the games' front page, unless a game already shows under the Library's list
            guidesOnLibrary = false
            libraryPath = []
            PrepareMeLibraryReturn.shared.clear()
            guard !onGame, let id = Self.gamesID else { return }
            gamesOpening = true
            Task {
                if let main = await ZimFileService.shared.getMainPageURL(zimFileID: id) {
                    browser.load(url: main)
                } else {
                    gamesOpening = false
                }
            }
        }
    }
    /// When each collection's first edition reached this phone, by key (`LibraryShelf.key`), so a newer edition is
    /// never New again (the Mac keeps the same in `library-first-seen.json`).
    static let firstSeenKey = "prepareme.library.firstSeen"
    private var watching: AnyCancellable?

    private init() {
        watching = PrepareMeLibrary.shared.store.$record  // sends the new record before it is stored, so before any redraw
            .removeDuplicates { $0.held == $1.held && $0.manifest?.shelf == $1.manifest?.shelf
                && $0.manifest?.files == $1.manifest?.files }
            .sink { [weak self] record in self?.refreshLibrary(record) }
    }

    private func refreshLibrary(_ record: LibraryRecord) {
        var seen = UserDefaults.standard.dictionary(forKey: Self.firstSeenKey) as? [String: String] ?? [:]
        let before = seen.count
        for file in record.held.values where seen[LibraryShelf.key(fileName: file.entry.name)] == nil {
            seen[LibraryShelf.key(fileName: file.entry.name)] = file.entry.deliveredAt
        }
        if seen.count != before { UserDefaults.standard.set(seen, forKey: Self.firstSeenKey) }
        libraryItems = LibraryShelf.items(record.held, dailyFile: Self.dailyFile, arrived: { file in
            seen[LibraryShelf.key(fileName: file.entry.name)].flatMap { ISO8601DateFormatter().date(from: $0) }
        }, named: { KiwixReader.record($0)?.name })
        offerItems = LibraryShelf.offered(record, dailyFile: Self.dailyFile)
        shelf = record.manifest?.shelf ?? .starting
    }

    /// A collection picked in a Library list: its front page in the Guides tab, on its Guides side; Back from that
    /// front page shows the list again (owner, 2026-11-12: as Back from a guide returns to its category).
    func openCollection(_ item: LibraryShelf.Item) {
        let path = libraryPath
        Task {
            guard let url = await ZimFileService.shared.getMainPageURL(zimFileID: item.id) else { return }
            browser(.guides).load(url: url)
            guidesOnLibrary = false
            libraryPath = []
            PrepareMeLibraryReturn.shared.set(front: url) { [weak self] in
                self?.guidesOnLibrary = true
                self?.libraryPath = path
                PrepareMeLibraryReturn.shared.clear()
            }
        }
    }

    static let dailyFile = PrepareMeKeptTabs.dailyFile
    static let overviewFile = PrepareMeKeptTabs.overviewFile
    static let guidesPage = PrepareMeKeptTabs.guidesPage

    func tabID(_ tab: PrepareMeTab) -> NSManagedObjectID {
        PrepareMeKeptTabs.tabID(key: "prepareme.tab.\(tab.rawValue)")
    }

    /// PrepareMe's help page, on Guides (Task 13.3; F48, F60): beside the daily library's own front page, as the
    /// Mac finds it (the review: Today's page may have moved on), from the phone's Settings or the iPad's Help menu.
    /// With no daily library on this device yet, Guides says so in its own way (its first page is missing too).
    func openHelp() {
        Task {
            selected = .guides
            guard let front = await startURL(.today) else { return }
            browser(.guides).load(url: MacRow.address(PrepareMeHelp.page, beside: front))
        }
    }

    func browser(_ tab: PrepareMeTab) -> BrowserViewModel {
        BrowserViewModel.getCached(tabID: tabID(tab))
    }

    /// The front page's Street map button in event mode (plan phase 9, item 9; prepareme-live.js).
    static let streetMapLink = URL(string: "prepareme://streetmap")!

    /// The app's own links: the street map's opens Maps on its Street map side, a guide's In the house Inventory on
    /// its items (phase 14, F57). Whether it was one.
    @discardableResult
    static func openAppLink(_ url: URL) -> Bool {
        if let house = GuideLinks.houseLink(url) {  // a guide's In the house (phase 14; F57): Inventory, its items
            let inventory = PhoneInventoryModel.shared
            inventory.openedPlace = nil
            inventory.openExpiring = false  // one page pushed at a time (the review)
            // with no copy yet, Inventory itself, which says how to get one, never a blank page (the review)
            inventory.openHouse = inventory.shown == nil ? nil : GuideHouse(title: house.title, words: house.words)
            shared.selected = .inventory
            return true
        }
        if let page = HomeLinks.page(url) {  // a label's QR code or a Shortcut (Our Home, Task 2.6): Today, at its start
            Task { await shared.openHome(page) }
            return true
        }
        if let id = Barcode.place(in: url.absoluteString) {  // an Our Home page's filled place, the bin label's link: Lists
            let inventory = PhoneInventoryModel.shared
            inventory.openHouse = nil
            inventory.openExpiring = false  // one page pushed at a time
            shared.selected = .inventory
            // a place the copy doesn't hold (or no copy yet): Lists at its top, never a screen saying it's missing
            inventory.openedPlace = inventory.shown?.places.contains { $0.id == id } == true ? id : nil
            return true
        }
        guard url.scheme == streetMapLink.scheme, url.host == streetMapLink.host else { return false }
        shared.streetMapFit = StreetMapLinks.bounds(url)  // nil for the plain link: the map stays where it was
        shared.setMapsSide(.street)
        shared.selected = .maps
        return true
    }

    /// An Our Home page of the daily library in Today at its start screen, as a tap on Today opens it (board 25); one the
    /// library doesn't hold opens the section's own page, and with no daily library yet, Today as it is.
    func openHome(_ page: String) async {
        selected = .today
        guard let url = PrepareMeKeptTabs.guideURL(page, held: PrepareMeLibrary.shared.store.record.held),
              let section = PrepareMeKeptTabs.guideURL(HomeLinks.section, held: PrepareMeLibrary.shared.store.record.held) else { return }
        let here = await ZimFileService.shared.getContentSize(url: url) != nil
        browser(.today).load(url: here ? url : section)
    }

    private var awake: AnyCancellable?
    private var homeAwake = false  // whether the screen is held awake for an Our Home step (the street map has its own)

    /// The screen kept awake while Today or Guides shows an Our Home page on a step (HomeLinks.keepsAwake; Task 2.6),
    /// as the street map's follow mode does, or a game page (games 3b: PrepareMeGamePlay); it locks as usual anywhere
    /// else.
    func watchAwake() {
        awake = Publishers.CombineLatest3($selected, browser(.today).$url, browser(.guides).$url)
            .receive(on: RunLoop.main)
            .sink { [weak self] tab, today, guides in
                guard let self else { return }
                let shown = tab == .today ? today : tab == .guides ? guides : nil
                let on = HomeLinks.keepsAwake(shown, dailyID: Self.heldID(Self.dailyFile))
                    || PrepareMeGamePlay.isGamePage(shown)
                guard on != self.homeAwake else { return }
                self.homeAwake = on
                UIApplication.shared.isIdleTimerDisabled = on
            }
    }

    /// Show `url` in a reading tab, and that tab (on Maps, its Find a map side: plan phase 9).
    func open(_ url: URL, in tab: PrepareMeTab) {
        browser(tab).load(url: url)
        if tab == .maps { setMapsSide(.find) }
        if tab == .guides {
            guidesOnLibrary = false
            libraryPath = []
            PrepareMeLibraryReturn.shared.clear()
        }
        selected = tab
    }

    /// A reading tab's own first page: the daily front page, its guide list, or Find a map (its Retap and Back to Find
    /// a map too); nil while its file isn't on this phone yet.
    func startURL(_ tab: PrepareMeTab) async -> URL? {
        let file = tab == .maps ? Self.overviewFile : Self.dailyFile
        // the sample's own Today and Guides (it has no topo maps: Maps' Find a map side says so)
        let sample = PrepareMeSample.shared.on && tab != .maps ? PrepareMeSample.id : nil
        guard let id = sample ?? Self.heldID(file), let main = await ZimFileService.shared.getMainPageURL(zimFileID: id) else {
            return nil
        }
        if tab == .maps { return await PrepareMeKeptTabs.findAMap(beside: main) }
        return tab == .guides ? main.deletingLastPathComponent().appendingPathComponent(Self.guidesPage) : main
    }

    /// The reading tab you're on, picked again: to its page's top, then to its first page (TabRetap; F45).
    func retap(_ tab: PrepareMeTab) async {
        guard !(tab == .maps && Self.onStreetMap) else { return }  // the map's own side (review)
        if tab == .guides, !libraryPath.isEmpty {  // a Library list: back to the Library's own first
            libraryPath = []
            return
        }
        if tab == .guides, guidesOnLibrary {  // the Library: back to the guide list's side first
            guidesOnLibrary = false
            return
        }
        let browser = browser(tab), scroll = browser.webView.scrollView
        let start = await startURL(tab)
        let onFirstPage = start.map { !PagePlace.isNewPage(from: $0, to: browser.url) } ?? true
        switch TabRetap.action(offset: scroll.contentOffset.y, inset: scroll.adjustedContentInset.top,
                               onFirstPage: onFirstPage) {
        case .scrollToTop:  // at the top the bar is back, with Back and Search (review)
            Self.showBars(of: browser)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: true)
        case .firstPage:
            // a child's Maps starts on the street map, so its first page is that (B2-22), not Find a map
            if tab == .maps, MapsFirstSide.retap(isChild: PhoneInventoryModel.shared.isChild) == .street {
                setMapsSide(.street)
            } else if let start { browser.load(url: start) }
        case .nothing:
            break
        }
    }

    /// Whether a page is in one of the map files (they open on the Maps tab).
    static func isMap(_ url: URL) -> Bool {
        PrepareMeKeptTabs.isMapFile(url, held: PrepareMeLibrary.shared.store.record.held)
    }

    static func heldID(_ name: String) -> UUID? {
        PrepareMeLibrary.shared.store.record.held.values.first { $0.entry.name == name }.flatMap { UUID(uuidString: $0.entry.id) }
    }
}

/// The phone's screen: the tab bar and its five places. Picking the reading tab you're on again scrolls it to its top,
/// then takes it back to its first page, as iPhone tab bars do (F45).
struct PrepareMeTabsView: View {
    @ObservedObject private var tabs = PrepareMeTabs.shared
    @State private var documents = PhoneDocumentsModel.shared
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var inventory = PhoneInventoryModel.shared  // its tab's badge: changes not saved
    @ObservedObject private var live = LiveConditions.shared  // Today's badge: something needs action
    @EnvironmentObject private var navigation: NavigationViewModel
    @Environment(\.dynamicTypeSize) private var size  // the person's own, read above the tab bar's cap below
    @ObservedObject private var play = PrepareMeGamePlay.shared  // a game page on screen: full screen (games 3b)
    @ObservedObject private var sample = PrepareMeSample.shared  // its opening and putting away make the tabs again

    /// The iPad's top tab bar at an accessibility text size is held to the standard size, as an iPhone's tab bar always
    /// is: its labels grew until Home Mac sat behind a scroll arrow and the bar scrolled (beta run 3's B3-05). Every
    /// tab's own screen takes the person's size again below. Smaller sizes are untouched.
    private var tabBarCap: DynamicTypeSize {
        UIDevice.current.userInterfaceIdiom == .pad && size.isAccessibilitySize ? .large : .accessibility5
    }

    var body: some View {
        TabView(selection: Binding(get: { tabs.selected }, set: { picked in
            if picked == tabs.selected, PrepareMeTab.reading.contains(picked) {  // the tab you're on (F45)
                Task { await tabs.retap(picked) }
            }
            tabs.selected = picked
        })) {
            SwiftUI.Tab(PrepareMeTab.today.title, systemImage: "sun.max", value: PrepareMeTab.today) {
                ReadingTab(tab: .today).id(sample.on).dynamicTypeSize(size)
            }
            // look 3 (spec section 9): a red mark while Today needs action, seen from whichever tab was left open
            .badge(live.needsAction ? Text(TodayMark.badge).accessibilityLabel(TodayMark.spoken) : nil)
            SwiftUI.Tab(PrepareMeTab.guides.title, systemImage: "book", value: PrepareMeTab.guides) {
                ReadingTab(tab: .guides).id(sample.on).dynamicTypeSize(size)
            }
            SwiftUI.Tab(PrepareMeTab.maps.title, systemImage: "map", value: PrepareMeTab.maps) {
                ReadingTab(tab: .maps).id(sample.on).dynamicTypeSize(size)
            }
            SwiftUI.Tab(PrepareMeTab.inventory.title, systemImage: "shippingbox", value: PrepareMeTab.inventory) {
                PhoneInventoryTab().dynamicTypeSize(size)
            }
            .badge(inventory.outbox.refused.count)  // changes the Mac refused, wherever you are (Task 2.4)
            if documents.adult {
                SwiftUI.Tab(PrepareMeTab.documents.title, systemImage: "lock.doc", value: PrepareMeTab.documents) {
                    PhoneDocumentsTab().dynamicTypeSize(size)
                }
            }
            if !PrepareMeTab.homeMacInBar {
                SwiftUI.Tab(PrepareMeTab.homeMac.title, systemImage: "arrow.down.circle", value: PrepareMeTab.homeMac) {
                    HomeMacTab().dynamicTypeSize(size)
                }
                .badge(tabs.unseenOffers)  // offers not yet seen (family downloads plan, phase 5)
            }
        }
        // the tab bar only: at the top on iPad, never a sidebar (owner, phase 4 gate: the sidebar opened over half of
        // Today); the sidebar's own button was what pushed Home Mac behind an arrow in portrait (the beta run's F07)
        .tabViewStyle(.tabBarOnly)
        .dynamicTypeSize(...tabBarCap)
        .background { TabBarSizeCap() }  // the same cap, on the bar itself; always there, so it can take it off again
        .modifier(BottomSearch(tabs: tabs))
        .background {  // the iPad's keyboard and menu bar act on the reading tab on screen (Task 10.6; F60)
            if PrepareMeTab.reading.contains(tabs.selected), !PrepareMeTabs.onStreetMap {
                KeyboardCommandsTarget(browser: tabs.browser(tabs.selected))
            }
        }
        .onChange(of: tabs.selected, initial: true) { _, picked in
            // links, search results and bookmarks open in the reading tab on screen (Kiwix's openURL goes to it)
            if PrepareMeTab.reading.contains(picked) { navigation.currentItem = .tab(objectID: tabs.tabID(picked)) }
            play.watch(PrepareMeTab.reading.contains(picked) ? tabs.browser(picked) : nil)
        }
        // full-screen play (games 3b): the game page over the tab bar, the search and the status bar, until it leaves
        .fullScreenCover(isPresented: Binding(get: { play.playing }, set: { _ in })) {
            PrepareMeGameScreen(browser: tabs.browser(tabs.selected)).dynamicTypeSize(size)
        }
        .task { navigation.observeOpeningFiles() }
        .task { tabs.watchAwake() }  // here, not at launch: the tabs' first use needs the library's records ready
        .task { await simulatorCheck() }
        .modifier(RoomSharingAsk())  // once, while paired (Unlisted plan, phase 4, decision 6)
        .sheet(isPresented: $tabs.homeMacSheet) { HomeMacTab(done: { tabs.homeMacSheet = false }).dynamicTypeSize(size) }
        // a tab no longer in the bar (Documents on a phone that isn't an adult's, Home Mac once it moved to the bar)
        .onChange(of: PrepareMeTab.shown, initial: true) { _, shown in
            if !shown.contains(tabs.selected) { tabs.selected = .today }
        }
        // Essential Documents lock when the app leaves the screen (design), and the app switcher shows a locked cover
        .onChange(of: phase) { _, now in if now == .background { documents.lock() } }
        .overlay {
            if phase != .active, tabs.selected == .documents { PhoneDocumentsCover() }
        }
    }

    private func simulatorCheck() async {
        #if targetEnvironment(simulator)
        // A session's simulator check only (screenshots, no taps): PREPAREME_CHECK_PAIR=<a pairing code for its loopback
        // test service> pairs at launch as the pairing sheet does; PREPAREME_CHECK_TAB=<tab> opens on that tab
        let check = ProcessInfo.processInfo.environment
        // PREPAREME_CHECK_SHARE_ROOM=yes or no: answers the free-space question before it is asked (unset: it asks)
        if let share = check["PREPAREME_CHECK_SHARE_ROOM"] { RoomSharing.answer(share == "yes") }
        if let code = check["PREPAREME_CHECK_PAIR"], MacLink.pairing == nil, (try? MacLink.pair(code)) != nil {
            await PhoneInventoryModel.shared.paired()
            await PrepareMeLibrary.shared.check()
        }
        // PREPAREME_CHECK_APPEARANCE=red or light: the red night screen on or off (kept in the settings, so set each run)
        if let look = check["PREPAREME_CHECK_APPEARANCE"] { PrepareMeRedNight.shared.on = look == "red" }
        // PREPAREME_CHECK_OPEN=<page>[#part]: opens that daily-library page in Today once it is held (Our Home's check)
        if let open = check["PREPAREME_CHECK_OPEN"] {
            let (page, part) = (open.split(separator: "#").first.map(String.init) ?? open,
                                open.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init))
            for _ in 0..<60 {
                if let url = PrepareMeKeptTabs.guideURL(page, held: PrepareMeLibrary.shared.store.record.held),
                   await ZimFileService.shared.getContentSize(url: url) != nil {
                    let shown = part.flatMap { URL(string: url.absoluteString + "#" + $0) } ?? url
                    tabs.selected = .today
                    tabs.browser(.today).webView.load(URLRequest(url: shown))
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // PREPAREME_CHECK_LINK=<prepareme:// link>: handed to the app's link handling as onOpenURL hands it, once the daily
        // library is held (Our Home, Task 2.6: iOS asks "Open in PrepareMe?" first for `simctl openurl`, a tap a check
        // doesn't make)
        if let link = check["PREPAREME_CHECK_LINK"].flatMap(URL.init(string:)) {
            for _ in 0..<60 where PrepareMeTabs.heldID(PrepareMeTabs.dailyFile) == nil {
                try? await Task.sleep(for: .seconds(1))
            }
            try? await Task.sleep(for: .seconds(2))
            PrepareMeTabs.openAppLink(link)
        }
        // PREPAREME_CHECK_SAMPLE=start or leave: Try the Sample, or Leave, as the buttons do (Unlisted plan, phase 4)
        if check["PREPAREME_CHECK_SAMPLE"] != nil { await PrepareMeSample.shared.settleOnce() }
        switch check["PREPAREME_CHECK_SAMPLE"] {
        case "start": await PrepareMeSample.shared.start()
        case "leave": await PrepareMeSample.shared.putAway()
        default: break
        }
        // homeMac opens Downloads as a tap does: its sheet on an adult's iPhone, its tab elsewhere
        if let tab = check["PREPAREME_CHECK_TAB"].flatMap(PrepareMeTab.init(rawValue:)) {
            if tab == .homeMac { tabs.openHomeMac() } else { tabs.selected = tab }
        }
        // PREPAREME_CHECK_GAMES=on: Guides on its Games side (games plan phase 4's check)
        if check["PREPAREME_CHECK_GAMES"] == "on" {
            try? await Task.sleep(for: .seconds(4))  // the record's first read
            tabs.selected = .guides
            tabs.setGuidesSide(.games)
        }
        // PREPAREME_CHECK_GAME=<path in the games file>: that page in Guides, as a tap on the Games list opens it, and
        // PREPAREME_CHECK_GAME_DONE=<seconds> presses Done that long after (full-screen play's checks, games 3b)
        if let path = check["PREPAREME_CHECK_GAME"] {
            for _ in 0..<60 where PrepareMeTabs.gamesID == nil { try? await Task.sleep(for: .seconds(1)) }
            try? await Task.sleep(for: .seconds(2))
            if let id = PrepareMeTabs.gamesID, let url = URL(zimFileID: id.uuidString, contentPath: path) {
                tabs.open(url, in: .guides)
                if let wait = check["PREPAREME_CHECK_GAME_DONE"].flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(wait))
                    play.done()
                }
            }
        }
        // PREPAREME_CHECK_SIDE=street: Maps on its Street map side, as the app's own link picks it (the shared marks
        // plan's checks: the system asks before it opens a link sent from outside, which no check can answer)
        if check["PREPAREME_CHECK_SIDE"] == "street" { tabs.setMapsSide(.street) }
        // PREPAREME_CHECK_LIBRARY=on (Guides on its Library side), new, unsorted or <category id> (that list pushed),
        // back-<category id> (its first collection opened, then Back pressed 15 seconds later): the Library plan's
        // phase 4 checks
        if let library = check["PREPAREME_CHECK_LIBRARY"] {
            try? await Task.sleep(for: .seconds(4))  // the record's first read
            tabs.selected = .guides
            tabs.guidesOnLibrary = true
            let id = library.hasPrefix("back-") ? String(library.dropFirst(5)) : library
            let rows: PrepareMeLibraryPage.Rows? = switch id {
            case "on": nil
            case "new": .new
            case "ready": .ready
            case "unsorted": .unsorted
            default: .category(id)
            }
            // a subcategory's folder is pushed on its category's list, as a tap there pushes it
            if case let .category(folder) = rows, tabs.shelf.top(of: folder) != folder {
                tabs.libraryPath = [.category(tabs.shelf.top(of: folder)), .category(folder)]
            } else if let rows {
                tabs.libraryPath = [rows]
            }
            if library.hasPrefix("back-"),
               let first = tabs.shelf.grouped(tabs.libraryItems).first(where: { $0.category.id == id })?.items.first {
                try? await Task.sleep(for: .seconds(2))
                tabs.openCollection(first)
                try? await Task.sleep(for: .seconds(15))
                _ = PrepareMeLibraryReturn.shared.goBack(at: tabs.browser(.guides).url)
            }
        }
        #endif
    }
}

/// What the iPad's ⌘[, ⌘] and text-size commands act on (Task 10.6; F60): the reading tab on screen says whether it
/// can go back or forward and has a page (the commands' focused values, which Kiwix's own screens set and PrepareMe's
/// tabs didn't, so the menu items stayed greyed out), and takes the Back and Forward the commands send.
private struct KeyboardCommandsTarget: View {
    @ObservedObject var browser: BrowserViewModel

    var body: some View {
        Color.clear
            .focusedSceneValue(\.canGoBack, browser.canGoBack)
            .focusedSceneValue(\.canGoForward, browser.canGoForward)
            .focusedSceneValue(\.isBrowserURLSet, browser.url != nil)
            .onReceive(NotificationCenter.default.publisher(for: .goBack)) { _ in browser.webView.goBack() }
            .onReceive(NotificationCenter.default.publisher(for: .goForward)) { _ in browser.webView.goForward() }
    }
}

/// A big iPhone's Search in the tab bar's accessory slot, above the tab bar, within the thumb's reach (Task 10.7; F33,
/// F67): the bar's own bottom search item hides under a tab bar, and a button laid over the page hid its last lines;
/// pages leave room for the accessory. iOS 26.1's; earlier iOS keeps search at the top only. At an accessibility text
/// size it is left out (beta run 3's B3-05): the pill and the tab bar grow with the text, the pill floated over the
/// band's buttons ("Meet at: …") on a Pro Max, and a page can't be given more room than the system gives it (an inset
/// set by hand once left Today blank: WebView.swift). The search at the top of the page is there at every size.
/// A reading tab's search box at the top of its page, except on a big iPhone, where the Search above the tab bar is
/// the one search (the owner's F33/F67 choice (a), 2026-10-18: search at the bottom on big phones, "the top as before
/// elsewhere"; the owner saw both at once, 2026-10-22): there the box shows only once that Search opens it, so typing
/// and results work as before. At an accessibility text size, or before iOS 26.1, the bottom Search isn't shown, so
/// the top box stays.
private struct TopSearch: ViewModifier {
    @Binding var text: String
    @Binding var searching: Bool
    let prompt: String
    @Environment(\.dynamicTypeSize) private var size

    private var bottomOnly: Bool {
        guard #available(iOS 26.1, *) else { return false }
        return PrepareMeTabs.searchAtBottom && !size.isAccessibilitySize
    }

    func body(content: Content) -> some View {
        if bottomOnly && !searching {
            content
        } else {
            content.searchable(text: $text, isPresented: $searching,
                               placement: .navigationBarDrawer(displayMode: .automatic), prompt: prompt)
        }
    }
}

private struct BottomSearch: ViewModifier {
    @ObservedObject var tabs: PrepareMeTabs
    @Environment(\.dynamicTypeSize) private var size

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: tabs.showsBottomSearch && !size.isAccessibilitySize) {
                Button { tabs.searchRequest = tabs.selected } label: {
                    Label(PrepareMeTabs.searchPrompt(tabs.selected), systemImage: "magnifyingglass")
                        .font(.pmBody)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PrepareMeColors.ink)
            }
        } else {
            content
        }
    }
}

/// The tab bar itself held to the standard text size at an accessibility size on an iPad (B3-05). SwiftUI's own cap on
/// the TabView does this too; this one is on the bar's view, which never touches a tab's screen. It stays in place at
/// every size so that it takes the cap off again when the text size comes back down while the app runs.
private struct TabBarSizeCap: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Holder { Holder() }
    func updateUIViewController(_ holder: Holder, context: Context) { holder.apply() }

    final class Holder: TextSizeHolder {
        override var held: UIView? { Self.tabBarController(from: view.window?.rootViewController)?.tabBar }
        override var cap: UIContentSizeCategory? {
            UIDevice.current.userInterfaceIdiom == .pad
                && traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .large : nil
        }

        private static func tabBarController(from controller: UIViewController?) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabs = controller as? UITabBarController { return tabs }
            let inside = controller.children + [controller.presentedViewController].compactMap { $0 }
            return inside.lazy.compactMap { tabBarController(from: $0) }.first
        }
    }
}

/// A reading tab's search field held to a size its word fits at (B3-05): at the largest text size the iPad showed an
/// empty grey pill with no "Search" (iPad only). Past this size the field's own text and placeholder stop growing; the
/// page's own text does not. Below it nothing is touched.
private struct SearchFieldSizeCap: UIViewControllerRepresentable {
    static let biggest = UIContentSizeCategory.extraExtraExtraLarge

    func makeUIViewController(context: Context) -> Holder { Holder() }
    func updateUIViewController(_ holder: Holder, context: Context) { holder.apply() }

    final class Holder: TextSizeHolder {
        override var held: UIView? {
            navigationController?.viewControllers.reversed().lazy
                .compactMap({ $0.navigationItem.searchController?.searchBar }).first
        }
        // the iPad's (B3-05); an iPhone's search field was not seen to lose its word, so it is left as it was
        override var cap: UIContentSizeCategory? {
            UIDevice.current.userInterfaceIdiom == .pad
                && traitCollection.preferredContentSizeCategory > SearchFieldSizeCap.biggest
                ? SearchFieldSizeCap.biggest : nil
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            DispatchQueue.main.async { [weak self] in self?.apply() }  // the search controller may come just after
        }
    }
}

/// B3-05's two caps: laid behind a view, it holds `held`'s text size at `cap` each time it appears or lays out, and
/// takes the hold off again while `cap` is nil. Its subclasses say which view and which size.
private class TextSizeHolder: UIViewController {
    var held: UIView? { nil }
    var cap: UIContentSizeCategory? { nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        apply()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        apply()
    }

    func apply() {
        guard let target = held else { return }
        let holding = target.traitOverrides.contains(UITraitPreferredContentSizeCategory.self)
        if let cap {
            if !holding { target.traitOverrides.preferredContentSizeCategory = cap }
        } else if holding {
            target.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
    }
}

/// One reading tab: its page, with back, forward, contents and a menu in its own top bar, and search on Today and
/// Guides. It opens its first page when it has none; a page of a map file opened from Today or Guides moves to Maps.
private struct ReadingTab: View {
    let tab: PrepareMeTab
    @ObservedObject private var browser: BrowserViewModel
    @ObservedObject private var store = PrepareMeLibrary.shared.store
    @ObservedObject private var library = PrepareMeLibrary.shared  // phase M: Today's can't-update warning
    @StateObject private var search = SearchViewModel()
    @State private var bookmarks = false
    @ObservedObject private var tabs = PrepareMeTabs.shared  // the Maps side (plan phase 9), settled once a launch
    @ObservedObject private var play = PrepareMeGamePlay.shared  // its page lent to the full screen (games 3b)
    @ObservedObject private var sample = PrepareMeSample.shared

    /// The side shown: the one picked, else by who holds the phone (MapsFirstSide; B2-22).
    private var mapsPane: Binding<String> {
        Binding(get: { _ = tabs.mapsSideChanged; return tabs.mapsSide.rawValue },
                set: { if let side = MapsSide(rawValue: $0) { tabs.setMapsSide(side) } })
    }

    private var onStreetMap: Bool { tab == .maps && mapsPane.wrappedValue == MapsPane.street.rawValue }
    /// Guides on its Library side, while the device holds any collection (none: no Library side, the guide list).
    private var onLibraries: Bool { tab == .guides && !tabs.shelfItems.isEmpty && tabs.guidesOnLibrary }
    /// The switch shows while there's a Library or Games side (games plan phase 4).
    private var librariesSwitch: Bool { tab == .guides && (!tabs.shelfItems.isEmpty || gamesHeld) }
    private var gamesHeld: Bool { store.record.held[MacLibraries.gamesFile] != nil }
    @ObservedObject private var libraryReturn = PrepareMeLibraryReturn.shared
    /// Back from a collection's front page leads to its Library list (Guides only: the menu's own opens set none).
    private var backToLibrary: Bool { tab == .guides && libraryReturn.applies(browser.url) }

    @State private var searching = false
    private var prompt: String { PrepareMeTabs.searchPrompt(tab) }

    /// The menu's last item, back to the tab's own first page (Task 10.3; F19; owner, 2026-10-18, by click).
    static func backWords(_ tab: PrepareMeTab) -> String {
        switch tab {
        case .guides: "Back to the guide list"
        case .maps: "Back to Find a map"
        default: "Back to the top of Today"
        }
    }
    /// Phase 4, decision 2: the largest file this device may remove, offered on the room warning with one tap
    private var roomRemovable: HeldFile? { roomFull ? LibraryPlan.largestRemovable(store.record) : nil }
    private var roomFull: Bool { tab == .today && !library.cantUpdate.isEmpty }
    private var roomWarning: String? {
        tab == .today ? RoomWarning.words(library.cantUpdate, canRemove: roomRemovable != nil) : nil
    }
    @State private var removingForRoom: HeldFile?
    /// Over-the-air plan, layer 3: a TestFlight build two weekly rebuilds behind, with its Update button
    private var notUpdated: String? { tab == .today ? InstallInfo.notUpdated : nil }
    @State private var documents = PhoneDocumentsModel.shared  // Today's line for documents not here yet
    private var documentsMissing: Int { tab == .today && documents.adult ? documents.missing : 0 }

    init(tab: PrepareMeTab) {
        self.tab = tab
        browser = PrepareMeTabs.shared.browser(tab)
    }

    var body: some View {
        // only Guides pushes (its Library lists); the other tabs' stacks never share its path
        NavigationStack(path: tab == .guides ? $tabs.libraryPath : .constant([])) {
            Group {
                if onStreetMap {
                    StreetMapPane().modifier(SampleStripped())
                } else if tab == .maps {
                    page.modifier(SampleStripped())
                } else {
                    // the list over the page, so the search box and the switch stay where they are on both sides
                    SearchablePage(search: search) {
                        page.overlay { if onLibraries { PhoneLibraryList() } }.modifier(SampleStripped())
                    }
                        // short enough not to be cut (F63); on a big iPhone only once the bottom Search opens it
                        .modifier(TopSearch(text: $search.searchText, searching: $searching, prompt: prompt))
                        // the tab bar's Search, on a big iPhone: received, never watched, so a tab switch redraws
                        // no reading tab (review): the bar comes back first, since the search sits in it (F33, F67)
                        .onReceive(PrepareMeTabs.shared.$searchRequest) { asked in
                            guard asked == tab else { return }
                            PrepareMeTabs.shared.searchRequest = nil
                            PrepareMeTabs.showBars(of: browser)
                            searching = true
                        }
                        .onChange(of: searching) { _, now in PrepareMeTabs.shared.searching[tab] = now }
                        .background { SearchFieldSizeCap() }  // the field keeps its word at the largest text (B3-05)
                }
            }
            .navigationDestination(for: PrepareMeLibraryPage.Rows.self) { rows in
                PrepareMeLibraryPage(rows: rows, shelf: tabs.shelf, items: tabs.shelfItems,
                                     open: { tabs.openCollection($0) }, pick: { tabs.libraryPath.append($0) })
                    .onAppear { if rows == .ready { tabs.markOffersSeen() } }
                    .navigationTitle(PhoneLibraryList.title(rows, shelf: tabs.shelf))
                    .navigationBarTitleDisplayMode(.inline)
                    .pmBandBar()
            }
            .homeMacButton()
            .frame(maxWidth: .infinity, maxHeight: .infinity)  // the row below sits under the bar, not mid-page
            .pmBandBar()  // look 3: the band behind the bar and the row under it
            .pmBar(.top, spacing: roomWarning == nil && documentsMissing == 0 && notUpdated == nil ? nil : 0) {  // Today's page right under its row
                if let words = notUpdated { PMWarningRow(words, action: ("Update", InstallInfo.openTestFlight)) }
                if documentsMissing > 0 { PhoneDocumentsTodayLine(count: documentsMissing) }  // Essential Documents
                if let words = roomWarning {  // phase M: never quietly stale; look 3's amber row
                    Group {
                        if let held = roomRemovable {  // phase 4: one tap, which asks as Remove does
                            PMWarningRow(words, action: (HomeMacWords.removeButton(title: FileRow.title(held.entry),
                                                                                   size: held.entry.size),
                                                         { removingForRoom = held }), below: true)
                        } else {
                            PMWarningRow(words)
                        }
                    }
                    // at the largest sizes the row filled the screen and its Remove sat under the tab bar (phase 4)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                }
                if tab == .maps {  // plan phase 9: the two views of Maps, on a row of their own under the bar
                    Picker("Maps", selection: mapsPane) {
                        Text("Find a map").tag(MapsPane.find.rawValue)
                        Text("Street map").tag(MapsPane.street.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .pmOnBand()
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                if librariesSwitch {  // as Maps' switch (owner, 2026-10-25, by click)
                    Picker("Guides", selection: Binding(get: { tabs.guidesSide(at: browser.url) },
                                                        set: { tabs.setGuidesSide($0) })) {
                        Text("Guides").tag(PrepareMeTabs.GuidesSide.guides)
                        if !tabs.shelfItems.isEmpty { Text(MacLibraries.menuTitle).tag(PrepareMeTabs.GuidesSide.library) }
                        if gamesHeld { Text(MacLibraries.gamesTitle).tag(PrepareMeTabs.GuidesSide.games) }
                    }
                    .pickerStyle(.segmented)
                    .pmOnBand()
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
            .confirmationDialog("Remove \(removingForRoom.map { FileRow.title($0.entry) } ?? "") from this "
                                + "\(ThisDevice.word)?",
                                isPresented: Binding(get: { removingForRoom != nil },
                                                     set: { if !$0 { removingForRoom = nil } }),
                                titleVisibility: .visible, presenting: removingForRoom) { held in
                Button("Remove", role: .destructive) { Task { await library.remove(held.entry.name) } }
            } message: { held in  // as Downloads' Remove asks (phase 4, decision 2)
                Text("It frees \(StorageWords.size(held.entry.size)). Download it again under Downloads at home, "
                     + "over Wi-Fi.")
            }
            .navigationTitle(onStreetMap || browser.articleTitle.isEmpty ? title : browser.articleTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {  // shown in place of the title above, never cut short (F63)
                    BarTitleView(choices: BarTitle.choices(
                        title: onStreetMap || browser.articleTitle.isEmpty ? title : browser.articleTitle, tab: title))
                }
                if !onStreetMap {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button {
                            if !(backToLibrary && libraryReturn.goBack(at: browser.url)) { browser.webView.goBack() }
                        } label: { Label("Back", systemImage: "chevron.backward") }
                            .disabled(!browser.canGoBack && !backToLibrary)
                        Button { browser.webView.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                            .disabled(!browser.canGoForward)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        OutlineButton(browser: browser)
                        Menu {
                            Button("Bookmarks", systemImage: "star.square.on.square") { bookmarks = true }
                            ContentSearchButton(browser: browser)
                            // Read, not watched: it changes only with the store's record, which this tab watches;
                            // watching every tab switch too would redraw all three reading tabs on each one.
                            let items = PrepareMeTabs.shared.libraryItems, shelf = PrepareMeTabs.shared.shelf
                            if !items.isEmpty && tab != .guides {  // Guides has the switch on screen (look 3 change 6); reference and vehicles: no link reaches them, and vehicles
                                Menu(MacLibraries.menuTitle, systemImage: "books.vertical") {  // is out of search
                                    ForEach(shelf.grouped(items), id: \.category.id) { group in
                                        Menu("\(group.category.emoji)  \(group.category.name)") {
                                            libraryButtons(group.items)
                                            // each subcategory's under its name (phase 4 review)
                                            ForEach(shelf.subGroups(items, in: group.category.id), id: \.category.id) { sub in
                                                Menu(sub.category.name) { libraryButtons(sub.items) }
                                            }
                                        }
                                    }
                                    let unsorted = shelf.unsorted(items)
                                    if !unsorted.isEmpty {
                                        Menu(MacSidebar.title(.shelfUnsorted) ?? "") { libraryButtons(unsorted) }
                                    }
                                }
                            }
                            RedNightSwitch()  // phase D
                            Button(Self.backWords(tab), systemImage: "house") {
                                Task {
                                    if let url = await PrepareMeTabs.shared.startURL(tab) { browser.load(url: url) }
                                }
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                    }
                }
            }
            .sheet(isPresented: $bookmarks) {
                SheetContent {
                    BookmarksListing(articleBookmarked: browser.articleBookmarked,
                                     isButtonDisabled: browser.zimFileName.isEmpty,
                                     createBookmark: { browser.createBookmark() },
                                     deleteBookmark: { browser.deleteBookmark() })
                }
            }
        }
        .onChange(of: store.record.held.count, initial: true) { _, _ in openFirstPageIfEmpty() }
        .onChange(of: browser.url) { _, url in  // the games' front page is on screen (or another page took its place)
            if tab == .guides, tabs.gamesOpening, url != nil { tabs.gamesOpening = false }
        }
        .onChange(of: browser.url) { _, url in
            guard tab != .maps, let url, PrepareMeTabs.isMap(url) else { return }
            PrepareMeTabs.shared.open(url, in: .maps)  // the front page's Maps link, and any map, read on Maps
            browser.webView.goBack()
        }
    }

    var title: String { tab.title }

    /// The ••• menu's Library: each collection opens at its front page in this tab.
    @ViewBuilder private func libraryButtons(_ items: [LibraryShelf.Item]) -> some View {
        ForEach(items, id: \.id) { item in
            Button(InventoryLook.title(item.title)) {
                Task {
                    if let url = await ZimFileService.shared.getMainPageURL(zimFileID: item.id) { browser.load(url: url) }
                }
            }
        }
    }

    @ViewBuilder var page: some View {
        if play.playing && tabs.selected == tab {
            PrepareMeColors.ground  // the page is in the full screen (PrepareMeGameScreen), which holds its web view
        } else if browser.url == nil {
            if tab == .maps, sample.on {
                PMStateScreen { PMState(symbol: "map", heading: "Find a map", line: SampleLibrary.noTopo) }
            } else if tab == .maps, PrepareMeTabs.heldID(PrepareMeTabs.dailyFile) != nil {
                FindAMapEmpty()
            } else {
                PrepareMeWelcome()
            }
        } else {
            WebView(browser: browser)
                // On Maps the page starts under its Find a map and Street map row: UIKit is told only of the top bar, so
                // a page under the row had its first line and a half hidden (review, 2026-10-15); Today's room warning
                // the same (phase M: it hid the page's heading); still so in Apple's own bar (phase 10, checked); and
                // Guides' Other libraries switch (it hid a library's title, 2026-10-25)
                .ignoresSafeArea(edges: tab == .maps || roomWarning != nil || notUpdated != nil || librariesSwitch
                                 || sample.on
                                 ? [.horizontal, .bottom] : .all)
                .overlay { if browser.isLoading == true { LoadingProgressView() } }
                .onAppear { if tab == .today { TodayPull.shared.attach(to: browser.webView.scrollView) } }
                .modifier(ExternalLinkHandler(externalURL: $browser.externalURL))
                .task { await browser.updateLastOpened() }
                .onDisappear { Task { await browser.persistState() } }
        }
    }

    private func openFirstPageIfEmpty() {
        guard browser.url == nil else { return }
        Task { if let url = await PrepareMeTabs.shared.startURL(tab) { browser.load(url: url) } }
    }
}

/// Find a map before its file is on this device (beta run 3, B3-02): while the topo overview waits for room under the
/// reserve, the reason and Download (the same ask as Downloads' Download, `FileRow.get`; a child's phone too since the
/// family downloads plan, phase 2); once it is on its way, "Getting the map overview now…" (owner, 2026-10-21); every
/// other empty case keeps its old words.
private struct FindAMapEmpty: View {
    @ObservedObject private var library = PrepareMeLibrary.shared
    @ObservedObject private var store = PrepareMeLibrary.shared.store
    @State private var answer: FileRow.GetAnswer?
    @State private var overview: Manifest.Entry?

    var body: some View {
        // centered when it fits, scrolling when it doesn't: at the largest text the words and the button together are
        // taller than an SE's screen, and a button below the fold would be out of reach (PMStateScreen); look 3's one
        // look for "not here yet" (spec section 10), the tab's own name over its words
        PMStateScreen { content }
            .modifier(DownloadAnswer(entry: overview, answer: $answer))
    }

    @ViewBuilder private var content: some View {
        let heading = "Find a map"  // the switch's word for this side
        if let entry = FindAMapWords.waitingOverview(library.waitingForRoom, overviewFile: PrepareMeTabs.overviewFile) {
            let size = StorageWords.size(entry.size)
            PMState(symbol: "map", heading: heading,
                    line: FindAMapWords.waitingForRoom(size: size, device: ThisDevice.word),
                    action: (FindAMapWords.getThisFile, {
                        overview = entry
                        answer = FileRow.get(entry)
                    }))
        } else if FindAMapWords.isGetting(requested: store.record.requested, downloading: library.progress,
                                          overviewFile: PrepareMeTabs.overviewFile) {
            PMState(symbol: "map", heading: heading, line: FindAMapWords.getting(device: ThisDevice.word))
            if let note = store.notes[PrepareMeTabs.overviewFile] {  // as Home Mac says it: checking, or why not
                Text(note).font(.pmNote).foregroundStyle(PrepareMeColors.text2).padding(.horizontal, 24)
            }
        } else {
            PMState(symbol: "map", heading: heading, line: FindAMapWords.fromTheMac)
        }
    }
}

/// Guides' Library side (owner, 2026-10-25, by click; Library plan phase 4, 2026-11-12; drawn as the guide list since
/// the Library matches Guides plan, phase 2): the band card, New while any collection arrived in the last 30 days, the
/// Mac's categories holding a collection (each with its emoji and count), then Needs a category while any has none.
/// Each pushes its list (`PrepareMeLibraryPage`), where a tap opens a collection.
private struct PhoneLibraryList: View {
    @ObservedObject private var tabs = PrepareMeTabs.shared

    static func title(_ rows: PrepareMeLibraryPage.Rows, shelf: LibraryShelf) -> String {
        switch rows {
        case let .category(id):
            return shelf.categories.first { $0.id == id }  // a subcategory is a folder (owner, 2026-11-14)
                .map { "\($0.parent == nil ? $0.emoji : PrepareMeLibraryPage.folder) \($0.name)" } ?? MacLibraries.menuTitle
        case .new: return MacSidebar.title(.shelfNew) ?? ""
        case .ready: return HomeMacWords.readyBar
        case .unsorted: return MacSidebar.title(.shelfUnsorted) ?? ""
        case .all: return MacLibraries.menuTitle
        }
    }

    /// The shared page (Library matches Guides plan, 2.1), as the Mac draws it: pushed by value, so Back from a
    /// collection can give its list back (`PrepareMeLibraryReturn`).
    var body: some View {
        PrepareMeLibraryPage(rows: .all, shelf: tabs.shelf, items: tabs.shelfItems, open: { tabs.openCollection($0) },
                             pick: { tabs.libraryPath.append($0) }, title: MacLibraries.menuTitle,
                             readyBar: tabs.readyBarShown, putAwayReady: { tabs.putAwayReady() })
    }
}

/// A reading tab's top-bar title (BarTitle; beta run 1's F63, beta run 2's B2-17; owner, 2026-10-21): the first of its
/// choices that fits the room between the bar's buttons, on one line at the bar's own size or else on two at 15 points,
/// never cut short with "…"; the last, the tab's name, always does. Like the system's bar titles it stops growing past
/// the standard text size, where a title larger still would leave room for none.
private struct BarTitleView: View {
    let choices: [String]
    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var size

    private static let biggest = DynamicTypeSize.large
    private static let wide: CGFloat = 4000

    var body: some View {
        let (words, lines) = Self.pick(choices, width: width, size: min(size, Self.biggest))
        Text(words)
            .font(lines == 1 ? .pmHeadline : .pmNote.weight(.semibold))
            .lineLimit(lines)
            .multilineTextAlignment(.center)
            .dynamicTypeSize(...Self.biggest)
            // asks for more than any bar has, so the bar gives it all the room between its buttons whatever the words:
            // measured from the words' own width, a shorter choice would leave too little room for a longer one
            .frame(idealWidth: Self.wide, maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .accessibilityLabel(choices.first ?? words)  // VoiceOver reads the whole title
            .accessibilityAddTraits(.isHeader)
    }

    /// The words and how many lines: the first choice that fits `width` on one line at the headline size, else on
    /// two at the subheadline size; before the width is known, the tab's name
    static func pick(_ choices: [String], width: CGFloat, size: DynamicTypeSize) -> (String, Int) {
        let last = choices.last ?? ""
        guard width > 0 else { return (last, 1) }
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let one = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        let body = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let two = UIFont(descriptor: body.fontDescriptor.withSymbolicTraits(.traitBold) ?? body.fontDescriptor,
                         size: body.pointSize)
        for words in choices.dropLast() {
            if lines(words, one, width) <= 1 { return (words, 1) }
            if lines(words, two, width) <= 2 { return (words, 2) }
        }
        return (last, lines(last, one, width) <= 1 ? 1 : 2)
    }

    /// How many lines `words` take at `font` in `width` points, wrapped at spaces as Text wraps them
    static func lines(_ words: String, _ font: UIFont, _ width: CGFloat) -> Int {
        let box = (words as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], attributes: [.font: font],
                                                   context: nil)
        return Int((box.height / font.lineHeight).rounded())
    }
}

/// Search results over the page while searching (Kiwix's own results list; a result opens in this tab).
private struct SearchablePage<Page: View>: View {
    @ObservedObject var search: SearchViewModel
    @ViewBuilder let page: () -> Page
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        page().overlay { if isSearching { SearchResults(viewModel: search) } }
    }
}

/// Home Mac: the Mac, the library on this phone and this install (HomeMacView), and Kiwix's settings behind the gear.
/// On an adult's iPhone it is a sheet from each tab's bar, with Done.
private struct HomeMacTab: View {
    var done: (() -> Void)?
    @State private var settings = false
    @State private var aboutCheck: String?

    var body: some View {
        NavigationStack {
            HomeMacView()
                .pmBandBar()  // look 3
                #if targetEnvironment(simulator)
                // a session's simulator check (screenshots, no taps; Unlisted plan, phase 4): PREPAREME_CHECK_ABOUT=about
                // or acknowledgements opens that screen over Downloads (with PREPAREME_CHECK_TAB=homeMac)
                .onAppear { aboutCheck = ProcessInfo.processInfo.environment["PREPAREME_CHECK_ABOUT"] }
                .sheet(item: Binding(get: { aboutCheck.map(CheckedScreen.init) }, set: { aboutCheck = $0?.id })) {
                    if $0.id == "acknowledgements" { NavigationStack { AcknowledgementsList() } } else { NavigationStack { About() } }
                }
                #endif
                .toolbar {
                    Button { settings = true } label: {  // the gear with its word (F41): a toolbar shows a Label's icon alone
                        HStack(spacing: 6) { Image(systemName: "gear"); Text("Settings") }
                    }
                    .accessibilityLabel("Settings")
                }
                .toolbar {
                    if let done {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { done() } }
                    }
                }
                .sheet(isPresented: $settings) {
                    NavigationStack {
                        Settings(scrollToHotspot: false).toolbar {
                            // the help page from the gear (Task 13.3; F48): it opens on Guides
                            ToolbarItem(placement: .topBarLeading) {
                                Button(PrepareMeHelp.menuTitle) {
                                    settings = false
                                    PrepareMeTabs.shared.openHelp()
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } }
                        }
                    }
                }
        }
    }
}
#if targetEnvironment(simulator)
private struct CheckedScreen: Identifiable {
    let id: String
}
#endif

/// Pull down on Today to read the conditions now (look 3, spec section 9), on the page's own scroll view, which
/// SwiftUI's `.refreshable` doesn't reach. It reads as the app coming forward does (`refresh()`): each feed at most as
/// often as its own spacing allows.
@MainActor
final class TodayPull: NSObject {
    static let shared = TodayPull()

    func attach(to scroll: UIScrollView) {
        guard scroll.refreshControl == nil else { return }
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(pulled(_:)), for: .valueChanged)
        scroll.refreshControl = control
    }

    @objc private func pulled(_ control: UIRefreshControl) {
        Task {
            await LiveConditions.shared.refresh()
            control.endRefreshing()
        }
    }
}

/// Phase M: Today's warning when a base file can't update for lack of room (owner's ruling: a stale library is a
/// defect, never quiet). Nil when every base file is current or has room.
enum RoomWarning {
    @MainActor static func words(_ entries: [Manifest.Entry], canRemove: Bool = false) -> String? {
        guard let first = entries.first else { return nil }
        return HomeMacWords.roomWarning(file: FileRow.title(first), more: entries.count - 1,
                                        need: first.size + LibraryPlan.spareBytes,
                                        free: PrepareMeLibrary.availableBytes(), device: ThisDevice.word,
                                        canRemove: canRemove)
    }
}
#endif
