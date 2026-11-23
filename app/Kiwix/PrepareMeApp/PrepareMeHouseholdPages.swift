// This file is part of PrepareMe, a local build of Kiwix for one household's phones and Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import AppKit
import AVKit
import PrepareMeShared
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Household pages on the Mac (concept-doc plan, phase C; task plan docs/plans/2026-10-19-phase-c-household-pages.md;
/// the owner's mockup, 2026-10-19): the household's own step-by-step pages, written here and read on every phone one
/// step per screen. The pages, their photos and videos live in Household Private (HouseholdPagesFolder); every word is
/// ID-checked before a page is saved, every photo and video frame read and checked, and the owner looks at each photo
/// or video before it's kept (HouseholdMedia).
@MainActor
final class HouseholdPagesModel: ObservableObject {
    static let shared = HouseholdPagesModel()

    @Published private(set) var listed: [HouseholdPagesFolder.Listed] = []
    /// The editor's Your Words for Where You Live… was pressed: Settings › Household scrolls to that section, then clears it
    @Published var showOwnWords = false
    @Published private(set) var guides: [GuideList.Guide] = []
    /// The phones' copy of the inventory, never the Mac's own: the pickers' places and items (the editor plan, Task 4)
    @Published private(set) var copy: PhoneInventory?
    @Published private(set) var missing: [String] = []  // the pages Today looks for that aren't in the library (B2-26)
    @Published var message: String?
    /// Why the last Save of the open page was refused, for the editor's alert (owner, 2026-11-18: "not saving").
    @Published var saveRefused: String?
    @Published private(set) var busy: String?  // what the model is doing, said on screen
    /// The page open in the editor and what isn't saved yet: kept here, not in the view, so leaving the row or closing
    /// the window keeps the edits, and picking another page or quitting asks first (the audit, 2026-10-22, finding 3).
    @Published var working: Working?
    /// An imported draft's photos, each waiting for the owner's look before it's kept, as a picked photo (Task 3.2):
    /// the steps that name it, and the photo checked.
    @Published var importLooks: [(steps: [Int], prepared: Prepared)] = []

    struct Working {
        let name: String
        var page: HouseholdPage?
        var saved: HouseholdPage?  // nil: a new page, never saved
        /// Photos and videos taken off steps, set aside only once the page is saved: until then the saved page still
        /// names them (the review, 2026-10-19).
        var aside: [(photo: String, video: String)] = []
        /// Photos and videos kept since the last save, set aside by Don't Save or Cancel: the saved page doesn't name them.
        var added: [(photo: String, video: String)] = []
        var unsaved: Bool { page != nil && page != saved }
    }

    /// The owner's words for where the household lives (house number, street name...): kept only in this app's
    /// defaults on this Mac, as names typed when pairing are; never in the library, a page or git.
    static let ownWordsKey = "prepareme.household.ownWords"
    var ownWords: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.ownWordsKey) ?? [] }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                      forKey: Self.ownWordsKey)
        }
    }

    var folder: HouseholdPagesFolder? { PrepareMeHome.url.map(HouseholdPagesFolder.init) }

    func refresh() {
        listed = folder?.list() ?? []
    }

    /// The page's paper card (Task 4.3), as saved, through the Mac's print dialog.
    func printCard(_ name: String) {
        guard let page = read(name) else { return }
        HomeCardPrint.print(HomeCard(page, name: name, printed: Date()), photos: folder?.daily)
    }

    func read(_ name: String) -> HouseholdPage? {
        do {
            return try folder?.read(name)
        } catch {
            message = HouseholdPagesWords.handWritten
            return nil
        }
    }

    /// Checks every word, then saves; whether it was saved. Fails closed: no check, no save.
    func save(_ page: HouseholdPage, as name: String) async -> Bool {
        guard let folder else { return false }
        if let problem = page.problem {  // what the packer would refuse: never a page that stops the build
            message = problem
            return false
        }
        busy = HouseholdPagesWords.checking
        defer { busy = nil }
        do {
            if let refusal = try await HouseholdMedia.refusal(page: page, ownWords: ownWords,
                                                              checker: InventoryModel.checker()) {
                message = refusal
                return false
            }
            try folder.save(page, as: name)
            message = HouseholdPagesWords.saved
            refresh()
            return true
        } catch let unavailable as CheckUnavailable {
            message = unavailable.description
        } catch HouseholdPagesFolder.Problem.handWritten {
            message = HouseholdPagesWords.handWritten
        } catch {
            message = HouseholdPagesWords.notSaved
        }
        return false
    }

    /// A photo or video made ready and checked, for the owner's look before it's kept.
    struct Prepared: Identifiable {
        let id = UUID()
        let preview: CGImage
        let jpeg: Data?  // a photo
        let video: URL?  // a converted video, in the app's temporary folder
    }

    func preparePhoto(_ url: URL) async -> Prepared? {
        if let first = HouseholdMedia.wordsFirst(ownWords) {  // nothing kept until the owner's words are entered
            message = first
            return nil
        }
        busy = HouseholdPagesWords.readingPhoto
        defer { busy = nil }
        guard let jpeg = HouseholdMedia.smallPhoto(url),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            message = HouseholdWords.notAPhoto
            return nil
        }
        guard let text = await PhotoText.read(image: image) else {
            message = HouseholdWords.unreadablePhoto
            return nil
        }
        return await checked([text], label: "a photo") ? Prepared(preview: image, jpeg: jpeg, video: nil) : nil
    }

    func prepareVideo(_ url: URL) async -> Prepared? {
        if let first = HouseholdMedia.wordsFirst(ownWords) {  // before the conversion's wait
            message = first
            return nil
        }
        busy = HouseholdPagesWords.readingVideo
        defer { busy = nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("household-\(UUID().uuidString).mp4")
        do {
            try await HouseholdMedia.convertVideo(url, to: out)
            let frames = try await HouseholdMedia.frames(of: out)
            var texts: [String] = []
            for frame in frames {
                guard let text = await PhotoText.read(image: frame) else {
                    message = HouseholdWords.unreadablePhoto
                    return nil
                }
                texts.append(text)
            }
            guard let first = frames.first, await checked(texts, label: "a video") else {
                try? FileManager.default.removeItem(at: out)
                return nil
            }
            return Prepared(preview: first, jpeg: nil, video: out)
        } catch HouseholdMedia.Problem.tooLong(let seconds) {
            message = HouseholdWords.tooLong(seconds)
        } catch HouseholdMedia.Problem.notAVideo {
            message = HouseholdWords.notAVideo
        } catch {
            message = HouseholdWords.couldNotConvert
        }
        try? FileManager.default.removeItem(at: out)
        return nil
    }

    private func checked(_ texts: [String], label: String) async -> Bool {
        do {
            if let refusal = try await HouseholdMedia.refusal(texts: texts, label: label, ownWords: ownWords,
                                                              checker: InventoryModel.checker()) {
                message = refusal
                return false
            }
            return true
        } catch let unavailable as CheckUnavailable {
            message = unavailable.description
        } catch {
            message = HouseholdPagesWords.notSaved
        }
        return false
    }

    /// Keeps what the owner looked at and OK'd; its file's name for the step.
    func keep(_ prepared: Prepared, page name: String) -> String? {
        guard let folder else { return nil }
        defer { if let video = prepared.video { try? FileManager.default.removeItem(at: video) } }
        if let first = HouseholdMedia.wordsFirst(ownWords) {
            message = first
            return nil
        }
        do {
            if let jpeg = prepared.jpeg { return try folder.keepPhoto(jpeg, page: name) }
            if let video = prepared.video { return try folder.keepVideo(video, page: name) }
        } catch {
            message = HouseholdPagesWords.notSaved
        }
        return nil
    }

    func discard(_ prepared: Prepared) {
        if let video = prepared.video { try? FileManager.default.removeItem(at: video) }
    }

    func setAside(photo: String = "", video: String = "") {
        try? folder?.setAside(photo: photo, video: video, stamp: HouseholdPagesFolder.stamp())
    }

    /// The page `name` opened in the editor: as saved, or `draft`, a new page made by New page.
    func open(_ name: String, draft: HouseholdPage? = nil) {
        message = nil
        // a page that can't be read (written by hand) opens nothing: no blank "New page · not saved yet" row (2026-10-26)
        importLooks = []
        guard let page = draft ?? read(name) else { working = nil; return }
        working = Working(name: name, page: page, saved: draft == nil ? page : nil)
    }

    /// Saves the open page; whether it was saved (why not is in `message`).
    @discardableResult
    func saveWorking() async -> Bool {
        // each picked place, manual and thing as the phones' copy names it now (owner, 2026-11-20: followed)
        guard let open = working, let page = open.page.map({ HomePick.followed($0, in: copy) })?.tidied else { return false }
        guard await save(page, as: open.name) else {
            saveRefused = message  // the line at the editor's top is easy to miss, scrolled down a long page
            return false
        }
        guard working?.name == open.name else { return true }
        if working?.page == open.page { working?.page = page }  // the tidied form, unless typed over while checking
        for file in working?.aside ?? [] { setAside(photo: file.photo, video: file.video) }
        working?.saved = page
        working?.aside = []
        working?.added = []
        return true
    }

    /// Puts the open page back as last saved, or drops a new page never saved; photos and videos kept since go aside.
    func discardWorking() {
        guard let open = working else { return }
        importLooks = []
        for file in open.added { setAside(photo: file.photo, video: file.video) }
        message = nil
        working = open.saved.map {
            Working(name: open.name, page: $0, saved: $0)
        }
    }

    /// Quitting with a page's edits not saved asks first, the usual Mac way (the audit, 2026-10-22, finding 3): Save
    /// quits once the page is saved, and stays open with the reason when it can't be.
    func askBeforeQuit() -> NSApplication.TerminateReply {
        guard let open = working, open.unsaved else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = HouseholdPagesWords.saveAsk(open.page?.title ?? "")
        alert.informativeText = HouseholdPagesWords.lostIfNot
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                let saved = await saveWorking()
                if !saved, let why = saveRefused {  // said here: the editor's window may be closed
                    saveRefused = nil
                    let refused = NSAlert()
                    refused.messageText = HouseholdPagesWords.notSavedTitle
                    refused.informativeText = why
                    refused.runModal()
                }
                NSApp.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            discardWorking()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func delete(_ name: String) {
        if working?.name == name { working = nil }
        do {
            try folder?.delete(name, stamp: HouseholdPagesFolder.stamp())
            message = HouseholdPagesWords.deleted
        } catch {
            message = HouseholdPagesWords.notDeleted
        }
        refresh()
    }

    /// Start from the draft (owner, 2026-10-26): the starter-named page, by hand or saved, goes to Backups › Household
    /// pages, and its draft opens.
    func startFromDraft(_ name: String) {
        if working?.name == name { working = nil }
        do {
            try folder?.setAsideForStarter(name, stamp: HouseholdPagesFolder.stamp())
            refresh()
            open(name)
            message = HouseholdPagesWords.draftOpened
        } catch {
            message = HouseholdPagesWords.notDeleted
            refresh()
        }
    }

    /// A draft pack read and checked (Our Home plan, Task 3.2), shown on the import sheet: nothing is kept yet.
    struct PendingDraft: Identifiable {
        let id = UUID()
        let pack: HouseholdPagesFolder.DraftPack
        let name: String  // the page it becomes: the pack's, or the right-clicked page's (Replace with a Draft…)
        let replaces: Bool  // a page of that name is there, and moves to Backups on Import
        let from: String  // "PrepareMe Drafts › shutoffs"
        let photos: [Prepared]  // the pack's pictures, in its order, each read and checked as a picked photo
    }

    /// Reads the pack at `url` and checks it as Save and a picked photo would (its words, then each picture through
    /// smallPhoto, its text read and checked), keeping nothing; nil with the refusal's words in `message`. `target`:
    /// the page Replace with a Draft… was chosen on, in place of the pack's own name.
    func readDraft(_ url: URL, as target: String? = nil) async -> PendingDraft? {
        guard let home = PrepareMeHome.url else { return nil }
        message = nil
        let pack: HouseholdPagesFolder.DraftPack
        do {
            pack = try HouseholdPagesFolder.readDraft(url, home: home)
        } catch {
            message = (error as? HouseholdPagesFolder.DraftProblem)?.words ?? HouseholdPagesWords.notImported
            return nil
        }
        busy = HouseholdPagesWords.checking
        do {
            let refusal = try await HouseholdMedia.refusal(page: pack.page, ownWords: ownWords,
                                                           checker: InventoryModel.checker())
            busy = nil
            if let refusal { message = refusal; return nil }
        } catch {
            busy = nil
            message = (error as? CheckUnavailable)?.description ?? HouseholdPagesWords.notImported
            return nil
        }
        var photos: [Prepared] = []
        for picture in pack.pictures {
            guard let prepared = await preparePhoto(picture) else { return nil }  // its refusal is in `message`
            photos.append(prepared)
        }
        let name = target ?? pack.name
        return PendingDraft(pack: pack, name: name,
                            replaces: listed.contains { $0.name == name && $0.kind != .starter },
                            from: "\(url.deletingLastPathComponent().lastPathComponent) › \(url.lastPathComponent)",
                            photos: photos)
    }

    /// Import: the page of that name, if any, goes to Backups › Household pages (as Start from the draft or Delete),
    /// and the draft opens unsaved, its photos each waiting for the owner's look; Save writes it as any page.
    func importDraft(_ pending: PendingDraft) {
        guard let folder else { return }
        if working?.name == pending.name { working = nil }
        do {
            if pending.replaces {
                if HouseholdPage.starter(pending.name) != nil {
                    try folder.setAsideForStarter(pending.name, stamp: HouseholdPagesFolder.stamp())
                } else {
                    try folder.delete(pending.name, stamp: HouseholdPagesFolder.stamp())
                }
            }
        } catch {
            message = HouseholdPagesWords.notImported
            refresh()
            return
        }
        var page = pending.pack.page
        for n in page.steps.indices { page.steps[n].photo = "" }  // each set once the owner keeps it
        // a starter's name is "Not written yet" in the list behind it, and Don't Save goes back to that
        working = Working(name: pending.name, page: page, saved: HouseholdPage.starter(pending.name))
        importLooks = zip(pending.pack.pictures, pending.photos).map { picture, prepared in
            (pending.pack.page.steps.indices.filter { pending.pack.page.steps[$0].photo == picture.lastPathComponent },
             prepared)
        }
        message = pending.replaces ? HouseholdPagesWords.draftOpened : nil
        refresh()
    }

    /// The guides the daily library holds (packer's household/guide-list.json), for Links to guides.
    func loadGuides() async {
        guard let held = PrepareMeMac.shared.store.record.held[PrepareMeKeptTabs.dailyFile],
              let id = UUID(uuidString: held.entry.id),
              await ZimFileService.shared.getMainPageURL(zimFileID: id) != nil,
              let content = await ZimFileService.shared.getURLContent(zimFileID: id.uuidString,
                                                                      contentPath: GuideList.path),
              let list = try? GuideList(content.data) else { return }
        let topics = await ZimFileService.shared.getURLContent(zimFileID: id.uuidString, contentPath: GuideList.topicsPath)
        guides = (topics.map { list.withTopics($0.data) } ?? list).guides  // no topics file: one list
    }

    func loadItems() {
        copy = InventoryModel.folder.flatMap(PhoneInventory.read(in:))
    }

    /// The names in the hidden "Not in the library yet" line of the daily library's Today page, as a note here.
    func loadMissing() async {
        guard let held = PrepareMeMac.shared.store.record.held[PrepareMeKeptTabs.dailyFile],
              let id = UUID(uuidString: held.entry.id),
              let front = await ZimFileService.shared.getMainPageURL(zimFileID: id),
              let content = await ZimFileService.shared.getURLContent(zimFileID: id.uuidString,
                                                                      contentPath: front.contentPath),
              let page = String(data: content.data, encoding: .utf8) else { missing = []; return }
        missing = MissingPages.names(inPage: page)
    }

    func photoImage(_ file: String) -> NSImage? {
        guard !file.isEmpty, let folder else { return nil }
        return NSImage(contentsOf: folder.daily.appendingPathComponent(file))
    }
}

/// Household pages' words on the Mac (phase C).
enum HouseholdPagesWords {
    static let title = MacSidebar.editHouseholdPages  // the editor's own heading; File › Edit Household Pages opens it
    static let saved = "Saved. The phones get it with the next library build."
    static let notSaved = "PrepareMe couldn't save it; nothing was changed."
    static let notSavedTitle = "The page wasn't saved"
    static let deleted = "Deleted. The page and its photos and videos are in Household Private › Backups › Household pages."
    static let notDeleted = "PrepareMe couldn't delete the page; nothing was changed."
    static let handWritten = "This page was written by hand: PrepareMe doesn't change it. Edit it in a text editor."
    static let checking = "Checking every word…"
    static let readingPhoto = "Reading the photo for the ID check…"
    static let readingVideo = "Making the video ready and reading its frames…"
    static let inLibrary = "In the library"
    static let byHand = "Written by hand · PrepareMe doesn't change it"
    static let eventMode = "Today shows this page in event mode."
    // on Settings › Household since Our Home Task 1.3 (board 23, OK'd as drawn 2026-11-16); the editor's button opens it
    static let ownWordsTitle = "Your words for where you live"
    static let ownWordsButton = "Your Words for Where You Live…"
    static let ownWordsWhy = "Street, town and other words that would say where home is. Photos, videos and Our Home "
        + "pages are checked for them before they're kept."
    static let lookTitle = "Look before it's kept"
    static let missingTitle = "Pages Today looks for that aren't written yet"
    static let startFromDraft = "Start from the draft…"
    static let draftAsk = "Start from the draft?"
    static let draftWhy = "This page moves to Household Private › Backups › Household pages, so nothing is lost, and the "
        + "draft opens here. Fill in its blanks and save."
    static let draftOpened = "The draft is open. Your old page is in Household Private › Backups › Household pages."
    static let newNotSaved = "New page · not saved yet"
    // Import a draft (Our Home plan, Task 3.2; OK'd with phase D's board 22, 2026-11-16)
    static let importDraft = "Import a draft…"
    static let replaceWithDraft = "Replace with a Draft…"
    static let printCard = "Print Card…"  // the page's paper card (Task 4.3; the owner's click, 2026-11-16)
    static let notImported = "PrepareMe couldn't import the draft; nothing was changed."
    static let pickDraft = "Pick a draft's folder, such as one in PrepareMe Drafts."
    static func importAsk(_ title: String) -> String { "Import the draft “\(title)”?" }
    static func importFrom(_ from: String) -> String { "From \(from). Nothing is kept until you press Import." }
    static func importPage(steps: Int, blanks: Int, replaces: Bool) -> String {
        (steps == 1 ? "1 step" : "\(steps) steps")
            + (blanks == 0 ? ", nothing to fill in." : blanks == 1 ? ", 1 blank to fill in." : ", \(blanks) blanks to fill in.")
            + (replaces ? " It replaces your page of the same name, which moves to Backups." : "")
    }
    static func importPhotos(_ count: Int) -> String { count == 1 ? "1 photo" : "\(count) photos" }
    static let importPhotosWhy = "each checked as if you had picked it"
    /// What isn't imported: a PDF is a manual, attached to its item with Add manual…; the rest by name.
    static func notImportedFiles(_ files: [String]) -> String {
        let parts = files.map { $0.lowercased().hasSuffix(".pdf")
            ? "the manual (\($0); attach it to its item in Inventory with Add Manual…)" : $0 }
        return parts.count < 2 ? parts.joined() + "."
            : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1] + "."
    }
    static let lostIfNot = "If you don't save, the changes are lost."
    static func saveAsk(_ title: String) -> String { "Save the changes to “\(title.isEmpty ? "Untitled page" : title)”?" }
}

/// The Household pages row: the list of pages beside the editor (the mockup's middle and right columns).
struct PrepareMeHouseholdPagesView: View {
    @ObservedObject private var model = HouseholdPagesModel.shared
    @State private var selected: String?
    @State private var naming = false
    @State private var deleting: HouseholdPagesFolder.Listed?  // right-click › Delete Page…, waiting for its yes
    @State private var newTitle = ""
    @State private var leaving: (() -> Void)?  // what waits on Save or Don't Save (the audit, finding 3)
    @State private var importing: HouseholdPagesModel.PendingDraft?  // the import sheet's pack (board 22)
    /// Import pressed: done once the sheet has gone, since macOS drops a sheet (the first photo's look) asked for while
    /// another is closing (the check build, 2026-11-16: the looks never showed)
    @State private var imported: HouseholdPagesModel.PendingDraft?
    #if PREPAREME_CHECK
    static var importedOnce = false
    #endif

    var body: some View {
        ListColumnSplit {  // the list column hides (the Apple guidelines plan, phase 7)
            VStack(alignment: .leading, spacing: 0) {
                List(selection: Binding(get: { selected }, set: { picked in leave { selected = picked } })) {
                    if let draft = model.working, draft.saved == nil {  // a new page stays listed until saved or not
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.page?.title ?? "")
                            Text(HouseholdPagesWords.newNotSaved).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                        }
                        .tag(draft.name)
                    }
                    ForEach(model.listed) { page in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.title)
                            Text(subtitle(page)).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                        }
                        .tag(page.name)
                        .contextMenu {  // a page's own commands (the Apple guidelines plan, phase 8)
                            // on every row, so a right-click never opens nothing: a starter not yet written and a page
                            // written by hand have nothing PrepareMe can delete (owner check 65, 2026-11-14)
                            // board 21: above Delete Page… and its line; a page written by hand that isn't a
                            // starter's has nothing PrepareMe can set aside for it
                            // the paper card (Task 4.3), of the page as saved: only a page the Mac wrote has one
                            Button(HouseholdPagesWords.printCard) { leave { model.printCard(page.name) } }
                                .disabled(page.kind != .page)
                            Button(HouseholdPagesWords.replaceWithDraft) { leave { pickDraft(as: page.name) } }
                                .disabled(page.kind == .handWritten && !HouseholdPage.starterNames.contains(page.name))
                            Divider()
                            PMMenuDelete("Delete Page…") { deleting = page }.disabled(page.kind != .page)
                        }
                    }
                    if !model.missing.isEmpty {
                        Section(pmTitle: HouseholdPagesWords.missingTitle) {
                            ForEach(model.missing, id: \.self) { name in
                                // a household page's name opens its draft above; any other is a note only (2026-10-26)
                                if let starter = HouseholdPagesFolder.starter(forMissing: name) {
                                    Text(name).foregroundStyle(PrepareMeColors.text2).tag(starter)
                                } else {
                                    Text(name).foregroundStyle(PrepareMeColors.text2).selectionDisabled()
                                }
                            }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("New page") { leave { newTitle = ""; naming = true } }
                        Button(HouseholdPagesWords.importDraft) { leave { pickDraft() } }  // board 18
                    }
                    Button(HouseholdPagesWords.ownWordsButton) {  // Settings › Household (board 23)
                        model.showOwnWords = true
                        NotificationCenter.default.post(name: .prepareMeSettings, object: MacStatus.Tab.household)
                    }
                }
                .padding(12)
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 360)
        } content: {
            Group {
                if let selected {
                    HouseholdPageEditor(name: selected) { self.selected = model.listed.first?.name }.id(selected)
                } else {
                    Text("Pick a page, or make a new one.").foregroundStyle(PrepareMeColors.text2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            model.refresh()
            #if PREPAREME_CHECK
            if let page = ProcessInfo.processInfo.environment["PREPAREME_CHECK_PAGE"] { selected = page }  // a check's page
            #endif
            if selected == nil { selected = model.working?.name ?? model.listed.first?.name }  // back where it was
        }
        #if PREPAREME_CHECK
        // The check build only: PREPAREME_CHECK_PART=card writes PREPAREME_CHECK_PAGE's paper card to home-card.pdf in
        // the check home, as Print Card… would hand it to the print dialog (a right-click can't be driven in a check).
        .task {
            let env = ProcessInfo.processInfo.environment
            guard env["PREPAREME_CHECK_PART"] == "card", let name = env["PREPAREME_CHECK_PAGE"],
                  let home = env["PREPAREME_CHECK_HOME"], let page = model.read(name) else { return }
            let card = HomeCard(page, name: name, printed: Date())
            try? HomeCardPrint.pdf(card, photos: model.folder?.daily)
                .write(to: URL(fileURLWithPath: home).appendingPathComponent("home-card.pdf"))
        }
        // The check build only: PREPAREME_CHECK_PICK naming a folder is a draft pack, taken through Import a draft…'s
        // steps (the open panel can't be driven in a check); PREPAREME_CHECK_PART=import then presses Import.
        .task {
            var folder: ObjCBool = false
            guard let path = ProcessInfo.processInfo.environment["PREPAREME_CHECK_PICK"], !Self.importedOnce,
                  FileManager.default.fileExists(atPath: path, isDirectory: &folder), folder.boolValue else { return }
            Self.importedOnce = true
            try? await Task.sleep(for: .seconds(2))
            if model.ownWords.isEmpty { model.ownWords = ["SAMPLE made up words"] }  // the check build's own defaults
            importing = await model.readDraft(URL(fileURLWithPath: path, isDirectory: true))
            guard ProcessInfo.processInfo.environment["PREPAREME_CHECK_PART"]?.hasPrefix("import") == true,
                  let pending = importing
            else { return }
            try? await Task.sleep(for: .seconds(3))
            imported = pending  // Import's own path
            importing = nil
        }
        #endif
        .task {
            model.loadItems()
            await model.loadGuides()
            await model.loadMissing()
        }
        .sheet(isPresented: $naming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New page").font(.pmTitle)
                TextField("Title", text: $newTitle, prompt: Text("What the page is for, such as Lighting the wood stove"))
                HStack {
                    Spacer()
                    Button("Cancel") { naming = false }.keyboardShortcut(.cancelAction)
                    Button("Make it") {
                        // a random name, never the title's words (the review): the name is the page's path
                        let taken = (model.folder?.takenNames() ?? []).union(model.working.map { [$0.name] } ?? [])
                        let name = HouseholdPage.newName(taken: taken)
                        model.open(name, draft: HouseholdPage(title: newTitle, steps: [.init(words: "")]))
                        naming = false
                        model.refresh()
                        selected = name
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
        .sheet(item: $importing, onDismiss: {
            guard let pending = imported else { return }
            imported = nil
            model.importDraft(pending)
            selected = pending.name
        }) { pending in
            DraftSheet(pending: pending) { go in
                if go { imported = pending }
                importing = nil
            }
        }
        .alert(HouseholdPagesWords.saveAsk(model.working?.page?.title ?? ""),
               isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } })) {
            Button("Save") {
                let then = leaving
                Task { if await model.saveWorking() { then?() } }  // refused: the editor says why, and stays
            }
            Button("Don't Save", role: .destructive) {
                let then = leaving
                model.discardWorking()
                then?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(HouseholdPagesWords.lostIfNot)
        }
        .confirmationDialog("Delete \(deleting?.title ?? "")?", isPresented: Binding(get: { deleting != nil },
                                                                                    set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { page in
            Button("Delete", role: .destructive) {
                model.delete(page.name)
                if selected == page.name { selected = model.listed.first?.name }
            }
        } message: { _ in
            Text("The page and its photos and videos move to Household Private › Backups › Household pages.")
        }
    }

    /// Import a draft… (or Replace with a Draft… on page `target`): the open panel picks a pack's folder, then it is
    /// read and checked, and the import sheet shows what it holds.
    func pickDraft(as target: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = HouseholdPagesWords.pickDraft
        if let drafts = PrepareMeHome.url?.appendingPathComponent("PrepareMe Drafts", isDirectory: true),
           FileManager.default.fileExists(atPath: drafts.path) { panel.directoryURL = drafts }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { importing = await model.readDraft(url, as: target) }
    }

    /// Another page or New page: at once, or once the open page's edits are saved or let go.
    func leave(then: @escaping () -> Void) {
        if model.working?.unsaved == true { leaving = then } else { then() }
    }

    func subtitle(_ page: HouseholdPagesFolder.Listed) -> String {
        switch page.kind {
        case .page where page.blanksLeft > 0: HomeEditorWords.leftToFill(page.blanksLeft) ?? ""
        case .page where !page.walked.isEmpty: HomeEditorWords.walked(page.walked)
        case .page: HouseholdPagesWords.inLibrary
        case .handWritten: HouseholdPagesWords.byHand
        case .starter: HomeEditorWords.notWritten  // board 18's page list
        }
    }
}

/// What a draft pack holds, before anything is kept (board 22): the page, its photos, and what isn't imported.
struct DraftSheet: View {
    let pending: HouseholdPagesModel.PendingDraft
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HouseholdPagesWords.importAsk(pending.pack.page.title)).font(.pmTitle)
            Text(HouseholdPagesWords.importFrom(pending.from)).foregroundStyle(PrepareMeColors.text2)
            row("📄", "The page", ": " + HouseholdPagesWords.importPage(steps: pending.pack.page.steps.count,
                                                                       blanks: pending.pack.page.blanksLeft,
                                                                       replaces: pending.replaces))
            if !pending.pack.pictures.isEmpty {
                row("🖼️", HouseholdPagesWords.importPhotos(pending.pack.pictures.count),
                    ", \(HouseholdPagesWords.importPhotosWhy): "
                        + pending.pack.pictures.map(\.lastPathComponent).joined(separator: ", "))
            }
            if !pending.pack.ignored.isEmpty {
                row("📘", "Not imported", ": " + HouseholdPagesWords.notImportedFiles(pending.pack.ignored))
            }
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Import") { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    func row(_ icon: String, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(icon).accessibilityHidden(true)
            (Text(lead).bold() + Text(rest)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The owner's words for where the household lives, one a line: Settings › Household's section (Our Home Task 1.3,
/// board 23; a sheet from the editor until then). Saved as typed, as the form's other rows are.
struct OwnWordsSection: View {
    @ObservedObject private var model = HouseholdPagesModel.shared
    @State private var text = ""

    var body: some View {
        Section {
            TextEditor(text: $text).font(.pmBody).frame(minHeight: 80).pmBox()  // the typed box's one outline
                .onChange(of: text) { _, now in model.ownWords = now.split(separator: "\n").map(String.init) }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(HouseholdPagesWords.ownWordsTitle).font(.pmHeadline).foregroundStyle(PrepareMeColors.ink)
                Text(HouseholdPagesWords.ownWordsWhy).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("One a line.").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
        }
        .id(Self.id)
        .onAppear { text = model.ownWords.joined(separator: "\n") }
    }

    static let id = "ownWords"
}

/// One page's editor: its title, When to use this, numbered steps (each its words, name, photo or video, caution),
/// links to guides and search words; Save checks every word first.
struct HouseholdPageEditor: View {
    let name: String
    /// Cancel on a new page never saved: the page is gone, so the list picks another.
    var discarded: () -> Void = {}
    #if PREPAREME_CHECK
    static var pickedOnce = false
    static var draftedOnce = false
    #endif
    @ObservedObject private var model = HouseholdPagesModel.shared
    @State private var looking: (step: Int, prepared: HouseholdPagesModel.Prepared)?
    @State private var confirmingDelete = false
    @State private var confirmingDraft = false
    @State private var lastBlank: HouseholdPage.Blank?  // the bar's Go to the next went here last (board 7)
    @State private var scrollTo: (id: String, tick: Int) = ("", 0)
    @State private var newWord = ""  // a search word being typed, a tag on Return (board 8)
    @AppStorage("prepareme.household.preview") private var previewing = true
    @State private var detailsOpen = false
    @State private var openSteps: Set<Int> = [0]
    /// A step's rows added and still empty, by step, so typing never takes a row away (boards 1 and 2)
    @State private var showing: [Int: Set<HouseholdPage.Part>] = [:]
    /// A picked place or manual being picked again (Pick again), by step
    @State private var picking: [Int: Set<HouseholdPage.Part>] = [:]
    @State private var seed = ""  // the check build's words in a picker's box

    // the model's working copy of this page (HouseholdPagesModel.Working), read and changed in place
    private var open: HouseholdPagesModel.Working? {
        get { model.working?.name == name ? model.working : nil }
        nonmutating set { if model.working?.name == name, let newValue { model.working = newValue } }
    }
    private var page: HouseholdPage? {
        get { open?.page }
        nonmutating set { open?.page = newValue }
    }
    private var saved: HouseholdPage? { open?.saved }
    private var aside: [(photo: String, video: String)] {
        get { open?.aside ?? [] }
        nonmutating set { open?.aside = newValue }
    }
    private var added: [(photo: String, video: String)] {
        get { open?.added ?? [] }
        nonmutating set { open?.added = newValue }
    }

    var body: some View {
        HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
            if let page {
                editor(page)
            } else {
                VStack(spacing: 12) {
                    Text(model.message ?? HouseholdPagesWords.handWritten).foregroundStyle(PrepareMeColors.text2)
                    if HouseholdPage.starterNames.contains(name) {
                        Button(HouseholdPagesWords.startFromDraft) { confirmingDraft = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 440, maxWidth: .infinity, alignment: .leading)
            if previewing, let page {  // board 18's right column, drawn as the packer draws it (HomePage)
                Divider()
                HomePreview(page: page, guideTitles: Dictionary(model.guides.map { ($0.page, $0.title) },
                                                                 uniquingKeysWith: { a, _ in a }),
                            base: model.folder?.daily, step: openSteps.count == 1 ? openSteps.first : nil)
                    .frame(width: 360)
            }
        }
        .toolbar { if page != nil { tools } }
        #if PREPAREME_CHECK
        // The check build only: a made-up photo or video named by PREPAREME_CHECK_PICK goes through the same steps as
        // one picked in the open panel, which runs outside the app and can't be driven in a check (the owner's first
        // video crashed the look window, 2026-10-19). Step 1, once.
        .task {
            var folder: ObjCBool = false  // a folder is a draft pack: the list takes it (Import a draft…)
            guard let path = ProcessInfo.processInfo.environment["PREPAREME_CHECK_PICK"], !Self.pickedOnce,
                  !(FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue) else { return }
            // the editor is made again as the list picks its first row: only the one still on screen picks
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !Self.pickedOnce else { return }
            Self.pickedOnce = true
            let url = URL(fileURLWithPath: path)
            let video = ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
            let prepared = video ? await model.prepareVideo(url) : await model.preparePhoto(url)
            if let prepared { looking = (0, prepared) }
        }
        .task {  // PREPAREME_CHECK_PART: one part of the editor open for the check build's pictures, or Save
            try? await Task.sleep(for: .seconds(2))  // once the page is open
            if model.guides.isEmpty { await model.loadGuides() }  // the daily library may be held only now
            switch ProcessInfo.processInfo.environment["PREPAREME_CHECK_PART"] {
            case "words": openSteps = []  // every step folded: Links to guides and Search words' tags in view
            case "next-blank": goToNextBlank()  // the bar's Go to the next, once
            case "next-blank-2": goToNextBlank(); try? await Task.sleep(for: .seconds(1)); goToNextBlank()
            case "details": detailsOpen = true; openSteps = []
            case "step2": openSteps = [1]
            case "steps-3-4": openSteps = [2, 3]  // a made-up page's numbers, picked place and manual
            case "import-step3": openSteps = [2]  // the imported draft's step 3, its kept photo in the preview
            // the step card (the editor plan, Task 5): step 1 with every part, each picker open, a stale place
            case "parts": checkParts(); openSteps = [0]
            case "place-picker":
                seed = String(model.copy?.places.first?.name.prefix(3) ?? "")
                showing[0] = [.place]; page?.steps[0].place = nil; openSteps = [0]
            case "guide-picker": showing[0] = [.guide]; page?.steps[0].guide = ""; openSteps = [0]
            case "guide-search":
                seed = String(model.guides.first?.title.split(separator: " ").last ?? "")
                showing[0] = [.guide]; page?.steps[0].guide = ""; openSteps = [0]
            case "manual-picker": showing[0] = [.manual]; page?.steps[0].manual = nil; openSteps = [0]
            case "stale": page?.steps[0].place = .init(id: 999_999, words: "SAMPLE Gone shelf"); openSteps = [0]
            case "save":  // a made-up change saved through Save's own path (the checks, then the file)
                if model.ownWords.isEmpty { model.ownWords = ["SAMPLE made up words"] }  // the check build's own defaults
                page?.walked = Self.today()
                await model.saveWorking()
            default: break
            }
        }
        .task {  // PREPAREME_CHECK_DRAFT=<name>: Start from the draft's button, pressed once on that page
            guard ProcessInfo.processInfo.environment["PREPAREME_CHECK_DRAFT"] == name, !Self.draftedOnce else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !Self.draftedOnce else { return }
            Self.draftedOnce = true
            model.startFromDraft(name)
        }
        #endif
        .onAppear {
            if model.working?.name != name { model.open(name) }  // the same page again keeps its edits
        }
        .sheet(item: Binding(get: { currentLook }, set: { if $0 == nil, let open = looking { model.discard(open.prepared); looking = nil } })) { look in
            LookSheet(prepared: look.prepared) { keep in finish(look, keep: keep) }
        }
        .alert(HouseholdPagesWords.notSavedTitle, isPresented: Binding(get: { model.saveRefused != nil },
                                                                      set: { if !$0 { model.saveRefused = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.saveRefused ?? "")
        }
        .confirmationDialog(HouseholdPagesWords.draftAsk, isPresented: $confirmingDraft) {
            Button("Start from the Draft") { model.startFromDraft(name) }
        } message: {
            Text(HouseholdPagesWords.draftWhy)
        }
        .confirmationDialog("Delete \(page?.title ?? name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.delete(name) }
        } message: {
            Text("The page and its photos and videos move to Household Private › Backups › Household pages.")
        }
    }

    struct Look: Identifiable {
        let steps: [Int]
        let prepared: HouseholdPagesModel.Prepared
        var imported = false  // an imported draft's photo (Task 3.2), from the model's queue
        var id: UUID { prepared.id }
    }

    /// The look on screen: a photo or video picked here, else an imported draft's next photo.
    private var currentLook: Look? {
        if let looking { return Look(steps: [looking.step], prepared: looking.prepared) }
        guard open != nil, let next = model.importLooks.first else { return nil }
        return Look(steps: next.steps, prepared: next.prepared, imported: true)
    }

    /// Keep it: kept, and named on its steps; else let go. A draft's photo kept for none of its steps stays off.
    func finish(_ look: Look, keep: Bool) {
        // the steps are still there (steps are locked while a photo or video is made ready; the review)
        if keep, !look.steps.isEmpty, look.steps.allSatisfy({ page?.steps.indices.contains($0) == true }),
           let file = model.keep(look.prepared, page: name) {
            for n in look.steps {
                if look.prepared.video != nil { page?.steps[n].video = file } else { page?.steps[n].photo = file }
            }
            added.append(look.prepared.video != nil ? ("", file) : (file, ""))
        } else {
            model.discard(look.prepared)
        }
        if look.imported { if !model.importLooks.isEmpty { model.importLooks.removeFirst() } } else { looking = nil }
    }

    @ViewBuilder func editor(_ current: HouseholdPage) -> some View {
        Text(current.title.isEmpty ? "Untitled page" : current.title).font(.pmTitle)
        if let message = model.message {
            Text(message).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
        }
        if let busy = model.busy { ProgressView(busy).controlSize(.small) }
        if let left = HomeEditorWords.leftToFill(current.blanksLeft) {  // board 7's bar, only with blanks left
            HStack {
                Text(left).font(.pmBody.bold()).foregroundStyle(PrepareMeColors.caution)
                Spacer()
                Button(HomeEditorWords.goToNext) { goToNextBlank() }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: PrepareMeCorners.panel).fill(PrepareMeColors.accentBg))
            .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.panel).stroke(PrepareMeColors.accent))
        }
        ScrollViewReader { proxy in
            form(current)
                .onChange(of: scrollTo.tick) { _, _ in
                    withAnimation { proxy.scrollTo(scrollTo.id, anchor: .center) }  // a fold's own motion only
                }
        }
        HStack {
            Button("Delete page…") { confirmingDelete = true }
                .disabled(model.listed.first { $0.name == name }?.kind != .page)
            if HouseholdPage.starterNames.contains(name), model.listed.first(where: { $0.name == name })?.kind == .page {
                Button(HouseholdPagesWords.startFromDraft) { confirmingDraft = true }  // a saved page back to the draft
                    .disabled(model.busy != nil)
            }
            Spacer()
            // puts back the page as last saved; click only, so Escape in a box never throws away a page's edits
            Button("Cancel") { cancel() }
                .disabled(model.busy != nil || (saved != nil && page == saved))
        }
        .focusedSceneValue(\.macSave, MacSave(enabled: model.busy == nil && page != saved) {
            Task { await model.saveWorking() }
        })
    }

    /// Board 18's toolbar: Preview and Save (⌘S is File › Save's, look 3, change 18); Fill In Blanks' switch went
    /// with the editor's fresh look (board 7).
    @ToolbarContentBuilder var tools: some ToolbarContent {
        ToolbarItemGroup {
            Button { previewing.toggle() } label: {  // a toolbar button that shows or hides the column, not a switch
                Label(HomeEditorWords.preview, systemImage: previewing ? "iphone" : "iphone.slash")
            }
            .help(HomeEditorWords.previewTitle)
            .accessibilityValue(previewing ? "Shown" : "Hidden")
            Button("Save") { Task { await model.saveWorking() } }
                .disabled(model.busy != nil || page == saved)
        }
    }

    @ViewBuilder func form(_ current: HouseholdPage) -> some View {
        PMForm {
            Section {
                DisclosureGroup(HomeEditorWords.pageDetails, isExpanded: $detailsOpen) {
                    // a label over each left-aligned box, as the step rows (a grouped form's labeled field right-aligns)
                    VStack(alignment: .leading, spacing: 8) {
                        labeled("Title") { TextField("Title", text: binding(\.title)) }
                        labeled("Use this when") { TextField("Use this when", text: binding(\.when), axis: .vertical) }
                        blankFields(.when, current)
                        labeled(HomeEditorWords.dangerFirst) {
                            TextField(HomeEditorWords.dangerFirst, text: binding(\.danger), axis: .vertical)
                        }
                        hint(HomeEditorWords.dangerHint)
                        labeled(HomeEditorWords.need) { needTags(current) }
                        labeled(HomeEditorWords.next) { TextField(HomeEditorWords.next, text: binding(\.next), axis: .vertical) }
                        if !current.sources.isEmpty {
                            labeled(HomeEditorWords.sources) { Text(current.sources) }  // read only: the draft's
                        }
                        labeled(HomeEditorWords.walkedLabel) {
                            HStack {
                                Text(current.walked.isEmpty ? HomeEditorWords.notYet
                                     : HomeEditorWords.walked(current.walked).replacingOccurrences(of: "Walked through ", with: ""))
                                Button(HomeEditorWords.today) { page?.walked = Self.today() }
                            }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .padding(.top, 6)
                }
            }
            if HouseholdPage.starterNames.contains(name) {
                Text(HouseholdPagesWords.eventMode).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            Section(pmTitle: "Steps") {
                ForEach(Array(current.steps.indices), id: \.self) { n in
                    step(n, current, count: current.steps.count)
                }
                Button("Add step") { page?.steps.append(.init(words: "")) }.disabled(model.busy != nil)
            }
            Section(pmTitle: "Links to guides") {
                ForEach(current.guides, id: \.self) { id in
                    HStack {
                        Text(model.guides.first { $0.id == id }?.title ?? id)
                        Spacer()
                        Button("Remove") { page?.guides.removeAll { $0 == id } }
                    }
                }
                HomeGuidePicker(guides: model.guides.filter { !current.guides.contains($0.id) },
                                pick: { page?.guides.append($0.id) })
                    .disabled(model.guides.isEmpty)
            }
            labeled("Search words") {
                VStack(alignment: .leading, spacing: 6) {
                    if !current.keywords.isEmpty {
                        FlowRow(spacing: 6) {
                            ForEach(current.keywords, id: \.self) { word in
                                HomeTag(words: word) { page?.keywords.removeAll { $0 == word } }
                            }
                        }
                    }
                    TextField("Search words", text: $newWord, prompt: Text(HomeEditorWords.addOne))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .onSubmit { addWords() }
                }
            }
        }
        .formStyle(.grouped)
        Text(HouseholdWords.lookFirst).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    func labeled(_ label: String, @ViewBuilder _ box: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            box()
        }
    }

    func hint(_ words: String) -> some View {
        Text(words).font(.pmNote).foregroundStyle(PrepareMeColors.text2).fixedSize(horizontal: false, vertical: true)
    }

    /// Board 7: each blank an amber row where it sits ("Fill in: {question}"), its box filling the blank in place;
    /// amber while it's empty. Its id is where it is, so typing an answer never remakes the row and takes the box.
    @ViewBuilder func blankFields(_ field: HouseholdPage.Blank.Field, _ current: HouseholdPage) -> some View {
        ForEach(current.blanks.filter { $0.field == field }, id: \.index) { blank in
            let open = blank.answer == nil
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("✏️").accessibilityHidden(true)
                    Text(HomeEditorWords.fillInLabel(blank.question)).font(.pmBody.bold())
                        .foregroundStyle(open ? PrepareMeColors.caution : PrepareMeColors.ink)
                }
                TextField(blank.question, text: Binding(get: { blank.answer ?? "" }, set: { page?.fill(blank, with: $0) }))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                Text(HomeEditorWords.answerReplaces(blank.question)).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: PrepareMeCorners.control)
                .fill(open ? PrepareMeColors.accentBg : PrepareMeColors.tile))
            .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.control)
                .stroke(open ? PrepareMeColors.accent : PrepareMeColors.line))
            .id(Self.rowID(blank))
        }
    }

    static func rowID(_ blank: HouseholdPage.Blank) -> String {
        switch blank.field {
        case .when: "blank-when-\(blank.index)"
        case .words(let i): "blank-words-\(i)-\(blank.index)"
        case .caution(let i): "blank-caution-\(i)-\(blank.index)"
        }
    }

    /// Go to the next: opens Page details or the step holding the next blank left, and brings its row into view.
    func goToNextBlank() {
        guard let next = page?.nextBlank(after: lastBlank) else { return }
        lastBlank = next
        switch next.field {
        case .when: detailsOpen = true
        case .words(let i), .caution(let i): openSteps.insert(i)
        }
        let id = Self.rowID(next)
        DispatchQueue.main.async { scrollTo = (id, scrollTo.tick + 1) }  // once the fold has opened
    }

    /// Board 8: What you need's tags, an old page's words (removable only) then its things, over the item picker,
    /// which goes at 8 things.
    @ViewBuilder func needTags(_ current: HouseholdPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let old = current.need.filter { !$0.isEmpty }
            if !old.isEmpty || !current.things.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(old, id: \.self) { word in HomeTag(words: word) { page?.need.removeAll { $0 == word } } }
                    ForEach(Array(current.things.enumerated()), id: \.offset) { i, thing in
                        HomeTag(words: thingWords(thing)) { if page?.things.indices.contains(i) == true { page?.things.remove(at: i) } }
                    }
                }
            }
            if current.things.count < HouseholdPage.maxThings {
                HomeThingPicker(copy: model.copy) { page?.things.append($0) }
            }
        }
    }

    /// A picked thing as its name and where the phones' copy keeps it now; a typed one, its words.
    func thingWords(_ thing: HouseholdPage.Picked) -> String {
        guard let id = thing.id, let copy = model.copy, let item = HomeSlots.item(id: id, in: copy) else { return thing.words }
        return item.place.isEmpty ? item.name : HomeEditorWords.row(item.name, item.place)
    }

    /// Return in Search words: each word typed (a ";" splits them) becomes a tag, once.
    func addWords() {
        for word in newWord.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !word.isEmpty {
            if page?.keywords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) == false {
                page?.keywords.append(word)
            }
        }
        newWord = ""
    }

    /// A step's one line when folded: its kind and what it carries (board 18's step rows).
    func summary(_ step: HouseholdPage.Step) -> String {
        var parts: [String] = []
        if step.kind == .yesNo { parts.append("Yes or No: Yes to \(step.yes ?? 0), No to \(step.no ?? 0)") }
        if step.kind == .checklist { parts.append("Checklist") }
        parts += HomeEditorWords.partNames.filter { step.has($0.0) }.map(\.1)
        let left = HouseholdPage.blanks(step.words).filter { $0.answer == nil }.count
            + HouseholdPage.blanks(step.caution).filter { $0.answer == nil }.count
        if let line = HomeEditorWords.leftToFill(left) { parts.append(line) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder func step(_ n: Int, _ current: HouseholdPage, count: Int) -> some View {
        let step = current.steps[n]
        DisclosureGroup(isExpanded: Binding(get: { openSteps.contains(n) },
                                            set: { if $0 { openSteps.insert(n) } else { openSteps.remove(n) } })) {
            stepRows(n, step, current, count: count)
        } label: {
            HStack(spacing: 10) {
                // look 3's step cards (plan Task 6.2): the number in the rounded typeface on the teal, the tint so red
                // night's ink reaches it
                Text("\(n + 1)").font(.pmStepNumber).frame(width: 28, height: 28)
                    .background(Circle().fill(.tint)).foregroundStyle(PrepareMeColors.onTeal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.name.isEmpty ? (step.words.isEmpty ? "Step \(n + 1)" : step.words) : step.name).lineLimit(1)
                    let line = summary(step)
                    if !line.isEmpty { Text(line).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    #if PREPAREME_CHECK
    /// PREPAREME_CHECK_PART=parts: step 1 with every part, from the check build's made-up copy and guides.
    func checkParts() {
        guard page?.steps.isEmpty == false else { return }
        page?.steps[0].danger = "SAMPLE never touch it while standing in water."
        page?.steps[0].caution = "SAMPLE the handle may be stiff."
        if let copy = model.copy, let place = copy.places.first(where: { $0.keptIn != nil }) ?? copy.places.first {
            page?.steps[0].place = .init(id: place.id, words: copy.path(place.id))
        }
        page?.steps[0].call = .init(number: "(202) 555-0123", label: "SAMPLE water company")
        if let guide = model.guides.first { page?.steps[0].guide = guide.id }
        if let copy = model.copy, let item = HomePick.items("", in: copy, withManual: true).first {
            page?.steps[0].manual = .init(id: item.id, words: item.name)
        }
    }
    #endif

    /// Whether step n shows `part`'s row: set on the page, or added and still empty.
    func shows(_ n: Int, _ part: HouseholdPage.Part) -> Bool {
        stepAt(n)?.has(part) == true || showing[n]?.contains(part) == true
    }

    /// The × on a part's row: that part alone, a photo or video moved aside once the page is saved.
    func removePart(_ n: Int, _ part: HouseholdPage.Part) {
        guard let step = stepAt(n) else { return }
        if part == .photo { aside.append((step.photo, "")) }
        if part == .video { aside.append(("", step.video)) }
        page?.steps[n].remove(part)
        showing[n]?.remove(part)
        picking[n]?.remove(part)
    }

    func addPart(_ n: Int, _ part: HouseholdPage.Part) {
        switch part {
        case .photo: pick(n, video: false)
        case .video: pick(n, video: true)
        default: showing[n, default: []].insert(part)
        }
    }

    /// make it a Caution or make it a Danger: the words, and an empty row just added, move to the other kind.
    func switchWarning(_ n: Int, _ kind: HouseholdPage.Part) {
        let other: HouseholdPage.Part = kind == .danger ? .caution : .danger
        page?.steps[n].switchWarning(kind)
        if showing[n]?.remove(kind) != nil { showing[n, default: []].insert(other) }
    }

    func canSwitch(_ n: Int, _ step: HouseholdPage.Step, _ kind: HouseholdPage.Part) -> Bool {
        step.canSwitch(kind) && showing[n]?.contains(kind == .danger ? .caution : .danger) != true
    }

    /// A part's words: typing keeps its row, even emptied.
    func partBinding(_ n: Int, _ part: HouseholdPage.Part, _ key: WritableKeyPath<HouseholdPage.Step, String>) -> Binding<String> {
        Binding(get: { stepAt(n)?[keyPath: key] ?? "" }, set: {
            guard page?.steps.indices.contains(n) == true else { return }
            showing[n, default: []].insert(part)
            page?.steps[n][keyPath: key] = $0
        })
    }

    /// A picked place or item the phones' copy no longer holds under that name.
    func stale(_ picked: HouseholdPage.Picked, place: Bool) -> Bool {
        model.copy.map { HomePick.stale(picked, place: place, in: $0) } ?? false
    }

    /// Boards 1 and 2: the step's three labeled boxes, a row for each part it carries, and Add to this step.
    @ViewBuilder func stepRows(_ n: Int, _ step: HouseholdPage.Step, _ current: HouseholdPage, count: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                labeled(HomeEditorWords.whatToDo) {
                    TextField("Step \(n + 1): what to do", text: stepBinding(n, \.words),
                              prompt: Text(step.kind == .yesNo ? HomeEditorWords.question : "What to do"), axis: .vertical)
                }
                blankFields(.words(n), current)
                labeled(HomeEditorWords.shortName) {
                    TextField("Step \(n + 1): short name", text: stepBinding(n, \.name),
                              prompt: Text("Short name, such as Water main"))
                }
                labeled(HomeEditorWords.stepIs) {
                    Picker(HomeEditorWords.stepIs, selection: Binding(get: { step.kind }, set: { page?.setKind($0, step: n) })) {
                        ForEach(HomeEditorWords.kinds, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if step.kind == .yesNo {
                    goesTo(HomeEditorWords.yesGoesTo, n, current, \.yes)
                    goesTo(HomeEditorWords.noGoesTo, n, current, \.no)
                }
                if step.kind == .checklist {
                    TextEditor(text: Binding(get: { (stepAt(n)?.ticks ?? []).joined(separator: "\n") },
                                             set: { page?.steps[n].ticks = $0.components(separatedBy: "\n") }))
                        .font(.pmBody).frame(minHeight: 60).pmBox()
                        .accessibilityLabel("Step \(n + 1): \(HomeEditorWords.ticks)")
                    hint(HomeEditorWords.ticksHint)
                }
                partRows(n, step, current)
                let offers = step.offered(showing: showing[n] ?? [])
                if !step.wanted.isEmpty, step.photo.isEmpty {
                    Text(HomeEditorWords.photoWanted).font(.pmNote.bold())
                    hint(step.wanted)
                }
                if !offers.isEmpty {
                    labeled(HomeEditorWords.addToStep) {
                        FlowRow(spacing: 6) {
                            ForEach(offers, id: \.self) { part in
                                Button("+ \(HomeEditorWords.adds(part))") { addPart(n, part) }
                                    .pmAction(fullWidth: false, compact: true)
                            }
                        }
                    }
                }
                if !step.checked.isEmpty {
                    hint(HouseholdPage.checkedHash(step.words) == step.checked ? HomeEditorWords.checked
                         : HomePage.word("STEP_CHANGED"))
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .disabled(model.busy != nil)  // no step changes while a photo or video is made ready (the review)
            VStack(spacing: 4) {
                Button { move(n, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(n == 0)
                    .accessibilityLabel("Move step \(n + 1) up")
                Button { move(n, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(n == count - 1)
                    .accessibilityLabel("Move step \(n + 1) down")
                Button { remove(n) } label: { Image(systemName: "trash") }.disabled(count == 1)
                    .accessibilityLabel("Remove step \(n + 1)")
            }
            .disabled(model.busy != nil)
        }
    }

    /// Each part the step carries or was just given, one labeled row with its × (board 2), in the boards' order.
    @ViewBuilder func partRows(_ n: Int, _ step: HouseholdPage.Step, _ current: HouseholdPage) -> some View {
        if shows(n, .danger) {
            HomePartRow(mark: "⚠️", title: HomeEditorWords.danger, titleColor: PrepareMeColors.red,
                        detail: HomeEditorWords.danger, tone: .danger,
                        action: canSwitch(n, step, .danger) ? (HomeEditorWords.makeCaution, { switchWarning(n, .danger) }) : nil,
                        remove: { removePart(n, .danger) }) {
                TextField("Step \(n + 1): danger", text: partBinding(n, .danger, \.danger),
                          prompt: Text("Danger for this step, if any"), axis: .vertical)
            }
        }
        if shows(n, .caution) {
            HomePartRow(mark: "🟠", title: HomeEditorWords.caution, titleColor: PrepareMeColors.caution,
                        detail: HomeEditorWords.caution, tone: .caution,
                        action: canSwitch(n, step, .caution) ? (HomeEditorWords.makeDanger, { switchWarning(n, .caution) }) : nil,
                        remove: { removePart(n, .caution) }) {
                TextField("Step \(n + 1): caution", text: partBinding(n, .caution, \.caution),
                          prompt: Text("A caution for this step, if any"), axis: .vertical)
                blankFields(.caution(n), current)
            }
        }
        if shows(n, .place) {
            if let place = step.place, picking[n]?.contains(.place) != true {
                let old = stale(place, place: true)
                HomePartRow(mark: "📍", title: HomePick.current(place, place: true, in: model.copy).words,
                            detail: old ? HomeEditorWords.stale
                                : HomeEditorWords.row(HomeEditorWords.place, place.id == nil ? "" : HomeEditorWords.fromInventory),
                            tone: old ? .caution : .plain,
                            button: old ? (HomeEditorWords.pickAgain, { picking[n, default: []].insert(.place) }) : nil,
                            remove: { removePart(n, .place) })
            } else {
                HomePartRow(mark: "📍", title: "", detail: "", remove: { removePart(n, .place) }) {
                    HomePlacePicker(copy: model.copy, pick: { picked in
                        page?.steps[n].place = picked
                        picking[n]?.remove(.place)
                    }, query: seed)
                }
            }
        }
        if shows(n, .call) {
            HomePartRow(mark: "📞", title: "", detail: HomeEditorWords.call, remove: { removePart(n, .call) }) {
                HomeCallBoxes(number: callBinding(n, \.number), label: callBinding(n, \.label), step: n)
            }
        }
        if shows(n, .guide) {
            if !step.guide.isEmpty {
                HomePartRow(mark: "📘", title: model.guides.first { $0.id == step.guide }?.title ?? step.guide,
                            detail: HomeEditorWords.guide, remove: { removePart(n, .guide) })
            } else {
                HomePartRow(mark: "📘", title: "", detail: "", remove: { removePart(n, .guide) }) {
                    HomeGuidePicker(guides: model.guides, pick: { page?.steps[n].guide = $0.id }, query: seed)
                }
            }
        }
        if shows(n, .manual) {
            if let manual = step.manual, picking[n]?.contains(.manual) != true {
                let old = stale(manual, place: false)
                HomePartRow(mark: "📖", title: HomeSlots.readManual,
                            detail: old ? HomeEditorWords.stale
                                : HomeEditorWords.row(HomeEditorWords.manual, HomePick.current(manual, place: false, in: model.copy).words),
                            tone: old ? .caution : .plain,
                            button: old ? (HomeEditorWords.pickAgain, { picking[n, default: []].insert(.manual) }) : nil,
                            remove: { removePart(n, .manual) })
            } else {
                HomePartRow(mark: "📖", title: "", detail: "", remove: { removePart(n, .manual) }) {
                    HomeManualPicker(copy: model.copy, pick: { picked in
                        page?.steps[n].manual = picked
                        picking[n]?.remove(.manual)
                    }, query: seed)
                }
            }
        }
        if step.has(.photo) {
            HomePartRow(mark: "📷", title: "", detail: HomeEditorWords.photo, remove: { removePart(n, .photo) }) {
                if let image = model.photoImage(step.photo) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 120, height: 72).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        if step.has(.video) {
            HomePartRow(mark: "🎬", title: "", detail: HomeEditorWords.video, remove: { removePart(n, .video) })
        }
        if step.has(.items) {  // an old page's line: shown and removable, never added (the design's calls)
            HomePartRow(mark: "📍", title: step.items.joined(separator: ", "), detail: HomeEditorWords.kept,
                        remove: { removePart(n, .items) })
        }
    }

    /// Yes goes to or No goes to: a step by number and name (board 19), "Choose a step" while it names none.
    func goesTo(_ label: String, _ n: Int, _ current: HouseholdPage, _ key: WritableKeyPath<HouseholdPage.Step, Int?>) -> some View {
        HStack {
        Text(label).fixedSize()
        Picker(label, selection: Binding(get: { current.steps[n][keyPath: key] ?? 0 },
                                         set: { if page?.steps.indices.contains(n) == true { page?.steps[n][keyPath: key] = $0 } })) {
            Text(HomeEditorWords.chooseStep).tag(0)
            ForEach(Array(current.steps.indices).filter { $0 != n }, id: \.self) { i in
                let s = current.steps[i]
                Text(HomeEditorWords.answerTo(i + 1, s.name.isEmpty ? s.words : s.name)).tag(i + 1)
            }
        }
        }
    }

    func stepAt(_ n: Int) -> HouseholdPage.Step? {
        page.flatMap { $0.steps.indices.contains(n) ? $0.steps[n] : nil }
    }

    func binding(_ key: WritableKeyPath<HouseholdPage, String>) -> Binding<String> {
        Binding(get: { page?[keyPath: key] ?? "" }, set: { page?[keyPath: key] = $0 })
    }

    func stepBinding(_ n: Int, _ key: WritableKeyPath<HouseholdPage.Step, String>) -> Binding<String> {
        Binding(get: { page.flatMap { $0.steps.indices.contains(n) ? $0.steps[n][keyPath: key] : nil } ?? "" },
                set: { if page?.steps.indices.contains(n) == true { page?.steps[n][keyPath: key] = $0 } })
    }

    /// A step's number to call, two boxes; both empty takes the number away.
    func callBinding(_ n: Int, _ key: WritableKeyPath<HouseholdPage.Call, String>) -> Binding<String> {
        Binding(get: { stepAt(n)?.call?[keyPath: key] ?? "" }, set: { value in
            guard page?.steps.indices.contains(n) == true else { return }
            showing[n, default: []].insert(.call)  // emptied, the row stays while it's typed in
            var call = page?.steps[n].call ?? HouseholdPage.Call(number: "", label: "")
            call[keyPath: key] = value
            page?.steps[n].call = call.number.isEmpty && call.label.isEmpty ? nil : call
        })
    }

    static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func cancel() {
        model.discardWorking()
        if model.working == nil { discarded() }  // a new page never saved is gone
    }

    func move(_ n: Int, by delta: Int) {
        page?.moveStep(from: n, to: n + delta)  // every Yes and No still on the step it meant
        let swap = { (i: Int) in i == n ? n + delta : i == n + delta ? n : i }
        openSteps = Set(openSteps.map(swap))
        showing = Dictionary(uniqueKeysWithValues: showing.map { (swap($0.key), $0.value) })
        picking = Dictionary(uniqueKeysWithValues: picking.map { (swap($0.key), $0.value) })
    }

    func remove(_ n: Int) {
        guard let step = page?.steps[n] else { return }
        aside.append((step.photo, step.video))  // moved once the page is saved
        page?.removeStep(at: n)  // a Yes or No that named it waits for another step before Save
        let after = { (i: Int) -> Int? in i == n ? nil : i > n ? i - 1 : i }
        openSteps = Set(openSteps.compactMap(after))
        showing = Dictionary(uniqueKeysWithValues: showing.compactMap { k, v in after(k).map { ($0, v) } })
        picking = Dictionary(uniqueKeysWithValues: picking.compactMap { k, v in after(k).map { ($0, v) } })
    }

    /// The open panel for a step's photo or video, then the checks, then the owner's look.
    func pick(_ n: Int, video: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = video ? [.movie] : [.image]
        panel.message = video ? "Pick a short video of this step (a minute at most; its sound isn't kept)."
            : "Pick a photo of this step. Photograph the valve or switch, not a label."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let prepared = video ? await model.prepareVideo(url) : await model.preparePhoto(url)
            if let prepared { looking = (n, prepared) }
        }
    }
}

/// "Preview, as a phone shows it" (board 18): the working page as the packer draws it (HomePage, pinned to its bytes),
/// its slots filled from the phones' copy as a phone would, shown on the step being edited.
struct HomePreview: View {
    let page: HouseholdPage
    let guideTitles: [String: String]
    let base: URL?  // the pages' folder, so a step's photo shows
    let step: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(HomeEditorWords.previewTitle).font(.pmNote.bold()).foregroundStyle(PrepareMeColors.text2).padding(12)
            PreviewWeb(html: HomePage.document(page, guideTitles: guideTitles), base: base,
                       hash: step.map { "#step-\($0 + 1)" })
        }
    }
}

struct PreviewWeb: NSViewRepresentable {
    let html: String
    let base: URL?
    let hash: String?

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown = "", target: String?, kept = ""  // target: the step's screen, "#step-N" (hash is NSObject's)
        var pending: DispatchWorkItem?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let to = target ?? kept
            if !to.isEmpty { webView.evaluateJavaScript(HomePage.previewShow(to)) }
            PrepareMeOurHome.fill(webView, anyPage: true)
        }

        /// The page's own screens only: a link out of it (a guide, the map, a calculator) goes nowhere in a preview.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let bare = { (url: URL?) in url?.absoluteString.components(separatedBy: "#").first }
            decisionHandler(action.navigationType == .other || bare(action.request.url) == bare(webView.url) ? .allow : .cancel)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The preview never takes the keyboard from the box being typed in (HomePage.previewShow says why).
    static let noFocus = WKUserScript(source: HomePage.previewNoFocus, injectionTime: .atDocumentStart,
                                      forMainFrameOnly: true)

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(Self.noFocus)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let c = context.coordinator
        if c.shown == html {
            if c.target != hash, let hash { view.evaluateJavaScript(HomePage.previewShow(hash)) }
            c.target = hash
            return
        }
        c.shown = html
        c.target = hash
        c.pending?.cancel()
        // a moment after the last key, keeping the screen the preview was on
        let work = DispatchWorkItem { [html, base] in
            view.evaluateJavaScript("location.hash") { found, _ in
                c.kept = found as? String ?? ""
                view.loadHTMLString(html, baseURL: base)
            }
        }
        c.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

/// AppKit's player in SwiftUI. SwiftUI's own VideoPlayer can't be drawn on macOS 27.0.1: "failed to demangle superclass
/// of VideoPlayerView from mangled name 'So12AVPlayerViewC'", an abort inside Apple's code (the owner's first video,
/// 2026-10-19; reproduced alone, outside the app). AVPlayerView itself draws fine.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}

/// The owner's look at a checked photo or video before it's kept.
struct LookSheet: View {
    let prepared: HouseholdPagesModel.Prepared
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HouseholdPagesWords.lookTitle).font(.pmTitle)
            if let video = prepared.video {
                PlayerView(player: AVPlayer(url: video)).frame(width: 560, height: 315)
            } else {
                Image(decorative: prepared.preview, scale: 1).resizable().scaledToFit().frame(maxWidth: 560, maxHeight: 360)
            }
            Text(HouseholdWords.lookFirst).foregroundStyle(PrepareMeColors.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Keep it") { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        #if PREPAREME_CHECK
        .task(id: prepared.id) {  // PREPAREME_CHECK_PART=import: Keep it, 3 seconds after each look shows (only one that shows)
            guard ProcessInfo.processInfo.environment["PREPAREME_CHECK_PART"]?.hasPrefix("import") == true else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { done(true) }
        }
        #endif
    }
}
#endif
