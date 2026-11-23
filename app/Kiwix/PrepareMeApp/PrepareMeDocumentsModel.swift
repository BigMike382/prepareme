#if os(macOS)
import AppKit
import CryptoKit
import LocalAuthentication
import PDFKit
import PrepareMeShared
import SwiftUI
import UniformTypeIdentifiers

/// Essential Documents on the Mac (docs/documents.md; plan 2026-10-24, phase 1): the store's state while the section
/// is locked or open, and every change to it. The household key and the index are held only while it's open; locking
/// drops both and wipes the unlocked copies. Nothing here writes a log.
@MainActor @Observable
final class DocumentsModel {
    static let shared = DocumentsModel()

    enum State: Equatable { case locked, unlocking, open, failed(String) }

    enum Pick: Hashable { case folder(UUID), document(UUID), recentlyDeleted }

    private(set) var state = State.locked
    private(set) var index = DocumentIndex()
    private(set) var busy = false
    var pick: Pick?
    /// The last add's or change's result, in counts only, or a refusal; shown above the list until dismissed.
    var message: String?
    /// The send waiting on its confirmation, after the fresh Touch ID.
    var confirming: (document: StoredDocument, way: DocumentSendWay)?
    var askingPassword: StoredDocument?
    /// The insurance move's report (phase 2), shown until dismissed: counts, item numbers and fingerprints only.
    var insuranceReport: [String]?
    var naming: DocumentsNaming?
    var deleting: Pick?
    /// The folders shown open, kept while the section is open.
    var expanded: Set<UUID> = []
    /// The open PDF or photo's view, for the bar's and the menus' zoom and rotate.
    let pdf = DocumentPDFController()

    @ObservationIgnored private var store: DocumentStore?
    @ObservationIgnored private var lastActive = Date()
    @ObservationIgnored var visible = false {
        didSet {
            if visible, state == .open, DocumentsWords.shouldLock(lastActive: lastActive, now: Date()) { lock() }
            lastActive = Date()
        }
    }
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var sender: DocumentSender?

    var root: URL? {
        PrepareMeHome.url?.appendingPathComponent("Library/Application Support/PrepareMe/documents", isDirectory: true)
    }

    var idleLock: TimeInterval {
        #if PREPAREME_CHECK
        // the check build only: PREPAREME_CHECK_DOCUMENTS_IDLE=seconds, so the idle lock can be seen without waiting
        if let seconds = ProcessInfo.processInfo.environment["PREPAREME_CHECK_DOCUMENTS_IDLE"].flatMap(Double.init) {
            return seconds
        }
        #endif
        return DocumentsWords.idleLock
    }

    // MARK: Locking

    func unlock() {
        guard state != .unlocking, state != .open, let root else { return }
        state = .unlocking
        watch()
        Task.detached {
            let result = Self.openKey(root)
            await MainActor.run { self.opened(result, root: root) }
        }
    }

    private nonisolated static func hasKey(_ root: URL) -> Bool {
        #if PREPAREME_CHECK
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_DOCUMENTS"] == "open" {
            return FileManager.default.fileExists(atPath: root.appendingPathComponent("check.key").path)
        }
        #endif
        return DocumentKey.exists(in: root)
    }

    private nonisolated static func openKey(_ root: URL, reason: String = DocumentsWords.unlockReason)
        -> Result<SymmetricKey, Error> {
        let context = LAContext()
        context.localizedReason = reason
        #if PREPAREME_CHECK
        // the check build only: PREPAREME_CHECK_DOCUMENTS=open opens with a check key made without the presence check,
        // in the check folder, so screens can be shot with no one at the sensor (never compiled into a real build)
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_DOCUMENTS"] == "open" {
            return Result { try CheckKey.open(root) }
        }
        #endif
        return Result {
            DocumentKey.exists(in: root) ? try DocumentKey.open(in: root, context: context)
                : try DocumentKey.create(in: root, context: context)
        }
    }

    private func opened(_ result: Result<SymmetricKey, Error>, root: URL) {
        switch result {
        case .success(let key):
            let store = DocumentStore(root: root, key: key)
            do {
                var index = try store.load()
                let gone = index.purgeExpired()
                if !gone.isEmpty {
                    try store.save(index)
                    store.remove(files: gone)
                }
                self.store = store
                self.index = index
                state = .open
                lastActive = Date()
                DocumentScratch.wipe()
                relist()
                // after the first Bring In the Insurance Record, every unlock brings in what's new (owner, 2026-10-24)
                if index.brought?[InsuranceMove.recordKey] != nil { moveInsurance(report: false) }
                takePhoneChanges()
            } catch {
                state = .failed(DocumentsWords.cantRead)
            }
        case .failure(let error):
            // stays locked, with Unlock still there to try again; a cancel says nothing
            let error = error as NSError
            let cancels = [LAError.userCancel, .appCancel, .systemCancel].map(\.rawValue)
            if (error as Error as? DocumentKey.Failure) == .noSecureEnclave {
                state = .failed(DocumentsWords.noSecureEnclave)
            } else if error.domain == LAErrorDomain {
                state = .locked
                message = cancels.contains(error.code) ? nil : DocumentsWords.notUnlocked
            } else {
                state = .locked
                message = DocumentsWords.cantOpenKey
            }
        }
    }

    func lock() {
        store = nil
        index = DocumentIndex()
        pick = nil
        confirming = nil
        askingPassword = nil
        naming = nil
        deleting = nil
        insuranceReport = nil
        expanded = []
        message = nil
        if state != .unlocking { state = .locked }
        DocumentScratch.wipe()
    }

    /// Any key, click or scroll in the section counts as a touch.
    func touch() { if visible { lastActive = Date() } }

    /// Locks on hide, screen lock, sleep and switching users, and after the idle time on another screen or untouched.
    private func watch() {
        guard !watching else { return }
        watching = true
        let lockNow: @Sendable (Notification) -> Void = { _ in Task { @MainActor in DocumentsModel.shared.lock() } }
        NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main,
                                               using: lockNow)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: lockNow)
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main, using: lockNow)
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .magnify]) {
            DocumentsModel.shared.touch()
            return $0
        }
        Task { @MainActor in
            var ticks = 0
            while true {
                try? await Task.sleep(for: .seconds(5))
                let model = DocumentsModel.shared
                if model.state == .open, Date().timeIntervalSince(model.lastActive) >= model.idleLock { model.lock() }
                ticks += 1
                if ticks % 6 == 0 { model.takePhoneChanges() }  // the adults' phones' changes, every half minute
            }
        }
    }

    // MARK: Changes

    private func change(_ edit: (inout DocumentIndex) -> Void) {
        guard let store else { return }
        guard !busy else {  // an add or the insurance move saves its own copy of the index when it's done
            message = DocumentsWords.waitForAdd
            return
        }
        var next = index
        edit(&next)
        do {
            try store.save(next)
            index = next
            relist()
        } catch {
            message = DocumentsWords.cantRead
        }
    }

    func newFolder(named name: String, in parent: UUID?) {
        var made: UUID?
        change { made = $0.newFolder(name, in: parent) }
        if let made { pick = .folder(made) }
    }

    func rename(_ pick: Pick, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch pick {
        case .folder(let id): change { $0.rename(folder: id, to: name) }
        case .document(let id): change { $0.rename(document: id, to: name) }
        case .recentlyDeleted: break
        }
    }

    func move(_ pick: Pick, to folder: UUID?) {
        switch pick {
        case .folder(let id):
            var moved = true
            change { moved = $0.move(folder: id, to: folder) }
            if !moved { message = "A folder can't go inside itself." }
        case .document(let id): change { $0.move(document: id, to: folder) }
        case .recentlyDeleted: break
        }
    }

    func delete(_ pick: Pick) {
        switch pick {
        case .folder(let id): change { $0.delete(folder: id) }
        case .document(let id): change { $0.delete(document: id) }
        case .recentlyDeleted: return
        }
        self.pick = nil
    }

    func putBack(_ pick: Pick) {
        switch pick {
        case .folder(let id): change { $0.putBack(folder: id) }
        case .document(let id): change { $0.putBack(document: id) }
        case .recentlyDeleted: break
        }
    }

    /// The folder a new document goes into: the picked folder, or the picked document's.
    var targetFolder: UUID? {
        switch pick {
        case .folder(let id): return id
        case .document(let id): return index.documents.first { $0.id == id }?.folder
        default: return nil
        }
    }

    /// A folder's place, "Insurance › Auto", for Info and Move to Folder.
    func path(of folder: UUID?) -> String? {
        var names: [String] = []
        var current = folder
        while let id = current, let found = index.folder(id), names.count < 64 {
            names.insert(found.name, at: 0)
            current = found.parent
        }
        return names.isEmpty ? nil : names.joined(separator: " › ")
    }

    /// Every folder not in Recently Deleted, by place, for Move to Folder.
    var folderPaths: [(id: UUID, path: String)] {
        index.folders.filter { !index.isDeleted(folder: $0.id) }
            .compactMap { folder in path(of: folder.id).map { (folder.id, $0) } }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var picked: StoredDocument? {
        guard case .document(let id) = pick else { return nil }
        return index.documents.first { $0.id == id && !index.isDeleted($0) }
    }

    // MARK: The insurance move (phase 2)

    /// Bring In the Insurance Record…: whatever isn't here yet, then the report.
    func bringInsurance() { moveInsurance(report: true) }

    /// Reads the inventory (never writes it) and its insurance PDF, brings in what's new, and with `report` checks every
    /// copy against its original. Off the main thread, holding `busy` as an add does.
    private func moveInsurance(report: Bool) {
        guard let store, !busy, let inventory = InventoryModel.fileURL else { return }
        busy = true
        let start = index
        let pdf = InventoryModel.folder?.appendingPathComponent(InsurancePDF.fileName)
        Task.detached {
            let outcome = Self.runMove(store, start, inventory: inventory, pdf: pdf, report: report)
            await MainActor.run { self.moved(outcome, report: report) }
        }
    }

    private struct Moved: Sendable {
        var index: DocumentIndex?
        var brought = InsuranceMove.Brought()
        var lines: [String]?
        var problem: String?
    }

    private nonisolated static func runMove(_ store: DocumentStore, _ start: DocumentIndex, inventory: URL, pdf: URL?,
                                            report: Bool) -> Moved {
        func read() -> InsuranceMove.Source? {
            let data = pdf.flatMap { try? Data(contentsOf: $0) }
            return (try? InventoryFile(url: inventory, readOnly: true)).flatMap { try? InsuranceMove.source($0, pdf: data) }
        }
        guard FileManager.default.fileExists(atPath: inventory.path), let before = read() else {
            return Moved(problem: DocumentsWords.noInventory)
        }
        guard before.started || !before.items.isEmpty else {
            return Moved(lines: report ? [DocumentsWords.noInsuranceRecord] : nil)
        }
        var index = start
        let (brought, old) = InsuranceMove.bring(before, store: store, index: &index)
        guard (try? store.save(index)) != nil else { return Moved(problem: DocumentsWords.cantRead) }
        store.remove(files: old)
        guard report else { return Moved(index: index, brought: brought) }
        guard let after = read() else { return Moved(index: index, brought: brought, problem: DocumentsWords.noInventory) }
        return Moved(index: index, brought: brought,
                     lines: InsuranceMove.lines(InsuranceMove.report(before, after: after, store: store, index: index)))
    }

    private func moved(_ outcome: Moved, report: Bool) {
        busy = false
        relist()
        guard store != nil else { return }  // locked while it ran: the next unlock reads what was saved
        if let next = outcome.index { index = next }
        if report, let lines = outcome.lines {
            insuranceReport = lines
        } else if let line = outcome.problem ?? DocumentsWords.broughtLine(outcome.brought) {
            message = line
        }
    }

    /// Files and folders from the open panel, a drop or Continuity Camera: each file checked against its stored copy,
    /// each folder's folders kept (ruling A). Off the main thread; the result in counts only.
    func add(_ urls: [URL], to folder: UUID?) {
        guard let store, !urls.isEmpty else { return }
        guard !busy else {
            message = DocumentsWords.waitForAdd
            return
        }
        busy = true
        let start = index
        Task.detached {
            var index = start
            var report = DocumentImportReport()
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if values?.isDirectory == true && values?.isPackage != true {
                    let more = store.addFolder(url, to: folder, in: &index)
                    report.added += more.added
                    report.foldersMade += more.foldersMade
                    report.alreadyHere += more.alreadyHere
                    report.refused.merge(more.refused, uniquingKeysWith: +)
                } else {
                    do {
                        try store.add(url, to: folder, in: &index)
                        report.added += 1
                    } catch {
                        report.refused[error as? DocumentRefusal ?? .unreadable, default: 0] += 1
                    }
                }
            }
            let saved = (try? store.save(index)) != nil
            await MainActor.run { self.added(index, report: report, saved: saved, single: urls.count == 1) }
        }
    }

    private func added(_ next: DocumentIndex, report: DocumentImportReport, saved: Bool, single: Bool) {
        busy = false
        relist()
        guard store != nil else { return }  // locked while it ran: the next unlock reads what was saved
        guard saved else {
            message = DocumentsWords.cantRead
            return
        }
        let new = next.documents.filter { doc in !index.documents.contains { $0.id == doc.id } }
        index = next
        if single, report.added == 1, let doc = new.first {
            pick = .document(doc.id)
            message = nil
        } else if single, report.added == 0, report.foldersMade == 0, report.alreadyHere == 0,
                  let reason = report.refused.keys.first {
            message = DocumentsWords.refused(reason)
        } else {
            message = DocumentsWords.report(report)
        }
    }

    /// Continuity Camera's scans and photos (File › Import from iPhone or iPad): each written to a sealed scratch
    /// copy just long enough to be stored, then wiped. A scan has no original, so its fingerprint starts here.
    func addScanned(_ providers: [NSItemProvider]) -> Bool {
        guard store != nil else { return false }
        let folder = targetFolder
        let copies = providers.map(Self.scratchCopy)  // started here, before the import call returns
        Task {
            var urls: [URL] = []
            for copy in copies {
                if let url = await copy.value { urls.append(url) }
            }
            guard !urls.isEmpty else {
                message = DocumentsWords.scanNotReceived
                return
            }
            add(urls, to: folder)
        }
        return true
    }

    /// Starts reading one scan or photo at once: read later, after the import call had returned, the owner's first
    /// real scan failed (NSItemProviderErrorDomain -1000, 2026-10-25).
    private static func scratchCopy(_ provider: NSItemProvider) -> Task<URL?, Never> {
        let types: [(UTType, String)] = [(.pdf, "pdf"), (.heic, "heic"), (.jpeg, "jpeg"), (.png, "png"), (.tiff, "tiff")]
        guard let (type, ext) = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.0.identifier) })
        else { return Task { nil } }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        let name = (type == .pdf ? "Scan " : "Photo ") + stamp + "." + ext
        let (done, finish) = AsyncStream<URL?>.makeStream()
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            finish.yield(data.flatMap { try? DocumentScratch.copy($0, named: name) })
            finish.finish()
        }
        return Task {
            for await url in done { return url }
            return nil
        }
    }

    // MARK: The adults' phones (phase 3)

    /// The list the phones' service serves (DocumentList), written again after every change to the store and at each
    /// look of the Mac's (PrepareMeMac.check): no key needed, since it names only encrypted files. Then the iCloud copy
    /// from it (phase 4). One at a time, off the main thread.
    func relist() {
        guard let root else { return }
        let backup = backupFolder
        let store = store
        Task {
            await Self.lister.refresh(root, backup: backup, store: store)
            refreshBackup()
        }
    }

    private static let lister = DocumentLister()

    /// The adults' phones' changes waiting in the service's inbox (DocumentInbox), applied with the key: at unlock and
    /// every half minute while open. Off the main thread, holding `busy` as an add does.
    func takePhoneChanges() {
        guard let store, let root, !busy, state == .open, DocumentInbox.waitingOutboxes(root: root) > 0 else { return }
        busy = true
        let start = index
        Task.detached {
            var index = start
            let (result, done) = DocumentInbox.apply(store: store, index: &index)
            let saved = index == start || (try? store.save(index)) != nil
            if saved { DocumentInbox.tidy(done, inbox: root.appendingPathComponent(DocumentInbox.folderName)) }
            await MainActor.run { self.tookPhoneChanges(saved ? index : nil, result) }
        }
    }

    private func tookPhoneChanges(_ next: DocumentIndex?, _ result: DocumentInbox.Result) {
        busy = false
        relist()
        guard store != nil else { return }  // locked while it ran: the next unlock reads what was saved
        guard let next else {
            message = DocumentsWords.cantRead
            return
        }
        index = next
        if let line = DocumentsWords.phoneChanges(result) { message = line }
    }

    /// Settings › Phones' Give It Essential Documents… (owner, 2026-10-24: the owner approves each phone): Touch ID or
    /// the password first, then the household key sealed to the lock that phone asked with, kept for the service to
    /// hand it (DocumentHandoff). Nil when it was given, else why not.
    func give(_ phone: PairingDesk.Phone, ask: DocumentHandoff.Request, pairing folder: URL) async -> String? {
        // never makes the key: a Mac with no Essential Documents yet has nothing to give
        guard let root, Self.hasKey(root) else { return DocumentsWords.cantOpenKey }
        let key: SymmetricKey
        switch await Task.detached(operation: { Self.openKey(root, reason: DocumentsWords.giveReason) }).value {
        case .success(let opened):
            key = opened
        case .failure(let error):
            let error = error as NSError
            let cancels = [LAError.userCancel, .appCancel, .systemCancel].map(\.rawValue)
            return error.domain == LAErrorDomain && cancels.contains(error.code) ? nil : DocumentsWords.cantOpenKey
        }
        do {
            let url = folder.appendingPathComponent(DocumentHandoff.giftsName)
            var all = DocumentHandoff.readGifts(try? Data(contentsOf: url))
            all[phone.label] = try DocumentHandoff.seal(key, for: ask, label: phone.label, paired: phone.added)
            try DurableFile.write(DocumentHandoff.encoded(all), to: url)
            relist()  // the list it will be served, current
            return nil
        } catch {
            return DocumentsWords.cantGive
        }
    }

    // MARK: Backups and restore (phase 4)

    /// Household Private › Backups › Documents: the iCloud copy (DocumentBackup), still encrypted.
    var backupFolder: URL? {
        PrepareMeHome.url?.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/Household Private/Backups/Documents", isDirectory: true)
    }

    private(set) var hasSpare = false
    private(set) var backupStatus: DocumentBackup.Status?
    private(set) var restoreRecord: DocumentRestoreTest.Record?
    /// The recovery password being made: shown once, then pasted back from Passwords before the spare is written.
    var spareDraft: String?
    /// Use the Recovery Password…'s sheet, from the locked screen.
    var recovering = false
    /// Documents › Test a Restore…'s sheet (Settings › Backups keeps its own).
    var testingRestore = false

    /// Whether this Mac's store holds the spare, and the last copy's and Test a restore's results, for the screens.
    func refreshBackup() {
        guard let root else { return }
        hasSpare = DocumentSpare.read(in: root) != nil
        backupStatus = DocumentBackup.readStatus(in: root)
        restoreRecord = DocumentRestoreTest.read(in: root)
    }

    func startSpare() {
        guard state == .open else { return }
        spareDraft = DocumentSpare.newPassword()
    }

    /// Writes the spare once the pasted-back password matches the one shown; false (nothing written) when it doesn't.
    func saveSpare(pasted: String) -> Bool {
        guard let store, let draft = spareDraft else { return false }
        guard DocumentSpare.normalized(pasted) == DocumentSpare.normalized(draft) else { return false }
        spareDraft = nil
        do {
            try store.writeSpare(password: draft)
            message = DocumentsWords.spareMade
        } catch {
            message = DocumentsWords.cantRead
        }
        relist()  // the iCloud copy can start now
        return true
    }

    /// The password onto this Mac's clipboard only (never Universal Clipboard), marked for clipboard managers to skip,
    /// and taken off again after 2 minutes unless something else was copied since.
    func copySpare() {
        guard let draft = spareDraft else { return }
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(draft, forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        Task {
            try? await Task.sleep(for: .seconds(120))
            if board.string(forType: .string) == draft { board.clearContents() }
        }
    }

    /// Use the Recovery Password… (a new Mac, or a key file that won't open): the spare opened with it, then the key
    /// sealed to this Mac's own Secure Enclave, which asks once, and the section opens.
    func recover(password: String) {
        guard let root, state != .unlocking, let spare = DocumentSpare.read(in: root) else { return }
        guard let key = try? spare.open(password: password) else {
            message = DocumentsWords.recoverWrong
            return
        }
        recovering = false
        message = nil
        state = .unlocking
        watch()
        Task.detached {
            let result = Result { () throws -> SymmetricKey in
                try Self.adopt(key, root)
                return key
            }
            await MainActor.run { self.opened(result, root: root) }
        }
    }

    private nonisolated static func adopt(_ key: SymmetricKey, _ root: URL) throws {
        #if PREPAREME_CHECK
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_DOCUMENTS"] == "open" { return try CheckKey.adopt(key, root) }
        #endif
        let context = LAContext()
        context.localizedReason = DocumentsWords.recoverReason
        try DocumentKey.adopt(key, in: root, context: context)
    }

    /// Test a Restore…: the copy at `copy` opened with the password alone, every document read back; the result
    /// recorded beside this Mac's store (counts only) and returned as its line. The store needn't be open.
    func testRestore(_ copy: URL, iCloud: Bool, password: String) async -> String {
        let scoped = copy.startAccessingSecurityScopedResource()
        let result = await Task.detached { DocumentRestoreTest.run(copy: copy, password: password) }.value
        if scoped { copy.stopAccessingSecurityScopedResource() }
        if let root { DocumentRestoreTest.record(result, from: iCloud ? "iCloud" : "folder", in: root) }
        refreshBackup()
        return DocumentsWords.restoreLine(result, from: iCloud ? "iCloud copy" : "copy")
    }

    // MARK: Opening

    func data(of document: StoredDocument) async -> Result<Data, Error> {
        guard let store else { return .failure(DocumentCipher.Failure.damaged) }
        return await Task.detached { Result { try store.data(of: document) } }.value
    }

    // MARK: Sending (print, AirDrop, share, locked PDF)

    /// A fresh Touch ID or password first, even with the section open, then the confirmation (default Cancel).
    func send(_ document: StoredDocument, _ way: DocumentSendWay) {
        guard state == .open else { return }
        if way == .print, document.kind == .office {
            message = DocumentsWords.noPrint
            return
        }
        Task {
            guard await Self.freshCheck() else { return }
            confirming = (document, way)
        }
    }

    private static func freshCheck() async -> Bool {
        #if PREPAREME_CHECK
        if ProcessInfo.processInfo.environment["PREPAREME_CHECK_DOCUMENTS"] == "open" { return true }
        #endif
        return (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: DocumentsWords.sendReason)) ?? false
    }

    /// After the owner confirmed: print straight from memory; AirDrop or the share picker from a sealed scratch copy
    /// wiped when it's done; a locked PDF after its password.
    func confirmed(_ document: StoredDocument, _ way: DocumentSendWay) {
        confirming = nil
        if way == .lockedPDF {
            askingPassword = document
            return
        }
        Task {
            guard case .success(let data) = await data(of: document) else {
                message = DocumentsWords.damaged
                return
            }
            switch way {
            case .print:
                guard let pdf = DocumentPages.pdf(data, kind: document.kind),
                      let operation = pdf.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit,
                                                         autoRotate: true) else { return }
                operation.jobTitle = document.name
                if operation.run() { recordSend(document, .print) }
            case .airDrop, .share:
                guard let url = try? DocumentScratch.copy(data, named: document.fileName) else { return }
                share(url, document: document, way: way)
            case .lockedPDF:
                break
            }
        }
    }

    func sendLocked(_ document: StoredDocument, password: String) {
        askingPassword = nil
        Task {
            guard case .success(let data) = await data(of: document),
                  let pdf = DocumentPages.pdf(data, kind: document.kind) else {
                message = DocumentsWords.damaged
                return
            }
            let folder = DocumentScratch.folder().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent(document.name + ".pdf")
            let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password,
                                                          .ownerPasswordOption: UUID().uuidString]
            guard pdf.write(to: url, withOptions: options) else { return }
            share(url, document: document, way: .lockedPDF)
        }
    }

    private func share(_ url: URL, document: StoredDocument, way: DocumentSendWay) {
        let sender = DocumentSender(url: url) { [weak self] sent in
            if sent { self?.recordSend(document, way) }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            self?.sender = nil
        }
        self.sender = sender
        if way == .airDrop { sender.airDrop() } else { sender.pick() }
    }

    private func recordSend(_ document: StoredDocument, _ way: DocumentSendWay) {
        let device = Host.current().localizedName ?? "This Mac"
        change { $0.recordSend(DocumentSend(date: Date(), device: device, how: way.rawValue), for: document.id) }
    }
}

/// Writes the store's list for the phones' service, then the iCloud copy from it, one at a time.
actor DocumentLister {
    /// `store`, while unlocked, stamps the list with what only it knows (audit G2), read from the index as saved: some
    /// callers relist before their model holds the new index.
    func refresh(_ root: URL, backup: URL?, store: DocumentStore?) {
        let stamp = store.flatMap { store in (try? store.load()).map { (store.keyID, $0.removedFiles ?? []) } }
        let list = (try? DocumentList.refresh(root: root, stamp: stamp)) ?? nil
        guard let backup, list != nil else { return }  // no store yet: nothing to copy, and nothing to say
        DocumentBackup.writeStatus(DocumentBackup.copy(from: root, to: backup, list: list), in: root)
    }
}

/// One send's AirDrop or share picker, holding the scratch copy until the service is done with it. The picker
/// leaves out what would copy it on without a send: Copy, Add to Photos, Assign to Contact, Add to Reading List.
@MainActor
final class DocumentSender: NSObject, @preconcurrency NSSharingServicePickerDelegate,
                            @preconcurrency NSSharingServiceDelegate {
    let url: URL
    let done: (Bool) -> Void
    private var finished = false

    init(url: URL, done: @escaping (Bool) -> Void) {
        self.url = url
        self.done = done
    }

    func airDrop() {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else {
            finish(false)
            return
        }
        service.delegate = self
        service.perform(withItems: [url])
    }

    func pick() {
        guard let window = NSApp.keyWindow, let view = window.contentView else {
            finish(false)
            return
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = self
        let anchor = NSRect(x: view.bounds.maxX - 120, y: view.bounds.maxY - 40, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    // shortcut: matches the services' English titles (this Mac's language); a Mac in another language would show them
    static let leftOut = ["copy", "photos", "contact", "reading list"]

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              sharingServicesForItems items: [Any],
                              proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        proposedServices.filter { service in !Self.leftOut.contains { service.title.lowercased().contains($0) } }
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil { finish(false) }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish(true) }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        finish(false)
    }

    private func finish(_ sent: Bool) {
        guard !finished else { return }
        finished = true
        done(sent)
    }
}

/// A PDF or photo as PDF pages, in memory only: a photo's every frame (a scanner's TIFF can hold several) a page.
enum DocumentPages {
    nonisolated static func pdf(_ data: Data, kind: DocumentTypes.Kind) -> PDFDocument? {
        switch kind {
        case .pdf:
            return PDFDocument(data: data)
        case .image:
            let pdf = PDFDocument()
            for rep in NSBitmapImageRep.imageReps(with: data) {
                let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
                image.addRepresentation(rep)
                if let page = PDFPage(image: image) { pdf.insert(page, at: pdf.pageCount) }
            }
            return pdf.pageCount > 0 ? pdf : nil
        case .office:
            return nil
        }
    }
}

#if PREPAREME_CHECK
/// The check build's own key (never compiled into a real build): a Secure Enclave key without the presence check, in
/// the check folder, so a session's screenshots can show the open section with no one at the sensor.
enum CheckKey {
    nonisolated static func open(_ root: URL) throws -> SymmetricKey {
        let url = root.appendingPathComponent("check.key")
        if let data = try? Data(contentsOf: url) {
            let file = try JSONDecoder().decode(DocumentKeyFile.self, from: data)
            let lock = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: file.lock)
            return try file.open { try lock.sharedSecretFromKeyAgreement(with: $0) }
        }
        let lock = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        let key = SymmetricKey(size: .bits256)
        try DocumentStore.prepare(root)
        try DurableFile.write(JSONEncoder().encode(DocumentKeyFile.seal(key, to: lock.publicKey,
                                                                        lockData: lock.dataRepresentation)), to: url)
        return key
    }

    /// The spare's key kept as the check key, as DocumentKey.adopt keeps it as this Mac's.
    nonisolated static func adopt(_ key: SymmetricKey, _ root: URL) throws {
        let lock = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        try DocumentStore.prepare(root)
        try DurableFile.write(JSONEncoder().encode(DocumentKeyFile.seal(key, to: lock.publicKey,
                                                                        lockData: lock.dataRepresentation)),
                              to: root.appendingPathComponent("check.key"))
    }
}
#endif
#endif
