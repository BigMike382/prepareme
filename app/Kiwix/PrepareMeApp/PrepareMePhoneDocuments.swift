#if os(iOS)
import LocalAuthentication
import PDFKit
import PhotosUI
import PrepareMeShared
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// The Documents tab on an adult's phone or iPad (docs/documents.md, "The phones"; owner, 2026-10-24): before the Mac
/// gives this device the key, what to do; then locked until Face ID, Touch ID or the passcode; then the household's
/// folders and documents, a folder at a time. Nothing behind the lock is drawn, not even a name, until it opens.
struct PhoneDocumentsTab: View {
    @State private var model = PhoneDocumentsModel.shared

    var body: some View {
        NavigationStack(path: $model.path) {
            Group {
                switch model.state {
                case .open: PhoneDocumentsFolder(folder: nil)
                case .locked, .unlocking: PhoneDocumentsLocked(failure: nil)
                case .failed(let words): PhoneDocumentsLocked(failure: words)
                }
            }
            .pmBandBar()  // look 3
            .homeMacButton()
            .navigationDestination(for: PhoneDocumentsRoute.self) { route in
                switch route {
                case .folder(let id): PhoneDocumentsFolder(folder: id).homeMacButton()
                case .document(let id): PhoneDocumentViewer(id: id).homeMacButton()
                case .recentlyDeleted: PhoneDocumentsRecentlyDeleted().homeMacButton()
                }
            }
        }
        // the idle lock's activity: moving between folders and documents, every action (the model's) and a PDF's page
        // turns; never a gesture over the screen, which took the rows' taps
        .onChange(of: model.path) { _, _ in model.touched() }
        .onAppear { model.shown() }
        .modifier(PhoneDocumentsDialogs())
        .task { await checkHooks() }
    }

    private func checkHooks() async {
        #if targetEnvironment(simulator)
        // A session's simulator check only (screenshots; the made-up store from a loopback test service, whose Mac
        // check build gives the key by itself): _DOCUMENTS=unlock checks with the Mac every 5 seconds until every
        // document is here, then unlocks (the session matches Face ID); _PICK=<name>|deleted shows that folder or
        // document once it opens
        let check = ProcessInfo.processInfo.environment
        if check["PREPAREME_CHECK_DOCUMENTS"] == "unlock" {
            for _ in 0..<36 where !model.given || model.missing > 0 || !model.mirrored {
                await PrepareMeLibrary.shared.check(.checkNow)
                try? await Task.sleep(for: .seconds(5))
            }
            model.unlock()
        }
        // _CHANGE=1: a made-up folder and note made here once it opens, sent at the next check, for the Mac to apply
        if check["PREPAREME_CHECK_DOCUMENTS_CHANGE"] == "1" {
            while model.state != .open { try? await Task.sleep(for: .milliseconds(300)) }
            model.newFolder("Phone folder (FAKE)", in: nil)
            model.add([.data(Data("Made-up note from the phone. FAKE.".utf8), name: "Phone note (FAKE)", type: "txt")],
                      to: nil)
            try? await Task.sleep(for: .seconds(3))
            await PrepareMeLibrary.shared.check(.checkNow)
        }
        guard let pick = check["PREPAREME_CHECK_DOCUMENTS_PICK"], !pick.isEmpty else { return }
        while model.state != .open { try? await Task.sleep(for: .milliseconds(300)) }
        try? await Task.sleep(for: .seconds(1))
        if pick == "deleted" {
            model.path = [.recentlyDeleted]
        } else if let folder = model.index.folders.first(where: { $0.name == pick }) {
            model.path = [.folder(folder.id)]
        } else if let document = model.index.documents.first(where: { $0.name == pick }) {
            model.path = [.document(document.id)]
        }
        #endif
    }
}

// MARK: The locked screen

private struct PhoneDocumentsLocked: View {
    let failure: String?
    @State private var model = PhoneDocumentsModel.shared

    var body: some View {
        // look 3's one look for "locked" (spec section 10): a refusal in red, the unlock as its one button
        PMStateScreen {
            let given = model.given && failure == nil
            PMState(symbol: model.given ? "lock.fill" : "desktopcomputer", heading: DocumentsWords.lockedHeading,
                    line: failure ?? (model.given ? DocumentsWords.lockedBody
                                                  : DocumentsWords.notGivenYet(asked: model.asked)),
                    kind: failure == nil ? .info : .damaged,
                    action: given ? (DocumentsWords.unlockButton(biometry: Self.biometry), { model.unlock() }) : nil)
                .disabled(model.state == .unlocking)
            if model.state == .unlocking { ProgressView() }
            if let message = model.message {
                Text(message).foregroundStyle(PrepareMeColors.text2).padding(.horizontal, 24)
            }
            if model.refused != nil { PhoneDocumentsKept() }
            if model.missing > 0 { PhoneDocumentsMissing(count: model.missing) }
            if model.onlyHere > 0 {
                Text(DocumentsWords.onlyHere(model.onlyHere, device: ThisDevice.word)).font(.pmNote)
                    .foregroundStyle(PrepareMeColors.text2).padding(.horizontal, 24)
            }
        }
        .navigationTitle(PrepareMeTab.documents.title)
        .pmTitleSmall()
        .onAppear { model.refreshStanding() }
    }

    /// "Face ID" or "Touch ID" where the device has it set up, else the button just says Unlock (the passcode asks).
    static var biometry: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return nil
        }
    }
}

/// The amber line: documents the Mac has that this device hasn't (design: "Missing is loud, not a footer"); look 3's
/// one amber row (spec section 10, rule 4).
private struct PhoneDocumentsMissing: View {
    let count: Int

    var body: some View { PMWarningRow(DocumentsWords.missing(count, device: ThisDevice.word)) }
}

/// The amber line when this device kept its own copy instead of the Mac's list (audit G2), with "Use the Mac's
/// Copy…" under it while open and only for a list under this device's own key.
private struct PhoneDocumentsKept: View {
    @State private var model = PhoneDocumentsModel.shared

    var body: some View {
        if let refused = model.refused {
            PMWarningRow(DocumentsWords.keptOwnCopy(refused, ownKeyID: model.ownKeyID, device: ThisDevice.word),
                         action: DocumentsWords.offersMacsCopy(refused, ownKeyID: model.ownKeyID)
                             ? (DocumentsWords.useMacsCopy, { model.confirmingMacsCopy = true }) : nil,
                         below: true)
        }
    }
}

// MARK: A folder

private struct PhoneDocumentsFolder: View {
    let folder: UUID?
    @State private var model = PhoneDocumentsModel.shared
    @State private var scanning = false
    @State private var picking = false
    @State private var importing = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        let folders = model.index.folders(in: folder)
        let documents = model.index.documents(in: folder)
        PMList {
            if folder == nil, model.refused != nil || model.missing > 0 || model.message != nil || model.waiting > 0
                || model.onlyHere > 0 {
                Section {
                    if model.refused != nil { PhoneDocumentsKept().listRowInsets(EdgeInsets()) }
                    if model.missing > 0 { PhoneDocumentsMissing(count: model.missing).listRowInsets(EdgeInsets()) }
                    if let message = model.message {
                        HStack(alignment: .top) {
                            Text(message).foregroundStyle(PrepareMeColors.ink)
                            Spacer()
                            Button("Dismiss", systemImage: "xmark") { model.message = nil }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                    if model.waiting > 0 {
                        Text(DocumentsWords.waitingHere(model.waiting)).font(.pmNote)
                            .foregroundStyle(PrepareMeColors.text2)
                    }
                    if model.onlyHere > 0 {
                        Text(DocumentsWords.onlyHere(model.onlyHere, device: ThisDevice.word)).font(.pmNote)
                            .foregroundStyle(PrepareMeColors.text2)
                    }
                }
            }
            if folders.isEmpty && documents.isEmpty {
                Section {
                    if folder == nil {  // look 3's one look, as the Mac's empty Documents (spec section 10, rule 1)
                        PMState(symbol: "folder", heading: DocumentsWords.emptyHeading, line: DocumentsWords.emptyBody)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("No documents in this folder.").foregroundStyle(PrepareMeColors.text2)
                    }
                }
            }
            Section {
                // each row is its own button beside its •••, never one inside the other's link (look 3 change 16), so a
                // tap on the three dots can't open the row and VoiceOver reads them as two controls
                ForEach(folders) { item in
                    HStack {
                        Button { model.path.append(.folder(item.id)) } label: {
                            HStack {
                                Label {
                                    Text(item.name)
                                } icon: {
                                    Image(systemName: "folder").foregroundStyle(PrepareMeColors.ink)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(PrepareMeColors.ink)
                        PhoneRowMore(name: item.name) { PhoneDocumentsFolderMenu(folder: item) }
                        Image(systemName: "chevron.right").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                            .accessibilityHidden(true)
                    }
                    .contextMenu { PhoneDocumentsFolderMenu(folder: item) }
                }
                ForEach(documents) { document in
                    HStack {
                        Button { model.path.append(.document(document.id)) } label: {
                            HStack {
                                PhoneDocumentRow(document: document)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(PrepareMeColors.ink)
                        PhoneRowMore(name: document.name) { PhoneDocumentsRowMenu(document: document) }
                        Image(systemName: "chevron.right").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                            .accessibilityHidden(true)
                    }
                    .contextMenu { PhoneDocumentsRowMenu(document: document) }
                }
            }
            if folder == nil {
                let deleted = model.index.recentlyDeleted
                if !deleted.folders.isEmpty || !deleted.documents.isEmpty {
                    Section {
                        NavigationLink(value: PhoneDocumentsRoute.recentlyDeleted) {
                            Label("Recently Deleted", systemImage: "trash")
                        }
                    }
                }
                Section {
                    Text(footer).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    if model.busy { ProgressView() }
                }
            }
        }
        .navigationTitle(model.index.folder(folder)?.name ?? PrepareMeTab.documents.title)
        .pmTitleSmall()
        .toolbar {  // look 3 change 15: Lock, on every folder screen (the Mac has it in the toolbar too)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Lock", systemImage: "lock") { model.lock() }.labelStyle(.titleAndIcon)
            }
        }
        .pmAddBar {  // look 3 change 13: the one Add, at the bottom
            Menu {
                Button(DocumentsWords.scanButton, systemImage: "doc.viewfinder") { scanning = true }
                    .disabled(!VNDocumentCameraViewController.isSupported)
                Button("Photos", systemImage: "photo") { picking = true }
                Button("Files", systemImage: "folder") { importing = true }
                Button("New Folder", systemImage: "folder.badge.plus") { model.naming = .newFolder(parent: folder) }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .pmMenuAction()  // not pmAction: a Menu ignores the button style, so Add hugged its words
            .disabled(model.busy)
        }
        .fullScreenCover(isPresented: $scanning) {
            PhoneDocumentScanner { pages in
                scanning = false
                guard let pages else { return }
                model.add([.data(pages, name: Self.name(DocumentsWords.scanName), type: "pdf")], to: folder)
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $picking, selection: $photos, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            Task { model.add(await Self.load(picked), to: folder) }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: DocumentTypes.extensions.compactMap { UTType(filenameExtension: $0) },
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls.map { .file($0) }, to: folder) }
        }
    }

    private var footer: String {
        let count = model.index.live.count
        return model.missing > 0 ? DocumentsWords.documents(count)
            : DocumentsWords.footer(count: count, device: ThisDevice.word)
    }

    static func name(_ word: String) -> String {
        "\(word) \(Date().formatted(date: .abbreviated, time: .shortened))"
            .replacingOccurrences(of: ":", with: ".")
    }

    /// The picked photos' bytes as Photos keeps them, each with its own type.
    static func load(_ picked: [PhotosPickerItem]) async -> [PhoneDocumentsSource] {
        var sources: [PhoneDocumentsSource] = []
        for item in picked {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.compactMap(\.preferredFilenameExtension)
                .first { DocumentTypes.kind(forExtension: $0) == .image } ?? "jpeg"
            sources.append(.data(data, name: name(DocumentsWords.photoName), type: type))
        }
        return sources
    }
}

private struct PhoneDocumentRow: View {
    let document: StoredDocument

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.name)
                Text("\(document.type.uppercased()) · \(ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file))")
                    .font(.pmNote)
                    .foregroundStyle(PrepareMeColors.text2)
            }
        } icon: {
            Image(systemName: document.kind == .pdf ? "doc.richtext" : document.kind == .image ? "photo" : "doc.text")
                .foregroundStyle(PrepareMeColors.ink)
        }
    }
}

/// A document's long-press menu (design): Open, Share…, Print…, Rename, Move to Folder…, then Delete last, in red.
/// The visible ••• on a row (look 3 change 16, accessibility fix 5): the menu that was long-press only, a 44-point
/// target of its own beside the row's link, named for its row.
private struct PhoneRowMore<Items: View>: View {
    let name: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(PrepareMeColors.ink)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More actions for \(name)")
    }
}

private struct PhoneDocumentsRowMenu: View {
    let document: StoredDocument
    @State private var model = PhoneDocumentsModel.shared

    var body: some View {
        Button("Open", systemImage: "doc") { model.path.append(.document(document.id)) }
        Button("Share…", systemImage: "square.and.arrow.up") { model.send(document, .share) }
        Button("Print…", systemImage: "printer") { model.send(document, .print) }
            .disabled(document.kind == .office)
        Button("Send as Locked PDF…", systemImage: "lock.doc") { model.send(document, .lockedPDF) }  // as the viewer's
            .disabled(document.kind == .office)
        Button("Rename…", systemImage: "pencil") { model.naming = .rename(.document(document.id)) }
        Button("Move to Folder…", systemImage: "folder") { model.moving = .document(document.id) }
        Divider()
        PMMenuDelete("Delete…", systemImage: "trash") { model.deleting = .document(document.id) }
    }
}

private struct PhoneDocumentsFolderMenu: View {
    let folder: DocumentFolder
    @State private var model = PhoneDocumentsModel.shared

    var body: some View {
        Button("Open", systemImage: "folder") { model.path.append(.folder(folder.id)) }
        Button("Rename…", systemImage: "pencil") { model.naming = .rename(.folder(folder.id)) }
        Button("Move to Folder…", systemImage: "folder") { model.moving = .folder(folder.id) }
        Divider()
        PMMenuDelete("Delete…", systemImage: "trash") { model.deleting = .folder(folder.id) }
    }
}

// MARK: Recently Deleted

private struct PhoneDocumentsRecentlyDeleted: View {
    @State private var model = PhoneDocumentsModel.shared

    var body: some View {
        let deleted = model.index.recentlyDeleted
        PMList {
            Section {
                Text(DocumentsWords.deleteDocumentMessage).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
            Section {
                ForEach(deleted.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .contextMenu { Button("Put Back", systemImage: "arrow.uturn.backward") { model.putBack(.folder(folder.id)) } }
                        .swipeActions { Button("Put Back") { model.putBack(.folder(folder.id)) } }
                }
                ForEach(deleted.documents) { document in
                    PhoneDocumentRow(document: document)
                        .contextMenu {
                            Button("Put Back", systemImage: "arrow.uturn.backward") { model.putBack(.document(document.id)) }
                        }
                        .swipeActions { Button("Put Back") { model.putBack(.document(document.id)) } }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .pmTitleSmall()
    }
}

// MARK: The viewer

/// One document: PDFs and photos in Apple's PDF view (zoom, pages, a quarter turn for reading that never changes the
/// stored file), Word, Excel, iWork and text in Quick Look from a sealed copy wiped when it closes or Documents locks.
private struct PhoneDocumentViewer: View {
    let id: UUID
    @State private var model = PhoneDocumentsModel.shared
    @State private var pdf: PDFDocument?
    @State private var copy: URL?
    @State private var failed = false
    @State private var turns = 0

    private var document: StoredDocument? { model.index.documents.first { $0.id == id } }

    var body: some View {
        Group {
            if let pdf {
                PhoneDocumentPDF(pdf: pdf, turns: turns)
            } else if let copy {
                PhoneDocumentQuickLook(url: copy)
            } else if failed {
                PMStateScreen {  // look 3's one look, in red: damaged (spec section 10, rules 1 and 3)
                    PMState(symbol: "exclamationmark.triangle", heading: DocumentsWords.damagedHeading,
                            line: DocumentsWords.damaged, kind: .damaged)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PrepareMeColors.ground)
        .navigationTitle(document?.name ?? "")
        .pmTitleSmall()
        .toolbar {
            if let document {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if pdf != nil {
                        Button("Rotate", systemImage: "rotate.right") {
                            model.touched()
                            turns += 1
                        }
                    }
                    Menu {
                        Button("Share…", systemImage: "square.and.arrow.up") { model.send(document, .share) }
                        Button("Print…", systemImage: "printer") { model.send(document, .print) }
                            .disabled(document.kind == .office)
                        Button("Send as Locked PDF…", systemImage: "lock.doc") { model.send(document, .lockedPDF) }
                            .disabled(document.kind == .office)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: id) { await load() }
        .onDisappear {
            if let copy { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        }
    }

    private func load() async {
        guard let document, let data = await model.data(of: document) else {
            failed = true
            return
        }
        if let pages = PhoneDocumentPages.pdf(data, kind: document.kind) {
            pdf = pages
        } else {
            copy = try? DocumentScratch.copy(data, named: document.fileName)
            failed = copy == nil
        }
    }
}

private struct PhoneDocumentPDF: UIViewRepresentable {
    let pdf: PDFDocument
    let turns: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = UIColor(PrepareMeColors.ground)
        view.document = pdf
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneDocumentsModel.shared.touched() }  // reading counts as activity
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.turns != turns else { return }
        let more = (turns - context.coordinator.turns) * 90
        context.coordinator.turns = turns
        for number in 0..<pdf.pageCount {  // for reading only: the stored file is never changed
            if let page = pdf.page(at: number) { page.rotation = (page.rotation + more) % 360 }
        }
        view.document = nil
        view.document = pdf
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var turns = 0
    }
}

private struct PhoneDocumentQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: The scanner and the share sheet

/// VisionKit's document camera; the pages come back as one PDF, in memory, never saved to Photos.
private struct PhoneDocumentScanner: UIViewControllerRepresentable {
    let done: (Data?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let camera = VNDocumentCameraViewController()
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: (Data?) -> Void
        init(done: @escaping (Data?) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let pdf = PDFDocument()
            for number in 0..<scan.pageCount {
                if let page = PDFPage(image: scan.imageOfPage(at: number)) { pdf.insert(page, at: pdf.pageCount) }
            }
            done(pdf.pageCount > 0 ? pdf.dataRepresentation() : nil)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done(nil) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            done(nil)
        }
    }
}

/// The share sheet, leaving out what would copy a document on without a send (design): Copy, Save Image, Assign to
/// Contact and Add to Reading List. Print goes from memory instead (Print…).
private struct PhoneDocumentShareSheet: UIViewControllerRepresentable {
    let share: PhoneDocumentsShare

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let sheet = UIActivityViewController(activityItems: [share.url], applicationActivities: nil)
        sheet.excludedActivityTypes = [.copyToPasteboard, .saveToCameraRoll, .assignToContact, .addToReadingList,
                                       .print]
        sheet.completionWithItemsHandler = { activity, completed, _, _ in
            PhoneDocumentsModel.shared.shared(share, activity: activity, completed: completed)
        }
        return sheet
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: The dialogs

private struct PhoneDocumentsDialogs: ViewModifier {
    @State private var model = PhoneDocumentsModel.shared
    @State private var name = ""
    @State private var password = ""

    func body(content: Content) -> some View {
        content
            .alert(namingTitle, isPresented: Binding(get: { model.naming != nil }, set: { if !$0 { model.naming = nil } })) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { model.naming = nil }
                Button(model.naming.map { if case .newFolder = $0 { "Create" } else { "Rename" } } ?? "OK") {
                    let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let naming = model.naming, !typed.isEmpty {
                        switch naming {
                        case .newFolder(let parent): model.newFolder(typed, in: parent)
                        case .rename(let target): model.rename(target, to: typed)
                        }
                    }
                    model.naming = nil
                }
            }
            .onChange(of: model.naming) { _, naming in name = naming.map(currentName) ?? "" }
            .alert(DocumentsWords.useMacsCopyTitle, isPresented: $model.confirmingMacsCopy) {
                Button("Cancel", role: .cancel) {}
                Button(DocumentsWords.useMacsCopyConfirm, role: .destructive) { model.useMacsCopy() }
            } message: {
                Text(DocumentsWords.useMacsCopyMessage(model.refused?.files ?? 0, device: ThisDevice.word))
            }
            .alert(deleteTitle, isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } })) {
                Button("Cancel", role: .cancel) { model.deleting = nil }
                Button("Delete", role: .destructive) {
                    if let target = model.deleting { model.delete(target) }
                    model.deleting = nil
                }
            } message: {
                Text(deleteMessage)
            }
            .alert(model.confirming.map { DocumentsWords.sendTitle($0.document.name, $0.way) } ?? "",
                   isPresented: Binding(get: { model.confirming != nil }, set: { if !$0 { model.confirming = nil } })) {
                Button("Cancel", role: .cancel) { model.confirming = nil }  // the default (design)
                Button(model.confirming?.way == .print ? "Print" : "Continue") {
                    if let (document, way) = model.confirming { model.confirmed(document, way) }
                }
            } message: {
                Text(model.confirming?.way == .print ? DocumentsWords.printMessage : DocumentsWords.sendMessage)
            }
            .alert("Send as a locked PDF", isPresented: Binding(get: { model.askingPassword != nil },
                                                                set: { if !$0 { model.askingPassword = nil } })) {
                SecureField("Password", text: $password)
                Button("Cancel", role: .cancel) {
                    password = ""
                    model.askingPassword = nil
                }
                Button("Make the Locked PDF") {
                    if let document = model.askingPassword, !password.isEmpty { model.sendLocked(document, password: password) }
                    password = ""
                    model.askingPassword = nil
                }
            } message: {
                Text(DocumentsWords.lockedPDFMessage)
            }
            .sheet(item: $model.moving) { target in PhoneDocumentsMoveSheet(target: target) }
            .sheet(item: $model.sharing, onDismiss: {
                if let share = model.sharing { model.shared(share, activity: nil, completed: false) }
            }) { share in
                PhoneDocumentShareSheet(share: share).presentationDetents([.medium, .large])
            }
    }

    private var namingTitle: String {
        switch model.naming {
        case .newFolder?: return "New Folder"
        case .rename?: return "Rename"
        case nil: return ""
        }
    }

    private func currentName(_ naming: PhoneDocumentsNaming) -> String {
        switch naming {
        case .newFolder: return ""
        case .rename(.folder(let id)): return model.index.folder(id)?.name ?? ""
        case .rename(.document(let id)): return model.index.documents.first { $0.id == id }?.name ?? ""
        }
    }

    private var deleteTitle: String {
        switch model.deleting {
        case .folder(let id)?: return DocumentsWords.deleteFolderTitle(model.index.folder(id)?.name ?? "")
        case .document(let id)?:
            return DocumentsWords.deleteDocumentTitle(model.index.documents.first { $0.id == id }?.name ?? "")
        case nil: return ""
        }
    }

    private var deleteMessage: String {
        if case .folder(let id)? = model.deleting {
            return DocumentsWords.deleteFolderMessage(documents: model.index.documentCount(inFolder: id))
        }
        return DocumentsWords.deleteDocumentMessage
    }
}

/// Move to Folder…: the folders as a tree, the top level first; a folder never into itself.
private struct PhoneDocumentsMoveSheet: View {
    let target: PhoneDocumentsTarget
    @State private var model = PhoneDocumentsModel.shared
    @Environment(\.dismiss) private var dismiss

    private var rows: [(folder: DocumentFolder, depth: Int)] {
        var rows: [(DocumentFolder, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for folder in model.index.folders(in: parent) {
                if case .folder(let id) = target, model.index.subtree(id).contains(folder.id) { continue }
                rows.append((folder, depth))
                walk(folder.id, depth + 1)
            }
        }
        walk(nil, 0)
        return rows
    }

    var body: some View {
        NavigationStack {
            PMList {
                Button {
                    model.move(target, to: nil)
                    dismiss()
                } label: {
                    Label("Top level", systemImage: "tray.full")
                }
                ForEach(rows, id: \.folder.id) { row in
                    Button {
                        model.move(target, to: row.folder.id)
                        dismiss()
                    } label: {
                        Label(row.folder.name, systemImage: "folder").padding(.leading, CGFloat(row.depth) * 20)
                    }
                }
            }
            .navigationTitle("Move to Folder")
            .pmTitleSmall()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: Home Mac in each tab's bar (iPhone, adults)

extension View {
    /// On an adult's iPhone Documents takes Home Mac's place in the tab bar, and Home Mac is a button at the top right
    /// of each tab (owner, 2026-10-24); elsewhere, nothing.
    func homeMacButton() -> some View { modifier(HomeMacButton()) }
}

private struct HomeMacButton: ViewModifier {
    @ObservedObject private var tabs = PrepareMeTabs.shared

    func body(content: Content) -> some View {
        content.toolbar {
            if PrepareMeTab.homeMacInBar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { tabs.homeMacSheet = true } label: {
                        // its word, not the symbol alone (family downloads plan, phase 1): a bar draws a Label's
                        // icon only, whatever its style, so the two are drawn side by side
                        HStack(spacing: 4) {
                            // offers not yet seen (family downloads plan, phase 5), in the symbol's place: beside the
                            // word, the button outgrew the bar and iOS folded it into a ••• of its own
                            if tabs.unseenOffers > 0 {
                                Text("\(tabs.unseenOffers)").font(.pmNote.bold()).monospacedDigit()
                                    .foregroundStyle(PrepareMeColors.teal)
                                    .frame(minWidth: 22, minHeight: 22)
                                    .background(PrepareMeColors.onTeal, in: .capsule)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                            Text(PrepareMeTab.homeMac.title)
                        }
                    }
                    .accessibilityLabel(tabs.unseenOffers > 0
                                        ? "\(PrepareMeTab.homeMac.title), \(tabs.unseenOffers) new" : PrepareMeTab.homeMac.title)
                }
            }
        }
    }
}

/// The cover the app switcher shows while Essential Documents were on screen (design): the locked screen's look, with
/// no name or page behind it.
struct PhoneDocumentsCover: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.pmLargeTitle).foregroundStyle(PrepareMeColors.text2)
            Text(DocumentsWords.lockedHeading).font(.pmTitle).foregroundStyle(PrepareMeColors.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PrepareMeColors.ground)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Today's line when documents the Mac has aren't on this device yet (design).
struct PhoneDocumentsTodayLine: View {
    let count: Int

    var body: some View {
        PhoneDocumentsMissing(count: count)  // the row's own ground reaches the edges (look 3)
    }
}
#endif
