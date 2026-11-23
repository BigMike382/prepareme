// This file is part of PrepareMe, a local build of Kiwix for one household's phones and Mac (players-and-scoreboard
// plan, stage 1: the game bridge and the app's store for saves).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
import os
import PrepareMeShared
import WebKit
#if targetEnvironment(simulator) || PREPAREME_CHECK
import QuartzCore
#endif

/// The game bridge on the phone, the iPad and the Mac (`GameBridge` in PrepareMeShared holds the rules and is what the
/// tests run): a page of our own games keeps its save here and gets it back, in the app's own folder rather than the
/// page's storage, which every page of the games file shares. Each page's controller gets the handler inside the
/// bridge's own content world (`register`) and the page script (`script`, laid again when the list of our own games
/// changes, and a moment after the saves stop). Stage 1b: each save carries its count (`GameSaves`), and the page's
/// own storage holds the same counted copy, so a page opened before the script is laid again still starts from the
/// newest (kit.js takes the higher count); laying every script again on each save stalled the screen about 45 ms a
/// save on the phone simulator (players plan, section 12, stage 1b).
@MainActor
final class PrepareMeGameSaves: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = PrepareMeGameSaves()
    static let world = WKContentWorld.world(name: GameBridge.world)

    /// The app's own Application Support › PrepareMe (in its container on the Mac): the same folder the phone's
    /// inventory copy and the Mac's library copies are in, never the service's folder or iCloud.
    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrepareMe")
    }

    private(set) var store: GameSaves
    /// Stage 3: the finished games' lines, read from their own file at the first ask about lines in a launch (a year of
    /// games is far bigger than the saves, and most launches never ask). Each line is written before its page is
    /// answered. Fixed words and counts only reach the log, never a line.
    private lazy var lines: GameLines = {
        let lines = GameLines.load(Self.folder)
        if lines.setAside != nil { Self.log.notice("game lines unreadable: set aside, started again") }
        if lines.blocked { Self.log.notice("game lines unreadable and not renamed: no lines kept") }
        if lines.skipped > 0 { Self.log.notice("game lines: \(lines.skipped, privacy: .public) unreadable lines skipped") }
        return lines
    }()
    private var refused: [GameBridge.Refusal: Int] = [:]
    /// Saves are written off the main thread, one after another, in the order they came.
    private let writer = DispatchQueue(label: "com.bigmike382.prepareme.game-saves")
    private var reading: Task<Void, Never>?
    private var relaying: Task<Void, Never>?
    /// How long after the last save the scripts are laid again.
    private static let quiet: Duration = .seconds(2)
    /// Every page's controller, to lay the bridge's script again in each.
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private static let log = Logger(subsystem: AppCopy.id, category: "games")

    private override init() {
        store = GameSaves.load(Self.folder)
        super.init()
        // fixed words only: the file's contents are never read into a log
        if store.setAside != nil { Self.log.notice("game store unreadable: set aside, started empty") }
        if store.blocked { Self.log.notice("game store not readable now or not renamed: saves stay with the pages") }
        #if targetEnvironment(simulator) || PREPAREME_CHECK
        Self.checkPages()
        #endif
    }

    func register(_ controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: Self.world, name: GameBridge.handler)
        controllers.add(controller)
    }

    var script: WKUserScript {
        WKUserScript(source: GameBridge.pageScript(gamesID: store.games, ours: store.ours, saves: store.saves),
                     injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world)
    }

    /// The games file arrived or changed: its list of our own games read again, once the reader has it open (a launch
    /// opens its files a moment after the record is read). Until then the list last read stands.
    func gamesFileChanged(_ id: UUID?) {
        guard let id else { return }
        reading?.cancel()
        reading = Task {
            for _ in 0..<60 {
                if Task.isCancelled { return }
                if await ZimFileService.shared.getMainPageURL(zimFileID: id) != nil { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, await ZimFileService.shared.getMainPageURL(zimFileID: id) != nil else { return }
            let data = await ZimFileService.shared.getURLContent(zimFileID: id.uuidString,
                                                                 contentPath: GameBridge.oursPath)?.data
            // no list (a games file from before stage 1) or a wrong one: no page of the file is ours
            if store.read(gamesID: id, ours: GameBridge.ours(from: data) ?? []) { changed { _ in }; relay() }
        }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                           replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            let info = message.frameInfo
            let frame = GameBridge.Frame(isMain: info.isMainFrame, scheme: info.securityOrigin.protocol,
                                         host: info.securityOrigin.host,
                                         path: info.request.url?.path(percentEncoded: false) ?? "")
            // the player list (the Mac's own, or a phone's copy of it) read only for an ask about players: a few
            // hundred bytes, so a change on the Mac or a look at home shows at the next ask
            let answer = store.answer(message.body, from: frame, players: PlayerList.load(Self.folder), lines: self.lines)
            if let why = answer.refused {
                count(why)
                // told older, the page reloads: it must find the newest save in its script
                if why == .older { relay() }
                replyHandler(answer.reply, nil)
            } else if answer.changed {
                changed { saved in replyHandler(saved ? answer.reply : GameBridge.reply(.failure(.notSaved), saves: [:]),
                                                nil) }
            } else {
                replyHandler(answer.reply, nil)
            }
        }
    }

    /// The store written (off the main thread, in order) and the scripts laid again once the saves stop; `done` hears
    /// whether the write went through. A page told no still has its own counted copy, which wins at its next start
    /// (kit.js).
    private func changed(_ done: @escaping @MainActor (Bool) -> Void) {
        relaying?.cancel()
        relaying = Task {
            try? await Task.sleep(for: Self.quiet)
            if !Task.isCancelled { relay() }
        }
        let snapshot = store, folder = Self.folder
        writer.async {
            let saved = (try? snapshot.save(folder)) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !saved { self.count(.notSaved) }
                    done(saved)
                }
            }
        }
    }

    /// The page scripts laid again in every page's controller, the bridge's with the newest saves among them, so the
    /// next page opened starts with it; an open page is untouched. (WebKit has no public way to swap one content
    /// world's script alone, so every script is laid again: stage 1b measured what that costs.)
    private func relay() {
        relaying?.cancel(); relaying = nil
        #if targetEnvironment(simulator) || PREPAREME_CHECK
        let start = CACurrentMediaTime()
        defer { Self.timed(start) }
        #endif
        PrepareMeRedNight.shared.layScripts()
    }

    #if targetEnvironment(simulator) || PREPAREME_CHECK
    /// A session's check only (players plan, stage 1b): PREPAREME_CHECK_SAVE_TIMING=1 logs the time each kept save
    /// spends laying scripts again, and how many pages' controllers there are (numbers and fixed words only);
    /// PREPAREME_CHECK_SAVE_PAGES=<n> opens that many extra pages off the screen, each with its own controller, as
    /// open tabs would.
    private static var extra: [WKWebView] = []
    private static func timed(_ start: CFTimeInterval) {
        guard ProcessInfo.processInfo.environment["PREPAREME_CHECK_SAVE_TIMING"] == "1" else { return }
        let ms = (CACurrentMediaTime() - start) * 1000
        log.notice("game save relaid: \(ms, format: .fixed(precision: 2), privacy: .public) ms, \(shared.controllers.allObjects.count, privacy: .public) pages")
    }
    private static func checkPages() {
        guard let count = ProcessInfo.processInfo.environment["PREPAREME_CHECK_SAVE_PAGES"].flatMap(Int.init),
              count > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<min(count, 20) {
                let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WebViewConfiguration())
                view.loadHTMLString("<p>An extra page</p>", baseURL: nil)
                extra.append(view)
            }
        }
    }
    #endif

    /// Counted, and the first of each kind in a launch logged: the fixed words only, never anything the page sent.
    private func count(_ why: GameBridge.Refusal) {
        refused[why, default: 0] += 1
        if refused[why] == 1 { Self.log.notice("game bridge refused: \(why.rawValue, privacy: .public)") }
    }
}
