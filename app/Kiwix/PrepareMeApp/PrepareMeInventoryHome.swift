// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (the inventory fresh look, phase 3).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import PrepareMeShared
import SwiftUI

/// Inventory's home page on the Mac (the inventory fresh look, phase 3; spec 5.1, board 1), in place of the gray list
/// column: drawn as the Library page is (its frame: 16 on top, 24 at the sides, 12 between, 1280 wide at most), the
/// band, the counts, the Not counted row, then a tile for each category, place and vehicle, and the less-used lists as
/// one row of buttons. What it lists, and when, is `InventoryHomeTiles` (PrepareMeShared). A tile has no right-click
/// menu: its one command is opening its table (`open`). Its toolbar is board 1's: New Item… and Add by Barcode… (they
/// open All Items and its form there) and Print; the Inventory menu has the same, with Export CSV… and Remove Empty
/// Places… (the owner's choice A), Edit Table and Columns dimmed (`InventoryCommands.home`).
struct PrepareMeInventoryHome: View {
    let inventory: Inventory
    let open: (InventoryPick) -> Void
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.undoManager) private var undo
    @State private var shares: SupplyShares?
    @State private var removingEmpty = false  // Inventory › Remove Empty Places…, from here too (the owner's choice A)

    var body: some View {
        GeometryReader { box in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    band
                    InventoryCounts(inventory: inventory, shares: shares)
                    InventoryNotCounted(inventory: inventory, padded: false)
                    heading("Categories", edit: ("Edit Categories", .table("Categories")))
                    let across = Self.across(box.size.width)
                    tiles(InventoryHomeTiles.categories(inventory), across: across) { .view(.category($0)) }
                    heading(InventoryWords.locations, edit: ("Edit Locations", .table("Locations")))
                    tiles(InventoryHomeTiles.locations(inventory), across: across) { .view(.location($0)) }
                    let vehicles = InventoryHomeTiles.vehicles(inventory)
                    if !vehicles.isEmpty {  // hidden with none
                        heading(InventoryWords.vehicles)
                        tiles(vehicles, across: across) { .view(.location($0)) }
                    }
                    heading("More Lists")
                    moreLists
                }
                .padding(.top, 16).padding(.horizontal, box.size.width < 760 ? 16 : 24).padding(.bottom, 48)
                .frame(maxWidth: 1280)
                .frame(maxWidth: .infinity)
            }
        }
        .pmScreen()
        .navigationTitle("Inventory")
        .toolbar { toolbar }
        .focusedSceneValue(\.inventoryMenu, InventoryMenuActions(
            state: .home, add: { add(byBarcode: false) }, addByBarcode: { add(byBarcode: true) }, openForm: {},
            editTable: {}, columns: [], setShown: { _, _ in }, resetColumns: {}, delete: {},
            removeEmptyPlaces: { removingEmpty = true }, printBlankSheet: { BlankSheet.print() },
            printLabels: { InventoryDetail.printLabels(inventory, picked: [], size: $0) },
            printGrabSheets: { InventoryDetail.printGrabSheets(inventory, picked: []) },
            exportCSV: { InventoryDetail.exportCSV(inventory) }))
        .sheet(isPresented: $removingEmpty) {
            EmptyPlacesSheet(inventory: inventory) { ids in
                Task { await model.apply(.deleteRows(table: "Locations", rows: ids), undo: undo,
                                         name: InventoryWords.removeEmptyTitle) }
            }
        }
        .alert("Not Saved", isPresented: Binding(get: { model.message != nil && !removingEmpty },
                                                 set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .task(id: inventory.itemRows.count) { shares = InventoryModel.folder.flatMap { SupplyShares.read(in: $0) } }
    }

    /// How many tiles fit across at 200 points each, 10 apart, in the page's frame (its sides, 1280 at most).
    static func across(_ width: CGFloat) -> Int {
        let inside = min(width, 1280) - 2 * (width < 760 ? 16 : 24)
        return max(1, Int((inside + 10) / 210))
    }

    /// The table's own buttons and words (`InventoryDetail`'s toolbar), for what applies with no table on screen.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { add(byBarcode: false) } label: { Label("New Item…", systemImage: "plus") }.help("Add an item")
                .labelStyle(.titleAndIcon)
            Button { add(byBarcode: true) } label: { Label("Add by Barcode…", systemImage: "barcode.viewfinder") }
                .help("Scan products one after another with a USB scanner, or type their codes")
                .labelStyle(.titleAndIcon)
            Menu {
                Button("Print Blank Sheet…") { BlankSheet.print() }
                Menu(InventoryWords.labelsItem(selected: 0)) {
                    ForEach(BinLabelSize.allCases) { size in
                        Button(size.title + "…") { InventoryDetail.printLabels(inventory, picked: [], size: size) }
                    }
                }
                Button("Print Grab Sheets…") { InventoryDetail.printGrabSheets(inventory, picked: []) }
            } label: {
                Label("Print", systemImage: "printer")
            }
            .help(InventoryWords.printTip(blank: true, labels: true, grab: true, selected: 0))
            .labelStyle(.titleAndIcon)
        }
    }

    /// New Item… or Add by Barcode…: All Items, whose table opens the form (`InventoryDetail.takeAdd`).
    private func add(byBarcode: Bool) {
        model.addAsked = byBarcode
        open(.table("Inventory"))
    }

    private var band: some View {
        PMBand {
            VStack(alignment: .leading, spacing: 6) {
                Text("Inventory").font(.pmTitle)
                Text(([InventoryHomeTiles.bandLine(items: inventory.itemRows.count,
                                                   places: inventory.locationRows.count)]
                      + [shares.flatMap { InventoryHomeTiles.countedLine($0.today) }].compactMap { $0 })
                    .joined(separator: " "))
            }
        }
        .card()
    }

    /// A section's heading in the book typeface, with its table's edit button beside it.
    private func heading(_ words: String, edit: (title: String, pick: InventoryPick)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(words).font(.pmHeadline).fontDesign(.serif).accessibilityAddTraits(.isHeader)
            if let edit {
                // the tint, as the Library page's links: teal reads 1.6:1 on the red night screen's black
                Button(edit.title) { open(edit.pick) }
                    .buttonStyle(.plain).foregroundStyle(.tint).fontWeight(.semibold)
                    .help("Open the \(edit.pick == .table("Categories") ? "Categories" : "Locations") table to rename, add or delete")
            }
        }
        .padding(.top, 4)
    }

    /// The tiles `across` to a row (`across(_:)`), each row as tall as its tallest tile, so a name that wraps
    /// ("Hygiene and Sanitation") leaves no tile in its row shorter (fix round 1, finding 6): the emoji in a
    /// teal-tint box, the name in the book typeface over what it holds.
    private func tiles(_ list: [InventoryTile], across: Int, pick: @escaping (Int64) -> InventoryPick) -> some View {
        let rows = stride(from: 0, to: list.count, by: across).map { Array(list[$0..<min($0 + across, list.count)]) }
        return VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    ForEach(rows[index]) { one in tile(one) { open(pick(one.id)) } }
                    ForEach(rows[index].count..<across, id: \.self) { _ in  // a short last row keeps the tiles' width
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ one: InventoryTile, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(one.emoji).font(.pmHeadline).frame(width: 34, height: 34)
                    .background(PrepareMeColors.tealTint, in: .rect(cornerRadius: PrepareMeCorners.control))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(one.name).font(.pmHeadline).fontDesign(.serif).foregroundStyle(PrepareMeColors.ink)
                    Text(one.detail).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)  // as tall as its row
            .pmPanel()
            .contentShape(.rect)  // the whole tile takes the click, its empty end too
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(one.name), \(one.detail)")
    }

    /// The less-used lists, each only where the old list column showed it (`InventoryHomeTiles.more`).
    private var moreLists: some View {
        FlowRow {
            ForEach(Array(InventoryHomeTiles.more(inventory).enumerated()), id: \.offset) { _, more in
                Button(more.title) { open(Self.pick(more)) }.pmAction(fullWidth: false)
            }
        }
    }

    static func pick(_ more: InventoryHomeTiles.More) -> InventoryPick {
        switch more {
        case .toDo: .list(ListsLayout.todo)  // their sidebar rows' lists (the owner's choice B)
        case .upkeep: .list(ListsLayout.upkeep)
        case .grab(let tier): .view(.grab(tier))
        case .targets: .list(ListsLayout.targets)
        case .proposed: .list(ListsLayout.proposed)
        case .recalls: .list(ListsLayout.recalls)
        case .privateOnly: .view(.privateOnly)
        case .insured: .view(.insured)
        case .bought: .list(ListsLayout.bought)
        }
    }
}

/// Buttons laid in lines, wrapping as the window narrows.
struct FlowRow: Layout {  // also Edit Our Home's Add to this step and tags
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = lines(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

/// The counts on Inventory's home page (look 3's strip over the table until phase 3; spec 5.1): All Items, To Buy and
/// Expiring Soon in the words the sidebar and the phone give them, each opening its list, then the days of water and of
/// food from the lists job's last count (supply.json), in the phones' words (`InventoryHome.chip`); a supply short of
/// its goal in red with a heavier edge, as on Today. No supply's count while the count has none. One to a row at the
/// large text sizes.
struct InventoryCounts: View {
    let inventory: Inventory
    let shares: SupplyShares?
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        let expiring = inventory.items(in: .expiringSoon).count
        layout {
            Group {  // each as tall as the tallest, whose words wrapped (fix round 1, finding 6)
                PMCount(inventory.itemRows.count, "All Items") { model.requestedPick = .table("Inventory") }.onPanel()
                PMCount(model.toBuy?.items.count ?? 0, "To Buy") { model.requestedPick = .toBuy }.onPanel()
                PMCount(expiring, "Expiring Soon", kind: expiring > 0 ? .attention : .info) {
                    model.requestedPick = .view(.expiringSoon)
                }
                .onPanel()
                ForEach(["water", "food"], id: \.self) { kind in
                    if let supply = shares?.supplies.first(where: { $0.kind == kind }) {
                        let chip = InventoryHome.chip(kind: kind, days: supply.days, target: supply.target)
                        PMCount(number: chip.number, chip.label, kind: chip.low ? .damaged : .info).onPanel()
                            .overlay {
                                if chip.low {
                                    RoundedRectangle(cornerRadius: PrepareMeCorners.panel)
                                        .strokeBorder(PrepareMeColors.redMark, lineWidth: 2)
                                }
                            }
                            .accessibilityLabel(chip.spoken)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
