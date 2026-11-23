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

import SwiftUI

import Defaults
#if PREPAREME_APP
import PrepareMeShared

private extension SearchResultItems {
    /// The results' pages, so the marks are prepared again only when the results change
    var markKey: [String] {
        if case let .results(found) = self { found.map(\.url.absoluteString) } else { [] }
    }
}
#endif

struct SearchResults: View {
    @Default(.recentSearchTexts) private var recentSearchTexts
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.managedObjectContext) private var managedObjectContext
    @Environment(\.isSearching) private var isSearching
    @ObservedObject var viewModel: SearchViewModel
    #if PREPAREME_APP
    @ObservedObject private var marks = PrepareMeSearchMarks.shared
    #endif
    @EnvironmentObject private var navigation: NavigationViewModel
    @FocusState private var focusedSearchItem: String? // macOS only
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ZimFile.size, ascending: false)],
        predicate: ZimFile.openedPredicate(),
        animation: .easeInOut
    ) private var zimFiles: FetchedResults<ZimFile>

    var body: some View {
        Group {
            if zimFiles.isEmpty {
                Message(text: LocalString.search_result_zimfile_empty_message)
            } else if horizontalSizeClass == .regular {
                HStack(spacing: 0) {
                    if !sidebarIsEmpty {  // PrepareMe: no empty column beside the results (beta run 3, B3-07)
#if os(macOS)
                        sidebar.frame(width: 250)
#elseif os(iOS)
                        sidebar.frame(width: 350)
#endif
                        Divider().ignoresSafeArea(.all, edges: .vertical)
                    }
                    content.frame(maxWidth: .infinity)
                }
            } else if viewModel.searchText.isEmpty {
                sidebar
            } else {
                content
            }
        }
        #if PREPAREME_APP
        .task(id: viewModel.results.markKey + viewModel.meaningAbove.map(\.url.absoluteString)) {
            if case let .results(found) = viewModel.results { await marks.prepare(found) }
            await marks.prepare(viewModel.meaningAbove)
        }
        #endif
        .onReceive(viewModel.$results, perform: { (results: SearchResultItems) in
            switch results.count {
            case 0:
                voiceOver(announcement: LocalString.search_result_zimfile_no_result_message)
            default:
                let resultCountText = LocalString.search_result_zimfile_voice_over_count(withArgs: "\(results.count)")
                voiceOver(announcement: resultCountText)
            }
        })
        .background(Color.background)
    }
    
    /// PrepareMe (beta run 3, B3-07): more than one library to choose from, for the "Included in Search" panel
    private var hasLibraryChoice: Bool { FeatureFlags.hasLibrary && zimFiles.count > 1 }

    /// PrepareMe (beta run 3, B3-07): the "Included in Search" panel is there only when there is more than one library
    /// to choose from, and, on the phone and iPad (not PrepareMe on the Mac), not beside a search's results (the iPad
    /// showed its switches there, "None" and all); it is back whenever the search box is empty, where a library
    /// (vehicles) is ticked in.
    private var showsLibraryChoice: Bool {
        guard hasLibraryChoice else { return false }
        #if PREPAREME_APP && os(iOS)
        return viewModel.searchText.isEmpty
        #else
        return true
        #endif
    }

    /// Nothing for the sidebar to list: no recent searches (shown when the library has no choice to make, or has some)
    /// and no library panel
    private var sidebarIsEmpty: Bool {
        FeatureFlags.hasLibrary && recentSearchTexts.isEmpty && !showsLibraryChoice
    }

    /// The line over results that searched every library because none was ticked: it names the panel only where the
    /// reader can get to it (on the phone and iPad, by clearing the search box; with one library there is no panel,
    /// and the line says that one was searched: the owner's click, 2026-10-21)
    private var untickedLine: String {
        let searched = "so every library except vehicles was searched."
        guard hasLibraryChoice else { return "Nothing is ticked, so this library was searched." }
        #if PREPAREME_APP && os(iOS)
        return "Nothing is ticked under Included in Search, \(searched) Clear the search box to see the panel."
        #else
        return "Nothing is ticked under Included in Search, \(searched)"
        #endif
    }

    /// PrepareMe: over the closest pages, when no page holds every word searched (SearchOperation.addClosest)
    static let closestLine = "No page has all of those words. These have some of them:"
    /// PrepareMe: over the closest guides, when only other libraries' pages hold every word, and over those pages
    static let closestGuidesLine = "No guide has all of those words. These have some of them:"
    static let otherLibrariesLine = "Library:"  // owner, 2026-11-12: was "Other libraries:"
    /// PrepareMe: over meaning search's section (SearchOperation.addMeaning; owner, 2026-10-28), and over the results
    /// after it when no closest pages follow
    static let meaningLine = "Best matches:"
    static let moreResultsLine = "More results:"

    /// PrepareMe: the line over each place in `count` results: over meaning search's section (its first `meaning`) and
    /// what follows it, over the closest pages (the next `closest`) and over other libraries' pages after them
    static func lines(meaning: Int, closest: Int, count: Int) -> [Int: String] {
        let overClosest = meaning + closest < count ? closestGuidesLine : closestLine
        var lines: [Int: String] = [:]
        if meaning > 0 {
            lines[0] = meaningLine
            lines[meaning] = closest > 0 ? overClosest : moreResultsLine
        } else if closest > 0 {
            lines[0] = overClosest
        }
        if closest > 0 {
            lines[meaning + closest] = otherLibrariesLine
        }
        return lines.filter { $0.key < count }
    }

    /// PrepareMe: a line in the list of results, the closest pages' look
    private func resultsLine(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
    }

    /// A result's row: its title, mark (PrepareMe: PrepareMeSearchMarks, owner 2026-10-21, said after its title in
    /// place of the library's icon) or library, and snippet
    private func resultRow(_ result: SearchResult) -> some View {
        #if PREPAREME_APP
        let title = zimFiles.first { $0.fileID == result.zimFileID }?.name
        let mark = marks.mark(result, title: title)
        #endif
        return Button {
            openResult(result: result)
        } label: {
            #if PREPAREME_APP
            ArticleCell(result: result, mark: mark)
            #else
            ArticleCell(result: result, zimData: viewModel.zimDataDict[result.zimFileID])
            #endif
        }
        #if PREPAREME_APP
        .accessibilityLabel("\(result.title), \(mark.spoken)")
        #else
        .accessibilityLabel(result.title)
        #endif
        .accessibilityHint(result.snippet?.string ?? "")
        .buttonStyle(.plain)
        .modifier(
            Focusable( // macOS only
                $focusedSearchItem,
                equals: result.url.absoluteString,
                onReturn: {
                    openResult(result: result)
                },
                onDismiss: {
                    $focusedSearchItem.wrappedValue = nil
                    dismissSearch()
                })
        )
    }

    /// PrepareMe: says so above the results when nothing is ticked and every library is searched instead
    @ViewBuilder
    var content: some View {
        VStack(spacing: 0) {
            if viewModel.searchingAllUnticked && !viewModel.searchText.isEmpty {
                Text(untickedLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            searchResultsContent
        }
    }

    @ViewBuilder
    var searchResultsContent: some View {
        if case SearchResultItems.results([]) = viewModel.results {
            if viewModel.searchText.isEmpty {
                Spacer()
            } else {
                if viewModel.inProgress {
                    Group {
                        ProgressView()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Message(text: LocalString.search_result_zimfile_no_result_message)
                }
            }
        } else {
            ScrollViewReader { scrollReader in
                ScrollView {
                    SearchList {
                        switch viewModel.results {
                        case let .results(results):
                            // PrepareMe (both builds; owner, 2026-10-28): the closest pages, said to be only that;
                            // when they're the guides, other libraries' pages holding every word follow under a line.
                            // Meaning search's section, when there is one, goes above them (PrepareMe only)
                            let lines = Self.lines(meaning: viewModel.meaningCount, closest: viewModel.closestCount,
                                                   count: results.count)
                            ForEach(Array(results.enumerated()), id: \.element.url.absoluteString) { place, result in
                                if let line = lines[place] {
                                    resultsLine(line)
                                }
                                resultRow(result)
                            }
                        case let .suggestions(suggestions):
                            // PrepareMe (owner, 2026-10-28): meaning search's best pages above "Did you mean", so a
                            // misspelled search still finds the guide it means
                            if !viewModel.meaningAbove.isEmpty {
                                resultsLine(Self.meaningLine)
                                ForEach(viewModel.meaningAbove, id: \.url.absoluteString) { result in
                                    resultRow(result)
                                }
                            }
                            Text(LocalString.common_search_suggestion)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                            
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button {
                                    viewModel.searchText = suggestion
                                } label: {
                                    ArticleCell(searchSuggestion: suggestion)
                                }
                                .buttonStyle(.plain)
                                .modifier(
                                    Focusable( // macOS only
                                        $focusedSearchItem,
                                        equals: suggestion,
                                        onReturn: {
                                            viewModel.searchText = suggestion
                                        },
                                        onDismiss: {
                                            $focusedSearchItem.wrappedValue = nil
                                            dismissSearch()
                                        })
                                )
                            }
                        }
                    }.padding()
                }
                .onReceive(self.focusedSearchItem.publisher) { focusedURL in
                    scrollReader.scrollTo(focusedURL, anchor: .center)
                }
                .modifier(MoveCommand(perform: { direction in
                    onMove(direction: direction) // macOS only
                }))
                .overlay(alignment: .center) {
                    if viewModel.inProgress {
                        ProgressView()
                    }
                }
            }
        }
    }
    
    private func voiceOver(announcement: String) {
        var attributed = AttributedString(announcement)
        attributed.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(attributed).post()
    }
    
    // macOS only
    private func onMove(direction: MoveDirection) {
        let index: Int = if let item = focusedSearchItem {
            viewModel.results.firstIndex(where: item) ?? -1
        } else {
            -1
        }
        let nextIndex: Int
        switch direction {
        case .up: nextIndex = viewModel.results.index(before: index)
        case .down: nextIndex = viewModel.results.index(after: index)
        default: nextIndex = viewModel.results.startIndex
        }
        if (viewModel.results.startIndex..<viewModel.results.endIndex).contains(nextIndex) {
            switch viewModel.results {
            case let .results(results):
                let urlString = results[nextIndex].url.absoluteString
                focusedSearchItem = urlString
            case let .suggestions(suggestions):
                focusedSearchItem = suggestions[nextIndex]
            }
        }
    }

    private func openResult(result: SearchResult) {
        recentSearchTexts = {
            var searchTexts = Defaults[.recentSearchTexts]
            searchTexts.removeAll(where: { $0 == viewModel.searchText })
            searchTexts.insert(viewModel.searchText, at: 0)
            return searchTexts
        }()

        dismissSearch()
        #if os(macOS)
        // delayed fix for placement: .toolbarPrincipal on macOS
        // as it's not always dismissing properly, so we try again if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if isSearching {
                dismissSearch()
            }
        }
        #endif
        NotificationCenter.openURL(result.url)
    }

    var sidebar: some View {
        List {
            if !FeatureFlags.hasLibrary || !recentSearchTexts.isEmpty {
                Section {
                    ForEach(recentSearchTexts.prefix(6), id: \.self) { searchText in
                        Button(searchText) {
                            viewModel.searchText = searchText
                        }.swipeActions {
                            Button(LocalString.search_result_sidebar_button_remove, role: .destructive) {
                                recentSearchTexts.removeAll { $0 == searchText }
                            }
                        }
#if os(macOS)
                        .buttonStyle(.link)
#endif
                    }
                } header: { recentSearchHeader }
            }
            if showsLibraryChoice {
                Section {
                    ForEach(zimFiles, id: \.fileID) { zimFile in
                        HStack {
                            Toggle(zimFile.name, isOn: Binding<Bool>(get: {
                                zimFile.includedInSearch && !zimFile.isMissing
                            }, set: {
                                zimFile.includedInSearch = $0
                                try? managedObjectContext.save()
                            })).disabled(zimFile.isMissing)
                            Spacer()
                        }
                    }
                } header: { searchFilterHeader }
            }
        }
        .modifier(NotFocusable()) // macOS only
    }
    
    private var recentSearchHeader: some View {
        HStack {
            Text(LocalString.search_result_header_text)
            Spacer()
            Button {
                recentSearchTexts.removeAll()
            } label: {
                Text(LocalString.search_result_button_clear).font(.caption).fontWeight(.medium)
            }
            .disabled(recentSearchTexts.isEmpty)
        }
    }
    
    private var searchFilterHeader: some View {
        HStack {
            Text(LocalString.search_result_filter_hearder_text)
            Spacer()
            if zimFiles.count == zimFiles.filter({ $0.includedInSearch }).count {
                Button {
                    zimFiles.forEach { $0.includedInSearch = false }
                    try? managedObjectContext.save()
                } label: {
                    Text(LocalString.search_result_filter_hearder_button_none).font(.caption).fontWeight(.medium)
                }
            } else {
                Button {
                    zimFiles.forEach { $0.includedInSearch = true }
                    try? managedObjectContext.save()
                } label: {
                    Text(LocalString.search_result_filter_hearder_button_all).font(.caption).fontWeight(.medium)
                }
            }
        }
    }
}
