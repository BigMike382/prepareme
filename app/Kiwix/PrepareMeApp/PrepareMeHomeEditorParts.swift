// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (the Our Home editor's fresh look,
// docs/plans/2026-11-20-our-home-editor.md, Task 5).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import PrepareMeShared
import SwiftUI

/// One part set on a step (board 2): its mark and what it says, its small line, and a × that takes it away. A stale
/// pick (`stale`, the place or item the phones' copy no longer holds under that name) sits on amber with "Pick again".
struct HomePartRow<Content: View>: View {
    enum Tone { case plain, danger, caution }
    let mark: String
    let title: String
    var titleColor = PrepareMeColors.ink
    let detail: String
    var tone = Tone.plain
    /// joined to the small line with " · ", as board 2's "Danger · make it a Caution"
    var action: (label: String, run: () -> Void)?
    /// its own button on the row, apart from the small line: Pick again (the design session, 2026-11-20)
    var button: (label: String, run: () -> Void)?
    let remove: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(mark).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if !title.isEmpty { Text(title).font(.pmBody.bold()).foregroundStyle(titleColor) }
                content()
                if !detail.isEmpty, detail != title || action != nil {  // a warning's own name once, not twice
                    HStack(spacing: 4) {
                        Text(action == nil ? detail : "\(detail) ·").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                        if let action {  // the teal of what you can press, underlined as the board draws it
                            Button(action: action.run) { Text(action.label).underline() }
                                .buttonStyle(.plain).font(.pmNote).foregroundStyle(PrepareMeColors.teal)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)  // its full height in a form's row, never a squashed box
            Spacer(minLength: 0)
            if let button {
                Button(button.label, action: button.run).controlSize(.small)
            }
            Button(action: remove) { Image(systemName: "xmark").font(.pmNote) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: PrepareMeCorners.control).fill(ground))
        .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.control).stroke(edge))
    }

    private var ground: Color {
        switch tone {
        case .plain: PrepareMeColors.tile
        case .danger: PrepareMeColors.redBg
        case .caution: PrepareMeColors.accentBg
        }
    }

    private var edge: Color {
        switch tone {
        case .plain: PrepareMeColors.line
        case .danger: PrepareMeColors.redMark
        case .caution: PrepareMeColors.accent
        }
    }
}

extension HomePartRow where Content == EmptyView {
    init(mark: String, title: String, detail: String, tone: Tone = .plain,
         action: (label: String, run: () -> Void)? = nil, button: (label: String, run: () -> Void)? = nil,
         remove: @escaping () -> Void) {
        self.init(mark: mark, title: title, detail: detail, tone: tone, action: action, button: button, remove: remove) {
            EmptyView()
        }
    }
}

/// A picker's list under its box: a heading on the tile, then its rows; the first row a pick of its own.
struct HomePickList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: PrepareMeCorners.control).fill(PrepareMeColors.panel))
        .clipShape(RoundedRectangle(cornerRadius: PrepareMeCorners.control))
        .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.control).stroke(PrepareMeColors.line))
    }

    static func heading(_ words: String) -> some View {
        Text(words).font(.pmNote.bold()).foregroundStyle(PrepareMeColors.text2)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading).background(PrepareMeColors.tile)
    }

    static func row(_ words: String, trailing: String = "", indent: Bool = false, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack {
                Text(words).foregroundStyle(PrepareMeColors.ink)
                Spacer()
                if !trailing.isEmpty { Text(trailing).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
            }
            .padding(.leading, indent ? 22 : 10).padding(.trailing, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Board 3: a place, picked from the phones' copy by any part of its path, or kept as typed.
struct HomePlacePicker: View {
    let copy: PhoneInventory?
    let pick: (HouseholdPage.Picked) -> Void
    @State var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HomeEditorWords.place).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            TextField(HomeEditorWords.place, text: Binding(get: { query }, set: {
                query = String($0.prefix(HouseholdPage.maxPlace))  // the box stops taking characters at 80
            }))
            .textFieldStyle(.roundedBorder).labelsHidden()
            let words = query.trimmingCharacters(in: .whitespaces)
            if !words.isEmpty {
                let found = copy.map { HomePick.places(words, in: $0) } ?? []
                HomePickList {
                    HomePickList<EmptyView>.heading(HomeEditorWords.inInventory)
                    if found.isEmpty {
                        Text(HomeEditorWords.noPlace(words)).font(.pmNote).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(found, id: \.id) { place in
                        HomePickList<EmptyView>.row(place.path, trailing: HomeEditorWords.itemCount(place.count)) {
                            pick(.init(id: place.id, words: HomePick.words(place.path)))
                        }
                    }
                    HomePickList<EmptyView>.heading(HomeEditorWords.or)
                    HomePickList<EmptyView>.row(HomeEditorWords.useTyped(words), trailing: HomeEditorWords.notInInventory) {
                        pick(.init(id: nil, words: words))
                    }
                }
            }
        }
    }
}

/// Board 6: a manual, picked from the copy's items that have one attached.
struct HomeManualPicker: View {
    let copy: PhoneInventory?
    let pick: (HouseholdPage.Picked) -> Void
    @State var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HomeEditorWords.manual).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            TextField(HomeEditorWords.manual, text: $query, prompt: Text(Image(systemName: "magnifyingglass")))
                .textFieldStyle(.roundedBorder).labelsHidden()
            let found = copy.map { HomePick.items(query, in: $0, withManual: true) } ?? []
            if !found.isEmpty {
                HomePickList {
                    HomePickList<EmptyView>.heading(HomeEditorWords.withManual)
                    ForEach(found, id: \.id) { item in
                        HomePickList<EmptyView>.row(item.name, trailing: item.place) { pick(.init(id: item.id, words: HomePick.words(item.name))) }
                    }
                }
            }
            Text(HomeEditorWords.manualNote).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Board 5: a guide, by search over the titles or by the Guides list's topics; one picker for a step's guide and the
/// page's Links to guides. A list with no topics (format 1, an older library) is one list.
struct HomeGuidePicker: View {
    let guides: [GuideList.Guide]
    var label = HomeEditorWords.guide
    let pick: (GuideList.Guide) -> Void
    @State var query = ""
    @State private var open: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            TextField(HomeEditorWords.guide, text: $query, prompt: Text("\(Image(systemName: "magnifyingglass")) \(HomeEditorWords.searchGuides)"))
                .textFieldStyle(.roundedBorder).labelsHidden()
            let groups = HomePick.guides(query, in: guides)
            let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
            if !groups.isEmpty {
                HomePickList {
                    ForEach(groups, id: \.topic) { group in
                        if group.topic.isEmpty {  // no topics: the one list
                            if searching || groups.count == 1 { rows(group.guides, indent: false) }
                        } else if searching {
                            HomePickList<EmptyView>.heading(HomeEditorWords.topicOf(group.topic, group.guides.count, group.total))
                            rows(group.guides, indent: false)
                        } else {
                            let isOpen = open.contains(group.topic)
                            Button {
                                if isOpen { open.remove(group.topic) } else { open.insert(group.topic) }
                            } label: {
                                HStack {
                                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.pmNote)
                                    Text(group.topic).fontWeight(isOpen ? .semibold : .regular)
                                    Spacer()
                                    Text("\(group.total)").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                                .background(isOpen ? PrepareMeColors.tealTint : .clear)
                            }
                            .buttonStyle(.plain)
                            if isOpen { rows(group.guides, indent: true) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder func rows(_ list: [GuideList.Guide], indent: Bool) -> some View {
        ForEach(list, id: \.page) { guide in HomePickList<EmptyView>.row(guide.title, indent: indent) { pick(guide) } }
    }
}

/// Board 8: a tag, its words and a × that takes it away.
struct HomeTag: View {
    let words: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(words).font(.pmNote.bold()).foregroundStyle(PrepareMeColors.teal)
            Button(action: remove) { Image(systemName: "xmark").font(.pmNote) }
                .buttonStyle(.borderless).accessibilityLabel("Remove \(words)")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(PrepareMeColors.tealTint))
    }
}

/// Board 8: a thing What you need lists, an item picked from the phones' copy (the phone shows where it's kept) or
/// words kept as typed; the box stops taking characters at 60.
struct HomeThingPicker: View {
    let copy: PhoneInventory?
    let pick: (HouseholdPage.Picked) -> Void
    @State var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(HomeEditorWords.need, text: Binding(get: { query }, set: {
                query = String($0.prefix(HouseholdPage.maxThing))
            }))
            .textFieldStyle(.roundedBorder).labelsHidden()
            let words = query.trimmingCharacters(in: .whitespaces)
            if !words.isEmpty {
                let found = copy.map { HomePick.items(words, in: $0, withManual: false) } ?? []
                HomePickList {
                    if !found.isEmpty {
                        HomePickList<EmptyView>.heading(HomeEditorWords.inInventory)
                        ForEach(found, id: \.id) { item in
                            HomePickList<EmptyView>.row(item.name, trailing: item.place) { chose(.init(id: item.id, words: HomePick.words(item.name))) }
                        }
                        HomePickList<EmptyView>.heading(HomeEditorWords.or)
                    }
                    HomePickList<EmptyView>.row(HomeEditorWords.useTyped(words), trailing: HomeEditorWords.notInInventory) {
                        chose(.init(id: nil, words: words))
                    }
                }
            }
        }
    }

    func chose(_ thing: HouseholdPage.Picked) {
        pick(thing)
        query = ""
    }
}

/// Board 4: a number to call and who it calls; the number tidied to its look when its box lets go of the keyboard,
/// and too few or too many digits said under it while typing.
struct HomeCallBoxes: View {
    @Binding var number: String
    @Binding var label: String
    let step: Int
    @FocusState private var onNumber: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Step \(step + 1): \(HomeEditorWords.call)", text: $number, prompt: Text(HomeEditorWords.call))
                    .focused($onNumber)
                TextField("Step \(step + 1): who it calls", text: $label,
                          prompt: Text("Who it calls, such as Gas emergency line"))
            }
            .textFieldStyle(.roundedBorder).labelsHidden()
            if !number.isEmpty, let problem = HouseholdPage.callProblem(number) {
                Text(problem).font(.pmNote).foregroundStyle(PrepareMeColors.caution)
            }
        }
        .onChange(of: onNumber) { _, now in
            guard !now, HouseholdPage.callProblem(number) == nil else { return }
            number = HomePage.shownNumber(number.filter(\.isNumber))  // Save keeps its digits alone
        }
    }
}
#endif
