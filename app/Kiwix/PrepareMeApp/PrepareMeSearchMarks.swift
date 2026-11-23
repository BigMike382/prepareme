// This file is part of PrepareMe, a local build of Kiwix for one household (owner, 2026-10-21).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import PrepareMeShared
import SwiftUI

/// The mark on each search result, on the phone and the Mac (SearchMark's rules): which library a result is from, by
/// the files this device holds, and each guide's group, read from the daily library's category pages once per copy.
/// A walk-through's group is its guide's, read from its own page the first time search finds it.
@MainActor
final class PrepareMeSearchMarks: ObservableObject {
    static let shared = PrepareMeSearchMarks()

    @Published private(set) var groups: [String: String] = [:]
    @Published private(set) var walkthroughs: [String: String] = [:]  // a walk-through's page → its guide's group
    private var readFrom: String?  // the daily copy (its SHA-256) the groups came from
    private var asked: Set<String> = []

    /// The files this device holds: the phone's library, or the Mac's copies
    static var held: [String: HeldFile] {
        #if os(iOS)
        PrepareMeLibrary.shared.record.held
        #else
        PrepareMeMac.shared.store.record.held
        #endif
    }

    /// The groups brought up to date with the daily copy held now, then the groups of the walk-throughs in `results`.
    /// A copy that isn't open yet is tried again with the next results.
    func prepare(_ results: [SearchResult]) async {
        guard let daily = Self.held[PrepareMeKeptTabs.dailyFile] else { return }
        let id = daily.entry.id
        if daily.entry.sha256 != readFrom,
           let content = await ZimFileService.shared.getURLContent(zimFileID: id, contentPath: GuideTopics.path),
           let topics = try? GuideTopics(content.data) {
            let found = await SearchMark.groups(topics) { page in await Self.text(id, page) }
            (groups, walkthroughs, asked, readFrom) = (found, [:], [], daily.entry.sha256)
        }
        for result in results where result.zimFileID.uuidString.caseInsensitiveCompare(id) == .orderedSame {
            let path = result.url.contentPath
            guard SearchMark.isWalkthrough(path), readFrom != nil, asked.insert(path).inserted,
                  let page = await Self.text(id, path),
                  let group = SearchMark.walkthroughGroup(links: page, groups: groups) else { continue }
            walkthroughs[path] = group
        }
    }

    nonisolated private static func text(_ id: String, _ path: String) async -> String? {
        await ZimFileService.shared.getURLContent(zimFileID: id, contentPath: path)
            .map { String(decoding: $0.data, as: UTF8.self) }
    }

    /// A result's mark; `title` is its library's ZIM title (Kiwix's record of the open file)
    func mark(_ result: SearchResult, title: String?) -> SearchMark {
        let id = result.zimFileID.uuidString
        let held = Self.held.values.first { $0.entry.id.caseInsensitiveCompare(id) == .orderedSame }
        let name = held?.entry.name ?? ""
        let library: SearchMark.Library
        if name == PrepareMeKeptTabs.dailyFile {
            library = .guides(groups: groups, title: title ?? "")
        } else if name.hasPrefix("prepareme-maps") {
            library = .maps
        } else {
            library = .other(title: title ?? held.map { HomeMacWords.title($0.entry) } ?? "")
        }
        let path = result.url.contentPath
        return SearchMark.mark(path: path, in: library, walkthroughGroup: walkthroughs[path])
    }
}

/// The mark under a result's title: the group's emoji (or its symbol) and the kind word, or the library's name. The
/// row's own label says it to VoiceOver (SearchResults), so this line is hidden from it.
struct SearchMarkLine: View {
    let mark: SearchMark

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let emoji = mark.emoji {
                Text(emoji)
            } else if let symbol = mark.symbol {
                Image(systemName: symbol).foregroundStyle(PrepareMeColors.text2)
            }
            Text(mark.word).foregroundStyle(PrepareMeColors.text2)
        }
        .font(.pmNote)
        .accessibilityHidden(true)
    }
}
