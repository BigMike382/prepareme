import Combine
import PDFKit
import PrepareMeShared
import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The red night screen (concept-doc plan, phase D; the owner's answers 2026-10-19): one switch per device, kept in this
/// device's defaults (never synced, never sent to the service), off until a person turns it on, never by itself. While
/// on, the app is dark and each of its windows carries a red layer on top that multiplies what is under it, so only
/// the red part of each color is left: pages, the street map, photos, videos and the app's own screens all go red on
/// black (the spike, Task D.1, in the plan's "Found on the way"). The dark palette's text and danger marks keep their
/// bright red; green and blue marks go dim, and every mark keeps its word or shape (CLAUDE.md's dated exception).
/// Pages also get `pageScript`: no white page while red. The keyboard and the status bar, which iOS draws in windows
/// of its own, stay dark grey.
@MainActor
final class PrepareMeRedNight: ObservableObject {
    static let shared = PrepareMeRedNight()
    static let title = RedNight.title

    private let defaults: UserDefaults
    @Published var on: Bool {
        didSet {
            guard on != oldValue else { return }
            defaults.set(on, forKey: RedNight.key)
            apply()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        on = defaults.bool(forKey: RedNight.key)
    }

    // MARK: Pages

    /// Every page's user content controllers, so a change reaches pages opened after it in a tab made before it.
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    func register(_ controller: WKUserContentController) { controllers.add(controller) }

    static func pageScript(on: Bool) -> String { RedNight.pageScript(on: on) }
    static let changed = Notification.Name("PrepareMe.redNightChanged")
    static func push(on: Bool) -> String { RedNight.push(on: on) }

    /// A page's web view while red: see-through, so before its page arrives it shows the dark app behind it rather
    /// than white (bright red under the layer); as built while off (the review: a page with no background of its own
    /// keeps its white then).
    static func surface(_ webView: WKWebView, red: Bool) {
        #if os(iOS)
        webView.isOpaque = !red
        #else
        webView.setValue(!red, forKey: "drawsBackground")
        #endif
    }

    /// A PDF (a topo map, a manual, a reference) is drawn by WebKit, white pages on black, out of the page script's
    /// reach, and no color filter darkens both: its text is black too (found by listing the PDF view's parts on the
    /// simulator, 2026-10-19). So while red, a PDF is shown over its web view in PrepareMe's own viewer, black around
    /// the pages and each page drawn inverted (the owner, by click: "Build the viewer now"). `data` nil takes it away.
    static func showPDF(_ data: Data?, over webView: WKWebView) {
        let shown = webView.subviews.first { $0 is RedPDFView } as? RedPDFView
        guard let data, let document = PDFDocument(data: data) else {
            shown?.removeFromSuperview()
            return
        }
        if let shown, shown.shownData == data { return }
        shown?.removeFromSuperview()
        let view = RedPDFView(frame: webView.bounds)
        #if os(iOS)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        view.autoresizingMask = [.width, .height]
        #endif
        view.show(document, data: data)
        webView.addSubview(view)
    }

    /// PDFKit's view, black around the pages, its pages inverted (InvertedPage).
    final class RedPDFView: PDFView {
        private(set) var shownData: Data?

        func show(_ document: PDFDocument, data: Data) {
            shownData = data
            document.delegate = InvertedPages.shared  // before any page is read, so every page is an InvertedPage
            autoScales = true
            displayMode = .singlePageContinuous
            displaysPageBreaks = true
            pageShadowsEnabled = false
            backgroundColor = .black
            self.document = document
        }
    }

    /// The document's delegate (held here: a document holds its delegate weakly), naming InvertedPage for its pages.
    nonisolated final class InvertedPages: NSObject, PDFDocumentDelegate, @unchecked Sendable {
        static let shared = InvertedPages()
        func classForPage() -> AnyClass { InvertedPage.self }
    }

    /// A page drawn as built, then turned over by difference with white: white paper black, black lines white.
    /// PDFKit draws pages off the main thread (nonisolated, as the street map's scheme handler: CLAUDE.md).
    nonisolated final class InvertedPage: PDFPage, @unchecked Sendable {
        override func draw(with box: PDFDisplayBox, to context: CGContext) {
            super.draw(with: box, to: context)
            context.saveGState()
            context.setBlendMode(.difference)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds(for: box))
            context.restoreGState()
        }
    }

    // MARK: Windows

    private var watching: [AnyCancellable] = []

    /// Called once at launch: lays the red on each window as it appears.
    func start() {
        #if os(iOS)
        let shown = [UIWindow.didBecomeVisibleNotification, UIWindow.didBecomeKeyNotification,
                     UIScene.didActivateNotification]
        #else
        let shown = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didUpdateNotification]
        #endif
        for name in shown {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.layWindows() } }
                .store(in: &watching)
        }
        apply()
    }

    private func apply() {
        layWindows()
        layScripts()
        NotificationCenter.default.post(name: Self.changed, object: nil)  // open pages (BrowserViewModel)
    }

    /// The page scripts laid again as things now stand (this switch, the phone's role: F-092), for pages opened from
    /// now on in tabs made before.
    func layScripts() {
        for controller in controllers.allObjects {
            controller.removeAllUserScripts()
            WebViewConfiguration.addScripts(to: controller)
        }
    }

    #if os(iOS)
    /// A window takes the layer when it is one of the app's own, at the normal level: iOS's text-effects window (level
    /// 10, transparent over everything) painted the whole screen solid red with one (the spike).
    static func takesLayer(level: UIWindow.Level, hidden: Bool) -> Bool { level == .normal && !hidden }

    /// The appearance a window gets: dark while red, else the person's own choice in Settings.
    static func style(red: Bool, chosen: UserColorScheme) -> UIUserInterfaceStyle {
        red ? .dark : chosen.asUserInterfaceStyle
    }

    private func layWindows() {
        let chosen = UserColorScheme(rawValue: UserDefaults.standard.integer(forKey: "userColorScheme")) ?? .system
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where Self.takesLayer(level: window.windowLevel, hidden: window.isHidden) {
                window.overrideUserInterfaceStyle = Self.style(red: on, chosen: chosen)
                // UIKit's own controls (alerts, menus) take the asset tint, the teal, dim in red: the ink while red
                window.tintColor = on ? UIColor(PrepareMeColors.ink) : nil
                let layer = window.subviews.first { $0 is Layer }
                if on, layer == nil {
                    window.addSubview(Layer(frame: window.bounds))
                } else if !on {
                    layer?.removeFromSuperview()
                }
            }
        }
    }

    /// Never takes a touch, and its layer's height above every view (zPosition) keeps it on top of screens, sheets
    /// and menus added after it; it follows the window's size (an iPad turned, Split View).
    final class Layer: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            backgroundColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
            layer.compositingFilter = "multiplyBlendMode"
            layer.zPosition = 1_000_000
        }
        required init?(coder: NSCoder) { fatalError("not from a file") }
    }
    #else
    /// The app's appearance: dark while red, else the person's own choice in Settings.
    static func appearance(red: Bool, chosen: UserColorScheme) -> NSAppearance? {
        red ? NSAppearance(named: .darkAqua) : chosen.asNSAppearance
    }

    /// Only the red part of each color, its alpha kept: a popover, a tooltip or a window's rounded corner stays
    /// see-through (a red layer over the window, as on the phone, painted those solid red: the review).
    static let redOnly: CIFilter = {
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        return filter
    }()

    private var clear = true  // no window carries the filter: off, with nothing left to take away

    /// Each window's frame view (its title bar, toolbar and content) carries `redOnly` while on; nothing is added to
    /// the window's views, so nothing has to be kept on top. Runs after every event (a new window or sheet gets it at
    /// once), so off and clear it returns straight away.
    private func layWindows() {
        let chosen = UserColorScheme(rawValue: UserDefaults.standard.integer(forKey: "userColorScheme")) ?? .system
        let appearance = Self.appearance(red: on, chosen: chosen)
        if NSApplication.shared.appearance != appearance { NSApplication.shared.appearance = appearance }
        guard on || !clear else { return }
        for window in NSApplication.shared.windows {
            guard let frame = window.contentView?.superview else { continue }
            let laid = frame.contentFilters.contains { $0 === Self.redOnly }
            if on, !laid {
                frame.wantsLayer = true
                frame.layerUsesCoreImageFilters = true
                frame.contentFilters += [Self.redOnly]
            } else if !on, laid {
                frame.contentFilters.removeAll { $0 === Self.redOnly }
            }
        }
        clear = !on
    }
    #endif
}

/// The switch, as a toggle with its checkmark: the page menu (•••), the street map and the menu bars.
struct RedNightSwitch: View {
    @ObservedObject var red = PrepareMeRedNight.shared
    /// A menu's title capitals (docs/design/menus.md); Home Mac's switch, not in a menu, passes the plain name
    var title = "Red Night Screen"

    var body: some View {
        Toggle(isOn: $red.on) { Label(title, systemImage: "moon") }.pmSwitch()
    }
}
