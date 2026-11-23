// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (Library plan, phase 3).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import PrepareMeShared
import SwiftUI

/// The owner's edits to the Library, on the Mac only (owner, 2026-11-12; docs/plans/2026-11-12-library-section.md,
/// phase 3), as sheets over the main window (`LibraryEditSheets`), so a download that finishes while Add to Library is
/// closed still asks:
/// - Which category? when a download is kept (`PrepareMeLibraryShelf.ask`): the categories, New category…, Later
///   (nothing placed: it shows under Needs a category) and Put it here.
/// - Rename… (name and emoji) and Delete… on a category's right-click; Delete moves its files to another category
///   first and won't finish without one.
/// - New Subcategory… on a category's right-click (library redesign plan 4.3: a name only, one level); a
///   subcategory's Rename… asks its name only, and Delete… on a category takes its subcategories and their files.
extension PrepareMeLibraryShelf {
    enum Sheet: Identifiable, Equatable {
        case pick(key: String, title: String)
        case rename(id: String)
        case remove(id: String)
        case describe(key: String, title: String)  // Edit Description… (library redesign plan 2.5)
        case newSub(parent: String)  // New Subcategory… (library redesign plan 4.3)

        var id: String {
            switch self {
            case let .pick(key, _): return "pick-\(key)"
            case let .rename(id): return "rename-\(id)"
            case let .remove(id): return "remove-\(id)"
            case let .describe(key, _): return "describe-\(key)"
            case let .newSub(parent): return "newsub-\(parent)"
            }
        }
    }

    /// Which category? for a download just kept, unless the owner placed its collection already (a newer edition
    /// keeps its place) or never saved the shelf (the first-launch sheet sorts it with the rest).
    func ask(name: String, title: String, suggest: String? = nil) {
        let key = LibraryShelf.key(fileName: name)
        guard let shelf, shelf.placed[key] == nil else { return }
        if let suggest, shelf.categories.contains(where: { $0.id == suggest }) { suggested[key] = suggest }
        show(.pick(key: key, title: title))
    }

    /// A sheet now, or after the one showing closes (a second download finishing, or one ending during Rename…).
    func show(_ next: Sheet) {
        if sheet == nil { sheet = next } else if !waiting.contains(next) { waiting.append(next) }
    }

    /// The sheet closed: the next one waiting, a moment later so the first has gone.
    func sheetClosed() {
        guard sheet == nil, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            show(next)
        }
    }

    /// A collection moved from its right-click's Move to ▸ (the Mac's Library list).
    func move(_ item: LibraryShelf.Item, to id: String) {
        save(current.moving(key: item.key, to: id))
    }

    /// The owner's description for a collection, or none (Use the Original): on its card on the Mac and every phone.
    @discardableResult
    func describe(_ key: String, as text: String?) -> Bool {
        save(current.describing(key: key, as: text))
    }

    /// What a collection's card says: the owner's description, else the file's own (the manifest's, or Kiwix's record
    /// of it until the packer's next run gives the manifest one).
    func description(for item: LibraryShelf.Item) -> String? {
        current.description(for: item, recorded: KiwixReader.record(item.id)?.fileDescription)
    }

    func original(_ item: LibraryShelf.Item) -> String? {
        LibraryShelf.original(item, recorded: KiwixReader.record(item.id)?.fileDescription)
    }
}

/// The Library's sheets over the main window.
struct LibraryEditSheets: ViewModifier {
    @ObservedObject private var shelf = PrepareMeLibraryShelf.shared

    func body(content: Content) -> some View {
        content.sheet(item: $shelf.sheet, onDismiss: { shelf.sheetClosed() }) { sheet in
            switch sheet {
            case let .pick(key, title): PrepareMeCategoryPicker(key: key, title: title)
            case let .rename(id): PrepareMeCategoryRename(id: id)
            case let .remove(id): PrepareMeCategoryRemove(id: id)
            case let .describe(key, title): PrepareMeDescriptionEdit(key: key, title: title)
            case let .newSub(parent): PrepareMeSubcategoryNew(parent: parent)
            }
        }
    }
}

/// Which category? for a download just kept.
struct PrepareMeCategoryPicker: View {
    let key: String
    let title: String
    @ObservedObject private var store = PrepareMeLibraryShelf.shared
    @State private var pending: LibraryShelf?  // the shelf with a category added here, saved only by Put it here
    @State private var chosen: String?
    @State private var adding = false
    @State private var name = ""
    @State private var emoji: String?
    @State private var failed = false

    static let heading = "Which category?"

    var body: some View {
        let shelf = pending ?? store.current
        VStack(alignment: .leading, spacing: 12) {
            if adding {
                PrepareMeCategoryForm(heading: "New Category", name: $name, emoji: $emoji, shelf: shelf, own: nil,
                                      parent: nil, confirm: "Add") {
                    if let (added, id) = shelf.adding(name: name, emoji: emoji ?? "") {
                        pending = added
                        chosen = id
                        adding = false
                    }
                } cancel: { adding = false }
            } else {
                Text(Self.heading).font(.pmTitle)
                Text("\(InventoryLook.title(title)) is downloaded and checked. Pick where it goes in the Library.")
                    .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                if let item = store.items.first(where: { $0.key == key }), let about = store.description(for: item) {
                    Text(about).font(.pmNote).foregroundStyle(PrepareMeColors.text2)  // what it is (plan 2.5)
                }
                ScrollView {
                    Picker("Category", selection: $chosen) {
                        ForEach(shelf.categories) { category in  // a subcategory right under its category, named by both
                            Text(shelf.path(of: category.id)).tag(Optional(category.id))
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("New Category…") {
                    name = ""
                    emoji = nil
                    adding = true
                }
                if failed {
                    Text("That wasn't saved. Try again.").font(.pmNote).foregroundStyle(PrepareMeColors.red)
                }
                HStack {
                    Spacer()
                    Button("Later") { later() }.keyboardShortcut(.cancelAction)
                        .help("It shows under Needs a category until you move it")
                    Button("Put It Here") { put(shelf) }.keyboardShortcut(.defaultAction).disabled(chosen == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 440)
        .pmScreen()
        .onAppear {
            // an Other Sites entry's suggested category (plan 5.4), else the starting set's, when either has one
            chosen = store.suggested[key] ?? store.current.category(for: key)
            check()
        }
    }

    /// Later: under Needs a category, even one the starting set would place, until it's moved (the design's word).
    private func later() {
        store.save(store.current.moving(key: key, to: LibraryShelf.needsCategory))
        store.sheet = nil
    }

    private func put(_ shelf: LibraryShelf) {
        guard let chosen else { return }
        if store.save(shelf.moving(key: key, to: chosen)) { store.sheet = nil } else { failed = true }
    }

    /// The check build only: PREPAREME_CHECK_PICK=<category id> chooses it; `new` opens New Category filled in
    /// (Radio, 📻); `added` adds it too; `put-<category id>` and `later` press those after a pause for a capture.
    private func check() {
        #if PREPAREME_CHECK
        guard let step = ProcessInfo.processInfo.environment["PREPAREME_CHECK_PICK"] else { return }
        if step == "new" || step == "added" {
            adding = true
            name = "Radio"
            emoji = "📻"
            if step == "added", let (added, id) = store.current.adding(name: name, emoji: "📻") {
                pending = added
                chosen = id
                adding = false
            }
        } else if step == "later" || step.hasPrefix("put-") {
            if step.hasPrefix("put-") { chosen = String(step.dropFirst(4)) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                if step == "later" { later() } else { put(store.current) }
            }
        } else {
            chosen = step
        }
        #endif
    }
}

/// Edit Description… on a collection's right-click (library redesign plan 2.5; owner, 2026-11-13): the owner's own line
/// for its card, 160 characters at most, shown on the Mac and every phone; Use the Original goes back to the file's.
struct PrepareMeDescriptionEdit: View {
    let key: String
    let title: String
    @ObservedObject private var store = PrepareMeLibraryShelf.shared
    @State private var text = ""
    @State private var failed = false

    private var item: LibraryShelf.Item? { store.items.first { $0.key == key } }
    private var saved: String { store.current.descriptions[key] ?? item.flatMap(store.original) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Description for \(InventoryLook.title(title))").font(.pmTitle)
            Text("Shown on its card on the Mac and every phone.").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            TextEditor(text: $text)
                .font(.pmBody)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(PrepareMeColors.line))
                .onChange(of: text) {
                    if text.count > LibraryShelf.descriptionLimit { text = String(text.prefix(LibraryShelf.descriptionLimit)) }
                }
            if let original = item.flatMap(store.original) {
                Text("The file's own line: \"\(original)\"").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            if failed {
                Text("That wasn't saved. Try again.").font(.pmNote).foregroundStyle(PrepareMeColors.red)
            }
            HStack {
                Button("Use the Original") { finish(nil) }
                    .disabled(store.current.descriptions[key] == nil)
                Spacer()
                Button("Cancel") { store.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { finish(text) }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines) == saved)
            }
        }
        .padding(20)
        .frame(width: 460)
        .pmScreen()
        .onAppear {
            text = saved
            #if PREPAREME_CHECK  // PREPAREME_CHECK_DESCRIBE=<words> types them, for a capture of a changed box
            if let typed = ProcessInfo.processInfo.environment["PREPAREME_CHECK_DESCRIBE"] { text = typed }
            #endif
        }
    }

    /// Saved, or back to the file's own line (nil, or a box left empty, or the original typed again).
    private func finish(_ typed: String?) {
        let trimmed = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let own = trimmed.isEmpty || trimmed == item.flatMap(store.original) ? nil : trimmed
        if store.describe(key, as: own) { store.sheet = nil } else { failed = true }
    }
}

/// A category's name and emoji (New Category and Rename): the name 1 to 20 characters, no sibling's (ignoring case),
/// and one emoji from the grid (LibraryShelf.adding and renaming refuse anything else). A subcategory's (`parent` set)
/// is its name only: it shows its category's emoji.
struct PrepareMeCategoryForm: View {
    let heading: String
    @Binding var name: String
    @Binding var emoji: String?
    let shelf: LibraryShelf
    let own: String?  // the category being renamed: its own name stays allowed
    let parent: String?  // a subcategory's category: its siblings are the names it can't take
    let confirm: String
    let done: () -> Void
    let cancel: () -> Void

    private var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Type a name." }
        if trimmed.count > LibraryShelf.nameLimit { return "\(LibraryShelf.nameLimit) characters at most." }
        if shelf.categories.contains(where: {
            $0.id != own && $0.parent == parent && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return parent == nil ? "A category has that name already." : "A subcategory here has that name already."
        }
        if parent == nil, emoji == nil { return "Pick an icon." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.pmTitle)
            TextField("Name", text: $name, prompt: Text(parent == nil ? "Such as Radio" : "Such as Homesteading"))
            if parent == nil { icons }
            if let problem, !name.isEmpty || emoji != nil {
                Text(problem).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(confirm, action: done).keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
    }

    @ViewBuilder private var icons: some View {
            Text("Icon").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 8), spacing: 6) {
                ForEach(LibraryShelf.emojiGrid, id: \.self) { item in
                    Button { emoji = item } label: {
                        Text(item).font(.pmEntry).frame(width: 40, height: 36)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(emoji == item ? PrepareMeColors.ink : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(emoji == item ? .isSelected : [])
                }
            }
    }
}

/// New Subcategory… on a category's right-click (library redesign plan 4.3): a name only, under that category.
struct PrepareMeSubcategoryNew: View {
    let parent: String
    @ObservedObject private var store = PrepareMeLibraryShelf.shared
    @State private var name = ""
    @State private var emoji: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PrepareMeCategoryForm(heading: "New Subcategory in \(store.current.path(of: parent))", name: $name,
                                  emoji: $emoji, shelf: store.current, own: nil, parent: parent, confirm: "Add") {
                if let (added, _) = store.current.addingSub(name: name, to: parent) {
                    if store.save(added) { store.sheet = nil } else { failed = true }
                }
            } cancel: { store.sheet = nil }
            if failed {
                Text("That wasn't saved. Try again.").font(.pmNote).foregroundStyle(PrepareMeColors.red)
            }
        }
        .padding(20)
        .frame(width: 420, height: 170)
        .pmScreen()
    }
}

/// Rename… on a category: its name and emoji; its files stay.
struct PrepareMeCategoryRename: View {
    let id: String
    @ObservedObject private var store = PrepareMeLibraryShelf.shared
    @State private var name = ""
    @State private var emoji: String?
    @State private var failed = false

    var body: some View {
        let parent = store.current.categories.first { $0.id == id }?.parent
        VStack(alignment: .leading, spacing: 8) {
            PrepareMeCategoryForm(heading: parent == nil ? "Rename Category" : "Rename Subcategory", name: $name,
                                  emoji: $emoji, shelf: store.current, own: id, parent: parent, confirm: "Rename") {
                if let renamed = store.current.renaming(id: id, to: name, emoji: emoji ?? "") {
                    if store.save(renamed) { store.sheet = nil } else { failed = true }
                }
            } cancel: { store.sheet = nil }
            if failed {
                Text("That wasn't saved. Try again.").font(.pmNote).foregroundStyle(PrepareMeColors.red)
            }
        }
        .padding(20)
        .frame(width: 420, height: parent == nil ? 300 : 170)
        .pmScreen()
        .onAppear {
            let category = store.current.categories.first { $0.id == id }
            name = category?.name ?? ""
            emoji = category?.emoji
        }
    }
}

/// Delete… on a category (Remove… until 2026-11-13, owner): its files go to another category first ("Move its N files to:"), and it won't remove
/// without one; an empty category asks only to confirm. The last category stays.
struct PrepareMeCategoryRemove: View {
    let id: String
    @ObservedObject private var store = PrepareMeLibraryShelf.shared
    @State private var target: String?
    @State private var failed = false

    /// What Delete… says about a category's subcategories, which go with it.
    static func subsGo(_ names: [String]) -> String {
        let list = names.count < 3 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return names.count == 1 ? "Its subcategory \(list) goes too." : "Its subcategories \(list) go too."
    }

    var body: some View {
        let shelf = store.current
        let subs = shelf.children(of: id)
        let going = Set([id] + subs.map(\.id))  // a category's subcategories go with it (library redesign plan 4.3)
        let count = store.items.filter { shelf.category(for: $0.key).map(going.contains) ?? false }.count
        let others = shelf.categories.filter { !going.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(shelf.categories.contains { $0.id == id } ? shelf.path(of: id) : "this category")?")
                .font(.pmTitle)
            if !subs.isEmpty {
                Text(Self.subsGo(subs.map(\.name))).foregroundStyle(PrepareMeColors.text2)
            }
            if others.allSatisfy({ $0.parent != nil }) {
                Text("The Library keeps at least one category.").foregroundStyle(PrepareMeColors.text2)
            } else if count > 0 {
                Picker("Move its \(count) \(count == 1 ? "file" : "files") to:", selection: $target) {
                    Text("Choose…").tag(String?.none)
                    ForEach(others) { other in Text(shelf.path(of: other.id)).tag(Optional(other.id)) }
                }
            } else {
                Text("It holds no files.").foregroundStyle(PrepareMeColors.text2)
            }
            if failed {
                Text("That wasn't saved. Try again.").font(.pmNote).foregroundStyle(PrepareMeColors.red)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { store.sheet = nil }.keyboardShortcut(.cancelAction)
                // red words: macOS colors a destructive button only in an alert, and this box is a sheet
                Button(role: .destructive) { remove(count: count, others: others) } label: {
                    Text("Delete").foregroundStyle(PrepareMeColors.red)
                }
                    .disabled(others.allSatisfy { $0.parent != nil } || (count > 0 && target == nil))
            }
        }
        .padding(20)
        .frame(width: 420, height: 200)
        .pmScreen()
        .onAppear {
            #if PREPAREME_CHECK
            target = ProcessInfo.processInfo.environment["PREPAREME_CHECK_REMOVE_TO"]  // the check's choice
            #endif
        }
    }

    private func remove(count: Int, others: [LibraryShelf.Category]) {
        // an empty category's files go nowhere: any other category stands in as the target
        guard let to = count > 0 ? target : others.first?.id,
              let removed = store.current.removing(id: id, movingFilesTo: to, keys: store.items.map(\.key)) else { return }
        guard store.save(removed) else { failed = true; return }
        let tabs = PrepareMeMacTabs.shared
        // its subcategories went with it (library redesign 4.2): any row of theirs opens the Library's list
        tabs.row = MacSidebar.restore(tabs.row, shelf: removed)
        if let back = tabs.returnRow, MacSidebar.restore(back, shelf: removed) != back {
            tabs.moveReturn(to: MacSidebar.restore(back, shelf: removed))  // its list is gone: Back leads to the Library's
        }
        store.sheet = nil
    }
}
#endif
