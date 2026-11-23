// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (library redesign plan 3.1).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import PrepareMeShared
import SwiftUI

/// One collection's card, on the Mac and the phones (library redesign plan 3.1; owner, 2026-11-13): its name, what it
/// is (the owner's line, else the file's own), **Inside:** what the file holds, its size and month (on the Mac, then
/// For the family or Mac only), and where it came from. No warning word: the Library's band says once that outside
/// collections come as they are (owner, 2026-11-13, by click: the source in place of "not checked").
struct PrepareMeLibraryCard: View {
    let item: LibraryShelf.Item
    let shelf: LibraryShelf
    var emoji: String?

    static let forFamily = "For the family"
    static let macOnly = "Mac only"
    @ObservedObject private var redNight = PrepareMeRedNight.shared

    /// Where it came from: the manifest's line, else what its kind says until the packer's next run gives one.
    static func source(_ item: LibraryShelf.Item) -> String {
        item.source ?? (item.notChecked ? "Kiwix" : "PrepareMe")
    }

    var body: some View {
        // an offer has no size line of its own: the reader still remembers a file removed here (phase 5)
        let record = item.offer == nil ? KiwixReader.record(item.id) : nil
        let about = shelf.description(for: item, recorded: record?.fileDescription)
        HStack(alignment: .firstTextBaseline) {
            if let emoji { Text(emoji).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 3) {
                Text(InventoryLook.title(item.title)).font(.pmHeadline.leading(.tight)).fontDesign(.serif)
                    .foregroundStyle(PrepareMeColors.ink)
                if let about { note(Text(about)) }
                if let inside = item.inside, !inside.isEmpty {
                    note(Text("\(Text("Inside:").bold()) \(inside)"))
                }
                if let record { note(sizeLine(size: record.size, date: record.created)) }
                if let offer = item.offer {  // family downloads plan, phase 5: offered, not on this device
                    note(Text("\(Text(HomeMacWords.notDownloaded).bold()) · \(StorageWords.size(offer.size))"))
                }
                note(Text(Self.source(item)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: Text) -> some View {
        text.font(.pmNote).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
    }

    /// "1.9 GB · January 2025", and on the Mac "· For the family" (teal; the ink on the red night screen, as the tint is) or "· Mac only": the phones hold what they
    /// show, so theirs stops at the month.
    private func sizeLine(size: Int64, date: Date) -> Text {
        let plain = "\(StorageWords.size(size)) · \(date.formatted(.dateTime.month(.wide).year()))"
        #if os(macOS)
        let mark = redNight.on ? PrepareMeColors.ink : PrepareMeColors.teal
        return item.family
            ? Text("\(plain) · \(Text(Self.forFamily).foregroundStyle(mark))")
            : Text("\(plain) · \(Self.macOnly)")
        #else
        return Text(plain)
        #endif
    }
}
