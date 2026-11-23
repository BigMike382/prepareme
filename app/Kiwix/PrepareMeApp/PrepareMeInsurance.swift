// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 7, slice 7).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import AppKit
import ImageIO
import PrepareMeShared
import SwiftUI
import UniformTypeIdentifiers

/// The insurance record in an item's form (build plan phase 7, slice 7; Insurance.swift), Mac only: a button that adds
/// the Purchased, Price and Serial number columns the first time (they then show with the item's other columns; a
/// record started before serial numbers offers to add that one), and the item's photos. A photo is made small here (1600 pixels on its long side, JPEG) and carries none of the original's metadata,
/// so no camera location is kept; the editor reads its text for the ID check before keeping it.
struct InsuranceSection: View {
    let inventory: Inventory
    let id: Int64
    @ObservedObject private var model = InventoryModel.shared
    @Environment(\.undoManager) private var undo
    @State private var enlarged: InventoryPhoto?
    @State private var adding = false

    var body: some View {
        Section(pmTitle: "Insurance record (Mac only)") {
            if !inventory.hasInsuranceRecord {
                HStack {
                    Text("Adds Purchased, Price and Serial number to every item, kept on this Mac and in its backups "
                         + "only.")
                        .foregroundStyle(PrepareMeColors.text2)
                    Spacer()
                    Button("Start the record") {
                        Task { await model.apply(.startInsurance, undo: nil, name: "Start the insurance record") }
                    }
                }
            } else if inventory.needsSerialColumn {  // a record started before serial numbers (step 6, part 1)
                HStack {
                    Text("Adds Serial number to every item, kept on this Mac and in its backups only, never on a "
                         + "phone.")
                        .foregroundStyle(PrepareMeColors.text2)
                    Spacer()
                    Button("Add serial numbers") {
                        Task { await model.apply(.startInsurance, undo: nil, name: "Add serial numbers") }
                    }
                }
            }
            let photos = model.photos(of: id)
            if !photos.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(photos) { photo in
                            VStack(spacing: 4) {
                                if let image = NSImage(data: photo.jpeg) {
                                    Image(nsImage: image).resizable().scaledToFill().frame(width: 96, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .onTapGesture { enlarged = photo }
                                        .help("Show it larger")
                                        // a button to VoiceOver too (the Apple guidelines plan, phase 4)
                                        .accessibilityLabel("Photo").accessibilityAddTraits(.isButton)
                                        .accessibilityAction { enlarged = photo }
                                }
                                Button("Remove") {
                                    Task { await model.apply(.removePhoto(id: photo.id, row: id), undo: undo,
                                                             name: "Remove photo") }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            HStack {
                Button(adding ? "Reading the photos…" : "Add photos…") { pick() }.disabled(adding)
                Text("A photo's words are checked like a cell's (prices are fine): one showing an ID number or a "
                     + "labeled account, code or PIN isn't kept.")
                    .font(.pmNote).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $enlarged) { photo in
            VStack {
                if let image = NSImage(data: photo.jpeg) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 900, maxHeight: 700)
                }
                HStack {
                    Spacer()
                    Button("Done") { enlarged = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
    }

    /// The open panel, then each picked image made small and kept in turn (each through the editor's checks).
    func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Pick photos of this item, its receipt or its label."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        adding = true
        Task {
            defer { adding = false }
            for url in urls {
                guard let jpeg = Self.small(url) else {
                    model.message = "\(url.lastPathComponent) couldn't be read as a photo."
                    continue
                }
                if await model.apply(.addPhoto(row: id, jpeg: jpeg), undo: undo, name: "Add photo") == nil { break }
            }
        }
    }

    /// The image at `url` at most 1600 pixels on its long side, upright, as a JPEG with no metadata (the household
    /// pages' photos are made the same way: HouseholdMedia.smallPhoto).
    static func small(_ url: URL) -> Data? {
        HouseholdMedia.smallPhoto(url)
    }
}
#endif
