// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Combine
import Foundation
import PrepareMeShared
import WebKit

/// Our Home pages' slots filled from the phones' copy of the lists (docs/plans/2026-11-16-our-home.md, Task 2.4;
/// app/Service's HomeSlots), on the phone, the iPad and the Mac's reader. Only pages of the daily library are filled.
/// Each platform sets `source` once: the phone the copy it shows (its own edits on top), the Mac the phones' copy file
/// it writes, never its own inventory, so the Mac shows what a phone would.
@MainActor
enum PrepareMeOurHome {
    /// The daily library's id and the copy to fill from, read each time a page fills.
    static var source: (() -> (dailyID: UUID?, copy: PhoneInventory?))?
    /// The libraries this device holds, so Read the manual shows only for a manual that's really here
    static var held: (() -> [String: HeldFile])?

    /// The pages that had slots, so a copy that changed fills them again (`refill`).
    private static let filled = NSHashTable<WKWebView>.weakObjects()

    /// Fills the page in two trips (HomeSlots.readScript, then HomeSlots.script); a page outside the daily library, or
    /// with no slots, is left as it is. `anyPage`: the Mac editor's preview, which isn't in a library.
    static func fill(_ webView: WKWebView, anyPage: Bool = false) {
        guard let (dailyID, copy) = source?(), anyPage || (dailyID != nil && webView.url?.zimFileID == dailyID) else { return }
        webView.evaluateJavaScript(HomeSlots.readScript) { found, _ in
            guard let slots = found as? [[String]] else { return }
            filled.add(webView)
            let items = copy.map(HomeSlots.items) ?? []
            var kept: [String: [HomeSlots.Kept]] = [:]
            for slot in slots where slot.count == 3 && slot[0] == "items" {
                let words = slot[1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                kept[slot[1]] = HomeSlots.kept(words: words, in: items)
            }
            // the editor's picked places, manuals and things, by id (the editor plan, Task 2)
            var (places, picked) = HomeSlots.picked(slots, in: copy, links: placeLinks)
            Task {
                // a manual whose library (or whose copy of it) isn't on this device gets no link, never one to nothing
                let shelf = held?() ?? [:]
                func here(_ k: HomeSlots.Kept) async -> HomeSlots.Kept {
                    let path = k.manual.split(separator: "/").last.map(String.init) ?? ""
                    let url = k.manual.isEmpty ? nil : await PrepareMeKeptTabs.manualURL(path, held: shelf)
                    return HomeSlots.Kept(name: k.name, place: k.place, manual: url?.absoluteString ?? "")
                }
                for (words, found) in kept {
                    var checked: [HomeSlots.Kept] = []
                    for k in found { checked.append(await here(k)) }
                    kept[words] = checked
                }
                for (i, k) in picked { picked[i] = await here(k) }
                webView.evaluateJavaScript(HomeSlots.script(meet: copy.map(HomeSlots.meet) ?? [], kept: kept,
                                                            places: places, items: picked),
                                           completionHandler: nil)  // the callback form: the script returns nothing
            }
        }
    }

    /// Whether a filled place opens in Lists: on a phone and iPad; the Mac shows its path as plain words.
    #if os(iOS)
    static let placeLinks = true
    #else
    static let placeLinks = false
    #endif

    /// The copy changed: every page still showing slots fills again.
    static func refill() {
        filled.allObjects.forEach { fill($0) }
    }

    private static var changes: AnyCancellable?

    /// Fills again a moment after `changed` last fired (the phone's copy, or its own edits on top, changed).
    static func refill(on changed: some Publisher<Void, Never>) {
        changes = changed.debounce(for: .milliseconds(300), scheduler: RunLoop.main).sink { _ in refill() }
    }
}
