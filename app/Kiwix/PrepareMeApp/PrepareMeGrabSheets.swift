// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 7, part 2).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import AppKit
import PDFKit
import PrepareMeShared
import SwiftUI

/// Printed grab sheets (build plan phase 7, part 2; owner 2026-10-14: Private items included, since the paper stays
/// with its bin): first the grab lists (what to take in 10 minutes and in an hour, each bin or item with a box to tick
/// and its whole path, one in a vehicle marked loaded already if that vehicle goes), then a page for each vehicle (each
/// drawer, cabinet and bag in it, by its path, with what's in it; to keep in that vehicle), then a page for each bin not
/// in a vehicle, on US Letter, for when the phones are dead. Made on the Mac from the whole inventory, never for a phone.
enum GrabSheets {
    static let page = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 54
    static let linesPerPage = 34

    struct Sheet {
        let title: String
        let subtitle: String
        var lines: [Line]
    }

    struct Line {
        let text: String
        let detail: String
        let box: Bool
        let heading: Bool
    }

    /// The whole inventory as the checklist reads it, Private rows included (printing only).
    static func everything(_ inventory: Inventory) -> PhoneInventory {
        let copy = PhoneInventory.make(inventory, toBuy: nil, waiting: [], results: [:])
        return PhoneInventory(writtenAt: "", columns: copy.columns, items: inventory.itemRows.map {
            PhoneInventory.Row(id: $0.id, position: $0.position, values: $0.values)
        }, places: copy.places, categories: copy.categories, headsUpDays: copy.headsUpDays, toBuy: [], results: [:])
    }

    /// `vehicles`: the vehicles to give a page (nil: every one).
    static func sheets(_ inventory: Inventory, bins ids: [Int64], vehicles chosen: [Int64]? = nil,
                       printed: Date = Date()) -> [Sheet] {
        let all = everything(inventory)
        let list = GrabChecklist(all)
        func placeName(_ id: Int64) -> String { InventoryLook.title(inventory.name(ofLocation: id)) }
        let when = "Printed \(printed.formatted(date: .long, time: .omitted)) from PrepareMe. Check it against the bin."
        var grab = Sheet(title: "Grab and go", subtitle: when, lines: [])
        for (title, entries) in [("Grab in 10 minutes", list.tenMinutes), ("Grab in an hour", list.anHour)]
            where !entries.isEmpty {
            grab.lines.append(Line(text: title, detail: "", box: false, heading: true))
            for entry in entries {
                // places in title case, as the sidebar shows them (owner, 2026-10-31: everywhere they're read)
                let vehicle = entry.vehicle.map { "; loaded already if the \(placeName($0)) goes" } ?? ""
                let detail = [entry.whereKept.isEmpty ? "" : "In \(InventoryLook.title(entry.whereKept))\(vehicle)",
                              entry.contents.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: ". ")
                grab.lines.append(Line(text: entry.name, detail: detail, box: true, heading: false))
            }
        }
        if grab.lines.isEmpty {
            grab.lines.append(Line(text: "Nothing is marked Grab yet.", detail: "", box: false, heading: false))
        }
        var sheets = [grab]
        let quantity = inventory.items.column(Inventory.Label.quantity), unit = inventory.items.column("Unit")
        let expires = inventory.items.column("Expires")
        func line(_ row: InventoryRow) -> Line {
            func shown(_ column: InventoryColumn?) -> String {
                column.map { InventoryValues.shown(row[$0], in: $0, names: inventory.names(for: $0)) } ?? ""
            }
            let amount = [shown(quantity), shown(unit)].filter { !$0.isEmpty }.joined(separator: " ")
            let date = shown(expires)
            return Line(text: inventory.name(ofItem: row),
                        detail: [amount, date.isEmpty ? "" : "expires \(date)"].filter { !$0.isEmpty }
                            .joined(separator: ", "),
                        box: true, heading: false)
        }
        func sortedItems(in id: Int64) -> [InventoryRow] {
            inventory.items(in: .location(id)).filter { row in
                inventory.items.column(Inventory.Label.location).flatMap { row[$0].whole } == id
            }.sorted { inventory.name(ofItem: $0).localizedStandardCompare(inventory.name(ofItem: $1)) == .orderedAscending }
        }
        // A page for each vehicle (owner 2026-10-14): each drawer, cabinet and bag in it, by its path, with what's in it
        let vehicles = chosen ?? inventory.locationRows.map(\.id).filter(inventory.isVehicle)
        for vehicle in vehicles {
            let name = placeName(vehicle)
            var sheet = Sheet(title: name.isEmpty ? "Unnamed vehicle" : name,
                              subtitle: "Kept loaded in it. " + when, lines: [])
            let inside = inventory.within(vehicle).sorted {
                inventory.path(ofLocation: $0).localizedStandardCompare(inventory.path(ofLocation: $1)) == .orderedAscending
            }
            for place in inside {
                let rows = sortedItems(in: place)
                guard !rows.isEmpty else { continue }
                let path = place == vehicle ? "Loose in the \(name)"
                    : inventory.chain(ofLocation: place).reversed().drop { $0 != vehicle }.dropFirst()
                        .map(placeName).joined(separator: " › ")
                sheet.lines.append(Line(text: path, detail: "", box: false, heading: true))
                sheet.lines += rows.map(line)
            }
            if sheet.lines.isEmpty { sheet.lines.append(Line(text: "Nothing in it yet.", detail: "", box: false,
                                                             heading: false)) }
            sheets.append(sheet)
        }
        for id in ids where inventory.vehicle(holding: id) == nil {  // a vehicle's bins are on its own page
            let name = placeName(id)
            let kept = inventory.keptIn(id).map { "In \(InventoryLook.title(inventory.path(ofLocation: $0))). " } ?? ""
            let rows = inventory.items(in: .location(id)).sorted {
                inventory.name(ofItem: $0).localizedStandardCompare(inventory.name(ofItem: $1)) == .orderedAscending
            }
            var sheet = Sheet(title: name.isEmpty ? "Unnamed bin" : name, subtitle: kept + when, lines: [])
            sheet.lines += rows.map(line)
            if rows.isEmpty { sheet.lines.append(Line(text: "Nothing in it.", detail: "", box: false, heading: false)) }
            sheets.append(sheet)
        }
        return sheets
    }

    /// The sheets as a PDF: a sheet longer than a page goes on, "(continued)".
    @MainActor
    static func pdf(_ sheets: [Sheet]) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for sheet in sheets {
            for start in stride(from: 0, to: max(sheet.lines.count, 1), by: linesPerPage) {
                let part = Array(sheet.lines[start..<min(start + linesPerPage, sheet.lines.count)])
                let renderer = ImageRenderer(content: SheetPage(title: start == 0 ? sheet.title
                                                                    : "\(sheet.title) (continued)",
                                                                subtitle: sheet.subtitle, lines: part)
                    .frame(width: page.width, height: page.height))
                context.beginPDFPage(nil)
                renderer.render { _, draw in draw(context) }
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    @MainActor
    static func print(_ sheets: [Sheet]) {
        guard let document = PDFDocument(data: pdf(sheets)) else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.paperSize = page
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false)?.run()
    }
}

struct SheetPage: View {
    let title: String
    let subtitle: String
    let lines: [GrabSheets.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.heading {
                    Text(line.text).font(.system(size: 14, weight: .semibold)).padding(.top, 6)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.box ? "☐" : "").font(.system(size: 13)).frame(width: 14, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.text).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            if !line.detail.isEmpty {
                                Text(line.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(GrabSheets.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.black)
        .background(.white)
        .environment(\.colorScheme, .light)
    }
}
#endif

#if os(macOS)
/// The insurance record as a PDF (build plan phase 7, part 2; owner 2026-10-14): a summary of every item with a price
/// or a purchase date and the total, then a page for each such item with its photos (two to a row, four to a page),
/// written into the inventory folder whenever the record changes. The nightly lists job copies it to Household
/// Private › Backups › Insurance (readiness/backup.py), so the record opens on any phone or computer if the Mac is
/// lost. Never on a phone: the phones' copy carries none of it.
enum InsurancePDF {
    static let fileName = "insurance.pdf"
    static let summaryLines = 30

    struct Item {
        let name: String
        let detail: String
        let price: String
        let photos: [Data]
    }

    static func items(_ inventory: Inventory, photos: (Int64) -> [InventoryPhoto]) -> [Item] {
        let price = inventory.items.column(Insurance.price), purchased = inventory.items.column(Insurance.purchased)
        let serial = inventory.items.column(Insurance.serial)  // step 6, part 1
        let category = inventory.items.column(Inventory.Label.category)
        let location = inventory.items.column(Inventory.Label.location)
        return inventory.items(in: .insured).map { row in
            func shown(_ column: InventoryColumn?) -> String {
                column.map { InventoryValues.shown(row[$0], in: $0, names: inventory.names(for: $0)) } ?? ""
            }
            let bought = shown(purchased), number = shown(serial).trimmingCharacters(in: .whitespaces)
            // a category and a place in title case, as the sidebar shows them (owner, 2026-10-31)
            let detail = [InventoryLook.title(shown(category)), InventoryLook.title(shown(location)),
                          bought.isEmpty ? "" : "bought \(bought)",
                          number.isEmpty ? "" : "serial \(number)"]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            let amount = price.flatMap { row[$0].number }.map { $0.formatted(.currency(code: "USD")) } ?? ""
            return Item(name: inventory.name(ofItem: row), detail: detail, price: amount,
                        photos: photos(row.id).map(\.jpeg))
        }
    }

    /// A fingerprint of what the PDF shows (the items' words, and the photos' counts by item and their size), so it is
    /// written again only when that changes, without reading a photo to find out.
    static func digest(_ items: [Item], total: Double, photos: [[Int64]], bytes: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(total)
        hasher.combine(photos)
        hasher.combine(bytes)
        for item in items {
            hasher.combine(item.name)
            hasher.combine(item.detail)
            hasher.combine(item.price)
        }
        return hasher.finalize()
    }

    @MainActor
    static func pdf(_ items: [Item], total: Double, made: Date = Date()) -> Data {
        let page = GrabSheets.page
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        func draw(_ view: some View) {
            let renderer = ImageRenderer(content: view.frame(width: page.width, height: page.height))
            context.beginPDFPage(nil)
            renderer.render { _, render in render(context) }
            context.endPDFPage()
        }
        let when = "Made \(made.formatted(date: .long, time: .shortened)) by PrepareMe. "
            + "\(items.count) item\(items.count == 1 ? "" : "s"), \(total.formatted(.currency(code: "USD"))) in all."
        let lines = items.map { GrabSheets.Line(text: $0.name, detail: [$0.price, $0.detail].filter { !$0.isEmpty }
                                                    .joined(separator: " · "), box: false, heading: false) }
        for start in stride(from: 0, to: max(lines.count, 1), by: summaryLines) {
            draw(SheetPage(title: start == 0 ? "Insurance record" : "Insurance record (continued)", subtitle: when,
                           lines: Array(lines[start..<min(start + summaryLines, lines.count)])))
        }
        for item in items {
            for start in stride(from: 0, to: max(item.photos.count, 1), by: 4) {
                draw(InsurancePage(item: item, photos: Array(item.photos[start..<min(start + 4, item.photos.count)]),
                                   continued: start > 0))
            }
        }
        context.closePDF()
        return data as Data
    }
}

struct InsurancePage: View {
    let item: InsurancePDF.Item
    let photos: [Data]
    let continued: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(continued ? "\(item.name) (continued)" : item.name).font(.system(size: 20, weight: .bold))
            Text([item.price, item.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(photos.enumerated()), id: \.offset) { _, jpeg in
                    if let image = NSImage(data: jpeg) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 300)
                    }
                }
            }
            if photos.isEmpty { Text("No photos.").font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(GrabSheets.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.black)
        .background(.white)
        .environment(\.colorScheme, .light)
    }
}
#endif
