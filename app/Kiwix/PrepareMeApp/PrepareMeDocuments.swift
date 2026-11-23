#if os(macOS)
import AppKit
import LocalAuthentication
import PDFKit
import PrepareMeShared
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's Essential Documents (docs/documents.md; plan 2026-10-24, phase 1): locked until Touch ID or the
/// password, then the household's folders and documents beside a viewer. Nothing behind the lock is drawn, not even
/// a name, until it opens.
struct PrepareMeDocumentsView: View {
    @State private var model = DocumentsModel.shared

    var body: some View {
        Group {
            switch model.state {
            case .open:
                if model.index.folders.isEmpty && model.index.documents.isEmpty {
                    DocumentsEmpty()
                } else {
                    DocumentsBrowser()
                }
            case .locked, .unlocking:
                DocumentsLocked(failure: nil)
            case .failed(let words):
                DocumentsLocked(failure: words)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PrepareMeColors.ground)
        .onAppear { model.visible = true }
        .onDisappear { model.visible = false }
        .focusedSceneValue(\.documentsMenu, DocumentsMenuActions(model: model))
        .importsItemProviders(model.state == .open ? [.pdf, .image] : []) { model.addScanned($0) }
        .modifier(DocumentsDialogs(model: model))
        .modifier(DocumentsBackupDialogs(model: model))
        .onAppear { model.refreshBackup() }
        .task { await checkHooks() }
    }

    private func checkHooks() async {
        #if PREPAREME_CHECK
        // The check build only, for a check that can't click (screenshots only): PREPAREME_CHECK_APPEARANCE=light or dark;
        // PREPAREME_CHECK_DOCUMENTS=open (the check key) or prompt (the real Touch ID prompt); _ADD=a folder of fake
        // documents in the check home; _EXPAND=all; _TRASH=a name to put in Recently Deleted; _PICK=a name, folder:NAME
        // or deleted; _SEND=print, airDrop, share or lockedPDF; _DELETE=a name, asking first; _NEWFOLDER=1; _INSURANCE=1
        // (Bring In the Insurance Record, from the check home's made-up inventory)
        let check = ProcessInfo.processInfo.environment
        try? await Task.sleep(for: .seconds(2))  // after UserColorSchemeStore's init clears the key
        // The red night screen's layWindows puts the chosen scheme back after every event, so choose it, not NSApp's.
        let scheme: UserColorScheme? = ["light": .light, "dark": .dark][check["PREPAREME_CHECK_APPEARANCE"] ?? ""]
        if let scheme {
            UserDefaults.standard.set(scheme.rawValue, forKey: "userColorScheme")
            NSApp.appearance = scheme.asNSAppearance
        }
        guard let how = check["PREPAREME_CHECK_DOCUMENTS"] else { return }
        // phase 4: _RECOVER=sheet shows Use the Recovery Password…, _RECOVER=1 uses DIR's check-recovery-password.txt
        // (written by _SPARE=make) in place of Unlock
        let passwordFile = PrepareMeHome.url?.appendingPathComponent("check-recovery-password.txt")
        let checkPassword = passwordFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        model.refreshBackup()
        switch check["PREPAREME_CHECK_DOCUMENTS_RECOVER"] {
        case "sheet": model.recovering = true
        case "1": model.recover(password: checkPassword ?? "")
        default: model.unlock()
        }
        guard how == "open" else { return }
        while model.state != .open { try? await Task.sleep(for: .milliseconds(200)) }
        if let folder = check["PREPAREME_CHECK_DOCUMENTS_ADD"], model.index.documents.isEmpty {
            model.add([URL(fileURLWithPath: folder, isDirectory: true)], to: nil)
            while model.busy { try? await Task.sleep(for: .milliseconds(200)) }
        }
        func find(_ name: String) -> StoredDocument? { model.index.documents.first { $0.name == name } }
        if let name = check["PREPAREME_CHECK_DOCUMENTS_TRASH"], let doc = find(name), doc.deleted == nil {
            model.delete(.document(doc.id))
        }
        if check["PREPAREME_CHECK_DOCUMENTS_EXPAND"] == "all" { model.expanded = Set(model.index.folders.map(\.id)) }
        if let pick = check["PREPAREME_CHECK_DOCUMENTS_PICK"] {
            if pick == "deleted" {
                model.pick = .recentlyDeleted
            } else if pick.hasPrefix("folder:"), let folder = model.index.folders.first(where: { "folder:" + $0.name == pick }) {
                model.pick = .folder(folder.id)
            } else if let doc = find(pick) {
                model.pick = .document(doc.id)
            }
        }
        try? await Task.sleep(for: .seconds(1))
        if let way = DocumentSendWay.allCases.first(where: { "\($0)" == check["PREPAREME_CHECK_DOCUMENTS_SEND"] }),
           let doc = model.picked {
            model.send(doc, way)
        }
        if let name = check["PREPAREME_CHECK_DOCUMENTS_DELETE"], let doc = find(name) { model.deleting = .document(doc.id) }
        if check["PREPAREME_CHECK_DOCUMENTS_NEWFOLDER"] == "1" { model.naming = .newFolder(parent: nil) }
        if check["PREPAREME_CHECK_DOCUMENTS_INSURANCE"] == "1" { model.bringInsurance() }
        // phase 4: _SPARE=sheet shows the recovery password's sheet; _SPARE=make sets one, its password written to DIR's
        // check-recovery-password.txt (made-up documents only); _RESTORE=sheet shows Test a Restore…, _RESTORE=icloud
        // runs it on DIR's stand-in iCloud copy with that password
        switch check["PREPAREME_CHECK_DOCUMENTS_SPARE"] {
        case "sheet":
            model.startSpare()
        case "make":
            model.startSpare()
            if let draft = model.spareDraft, let passwordFile {
                try? draft.write(to: passwordFile, atomically: true, encoding: .utf8)
                _ = model.saveSpare(pasted: draft)
            }
        default: break
        }
        switch check["PREPAREME_CHECK_DOCUMENTS_RESTORE"] {
        case "sheet":
            model.testingRestore = true
        case "icloud":
            try? await Task.sleep(for: .seconds(3))  // the copy after _SPARE=make's relist
            let password = passwordFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            if let copy = model.backupFolder { model.message = await model.testRestore(copy, iCloud: true, password: password) }
        default: break
        }
        // _GIVE=1: Settings › Devices' Give It Essential Documents… for each adult's phone that asks, as it asks (the
        // simulator check of phase 3, with the loopback test service on DIR's pairing and documents folders)
        while check["PREPAREME_CHECK_DOCUMENTS_GIVE"] == "1" {
            let pairing = PhonePairing.shared
            pairing.refresh()
            for phone in pairing.phones ?? [] where !phone.readOnly && pairing.documentAsks[phone.label] != nil
                && !pairing.documentsGiven.contains(phone.label) {
                await pairing.give(phone)
            }
            try? await Task.sleep(for: .seconds(3))
        }
        #endif
    }
}

// MARK: The locked and empty screens

private struct DocumentsLocked: View {
    let failure: String?
    @State private var model = DocumentsModel.shared

    var body: some View {
        PMStateScreen {  // look 3's one look (spec section 10, rule 1; plan Task 6.2): a refusal in red
            PMState(symbol: "lock.fill", heading: DocumentsWords.lockedHeading, line: failure ?? DocumentsWords.lockedBody,
                    kind: failure == nil ? .info : .damaged)
            if failure == nil {  // a failure here is one Unlock can't mend (no Secure Enclave)
                Button(DocumentsWords.unlockButton(biometry: Self.biometry)) { model.unlock() }
                    .pmAction(fullWidth: false)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.state == .unlocking)
            }
            if model.hasSpare {  // a new Mac, or a key file that won't open (phase 4)
                Button(DocumentsWords.recoverButton) {
                    model.message = nil
                    model.recovering = true
                }
                .pmAction(fullWidth: false)
                .disabled(model.state == .unlocking)
            }
            if model.state == .unlocking { ProgressView().controlSize(.small) }
            if let message = model.message {
                Text(message).foregroundStyle(PrepareMeColors.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
    }

    /// "Touch ID" on a Mac with it, else the button just says Unlock (the password or an Apple Watch asks then).
    static var biometry: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return context.biometryType == .touchID ? "Touch ID" : nil
    }
}

private struct DocumentsEmpty: View {
    @State private var model = DocumentsModel.shared

    var body: some View {
        PMStateScreen {  // look 3's one look (spec section 10, rule 1; plan Task 6.2)
            if let message = model.message { DocumentsBanner(text: message) }
            DocumentsSpareBanner().frame(maxWidth: 520)
            PMState(symbol: "folder", heading: DocumentsWords.emptyHeading, line: DocumentsWords.emptyBody)
            HStack(spacing: 12) {
                Button("Add Documents…") { DocumentsPanels.addDocuments(to: nil) }.pmAction(fullWidth: false)
                Button(DocumentsWords.addFolder) { DocumentsPanels.addFolder(to: nil) }.pmAction(fullWidth: false)
            }
            .controlSize(.large)
            .disabled(model.busy)
            Text("To scan with your iPhone: File › Import from iPhone or iPad › Scan Documents.")
                .foregroundStyle(PrepareMeColors.text2)
            if model.busy { ProgressView().controlSize(.small) }
        }
    }
}

private struct DocumentsBanner: View {
    let text: String
    @State private var model = DocumentsModel.shared

    var body: some View {
        HStack(alignment: .top) {
            Text(text).foregroundStyle(PrepareMeColors.ink).frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark") { model.message = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(PrepareMeColors.panel, in: RoundedRectangle(cornerRadius: PrepareMeCorners.panel))
        .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.panel).stroke(PrepareMeColors.line))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}

// MARK: The list and the viewer

private struct DocumentsBrowser: View {
    @State private var model = DocumentsModel.shared

    var body: some View {
        // not HSplitView: it laid the viewer out wider than its pane and cut off its right side (seen on screen)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let message = model.message { DocumentsBanner(text: message) }
                DocumentsSpareBanner()
                List(selection: $model.pick) {
                    DocumentFolderRows(parent: nil)
                    if !model.index.recentlyDeleted.folders.isEmpty || !model.index.recentlyDeleted.documents.isEmpty {
                        Label("Recently Deleted", systemImage: "trash").tag(DocumentsModel.Pick.recentlyDeleted)
                    }
                }
                .scrollContentBackground(.hidden)
                .dropDestination(for: URL.self) { urls, _ in
                    model.add(urls, to: nil)
                    return true
                }
                HStack {
                    Text(DocumentsWords.footer(count: model.index.live.count)).foregroundStyle(PrepareMeColors.text2)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(width: 270)
            Divider()
            DocumentsDetail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A folder's own folders (each with its disclosure triangle) and documents, any depth, as Files lists them.
private struct DocumentFolderRows: View {
    let parent: UUID?
    @State private var model = DocumentsModel.shared

    var body: some View {
        ForEach(model.index.folders(in: parent)) { folder in
            DisclosureGroup(isExpanded: Binding(get: { model.expanded.contains(folder.id) },
                                                set: { open in
                                                    if open { model.expanded.insert(folder.id) }
                                                    else { model.expanded.remove(folder.id) }
                                                })) {
                DocumentFolderRows(parent: folder.id)
            } label: {
                Label(folder.name, systemImage: "folder")
                    .tag(DocumentsModel.Pick.folder(folder.id))
                    .contextMenu { DocumentsRowMenu(pick: .folder(folder.id)) }
                    .dropDestination(for: String.self) { ids, _ in
                        for id in ids.compactMap(UUID.init(uuidString:)) {
                            let isFolder = model.index.folders.contains { $0.id == id }
                            model.move(isFolder ? .folder(id) : .document(id), to: folder.id)
                        }
                        return true
                    }
                    .draggable(folder.id.uuidString)
            }
        }
        ForEach(model.index.documents(in: parent)) { document in
            HStack {
                Label(document.name, systemImage: Self.symbol(document.kind))
                Spacer(minLength: 4)
                Text(document.type.uppercased()).foregroundStyle(PrepareMeColors.text2)  // two of one name tell apart
            }
                .tag(DocumentsModel.Pick.document(document.id))
                .contextMenu { DocumentsRowMenu(pick: .document(document.id)) }
                .draggable(document.id.uuidString)
                .accessibilityLabel("\(document.name), \(document.type.uppercased())")
        }
    }

    static func symbol(_ kind: DocumentTypes.Kind) -> String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .office: return "doc.text"
        }
    }
}

/// A row's right-click menu: Open, Share…, Print…, AirDrop, Rename…, Move to Folder, then Delete last, in red.
private struct DocumentsRowMenu: View {
    let pick: DocumentsModel.Pick
    @State private var model = DocumentsModel.shared

    var body: some View {
        switch pick {
        case .document(let id):
            if let document = model.index.documents.first(where: { $0.id == id }) {
                Button("Open") { model.pick = pick }
                Divider()
                Button("Share…") { model.send(document, .share) }
                Button("AirDrop…") { model.send(document, .airDrop) }
                Button("Send as Locked PDF…") { model.send(document, .lockedPDF) }.disabled(document.kind == .office)
                Button("Print…") { model.send(document, .print) }.disabled(document.kind == .office)
                Divider()
                Button("Rename…") { model.naming = .rename(pick, document.name) }
                DocumentsMoveMenu(pick: pick)
                Divider()
                PMMenuDelete("Delete…") { model.deleting = pick }
            }
        case .folder(let id):
            if let folder = model.index.folder(id) {
                Button("New Folder Inside…") { model.naming = .newFolder(parent: id) }
                Button("Add Documents Here…") { DocumentsPanels.addDocuments(to: id) }
                Divider()
                Button("Rename…") { model.naming = .rename(pick, folder.name) }
                DocumentsMoveMenu(pick: pick)
                Divider()
                PMMenuDelete("Delete…") { model.deleting = pick }
            }
        case .recentlyDeleted:
            EmptyView()
        }
    }
}

private struct DocumentsMoveMenu: View {
    let pick: DocumentsModel.Pick
    @State private var model = DocumentsModel.shared

    var body: some View {
        Menu("Move to Folder") {
            Button("Top Level") { model.move(pick, to: nil) }
            Divider()
            ForEach(model.folderPaths, id: \.id) { entry in
                Button(entry.path) { model.move(pick, to: entry.id) }
            }
        }
    }
}

private struct DocumentsDetail: View {
    @State private var model = DocumentsModel.shared

    var body: some View {
        switch model.pick {
        case .document:
            if let document = model.picked { DocumentViewer(document: document) } else { placeholder }
        case .recentlyDeleted:
            DocumentsRecentlyDeleted()
        case .folder(let id):
            VStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 36)).foregroundStyle(PrepareMeColors.text2)
                    .accessibilityHidden(true)
                Text(model.index.folder(id)?.name ?? "").font(.pmTitle).foregroundStyle(PrepareMeColors.ink)
                Text(DocumentsWords.documents(model.index.documentCount(inFolder: id)))
                    .foregroundStyle(PrepareMeColors.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        Text("Pick a document to read it.").foregroundStyle(PrepareMeColors.text2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One document: PDFs and photos in Apple's PDF view (zoom, pages, a quarter turn for reading that never changes the
/// stored file), Word, Excel, iWork and text in Quick Look from a sealed copy wiped when it closes.
private struct DocumentViewer: View {
    let document: StoredDocument
    @State private var model = DocumentsModel.shared
    @State private var loaded: Loaded?
    @State private var info = false
    @Environment(\.colorScheme) private var scheme

    enum Loaded { case pdf(PDFDocument), file(URL), failed }

    var body: some View {
        content
            .navigationSubtitle(document.name)  // under the screen's title in the band
            .toolbar {  // the document's buttons in the band (look 3, plan Task 6.2), as they were on its own row
                ToolbarItemGroup(placement: .primaryAction) {
                    if case .pdf = loaded {
                        if model.pdf.pages > 0 {
                            // the room an icon button has inside the band's pill, so its left end matches the right
                            // (owner, 2026-11-14: the words sat against the edge)
                            Text("Page \(model.pdf.page) of \(model.pdf.pages)").fixedSize().padding(.leading, 10)
                        }
                        Button("Rotate Left", systemImage: "rotate.left") { model.pdf.rotate(-90) }
                        Button("Rotate Right", systemImage: "rotate.right") { model.pdf.rotate(90) }
                        Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.pdf.zoomOut() }
                        Button("Zoom In", systemImage: "plus.magnifyingglass") { model.pdf.zoomIn() }
                    }
                    Button("Info", systemImage: "info.circle") { info.toggle() }
                        .popover(isPresented: $info) { DocumentInfo(document: document) }
                    Menu {
                        Button("Share…") { model.send(document, .share) }
                        Button("AirDrop…") { model.send(document, .airDrop) }
                        Button("Send as Locked PDF…") { model.send(document, .lockedPDF) }.disabled(document.kind == .office)
                        Button("Print…") { model.send(document, .print) }.disabled(document.kind == .office)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button("Lock", systemImage: "lock") { model.lock() }
                }
            }
            .task(id: document.id) { await load() }
            .onDisappear { close() }
    }

    @ViewBuilder private var content: some View {
        switch loaded {
        case .pdf(let pdf):
            DocumentPDFView(document: pdf, controller: model.pdf)
                // a slight dim in Dark Mode, as Books does, rather than inverting a scan
                .overlay { if scheme == .dark { Color.black.opacity(0.14).allowsHitTesting(false) } }
                .accessibilityLabel("\(document.name), page \(model.pdf.page) of \(model.pdf.pages)")
        case .file(let url):
            VStack(spacing: 0) {
                DocumentQuickLook(url: url)
                Text(DocumentsWords.quickLookNote).foregroundStyle(PrepareMeColors.text2).padding(8)
            }
        case .failed:
            PMStateScreen {  // look 3's one look, in red: damaged (spec section 10, rules 1 and 3)
                PMState(symbol: "exclamationmark.triangle", heading: DocumentsWords.damagedHeading,
                        line: DocumentsWords.damaged, kind: .damaged)
            }
        case nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        close()
        loaded = nil
        guard case .success(let data) = await model.data(of: document) else {
            loaded = .failed
            return
        }
        if let pdf = DocumentPages.pdf(data, kind: document.kind) {
            loaded = .pdf(pdf)
        } else if document.kind == .office, let url = try? DocumentScratch.copy(data, named: document.fileName) {
            loaded = .file(url)
        } else {
            loaded = .failed
        }
    }

    private func close() {
        if case .file(let url) = loaded { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

private struct DocumentInfo: View {
    let document: StoredDocument
    @State private var model = DocumentsModel.shared

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Type", document.type.uppercased())
            row("Size", ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file))
            row("Added", document.added.formatted(date: .abbreviated, time: .shortened))
            row("Folder", model.path(of: document.folder) ?? "Top level")
            GridRow(alignment: .top) {
                Text("Fingerprint").foregroundStyle(PrepareMeColors.text2)
                Text(document.sha256).font(.pmBody.monospaced()).textSelection(.enabled).frame(width: 300, alignment: .leading)
            }
            GridRow(alignment: .top) {
                Text("Sent").foregroundStyle(PrepareMeColors.text2)
                VStack(alignment: .leading, spacing: 2) {
                    if document.sends.isEmpty { Text("Never: no copy has left PrepareMe.") }
                    ForEach(Array(document.sends.enumerated()), id: \.offset) { _, send in
                        Text(DocumentsWords.sendLine(send))
                    }
                }
            }
        }
        .foregroundStyle(PrepareMeColors.ink)
        .padding(16)
        .frame(width: 440)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(PrepareMeColors.text2)
            Text(value)
        }
    }
}

private struct DocumentsRecentlyDeleted: View {
    @State private var model = DocumentsModel.shared

    var body: some View {
        let deleted = model.index.recentlyDeleted
        VStack(alignment: .leading, spacing: 0) {
            Text("Recently Deleted").font(.pmTitle).foregroundStyle(PrepareMeColors.ink).padding([.horizontal, .top], 16)
            Text("Each item is removed for good \(DocumentIndex.recentlyDeletedDays) days after it was deleted, and a "
                 + "restore never brings it back.")
                .foregroundStyle(PrepareMeColors.text2).padding(.horizontal, 16).padding(.vertical, 6)
            PMList {
                ForEach(deleted.folders) { folder in
                    row(folder.name, symbol: "folder", deleted: folder.deleted, pick: .folder(folder.id))
                }
                ForEach(deleted.documents) { document in
                    row(document.name, symbol: DocumentFolderRows.symbol(document.kind), deleted: document.deleted,
                        pick: .document(document.id))
                }
            }
        }
    }

    private func row(_ name: String, symbol: String, deleted: Date?, pick: DocumentsModel.Pick) -> some View {
        let left = deleted.map { DocumentIndex.recentlyDeletedDays - Int(Date().timeIntervalSince($0) / 86_400) } ?? 0
        return HStack {
            Label(name, systemImage: symbol).foregroundStyle(PrepareMeColors.ink)
            Spacer()
            Text(left == 1 ? "1 day left" : "\(max(left, 0)) days left").foregroundStyle(PrepareMeColors.text2)
            Button("Put Back") { model.putBack(pick) }.pmAction(fullWidth: false)
        }
        .contextMenu { Button("Put Back") { model.putBack(pick) } }  // as the phone's held finger (docs/design/menus.md)
    }
}

// MARK: Apple's viewers

/// Apple's PDF view, in memory only; it reports its page to the controller the menus and the bar use.
private struct DocumentPDFView: NSViewRepresentable {
    let document: PDFDocument
    let controller: DocumentPDFController

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(PrepareMeColors.ground)
        controller.attach(view)
        view.document = document
        controller.pageChanged()
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
            controller.pageChanged()
        }
        controller.attach(view)
    }
}

@MainActor @Observable
final class DocumentPDFController {
    @ObservationIgnored private weak var view: PDFView?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private(set) var page = 1
    private(set) var pages = 0

    var showing: Bool { view?.document != nil }

    func attach(_ view: PDFView) {
        guard self.view !== view else { return }
        self.view = view
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { _ in
            Task { @MainActor in DocumentsModel.shared.pdf.pageChanged() }
        }]
    }

    func pageChanged() {
        guard let view, let document = view.document else { return }
        // Scrolling too, once the pages are laid out: the count follows the page at the top.
        if observers.count == 1, let clip = view.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                    object: clip, queue: .main) { _ in
                Task { @MainActor in DocumentsModel.shared.pdf.pageChanged() }
            })
        }
        // The page at the top of the view, as it reads; PDFKit's currentPage is the one at the middle.
        let top = NSPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY + 1 : view.bounds.maxY - 1)
        let now = (view.page(for: top, nearest: true) ?? view.currentPage).map { document.index(for: $0) + 1 } ?? 1
        if pages != document.pageCount { pages = document.pageCount }
        if page != now { page = now }
    }

    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func actualSize() { view?.scaleFactor = 1 }

    /// Turns every page a quarter turn for reading; the stored file never changes.
    func rotate(_ degrees: Int) {
        guard let view, let document = view.document else { return }
        for number in 0..<document.pageCount {
            guard let page = document.page(at: number) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        view.layoutDocumentView()
    }
}

private struct DocumentQuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

// MARK: Dialogs and panels

/// What a dialog is asking for: a new folder's name, or a new name.
enum DocumentsNaming: Equatable {
    case newFolder(parent: UUID?)
    case rename(DocumentsModel.Pick, String)
}

private struct DocumentsDialogs: ViewModifier {
    @Bindable var model: DocumentsModel
    @State private var name = ""
    @State private var password = ""
    @State private var again = ""

    func body(content: Content) -> some View {
        content
            .alert(model.naming.map(title) ?? "", isPresented: Binding(get: { model.naming != nil },
                                                                      set: { if !$0 { model.naming = nil } })) {
                TextField("Name", text: $name)
                Button(model.naming.map(button) ?? "OK") {
                    switch model.naming {
                    case .newFolder(let parent): model.newFolder(named: name.isEmpty ? "New Folder" : name, in: parent)
                    case .rename(let pick, _): model.rename(pick, to: name)
                    case nil: break
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: model.naming) { _, naming in
                if case .rename(_, let old) = naming { name = old } else { name = "" }
            }
            .alert(deleteTitle, isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } }),
                   presenting: model.deleting) { pick in
                Button("Delete", role: .destructive) { model.delete(pick) }
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            } message: { pick in
                if case .folder(let id) = pick {
                    Text(DocumentsWords.deleteFolderMessage(documents: model.index.documentCount(inFolder: id)))
                } else {
                    Text(DocumentsWords.deleteDocumentMessage)
                }
            }
            .alert(model.confirming.map { DocumentsWords.sendTitle($0.document.name, $0.way) } ?? "",
                   isPresented: Binding(get: { model.confirming != nil }, set: { if !$0 { model.confirming = nil } }),
                   presenting: model.confirming.map(Confirming.init)) { ask in
                switch ask.way {
                case .share:
                    Button("Send as Locked PDF…") { model.confirmed(ask.document, .lockedPDF) }
                        .disabled(ask.document.kind == .office)
                    Button("Share…") { model.confirmed(ask.document, .share) }
                case .airDrop: Button("AirDrop…") { model.confirmed(ask.document, .airDrop) }
                case .print: Button("Print…") { model.confirmed(ask.document, .print) }
                case .lockedPDF: Button("Continue…") { model.confirmed(ask.document, .lockedPDF) }
                }
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            } message: { ask in
                Text(ask.way == .print ? DocumentsWords.printMessage : DocumentsWords.sendMessage)
            }
            .sheet(isPresented: Binding(get: { model.insuranceReport != nil },
                                        set: { if !$0 { model.insuranceReport = nil } })) {
                InsuranceReportSheet(lines: model.insuranceReport ?? []) { model.insuranceReport = nil }
            }
            .sheet(item: Binding(get: { model.askingPassword.map(Confirming.init) },
                                 set: { if $0 == nil { model.askingPassword = nil } })) { ask in
                VStack(alignment: .leading, spacing: 12) {
                    Text(DocumentsWords.sendTitle(ask.document.name, .lockedPDF)).font(.pmHeadline)
                    Text(DocumentsWords.lockedPDFMessage).foregroundStyle(PrepareMeColors.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("Password (8 characters or more)", text: $password)
                    SecureField("The same password again", text: $again)
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { model.askingPassword = nil }.keyboardShortcut(.cancelAction)
                        Button("Make Locked PDF") { model.sendLocked(ask.document, password: password) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(password.count < 8 || password != again)
                    }
                }
                .padding(20)
                .frame(width: 420)
                .onDisappear {
                    password = ""
                    again = ""
                }
            }
    }

    /// A send waiting on its answer, as an item a sheet or an alert can carry.
    struct Confirming: Identifiable {
        let document: StoredDocument
        let way: DocumentSendWay
        var id: UUID { document.id }

        init(_ pair: (document: StoredDocument, way: DocumentSendWay)) {
            document = pair.document
            way = pair.way
        }

        init(_ document: StoredDocument) {
            self.document = document
            way = .lockedPDF
        }
    }

    private var deleteTitle: String {
        switch model.deleting {
        case .folder(let id): return DocumentsWords.deleteFolderTitle(model.index.folder(id)?.name ?? "")
        case .document(let id):
            return DocumentsWords.deleteDocumentTitle(model.index.documents.first { $0.id == id }?.name ?? "")
        default: return ""
        }
    }

    private func title(_ naming: DocumentsNaming) -> String {
        if case .newFolder = naming { return "New Folder" }
        return "Rename"
    }

    private func button(_ naming: DocumentsNaming) -> String {
        if case .newFolder = naming { return "Create" }
        return "Rename"
    }
}

/// The open panels: documents (several at once) or one folder whose contents come in with their folders.
@MainActor
enum DocumentsPanels {
    static func addDocuments(to folder: UUID?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentTypes.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add"
        panel.message = "Each file is kept exactly as it is, locked, on this Mac."
        guard panel.runModal() == .OK else { return }
        DocumentsModel.shared.add(panel.urls, to: folder)
    }

    static func addFolder(to folder: UUID?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = DocumentsWords.addFolderMessage
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DocumentsModel.shared.add([url], to: folder)
    }
}

// MARK: The menu bar

@MainActor
struct DocumentsMenuActions {
    let model: DocumentsModel
    var isOpen: Bool { model.state == .open }
    var picked: StoredDocument? { isOpen ? model.picked : nil }
    var canZoom: Bool { picked.map { $0.kind != .office } ?? false }
}

private struct DocumentsMenuKey: FocusedValueKey { typealias Value = DocumentsMenuActions }

extension FocusedValues {
    var documentsMenu: DocumentsMenuActions? {
        get { self[DocumentsMenuKey.self] }
        set { self[DocumentsMenuKey.self] = newValue }
    }
}

/// The insurance move's report (phase 2): its first line says whether every pair matches, then the counts and each
/// photo's and the PDF's two fingerprints, selectable so the owner can compare or keep them.
private struct InsuranceReportSheet: View {
    let lines: [String]
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(DocumentsWords.insuranceReportTitle).font(.pmHeadline)
            if let first = lines.first {
                Text(first).font(.pmBody.weight(.semibold))
                    .foregroundStyle(first.hasPrefix("Every pair matches") ? PrepareMeColors.ink : PrepareMeColors.red)
            }
            Text(DocumentsWords.insuranceReportNote).foregroundStyle(PrepareMeColors.text2)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(lines.dropFirst().joined(separator: "\n"))
                    .font(.pmBody.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 360)
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760)
    }
}

/// The menu bar's Documents (Apple's menu bar page: every toolbar and right-click item is a menu command too), dimmed
/// when Essential Documents isn't on screen. Keys only where they're free: two items on one key and the dimmed one
/// swallows it (tested 2026-10-24), so Rotate Left is ⇧⌘R (⌘L is the street map's Find Me) and Lock ⌥⌘L. Zoom is
/// View's own ⌘+, ⌘− and ⌘0 (PageZoomCommands) and Print File's ⌘P.
struct DocumentsMenu: Commands {
    @FocusedValue(\.documentsMenu) private var documents

    var body: some Commands {
        CommandMenu("Documents") {
            let open = documents?.isOpen == true
            let picked = documents?.picked
            // one item that reads what it will do (menu bar plan, owner 2026-11-14: two, one always dimmed, until then)
            Button(open ? "Lock" : "Unlock") {
                if open { documents?.model.lock() } else { documents?.model.unlock() }
            }
            .keyboardShortcut("l", modifiers: [.command, .option]).disabled(documents == nil)
            Divider()
            Button("New Folder…") { documents?.model.naming = .newFolder(parent: documents?.model.targetFolder) }
                .disabled(!open)
            Button("Add Documents…") { DocumentsPanels.addDocuments(to: documents?.model.targetFolder) }
                .disabled(!open || documents?.model.busy == true)
            Button(DocumentsWords.addFolder) { DocumentsPanels.addFolder(to: documents?.model.targetFolder) }
                .disabled(!open || documents?.model.busy == true)
            Button(DocumentsWords.bringInsurance) { documents?.model.bringInsurance() }
                .disabled(!open || documents?.model.busy == true)
            Divider()
            Button(documents?.model.hasSpare == true ? DocumentsWords.makeNewSpare : DocumentsWords.makeSpare) {
                documents?.model.startSpare()
            }
            .disabled(!open)
            Button(DocumentsWords.testRestore) { documents?.model.testingRestore = true }.disabled(documents == nil)
            Divider()
            Button("Share…") { picked.map { documents?.model.send($0, .share) } }.disabled(picked == nil)
            Button("AirDrop…") { picked.map { documents?.model.send($0, .airDrop) } }.disabled(picked == nil)
            Button("Send as Locked PDF…") { picked.map { documents?.model.send($0, .lockedPDF) } }
                .disabled(picked == nil || picked?.kind == .office)
            Divider()
            Button("Rotate Left") { documents?.model.pdf.rotate(-90) }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(documents?.canZoom != true)
            Button("Rotate Right") { documents?.model.pdf.rotate(90) }
                .keyboardShortcut("r", modifiers: .command).disabled(documents?.canZoom != true)
            Divider()
            Button("Rename…") { picked.map { documents?.model.naming = .rename(.document($0.id), $0.name) } }
                .disabled(picked == nil)
            Button("Delete…") { picked.map { documents?.model.deleting = .document($0.id) } }.disabled(picked == nil)
        }
    }
}
#endif
