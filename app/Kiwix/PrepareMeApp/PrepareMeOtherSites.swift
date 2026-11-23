// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (library redesign, phase 5).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import Foundation
import PrepareMeShared
import SwiftUI

/// The Other Sites list (librarian/outside.toml, packed into the daily library as `OutsideList.path`), read as the guide
/// list is (`PrepareMeMacTabs.refreshTopics`). In the check build, PREPAREME_CHECK_OUTSIDE_LIST=<path to a JSON file>
/// reads a made-up list instead (its item may come over http from 127.0.0.1), and PREPAREME_CHECK_OUTSIDE_START=<key>
/// starts that item's download once, since the check app takes no clicks.
@MainActor
final class OtherSitesList: ObservableObject {
    static let shared = OtherSitesList()

    /// nil until read, or when it couldn't be (no daily library yet, or refused): then nothing is called dropped.
    @Published private(set) var list: OutsideList?
    var entries: [OutsideList.Entry] { list?.entries ?? [] }
    private var checkStarted = false

    func refresh() async {
        var list: OutsideList?
        let check = ProcessInfo.processInfo.environment
        if PrepareMeHome.isCheck, let path = check["PREPAREME_CHECK_OUTSIDE_LIST"] {
            list = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? OutsideList.decode($0, loopback: true) }
        } else if let held = PrepareMeMac.shared.store.record.held[PrepareMeKeptTabs.dailyFile] {
            let content = await ZimFileService.shared.getURLContent(zimFileID: held.entry.id, contentPath: OutsideList.path)
            list = content.flatMap { try? OutsideList.decode($0.data) }  // missing (an older daily) or refused: none
        }
        self.list = list
        if PrepareMeHome.isCheck, !checkStarted, let key = check["PREPAREME_CHECK_OUTSIDE_START"],
           let entry = entries.first(where: { $0.key == key }) {
            checkStarted = true
            MacDownloads.shared.startOutside(entry)
        }
    }
}

/// Add to Library › Other Sites (library redesign plan 5.4; spec, "Downloading one"): the note, then a card per entry
/// with its title, description, "site · license · size PDF" and the Download button or its progress
/// (`PrepareMeDownloadButton`), and under it why the last try was refused (a file changed at its site, no room).
struct PrepareMeOtherSitesView: View {
    @ObservedObject private var list = OtherSitesList.shared
    @ObservedObject private var downloads = MacDownloads.shared

    static let note = "Single books and handbooks from sites on PrepareMe's trusted list. Each was looked at before it "
        + "was listed: its source, license and size. We haven't reviewed what's inside."
    static let empty = "Nothing is listed yet. Items are added one at a time, each checked first."

    static func facts(_ entry: OutsideList.Entry) -> String {
        let site = entry.host.hasPrefix("www.") ? String(entry.host.dropFirst(4)) : entry.host
        return "\(site) · \(entry.license) · \(StorageWords.size(entry.size)) PDF"
    }

    var body: some View {
        PMList {
            Section {
                Text(Self.note).foregroundStyle(PrepareMeColors.text2)
                if list.entries.isEmpty {
                    Text(Self.empty).foregroundStyle(PrepareMeColors.text2)
                }
            }
            ForEach(list.entries) { entry in
                let source = MacDownloads.source(of: entry)
                PMCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title).font(.pmHeadline)
                        Text(entry.description)
                        Text(Self.facts(entry)).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                        PrepareMeDownloadButton(source: source, title: entry.title,
                                                start: { downloads.startOutside(entry) })
                        if let why = downloads.failed[source.absoluteString] {
                            Text(why).font(.pmNote).foregroundStyle(PrepareMeColors.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Other Sites")
        .task { await list.refresh() }
    }
}
#endif
