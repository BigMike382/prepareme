// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 7, part 2).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import PrepareMeShared
import SwiftUI
import UserNotifications

/// The lists on the phone (build plan phase 7, part 2): To do and Upkeep from the Mac's copy, the Event mode switch,
/// and the open recalls (top-ten plan phase 6). An adult's phone ticks a task done, marks an upkeep task done today and switches Event mode; each waits in
/// the outbox like any inventory change and shows at once. A child's phone reads them.
struct PhoneListsSection: View {
    let lists: PhoneLists
    @ObservedObject private var model = PhoneInventoryModel.shared

    var body: some View {
        // each a card, as the Inventory home's other rows (owner, 2026-10-25; InventoryLook)
        PMCard(title: "Lists") {
            if model.canEdit {
                Picker(selection: Binding(get: { lists.eventMode }, set: { model.switchEventMode($0) })) {
                    ForEach(ListsLayout.eventSwitch, id: \.self) { Text($0).tag($0) }
                } label: {
                    PMCardLabel(emoji: InventoryLook.Row.eventMode, title: "Event Mode")
                }
            } else {
                LabeledContent {
                    Text(lists.eventMode)
                } label: {
                    PMCardLabel(emoji: InventoryLook.Row.eventMode, title: "Event Mode")
                }
            }
        }
        PMCard {
            PMCardLink(emoji: InventoryLook.Row.todo,
                       title: "To Do (\(lists.todo.filter { !$0["Done"].isTicked }.count))") { PhoneToDoView() }
        }
        PMCard {
            PMCardLink(emoji: InventoryLook.Row.upkeep, title: "Upkeep") { PhoneUpkeepView() }
        }
        if let recalls = lists.recalls, !recalls.isEmpty {  // top-ten plan phase 6, Task 6.4
            PMCard {
                PMCardLink(emoji: InventoryLook.Row.recalls, title: "Recalls (\(recalls.count))") { PhoneRecallsView() }
            }
        }
    }
}

/// The open recalls for the household's items (top-ten plan phase 6, Task 6.4; the owner's fix 1: they left Today): an
/// adult's phone answers one (Not ours, Fixed, Replaced, Thrown away), which waits in the outbox like any change and
/// takes it off the list at once; a child's phone reads them. A Mac-only item's recall stays on the Mac.
struct PhoneRecallsView: View {
    @ObservedObject private var model = PhoneInventoryModel.shared

    var body: some View {
        let recalls = model.shown?.lists?.recalls ?? []
        PMList {
            if recalls.isEmpty { Text("No open recalls.").foregroundStyle(PrepareMeColors.text2) }
            ForEach(recalls, id: \.self) { recall in
                VStack(alignment: .leading, spacing: 6) {
                    Text(recall.item).fontWeight(.medium)
                    Text([recall.recall, recall.agency, recall.date, recall.level].filter { !$0.isEmpty }
                            .joined(separator: ", "))
                        .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    HStack(spacing: 16) {
                        let answers = PhoneRecall.answers(canEdit: model.canEdit)
                        if !answers.isEmpty {
                            Menu {
                                ForEach(answers, id: \.self) { word in
                                    Button(word) { model.edit(recall.answer(word), what: "\(recall.item): \(word)") }
                                }
                            } label: {
                                Label("Answer", systemImage: "checkmark.circle")
                            }
                            .pmAction()
                        }
                        if let page = URL(string: recall.link), page.scheme == "https" {
                            Link("Recall page", destination: page).font(.pmNote)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if !recalls.isEmpty {
                Text(RecallList.ours).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
        }
        .navigationTitle("Recalls")
        .pmTitleSmall()
    }
}

struct PhoneToDoView: View {
    @ObservedObject private var model = PhoneInventoryModel.shared
    @State private var editing: ToDoPick?

    var body: some View {
        let rows = model.shown?.lists?.todo ?? []
        PMList {
            // an empty list says where its rows come from (the Apple guidelines plan, phase 9: Apple's Writing page)
            if rows.isEmpty {
                Text(model.canEdit ? "Nothing to do. Add one with the button at the bottom." : "Nothing to do. To-dos are added on the Mac.")
                    .foregroundStyle(PrepareMeColors.text2)
            }
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if model.canEdit, !row.waiting {
                        Button { done(row) } label: {
                            Image(systemName: row["Done"].isTicked ? "checkmark.circle.fill" : "circle")
                                .font(.pmTitle)
                                // a 44-point tap, the picture its own size (Apple's Accessibility page; guidelines
                                // plan, phase 4)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        // a checkbox to VoiceOver: the task, then whether it's done (guidelines plan, phase 4)
                        .accessibilityLabel(row["Task"].text)
                        .accessibilityValue(row["Done"].isTicked ? "Done" : "Not done")
                        .accessibilityAddTraits(.isToggle)
                    }
                    // a tap edits it on an adult's phone (owner, 2026-10-30), as the Mac's double-click does; plain
                    // words elsewhere, never a switched-off button VoiceOver reads as "dimmed"
                    if model.canEdit, !row.waiting {
                        Button { editing = ToDoPick(row: row) } label: { details(row) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(PrepareMeColors.ink)
                            .accessibilityHint("Edits the to-do")
                    } else {
                        details(row)
                    }
                }
                .swipeActions(edge: .leading) {  // the tick, by swipe too (the Apple guidelines plan, phase 9)
                    if model.canEdit, !row.waiting {
                        Button(row["Done"].isTicked ? "Not done" : "Done") { done(row) }.tint(PrepareMeColors.okMark)
                    }
                }
                .contextMenu {  // a held finger: the row's tap and its tick (docs/design/menus.md)
                    if model.canEdit, !row.waiting {
                        Button("Edit…", systemImage: "pencil") { editing = ToDoPick(row: row) }
                        Button(row["Done"].isTicked ? "Not Done" : "Done",
                               systemImage: row["Done"].isTicked ? "circle" : "checkmark.circle") { done(row) }
                    }
                }
            }
        }
        .navigationTitle("To Do")
        .pmTitleSmall()
        .pmAddBar(show: model.canEdit) {
            Button { editing = ToDoPick(row: nil) } label: { Label("Add a to-do", systemImage: "plus") }.pmAction()
        }
        .sheet(item: $editing) { pick in NavigationStack { PhoneToDoForm(row: pick.row) } }
    }

    @ViewBuilder private func details(_ row: ListRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row["Task"].text).strikethrough(row["Done"].isTicked)
            let detail = [row["Horizon"].text, row["Due"].isBlank ? "" : "due \(row["Due"].text)"]
                .filter { !$0.isEmpty }.joined(separator: ", ")
            if !detail.isEmpty { Text(detail).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
            if !row["Why"].isBlank { Text(row["Why"].text).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
            if row["Life-safety"].isTicked { LifeSafetyTag() }
            if row.waiting { Text("Waiting for the Mac.").font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The tick's change: done, or not done again.
    private func done(_ row: ListRow) {
        model.edit(.listSet(sheet: ListsLayout.todo, row: ListRowRef(row), column: "Done",
                            value: .bool(!row["Done"].isTicked), expected: row["Done"]),
                   what: "\(row["Task"].text): done")
    }
}

/// Which to-do the form opens: a new one (nil) or one on the list.
struct ToDoPick: Identifiable {
    let id = UUID()
    let row: ListRow?
}

/// New To-Do or Edit To-Do on an adult's phone (owner, 2026-10-30): the columns the Mac's form has (`ListsLayout
/// .editable`), less the tick's, each through the Mac's checks once it arrives. Edits go cell by cell as the Mac's do.
struct PhoneToDoForm: View {
    let row: ListRow?
    @ObservedObject private var model = PhoneInventoryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var cells: [String: ListCell] = [:]

    var columns: [String] {
        let shown = row ?? ListRow(pos: -1, cells: [:])
        return (ListsLayout.sheets[ListsLayout.todo] ?? [])
            .filter { $0 != "Done" && $0 != "Done on" && ListsLayout.editable(ListsLayout.todo, column: $0, row: shown) }
    }

    var changed: [String] { columns.filter { (cells[$0] ?? .null) != (row?[$0] ?? .null) } }

    var body: some View {
        PMForm {
            if let why = row?["Why"], !why.isBlank, !columns.contains("Why") {
                Text(why.text).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            ForEach(columns, id: \.self) { column in
                ListField(sheet: ListsLayout.todo, column: column,
                          value: Binding(get: { cells[column] ?? .null }, set: { cells[column] = $0 }))
            }
        }
        .navigationTitle(row == nil ? "New To-Do" : "Edit To-Do")
        .pmTitleSmall()
        // a swipe down doesn't drop what was typed; Cancel does (the Apple guidelines plan, phase 9)
        .interactiveDismissDisabled(!changed.isEmpty)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(row == nil ? "Add" : "Save") { save() }
                    .disabled((cells["Task"] ?? .null).text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { cells = row?.cells ?? [:] }
    }

    func save() {
        let task = (cells["Task"] ?? .null).text
        guard let row else {
            model.edit(.listAdd(sheet: ListsLayout.todo, cells: cells.filter { !$0.value.isBlank }), what: "Added \(task)")
            return dismiss()
        }
        // an owner's row is found by its cells, so each change names the row as the one before it left it
        var current = row
        for column in changed {
            model.edit(.listSet(sheet: ListsLayout.todo, row: ListRowRef(current), column: column,
                                value: cells[column] ?? .null, expected: current[column]),
                       what: "\(task): \(column)")
            current.cells[column] = cells[column] ?? .null
        }
        dismiss()
    }
}

struct PhoneUpkeepView: View {
    @ObservedObject private var model = PhoneInventoryModel.shared

    var body: some View {
        let rows = (model.shown?.lists?.upkeep ?? []).filter { $0["Active"].isTicked }
        PMList {
            if rows.isEmpty { Text("No upkeep tasks yet. They're added on the Mac.").foregroundStyle(PrepareMeColors.text2) }
            ForEach(rows, id: \.self) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row["Task"].text)
                    let every = row["Every"].isBlank ? "" : "every \(row["Every"].text) \(row["Unit"].text)"
                    Text([every, row["Last done"].isBlank ? "never done" : "last done \(row["Last done"].text)",
                          row["Next due"].isBlank ? "" : "next due \(row["Next due"].text)"]
                            .filter { !$0.isEmpty }.joined(separator: ", "))
                        .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    if model.canEdit, row["Last done"] != ListCell.day(Date()) {
                        Button("Done today") {
                            model.edit(.listSet(sheet: ListsLayout.upkeep, row: ListRowRef(row), column: "Last done",
                                                value: .day(Date()), expected: row["Last done"]),
                                       what: "\(row["Task"].text): done today")
                        }
                        .pmAction()
                    }
                }
            }
        }
        .navigationTitle("Upkeep")
        .pmTitleSmall()
    }
}
/// Days of water and food (build plan phase 7, part 2), counted on this phone from its copy and its own changes, so
/// they stay right with the Mac off (SupplyShares.swift); the Mac's own count when the copy doesn't line up. Laid out
/// as the Today page's boxes (owner, 2026-11-14, by click): Water and Food side by side, "+N if filled" in the Water
/// box, then one Pet food box halved Cat | Dog (`InventoryHome`). In event mode only, each counted supply's run-out
/// line under the boxes, and the rule under them (step 8c, section 4; UseLog.swift). Under the calculators' row, on
/// a phone that may edit, the Not counted notice (owner, 2026-11-14, by click: the reasons left Today; under the
/// days they explain, owner 2026-11-16): the reasons as one amber row, Show them opening the rows left out.
struct PhoneSuppliesSection: View {
    let copy: PhoneInventory
    let links: CalculatorLinks?  // the daily library's, for the way to every supply's calculators (B2-30; R9.2)
    @ObservedObject private var model = PhoneInventoryModel.shared
    @Environment(\.dynamicTypeSize) private var size

    /// The log in event mode, else nil (no line)
    var log: PhoneUseLog? {
        RunsOut.log(copy, localSwitch: model.localEventMode,
                    localAt: UserDefaults.standard.object(forKey: PhoneInventoryModel.localSwitchAtKey) as? Date)
    }

    var body: some View {
        let supplies = copy.supply?.supplies ?? []
        let main = InventoryHome.mainKinds(supplies), pets = InventoryHome.petKinds(supplies, pets: copy.pets)
        let shown = supplies.filter { $0.perDay != nil }  // the counted ones: the run-out lines and the foot
        let hasCalculators = links.map { !model.supplyCalculators(copy, links: $0).isEmpty } ?? false
        let notCounted = model.canEdit ? copy.supply?.notCountedLine : nil
        if !main.isEmpty || !pets.isEmpty || hasCalculators || notCounted != nil {
            Section {
                let log = self.log
                if !main.isEmpty || !pets.isEmpty {
                    // side by side, one under another from xxxLarge up (R9.2, mockup 2)
                    let across = size >= .xxxLarge ? AnyLayout(VStackLayout(spacing: 8))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
                    VStack(spacing: 8) {
                        across {
                            ForEach(main, id: \.kind) { kind in
                                let found = SupplyShares.days(kind, in: copy)
                                chip(InventoryHome.chip(kind: kind.kind, days: found.days, target: kind.target),
                                     fill: InventoryHome.fillShort(kind))  // containers ticked Empty until needed
                            }
                        }
                        if !pets.isEmpty { petBox(pets) }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    if let log {  // beside the planned days, never in their place
                        ForEach(shown, id: \.kind) { kind in
                            Text(RunsOut.line(kind, copy: copy, log: log, own: RunsOut.ownTaps(model.outbox),
                                              have: SupplyShares.have(kind, in: copy)
                                                  ?? kind.days.flatMap { days in kind.perDay.map { days * $0 } }))
                                .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                        }
                    }
                }
                if hasCalculators {  // every group's calculators, stocked or not (B2-30)
                    NavigationLink { PhoneSupplyCalculatorsScreen(links: links) } label: {
                        Label(InventoryHome.calculatorsLink, systemImage: "function")
                    }
                }
                if let notCounted {
                    let left = copy.items.filter {
                        copy.supply?.leftOut(row: $0.position, item: copy.itemName($0)) == true
                    }
                    PMWarningRow(notCounted).listRowInsets(EdgeInsets())
                    if !left.isEmpty {
                        NavigationLink(SupplyShares.showThem(left.count)) {
                            ItemList(title: SupplyShares.leftOutTitle, rows: left)
                        }
                    }
                }
            } header: {
                Text(InventoryHome.suppliesTitle).foregroundStyle(PrepareMeColors.text2)
            } footer: {
                let foot = [shown.allSatisfy { SupplyShares.days($0, in: copy).here } ? nil : "As the Mac last counted them.",
                            log == nil ? nil : RunsOut.rule]  // the rule under the lines, in event mode
                    .compactMap { $0 }.joined(separator: "\n")
                if !shown.isEmpty, !foot.isEmpty {  // nothing when this device counted them (owner, 2026-11-16)
                    Text(foot).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
            }
        }
    }

    /// One supply: its days big, what they count and the goal in words under; short of the goal in red, with a
    /// heavier edge and the spoken words too, so it never rests on color alone.
    func chip(_ chip: InventoryHome.Chip, fill: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chip.number).font(.pmCount.monospacedDigit())
                .foregroundStyle(chip.low ? PrepareMeColors.red : PrepareMeColors.ink)
            Text(chip.label).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            if let fill { Text(fill).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(chip.low ? PrepareMeColors.redMark : PrepareMeColors.edge, lineWidth: chip.low ? 3 : 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.spoken + (fill.map { ", \($0)" } ?? ""))
    }

    /// The Pet food box, full width under Water and Food: a half for each pet, its name over its days and goal, the
    /// days red when short of the goal (the goal says so in words too, and VoiceOver "short of goal"); as on Today
    /// only a half is marked short, never the box. The halves stack from xxxLarge up.
    func petBox(_ kinds: [SupplyShares.Kind]) -> some View {
        let stacked = size >= .xxxLarge
        let halves = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return VStack(alignment: .leading, spacing: 6) {
            Text(InventoryHome.petFoodTitle).font(.pmNote.weight(.semibold)).foregroundStyle(PrepareMeColors.text2)
                .accessibilityAddTraits(.isHeader)
            halves {
                ForEach(Array(kinds.enumerated()), id: \.element.kind) { index, kind in
                    let half = InventoryHome.half(days: SupplyShares.days(kind, in: copy).days, target: kind.target)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(InventoryHome.petName(kind)).font(.pmNote.weight(.semibold))
                            .foregroundStyle(PrepareMeColors.ink)
                        Text(half.number).font(.pmCount.monospacedDigit())
                            .foregroundStyle(half.low ? PrepareMeColors.red : PrepareMeColors.ink)
                        Text(half.label).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, index > 0 && !stacked ? 12 : 0)
                    .overlay(alignment: .leading) {  // the line between the halves
                        if index > 0 && !stacked { Rectangle().fill(PrepareMeColors.edge).frame(width: 1) }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(InventoryHome.petName(kind)): \(half.spoken)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PrepareMeColors.edge, lineWidth: 1))
    }
}

/// The grab-and-go checklist (build plan phase 7, part 2): each bin or item ticked as it goes in the car, on this phone
/// only (never sent), with Start over for the next time.
struct PhoneGrabChecklistView: View {
    @ObservedObject private var model = PhoneInventoryModel.shared
    @AppStorage("PrepareMe.grabTicks") private var stored = ""
    @AppStorage("PrepareMe.grabVehicles") private var vehiclesGoing = ""  // the vehicles ticked as going, by id
    @State private var confirming = false

    var ticked: Set<String> { Set(stored.split(separator: "\n").map(String.init)) }
    var going: Set<Int64> { Set(vehiclesGoing.split(separator: "\n").compactMap { Int64($0) }) }

    func toggle(_ id: String) {
        var found = ticked
        if found.contains(id) { found.remove(id) } else { found.insert(id) }
        stored = found.sorted().joined(separator: "\n")
    }

    func toggleVehicle(_ id: Int64) {
        var found = going
        if found.contains(id) { found.remove(id) } else { found.insert(id) }
        vehiclesGoing = found.sorted().map(String.init).joined(separator: "\n")
    }

    var body: some View {
        let list = model.shown.map { GrabChecklist($0, going: going) }
        let all = list?.all ?? []
        let done = all.filter { ticked.contains($0.id) }.count
        PMList {
            if let vehicles = list?.vehicles, !vehicles.isEmpty {
                Section {
                    ForEach(vehicles) { vehicle in
                        Toggle(isOn: Binding(get: { going.contains(vehicle.id) }, set: { _ in toggleVehicle(vehicle.id) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(InventoryLook.title(vehicle.name))
                                Text("\(vehicle.items) item\(vehicle.items == 1 ? "" : "s") kept in it")
                                    .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                            }
                        }.pmSwitch()
                    }
                } header: {
                    Text("Which vehicles are going?").foregroundStyle(PrepareMeColors.text2)
                } footer: {
                    if let loaded = list?.loaded, loaded > 0 {
                        Text("\(loaded) item\(loaded == 1 ? " is" : "s are") loaded already in the vehicles going.")
                            .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                }
            }
            if all.isEmpty {
                Text(list?.vehicles.isEmpty == false && !going.isEmpty
                     ? "Nothing else to grab: what's marked Grab is in the vehicles going."
                     : "Nothing is marked to grab yet. On the Mac, set Grab on a bin (a place) or an item.")
                    .foregroundStyle(PrepareMeColors.text2)
            } else {
                Section {
                    Text("\(done) of \(all.count) packed").font(.pmHeadline)
                }
                section("Grab in 10 minutes", list?.tenMinutes ?? [])
                section("Grab in an hour", list?.anHour ?? [])
            }
        }
        .navigationTitle("Grab-and-Go Checklist")
        .pmTitleSmall()
        .toolbar {
            if done > 0 || !going.isEmpty {
                Button("Start over") { confirming = true }
            }
        }
        .confirmationDialog("Untick everything?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Start over", role: .destructive) {
                stored = ""
                vehiclesGoing = ""
            }
        }
    }

    @ViewBuilder func section(_ title: String, _ entries: [GrabChecklist.Entry]) -> some View {
        if !entries.isEmpty {
            Section(pmTitle: title) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { toggle(entry.id) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: ticked.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.pmTitle)
                                    .foregroundStyle(ticked.contains(entry.id) ? PrepareMeColors.okMark : PrepareMeColors.text2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(InventoryLook.title(entry.name)).foregroundStyle(.primary)
                                    // a bin's count or an item's quantity (Task 12.1; F31), then where it is
                                    if !entry.detail.isEmpty {
                                        Text(entry.detail).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                                    }
                                    if !entry.whereKept.isEmpty {
                                        Text(InventoryLook.title(entry.vehicle == nil ? entry.whereKept : "From \(entry.whereKept)"))
                                            .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(entry.name)\(entry.detail.isEmpty ? "" : ", \(entry.detail)")")
                        .accessibilityValue(ticked.contains(entry.id) ? "packed" : "not yet")
                        .accessibilityAddTraits(.isToggle)  // a checkbox to VoiceOver (guidelines plan, phase 4)
                        if !entry.contents.isEmpty {  // a bin's names, a tap away (owner, 2026-10-18, by click)
                            DisclosureGroup {
                                Text(entry.contents.joined(separator: ", "))
                                    .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                // VoiceOver hears whose (review), and the shown words first (spec section 8, fix 10)
                                let spoken = SpokenName.of("What's in \(entry.name)", word: "What's in it")
                                Text("What's in it").accessibilityLabel(spoken.label).accessibilityHint(spoken.hint ?? "")
                            }
                            .font(.pmNote)
                            .pmTint()
                            .padding(.leading, 36)  // under the name, past the tick
                        }
                    }
                    .swipeActions(edge: .leading) {  // the tick, by swipe too (the Apple guidelines plan, phase 9)
                        Button(ticked.contains(entry.id) ? "Not packed" : "Packed") { toggle(entry.id) }
                            .tint(PrepareMeColors.okMark)
                    }
                }
            }
        }
    }
}

/// Expiry reminders (build plan phase 7, part 2): scheduled on this phone from its copy, a count only, each time the
/// copy changes what they'd say. iOS's question comes only from Turn on reminders, under the app's own line (`ask`;
/// Task 12.6, F38): scheduling never asks; a no leaves nothing scheduled.
@MainActor
enum PhoneExpiryReminders {
    private static var last: [ExpiryReminders.Reminder]?

    /// The phone's answer for notifications, as the location's (LocationAsk.Status).
    static func status() async -> LocationAsk.Status {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .refused
        default: .allowed
        }
    }

    /// iOS's question, after the app's line, then the reminders at once if allowed.
    static func ask(_ copy: PhoneInventory) async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        last = nil
        schedule(copy)
    }

    static func schedule(_ copy: PhoneInventory) {
        let reminders = ExpiryReminders.make(copy)
        guard reminders != last else { return }
        last = reminders
        Task {
            let center = UNUserNotificationCenter.current()
            if reminders.isEmpty {  // nothing to say: never ask for leave to say it, only clear what's waiting
                let waiting = await center.pendingNotificationRequests().map(\.identifier)
                    .filter { $0.hasPrefix(ExpiryReminders.identifierPrefix) }
                center.removePendingNotificationRequests(withIdentifiers: waiting)
                return
            }
            guard await status() == .allowed else {  // never asks here: Turn on reminders does (F38)
                last = nil  // so a later yes schedules them at the next look
                return
            }
            let pending = await center.pendingNotificationRequests().map(\.identifier)
                .filter { $0.hasPrefix(ExpiryReminders.identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            for reminder in reminders {
                let content = UNMutableNotificationContent()
                content.title = ExpiryReminders.title
                content.body = reminder.body
                let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.day, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content,
                                                            trigger: trigger))
            }
        }
    }
}
#endif
