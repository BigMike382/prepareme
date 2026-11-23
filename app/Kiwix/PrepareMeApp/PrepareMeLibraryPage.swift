// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (Library plan, phase 2).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import PrepareMeShared
import SwiftUI

/// A Library list (owner, 2026-11-12; docs/plans/2026-11-12-library-section.md, task 2.2), drawn as the guide list
/// is: every category under its emoji and name (`all`), New, one category, or Needs a category. Each collection is a
/// card (`PrepareMeLibraryCard`): its name, description, Inside, size and month, and source. A tap
/// opens it (`open`). The Mac and the phones share it; each passes its own shelf and items.
struct PrepareMeLibraryPage: View {
    enum Rows: Hashable { case all, new, category(String), unsorted, ready }  // ready: the phones' offers only

    #if os(macOS)
    static let emptyCategory = "Nothing in this category yet. Move a collection here, or right-click the category in the "
        + "sidebar to rename or remove it."
    #else
    static let emptyCategory = "Nothing in this category yet."
    #endif

    let rows: Rows
    let shelf: LibraryShelf
    let items: [LibraryShelf.Item]
    let open: (LibraryShelf.Item) -> Void
    /// The Mac's right-click Move to ▸ (each category); nil on the phones, which only follow the Mac's shelf.
    var move: ((LibraryShelf.Item, String) -> Void)?
    /// The Mac's right-click Remove… for a download (owner, 2026-11-13, by click); PrepareMe's own collections are
    /// rebuilt from the owner's files each hour, so theirs only says why it can't go. Nil on the phones.
    var remove: ((LibraryShelf.Item) -> Void)?
    /// The Mac's right-click Edit Description… (library redesign plan 2.5); nil on the phones.
    var describe: ((LibraryShelf.Item) -> Void)?
    /// The Mac's tiles and bars (library redesign plan 3.2): picks the list the sidebar's own row picks.
    var pick: ((Rows) -> Void)?
    /// The Mac's band title: the sidebar row's words, or the category's emoji and name.
    var title = ""
    /// The phones' Ready to download bar on the whole Library (family downloads plan, phase 5): shown while any offer
    /// isn't put away, with its put-away button.
    var readyBar = false
    var putAwayReady: (() -> Void)?

    /// An empty New or Needs a category says so in its own words (phase 3 review): neither can be renamed or removed.
    static let emptyNew = "Nothing new in the last 30 days."
    static let emptyUnsorted = "Every collection has a category."

    static func emptyNote(_ rows: Rows) -> String {
        switch rows {
        case .new: emptyNew
        case .unsorted, .ready: emptyUnsorted
        case .all, .category: emptyCategory
        }
    }

    static let ownCollection = "Can't Remove: PrepareMe Rebuilds It Each Hour"

    static let emptySub = "Nothing in this subcategory yet."

    static func count(_ n: Int) -> String { n == 1 ? "1 collection" : "\(n) collections" }

    /// The offers among `items` in a category and its folders (family downloads plan, phase 5)
    private func toDownload(in id: String) -> Int { shelf.total(items.filter { $0.offer != nil }, in: id) }

    /// A subcategory shows as a folder on its category's page and opens to its own cards (owner, 2026-11-14, by
    /// click: on every device, its name and count; it replaced the subcategory headings of library redesign 4.4).
    static let folder = "📁"
    static let folderHint = "Opens the folder"

    /// The whole Library's band note (design, "What it looks like"): said once, for every outside collection.
    static let bandNote = "Books and references besides our guides. Collections from outside sources come as they "
        + "are: we haven't reviewed them the way we check our guides."

    static let newBar = "New in the Library"  // the design's words, as the guide list's New guides bar

    /// The page in Guides' look on every device (library redesign plan 3.2; Library matches Guides plan, 1.2 and 2.1):
    /// the band, then on the whole Library the New bar, the categories and the Needs a category bar; on a list, its
    /// folders, then its cards as many across as fit at 330 points. The guide list's page spacing: on the Mac 16 points
    /// on top, 24 at the sides (16 below the page's 760-point wide window, as front_style's); on the phones 12 under
    /// the top bar and 16 at the sides; 48 below, 1280 wide at most and centered, 12 points between pieces. The phones
    /// show the band on the whole Library only: a pushed list's bar title says what it is.
    var body: some View {
        #if os(macOS)
        GeometryReader { box in ScrollView { page(top: 16, sides: box.size.width < 760 ? 16 : 24) } }.pmScreen()
        #else
        PMPageRow { page(top: 12, sides: 16) }  // not a ScrollView: the search bar above keeps to a list
        #endif
    }

    private func page(top: CGFloat, sides: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsBand { band }
            content
        }
        .padding(.top, top).padding(.horizontal, sides).padding(.bottom, 48)
        .frame(maxWidth: 1280)
        .frame(maxWidth: .infinity)
    }

    #if os(macOS)
    private var showsBand: Bool { true }
    #else
    private var showsBand: Bool { rows == .all }
    #endif

    private var band: some View {
        PMBand {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.pmTitle)
                        .accessibilityLabel(Self.spoken(title))  // the emoji isn't read (phase 3 review)
                    Spacer()
                    if let bandCount {
                        let offers = rows.category.map(toDownload(in:)) ?? 0
                        Text(Self.count(bandCount) + (offers > 0 ? ", \(offers) to download" : ""))
                    }
                }
                if rows == .all { Text(Self.bandNote) }
            }
        }
        .card()
    }

    /// A category page's or folder's count in its band, a category's folders included; nil on other lists or none.
    private var bandCount: Int? {
        guard case let .category(id) = rows else { return nil }
        let count = shelf.total(items, in: id)
        return count > 0 ? count : nil
    }

    /// A category page's folders (none on a folder): on the Mac every subcategory, an empty one too, as the sidebar
    /// lists it; on the phones, which only follow the Mac's shelf, those holding a collection.
    private var folders: [LibraryShelf.Category] {
        guard case let .category(id) = rows else { return [] }
        #if os(macOS)
        return shelf.children(of: id)
        #else
        return shelf.subGroups(items, in: id).map(\.category)
        #endif
    }

    /// The cards a list (not the whole Library) shows: a category's loose ones, or a folder's.
    private var shown: [LibraryShelf.Item] {
        switch rows {
        case .all: []
        case .new: LibraryShelf.newItems(items, now: Date())
        case let .category(id): shelf.own(items, in: id)
        case .unsorted: shelf.unsorted(items)
        case .ready: items.filter { $0.offer != nil }
        }
    }

    /// How a list of categories or folders is drawn (Library matches Guides plan): one panel of rows (phone), row
    /// panels two to a line (iPad), or the guide list's tall tiles (the Mac).
    enum Form { case rows, columns, tiles }

    #if os(macOS)
    private var form: Form { .tiles }  // at every width (owner, 2026-11-14: phase 1 approved as built)
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var textSize

    /// The iPad's two to a line, as the guide list's groups (front_style's 760-pixel grid); one panel of rows on a
    /// phone, in Split View at a phone's width and at the accessibility text sizes (plan Review Focus 3 and 5).
    private var form: Form { sizeClass == .regular && !textSize.isAccessibilitySize ? .columns : .rows }
    #endif

    @ScaledMetric(relativeTo: .body) private var rowBox: CGFloat = 27  // the pages' 1.6em at 17 points

    /// A category's entry on the whole Library, or a folder's on its category's page: its icon in a tinted box, the
    /// name and count; it picks the list the sidebar's own row picks, or pushes it on the phones. A tile is the guide
    /// list's on a wide window (front_style: 255 points wide at least, 119 tall at least, 16 padding, the name in the
    /// book typeface at the bottom, an arrow top right: › here, since a tile opens a page where Guides' unfolds); a row
    /// is the guide list's on the phone (44 tall at least, 12 and 16 padding, the box 1.6em square, a › at its end).
    /// No panel of its own: `entries` gives a tile or an iPad row its panel, and a phone's rows one between them.
    private func entry(_ icon: String, _ name: String, _ count: Int, _ to: Rows, hint: String?) -> some View {
        let offers = to.category.map(toDownload(in:)) ?? 0
        let words = "\(name) (\(HomeMacWords.count(count, toDownload: offers)))"
        return Button { pick?(to) } label: {
            Group {
                if form == .tiles {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(icon).font(.pmTitle).frame(width: 32).padding(6)  // names line up
                            .background(PrepareMeColors.tealTint, in: .rect(cornerRadius: PrepareMeCorners.control))
                            .accessibilityHidden(true)
                        Text(words).font(.pmHeadline).fontDesign(.serif)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 119, alignment: .bottomLeading)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "chevron.right").foregroundStyle(PrepareMeColors.edge)
                            .padding(.top, 24).padding(.trailing, 16).accessibilityHidden(true)
                    }
                } else {
                    HStack(spacing: 12) {
                        // stops growing past the largest standard size, as the pages' emoji do, so at the
                        // accessibility sizes the name keeps the row's width (it broke "Homesteading" mid-word)
                        Text(icon).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .frame(width: min(rowBox, 40), height: min(rowBox, 40))
                            .background(PrepareMeColors.tealTint, in: .rect(cornerRadius: PrepareMeCorners.control))
                            .accessibilityHidden(true)
                        Text(words).bold()
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(PrepareMeColors.edge).accessibilityHidden(true)
                    }
                    .padding(.vertical, 12).padding(.horizontal, 16)
                    // an iPad line's two as tall as each other when one name wraps, as the guide list's grid
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: form == .columns ? .infinity : nil,
                           alignment: .leading)
                }
            }
            .contentShape(.rect)  // the whole row or tile takes the tap, its empty end too
        }
        .buttonStyle(.plain)
        // "Medical, 2 collections", as the old phone rows said; ", 1 to download" with an offer
        .accessibilityLabel("\(name), \(Self.count(count))" + (offers > 0 ? ", \(offers) to download" : ""))
        .accessibilityHint(hint ?? "")
    }

    /// The categories or folders in this device's form; nothing at all when there are none (no empty panel).
    @ViewBuilder private func entries(_ list: [(icon: String, name: String, count: Int, to: Rows)],
                                      hint: String? = nil) -> some View {
        if !list.isEmpty {
            switch form {
            case .rows:
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.offset) { index, one in
                        if index > 0 { Divider().overlay(PrepareMeColors.line) }
                        entry(one.icon, one.name, one.count, one.to, hint: hint)
                    }
                }
                .pmPanel()
            case .columns, .tiles:
                let columns = form == .tiles ? [GridItem(.adaptive(minimum: 255), spacing: 8, alignment: .top)]
                    : Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 2)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, one in
                        entry(one.icon, one.name, one.count, one.to, hint: hint).pmPanel()
                    }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if rows == .all {
            let new = LibraryShelf.newItems(items, now: Date()), unsorted = shelf.unsorted(items)
            let offers = items.count { $0.offer != nil }
            if readyBar && offers > 0 { bar(HomeMacWords.readyBar, offers, .ready, putAway: putAwayReady) }
            if !new.isEmpty { bar(Self.newBar, new.count, .new) }
            entries(shelf.grouped(items).map { group in
                (group.category.emoji, group.category.name, shelf.total(items, in: group.category.id),
                 .category(group.category.id))
            })
            if !unsorted.isEmpty { bar(MacSidebar.title(.shelfUnsorted) ?? "", unsorted.count, .unsorted) }
        } else {
            // folders first, as Finder keeps them on top
            entries(folders.map { (Self.folder, $0.name, shelf.total(items, in: $0.id), .category($0.id)) },
                    hint: Self.folderHint)
            if !shown.isEmpty {
                cards(shown, emoji: rows == .new)
            } else if folders.isEmpty {
                Text(isFolder ? Self.emptySub : Self.emptyNote(rows)).foregroundStyle(PrepareMeColors.text2)
                    .padding(14).pmPanel()
            }
        }
    }

    /// A subcategory's own page (its folder opened).
    private var isFolder: Bool {
        guard case let .category(id) = rows else { return false }
        return shelf.top(of: id) != id
    }

    /// A band title as VoiceOver reads it: the words, without the emoji in front.
    static func spoken(_ title: String) -> String {
        String(title.drop(while: { !$0.isLetter && !$0.isNumber }))
    }

    private func cards(_ items: [LibraryShelf.Item], emoji: Bool) -> some View {
        // one full-width column in the phone's form: 330 points wouldn't fit an iPad's narrowest Split View (review)
        let columns = form == .rows ? [GridItem(.flexible(), spacing: 12, alignment: .top)]
            : [GridItem(.adaptive(minimum: 330), spacing: 12, alignment: .top)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items, id: \.id) { item in card(item, emoji: emoji) }
        }
    }

    /// New's and Needs a category's bar: the teal-tinted row the guide list's New guides bar is (front_style's
    /// .new-btn: 48 points tall at least, 12-point corners, bold words in the link teal, a teal ›).
    /// Ready to download's has a put-away ✕ after its › (family downloads plan, phase 5), outside the bar's own button.
    private func bar(_ name: String, _ count: Int, _ to: Rows, putAway: (() -> Void)? = nil) -> some View {
        HStack(spacing: 0) {
            Button { pick?(to) } label: {
                HStack {
                    Text("\(name) (\(count))").bold().foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tint).accessibilityHidden(true)
                }
                .padding(.vertical, 12).padding(.leading, 16).padding(.trailing, putAway == nil ? 16 : 8)
                .frame(minHeight: 48)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(Self.count(count))")  // "New in the Library, 23 collections"
            if let putAway {
                Button(action: putAway) {
                    Image(systemName: "xmark").foregroundStyle(.tint).frame(minWidth: 44, minHeight: 48)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Put away \(name)")
            }
        }
        .background(PrepareMeColors.tealTint, in: .rect(cornerRadius: PrepareMeCorners.control))
    }

    /// One place in Move to ▸, greyed where the collection already is.
    private func moveButton(_ item: LibraryShelf.Item, _ id: String, _ words: String,
                            _ move: @escaping (LibraryShelf.Item, String) -> Void) -> some View {
        Button(words) { move(item, id) }.disabled(shelf.category(for: item.key) == id)
    }

    /// One collection's card, opening it on a click or tap, with the Mac's right-click menu: the pages' rounded panel,
    /// inside the button so its whole face takes a click or right-click (phase 3 review).
    #if os(iOS)
    /// The phones' card: a held file opens, an offer opens its sheet, each with its Download or Remove below
    /// (`PhoneLibraryCard`, family downloads plan, phase 5).
    private func card(_ item: LibraryShelf.Item, emoji: Bool) -> some View {
        let category = emoji ? shelf.category(for: item.key) : nil
        return PhoneLibraryCard(item: item, shelf: shelf, emoji: category.map(shelf.emoji(of:)), open: { open(item) })
    }
    #else
    private func card(_ item: LibraryShelf.Item, emoji: Bool) -> some View {
        let category = emoji ? shelf.category(for: item.key) : nil
        return Button { open(item) } label: {
            PrepareMeLibraryCard(item: item, shelf: shelf, emoji: category.map(shelf.emoji(of:)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).pmPanel().contentShape(.rect(cornerRadius: PrepareMeCorners.panel))
        }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let move {
                            Menu("Move to") {
                                // a category with subcategories is a menu of its own (library redesign plan 4.3)
                                ForEach(shelf.categories.filter { $0.parent == nil }) { category in
                                    let subs = shelf.children(of: category.id)
                                    if subs.isEmpty {
                                        moveButton(item, category.id, "\(category.emoji)  \(category.name)", move)
                                    } else {
                                        Menu("\(category.emoji)  \(category.name)") {
                                            moveButton(item, category.id, "\(category.name) (no subcategory)", move)
                                            ForEach(subs) { sub in moveButton(item, sub.id, sub.name, move) }
                                        }
                                    }
                                }
                            }
                        }
                        if let describe {
                            Button("Edit Description…") { describe(item) }
                        }
                        if let remove {
                            Divider()
                            if item.notChecked {  // a download from Add to Library (manifest kind `download`)
                                PMMenuDelete("Remove…") { remove(item) }
                            } else {
                                Text(Self.ownCollection)
                            }
                        }
                    }
    }
    #endif
}

extension PrepareMeLibraryPage.Rows {
    /// A category's id; nil for the other lists.
    var category: String? {
        if case let .category(id) = self { return id }
        return nil
    }
}

extension View {
    /// Look 3's panel: the pages' panel color, its line, 14-point corners (a card, a tile or a run of rows).
    func pmPanel() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(PrepareMeColors.panel, in: .rect(cornerRadius: PrepareMeCorners.panel))
            .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.panel).strokeBorder(PrepareMeColors.line))
    }
}
