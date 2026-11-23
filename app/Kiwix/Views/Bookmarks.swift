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

struct Bookmarks: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.managedObjectContext) private var managedObjectContext
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\.created, order: .reverse)],
        predicate: Bookmarks.buildPredicate(searchText: ""),
        animation: .easeInOut
    ) private var bookmarks: FetchedResults<Bookmark>
    @State private var searchText = ""
    #if PREPAREME_APP
    @State private var removing: Bookmark?  // the visible Remove's second tap (look 3, phase 4 review)
    #endif

    var body: some View {
        LazyVGrid(columns: ([gridItem]), spacing: 12) {
            ForEach(bookmarks, id: \.self) { bookmark in
                #if PREPAREME_APP
                VStack(alignment: .trailing, spacing: 0) {  // PrepareMe: a visible Remove under each (look 3, fix 15)
                    cell(bookmark)
                    Button(role: .destructive) {
                        removing = bookmark
                    } label: {
                        Label(LocalString.bookmark_context_menu_remove_title, systemImage: "star.slash")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(PrepareMeColors.red)
                }
                #else
                cell(bookmark)
                #endif
            }
        }
        .modifier(GridCommon())
        #if PREPAREME_APP
        // a tap just under a bookmark meant to open it never deletes it: Remove asks again, in the same word
        .confirmationDialog(LocalString.bookmark_context_menu_remove_title,
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .hidden, presenting: removing) { bookmark in
            Button(LocalString.bookmark_context_menu_remove_title, role: .destructive) {
                managedObjectContext.delete(bookmark)
                try? managedObjectContext.save()
            }
        }
        #endif
        .modifier(ToolbarRoleBrowser())
        .navigationTitle(LocalString.bookmark_navigation_title)
        .searchable(text: $searchText, prompt: LocalString.common_search)
        .onChange(of: searchText) { _, newValue in
            bookmarks.nsPredicate = Bookmarks.buildPredicate(searchText: newValue)
        }
        .overlay {
            if bookmarks.isEmpty {
                Message(text: LocalString.bookmark_overlay_empty_title)
            }
        }
    }

    private func cell(_ bookmark: Bookmark) -> some View {
        Button {
            NotificationCenter.openURL(bookmark.articleURL, inNewTab: true)
            if horizontalSizeClass == .compact {
                dismiss()
            }
        } label: {
            ArticleCell(
                bookmarkData: BookmarkArticleData(from: bookmark)
            )
        }
        .buttonStyle(.plain)
        .modifier(BookmarkContextMenu(bookmark: bookmark))
    }

    private var gridItem: GridItem {
        #if os(macOS)
        GridItem(.adaptive(minimum: 250, maximum: 500), spacing: 12)
        #elseif os(iOS)
        GridItem(.adaptive(minimum: 250, maximum: 500), spacing: 12)
        #endif
    }

    private static func buildPredicate(searchText: String) -> NSPredicate? {
        let searchPredicate: NSPredicate? = if searchText.isEmpty {
            nil
        } else {
            NSPredicate(format: "title CONTAINS[cd] %@", searchText)
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            searchPredicate,
            NSPredicate(format: "zimFile.isMissing == false")
        ].compactMap { $0 })
    }
}
