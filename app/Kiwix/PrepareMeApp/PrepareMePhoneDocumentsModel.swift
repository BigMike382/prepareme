#if os(iOS)
import CryptoKit
import Foundation
import LocalAuthentication
import PDFKit
import PrepareMeShared
import UIKit

/// Essential Documents on an adult's phone or iPad (docs/documents.md, "The phones"; plan 2026-10-24, phase 3): the
/// Mac's store mirrored over home Wi-Fi once the owner has given this device the key, opened with this device's own
/// Face ID, Touch ID or passcode, and this device's own changes kept encrypted until the Mac applies them. The key and
/// the index are held only while it's open; locking drops both and wipes the unlocked copies. Nothing here writes a
/// log. A child's phone never asks and the service never answers one (owner, 2026-10-24).
@MainActor @Observable
final class PhoneDocumentsModel {
    static let shared = PhoneDocumentsModel()

    enum State: Equatable { case locked, unlocking, open, failed(String) }

    private(set) var state = State.locked
    /// The Mac's index with this device's waiting changes on top.
    private(set) var index = DocumentIndex()
    private(set) var waiting = 0 { didSet { countOnlyHere() } }
    /// Documents added here the Mac hasn't taken yet (audit D5): they exist only on this device, out of its backup by
    /// the owner's ruling, so the list says so. From the plain waiting list (`DocumentOutbox.Ledger`), locked or open.
    private(set) var onlyHere = 0
    /// Files the Mac last listed that aren't on this device yet: the amber banner and Today's line.
    private(set) var missing = 0
    /// Why the Mac's last list was refused (audit G2: DocumentMirror.judge), so this device kept its own copy.
    private(set) var refused: DocumentMirror.Refusal?
    /// This device's key's fingerprint, known only while open: tells a list under another key apart.
    private(set) var ownKeyID: String?
    /// "Use the Mac's Copy…" waiting on its confirmation.
    var confirmingMacsCopy = false
    private(set) var given = false
    /// The Mac's index has come at least once.
    private(set) var mirrored = false
    private(set) var asked = false
    /// An adult's phone (MacLink.canEdit): only these have the Documents tab.
    private(set) var adult = MacLink.canEdit == true
    private(set) var busy = false
    var message: String?
    var naming: PhoneDocumentsNaming?
    var deleting: PhoneDocumentsTarget?
    var moving: PhoneDocumentsTarget?
    /// The send waiting on its confirmation, after the fresh Face ID.
    var confirming: (document: StoredDocument, way: DocumentSendWay)?
    var askingPassword: StoredDocument?
    var sharing: PhoneDocumentsShare?
    /// Where Documents is: folders and a document, back to the top when it locks.
    var path: [PhoneDocumentsRoute] = []

    @ObservationIgnored private var store: DocumentStore?
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var changes: [DocumentChange] = []
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var lastActive = Date()
    @ObservationIgnored private let desk = PhoneDocumentsDesk()

    static let root: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("PrepareMe/documents", isDirectory: true)

    private init() {
        refreshStanding()
        Task { @MainActor in  // the idle lock (design: "after 2 minutes")
            while true {
                try? await Task.sleep(for: .seconds(5))
                let model = PhoneDocumentsModel.shared
                if model.state == .open, DocumentsWords.shouldLock(lastActive: model.lastActive, now: Date()) {
                    model.lock()
                }
            }
        }
    }

    /// A touch, a scroll or an action in Documents: the idle lock starts again.
    func touched() { lastActive = Date() }

    /// Documents back on screen: locked first if it sat idle past the limit.
    func shown() {
        if state == .open, DocumentsWords.shouldLock(lastActive: lastActive, now: Date()) { lock() }
        lastActive = Date()
    }

    // MARK: Locking

    func unlock() {
        guard state != .unlocking, state != .open, given, let root = Self.root else { return }
        state = .unlocking
        message = nil
        Task.detached {
            let result = Self.openKey(root)
            await MainActor.run { self.opened(result, root: root) }
        }
    }

    /// This device's key; the first unlock after the owner's Give opens the Mac's gift with the lock this device asked
    /// with and keeps it as this device's household key (DocumentKey.receive).
    private nonisolated static func openKey(_ root: URL) -> Result<SymmetricKey, Error> {
        let context = LAContext()
        context.localizedReason = DocumentsWords.unlockReason
        return Result {
            if !DocumentKey.exists(in: root) {
                let served: DocumentHandoff.Served = try DocumentKey.read(incomingURL(root))
                let key = try DocumentKey.receive(served, in: root, context: context)
                try? FileManager.default.removeItem(at: incomingURL(root))
                return key
            }
            return try DocumentKey.open(in: root, context: context)
        }
    }

    private func opened(_ result: Result<SymmetricKey, Error>, root: URL) {
        switch result {
        case .success(let key):
            store = DocumentStore(root: root, key: key)
            self.key = key
            ownKeyID = DocumentSpare.keyID(key)
            state = .open
            lastActive = Date()
            DocumentScratch.wipe()
            refreshStanding()
            Task { await load() }
        case .failure(let failure):
            let error = failure as NSError
            let cancels = [LAError.userCancel, .appCancel, .systemCancel].map(\.rawValue)
            state = .locked
            if failure as? DocumentKey.Failure == .broken {
                // the key file, else the gift it would have come from: aside, and asked for again at home
                let file = DocumentKey.exists(in: root) ? DocumentKey.url(in: root) : Self.incomingURL(root)
                message = (try? DocumentKey.setAside(file, in: root)) != nil ? DocumentsWords.phoneKeySetAside
                    : DocumentsWords.phoneCantOpenKey
                refreshStanding()
            } else if error.domain == LAErrorDomain {
                message = cancels.contains(error.code) ? nil : DocumentsWords.notUnlocked
            } else {
                // the simulator's stand-in lock cancels as CocoaError (DocumentKey.Lock)
                message = (failure as? CocoaError)?.code == .userCancelled ? nil : DocumentsWords.phoneCantOpenKey
            }
        }
    }

    /// The Mac's index with this device's changes the Mac hasn't applied yet on top; the applied ones are dropped.
    private func load() async {
        guard let store, let key, let root = Self.root else { return }
        do {
            let mac = try store.load()
            let waiting = try await desk.settle(against: mac, root: root, key: key)
            guard self.store != nil else { return }  // locked meanwhile
            changes = waiting
            index = mac.overlaid(waiting)
            self.waiting = waiting.count
        } catch {
            lock()
            state = .failed(DocumentsWords.cantRead)
        }
    }

    func lock() {
        store = nil
        key = nil
        ownKeyID = nil
        confirmingMacsCopy = false
        changes = []
        index = DocumentIndex()
        if state != .unlocking { state = .locked }
        naming = nil
        deleting = nil
        moving = nil
        confirming = nil
        askingPassword = nil
        sharing = nil
        path = []
        DocumentScratch.wipe()
    }

    /// Whether the Mac has given this device the key (kept, or waiting for its first unlock), whether it has asked, and
    /// how many listed files aren't here. Read again after each check; while the device is locked the files can't be
    /// read (complete protection), so nothing changes then.
    func refreshStanding() {
        adult = MacLink.canEdit == true
        guard let root = Self.root, FileManager.default.isReadableFile(atPath: root.path) else { return }
        given = DocumentKey.exists(in: root) || FileManager.default.fileExists(atPath: Self.incomingURL(root).path)
        asked = DocumentKey.asked(in: root)
        mirrored = FileManager.default.fileExists(atPath: root.appendingPathComponent(DocumentList.indexName).path)
        missing = Self.missing(root)
        refused = DocumentMirror.held(in: root).refused
        if store == nil { waiting = DocumentOutbox.Ledger.read(in: root).changes.count }
        countOnlyHere()
    }

    private func countOnlyHere() {
        onlyHere = Self.root.map { DocumentOutbox.Ledger.read(in: $0).files.count } ?? 0
    }

    nonisolated static func incomingURL(_ root: URL) -> URL { root.appendingPathComponent("key.incoming") }

    nonisolated static func missing(_ root: URL) -> Int {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(DocumentList.fileName)),
              let list = try? DocumentList.read(data) else { return 0 }
        let standing = DocumentMirror.standing(list, held: DocumentMirror.held(in: root), root: root)
        return standing.all - standing.matching
    }

    /// The owner's way out of a refusal (audit G2, owner's choice A, 2026-11-22): the next check takes the Mac's list,
    /// removing what's only here. Offered only while open and only for a list under this device's own key.
    func useMacsCopy() {
        confirmingMacsCopy = false
        guard let refused, let keyID = refused.keyID, DocumentsWords.offersMacsCopy(refused, ownKeyID: ownKeyID),
              let root = Self.root else { return }
        message = (try? DocumentMirror.yield(to: keyID, root: root)) != nil
            ? DocumentsWords.usingMacsCopy(device: ThisDevice.word) : DocumentsWords.cantSave
    }

    // MARK: The check at home

    /// PrepareMeLibrary's check, once the Mac answered at `base`: an adult's phone asks for the key, sends its own adds
    /// and changes, mirrors the Mac's store and reports how it stands (counts only). One at a time.
    func sync(base: URL) async {
        adult = MacLink.canEdit == true
        guard adult, !syncing, let root = Self.root, let code = MacLink.pairing else { return }
        syncing = true
        defer { syncing = false }
        let changed = await Self.sync(root: root, link: DocumentsLink(code: code, base: base), desk: desk)
        refreshStanding()
        if changed, store != nil { await load() }
    }

    /// True when a new index came.
    private nonisolated static func sync(root: URL, link: DocumentsLink, desk: PhoneDocumentsDesk) async -> Bool {
        guard (try? prepare(root)) != nil else { return false }  // the device is locked: next time
        sweep(root)
        // the key: asked for with this device's lock until the owner gives it, then kept for the next unlock
        if !DocumentKey.exists(in: root), !FileManager.default.fileExists(atPath: incomingURL(root).path) {
            guard let answer = await link.ask("documents/key") else { return false }
            switch DocumentHandoff.keyStep(status: answer.status, served: answer.data,
                                           lock: { try? DocumentKey.lockToAsk(in: root) }) {
            case .keep:
                guard (try? DurableFile.write(answer.data, to: incomingURL(root))) != nil else { return false }
            case .ask:
                // none yet, or one sealed to a lock this phone set aside (DocumentKey.setAside): ask with this one
                guard let lock = try? DocumentKey.lockToAsk(in: root),
                      let body = try? JSONEncoder().encode(DocumentHandoff.Request(key: lock)) else { return false }
                _ = await link.ask("documents/key-request", method: "POST", body: body)
                return false
            case .stop:
                return false  // 403: not an adult's phone
            }
        }
        // the Mac's list, judged before anything is sent or taken (audit G2): a Mac set up again from an older copy or
        // under another key gets nothing from this device (it would drop the changes it can't apply), and this device
        // keeps its own copy, its last list included
        let answer = await link.ask("documents/list.json")
        let list = answer.flatMap { $0.status == 200 ? (try? DocumentList.read($0.data)) : nil }
        var held = DocumentMirror.held(in: root)
        let yield = DocumentMirror.yielded(in: root)
        if let list {
            try? DocumentMirror.record(DocumentMirror.judge(list, held: held, yield: yield), root: root, held: &held)
        }
        guard DocumentMirror.maySend(list, held: held, yield: yield) else { return false }
        // this device's adds, each file whole before the changes that name it, so the Mac can apply them
        let ledger = DocumentOutbox.Ledger.read(in: root)
        for name in ledger.files where list?.entry(named: name) == nil {
            guard await link.upload(root.appendingPathComponent("files").appendingPathComponent(name), as: name)
            else { break }
        }
        let outbox = root.appendingPathComponent(DocumentOutbox.fileName)
        if let sha = try? FileCheck.sha256(of: outbox), sha != ledger.posted, let body = try? Data(contentsOf: outbox),
           await link.ask("documents/changes", method: "POST", body: body)?.status == 202 {
            await desk.posted(sha, root: root)
        }
        // the Mac's store, each file checked against the list's fingerprint; the index last
        guard let answer, let list else { return false }
        try? DurableFile.write(answer.data, to: root.appendingPathComponent(DocumentList.fileName))
        try? DocumentMirror.adopt(list, own: Set(ledger.files), root: root, held: &held)
        let before = held.list?.index
        for entry in DocumentMirror.toFetch(list, held: held, root: root) {
            let fetched = root.appendingPathComponent(fetchingPrefix + UUID().uuidString.lowercased())
            guard await link.download("documents/files/\(entry.name)", to: fetched),
                  (try? DocumentMirror.take(fetched, as: entry, root: root, held: &held)) != nil else {
                try? FileManager.default.removeItem(at: fetched)
                break
            }
        }
        if let finished = try? await desk.finish(list, root: root, held: held) { held = finished }
        let standing = DocumentMirror.standing(list, held: held, root: root)
        let report = DocumentsPhoneReport(matching: standing.matching, all: standing.all, index: standing.index,
                                          waiting: DocumentOutbox.Ledger.read(in: root).changes.count)
        if let body = try? JSONEncoder().encode(report) {
            _ = await link.ask("documents/status", method: "POST", body: body)
        }
        return standing.index && before != list.index
    }

    nonisolated static let fetchingPrefix = "fetching-"

    /// A fetch cut short leaves its part behind: removed before the next.
    private nonisolated static func sweep(_ root: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix(fetchingPrefix) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// App-private storage (never in Files), complete file protection (unreadable while the device is locked), and out
    /// of the device's iCloud backup (design, 2026-10-24). New files take the folder's protection.
    nonisolated static func prepare(_ root: URL) throws {
        try DocumentStore.prepare(root)
        for folder in [root, root.appendingPathComponent("files", isDirectory: true)] {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: folder.path)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = root
        try url.setResourceValues(values)
    }

    // MARK: Changes (every one waits encrypted for the Mac)

    private func change(_ kind: DocumentChange.Kind) {
        guard state == .open, let key, let root = Self.root else { return }
        lastActive = Date()
        let change = DocumentChange(kind)
        let previous = tail
        tail = Task {
            await previous?.value
            do {
                try await desk.append(change, root: root, key: key)
                guard store != nil else { return }
                changes.append(change)
                index.apply(change)
                waiting = changes.count
            } catch {
                message = error is DocumentOutbox.Full ? DocumentsWords.outboxFull : DocumentsWords.cantSave
            }
        }
    }

    func newFolder(_ name: String, in parent: UUID?) {
        var scratch = index
        let id = scratch.newFolder(name, in: parent)
        if let folder = scratch.folder(id) { change(.newFolder(folder: folder)) }
    }

    func rename(_ target: PhoneDocumentsTarget, to name: String) {
        switch target {
        case .folder(let id): change(.renameFolder(id: id, name: name))
        case .document(let id): change(.renameDocument(id: id, name: name))
        }
    }

    func move(_ target: PhoneDocumentsTarget, to folder: UUID?) {
        switch target {
        case .folder(let id):
            guard folder.map({ !index.subtree(id).contains($0) }) ?? true else { return }  // never into itself
            change(.moveFolder(id: id, parent: folder))
        case .document(let id): change(.moveDocument(id: id, folder: folder))
        }
    }

    func delete(_ target: PhoneDocumentsTarget) {
        switch target {
        case .folder(let id): change(.deleteFolder(id: id))
        case .document(let id): change(.deleteDocument(id: id))
        }
    }

    func putBack(_ target: PhoneDocumentsTarget) {
        switch target {
        case .folder(let id): change(.putBackFolder(id: id))
        case .document(let id): change(.putBackDocument(id: id))
        }
    }

    /// Scans, photos and files into `folder`, each encrypted and read back before its add is recorded; counts only.
    func add(_ sources: [PhoneDocumentsSource], to folder: UUID?) {
        guard state == .open, !sources.isEmpty, let key, let root = Self.root else { return }
        lastActive = Date()
        busy = true
        let previous = tail
        tail = Task {
            await previous?.value
            var report = DocumentImportReport()
            for source in sources {
                do {
                    let change = try await desk.add(source, to: folder, root: root, key: key)
                    report.added += 1
                    if store != nil {
                        changes.append(change)
                        index.apply(change)
                    }
                } catch let reason as DocumentRefusal {
                    report.refused[reason, default: 0] += 1
                } catch {
                    message = error is DocumentOutbox.Full ? DocumentsWords.outboxFull : DocumentsWords.cantSave
                    break
                }
            }
            busy = false
            waiting = changes.count
            if report.added > 0 || !report.refused.isEmpty { message = DocumentsWords.report(report) }
        }
    }

    func data(of document: StoredDocument) async -> Data? {
        guard let store else { return nil }
        return await Task.detached { try? store.data(of: document) }.value
    }

    // MARK: Sending (share, print, locked PDF)

    /// A fresh Face ID, Touch ID or passcode first, even with Documents open, then the confirmation (default Cancel).
    func send(_ document: StoredDocument, _ way: DocumentSendWay) {
        guard state == .open else { return }
        lastActive = Date()
        if way == .print, document.kind == .office {
            message = DocumentsWords.noPrint
            return
        }
        Task {
            let fresh = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                                               localizedReason: DocumentsWords.sendReason)) ?? false
            if fresh, state == .open { confirming = (document, way) }
        }
    }

    /// After the confirmation: print straight from memory; the share sheet from a sealed scratch copy wiped when it's
    /// done; a locked PDF after its password.
    func confirmed(_ document: StoredDocument, _ way: DocumentSendWay) {
        confirming = nil
        if way == .lockedPDF {
            askingPassword = document
            return
        }
        Task {
            guard let data = await data(of: document) else {
                message = DocumentsWords.damaged
                return
            }
            switch way {
            case .print:
                let printer = UIPrintInteractionController.shared
                let info = UIPrintInfo.printInfo()
                info.jobName = document.name
                info.outputType = document.kind == .image ? .photo : .general
                printer.printInfo = info
                printer.printingItem = data  // from memory: no file is made
                printer.present(animated: true) { _, completed, _ in
                    if completed { PhoneDocumentsModel.shared.recordSend(document, .print) }
                }
            case .airDrop, .share:
                guard let url = try? DocumentScratch.copy(data, named: document.fileName) else { return }
                sharing = PhoneDocumentsShare(url: url, document: document)
            case .lockedPDF:
                break
            }
        }
    }

    func sendLocked(_ document: StoredDocument, password: String) {
        askingPassword = nil
        Task {
            guard let data = await data(of: document), let pdf = PhoneDocumentPages.pdf(data, kind: document.kind) else {
                message = DocumentsWords.damaged
                return
            }
            let folder = DocumentScratch.folder().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent(document.name.replacingOccurrences(of: "/", with: "-") + ".pdf")
            let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password,
                                                          .ownerPasswordOption: UUID().uuidString]
            guard pdf.write(to: url, withOptions: options) else { return }
            sharing = PhoneDocumentsShare(url: url, document: document, locked: true)
        }
    }

    /// The share sheet closed: the scratch copy wiped, and the send recorded when it went.
    func shared(_ share: PhoneDocumentsShare, activity: UIActivity.ActivityType?, completed: Bool) {
        sharing = nil
        try? FileManager.default.removeItem(at: share.url.deletingLastPathComponent())
        guard completed else { return }
        recordSend(share.document, share.locked ? .lockedPDF : activity == .airDrop ? .airDrop : .share)
    }

    private func recordSend(_ document: StoredDocument, _ way: DocumentSendWay) {
        change(.send(id: document.id, send: DocumentSend(date: Date(), device: UIDevice.current.name, how: way.rawValue)))
    }
}

enum PhoneDocumentsRoute: Hashable {
    case folder(UUID), document(UUID), recentlyDeleted
}

enum PhoneDocumentsTarget: Hashable, Identifiable {
    case folder(UUID), document(UUID)
    var id: Self { self }
}

/// What a name sheet asks for: a new folder's name, or a new name.
enum PhoneDocumentsNaming: Hashable, Identifiable {
    case newFolder(parent: UUID?), rename(PhoneDocumentsTarget)
    var id: Self { self }
}

enum PhoneDocumentsSource: Sendable {
    case file(URL)  // from Files, security-scoped
    case data(Data, name: String, type: String)  // a scan or a photo
}

struct PhoneDocumentsShare: Identifiable {
    let id = UUID()
    let url: URL
    let document: StoredDocument
    var locked = false
}

/// The one writer of this device's outbox, ledger and mirror's last step: an add, a recorded change and the mirror's
/// tidy-up never interleave, so the mirror never removes an add's file before the ledger names it. No method waits
/// on anything, so each runs whole.
actor PhoneDocumentsDesk {
    func append(_ change: DocumentChange, root: URL, key: SymmetricKey) throws {
        try record(DocumentOutbox.read(in: root, key: key) + [change], root: root, key: key)
    }

    private func record(_ changes: [DocumentChange], root: URL, key: SymmetricKey) throws {
        try DocumentOutbox.write(changes, in: root, key: key)
        try DocumentOutbox.Ledger.read(in: root).settled(changes).write(in: root)
    }

    func add(_ source: PhoneDocumentsSource, to folder: UUID?, root: URL, key: SymmetricKey) throws -> DocumentChange {
        try PhoneDocumentsModel.prepare(root)
        let store = DocumentStore(root: root, key: key)
        var scratch = DocumentIndex()
        let document: StoredDocument
        switch source {
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            document = try store.add(url, to: folder, in: &scratch)
        case let .data(data, name, type):
            document = try store.add(data, named: name, type: type, to: folder, in: &scratch)
        }
        let change = DocumentChange(.add(document: document))
        do {
            try record(DocumentOutbox.read(in: root, key: key) + [change], root: root, key: key)
        } catch {
            store.remove(files: [document.file])
            throw error
        }
        return change
    }

    /// The changes the Mac's index doesn't show applied yet, with the outbox and ledger cut down to them.
    func settle(against index: DocumentIndex, root: URL, key: SymmetricKey) throws -> [DocumentChange] {
        let all = DocumentOutbox.read(in: root, key: key)
        let waiting = DocumentOutbox.waiting(all, against: index)
        if waiting != all { try DocumentOutbox.write(waiting, in: root, key: key) }
        let ledger = DocumentOutbox.Ledger.read(in: root)
        if ledger.settled(waiting) != ledger { try ledger.settled(waiting).write(in: root) }
        return waiting
    }

    func posted(_ sha: String, root: URL) {
        var ledger = DocumentOutbox.Ledger.read(in: root)
        guard (try? FileCheck.sha256(of: root.appendingPathComponent(DocumentOutbox.fileName))) == sha else { return }
        ledger.posted = sha
        try? ledger.write(in: root)
    }

    func finish(_ list: DocumentList, root: URL, held: DocumentMirror.Held) throws -> DocumentMirror.Held {
        var held = held
        try DocumentMirror.finish(list, root: root, held: &held, keep: Set(DocumentOutbox.Ledger.read(in: root).files))
        return held
    }
}

/// Essential Documents' requests to the Mac's phones' service, on the base the library's check reached, with the
/// certificate pinned and this phone's token (MacLink's way).
struct DocumentsLink: Sendable {
    let code: PairingCode
    let base: URL
    static let haveHeader = "X-PrepareMe-Have"  // the service's HTTP.haveHeader

    struct Answer: Sendable {
        let status: Int
        let data: Data
        let have: Int64?
    }

    private func request(_ path: String, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        MacLink.authorize(&request, token: code.token)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    func ask(_ path: String, method: String = "GET", body: Data? = nil) async -> Answer? {
        var request = request(path, method: method, timeout: 30)
        request.httpBody = body
        let pin = PinCheck(pin: code.fp)
        let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let answer = response as? HTTPURLResponse else { return nil }
        return Answer(status: answer.statusCode, data: data,
                      have: answer.value(forHTTPHeaderField: Self.haveHeader).flatMap { Int64($0) })
    }

    /// One listed file to `place`, whole, or false.
    func download(_ path: String, to place: URL) async -> Bool {
        let pin = PinCheck(pin: code.fp)
        let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (temporary, response) = try? await session.download(for: request(path, method: "GET", timeout: 60))
        else { return false }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        try? FileManager.default.removeItem(at: place)
        return (try? FileManager.default.moveItem(at: temporary, to: place)) != nil
    }

    /// One of this device's added files into the Mac's inbox, piece by piece from what the service already has, so a
    /// send cut short goes on where it stopped. True once the service has it all.
    func upload(_ url: URL, as name: String) async -> Bool {
        guard let size = DocumentList.size(of: url), let handle = try? FileHandle(forReadingFrom: url),
              var have = await ask("documents/upload/\(name)")?.have else { return false }
        defer { try? handle.close() }
        while have < size {
            guard (try? handle.seek(toOffset: UInt64(have))) != nil,
                  let piece = try? handle.read(upToCount: DocumentInbox.maxPiece), !piece.isEmpty,
                  let answer = await ask("documents/upload/\(name)/\(have)", method: "POST", body: piece),
                  answer.status == 204 || answer.status == 409, let next = answer.have else { return false }
            have = next
        }
        return have == size
    }
}

/// A PDF or a photo as PDF pages, in memory only (the phone's locked PDF).
enum PhoneDocumentPages {
    static func pdf(_ data: Data, kind: DocumentTypes.Kind) -> PDFDocument? {
        switch kind {
        case .pdf: return PDFDocument(data: data)
        case .image:
            guard let image = UIImage(data: data), let page = PDFPage(image: image) else { return nil }
            let pdf = PDFDocument()
            pdf.insert(page, at: 0)
            return pdf
        case .office: return nil
        }
    }
}
#endif
