// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (the settings redesign, 2026-10-19).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import Foundation
import PrepareMeShared
import SwiftUI

/// Settings' Household tab (owner, 2026-11-14, by click; it was Inventory's Settings row): the form once the
/// inventory is read, and the Inventory screen's own words while it isn't. It opens the inventory itself, since the
/// tab can be the first thing opened this launch. Your words for where you live shows either way (Our Home Task 1.3):
/// Edit Our Home's photo and page checks wait on them, inventory or not.
struct PrepareMeHouseholdSettings: View {
    @ObservedObject private var model = InventoryModel.shared

    var body: some View {
        Group {
            switch model.state {  // as PrepareMeInventoryView shows it
            case .notOpened: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing: VStack(spacing: 0) { InventoryMissing(); ownWordsAlone }
            case .problem(let why):
                VStack(spacing: 0) {
                    InventoryNote(text: "The inventory couldn't be read", line: why, kind: .damaged,
                                  symbol: "exclamationmark.triangle")
                    ownWordsAlone
                }
            case .ready(let inventory): InventorySettingsForm(inventory: inventory)
            }
        }
        .onAppear { model.open() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.open() }
    }

    var ownWordsAlone: some View {
        PMForm { OwnWordsSection() }.formStyle(.grouped).frame(maxWidth: 780).background(PrepareMeColors.ground)
    }
}

/// The inventory's Settings as one form (settings redesign; owner, 2026-10-19, by click, after the mockup): People, Pets, Pet food, How long to prepare for and Reminders, each titled with a line saying what it's for
/// (SettingsForm's words), in place of the Settings table with the household members under it; the Lists' settings
/// moved in, so there is one Settings page. Every figure stays where it was kept (the inventory's Settings rows, the
/// lists' own settings table, PrepareMe_Members, PrepareMe_Pets), and every change goes through the editor as before.
/// A typed figure saves on Return and when the field is left (the item form's lesson, 2026-10-19); a refusal shows in
/// red under its row.
struct InventorySettingsForm: View {
    let inventory: Inventory
    @ObservedObject private var model = InventoryModel.shared
    @ObservedObject private var pages = HouseholdPagesModel.shared
    @Environment(\.undoManager) private var undo
    @State private var membersProblem: String?
    @State private var petsProblem: String?
    @State private var petSaves = SaveChain()
    @State private var memberSaves = SaveChain()

    /// The inventory as it is now, so a list's change is made against what the file holds (as ItemForm reads it).
    var current: Inventory { if case .ready(let found) = model.state { found } else { inventory } }

    var body: some View {
        ScrollViewReader { scroll in
            PMForm {
                if let message = model.message {  // a refusal no row took (an Undo)
                    Text(message).foregroundStyle(PrepareMeColors.red).fixedSize(horizontal: false, vertical: true)
                }
                // look 3, change 9: Event mode is switched in one place, the main window's sidebar
                Section {
                    peopleRows
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(SettingsForm.lede).foregroundStyle(PrepareMeColors.text2)
                            Spacer()
                            // in the toolbar until Settings' Household tab (2026-11-14): the Settings window has none
                            if model.saving > 0 { ProgressView().controlSize(.small).help("Checking and saving") }
                        }
                        .padding(.bottom, 8)
                        Text(SettingsForm.people.title).font(.pmHeadline).foregroundStyle(PrepareMeColors.ink)
                        Text(SettingsForm.people.why).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        levelsFold
                        Text(HouseholdMembers.source).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    petRows
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SettingsForm.pets.title).font(.pmHeadline).foregroundStyle(PrepareMeColors.ink)
                        Text(SettingsForm.pets.why).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                }
                Section {
                    ForEach(SettingsForm.petFoodRows, id: \.self) { SettingFigureRow(figure: $0, inventory: current) }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SettingsForm.petFood.title).font(.pmHeadline).foregroundStyle(PrepareMeColors.ink)
                        Text(SettingsForm.petFood.why).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                }
                OwnWordsSection()  // after the people and pets (board 23), pet food kept with the pets
                Section {
                    figures(SettingsForm.howLongRows)
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SettingsForm.howLong.title).font(.pmHeadline).foregroundStyle(PrepareMeColors.ink)
                        Text(SettingsForm.howLong.why).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                }
                Section {
                    figures(SettingsForm.reminderRows)
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SettingsForm.reminders.title).font(.pmHeadline).foregroundStyle(PrepareMeColors.ink)
                        Text(SettingsForm.reminders.why).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            .background(PrepareMeColors.ground)  // no navigationTitle: it would retitle the Settings window
            .task(id: pages.showOwnWords) {  // the editor's Your Words for Where You Live… lands on its section
                guard pages.showOwnWords else { return }
                try? await Task.sleep(for: .milliseconds(300))  // once the form has laid out
                scroll.scrollTo(OwnWordsSection.id, anchor: .top)  // no motion: only folds move (design rules)
                pages.showOwnWords = false
            }
        }
    }

    /// The three activity-level definitions, folded away until asked for (beta run 2, B2-17)
    var levelsFold: some View {
        DisclosureGroup(HouseholdMembers.levelsFold) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(HouseholdMembers.activities, id: \.self) { activity in
                    Text("\(activity): \(HouseholdMembers.activityMeans[activity] ?? "")")
                        .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
            }
        }
        .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
    }

    /// A section's figures; a lists' figure only once the lists are handed over.
    @ViewBuilder func figures(_ rows: [SettingsForm.Figure]) -> some View {
        ForEach(rows.filter { !$0.lists || current.lists != nil }, id: \.self) {
            SettingFigureRow(figure: $0, inventory: current)
        }
        if current.lists == nil, rows.contains(where: \.lists) {
            Text(SettingsForm.listsLater).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
        }
    }

    // MARK: People

    @ViewBuilder var peopleRows: some View {
        let members = current.members
        if current.membersUnreadable {  // its table in another shape: nothing to change here (step 8a review)
            Text(HouseholdMembers.unreadable).foregroundStyle(PrepareMeColors.red).fixedSize(horizontal: false, vertical: true)
        } else if members.isEmpty {  // the old figures count until people are added
            Text(SettingsForm.peopleUntil).foregroundStyle(PrepareMeColors.caution).fixedSize(horizontal: false, vertical: true)
            figures(SettingsForm.peopleFallback)
        } else {
            FactLine(text: SettingsForm.peopleFact(members), counted: true)
        }
        ForEach(Array(members.enumerated()), id: \.offset) { n, member in
            HStack(spacing: 8) {  // each menu's word beside it and the menu its own width, never cut short
                Text(HouseholdMembers.age).foregroundStyle(PrepareMeColors.text2)
                Picker(HouseholdMembers.age, selection: choice(n, \.age)) {
                    ForEach(HouseholdMembers.ages, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                Text(HouseholdMembers.sex).foregroundStyle(PrepareMeColors.text2).padding(.leading, 8)
                Picker(HouseholdMembers.sex, selection: choice(n, \.sex)) {
                    ForEach(HouseholdMembers.sexes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                Text(HouseholdMembers.activity).foregroundStyle(PrepareMeColors.text2).padding(.leading, 8)
                if HouseholdMembers.isToddler(member.age) {
                    Text(HouseholdMembers.noActivity).foregroundStyle(PrepareMeColors.text2)
                } else {
                    Picker(HouseholdMembers.activity, selection: choice(n, \.activity)) {
                        ForEach(HouseholdMembers.activities, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .help(HouseholdMembers.activityMeans[member.activity] ?? "")
                }
                Spacer(minLength: 0)
                Button(HouseholdMembers.remove) { changeMembers { $0.remove(at: n) } }
            }
        }
        Button { changeMembers { $0.append(HouseholdMembers.blank) } } label: {
            Label(HouseholdMembers.add, systemImage: "plus")
        }
        .labelStyle(.titleAndIcon)
        .disabled(members.count >= HouseholdMembers.most || current.membersUnreadable)
        if let membersProblem {
            Text(membersProblem).foregroundStyle(PrepareMeColors.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One member's menu, saving the list when it changes.
    func choice(_ n: Int, _ key: WritableKeyPath<HouseholdMember, String>) -> Binding<String> {
        Binding(get: { current.members.indices.contains(n) ? current.members[n][keyPath: key] : "" },
                set: { value in changeMembers { if $0.indices.contains(n) { $0[n][keyPath: key] = value } } })
    }

    /// The whole list saved with one person changed, added or removed. Saves run one after another, each made against
    /// the list as the one before left it, as the pets' do, so a second quick change is never refused as changed since
    /// (the audit, 2026-10-22, finding 11).
    func changeMembers(_ edit: @escaping @MainActor (inout [HouseholdMember]) -> Void) {
        let previous = memberSaves.last
        let save = Task { @MainActor in
            _ = await previous?.value
            let before = current.members
            var next = before
            edit(&next)
            next = next.map(HouseholdMembers.normalized)
            guard next != before else { return nil as String? }
            return await model.applyHere(.setMembers(next, expected: before), undo: undo, name: HouseholdMembers.title)
        }
        memberSaves.last = save
        Task { membersProblem = await save.value }
    }

    // MARK: Pets

    @ViewBuilder var petRows: some View {
        let pets = current.pets
        if current.petsUnreadable {  // likewise
            Text(HouseholdPets.unreadable).foregroundStyle(PrepareMeColors.red).fixedSize(horizontal: false, vertical: true)
        } else if pets.isEmpty {  // the old total weights count until pets are added
            Text(SettingsForm.petsUntil).foregroundStyle(PrepareMeColors.caution).fixedSize(horizontal: false, vertical: true)
            figures(SettingsForm.petsFallback)
        } else {
            let fact = SettingsForm.petsFact(pets)
            FactLine(text: fact.text, counted: fact.counted)
        }
        ForEach(Array(pets.enumerated()), id: \.offset) { n, pet in
            PetRow(pet: pet) { edit in
                await changePets { if $0.indices.contains(n) { edit(&$0[n]) } }
            } remove: {
                Task { petsProblem = await changePets { if $0.indices.contains(n) { $0.remove(at: n) } } }
            }
        }
        Button {
            Task { petsProblem = await changePets { $0.append(HouseholdPets.blank(after: $0)) } }
        } label: {
            Label(HouseholdPets.add, systemImage: "plus")
        }
        .labelStyle(.titleAndIcon)
        .disabled(pets.count >= HouseholdPets.most || current.petsUnreadable)
        if let petsProblem {
            Text(petsProblem).foregroundStyle(PrepareMeColors.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The whole list saved with one pet changed, added or removed; why it wasn't kept, or nil. Saves run one after
    /// another, each made against the list as the one before left it, so a weight typed while the name is still being
    /// saved, or Remove clicked with a name half typed, is never refused as changed since (review, 2026-10-19).
    func changePets(_ edit: @escaping @MainActor (inout [HouseholdPet]) -> Void) async -> String? {
        let previous = petSaves.last
        let save = Task { @MainActor in
            _ = await previous?.value
            let before = current.pets
            var next = before
            edit(&next)
            guard next != before else { return nil as String? }
            return await model.applyHere(.setPets(next, expected: before), undo: undo, name: HouseholdPets.title)
        }
        petSaves.last = save
        return await save.value
    }
}

/// The pets' or the people's saves in the order they were made (InventorySettingsForm.changePets, changeMembers).
@MainActor final class SaveChain {
    var last: Task<String?, Never>?
}

/// The blue line adding a section up (a key fact), or, when the lists job can't count from it, the amber one.
struct FactLine: View {
    let text: String
    let counted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(counted ? PrepareMeColors.infoMark : PrepareMeColors.accent).frame(width: 8, height: 8)
            Text(text).foregroundStyle(counted ? PrepareMeColors.info : PrepareMeColors.caution)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One pet: its name and weight typed (each saved on Return or on leaving the field), Dog or Cat picked, and Remove;
/// a refusal in red under it.
struct PetRow: View {
    let pet: HouseholdPet
    let change: @MainActor (@escaping @MainActor (inout HouseholdPet) -> Void) async -> String?  // saved; why not, or nil
    let remove: () -> Void
    @State private var name = ""
    @State private var weight = ""
    @State private var problem: String?
    @State private var pending: HouseholdPet?  // a change sent to be saved and not answered yet (as CellEditor's)
    @FocusState private var focus: Field?

    enum Field { case name, weight }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                TextField(HouseholdPets.name, text: $name, prompt: Text(HouseholdPets.name))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)  // a box to type in: a grouped form's fields show none by default
                    .frame(maxWidth: 200)
                    .focused($focus, equals: .name)
                    .onSubmit(commitName)
                Picker(HouseholdPets.kind, selection: Binding(get: { pet.kind }, set: { kind in
                    var next = pet
                    next.kind = kind
                    send(next, { $0.kind = kind }) {}
                })) {
                    ForEach(HouseholdPets.kinds, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 100)
                Spacer(minLength: 0)
                TextField(HouseholdPets.pounds, text: $weight)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($focus, equals: .weight)
                    .onSubmit(commitWeight)
                Text(HouseholdPets.pounds).foregroundStyle(PrepareMeColors.text2)
                Button(HouseholdPets.remove, action: remove)
            }
            if let problem {
                Text(problem).foregroundStyle(PrepareMeColors.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            name = pet.name
            weight = SettingsForm.shown(pet.weight)
        }
        .onChange(of: pet) { _, new in
            if focus != .name { name = new.name }
            if focus != .weight { weight = SettingsForm.shown(new.weight) }
        }
        .onChange(of: focus) { old, _ in  // a field left saves, as on Return
            if old == .name { commitName() }
            if old == .weight { commitWeight() }
        }
        .onDisappear {  // the page left with a field still being typed in
            if focus == .name { commitName() }
            if focus == .weight { commitWeight() }
        }
    }

    func commitName() {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = pet
        next.name = typed
        guard next != pet, next != pending else { return }
        send(next, { $0.name = typed }) { name = pet.name }
    }

    func commitWeight() {
        switch SettingsForm.weight(weight) {
        case .failure(let why):
            problem = why.description
            weight = SettingsForm.shown(pet.weight)
        case .success(let found):
            var next = pet
            next.weight = found
            guard next != pet, next != pending else { return }
            send(next, { $0.weight = found }) { weight = SettingsForm.shown(pet.weight) }
        }
    }

    /// One field's change (`edit`, making the pet `next`), once: Return and then leaving the field send it one time.
    /// Only the field is changed, on the pet as the save before left it. `undo` puts the field back when it was refused.
    func send(_ next: HouseholdPet, _ edit: @escaping @MainActor (inout HouseholdPet) -> Void,
              refused undo: @escaping @MainActor () -> Void) {
        pending = next
        Task {
            problem = await change(edit)
            if problem != nil { undo() }
            pending = nil
        }
    }
}

/// One figure of the form, kept where it always was: an inventory Settings row's Value, or a lists' setting. Typed, it
/// saves on Return and when the field is left; a figure that can't be kept (not a number, below zero, not whole where
/// the lists job reads it whole) is refused in red under the row, and the field shows what is kept.
struct SettingFigureRow: View {
    let figure: SettingsForm.Figure
    let inventory: Inventory
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.undoManager) private var undo
    @State private var draft = ""
    @State private var pending: String?  // a value sent to be saved and not answered yet (as CellEditor's)
    @State private var problem: String?
    @FocusState private var focused: Bool

    /// The inventory's Settings row and its Value column, when the file has them.
    var settingsCell: (row: InventoryRow, column: InventoryColumn)? {
        guard let setting = inventory.settings.column(Inventory.Label.setting),
              let value = inventory.settings.column(Inventory.Label.value),
              let row = inventory.settingRows.first(where: { InventoryFile.same(InventoryValues.plain($0[setting]),
                                                                                 figure.setting) }) else { return nil }
        return (row, value)
    }

    var listsRow: ListRow? {
        inventory.lists?.rows(ListsLayout.settings).first { $0["Setting"].text == figure.setting }
    }

    /// What is kept, as the field shows it: a Settings Value of 0 is Grist's blank, and the lists job reads it so.
    var shown: String {
        if figure.lists { return listsRow?["Value"].text ?? "" }
        guard let (row, column) = settingsCell else { return "" }
        if let number = row[column].number { return number == 0 ? "" : SettingsForm.shown(number) }
        return InventoryValues.plain(row[column])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(figure.label) {
                HStack(spacing: 8) {
                    TextField(figure.label, text: $draft)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .focused($focused)
                        .onSubmit(commit)
                    Text(figure.unit).foregroundStyle(PrepareMeColors.text2).frame(width: 64, alignment: .leading)
                }
            }
            if let problem {
                Text(problem).foregroundStyle(PrepareMeColors.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(figure.lists ? listsRow == nil : settingsCell == nil)
        .onAppear { draft = shown }
        .onChange(of: shown) { _, new in if !focused { draft = new } }
        .onChange(of: focused) { _, now in if !now { commit() } }  // a field left saves, as on Return
        .onDisappear { if focused { commit() } }  // the page left with it still being typed in
    }

    func commit() {
        guard draft != shown, draft != pending else { return }
        switch SettingsForm.figure(draft, whole: figure.whole) {
        case .failure(let why):
            problem = why.description
            draft = shown
        case .success(let value):
            save(value)
        }
    }

    func save(_ value: Double?) {
        let change: InventoryChange
        if figure.lists {
            guard let row = listsRow else { return }
            change = .listSet(sheet: ListsLayout.settings, row: ListRowRef(row), column: "Value",
                              value: value.map { .number($0) } ?? .null, expected: row["Value"])
        } else {
            guard let (row, column) = settingsCell else { return }
            switch InventoryValues.stored(value.map(InventoryValues.number) ?? "", in: column) {
            case .success(let stored):
                change = .set(table: "Settings", row: row.id, colId: column.colId, value: stored)
            case .failure(let why):
                problem = why.description
                draft = shown
                return
            }
        }
        pending = draft
        Task {
            problem = await model.applyHere(change, undo: undo, name: figure.label)
            if problem != nil { draft = shown }
            pending = nil
        }
    }
}

extension InventoryModel {
    /// One change, its refusal kept for the row that made it (shown in red under it) rather than the page's line: nil
    /// when it was kept.
    func applyHere(_ change: InventoryChange, undo: UndoManager?, name: String) async -> String? {
        guard await apply(change, undo: undo, name: name) == nil else { return nil }
        defer { message = nil }
        return message ?? "Nothing was saved."
    }
}
#endif
