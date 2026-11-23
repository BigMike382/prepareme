// This file is part of PrepareMe, a local build of Kiwix for one household's phones and Mac (games plan, phase 3b,
// package B: full-screen play).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Combine
import PrepareMeShared
import SwiftUI
import WebKit

/// Full-screen play: while the reading tab on screen shows a game page (`GamePlay.isGamePage`: any page of the games
/// file but its front page and its rules), the app's bars step aside and Done leads back to the Games list. On a phone
/// or iPad the page moves into a cover over the whole screen (`PrepareMeGameScreen`); on the Mac the sidebar and the
/// toolbar hide (RootView). Every page of the games file runs `GamePlay.pageScript`, which marks a game page
/// `data-pm-full` and tells this object (`pmFull`) whether the page asks for edge to edge.
@MainActor
final class PrepareMeGamePlay: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = PrepareMeGamePlay()

    /// The reading tab on screen shows a game page.
    @Published private(set) var playing = false
    /// The page that last asked for edge to edge (`viewport-fit=cover`), by web view; another page of it doesn't count.
    @Published private(set) var cover: [ObjectIdentifier: URL] = [:]
    private weak var browser: BrowserViewModel?
    private var watching: AnyCancellable?
    private var gamesWatch: AnyCancellable?
    private var gamesFileWatch: AnyCancellable?
    private var gamesSeen: UUID?

    private override init() {
        super.init()
        #if os(iOS)
        let record = PrepareMeLibrary.shared.store.$record
        #else
        let record = PrepareMeMac.shared.store.$record
        startAwake()
        #endif
        // the page script names the games file's ID: laid again when it changes (a new file, or the first read)
        gamesWatch = record
            .map { $0.held[MacLibraries.gamesFile]?.entry.id }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, Self.gamesID != self.gamesSeen else { return }
                self.gamesSeen = Self.gamesID
                PrepareMeRedNight.shared.layScripts()
            }
        // a new copy of the games file keeps its ID: its list of our own games is read again (players stage 1)
        gamesFileWatch = record
            .map { $0.held[MacLibraries.gamesFile]?.entry }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { entry in PrepareMeGameSaves.shared.gamesFileChanged(entry.flatMap { UUID(uuidString: $0.id) }) }
    }

    static var gamesID: UUID? {
        #if os(iOS)
        PrepareMeTabs.gamesID
        #else
        PrepareMeMac.shared.store.record.held[MacLibraries.gamesFile].flatMap { UUID(uuidString: $0.entry.id) }
        #endif
    }

    static func isGamePage(_ url: URL?) -> Bool { GamePlay.isGamePage(url, gamesID: gamesID) }

    /// Every page's controller gets the script's messages (once: the scripts are laid again, the handler stays).
    func register(_ controller: WKUserContentController) {
        controller.add(self, name: GamePlay.handler)
    }

    static var pageScript: String { GamePlay.pageScript(gamesID: gamesID) }

    /// The reading tab now on screen (nil: none); `playing` follows its page.
    func watch(_ browser: BrowserViewModel?) {
        self.browser = browser
        watching = browser?.$url
            .map { Self.isGamePage($0) }
            .removeDuplicates()
            .sink { [weak self] game in self?.set(playing: game) }
        if browser == nil { set(playing: false) }
    }

    /// A reading tab going off screen: forgotten, unless another has been watched since.
    func unwatch(_ browser: BrowserViewModel) {
        if self.browser === browser { watch(nil) }
    }

    private func set(playing: Bool) {
        guard playing != self.playing else { return }
        var still = Transaction()
        still.disablesAnimations = true  // no motion beyond folds (design rules): the cover appears, never slides
        withTransaction(still) { self.playing = playing }
        #if os(macOS)
        layAwake()
        #endif
    }

    /// Done: the Games list in the same tab.
    func done() {
        guard let browser, let id = Self.gamesID else { return }
        Task {
            if let main = await ZimFileService.shared.getMainPageURL(zimFileID: id) { browser.load(url: main) }
        }
    }

    /// Whether `webView`'s page asks for edge to edge now.
    func asksForCover(_ webView: WKWebView) -> Bool {
        guard let asked = cover[ObjectIdentifier(webView)], let url = webView.url else { return false }
        return asked.zimFileID == url.zimFileID && asked.contentPath == url.contentPath
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = message.webView,
              let asks = message.body as? Bool else { return }
        cover[ObjectIdentifier(view)] = asks ? view.url : nil
    }

    #if os(macOS)
    // MARK: The Mac's display kept awake while a game page is on screen and PrepareMe is frontmost

    private var awake: NSObjectProtocol?
    private var appWatch: [AnyCancellable] = []

    private func startAwake() {
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.layAwake() } }
                .store(in: &appWatch)
        }
    }

    private func layAwake() {
        let on = playing && NSApplication.shared.isActive
        if on, awake == nil {
            let options: ProcessInfo.ActivityOptions = [.idleDisplaySleepDisabled, .userInitiated]
            awake = ProcessInfo.processInfo.beginActivity(options: options, reason: "A game is on screen")
        } else if !on, let held = awake {
            ProcessInfo.processInfo.endActivity(held)
            awake = nil
        }
    }
    #endif
}

/// Done: a small quiet capsule, always reachable, back to the Games list (Escape too, from a keyboard).
struct PrepareMeGameDone: View {
    static let height: CGFloat = 30

    var body: some View {
        Button { PrepareMeGamePlay.shared.done() } label: {
            Text("Done")
                .font(.pmNote.weight(.semibold))
                .foregroundStyle(PrepareMeColors.teal)
                .padding(.horizontal, 14)
                .frame(height: Self.height)
                .background(Capsule().fill(PrepareMeColors.panel.opacity(0.9)))
                .overlay(Capsule().strokeBorder(PrepareMeColors.edge, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Done")
        .accessibilityHint("Back to the Games list")
    }
}

#if os(iOS)
/// The phone's and iPad's full screen: the game page over everything (tab bar, search, the Guides switch and the
/// status bar), laid edge to edge when it asks for it (the true safe-area figures reach it then), else inside the
/// safe area, as Safari lays a page; Done in the status-bar row beside the island where that row holds it, else in
/// the page's top-leading corner, inside the box our games keep free (`GamePlay.freeCorner`).
struct PrepareMeGameScreen: View {
    @ObservedObject var browser: BrowserViewModel
    @ObservedObject private var play = PrepareMeGamePlay.shared

    var body: some View {
        GeometryReader { box in
            let edge = box.safeAreaInsets
            let inBand = GamePlay.doneInBand(topInset: edge.top, height: PrepareMeGameDone.height)
            // the whole screen, Done inside it (a button moved up past its parent's edge took no presses)
            ZStack(alignment: .topLeading) {
                GameWebView(webView: browser.webView, cover: play.asksForCover(browser.webView))
                PrepareMeGameDone()
                    .padding(.leading, edge.leading + (inBand ? 20 : 8))
                    .padding(.top, inBand ? (edge.top - PrepareMeGameDone.height) / 2 : edge.top + 8)
            }
            .ignoresSafeArea()
        }
        .background(PrepareMeColors.ground.ignoresSafeArea())
        .statusBarHidden()
    }
}

/// The game page's own holder while full screen: its edges at the screen's for a page that asks for edge to edge,
/// else at the safe area's, and no inset of the reader's (its bars are gone).
private struct GameWebView: UIViewControllerRepresentable {
    let webView: WKWebView
    let cover: Bool

    func makeUIViewController(context: Context) -> Holder { Holder(webView: webView) }
    func updateUIViewController(_ holder: Holder, context: Context) { holder.cover = cover }

    final class Holder: UIViewController {
        let webView: WKWebView
        var cover = false { didSet { if cover != oldValue { lay() } } }
        private var edges: [NSLayoutConstraint] = []

        init(webView: WKWebView) {
            self.webView = webView
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("not from a file") }

        override func viewDidLoad() {
            super.viewDidLoad()
            webView.translatesAutoresizingMaskIntoConstraints = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            view.addSubview(webView)
            lay()
        }

        private func lay() {
            guard webView.superview === view else { return }
            NSLayoutConstraint.deactivate(edges)
            let guide = view.safeAreaLayoutGuide
            edges = cover
                ? [webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                   webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                   webView.topAnchor.constraint(equalTo: view.topAnchor),
                   webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)]
                : [webView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                   webView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                   webView.topAnchor.constraint(equalTo: guide.topAnchor),
                   webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)]
            NSLayoutConstraint.activate(edges)
        }
    }
}
#endif
