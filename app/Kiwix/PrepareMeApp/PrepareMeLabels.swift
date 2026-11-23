// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 7, slice 6).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import AppKit
import PDFKit
import PrepareMeShared

/// Bin labels (build plan phase 7, slice 6; sizes, step 6 part 2): the bins' labels drawn by PrepareMeShared's
/// BinLabelSheet in the size picked (the Letter sheet, the 62 mm roll or the 29 × 90 mm labels), then printed.
enum BinLabels {
    static func labels(_ inventory: Inventory, ids: [Int64]) -> [BinLabel] {
        ids.compactMap { id in
            guard let row = inventory.locationRows.first(where: { $0.id == id }) else { return nil }
            let label = inventory.locations.column(Inventory.Label.label).map { InventoryValues.plain(row[$0]) } ?? ""
            // in title case, as the sidebar shows places (owner, 2026-10-31: everywhere they're read)
            let place = inventory.keptIn(id).map { InventoryLook.title(inventory.name(ofLocation: $0)) } ?? ""
            return BinLabel(id: id, name: InventoryLook.title(inventory.name(ofLocation: id)), label: label, place: place)
        }
    }

    /// The print panel for the labels at `size`'s own page size and no margins (Print, or PDF › Save as PDF). The Mac
    /// keeps paper narrow side first and reads a page wider than tall as landscape, which a label printer's roll may
    /// not match (the review): the orientation is set for each size, a roll's page may turn to fit its paper, and the
    /// panel shows the paper and orientation picked. The owner's test print on the QL-810Wc settles it.
    @MainActor
    static func print(_ labels: [BinLabel], size: BinLabelSize) {
        guard !labels.isEmpty, let document = PDFDocument(data: BinLabelSheet.pdf(labels, size: size)) else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.paperSize = size.page
        info.orientation = size.page.width > size.page.height ? .landscape : .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleNone,
                                                      autoRotate: size != .letter) else { return }
        operation.printPanel.options.insert([.showsPaperSize, .showsOrientation])
        operation.run()
    }
}
#endif
