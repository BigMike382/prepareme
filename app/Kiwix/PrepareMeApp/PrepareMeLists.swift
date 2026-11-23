// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 7, part 2).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
import PrepareMeShared
import SwiftUI

#if os(macOS)

/// The lists in the Inventory window (build plan phase 7, part 2; owner 2026-10-14: Numbers retires once this is built):
/// To do, Upkeep, Targets, Proposed, Recalls and the Numbers file's leftover Bought rows, kept in the inventory file's
/// own tables (ListsTables.swift) and read by the lists job at its next run; the lists' settings are in the inventory's
/// Settings form since the settings redesign (PrepareMeInventorySettings.swift). Every change goes through the editor:
/// the lists job's own reader on a throwaway copy, so nothing its next run would refuse is kept.
/// The lists job's own words (a task's Why, a recall's title) show as written and aren't changed here.
struct ListSheetView: View {
    let inventory: Inventory
    let sheet: String
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.undoManager) private var undo
    @State private var editing: ListFormPick?

    var lists: Lists { inventory.lists ?? .none }
    var rows: [ListRow] { lists.rows(sheet) }

    var body: some View {
        Group {
            if inventory.lists == nil {
                InventoryNote(text: ListsWords.notThere)
            } else {
                PMList {
                    if rows.isEmpty { Text(Self.empty[sheet] ?? "Nothing here.").foregroundStyle(PrepareMeColors.text2) }
                    if sheet == ListsLayout.recalls {
                        recallRows
                    } else {
                        ForEach(rows, id: \.self) { row in line(row) }
                    }
                }
            }
        }
        .navigationTitle(ListsLayout.shownTitle(sheet))
        .toolbar {
            ToolbarItemGroup {
                if model.saving > 0 { ProgressView().controlSize(.small).help("Checking and saving") }
                if ListsLayout.addable.contains(sheet), inventory.lists != nil {
                    Button { editing = ListFormPick(row: nil) } label: { Label("Add…", systemImage: "plus") }  // opens the form first (owner, 2026-11-19)
                        .help("Add a row")
                }
            }
        }
        .alert("Not Saved", isPresented: Binding(get: { model.message != nil && editing == nil },
                                                 set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .sheet(item: $editing) { picked in
            ListRowForm(sheet: sheet, row: picked.row)
        }
        #if PREPAREME_CHECK
        .task {  // the check build only: PREPAREME_CHECK_NEW_ROW=1 opens the new-row form 3 s in, for a check that can't click
            guard ProcessInfo.processInfo.environment["PREPAREME_CHECK_NEW_ROW"] == "1", hasForm else { return }
            try? await Task.sleep(for: .seconds(3))
            if inventory.lists != nil { editing = ListFormPick(row: nil) }
        }
        #endif
    }

    var hasForm: Bool { Self.hasForm(sheet) }
    static func hasForm(_ sheet: String) -> Bool { [ListsLayout.todo, ListsLayout.upkeep, ListsLayout.targets].contains(sheet) }

    func line(_ row: ListRow) -> some View {
        ListLine(sheet: sheet, row: row, set: { column, value in set(row, column, value) },
                 edit: { editing = ListFormPick(row: row) },
                 remove: ListsLayout.removable(sheet, row: row) ? { remove(row) } : nil, recall: recallShown(row),
                 serials: sheet == ListsLayout.recalls ? RecallList.serials(row, in: inventory) : [])
            .contextMenu {  // the row's own buttons too, in its order (docs/design/menus.md)
                if hasForm { Button("Edit…") { editing = ListFormPick(row: row) } }
                if let tick = ListLine.tick[sheet] {
                    Toggle(tick.label, isOn: Binding(get: { row[tick.column].isTicked },
                                                     set: { set(row, tick.column, .bool($0)) }))
                        .pmSwitch()
                }
                switch sheet {
                case ListsLayout.upkeep:
                    Button("Done Today") { set(row, "Last done", .day(Date())) }
                case ListsLayout.proposed:
                    // menu items, written apart from the row's buttons, which PaletteTests finds by their words
                    if let picked = ProposalPick.picked(row) {
                        Button { set(row, picked, .bool(false)) } label: { Text("Undo") }
                    } else {
                        Button { set(row, "Accept", .bool(true)) } label: { Text("Accept") }
                        Button { set(row, "Decline", .bool(true)) } label: { Text("Decline") }
                    }
                default:
                    EmptyView()
                }
                if ListsLayout.removable(sheet, row: row) {
                    if hasForm || ListLine.tick[sheet] != nil || [ListsLayout.upkeep, ListsLayout.proposed].contains(sheet) {
                        Divider()
                    }
                    PMMenuDelete("Delete") { remove(row) }
                }
            }
    }

    /// Top-ten plan phase 6, Task 6.3: the open recalls, then the cleared in a closed fold at the foot (a Status set
    /// back to Open there returns one to the list), and the script's note under them
    @ViewBuilder var recallRows: some View {
        let split = RecallList.split(rows)
        ForEach(split.open, id: \.self) { row in line(row) }
        if !split.cleared.isEmpty {
            DisclosureGroup(RecallList.clearedHeading(split.cleared.count)) {
                ForEach(split.cleared, id: \.self) { row in line(row) }
            }
        }
        if !rows.isEmpty {
            Text(RecallList.ours).font(.pmNote).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A recall's item, title and page as the Mac shows them: a Mac-only item's by its inventory item (RecallList)
    func recallShown(_ row: ListRow) -> (item: String, recall: String, link: URL?)? {
        guard sheet == ListsLayout.recalls else { return nil }
        return RecallList.shown(row, in: lists) { id in
            // the row's place in the list, as the lists job numbers it, never its stored id (step 6 review)
            inventory.itemRows.first { Int64($0.position) == id }.map { inventory.name(ofItem: $0) }
        }
    }

    static let empty: [String: String] = [
        ListsLayout.todo: "Nothing to do.", ListsLayout.upkeep: "No upkeep tasks yet. Add one with +.",
        ListsLayout.targets: "No targets of your own yet. Add one with +.",
        ListsLayout.proposed: "No proposals waiting.", ListsLayout.recalls: "No recalls found for your items.",
        ListsLayout.bought: "Nothing left to move.",
    ]

    func set(_ row: ListRow, _ column: String, _ value: ListCell) {
        Task {
            await model.apply(.listSet(sheet: sheet, row: ListRowRef(row), column: column, value: value,
                                       expected: row[column]), undo: undo, name: column)
        }
    }

    func remove(_ row: ListRow) {
        Task { await model.apply(.listRemove(sheet: sheet, row: ListRowRef(row)), undo: undo, name: "Delete") }
    }
}

struct ListFormPick: Identifiable {
    let row: ListRow?
    var id: String { row.map { "\($0.pos)-\($0.id)" } ?? "new" }
}

/// One row as a line: its ticks as checkboxes, its words, and its own buttons (an upkeep task's Done today, a
/// proposal's Accept and Decline, a recall's Status).
struct ListLine: View {
    let sheet: String
    let row: ListRow
    let set: (String, ListCell) -> Void
    let edit: () -> Void
    /// Delete, where the row can go (the right-click menu's, on the row's Edit… button too)
    var remove: (() -> Void)? = nil
    /// A recall's item, title and page as shown (RecallList.shown); nil on the other lists
    var recall: (item: String, recall: String, link: URL?)? = nil
    /// A recall's item's serial numbers on this Mac (step 6, part 1), to compare by eye; none on the other lists
    var serials: [String] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let tick = Self.tick[sheet] {
                Toggle(tick.label, isOn: Binding(get: { row[tick.column].isTicked },
                                                 set: { set(tick.column, .bool($0)) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .pmSwitch()
                    .help(tick.label)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if row["Life-safety"].isTicked { LifeSafetyTag() }
                }
                if !detail.isEmpty { Text(detail).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
                if let flag = upkeepFlag { Text(flag).font(.pmNote).foregroundStyle(PrepareMeColors.caution) }
                if let serial = RecallList.serialLine(serials) {
                    Text(serial).font(.pmNote).foregroundStyle(PrepareMeColors.text2).textSelection(.enabled)
                }
                if !row["Why"].isBlank, sheet != ListsLayout.targets {
                    Text(row["Why"].text).font(.pmNote).foregroundStyle(PrepareMeColors.text2).lineLimit(3)
                }
            }
            Spacer()
            buttons
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { edit() }
    }

    static let tick: [String: (column: String, label: String)] = [
        ListsLayout.todo: ("Done", "Done"), ListsLayout.upkeep: ("Active", "Active"),
        ListsLayout.bought: ("Moved", "Moved"),
    ]

    var title: String {
        switch sheet {
        case ListsLayout.todo, ListsLayout.upkeep: row["Task"].text
        case ListsLayout.targets: row["Item or category"].text
        case ListsLayout.proposed: row["Text"].text
        case ListsLayout.recalls: recall?.item ?? row["Item"].text
        default: row["Item"].text
        }
    }

    var detail: String {
        func join(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: ", ") }
        switch sheet {
        case ListsLayout.todo:
            return join([InventoryLook.title(row["Category"].text), row["Horizon"].text, row["Due"].isBlank ? "" : "due \(row["Due"].text)",
                         row["Cost"].text, row["Notes"].text])
        case ListsLayout.upkeep:
            let every = row["Every"].isBlank ? "" : "every \(row["Every"].text) \(row["Unit"].text)"
            return join([every, row["Last done"].isBlank ? "never done" : "last done \(row["Last done"].text)",
                         row["Next due"].isBlank ? "" : "next due \(row["Next due"].text)",
                         InventoryLook.title(row["Category"].text)])
        case ListsLayout.targets:
            let amount = row["Target"].isBlank ? "" : "\(row["Target"].text) \(row["Unit"].text)"
            let days = row["Days"].isBlank ? "" : "\(row["Days"].text) days"
            return join([amount, days, row["Horizon"].text, row["Why"].text])
        case ListsLayout.proposed:
            return join([row["List"].text, InventoryLook.title(row["Category"].text), row["Source"].text])
        case ListsLayout.recalls:
            return join([recall?.recall ?? row["Recall"].text, row["Agency"].text, row["Date"].text, row["Level"].text,
                         row["Checked on"].isBlank ? "" : "checked \(row["Checked on"].text)"])
        case ListsLayout.bought:
            return join([row["Quantity"].text, row["Unit"].text, row["Location"].text, row["Check"].text])
        default:
            return ""
        }
    }

    /// An upkeep row's quote check when it didn't pass (readiness/sources.py's words), so the owner sees which rows
    /// need a look; nil when it passed, and on the other lists
    var upkeepFlag: String? {
        let check = row["Check"].text
        return sheet == ListsLayout.upkeep && !check.isEmpty && check != "quote found" ? check : nil
    }

    @ViewBuilder var buttons: some View {
        switch sheet {
        case ListsLayout.upkeep:
            Button("Done Today") { set("Last done", .day(Date())) }.pmAction()
        case ListsLayout.proposed:
            // The row stays until the lists job's next hourly read takes it: say what was picked, and let it be undone
            if let picked = ProposalPick.picked(row) {
                Text(ProposalPick.note(picked, row: row)).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                Button("Undo") { set(picked, .bool(false)) }.pmAction()
            } else {
                Button("Accept") { set("Accept", .bool(true)) }.pmAction()
                Button("Decline") { set("Decline", .bool(true)) }.pmAction()
            }
        case ListsLayout.recalls:
            Picker("Status", selection: Binding(get: { ListsLayout.recallStatus(row["Status"].text) },
                                                set: { set("Status", $0.isEmpty ? .null : .text($0)) })) {
                Text("Open").tag("")
                ForEach(ListsLayout.recallStatuses, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            if let link = recall?.link {
                Link("Recall page", destination: link).font(.pmNote)
            }
        default:
            EmptyView()
        }
        if ListSheetView.hasForm(sheet) {  // look 3, accessibility fix 7: the right-click menu's items, a button the keyboard reaches
            if let remove {
                Menu("Edit…") { PMMenuDelete("Delete", action: remove) } primaryAction: { edit() }.fixedSize()
            } else {
                Button("Edit…", action: edit)
            }
        }
    }
}

/// A proposal the owner has answered, shown as answered until the lists job's next read takes it off the list.
enum ProposalPick {
    /// "Accept" or "Decline" when ticked, else nil
    static func picked(_ row: ListRow) -> String? {
        row["Accept"].isTicked ? "Accept" : row["Decline"].isTicked ? "Decline" : nil
    }

    static func note(_ picked: String, row: ListRow) -> String {
        picked == "Accept" ? "Accepted: goes on \(row["List"].text) within the hour"
                           : "Declined: leaves this list within the hour"
    }
}

/// A To do, Upkeep or Targets row as a form: every column the owner may change on it, each as its kind (a tick, a
/// date, a number, one of a menu's choices, or words). Save sends each changed cell through the editor in turn.
struct ListRowForm: View {
    let sheet: String
    let row: ListRow?
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.undoManager) private var undo
    @Environment(\.dismiss) private var dismiss
    @State private var cells: [String: ListCell] = [:]
    @State private var saving = false

    var columns: [String] {
        let shown = row ?? ListRow(pos: -1, cells: [:])
        return (ListsLayout.sheets[sheet] ?? []).filter { ListsLayout.editable(sheet, column: $0, row: shown) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row == nil ? "New \(sheet == ListsLayout.todo ? "Task" : sheet == ListsLayout.upkeep ? "Upkeep Task" : "Target")"
                 : "Edit").font(.pmHeadline)
            if let why = row?["Why"], !why.isBlank, sheet == ListsLayout.todo, !columns.contains("Why") {
                Text(why.text).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            PMForm {
                ForEach(columns, id: \.self) { column in
                    ListField(sheet: sheet, column: column, value: Binding(get: { cells[column] ?? .null },
                                                                          set: { cells[column] = $0 }))
                }
            }
            if let message = model.message {
                Text(message).font(.pmNote).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.message = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button(row == nil ? "Add" : "Save") { save() }.keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding()
        .frame(width: 460)
        .onAppear { cells = row?.cells ?? [:] }
    }

    func save() {
        saving = true
        Task {
            defer { saving = false }
            model.message = nil
            if let row {
                var current = model.lists?.find(ListRowRef(row), in: sheet) ?? row
                for column in columns where (cells[column] ?? .null) != row[column] {
                    guard await model.apply(.listSet(sheet: sheet, row: ListRowRef(current), column: column,
                                                     value: cells[column] ?? .null, expected: current[column]),
                                            undo: undo, name: column) != nil else { return }
                    // An owner's row is found by its cells, which that change just made new: found again by its place
                    // in the sheet for the next field (review 2026-10-14)
                    var changed = current
                    changed.cells[column] = cells[column] ?? .null
                    current = model.lists?.rows(sheet).first { $0.pos == current.pos && $0.id == current.id } ?? changed
                }
            } else {
                let filled = cells.filter { !$0.value.isBlank }
                guard await model.apply(.listAdd(sheet: sheet, cells: filled), undo: undo, name: "Add") != nil else {
                    return
                }
            }
            dismiss()
        }
    }
}

#endif

#if os(macOS) || os(iOS)
/// One field of a list's form, by its column's kind (the phone's To do form too, 2026-10-30).
struct ListField: View {
    let sheet: String
    let column: String
    @Binding var value: ListCell
    @State private var typed = ""

    var menu: [String]? {
        switch column {
        case "Horizon": ListsLayout.horizons
        case "Cost": ListsLayout.costs
        case "Category": ToBuyList.groups
        case "Unit" where sheet == ListsLayout.upkeep: ListsLayout.upkeepUnits
        default: nil
        }
    }

    var body: some View {
        if ListsLayout.tickColumns.contains(column) {
            Toggle(column, isOn: Binding(get: { value.isTicked }, set: { value = .bool($0) })).pmSwitch()
        } else if ListsLayout.dateColumns.contains(column) {
            HStack {
                Toggle(column, isOn: Binding(get: { value.day != nil },
                                             set: { value = $0 ? .day(Date()) : .null })).pmSwitch()
                if let day = value.day {
                    DatePicker(column, selection: Binding(get: { day }, set: { value = .day($0) }),
                               displayedComponents: .date)
                        .labelsHidden()
                }
            }
        } else if let menu {
            Picker(column, selection: Binding(get: { value.text }, set: { value = $0.isEmpty ? .null : .text($0) })) {
                Text("—").tag("")
                ForEach(menu, id: \.self) { Text(column == "Category" ? InventoryLook.title($0) : $0).tag($0) }
            }
        } else if ListsLayout.numberColumns.contains(column) {
            TextField(column, text: Binding(get: { value.text }, set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                value = trimmed.isEmpty ? .null : InventoryValues.parseNumber(trimmed).map { .number($0) } ?? .text(text)
            }))
        } else {
            TextField(column, text: Binding(get: { value.text }, set: { value = .text($0) }), axis: .vertical)
                .lineLimit(1...4)
        }
    }
}

#endif

#if os(macOS)
/// Event mode: Auto, On or Off, in the main window's sidebar, its one place (look 3, change 9): a menu, where three
/// segments don't fit.
struct EventModePicker: View {
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.undoManager) private var undo

    var body: some View {
        if let current = model.lists?.setting(ListsLayout.eventMode).text {
            let picker = Picker("Event mode", selection: Binding(get: { current.isEmpty ? "Auto" : current },
                                                                 set: { picked in
                                                                     Task { await model.setEventMode(picked, undo: undo) }
                                                                 })) {
                ForEach(ListsLayout.eventSwitch, id: \.self) { Text($0).tag($0) }
            }
            picker.pickerStyle(.menu).labelsHidden()
        } else {
            Text("Event mode shows here once the lists job hands the lists over, within the hour.")
                .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
        }
    }
}
#endif
