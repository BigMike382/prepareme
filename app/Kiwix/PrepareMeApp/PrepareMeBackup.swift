// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (concept-doc plan, phase A).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import CryptoKit
import Foundation
import PrepareMeShared

/// The iCloud backup (concept-doc plan, phase A; docs/mac-app.md, "The iCloud backup"): after each library check and on
/// Back up now, every file the phones can get is copied from this app's own checked copies into iCloud Drive › PrepareMe
/// Backup, by PrepareMeShared's `Backup` (its rules and tests). The owner makes and shares that folder; the app never
/// creates or shares it. Its status record (Application Support › PrepareMe › backup › status.json) is what the
/// failure notice reads; Settings' Backups tab and the sidebar's warnings box show its words.
///
/// - One backup at a time, never started while the library's own copying runs. Back up now pressed during one runs
///   another right after it.
/// - The copying and its read-back run off the main thread; a held copy the library swaps away meanwhile waits for the
///   next check (never a failure). A copy that failed waits an hour before it is tried again, unless its file changes
///   or Back up now is pressed, so a stuck file isn't read every 30 seconds (review 2).
/// - While macOS's question about iCloud Drive waits for an answer (F-081), the record says so after 10 seconds and
///   again hourly, so Library status, the sidebar and the notice speak up rather than stay silent (review 2).
/// - The phones' inventory copy (InventoryModel's phone-inventory.json, never a Private row) goes too, with the rally
///   points (beta run 2, B2-04, choice a): read off the main thread at each look, and copied when what it holds changes.
@MainActor
final class PrepareMeBackup: ObservableObject {
    static let shared = PrepareMeBackup()

    @Published private(set) var status: BackupStatus?
    /// While a backup copies: how many of its changed files are done, of how many
    @Published private(set) var copying: (done: Int, total: Int)?
    @Published private(set) var upload: Backup.Upload?
    private var saved: BackupStatus?
    /// The Mac's backup-signing key (concept-doc plan, phase B), made once in the app's own container
    /// (backup-signing.key) and never replaced when it can't be read: then nil, tried again at each look, and the lists
    /// go unsigned, said in Library status (docs/mac-app.md says how to start a new one)
    private(set) var key: P256.Signing.PrivateKey?
    @Published private(set) var keyUnreadable = false

    private func signingKey() -> P256.Signing.PrivateKey? {
        if key == nil {
            do {
                key = try BackupSignature.loadOrMakeKey(at: PrepareMeMac.root.appendingPathComponent("backup-signing.key"))
                keyUnreadable = false
            } catch {
                keyUnreadable = true
            }
        }
        return key
    }

    nonisolated static func signer(_ key: P256.Signing.PrivateKey) -> @Sendable (Manifest) throws -> Data {
        { manifest in try BackupSignature.sign(manifest, with: key) }
    }
    private var running = false
    private var again = false
    /// Back up now pressed while the library's own copying ran: done at the next look
    private var wanted = false
    /// The copies that failed lately, the phones' inventory copy included: each name's `Backup.failureKey` then, and when
    private var failures: [String: (key: String, at: Date)] = [:]
    /// The phones' inventory copy as the last look read it, read again only once its file changed (whole-plan review)
    private var inventoryCache = Backup.InventoryCache()
    static let retryAfter: TimeInterval = 3600

    /// iCloud Drive › PrepareMe Backup under the account's real home (the sandbox's exception). A session's check build
    /// uses its scratch folder's stand-in, or PREPAREME_CHECK_BACKUP (its one test folder in iCloud Drive, build.sh).
    nonisolated static var folder: URL? {
        #if PREPAREME_CHECK
        if let path = ProcessInfo.processInfo.environment["PREPAREME_CHECK_BACKUP"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return PrepareMeHome.url?.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/\(Backup.folderName)", isDirectory: true)
    }

    /// Application Support › PrepareMe › backup: the status record and the backup manifest's local mirror
    nonisolated static var records: URL? { PrepareMeMac.folders?.appendingPathComponent("backup", isDirectory: true) }

    private init() {
        saved = Self.records.flatMap { BackupStatus.read(try? Data(contentsOf: $0.appendingPathComponent("status.json"))) }
        status = saved
    }

    /// A backup if one is due (after each library check), or at once (`now`: Back up now)
    func check(now: Bool = false) async {
        guard !running else {
            if now { again = true }
            return
        }
        running = true
        defer { running = false }
        var force = now || wanted
        repeat {
            again = false
            await once(force: force)
            force = true
        } while again
    }

    /// What a look needs from the backup folder, read off the main thread: macOS holds the app's first look at iCloud
    /// Drive until the owner answers its question, and the window must not freeze meanwhile (check build, 2026-10-18)
    struct Look: Sendable {
        var access: Backup.Access
        var backup: Manifest?
        var present: [String: Int64] = [:]
        var readMeThere = false
        var free: Int64?
        var upload: Backup.Upload?
        /// The key that signed the backup's list, from the local mirror (never iCloud's copy), or nil
        var signedBy: String?
        /// The phones' inventory copy, read once (Backup.inventorySource), or nil when there is none
        var inventory: Backup.InventorySource?
        /// The cache it came through, for the next look
        var cache = Backup.InventoryCache()
    }

    /// The rest of a look, once `Backup.access` (the step macOS's question holds) said `.ok`
    nonisolated static func look(_ folder: URL, mirror: URL, cache: Backup.InventoryCache) -> Look {
        let present: [String: Int64]
        do {
            present = try Backup.listing(in: folder)
        } catch {
            let error = error as NSError
            let code = Int32((error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0)
            let refused = error.code == NSFileReadNoPermissionError || Backup.refusal(code) != nil
            return Look(access: refused ? .refused : .unreadable, cache: cache)
        }
        let backup = Backup.readMirror(mirror, folder: folder)
        var signedBy: String?
        if let data = try? Data(contentsOf: mirror), case let .signed(key)? = try? BackupSignature.read(data).verdict {
            signedBy = key
        }
        let readMe = folder.appendingPathComponent(Backup.readMeName)
        let named = (backup?.files.map(\.name) ?? []) + (backup?.inventory.map { [$0.name] } ?? [])
        var cache = cache  // its size and date unchanged since the last look: not read, decoded and hashed again
        let inventory = InventoryModel.folder.flatMap { cache.source(in: $0) }
        return Look(access: .ok, backup: backup, present: present,
                    readMeThere: FileManager.default.fileExists(atPath: readMe.path),
                    free: Backup.freeSpace(at: folder),
                    upload: Backup.upload(of: named, in: folder), signedBy: signedBy,
                    inventory: inventory, cache: cache)
    }

    private func once(force: Bool) async {
        let mac = PrepareMeMac.shared
        guard mac.sync.copying == nil else {
            if force { wanted = true }
            return
        }
        guard let folder = Self.folder, let records = Self.records else { return }
        guard let delivery = mac.store.record.manifest else {  // no list read yet: the record still says the app looks
            heartbeat()
            return
        }
        wanted = false
        publishKey()
        let mirror = records.appendingPathComponent(Backup.manifestName)
        // macOS's question holds only the folder's first open (Backup.access), so only that is timed (cloud review, 3)
        let asking = Task { @MainActor [weak self] in  // the open still waiting after 10 seconds: macOS is asking
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled, let self {
                var waiting = self.status ?? BackupStatus()
                waiting.problem = BackupStatus.asking
                self.settle(waiting, behind: true, upload: nil)
                try? await Task.sleep(for: .seconds(Self.retryAfter))
            }
        }
        let access = await Task.detached(priority: .utility) { Backup.access(folder) }.value
        asking.cancel()
        let cache = inventoryCache
        let look = access == .ok
            ? await Task.detached(priority: .utility) { Self.look(folder, mirror: mirror, cache: cache) }.value
            : Look(access: access, cache: cache)
        inventoryCache = look.cache
        var next = status ?? BackupStatus()
        guard look.access == .ok else {
            next.problem = switch look.access {
            case .refused: BackupStatus.noAccess
            case .unreadable: BackupStatus.unreadable
            default: BackupStatus.noFolder
            }
            settle(next, behind: true, upload: nil)
            return
        }
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0.value.at) < Self.retryAfter }
        let holdOff = Backup.holdOff(delivery: delivery, inventory: look.inventory?.entry,
                                     failed: failures.mapValues(\.key), force: force)
        var plan = Backup.plan(delivery: delivery, held: mac.store.record.held, backup: look.backup,
                               present: look.present, holdOff: holdOff, inventory: look.inventory)
        // phase B: a list this key didn't sign (phase A's, or a key made again) is written again, signed
        if let key = signingKey(), look.signedBy != BackupSignature.publicKey(of: key), !plan.final.isEmpty {
            plan.rewrite = true
        }
        guard plan.wanted > 0 else {  // a list naming nothing for the phones: nothing to say "current" of
            heartbeat(upload: look.upload)
            return
        }
        let readMe = next.readMe != Backup.readMeDigest || !look.readMeThere
        next.current = plan.current
        next.wanted = plan.wanted
        // a copy held off after failing is still a failure, said as one until it lands
        let stuck = Backup.stuck(holdOff, plan: plan, inventory: look.inventory?.entry)
        guard plan.isDue || readMe || force || !stuck.isEmpty else {
            next.problem = nil
            settle(next, behind: false, upload: look.upload)
            return
        }
        if !plan.isDue && !readMe && !force {
            next.problem = BackupStatus.copyFailed
            next.failed = stuck.count
            settle(next, behind: true, upload: look.upload)
            return
        }
        if let room = Backup.room(bytes: plan.bytes, free: look.free) {
            next.problem = BackupStatus.noRoom
            next.need = room.need
            next.free = room.free
            settle(next, behind: true, upload: look.upload)
            return
        }
        copying = (0, max(plan.copies.count, 1))
        var hooks = Backup.Hooks()
        hooks.progress = { done, total in
            Task { @MainActor in PrepareMeBackup.shared.copying = (done, total) }
        }
        let source = mac.store.libraryFolder
        let signer = signingKey().map(Self.signer)
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = .current
        let writtenAt = stamp.string(from: Date())
        let run = plan, progress = hooks  // fixed before the copy starts, so the task gets its own values
        let result = await Task.detached(priority: .utility) { () throws -> (Backup.Outcome, Backup.Upload) in
            let outcome = try Backup.run(run, source: source, folder: folder, mirror: mirror, writtenAt: writtenAt,
                                         readMe: readMe, signer: signer, hooks: progress)
            let names = outcome.manifest.files.map(\.name) + (outcome.manifest.inventory.map { [$0.name] } ?? [])
            return (outcome, Backup.upload(of: names, in: folder))
        }.result
        copying = nil
        switch result {
        case let .success((outcome, upload)):
            let failed = Set(outcome.failed).union(stuck)
            let whole = failed.isEmpty && outcome.unremoved.isEmpty
            for name in outcome.failed {
                if let entry = plan.copies.first(where: { $0.entry.name == name })?.entry {
                    failures[name] = (Backup.failureKey(entry), Date())
                } else if let inventory = plan.inventoryCopy?.entry, inventory.name == name {
                    failures[name] = (Backup.failureKey(inventory), Date())  // held off like a file (checkpoint 1)
                }
            }
            for name in outcome.copied { failures[name] = nil }
            if outcome.inventoryCopied, let name = plan.inventoryCopy?.entry.name { failures[name] = nil }
            next.current = outcome.current
            next.wanted = outcome.wanted
            next.problem = !outcome.unremoved.isEmpty ? BackupStatus.notRemoved
                : failed.isEmpty ? nil : BackupStatus.copyFailed
            next.failed = !outcome.unremoved.isEmpty ? outcome.unremoved.count : failed.isEmpty ? nil : failed.count
            if outcome.readMeWritten { next.readMe = Backup.readMeDigest }
            settle(next, behind: !whole, ran: whole && outcome.waiting.isEmpty, upload: upload)
        case let .failure(error):
            next.problem = (error as? Backup.Problem) == .noFolder ? BackupStatus.noFolder : BackupStatus.notSaved
            settle(next, behind: true, upload: nil)
        }
    }

    /// A look that had nothing to back up (no delivery list yet, or one naming nothing for the phones): the record keeps
    /// its standing problem, but not "asking", which a finished look has answered, and its time moves on, so the
    /// notice doesn't take the app for gone (cloud review, 2). A standing upload problem is settle's to judge, from the
    /// upload state.
    private func heartbeat(upload: Backup.Upload? = nil) {
        var next = status ?? BackupStatus()
        if next.problem == BackupStatus.asking { next.problem = nil }
        let standing = next.problem != nil && next.problem != BackupStatus.uploadFailed
        settle(next, behind: standing, upload: upload ?? self.upload)
    }

    /// The record after a look: published with iCloud's upload state, and written whole when worth it (a small file
    /// in the local status folder, never iCloud). Files iCloud won't upload make it not current (phase K's drills,
    /// finding 1: `BackupStatus.take`), and so do files still waiting to upload after two days (offline fixes, phase 2).
    private func settle(_ record: BackupStatus, behind: Bool, ran: Bool = false, upload: Backup.Upload?) {
        var record = record
        let stood = record.problem == BackupStatus.uploadFailed
        let unuploaded = record.take(upload)
        if record.problem != BackupStatus.noRoom { (record.need, record.free) = (nil, nil) }
        if ![BackupStatus.copyFailed, BackupStatus.notRemoved, BackupStatus.uploadFailed].contains(record.problem) {
            record.failed = nil
        }
        if record.problem != BackupStatus.uploadFailed { record.uploads = nil }
        // uploads that went through after iCloud refused them: the copy iCloud now holds is current (review)
        record = record.updated(at: Date(), behind: behind || unuploaded, ran: ran || (stood && !unuploaded))
        status = record
        self.upload = upload
        guard record.worthWriting(over: saved), let records = Self.records else { return }
        do {
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
            try DurableFile.write(record.encoded(), to: records.appendingPathComponent("status.json"))
            saved = record
        } catch {
            // the record can't be written: Library status still shows the line; the notice sees an older record and
            // says so once it is BACKUP_DAYS old
        }
    }

    /// Library status's backup lines
    var lines: [String] {
        if let copying { return [BackupWords.copying(done: copying.done, total: copying.total)] }
        return [BackupWords.line(status, upload: upload, now: Date()), BackupWords.uploadProblem(upload),
                keyUnreadable ? BackupWords.unsigned : nil].compactMap { $0 }
    }

    /// The key's public half in the pairing folder (backup-key.json), for the phones' service to hand each paired phone
    /// with the list it serves; written whole, only when it isn't there already as it should be
    private func publishKey() {
        guard let key = signingKey(), let pairing = PrepareMeMac.folders?.appendingPathComponent(PairingDesk.folderName),
              let data = try? BackupSignature.publicKeyFile(of: key) else { return }
        let file = pairing.appendingPathComponent(BackupSignature.publicKeyFileName)
        guard BackupSignature.readPublicKeyFile(try? Data(contentsOf: file)) != BackupSignature.publicKey(of: key) else {
            return
        }
        try? FileManager.default.createDirectory(at: pairing, withIntermediateDirectories: true)
        try? DurableFile.write(data, to: file)
    }
}
#endif
