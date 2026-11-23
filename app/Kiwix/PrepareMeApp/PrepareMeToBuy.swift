// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 7, slice 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import Foundation
import PrepareMeShared
import SwiftUI

/// To buy in the Inventory window (build plan phase 7, slice 4): the lists' ranked list (to-buy.json, written by the
/// lists job after each read), filtered by group. Bought… adds the item to the inventory and keeps its tick in one
/// save; Not needed and Add your own… are ticks. The lists job counts each tick once at its next run (ToBuy.swift,
/// readiness/apptobuy.py), and the app then drops it. An item with a tick waiting is hidden; an own item waits below.
struct ToBuyView: View {
    let inventory: Inventory
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.undoManager) private var undo
    @State private var group = ""
    @State private var buying: ToBuyList.Item?
    @State private var adding = false

    var waiting: [ToBuyTick] { model.ticks }

    var items: [ToBuyList.Item] {
        let ticked = Set(waiting.map(\.item))
        return (model.toBuy?.items ?? []).filter { !ticked.contains($0.id) && (group.isEmpty || $0.category == group) }
    }

    var groups: [String] {
        let present = Set((model.toBuy?.items ?? []).compactMap(\.category))
        return ToBuyList.groups.filter(present.contains)
    }

    var body: some View {
        Group {
            if model.toBuy == nil {
                InventoryNote(text: "To Buy shows here after the lists' next hourly run.")
            } else {
                PMList {
                    if items.isEmpty {
                        Text(group.isEmpty ? "Nothing to buy." : "Nothing to buy in \(InventoryLook.title(group)).").foregroundStyle(PrepareMeColors.text2)
                    }
                    ForEach(items) { item in
                        ToBuyRow(item: item, buy: { buying = item }, notNeeded: {
                            Task {
                                await model.apply(.tick(ToBuyTick(kind: .notNeeded, item: item.id)), undo: undo,
                                                  name: "Not Needed")
                            }
                        })
                    }
                    let own = waiting.filter { $0.kind == .add }
                    if !own.isEmpty {
                        Section(pmTitle: "Yours, waiting for the lists' next run") {
                            ForEach(own) { tick in
                                Text([tick.text, tick.need.map(InventoryValues.number), tick.unit.isEmpty ? nil : tick.unit]
                                        .compactMap { $0 }.joined(separator: " "))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("To Buy")
        .task {  // the lists write their list on their own schedule: re-read it every 30 seconds while it shows
            while !Task.isCancelled {
                model.refreshToBuy()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Group", selection: $group) {
                    Text("All Groups").tag("")
                    ForEach(groups, id: \.self) { Text(InventoryLook.title($0)).tag($0) }
                }
                .help("Show one group of the lists")
                Button { adding = true } label: { Label("Add Your Own", systemImage: "plus") }
                    .help("Add something of your own to To Buy")
            }
        }
        .alert("Not Saved", isPresented: Binding(get: { model.message != nil && buying == nil && !adding },
                                                 set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .sheet(item: $buying) { item in BoughtForm(inventory: inventory, item: item) }
        .sheet(isPresented: $adding) { OwnItemForm() }
    }
}

struct ToBuyRow: View {
    let item: ToBuyList.Item
    let buy: () -> Void
    let notNeeded: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.text).font(.pmHeadline)
                    if item.lifeSafety { LifeSafetyTag() }
                }
                let amount = [item.need.map(InventoryValues.number), item.unit.isEmpty ? nil : item.unit]
                    .compactMap { $0 }.joined(separator: " ")
                let line = [amount, InventoryLook.title(item.category ?? ""), item.horizon ?? ""].filter { !$0.isEmpty }
                if !line.isEmpty { Text(line.joined(separator: ", ")).foregroundStyle(PrepareMeColors.text2) }
                if !item.why.isEmpty { Text(item.why).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
            }
            Spacer()
            Button("Bought…", action: buy)
            Button("Not Needed", action: notNeeded)
        }
        .padding(.vertical, 4)
    }
}

/// Bought: what came home, added to the inventory in the same save as the tick.
struct BoughtForm: View {
    let inventory: Inventory
    let item: ToBuyList.Item
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.undoManager) private var undo
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var quantity = ""
    @State private var unit = ""
    @State private var category: Int64 = 0
    @State private var location: Int64 = 0
    @State private var expires = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bought").font(.pmTitle)
            Text("It goes into the inventory now; the lists take it off To Buy at their next run.")
                .foregroundStyle(PrepareMeColors.text2)
            if let message = model.message { Text(message).foregroundStyle(PrepareMeColors.text2) }
            PMForm {
                TextField("Item", text: $name).capitalFirst($name)
                TextField("Quantity", text: $quantity)
                TextField("Unit", text: $unit)
                Picker("Category", selection: $category) {
                    Text("").tag(Int64(0))
                    ForEach(sorted(names(Inventory.Label.category)), id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Location", selection: $location) {
                    Text("").tag(Int64(0))
                    ForEach(sorted(names(Inventory.Label.location)), id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("Expires (2026-11-15)", text: $expires)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.message = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to the Inventory") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // a shortfall's text is the list's sentence and its need the whole shortfall: both start blank, as on the
            // phone (addition A; phase 2 review, I2); an expiry's text is the list's sentence too (round 2, 2)
            name = item.isListSentence ? "" : item.text
            quantity = item.isShortfall ? "" : item.need.map(InventoryValues.number) ?? ""
            unit = item.unit
            category = inventory.categoryRows.first { inventory.group(ofCategory: $0.id) == item.category }?.id ?? 0
        }
    }

    func names(_ label: String) -> [Int64: String] {
        inventory.items.column(label).map { inventory.names(for: $0) } ?? [:]
    }

    func sorted(_ names: [Int64: String]) -> [(Int64, String)] {
        names.map { ($0.key, $0.value) }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    func save() {
        // a shortfall's tick takes its line off To buy: an item with no Quantity counts nothing (phase 2 review, M1)
        if let problem = QuickForm.quantityProblem(required: item.isShortfall, typed: quantity) {
            model.message = problem
            return
        }
        var values: [String: SQLValue] = [:]
        func put(_ label: String, _ typed: String) -> Bool {
            guard let column = inventory.items.column(label) else { return true }
            switch InventoryValues.stored(typed, in: column, names: inventory.names(for: column)) {
            case .success(let value): values[column.colId] = value; return true
            case .failure(let problem): model.message = "\(column.label): \(problem.description)"; return false
            }
        }
        guard put(Inventory.Label.item, name), put(Inventory.Label.quantity, quantity), put("Unit", unit),
              put(Inventory.Label.expires, expires) else { return }
        if let column = inventory.items.column(Inventory.Label.category) { values[column.colId] = .int(category) }
        if let column = inventory.items.column(Inventory.Label.location) { values[column.colId] = .int(location) }
        let tick = ToBuyTick(kind: .bought, item: item.id)
        Task {
            if await model.apply(.bought(values: values, tick: tick), undo: undo, name: "Bought") != nil {
                dismiss()
            }
        }
    }
}

/// Add your own: something to buy that the lists didn't work out, in one of their groups.
struct OwnItemForm: View {
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.undoManager) private var undo
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var need = ""
    @State private var unit = ""
    @State private var group = "Other"
    @State private var why = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to To Buy").font(.pmTitle)
            if let message = model.message { Text(message).foregroundStyle(PrepareMeColors.text2) }
            PMForm {
                TextField("Item", text: $text).capitalFirst($text)
                TextField("How many", text: $need)
                TextField("Unit", text: $unit)
                Picker("Group", selection: $group) {
                    ForEach(ToBuyList.groups, id: \.self) { Text(InventoryLook.title($0)).tag($0) }
                }
                TextField("Why (optional)", text: $why)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.message = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    func save() {
        let trimmed = need.trimmingCharacters(in: .whitespaces)
        let amount = trimmed.isEmpty ? nil : InventoryValues.parseNumber(trimmed)
        if !trimmed.isEmpty, amount == nil || amount! < 0 {
            model.message = "How many: \(InputProblem.notANumber.description)"
            return
        }
        let tick = ToBuyTick(kind: .add, text: text.trimmingCharacters(in: .whitespaces), need: amount,
                             unit: unit.trimmingCharacters(in: .whitespaces), category: group,
                             why: why.trimmingCharacters(in: .whitespaces))
        Task {
            if await model.apply(.tick(tick), undo: undo, name: "Add to To Buy") != nil { dismiss() }
        }
    }
}
#endif
