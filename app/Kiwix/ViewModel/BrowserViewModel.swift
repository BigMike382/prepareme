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
import CoreData
import CoreLocation
import WebKit
import Defaults
import os
import CoreKiwix
#if PREPAREME_APP
import PrepareMeShared
#endif
#if PREPAREME_APP && os(iOS)
import UIKit
#endif

// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
@MainActor final class BrowserViewModel: NSObject, ObservableObject,
                              WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate,
                              NSFetchedResultsControllerDelegate {

    static var cache: OrderedCache<NSManagedObjectID, BrowserViewModel>?  // PrepareMe: internal for its tests
    /// PrepareMe app (plan phase 4; the app sets these, Kiwix never does): pages keep their folds as built instead of
    /// every fold opened on load (FINDINGS F-045), and a link into a library this phone doesn't hold goes to
    /// `missingLibrary`, which returns true when it handled it (the "Get this file" sheet) so no failure alert shows
    static var keepsFoldsAsBuilt = false
    static var missingLibrary: ((URL) -> Bool)?
    /// PrepareMe app (plan phase 9): its own prepareme:// links in a page (the front page's Street map button), handled
    /// by the app, which returns true when it did.
    static var appLink: ((URL) -> Bool)?
    /// PrepareMe app (plan phase 5; the app sets it, Kiwix never does): told when a page finishes loading, so the
    /// app can put its live conditions on the daily library's front page.
    static var pageFinished: (@MainActor (WKWebView) -> Void)?
    #if PREPAREME_APP
    /// PrepareMe app (Our Home plan, Task 2.4; the phone sets it): the numbers the daily library's Our Home pages may
    /// dial besides CallLinks' two (CallLinks.homeNumbers).
    static var callNumbers: (@MainActor () async -> Set<String>)?
    /// PrepareMe app (owner's phone, 2026-10-21; the phone sets it): a reading tab's own first page, where Back goes
    /// when every page behind it has left the library (BackSkip).
    static var startPage: (@MainActor (BrowserViewModel) async -> URL?)?
    #endif

    static func getCached(tabID: NSManagedObjectID) -> BrowserViewModel {
        if let cachedModel = cache?.findBy(key: tabID) {
            return cachedModel
        }
        if cache == nil {
            cache = .init()
        }
        let viewModel = BrowserViewModel(tabID: tabID)
        cache?.removeValue(forKey: tabID)
        cache?.setValue(viewModel, forKey: tabID)
        return viewModel
    }

    #if PREPAREME_APP
    /// PrepareMe (Mac sidebar plan, part 2 review, 3): the tab's model when one is made already, never a new one.
    static func cachedIfMade(tabID: NSManagedObjectID) -> BrowserViewModel? {
        cache?.findBy(key: tabID)
    }
    #endif

    // PrepareMe (both builds; owner's iPhone, 2026-11-20): Kiwix's purgeCache, run on a memory warning, dropped every
    // model made over 6 minutes before, the tab on screen's too, so the next getCached made a second one and a tapped
    // search result opened in a page no screen showed. It freed nothing (script handlers keep a model alive): gone.

    nonisolated static func destroyTabById(id: NSManagedObjectID) {
        Task { @MainActor in
            if let browserViewModel = cache?.findBy(key: id) {
                await browserViewModel.destroy()
                cache?.removeValue(forKey: id)
            }
        }
    }

    /// PrepareMe: reload the tabs on the front page of a library whose file was replaced (owner, 2026-10-07: only
    /// the front page, so a page in use, a calculator half filled in, is never wiped; any other page shows the new
    /// copy at the next page opened)
    static func reloadFrontPages(of zimFileIDs: [UUID]) async {
        guard !zimFileIDs.isEmpty, let cache else { return }
        for browser in cache.values {
            guard let url = browser.url, let zimFileID = url.zimFileID, zimFileIDs.contains(zimFileID),
                  let front = await ZimFileService.shared.getMainPageURL(zimFileID: zimFileID),
                  url.contentPath == front.contentPath else { continue }
            reloadWhenSettled(browser.webView)
        }
    }

    /// One reload waiting per web view still loading, until its page finishes.
    private static var reloadsWaiting: [ObjectIdentifier: NSKeyValueObservation] = [:]

    /// Never mid-load (FINDINGS F-096): a reload while a tab's first page is on its way never runs, and WebKit then
    /// says the tab is loading for good, a spinner over the finished page. Nor dropped: a page past its commit may
    /// have read the old file (the 2026-10-25 review). So a loading page is reloaded once it finishes, if still shown.
    static func reloadWhenSettled(_ webView: WKWebView) {
        guard webView.isLoading else {
            webView.reload()
            return
        }
        let key = ObjectIdentifier(webView), page = webView.url
        reloadsWaiting[key] = webView.observe(\.isLoading) { webView, _ in
            Task { @MainActor in
                guard !webView.isLoading, reloadsWaiting.removeValue(forKey: key) != nil, webView.url == page else {
                    return
                }
                webView.reload()
            }
        }
    }

    /// PrepareMe app (plan phase 5): the web views showing a library's front page, for the live conditions.
    static func frontPageWebViews() async -> [WKWebView] {
        guard let cache else { return [] }
        var found: [WKWebView] = []
        for browser in cache.values {
            guard let url = browser.url, let zimFileID = url.zimFileID,
                  let front = await ZimFileService.shared.getMainPageURL(zimFileID: zimFileID),
                  url.contentPath == front.contentPath else { continue }
            found.append(browser.webView)
        }
        return found
    }

    /// PrepareMe app: every tab's web view, for the phone's role marks when the role changes (F-092).
    static func everyWebView() -> [WKWebView] {
        cache?.values.map(\.webView) ?? []
    }

    nonisolated static func keepOnlyTabsByIds(_ ids: Set<NSManagedObjectID>) {
        Task { @MainActor in
            if let cache {
                for browser in cache.removeNotMatchingWith(keys: ids) {
                    await browser.destroy()
                }
            }
        }
    }
    
    // MARK: - Properties

    @Published private(set) var isLoading: Bool?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var articleTitle: String = ""
    @Published var zimFileName: String = ""
    @Published private(set) var articleBookmarked = false
    @Published private(set) var outlineItems = [OutlineItem]()
    @Published private(set) var outlineItemTree = [OutlineItem]()
    @MainActor @Published private(set) var hasURL: Bool = false
    @MainActor @Published private(set) var url: URL? {
        didSet {
            if !FeatureFlags.hasLibrary, url == nil {
                loadMainArticle()
            }
            if url != oldValue {
                bookmarkFetchedResultsController.fetchRequest.predicate = Self.bookmarksPredicateFor(url: url)
                try? bookmarkFetchedResultsController.performFetch()
            }
            hasURL = url != nil
        }
    }
    @MainActor var zimFileId: UUID? { url?.zimFileID }
    @Published var externalURL: URL?
    private var metaData: URLContentMetaData?
    private let cookieStore = CookieStore.shared

#if os(macOS)
    private var windowURLs: [URL] {
        UserDefaults.standard[.windowURLs]
    }
#endif
    let webView: WKWebView
    let tabID: NSManagedObjectID
    private var geolocationService: GeolocationService?
    private var pageEndedAt: Date?  // games plan phase 2: when the device last ended this tab's page process
    private var isLoadingObserver: NSKeyValueObservation?
    private var canGoBackObserver: NSKeyValueObservation?
    private var canGoForwardObserver: NSKeyValueObservation?
    private var titleURLObserver: AnyCancellable?
    #if PREPAREME_APP
    private var redNightObserver: AnyCancellable?  // phase D: an open page follows the switch
    #endif
    private let bookmarkFetchedResultsController: NSFetchedResultsController<Bookmark>
    /// Maps to injected javascript: window.webkit?.messageHandlers.*
    private let jsHandlers = ["headings", "geolocation", "scrollHandler", "zimCookies"]

    // MARK: - Lifecycle

    // swiftlint:disable:next function_body_length
    @MainActor private init(tabID: NSManagedObjectID) {
        self.tabID = tabID
        #if PREPAREME_APP && os(macOS)
        webView = PrepareMeWebView(frame: .zero, configuration: WebViewConfiguration())  // News's right-click marks
        #else
        webView = WKWebView(frame: .zero, configuration: WebViewConfiguration())
        #endif
        if !Bundle.main.isProduction {
                webView.isInspectable = true
        }
        // Bookmark fetching:
        bookmarkFetchedResultsController = NSFetchedResultsController(
            fetchRequest: Bookmark.fetchRequest(), // initially empty
            managedObjectContext: Database.shared.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        super.init()

        bookmarkFetchedResultsController.delegate = self

        // configure web view
        webView.allowsBackForwardNavigationGestures = true
        webView.configuration.defaultWebpagePreferences.preferredContentMode = .mobile // for font adjustment to work
        jsHandlers.forEach { handler in
            webView.configuration.userContentController.removeScriptMessageHandler(forName: handler)
            webView.configuration.userContentController.add(self, name: handler)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self

        restoreBy(tabID: tabID)

        #if PREPAREME_APP
        redNight()
        redNightObserver = NotificationCenter.default.publisher(for: PrepareMeRedNight.changed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.redNight()
                    self?.webView.evaluateJavaScript(PrepareMeRedNight.push(on: PrepareMeRedNight.shared.on))
                }
            }
        #endif

        // get outline items if something is already loaded
        if webView.url != nil {
            webView.evaluateJavaScript("getOutlineItems();")
        }

        // setup web view property observers
        canGoBackObserver = webView.observe(\.canGoBack, options: .initial) { [weak self] webView, _ in
            Task { [weak self] in
                await MainActor.run { [weak self] in
                    self?.canGoBack = webView.canGoBack
                }
            }
        }
        canGoForwardObserver = webView.observe(\.canGoForward, options: .initial) { [weak self] webView, _ in
            Task { [weak self] in
                await MainActor.run { [weak self] in
                    self?.canGoForward = webView.canGoForward
                }
            }
        }
        titleURLObserver = Publishers.CombineLatest(
            webView.publisher(for: \.title, options: .initial),
            webView.publisher(for: \.url, options: .initial)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] title, url in
            guard let title, let url else { return }
            self?.didUpdate(title: title, url: url)
        }
        isLoadingObserver = webView.observe(\.isLoading, options: .new) { [weak self] _, change in
            Task { @MainActor [weak self] in
                if change.newValue != self?.isLoading {
                    self?.isLoading = change.newValue
                }
                if change.newValue == false {
                    BrowserTabPreloader.shared.didLoadFirstBrowserTab()
                }
            }
        }
    }
    
    deinit {
        debugPrint("🧨 BrowserViewModel deinit 🧨")
    }

    @MainActor
    func destroy() async {
        bookmarkFetchedResultsController.delegate = nil
        canGoBackObserver?.invalidate()
        canGoForwardObserver?.invalidate()
        titleURLObserver?.cancel()
        isLoadingObserver?.invalidate()
        geolocationService?.stopAll()
        let contentController = webView.configuration.userContentController
        jsHandlers.forEach { handler in
            contentController.removeScriptMessageHandler(forName: handler)
        }
        contentController.removeAllUserScripts()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        #if os(iOS)
        webView.scrollView.delegate = nil
        #endif
        await clear()
    }

    @MainActor
    func clear() async {
        await webView.setAllMediaPlaybackSuspended(true)
        await webView.closeAllMediaPresentations()
        webView.stopLoading()
        url = nil
        articleTitle = ""
        zimFileName = ""
        outlineItems = []
        outlineItemTree = []
        // !important to make the webView disappear,
        // until new content is not starting to load
        // as complete clear of webView is not possible
        isLoading = nil
    }

    /// Get the webpage in a binary format
    /// - Returns: PDF of the current page (if text type) or binary data of the content
    /// and the file extension, if known
    func pageDataWithExtension() async -> (Data, String?)? {
        #if PREPAREME_APP && os(macOS)
        let pagePDF = { try await self.paperPDF() }  // the Mac's Share as its Print: paged, light (2026-11-14)
        #else
        let pagePDF = { try await self.printablePDF() }
        #endif
        if metaData?.isTextType == true,
           let pdfData = try? await pagePDF() {
            return (pdfData, metaData?.exportFileExtension)
        } else if let url = webView.url,
                  let contentData = await ZimFileService.shared.getURLContent(url: url)?.data {
            let pathExtesion = url.pathExtension
            let fileExtension: String?
            if !pathExtesion.isEmpty {
                fileExtension = pathExtesion
            } else {
                fileExtension = metaData?.exportFileExtension
            }
            return (contentData, fileExtension)
        }
        return nil
    }

    func forceLoadingState() {
        isLoading = true
    }

    private func didUpdate(title: String, url: URL) {
        let zimFile: ZimFile? = {
            guard let zimFileID = url.zimFileID else { return nil }
            return try? Database.shared.viewContext.fetch(ZimFile.fetchRequest(fileID: zimFileID)).first
        }()

        Task { @MainActor in
            metaData = await ZimFileService.shared.getContentMetaData(url: url)
            if title.isEmpty {
                articleTitle = metaData?.zimTitle ?? ""
            } else {
                articleTitle = title
            }
            // update view model
            zimFileName = zimFile?.name ?? ""
            self.url = url

            // update tab data
            let context = Database.shared.viewContext
            if let tab = try? context.existingObject(with: tabID) as? Tab {
                tab.title = articleTitle
#if os(iOS)
                // navigating from empty tab to a zimfile
                let isNavigatingAwayFromEmptyTab = tab.zimFile == nil && zimFile != nil
                if isNavigatingAwayFromEmptyTab {
                    // set back the date of creation of this tab to now
                    // new tabs are created with a distant future date
                    // so they always come first
                    tab.created = Date()
                }
                defer {
                    if isNavigatingAwayFromEmptyTab {
                        NotificationCenter.default.post(name: .enforceOneEmptyTab, object: nil)
                    }
                }
#endif
                tab.zimFile = zimFile
            }
            if context.hasChanges {
                try? context.save()
            }
            #if os(macOS)
            disableVideoContextMenu()
            #endif
        }
    }

    @MainActor
    func updateLastOpened() async {
        let currentTabID = tabID
        await Database.shared.viewContext.perform {
            let context = Database.shared.viewContext
            guard let tab = try? context.existingObject(with: currentTabID) as? Tab else {
                return
            }
            tab.lastOpened = Date()
            try? context.save()
        }
    }

    @MainActor
    func persistState() async {
        // PrepareMe: never while the page is still loading: that state holds only the page's address, which WebKit
        // loads again by itself when the tab is restored, racing the app's own first page (the beta run's F69); the
        // tab keeps the state it had
        guard !webView.isLoading else { return }
        let webData = webView.interactionState as? Data
        let currentTabID = tabID
        await Database.shared.viewContext.perform {
            let context = Database.shared.viewContext
            guard let tab = try? context.existingObject(with: currentTabID) as? Tab else {
                return
            }
            tab.interactionState = webData
            if context.hasChanges {
                try? context.save()
            }
        }
    }

    // MARK: - Content Loading
    @MainActor
    func load(url: URL) {
        guard webView.url != url else {
            return
        }
        webView.load(URLRequest(url: url))
        self.url = url
    }
    
    private func injectCookiesFor(url: URL) {
        if let zimFileID = url.zimFileID, let jsScript = injectCookieJSScriptFor(zimFileID: zimFileID) {
            webView.evaluateJavaScript(jsScript) { _, error in
                if let error {
                    Log.Cookies.error("unable to inject zimCookies: \(error.localizedDescription, privacy: .public)")
                } else {
                    Log.Cookies.debug("injected cookies for: \(zimFileID.uuidString)\n\(jsScript)")
                }
            }
        }
    }
    
    private func injectCookieJSScriptFor(zimFileID: UUID) -> String? {
        guard let jsonValues: String = cookieStore.getAllFor(zimFileID: zimFileID) else {
            Log.Cookies.debug("no ZIM Cookies for: \(zimFileID.uuidString)")
            return nil
        }
        return "setZIMCookies(\(String(reflecting: jsonValues)));"
    }

    @MainActor
    func loadRandomArticle(zimFileID: UUID? = nil) {
        let zimFileID = zimFileID ?? webView.url?.zimFileID
        Task { @ZimActor [weak self] in
            guard let url = ZimFileService.shared.getRandomPageURL(zimFileID: zimFileID) else { return }
            await MainActor.run { [weak self] in
                self?.load(url: url)
            }
        }
    }

    @MainActor
    func loadMainArticle(zimFileID: UUID? = nil) {
        let zimFileID = zimFileID ?? webView.url?.zimFileID
        Task { @ZimActor [weak self] in
            guard let url = ZimFileService.shared.getMainPageURL(zimFileID: zimFileID) else { return }
            await MainActor.run { [weak self] in
                self?.load(url: url)
            }
        }
    }

    private func restoreBy(tabID: NSManagedObjectID) {
        if let tab = try? Database.shared.viewContext.existingObject(with: tabID) as? Tab {
            webView.interactionState = tab.interactionState
            if webView.url != nil {
                // make sure category(.list) is not displayed
                // while restoring a tab
                isLoading = true
            }
            Task { [weak self] in
                await MainActor.run { [weak self] in
                    // migrate the tab urls on demand to ZIM scheme
                    self?.url = self?.webView.url?.updatedToZIMSheme()
                    if let webURL = self?.webView.url, webURL.isKiwixURL {
                        self?.load(url: webURL.updatedToZIMSheme())
                    }
                }
            }
        }
    }

    // MARK: - Video fixes
    func pauseVideoWhenNotInPIP() {
        // webView.pauseAllMediaPlayback() is not good enough
        // as that pauses in Picture in Picture mode as well.
        // Detecting PiP on a AVPictureInPictureController created by WKWebView
        // is currently non-trivial from the swift side
        webView.evaluateJavaScript("pauseVideoWhenNotInPIP();")
    }

    @MainActor
    func refreshVideoState() {
        Task { [weak webView] in
            await MainActor.run { [weak webView] in
                webView?.evaluateJavaScript("refreshVideoState();")
            }
        }
    }

    #if os(macOS)
    /// Disable the right-click context menu on video components
    @MainActor
    func disableVideoContextMenu() {
        webView.evaluateJavaScript("disableVideoContextMenu();")
    }
    #endif

    // MARK: - New Tab Creation

#if os(macOS)
    @MainActor
    @discardableResult func createNewWindow(with url: URL) -> Bool {
        guard let currentWindow = NSApp.keyWindow,
              let windowController = currentWindow.windowController else { return false }
        let context = Database.shared.viewContext
        // create a new Tab DB object, and a new BrowserViewModel (which creates a new WKWebView)
        // and pre-load the url into that
        let newTab = NavigationViewModel.makeTab(context: context)
        let newTabID = newTab.objectID
        BrowserViewModel.getCached(tabID: newTabID).load(url: url)

        // store the tabID statically, so that the new window can pick it up
        NavigationViewModel.tabIDToUseOnNewTab = newTabID

        windowController.newWindowForTab(nil)
        guard let newWindow = NSApp.keyWindow, currentWindow != newWindow else {
            // rather impossible case, but rolling back everything from above
            NavigationViewModel.tabIDToUseOnNewTab = nil
            context.delete(newTab)
            if context.hasChanges {
                try? context.save()
            }
            return false
        }
        currentWindow.addTabbedWindow(newWindow, ordered: .above)
        return true
    }
#endif

    // MARK: - WKNavigationDelegate

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    @MainActor func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame == true else {
            if navigationAction.request.url?.isZIMURL == true {
                // Allow to load iFrame content via src-doc instead of external src
                return .allow
            } else {
                return .cancel
            }
        }
        #if PREPAREME_APP && os(iOS)
        // Tap-to-call (B2-15): the number to dial only for a link activation (a tapped link, or a script's click on an
        // anchor, which WebKit reports the same way; CallLinks.telURL allows the two numbers only); any other
        // prepareme://call navigation (a script's location change, a form) is dropped, and the app's own address
        // never dials (onOpenURL)
        if let link = navigationAction.request.url, link.scheme == "prepareme", link.host == CallLinks.host {
            if let tel = CallLinks.dial(link, linkActivated: navigationAction.navigationType == .linkActivated,
                                        also: await Self.callNumbers?() ?? []) {
                await UIApplication.shared.open(tel)
            }
            return .cancel
        }
        #endif
        #if PREPAREME_APP && os(macOS)
        // News's marks (news plan Task 3.4): only a click on a mark's link in the News page itself, made in this
        // reader; any other way to the address (a script, another page, Mail or a link from outside) makes no mark
        // (the second review's findings 3 and 4). sourceFrame can be missing for a navigation from outside.
        if let link = navigationAction.request.url, let mark = NewsMark.parse(link) {
            if navigationAction.navigationType == .linkActivated,
               PrepareMeNewsMarks.isNewsPage((navigationAction.sourceFrame as WKFrameInfo?)?.request.url) {
                PrepareMeNewsMarks.shared.handle(mark, in: webView)
            }
            return .cancel
        }
        #endif
        if let link = navigationAction.request.url, link.scheme == "prepareme", Self.appLink?(link) == true {
            return .cancel
        }
        #if PREPAREME_APP && os(macOS)
        // a clicked link to the library's phone-width Inventory page: the Mac's Inventory screen (owner, 2026-10-28)
        if navigationAction.navigationType == .linkActivated, let link = navigationAction.request.url,
           MacRow.isInventoryPage(link), Self.appLink?(link) == true {
            return .cancel
        }
        #endif
        guard let url = navigationAction.request.url?.updatedToZIMSheme() else {
            return .cancel
        }

#if os(macOS) && !PREPAREME_APP // PrepareMe: one main window (Mac sidebar plan, part 2); a ⌘-click is a click
        // detect cmd + click event
        if navigationAction.modifierFlags.contains(.command) {
            if createNewWindow(with: url) {
                return .cancel
            }
        }
#endif

        if url.isZIMURL, let redirectedURL = await ZimFileService.shared.getRedirectedURL(url: url) {
            if webView.url != redirectedURL {
                webView.load(URLRequest(url: redirectedURL))
            }
            return .cancel
        } else if url.isZIMURL {
            guard await ZimFileService.shared.getContentSize(url: url) != nil else {
                let urlString = url.absoluteString
                let path = url.contentPath
                Log.URLSchemeHandler.error(
                    "Missing content at url: \(urlString, privacy: .public) => \(path, privacy: .public)"
                )
                if navigationAction.request.mainDocumentURL == url, Self.missingLibrary?(url) == true {
                    return .cancel // PrepareMe app: the get-file sheet instead of the alert
                }
                #if PREPAREME_APP
                // Back or Forward onto a page this copy of the library no longer has (a tab keeps its back list across
                // launches and new copies): no alert, the step goes past it (owner's phone, 2026-10-21)
                if navigationAction.navigationType == .backForward, navigationAction.request.mainDocumentURL == url {
                    skipGone(url)
                    return .cancel
                }
                #endif
                if navigationAction.request.mainDocumentURL == url {
                    // only show alerts for missing main document
                    #if PREPAREME_APP  // in PrepareMe's own words (BackSkip.goneWords)
                    NotificationCenter.default.post(
                        name: .alert, object: nil,
                        userInfo: ["alert": ActiveAlert.articleFailedToLoad, BackSkip.goneKey: true]
                    )
                    #else
                    NotificationCenter.default.post(
                        name: .alert,
                        object: nil,
                        userInfo: ["alert": ActiveAlert.articleFailedToLoad]
                    )
                    #endif
                }
                return .cancel
            }
            return .allow
        } else if url.isUnsupported {
            externalURL = url
            return .cancel
        } else if url.isGeoURL {
            if FeatureFlags.map {
                let _: CLLocation? = {
                    let parts = url.absoluteString.replacingOccurrences(of: "geo:", with: "").split(separator: ",")
                    guard let latitudeString = parts.first,
                          let longitudeString = parts.last,
                          let latitude = Double(latitudeString),
                          let longitude = Double(longitudeString) else { return nil }
                    return CLLocation(latitude: latitude, longitude: longitude)
                }()
            } else {
                let coordinate = url.absoluteString.replacingOccurrences(of: "geo:", with: "")
                if let url = URL(string: "http://maps.apple.com/?ll=\(coordinate)") {
#if os(macOS)
                    NSWorkspace.shared.open(url)
#elseif os(iOS)
                    await UIApplication.shared.open(url)
#endif
                }
            }
            return .cancel
        } else {
            return .cancel
        }
    }

    private var canShowMimeType = true
    #if PREPAREME_APP
    /// Phase D: whether the page shown is a PDF, which the red night screen shows in its own viewer
    /// (PrepareMeRedNight.showPDF).
    private var showsPDF = false
    /// The back list's entry of the page on screen, as of its commit: which way a step onto a gone page was going.
    private var shownItem: WKBackForwardListItem?

    /// A back or forward step onto `gone`, a page the library no longer has, cancelled: on past it instead, to the
    /// entry before it going back (the tab's first page when there's none) or after it going forward (BackSkip). The
    /// step starts once the cancel is through, which puts the list back on the page on screen; an entry it lands on
    /// that is gone too is skipped the same way, further on.
    @MainActor private func skipGone(_ gone: URL) {
        let list = webView.backForwardList
        guard let current = list.currentItem else { return }
        let items = list.backList + [current] + list.forwardList
        let shown = shownItem.flatMap { shown in items.firstIndex { $0 === shown } }
        switch BackSkip.step(entries: items.map { $0.url.updatedToZIMSheme() }, cursor: list.backList.count,
                             gone: gone, shown: shown) {
        case .go(let index):
            let item = items[index]
            Task { @MainActor [weak self] in self?.webView.go(to: item) }
        case .startPage:
            let urls = items.map { $0.url.updatedToZIMSheme() }
            Task { @MainActor [weak self] in
                guard let self, let start = await Self.startPage?(self) else { return }
                // already on it (the guide list, everything behind it gone): it stays, never a second entry of it
                if let shown, !PagePlace.isNewPage(from: start, to: urls[shown]) { return }
                if let entry = BackSkip.startEntry(entries: urls, start: start, shown: shown) {
                    self.webView.go(to: items[entry])  // its entry already in the list: the list doesn't grow
                } else {
                    self.webView.load(URLRequest(url: start))
                }
            }
        case .stay:
            break
        }
    }

    /// The red night screen as it now stands, on this tab's web view.
    @MainActor private func redNight() {
        let red = PrepareMeRedNight.shared.on
        PrepareMeRedNight.surface(webView, red: red)
        guard red, showsPDF, let url = webView.url else {
            PrepareMeRedNight.showPDF(nil, over: webView)
            return
        }
        Task { [weak self] in
            let data = await ZimFileService.shared.getURLContent(url: url)?.data
            guard let self, self.webView.url == url, self.showsPDF, PrepareMeRedNight.shared.on else { return }
            PrepareMeRedNight.showPDF(data, over: self.webView)
        }
    }

    /// The page as a PDF for Print and Share, in its own colors even while red: the page script set aside while it
    /// is made, so the paper isn't black.
    @MainActor func printablePDF() async throws -> Data {
        let red = PrepareMeRedNight.shared.on
        if red { _ = try? await webView.evaluateJavaScript(PrepareMeRedNight.push(on: false)) }
        defer { if red { webView.evaluateJavaScript(PrepareMeRedNight.push(on: true)) } }
        return try await webView.pdf()
    }

    #if os(macOS)
    /// The page as paper for File › Print (games plan phase 5, owner 2026-11-14): WebKit's own print, so it runs over
    /// letter pages and the page's print style applies, in the light look on a dark Mac, saved to a PDF the print
    /// panel then shows. printablePDF's one long screen-colored page printed black and shrunk onto one sheet.
    /// A PDF shown in the reader, or a tab with no window, keeps printablePDF.
    @MainActor func paperPDF() async throws -> Data {
        guard !showsPDF, let window = webView.window else { return try await printablePDF() }
        let red = PrepareMeRedNight.shared.on
        if red { _ = try? await webView.evaluateJavaScript(PrepareMeRedNight.push(on: false)) }
        let look = webView.appearance
        webView.appearance = NSAppearance(named: .aqua)
        defer {
            webView.appearance = look
            if red { webView.evaluateJavaScript(PrepareMeRedNight.push(on: true)) }
        }
        try await Task.sleep(for: .milliseconds(200))  // the page's colors follow the light look first
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PrepareMe print \(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds  // without it WebKit prints blank pages
        guard await PaperRun(operation, in: window).finished() else { throw CocoaError(.fileWriteUnknown) }
        return try Data(contentsOf: url)
    }
    #endif
    #else
    @MainActor func printablePDF() async throws -> Data { try await webView.pdf() }
    #endif

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @MainActor @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        canShowMimeType = navigationResponse.canShowMIMEType
        #if PREPAREME_APP
        if navigationResponse.isForMainFrame { showsPDF = navigationResponse.response.mimeType == "application/pdf" }
        #endif
        guard canShowMimeType else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Games plan phase 2 (owner, 2026-11-14): the device ended the page's process to save memory (a heavy game,
    /// usually), which leaves a blank tab. Reload once; ended again within a minute, the note instead, so it never loops.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        defer { pageEndedAt = now }
        if let last = pageEndedAt, now.timeIntervalSince(last) < 60 {
            NotificationCenter.default.post(name: .alert, object: nil, userInfo: ["alert": ActiveAlert.pageEnded])
        } else {
            webView.reload()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The previous document's geolocation callbacks are gone
        geolocationService?.stopAll()
        outlineItems = []
        #if PREPAREME_APP
        redNight()  // a PDF in the red viewer, a page not
        shownItem = webView.backForwardList.currentItem
        #endif
    }

    @MainActor
    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        webView.evaluateJavaScript(Self.keepsFoldsAsBuilt ? "getOutlineItems();" : "expandAllDetailTags(); getOutlineItems();")
#if os(iOS)
        // on iOS 17 on the iPhone, the video starts with a black screen
        // if there's a poster attribute
        if Device.current == .iPhone {
            webView.evaluateJavaScript("fixVideoElements();")
        }
        webView.adjustTextSize()
        Self.pageFinished?(webView)
#else
        Task { await persistState() }
        #if PREPAREME_APP
        Self.pageFinished?(webView)  // the Mac's reader fills Our Home pages too (Task 2.4)
        #endif
#endif
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: Error
    ) {
        let error = error as NSError
        // PrepareMe: a load cancelled by the next one is already stopped. Stopping here, a moment later, stopped the
        // next load instead and left the page loading for good (the beta run's F69, 2026-10-16).
        guard !Self.replacedByNextLoad(error, canShowMimeType: canShowMimeType) else { return }
        Task { @MainActor in
            webView.stopLoading()
            (webView.configuration
                .urlSchemeHandler(forURLScheme: KiwixURLSchemeHandler.ZIMScheme) as? KiwixURLSchemeHandler)?
                .didFailProvisionalNavigation()
        }
        guard canShowMimeType else {
            guard let kiwixURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL else {
                return
            }
            NotificationCenter.saveContent(url: kiwixURL)
            return
        }
        // PrepareMe app: a page whose library is held but not yet open, just after a start, is loaded again once it
        // is (as decidePolicy does for missing content): no failure alert (the beta run's F69)
        if let failed = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.updatedToZIMSheme(), failed.isZIMURL,
           Self.missingLibrary?(failed) == true {
            return
        }
        NotificationCenter.default.post(
            name: .alert, object: nil, userInfo: ["alert": ActiveAlert.articleFailedToLoad]
        )
    }

    /// PrepareMe: a provisional load the next load replaced, which is no failure. WebKit says "cancelled" (-999), or
    /// "interrupted" (WebKitErrorDomain 102): the owner's Mac, 2026-11-14, where Today asked for twice took the second
    /// for a failure, showed "Unable to load the page requested" and stopped the second load, a blank Today with a
    /// spinner (PrepareMeReplacedLoadTests). 102 also follows our own refusal of a type the page can't show, which
    /// `canShowMimeType` tells apart and the handler saves.
    nonisolated static func replacedByNextLoad(_ error: NSError, canShowMimeType: Bool) -> Bool {
        if error.code == NSURLErrorCancelled { return true }
        return canShowMimeType && error.domain == "WebKitErrorDomain" && error.code == 102
    }

    // MARK: - WKScriptMessageHandler

    @MainActor // swiftlint:disable:next cyclomatic_complexity
    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "headings", let headings = message.body as? [[String: String]] {
            self.generateOutlineList(headings: headings)
            self.generateOutlineTree(headings: headings)
        } else if message.name == "geolocation" {
            // PrepareMe (games plan phase 2; owner, 2026-11-14): off for every library page, so a game's or a
            // downloaded site's code never reaches the position. The page script stays: it stands in for the
            // browser's own navigator.geolocation, which would otherwise ask by itself. No PrepareMe page uses it.
            Task { await respondToJSWithGeolocation(response: GeolocationError.permissionDenied) }
        } else if message.name == "zimCookies", let body = message.body as? String {
            if body == "zimCookieStoreReady" {
                Log.Cookies.debug("zimCookieStoreReady")
                if let url = webView.url {
                    injectCookiesFor(url: url)
                }
            } else if let zimFileId {
                cookieStore.save(zimFileID: zimFileId, cookies: body)
            }
        } else if !Brand.disableImmersiveReading, message.name == "scrollHandler" {
            switch message.body as? String {
            case "up": NotificationCenter.default
                    .post(name: .webViewDidScroll, object: webView, userInfo: ["direction": "up"])
            case "down": NotificationCenter.default
                    .post(name: .webViewDidScroll, object: webView, userInfo: ["direction": "down"])
            default: break
            }
        }
    }
    
    // MARK: - Geolocation
    
    private func ensureGeolocationService() -> GeolocationService {
        if let service = geolocationService { return service }
        let service = GeolocationService { [weak self] jsResponse in
            Task {
                await self?.respondToJSWithGeolocation(response: jsResponse)
            }
        }
        geolocationService = service
        return service
    }

    private func respondToJSWithGeolocation(response: JSRespondable) async {
        do {
            _ = try await webView.callAsyncJavaScript(
                "window.__kiwixGeolocationResolve(payload);",
                arguments: ["payload": response.jsResponse],
                in: nil,
                contentWorld: .page
            )
        } catch let error as NSError where error.domain == WKError.errorDomain
            && (error.code == WKError.webContentProcessTerminated.rawValue
                || error.code == WKError.webViewInvalidated.rawValue) {
            // Page is gone — expected during teardown, no signal worth keeping.
        } catch {
            let message = error.localizedDescription
            Log.Geolocation.error(
                "respondToJSWithGeolocation failed: \(message, privacy: .public)"
            )
        }
    }

    // MARK: - WKUIDelegate

#if os(macOS)
    @MainActor
    func webView(
        _: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        guard let newUrl = navigationAction.request.url else { return nil }

        // open external link in default browser
        guard newUrl.isUnsupported == false else {
            externalURL = newUrl
            return nil
        }

        #if PREPAREME_APP
        // PrepareMe: one main window (Mac sidebar plan, part 2): a link that asks for a new window opens as any link
        // does, in its row's reading tab
        PrepareMeMacTabs.shared.open(newUrl)
        #else
        createNewWindow(with: newUrl)
        #endif
        return nil
    }
#else
    @MainActor
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let newURL = navigationAction.request.url else { return nil }
        if let frame = navigationAction.targetFrame, frame.isMainFrame {
            return nil
        }
        guard newURL.isUnsupported == false else {
            externalURL = newURL
            return nil
        }
        NotificationCenter.openURL(newURL, inNewTab: true)
        return nil
    }
#endif

#if os(iOS)
    
    // swiftlint:disable:next function_body_length
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo
    ) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL, url.isZIMURL else { return nil }
        let configuration = UIContextMenuConfiguration(
            previewProvider: {
                let webView = WKWebView(frame: .zero, configuration: WebViewConfiguration())
                if !Bundle.main.isProduction {
                    webView.isInspectable = true
                }
                #if PREPAREME_APP
                MainActor.assumeIsolated { PrepareMeRedNight.surface(webView, red: PrepareMeRedNight.shared.on) }
                #endif
                webView.load(URLRequest(url: url))
                return WebViewController(webView: webView)
            },
            actionProvider: { [weak self] _ in
                guard let self else { return UIMenu(children: []) }
                var actions = [UIAction]()
                
                // open url
                actions.append(
                    UIAction(title: LocalString.common_dialog_button_open,
                             image: UIImage(systemName: "doc.text")) { [weak self] _ in
                                 self?.webView.load(URLRequest(url: url))
                             }
                )
                // bookmark
                let bookmarkAction: UIAction = { [weak self] in
                    let context = Database.shared.viewContext
                    let predicate = NSPredicate(format: "articleURL == %@", url as CVarArg)
                    let request = Bookmark.fetchRequest(predicate: predicate)
                    
                    if let bookmarks = try? context.fetch(request),
                       !bookmarks.isEmpty {
                        return UIAction(title: LocalString.common_dialog_button_remove_bookmark,
                                        image: UIImage(systemName: "star.slash.fill")) { [weak self] _ in
                            self?.deleteBookmark(url: url)
                        }
                    } else {
                        return UIAction(
                            title: LocalString.common_dialog_button_bookmark,
                            image: UIImage(systemName: "star")
                        ) { [weak self] _ in
                            Task { @MainActor [weak self] in self?.createBookmark(url: url) }
                        }
                    }
                }()
                actions.append(bookmarkAction)
                
                return UIMenu(children: actions)
            }
        )
        return configuration
    }
#endif

    // MARK: - Bookmark

    nonisolated func controller(_: NSFetchedResultsController<NSFetchRequestResult>,
                                didChangeContentWith snapshot: NSDiffableDataSourceSnapshotReference) {
        let isEmpty: Bool = snapshot.itemIdentifiers.isEmpty
        Task { @MainActor in
            articleBookmarked = !isEmpty
        }
    }

    @MainActor 
    func createBookmark(url: URL? = nil) {
        guard let url = url ?? webView.url,
              let zimFileID = url.zimFileID else { return }
        let title = webView.title
        Task {
            guard let metaData = await ZimFileService.shared.getContentMetaData(url: url) else { return }
            await Database.shared.viewContext.perform {
                let context = Database.shared.viewContext
                let bookmark = Bookmark(context: context)
                bookmark.articleURL = url
                bookmark.created = Date()
                guard let zimFile = try? context.fetch(ZimFile.fetchRequest(fileID: zimFileID)).first else { return }

                bookmark.zimFile = zimFile
                bookmark.title = title ?? metaData.zimTitle
                try? context.save()
            }
        }
    }

    func deleteBookmark(url: URL? = nil) {
        guard let url = url ?? webView.url else { return }
        Task {
            await Database.shared.viewContext.perform {
                let context = Database.shared.viewContext
                let request = Bookmark.fetchRequest(predicate: NSPredicate(format: "articleURL == %@", url as CVarArg))
                guard let bookmark = try? context.fetch(request).first else { return }
                context.delete(bookmark)
                try? context.save()
            }
        }
    }

    // MARK: - Outline

    /// Scroll to an outline item
    /// - Parameter outlineItemID: ID of the outline item to scroll to
    func scrollTo(outlineItemID: String) {
        webView.evaluateJavaScript("scrollToHeading('\(outlineItemID)')")
    }

    /// Convert flattened heading element data to a list of OutlineItems.
    /// - Parameter headings: list of heading element data retrieved from webview
    @MainActor private func generateOutlineList(headings: [[String: String]]) {
        let allLevels = headings.compactMap { Int($0["tag"]?.suffix(1) ?? "") }
        let offset = allLevels.filter { $0 == 1 }.count == 1 ? 2 : allLevels.min() ?? 0
        let outlineItems: [OutlineItem] = headings.enumerated().compactMap { index, heading in
            guard let id = heading["id"],
                  let text = heading["text"],
                  let tag = heading["tag"],
                  let level = Int(tag.suffix(1)) else { return nil }
            return OutlineItem(id: id, index: index, text: text, level: max(level - offset, 0))
        }
        self.outlineItems = outlineItems
    }

    /// Convert flattened heading element data to a tree of OutlineItems.
    /// - Parameter headings: list of heading element data retrieved from webview
    @MainActor private func generateOutlineTree(headings: [[String: String]]) {
        outlineItemTree = TableOfContents.generateOutlineTree(headings: headings, articleTitle: articleTitle)
    }

    private static func bookmarksPredicateFor(url: URL?) -> NSPredicate? {
        guard let url else { return nil }
        return NSPredicate(format: "articleURL == %@", url as CVarArg)
    }
}

#if PREPAREME_APP && os(macOS)
/// One sheet-modal print operation, awaited (runModal reports through an Objective-C selector). WebKit spools on a
/// thread of its own and the report comes from there: kept on the main thread, the print deadlocks (2026-11-14).
@MainActor private final class PaperRun: NSObject {
    private let operation: NSPrintOperation
    private let window: NSWindow
    private nonisolated(unsafe) var done: CheckedContinuation<Bool, Never>?  // set before the run, taken once

    init(_ operation: NSPrintOperation, in window: NSWindow) {
        self.operation = operation
        self.window = window
    }

    func finished() async -> Bool {
        await withCheckedContinuation { continuation in
            done = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(ran(_:success:context:)), contextInfo: nil)
        }
    }

    @objc private nonisolated func ran(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        done?.resume(returning: success)
        done = nil
    }
}
#endif
