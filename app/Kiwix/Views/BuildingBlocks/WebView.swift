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
import SwiftUI
import WebKit
import Defaults
#if PREPAREME_APP
import PrepareMeShared  // BarTuck (FINDINGS F-079), TextSizeZoom
#endif

#if os(macOS)
struct WebView: NSViewRepresentable {
    @ObservedObject var browser: BrowserViewModel
    
    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        let webView = browser.webView
        enableAutoLayout(nsView: nsView, webView: webView)
        return nsView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(view: self,
                    onChangingFullscreen: { (enters: Bool, webView: WKWebView) in
            guard let nsView = webView.superview else { return }
            if enters {
                // auto-layout is not working
                // when the video is paused in full screen
                disableAutoLayout(nsView: nsView, webView: webView)
            } else {
                enableAutoLayout(nsView: nsView, webView: webView)
            }
        })
    }
    
    @MainActor
    private func enableAutoLayout(nsView: NSView, webView: WKWebView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        nsView.addSubview(webView)
        
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: nsView.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: nsView.safeAreaLayoutGuide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: nsView.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: nsView.safeAreaLayoutGuide.bottomAnchor)
        ])
    }
    
    @MainActor
    private func disableAutoLayout(nsView: NSView, webView: WKWebView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        nsView.addSubview(webView)
    }

    final class Coordinator {
        private let pageZoomObserver: Defaults.Observation
        private let fullScreenObserver: NSKeyValueObservation

        @MainActor
        init(
            view: WebView,
            onChangingFullscreen: @escaping @Sendable @MainActor (_ enters: Bool, _ webView: WKWebView) -> Void
        ) {
            let browser = view.browser
            pageZoomObserver = Defaults.observe(.webViewPageZoom) { [weak browser] change in
                browser?.webView.pageZoom = change.newValue
            }
            fullScreenObserver = view.browser.webView.observe(\.fullscreenState, options: [.new]) { webView, _ in
                Task { @MainActor in
                    switch webView.fullscreenState {
                    case .enteringFullscreen:
                        onChangingFullscreen(true, webView)
                    case .inFullscreen:
                        break
                    case .exitingFullscreen:
                        onChangingFullscreen(false, webView)
                    case .notInFullscreen:
                        break
                    @unknown default:
                        break
                    }
                }
            }
        }
        
        deinit {
            pageZoomObserver.invalidate()
            fullScreenObserver.invalidate()
        }
    }
}

#elseif os(iOS)
struct WebView: UIViewControllerRepresentable {
    @ObservedObject var browser: BrowserViewModel

    func makeUIViewController(context: Context) -> WebViewController {
        WebViewController(webView: browser.webView)
    }

    func updateUIViewController(_ controller: WebViewController, context: Context) { }
}

final class WebViewController: UIViewController {
    private let webView: WKWebView
    private let pageZoomObserver: Defaults.Observation
    private var didScrollTask: Task<Void, Never>?
    #if PREPAREME_APP
    private var offsetWatch: NSKeyValueObservation?
    private var tuck = BarTuck()
    private var textSizeTask: Task<Void, Never>?
    private var pageWatch: NSKeyValueObservation?
    /// Where each web view's page was when its view was last taken down (PagePlace, Task 10.2; F59): the iPad's narrow
    /// and wide layouts are different screens, so a size switch takes the page's view down and puts it up again.
    private static var places: [ObjectIdentifier: (url: URL?, share: Double, at: Date)] = [:]
    private var barsWatch: NSObjectProtocol?
    /// Behind the clock while the bar is tucked away, so the page never runs under it (Task 10.5; F55): the page's
    /// own ground, BASE's --bg.
    private let statusBacking = UIView()
    #endif
    
    init(webView: WKWebView) {
        self.webView = webView
        pageZoomObserver = Defaults.observe(.webViewPageZoom) { change in
            webView.adjustTextSize(pageZoom: change.newValue)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        webView.scrollView.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        
        // The contentInsetAdjustment .automatic is not properly working
        // when we expand / collapse the side bar on iPad
        // So we need a combination of auto-layout horizontally bound to safe-area
        // and setting the top / bottom insets, when they change (eg: toolbar changes on scroll)
        #if PREPAREME_APP
        // UIKit sets the top and bottom insets from the safe area, so WebKit knows the bars cover that part of the page.
        // An inset set by hand (below) is never treated as covered: whenever WebKit placed a page itself (restoring a
        // tab, going back, a page loaded before the bars' height was known), it put the page's top at the screen's top,
        // under the bar, 116 points up on an iPhone (owner, 2026-10-15: Today opened blank after an install). The
        // sides stay pinned to the safe area by the constraints below, so there is no side inset to set.
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        #else
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        #if PREPAREME_APP
        statusBacking.translatesAutoresizingMaskIntoConstraints = false
        statusBacking.backgroundColor = UIColor(PrepareMeColors.color(Palette.bg))
        statusBacking.alpha = 0
        statusBacking.isUserInteractionEnabled = false
        view.addSubview(statusBacking)
        NSLayoutConstraint.activate([
            statusBacking.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBacking.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBacking.topAnchor.constraint(equalTo: view.topAnchor),
            statusBacking.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        ])
        #endif
    }
    
    #if PREPAREME_APP
    /// A page with no bar over it (Today under its room warning row, phase M) left above its top goes back to it: the
    /// search bar's pull (PrepareMeLibrary.showSearchOnce) leaves it there when the row comes after the pull. A page
    /// being dragged stays put.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        statusBacking.alpha = navController?.isNavigationBarHidden == true ? 1 : 0  // never left on behind a bar (review)
        DispatchQueue.main.async { [weak self] in  // once the scroll view has its new insets, after this layout
            guard let scroll = self?.webView.scrollView, scroll.adjustedContentInset.top == 0, scroll.contentOffset.y < 0,
                  !scroll.isDragging, !scroll.isDecelerating else { return }
            scroll.contentOffset.y = 0
        }
    }
    #endif

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        #if !PREPAREME_APP  // UIKit sets them (viewDidLoad)
        webView.scrollView.contentInset = UIEdgeInsets(
            top: view.safeAreaInsets.top,
            left: webView.scrollView.contentInset.left, // unchanged on purpose
            bottom: view.safeAreaInsets.bottom,
            right: webView.scrollView.contentInset.right // unchanged on purpose
        )
        #endif
    }
    
    private var navController: UINavigationController?
    
    /// We want to enable immerse reading experience for our webview
    /// however simply modifying the navController from here has a knock-on effect
    /// on other views, like Hotspot (where the toolbar items are crucial)
    /// so we need to reset things, when we navigate away (parent == nil)
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        #if PREPAREME_APP
        if parent != nil {  // the phone's text size, now and whenever it changes (the beta run's F02)
            webView.adjustTextSize()
            textSizeTask?.cancel()
            textSizeTask = Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIContentSizeCategory.didChangeNotification) {
                    self?.webView.adjustTextSize()
                }
            }
        }
        #endif
        // navigated to webView
        if !Brand.disableImmersiveReading, let parent {
            navController = parent.navigationController
            #if PREPAREME_APP
            // The bars follow the reader's own scrolling, read from the scroll view (BarTuck), not the page script's
            // direction: the bar moving changed the page's position under the script, which turned it back and forth
            // about 20 times a second on Today (FINDINGS F-079). A second call replaces the watch, never doubles it.
            tuck = BarTuck()
            offsetWatch = webView.scrollView.observe(\.contentOffset) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.scrolled(view) }
            }
            // A new page shows the bar, so Back and Search are there (Task 10.2; F16); so does the page put up again
            // after its view was rebuilt, at the place it had (F59)
            showBars()
            // a place saved moments ago, for this page, read once: a rebuild, never an old visit (review)
            if let kept = Self.places.removeValue(forKey: ObjectIdentifier(webView)), kept.share > 0,
               Date().timeIntervalSince(kept.at) < 3, !PagePlace.isNewPage(from: kept.url, to: webView.url) {
                // once the page has reflowed to its new width
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, !PagePlace.isNewPage(from: kept.url, to: webView.url),
                          !webView.scrollView.isDragging, !webView.scrollView.isDecelerating else { return }
                    let scroll = webView.scrollView
                    scroll.contentOffset.y = PagePlace.offset(share: kept.share, inset: scroll.adjustedContentInset.top,
                                                              contentHeight: scroll.contentSize.height,
                                                              viewHeight: scroll.bounds.height)
                }
            }
            pageWatch = webView.observe(\.url, options: [.old, .new]) { [weak self] _, change in
                let (old, new) = (change.oldValue ?? nil, change.newValue ?? nil)
                MainActor.assumeIsolated {
                    guard PagePlace.isNewPage(from: old, to: new) else { return }
                    self?.showBars()
                }
            }
            barsWatch = NotificationCenter.default.addObserver(forName: Notification.Name("prepareme.showBars"),
                                                               object: webView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showBars() }  // the tab bar's Search, a retap to the top
            }
            #else
            didScrollTask = Task { @MainActor in
                for await notif in NotificationCenter.default
                    .notifications(named: .webViewDidScroll) where (notif.object as? WKWebView) === webView {
                    switch notif.userInfo?["direction"] as? String {
                    case "up":
                        navController?.setNavigationBarHidden(false, animated: true)
                        navController?.setToolbarHidden(false, animated: true)
                    case "down":
                        navController?.setNavigationBarHidden(true, animated: true)
                        navController?.setToolbarHidden(true, animated: true)
                    default: break
                    }
                }
            }
            #endif
        }
    }

    #if PREPAREME_APP
    private func showBars() {
        tuck = BarTuck()
        guard let navController, navController.isNavigationBarHidden else { return }
        navController.setNavigationBarHidden(false, animated: true)
        navController.setToolbarHidden(false, animated: true)
        statusBacking.alpha = 0
    }

    private func scrolled(_ view: UIScrollView) {
        guard let navController,
              let hide = tuck.scrolled(offset: view.contentOffset.y, inset: view.adjustedContentInset.top,
                                       hidden: navController.isNavigationBarHidden,
                                       byReader: view.isDragging || view.isDecelerating) else { return }
        navController.setNavigationBarHidden(hide, animated: true)
        navController.setToolbarHidden(hide, animated: true)
        UIView.animate(withDuration: 0.2) { self.statusBacking.alpha = hide ? 1 : 0 }  // the clock's strip (F55)
    }
    #endif
    
    override func willMove(toParent parent: UIViewController?) {
        // we are moving away from the webview, reset things
        if parent == nil {
            navController?.isNavigationBarHidden = false
            navController?.isToolbarHidden = false
            navController?.hidesBarsOnSwipe = false
            navController = nil
            didScrollTask?.cancel()
            didScrollTask = nil
            #if PREPAREME_APP
            offsetWatch?.invalidate()
            offsetWatch = nil
            textSizeTask?.cancel()
            textSizeTask = nil
            pageWatch?.invalidate()
            pageWatch = nil
            barsWatch.map(NotificationCenter.default.removeObserver)
            barsWatch = nil
            statusBacking.alpha = 0
            let scroll = webView.scrollView  // its place, for the view put up again (F59)
            Self.places[ObjectIdentifier(webView)] = (webView.url, PagePlace.share(
                offset: scroll.contentOffset.y, inset: scroll.adjustedContentInset.top,
                contentHeight: scroll.contentSize.height, viewHeight: scroll.bounds.height), Date())
            #endif
        }
        super.willMove(toParent: parent)
        
    }
}

extension WKWebView {
    func adjustTextSize(pageZoom: Double? = nil) {
        #if PREPAREME_APP
        // the reader's Page zoom times the phone's own text size (Settings › Accessibility › Display & Text Size ›
        // Larger Text; the beta run's F02)
        let pageZoom = TextSizeZoom.effective(user: pageZoom ?? Defaults[.webViewPageZoom],
                                              category: UIApplication.shared.preferredContentSizeCategory.rawValue)
        #else
        let pageZoom = pageZoom ?? Defaults[.webViewPageZoom]
        #endif
        #if PREPAREME_APP
        let javascript = TextSizeZoom.script(pageZoom)  // with long words broken past the normal size (Task 3.1)
        #else
        let template = "document.getElementsByTagName('body')[0].style.webkitTextSizeAdjust='%.0f%%'"
        let javascript = String(format: template, pageZoom * 100)
        #endif
        evaluateJavaScript(javascript, completionHandler: nil)
    }
}
#endif
