// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (Library plan, phase 2).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import Combine
import Foundation
import PrepareMeShared

/// The Mac's Library shelf (owner, 2026-11-12; docs/plans/2026-11-12-library-section.md): the categories file in the
/// pairing folder (`LibraryShelf.fileName`, which the phones' service serves to the phones), and the held files as
/// shelf items, each with the day its first edition arrived (`library-first-seen.json` beside it, so a newer edition
/// is never New again). `shelf` is nil until the owner saves the first-launch sheet; the screens then use the
/// starting set.
@MainActor
final class PrepareMeLibraryShelf: ObservableObject {
    static let shared = PrepareMeLibraryShelf()
    static let firstSeenName = "library-first-seen.json"

    @Published private(set) var shelf: LibraryShelf?
    @Published private(set) var items: [LibraryShelf.Item] = []
    /// The edit sheet showing over the main window (PrepareMeCategoryPicker.swift's `LibraryEditSheets`); nil for none.
    @Published var sheet: Sheet?
    /// Sheets asked for while one showed, in order (`show`).
    var waiting: [Sheet] = []
    /// The download a Library list's Remove… is asking about (`PrepareMeMacLibrary`); nil for none.
    @Published var removing: Manifest.Entry?
    /// The category an Other Sites entry suggests, by shelf key, picked first in its Which category? (plan 5.4).
    var suggested: [String: String] = [:]
    private var firstSeen: [String: String] = [:]  // key → ISO 8601
    private var watching: AnyCancellable?

    /// What the screens group by: the saved shelf, else the starting set.
    var current: LibraryShelf { shelf ?? .starting }

    nonisolated static var folder: URL? {
        PrepareMeMac.folders?.appendingPathComponent(PairingDesk.folderName)
    }

    private init() {
        if let folder = Self.folder {
            shelf = LibraryShelf.read(try? Data(contentsOf: folder.appendingPathComponent(LibraryShelf.fileName)))
            firstSeen = (try? Data(contentsOf: folder.appendingPathComponent(Self.firstSeenName)))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        }
        watching = PrepareMeMac.shared.store.$record
            .sink { [weak self] record in Task { @MainActor in self?.refresh(record.held) } }
    }

    private func refresh(_ held: [String: HeldFile]) {
        var changed = false
        for file in held.values where firstSeen[LibraryShelf.key(fileName: file.entry.name)] == nil {
            firstSeen[LibraryShelf.key(fileName: file.entry.name)] = file.entry.deliveredAt
            changed = true
        }
        if changed, let folder = Self.folder, let data = try? JSONEncoder().encode(firstSeen) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? DurableFile.write(data, to: folder.appendingPathComponent(Self.firstSeenName))
        }
        let seen = firstSeen
        items = LibraryShelf.items(held, dailyFile: PrepareMeKeptTabs.dailyFile, arrived: { file in
            seen[LibraryShelf.key(fileName: file.entry.name)].flatMap { ISO8601DateFormatter().date(from: $0) }
        }, named: { _ in nil })
        #if PREPAREME_CHECK
        // PREPAREME_CHECK_LIBRARY_ITEMS=<n>: that many made-up collections more, for a long Sort Your Library (the
        // owner's 15-row sheet that ran off the window, 2026-11-12)
        let extra = Int(ProcessInfo.processInfo.environment["PREPAREME_CHECK_LIBRARY_ITEMS"] ?? "") ?? 0
        items += (0..<extra).map { n in
            LibraryShelf.Item(id: UUID(), title: "Made-up collection \(n + 1)", key: "made-up-\(n + 1)",
                              notChecked: true, arrived: nil)
        }
        #endif
    }

    /// The shelf written whole (the first-launch sheet's Save, a pick, an edit); false when it couldn't be.
    @discardableResult
    func save(_ new: LibraryShelf) -> Bool {
        guard let folder = Self.folder else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try DurableFile.write(new.encoded(), to: folder.appendingPathComponent(LibraryShelf.fileName))
        } catch {
            return false
        }
        shelf = new
        return true
    }
}
#endif

#if os(macOS)
import SwiftUI

/// The Mac's Library screen for a Library row: the whole list, New, a category or Needs a category, its collections
/// opening in the Guides tab with Back leading here again (`PrepareMeMacTabs.openCollection`).
struct PrepareMeMacLibrary: View {
    let rows: PrepareMeLibraryPage.Rows
    @ObservedObject private var shelf = PrepareMeLibraryShelf.shared

    static func rows(_ row: MacRow) -> PrepareMeLibraryPage.Rows? {
        switch row {
        case .shelf: return .all
        case .shelfNew: return .new
        case let .shelfCategory(id): return .category(id)
        case .shelfUnsorted: return .unsorted
        default: return nil
        }
    }

    /// The sidebar row that picks a list: a tile or bar on the whole Library picks the row its sidebar row is.
    static func row(_ rows: PrepareMeLibraryPage.Rows) -> MacRow {
        switch rows {
        case .all: .shelf
        case .new: .shelfNew
        case let .category(id): .shelfCategory(id: id)
        case .unsorted: .shelfUnsorted
        case .ready: .shelf  // the phones' alone
        }
    }

    /// The band's title: the row's words, the category's emoji and name, or a folder's "📖 Books › Homesteading".
    static func title(_ row: MacRow) -> String {
        if case let .shelfCategory(id) = row, case let path = PrepareMeLibraryShelf.shared.current.path(of: id),
           !path.isEmpty {
            return path
        }
        return MacSidebar.title(row) ?? MacLibraries.menuTitle
    }

    var body: some View {
        let list = PrepareMeMacTabs.shared.row
        PrepareMeLibraryPage(rows: rows, shelf: shelf.current, items: shelf.items, open: { item in
            PrepareMeMacTabs.shared.openCollection(item.id, from: list)
        }, move: { item, id in shelf.move(item, to: id) }, remove: { shelf.removing = Self.file($0) },
           describe: { shelf.show(.describe(key: $0.key, title: $0.title)) },
           pick: { PrepareMeMacTabs.shared.pick(Self.row($0)) }, title: Self.title(list))
        // Remove…'s confirm, as Downloads' Remove… asks (owner, 2026-11-13, by click: a download can take hours back)
        .confirmationDialog(MacDownloads.removeAsk(InventoryLook.title(shelf.removing.map(HomeMacWords.title) ?? "")),
                            isPresented: Binding(get: { shelf.removing != nil }, set: { if !$0 { shelf.removing = nil } }),
                            presenting: shelf.removing) { file in
            Button("Remove", role: .destructive) { MacDownloads.shared.remove(file.name) }
        } message: { file in
            Text(MacDownloads.removeNote(size: file.size))
        }
    }

    /// The file a collection is, in the Mac's record (a shelf item names it by ID only).
    static func file(_ item: LibraryShelf.Item) -> Manifest.Entry? {
        PrepareMeMac.shared.store.record.held.values.first { UUID(uuidString: $0.entry.id) == item.id }?.entry
    }
}
#endif

#if os(macOS)
/// The first launch with the Library (owner, 2026-11-12, by click: "I propose, you confirm"): every collection the
/// Mac holds with the category the starting set gives it (Reference for one it gives none), each changeable; Save
/// writes the shelf, Not Now leaves it for the next launch (the screens meanwhile use the starting set).
struct PrepareMeLibrarySetupSheet: View {
    let done: () -> Void
    @ObservedObject private var shelf = PrepareMeLibraryShelf.shared
    @State private var picks: [String: String] = [:]
    @State private var failed = false

    static let title = "Sort Your Library"
    static let note = "Each collection is in the category shown. Change any, then save. You can move them later too."

    var body: some View {
        let start = LibraryShelf.starting
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title).font(.pmTitle)
            Text(Self.note).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            // the rows scroll inside the sheet, so the words above and the buttons below always show (a Form here grew
            // past the window with 15 collections and hid Save: owner's Mac, 2026-11-12)
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(shelf.items, id: \.id) { item in
                        GridRow {
                            Text(InventoryLook.title(item.title)).gridColumnAlignment(.trailing)
                                .accessibilityHidden(true)  // the picker carries the same words
                            Picker(InventoryLook.title(item.title), selection: binding(item.key)) {
                                ForEach(start.categories) { category in
                                    Text("\(category.emoji) \(category.name)").tag(category.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            if failed {
                Text("That wasn't saved. Try again.").font(.pmNote).foregroundStyle(PrepareMeColors.red)
            }
            HStack {
                Spacer()
                Button("Not Now") { done() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)  // the Mac's default button: one filled action only (PaletteTests)
            }
        }
        .padding(20)
        .frame(width: 480, height: Self.height(window: PrepareMeMacTabs.shared.window?.frame.height))
        .pmScreen()
    }

    /// 460 points, or less in a shorter window (its smallest is 500), never under 240: a sheet taller than its window
    /// runs off the screen's bottom.
    static func height(window: CGFloat?) -> CGFloat {
        min(460, max(240, (window ?? 500) - 70))
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { picks[key] ?? LibraryShelf.starting.category(for: key) ?? "reference" },
                set: { picks[key] = $0 })
    }

    private func save() {
        var new = LibraryShelf.starting
        for item in shelf.items {
            new.placed[item.key] = picks[item.key] ?? LibraryShelf.starting.category(for: item.key) ?? "reference"
        }
        if shelf.save(new) { done() } else { failed = true }
    }
}
#endif

#if os(macOS)
/// The first-launch sheet over the main window, once a launch, while the shelf was never saved and the Mac holds a
/// collection besides the daily library.
struct LibrarySetupOnce: ViewModifier {
    @ObservedObject private var shelf = PrepareMeLibraryShelf.shared
    @State private var dismissed = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { !dismissed && shelf.shelf == nil && !shelf.items.isEmpty },
                                           set: { if !$0 { dismissed = true } })) {
            PrepareMeLibrarySetupSheet { dismissed = true }
        }
    }
}
#endif
