// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household's Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if PREPAREME_APP && os(macOS)
import AppKit
import PrepareMeShared
import SwiftUI
import WebKit

/// The owner's three marks on the News page (news plan Task 3.4; docs/news.md, "The marks"; the pictures the owner
/// picked 2026-11-18, group 7): an opened story's Doesn't Belong and Take Down…, the same in a right-click on a story
/// (docs/design/menus.md: Take Down… red and last, after a line), and Should Have Been Here… at the page's end. Each
/// becomes a request file in the requests folder's news-marks (NewsMark), which the news job takes at its next run;
/// News's answer shows at the page's end, read by this app straight from News's own page.json (NewsAnswers), never from
/// the library: a mark sends nothing to the phones (the owner's word on the second review's finding 7, 2026-11-18). Doesn't Belong is written at once; Take Down… asks first;
/// Should Have Been Here… opens a sheet for a link or a headline.
@MainActor
final class PrepareMeNewsMarks: ObservableObject {
    static let shared = PrepareMeNewsMarks()

    /// Take Down…'s question: the story and its headline as the page shows it
    @Published var askingDown: (story: String, headline: String)?
    @Published var missedOpen = false
    @Published var missedText = ""
    /// A line after a mark (what happens next), or why it couldn't be saved
    @Published var notice: (title: String, message: String)?

    static let downTitle = "Take down this story?"
    static let downMessage = "“%@” leaves the News page and any line on Today at the next update. It can't be put back."
    static let downButton = "Take Down"
    static let missedTitle = "Should Have Been Here"
    static let missedMessage = "Paste a link to the story, or type its headline. News answers at the end of the News "
        + "page, at its next update, whether it saw the story and why it wasn't shown. What you type stays on this Mac."
    static let missedPlaceholder = "A link or a headline"
    static let wrongDone = ("Marked Doesn't Belong", "News keeps it for the weekly review. The story stays, and News's "
                            + "answer shows at the end of the News page at its next update.")
    static let missedDone = ("Sent to News", "News's answer shows at the end of the News page at its next update.")
    static let failed = "The mark couldn't be saved"
    static let wrongAgain = ("Already marked", "This story is marked Doesn't Belong. News keeps the first mark.")
    static let menuWrong = "Doesn't Belong"
    static let menuDown = "Take Down…"

    private var requests: URL? { PrepareMeMac.folders?.appendingPathComponent("requests") }
    /// The reader the mark came from: its headline goes in Take Down…'s question, and the story leaves it
    private weak var page: WKWebView?
    /// This launch's marks: Doesn't Belong once a story, and a taken-down story kept from the page when it reloads
    /// before the library's copy catches up (the second review's finding 8)
    private var marked: Set<String> = []
    /// Taken-down stories, kept TAKEN_HOURS across launches: the library's copy drops one only at its next regular
    /// update (up to 6 hours, since a mark starts none)
    private static let takenKey = "newsTakenDown"
    private static let takenHours: Double = 12
    var takenDown: Set<String> {
        let now = Date().timeIntervalSince1970
        let kept = (UserDefaults.standard.dictionary(forKey: Self.takenKey) as? [String: Double]) ?? [:]
        return Set(kept.filter { now - $0.value < Self.takenHours * 3600 && NewsMark.isStory($0.key) }.keys)
    }

    private func keepTakenDown(_ story: String) {
        let now = Date().timeIntervalSince1970
        var kept = (UserDefaults.standard.dictionary(forKey: Self.takenKey) as? [String: Double]) ?? [:]
        kept = kept.filter { now - $0.value < Self.takenHours * 3600 }
        kept[story] = now
        UserDefaults.standard.set(kept, forKey: Self.takenKey)
    }

    /// The News page's end: the marks and News's answers from page.json, as text (BrowserViewModel.pageFinished); and
    /// the day's first load noted for the trial (noteOpened).
    func fillAnswers(_ view: WKWebView) {
        guard Self.isNewsPage(view.url) else { return }
        noteOpened()
        guard let file = PrepareMeMac.folders?.appendingPathComponent(NewsAnswers.folderName)
                .appendingPathComponent(NewsAnswers.fileName) else { return }
        view.evaluateJavaScript(NewsAnswers.script(NewsAnswers.rows(try? Data(contentsOf: file))))
    }

    /// The day this launch last noted the page opened: one request a day, written quietly (no line if it fails; the
    /// next load tries again). News keeps one a day however many come.
    private var openedDay: String?

    private func noteOpened(now: Date = Date()) {
        let day = NewsMark.day(now)
        guard openedDay != day, let requests, let mark = NewsMark(kind: .opened, story: nil),
              (try? mark.write(in: requests, now: now)) != nil else { return }
        openedDay = day
    }

    /// Whether `url` is the library's News page, the one page whose links and right-click make marks: a library page
    /// (zim:) by that name, never a file or web page that shares it (the second review's finding 12).
    nonisolated static func isNewsPage(_ url: URL?) -> Bool {
        url?.isZIMURL == true && url?.lastPathComponent == MacRow.news.page(newPage: "")
    }

    /// A clicked mark link (BrowserViewModel's navigation, a link activation only), or the menu's, in `view`, the
    /// reader that shows the page; refused unless that reader shows the News page.
    func handle(_ mark: NewsMark, in view: WKWebView) {
        guard Self.isNewsPage(view.url) else { return }
        page = view
        switch mark.kind {
        case .wrong:
            guard let story = mark.story else { return }
            if marked.contains(story) {
                notice = Self.wrongAgain
            } else if save(mark) {
                marked.insert(story)
                notice = Self.wrongDone
            }
        case .down:
            guard let story = mark.story, !takenDown.contains(story) else { return }
            Task {
                askingDown = (story, await headline(of: story) ?? "This story")
            }
        case .missed:
            missedText = ""
            missedOpen = true
        case .opened:
            return  // never a link (NewsMark.parse refuses it)
        }
    }

    func confirmDown() {
        guard let asked = askingDown, let mark = NewsMark(kind: .down, story: asked.story) else { return }
        askingDown = nil
        if save(mark) {
            keepTakenDown(asked.story)
            hide(asked.story)
        }
    }

    func sendMissed() {
        guard let mark = NewsMark(kind: .missed, story: nil), NewsMark.cleaned(missedText) != nil else { return }
        missedOpen = false
        if save(mark, text: missedText) { notice = Self.missedDone }
    }

    @discardableResult
    private func save(_ mark: NewsMark, text: String? = nil) -> Bool {
        do {
            guard let requests else { throw POSIXError(.ENOENT) }
            try mark.write(in: requests, text: text)
            return true
        } catch {
            notice = (Self.failed, error.localizedDescription)
            return false
        }
    }

    /// The story's headline as the page shows it (its id has the record's shape, so it is safe inside the script).
    private func headline(of story: String) async -> String? {
        guard NewsMark.isStory(story) else { return nil }
        let script = "(document.querySelector('[data-story=\"\(story)\"] h3') || {}).textContent || ''"
        let found = try? await page?.evaluateJavaScript(script) as? String
        return found?.isEmpty == false ? found : nil
    }

    /// A taken-down story leaves the page on screen at once, and again whenever the page loads (addScripts lays the
    /// kept ones at launch); the library's copy follows at its next regular update.
    private func hide(_ story: String) {
        guard let page else { return }
        let script = Self.hideScript([story])
        page.evaluateJavaScript(script)
        page.configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    /// Removes the stories' cards from the News page (ids of the record's shape only, so safe inside the script);
    /// WebViewConfiguration.addScripts lays it again with the rest after red night's re-lay.
    static func hideScript(_ stories: some Sequence<String>) -> String {
        let ids = stories.filter(NewsMark.isStory).sorted().map { "'\($0)'" }.joined(separator: ",")
        return "if (document.getElementById('news-board')) [\(ids)].forEach(function (s) {"
            + " document.querySelectorAll('[data-story=\"' + s + '\"]').forEach(function (e) { e.remove(); }); });"
    }

    /// The right-click menu's marks on a story: Doesn't Belong, a line, Take Down… in red (PMMenuDelete's red for a
    /// menu), each made in `view`.
    func menuItems(for story: String, in view: WKWebView) -> [NSMenuItem] {
        guard NewsMark.isStory(story) else { return [] }
        let wrong = NSMenuItem(title: Self.menuWrong, action: #selector(MenuTarget.wrong(_:)), keyEquivalent: "")
        let down = NSMenuItem(title: Self.menuDown, action: #selector(MenuTarget.down(_:)), keyEquivalent: "")
        down.attributedTitle = NSAttributedString(string: Self.menuDown,
                                                  attributes: [.foregroundColor: NSColor(PrepareMeColors.red)])
        for item in [wrong, down] {
            item.target = MenuTarget.shared
            item.representedObject = MenuStory(story: story, view: view)
        }
        return [wrong, .separator(), down]
    }

    private final class MenuStory: NSObject {
        let story: String
        weak var view: WKWebView?
        init(story: String, view: WKWebView) { self.story = story; self.view = view }
    }

    @MainActor private final class MenuTarget: NSObject {
        static let shared = MenuTarget()

        @objc func wrong(_ item: NSMenuItem) { mark(.wrong, item) }
        @objc func down(_ item: NSMenuItem) { mark(.down, item) }

        private func mark(_ kind: NewsMark.Kind, _ item: NSMenuItem) {
            guard let picked = item.representedObject as? MenuStory, let view = picked.view,
                  let mark = NewsMark(kind: kind, story: picked.story) else { return }
            PrepareMeNewsMarks.shared.handle(mark, in: view)
        }
    }
}

/// The reader's web view on the Mac: a right-click on a News story adds the marks after the page's own menu (Copy,
/// Look Up and the rest kept: the second review's finding 12). The page script names the story under the pointer
/// before WebKit asks for the menu (both go in order over the same connection from the page).
final class PrepareMeWebView: WKWebView {
    static let handler = "newsStory"
    /// Only on the rebuilt News page (its section's id), only a story card, and only in a reader that has the
    /// handler (a plain web view made from the same configuration has none: the second review's finding 12)
    static let script = """
        document.addEventListener('contextmenu', function (e) {
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handler);
          if (!h) return;
          var s = document.getElementById('news-board') && e.target.closest ? e.target.closest('[data-story]') : null;
          h.postMessage(s ? s.getAttribute('data-story') : '');
        }, true);
        """

    fileprivate var storyUnderPointer: String?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        let controller = configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handler)
        controller.add(StoryMessages(self), name: Self.handler)  // its page script: WebViewConfiguration.addScripts
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let story = storyUnderPointer else { return }
        storyUnderPointer = nil
        let items = PrepareMeNewsMarks.shared.menuItems(for: story, in: self)
        guard !items.isEmpty else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        items.forEach(menu.addItem)
    }

    /// The check build's look at the menu (PREPAREME_CHECK_NEWS_MENU): the same items, opened in the page's middle.
    func popUpMarks(for story: String) {
        let menu = NSMenu()
        PrepareMeNewsMarks.shared.menuItems(for: story, in: self).forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
    }

    /// Holds the web view weakly: the content controller keeps its handlers alive.
    private final class StoryMessages: NSObject, WKScriptMessageHandler {
        weak var view: PrepareMeWebView?
        init(_ view: PrepareMeWebView) { self.view = view }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                let story = message.body as? String ?? ""
                let fromNews = PrepareMeNewsMarks.isNewsPage(message.frameInfo.request.url)  // no other page's menu
                view?.storyUnderPointer = fromNews && NewsMark.isStory(story) ? story : nil
            }
        }
    }
}

/// Take Down…'s question, Should Have Been Here…'s sheet and the line after a mark, on the reader that shows the page.
struct PrepareMeNewsMarksAsk: ViewModifier {
    @ObservedObject private var marks = PrepareMeNewsMarks.shared

    func body(content: Content) -> some View {
        content
            .alert(PrepareMeNewsMarks.downTitle, isPresented: Binding(get: { marks.askingDown != nil },
                                                                   set: { if !$0 { marks.askingDown = nil } })) {
                Button("Cancel", role: .cancel) { marks.askingDown = nil }
                Button(PrepareMeNewsMarks.downButton, role: .destructive) { marks.confirmDown() }
            } message: {
                Text(String(format: PrepareMeNewsMarks.downMessage, marks.askingDown?.headline ?? ""))
            }
            .alert(marks.notice?.title ?? "", isPresented: Binding(get: { marks.notice != nil },
                                                                  set: { if !$0 { marks.notice = nil } })) {
                Button("OK") { marks.notice = nil }
            } message: {
                Text(marks.notice?.message ?? "")
            }
            .sheet(isPresented: $marks.missedOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(PrepareMeNewsMarks.missedTitle).font(.pmHeadline)
                    Text(PrepareMeNewsMarks.missedMessage).font(.pmBody).fixedSize(horizontal: false, vertical: true)
                    TextField(PrepareMeNewsMarks.missedPlaceholder, text: $marks.missedText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { marks.sendMissed() }
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { marks.missedOpen = false }.keyboardShortcut(.cancelAction)
                        Button("Send") { marks.sendMissed() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(NewsMark.cleaned(marks.missedText) == nil)
                    }
                }
                .padding(20)
                .frame(width: 420)
            }
    }
}
#endif
