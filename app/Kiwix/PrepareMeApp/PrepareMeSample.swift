// This file is part of PrepareMe, a local build of Kiwix for one household's phones and Mac (Unlisted plan, phase 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import Combine
import CoreData
import PrepareMeShared
import SwiftUI

/// The sample library on an iPhone or iPad never paired (Unlisted plan, phase 4; SampleLibrary holds the rules): read
/// straight from the app's own Sample folder, never the library folder or the inventory copy file. It changes nothing
/// and sends nothing: the inventory reads only, no reminders, no pins. It is put away, leaving nothing behind, when
/// Leave is tapped, when the device pairs, or when any library arrives.
@MainActor
final class PrepareMeSample: ObservableObject {
    static let shared = PrepareMeSample()
    @Published private(set) var on = false
    private var watch: AnyCancellable?
    private var settling: Task<Void, Never>?

    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent(SampleLibrary.folder) }
    static let id = UUID(uuidString: SampleLibrary.id)!
    /// The sample's street map while it is open
    var mapFile: URL? { on ? Self.folder?.appendingPathComponent(SampleLibrary.map) : nil }

    /// Whether the welcome screen offers it now
    var offered: Bool {
        SampleLibrary.offered(hasFiles: SampleLibrary.hasFiles(in: Self.folder), paired: MacLink.pairing != nil,
                              held: PrepareMeLibrary.shared.store.record.held.count)
    }

    /// At launch: open it again, whole, at the app's new folder after an update, or put all of it away (SampleLibrary.
    /// atLaunch); a sample that can't be opened whole is put away, never left half-open. A second caller waits for the
    /// first to finish, so nothing puts it away while it is still opening.
    func settleOnce() async {
        if settling == nil { settling = Task { await settle() } }
        await settling?.value
    }

    private func settle() async {
        switch SampleLibrary.atLaunch(wasOn: UserDefaults.standard.bool(forKey: SampleLibrary.onKey),
                                      hasFiles: SampleLibrary.hasFiles(in: Self.folder),
                                      paired: MacLink.pairing != nil,
                                      held: PrepareMeLibrary.shared.store.record.held.count) {
        case .open: if !(await open()) { await putAway() }
        case .putAway: await putAway()
        case .nothing: break
        }
    }

    /// "Try the sample": opened on Today. False when it isn't offered or can't be opened whole.
    @discardableResult
    func start() async -> Bool {
        guard offered else { return false }
        guard await open() else {
            await putAway()
            return false
        }
        PrepareMeTabs.shared.selected = .today
        return true
    }

    private func open() async -> Bool {
        guard let folder = Self.folder, let copy = SampleLibrary.readInventory(in: folder),
              let meta = await LibraryOperations.open(url: folder.appendingPathComponent(SampleLibrary.library)),
              meta.fileID == Self.id else { return false }
        PhoneInventoryModel.shared.showSample(copy)
        UserDefaults.standard.set(true, forKey: SampleLibrary.onKey)
        on = true  // the reading tabs are made again (PrepareMeTabsView) and open the sample's pages
        PrepareMeTabs.shared.setMapsSide(.street)  // it has no topo maps (the stored side is a leftover key)
        // any library arriving puts it away (Add from Files, or a file the store took)
        watch = PrepareMeLibrary.shared.store.$record.map(\.held.count).removeDuplicates().filter { $0 > 0 }
            .sink { [weak self] _ in Task { await self?.putAway() } }
        return true
    }

    /// Everything the app kept of the sample removed: Kiwix's entry for it with its tabs, their history and bookmarks,
    /// its search words cache, the searches made and where the map was looking; the inventory back to none (or the
    /// copy saved before, if any). Safe to call when it was never opened.
    func putAway() async {
        let wasOn = on || UserDefaults.standard.bool(forKey: SampleLibrary.onKey)  // read before the key goes
        watch = nil
        PhoneInventoryModel.shared.leaveSample()
        await LibraryOperations.unlink(zimFileID: Self.id)
        if let record = KiwixReader.record(Self.id) {
            Database.shared.viewContext.delete(record)
            try? Database.shared.viewContext.save()
        }
        KiwixReader.forgetSpellings(SampleLibrary.id)
        // only when it was open: pairing and Add from Files put it away on the family's devices too (the lead, 2026-11-22)
        for key in SampleLibrary.removedAtPutAway(wasOn: wasOn) { UserDefaults.standard.removeObject(forKey: key) }
        // last: the reading tabs are made again only once Kiwix's tabs of the sample are gone, so they start empty
        if on {
            on = false
            PrepareMeTabs.shared.selected = .today
        }
    }
}

/// The strip on Today, Guides, Maps and Inventory while the sample is open (the plan's picture): the blue of a key
/// fact, never teal (what you can press) or amber (caution), with Leave.
struct SampleStrip: View {
    var body: some View {
        HStack(spacing: 12) { words; leave }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(PrepareMeColors.infoBg, ignoresSafeAreaEdges: .horizontal)
            // capped as the system's bars are: at the accessibility sizes it took a third of an SE's screen and hid the
            // map (2026-11-22); Today's page and Settings say the same words at full size
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var words: some View {
        Text("\(Text(SampleLibrary.stripTitle).bold()) \(SampleLibrary.stripWords)")
            .foregroundStyle(PrepareMeColors.info)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var leave: some View {
        Button(SampleLibrary.leave) { Task { await PrepareMeSample.shared.putAway() } }.pmAction(fullWidth: false)
    }
}

/// The strip over a tab's own screen while the sample is open: under the bar and its rows, in the screen's own colors
/// (inside the bar it took the band's dark look on Maps), and inside a search's page, so its search box stays (around
/// it, the iPad's search box went blank).
struct SampleStripped: ViewModifier {
    @ObservedObject private var sample = PrepareMeSample.shared

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) { if sample.on { SampleStrip() } }
    }
}

/// Settings' way out while the sample is open.
struct SampleSettings: View {
    @ObservedObject private var sample = PrepareMeSample.shared

    var body: some View {
        if sample.on {
            Section {
                Button(SampleLibrary.leaveSample) { Task { await sample.putAway() } }
            } footer: {
                Text("\(SampleLibrary.stripTitle) \(SampleLibrary.stripWords)")
                    .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
        }
    }
}
#endif
