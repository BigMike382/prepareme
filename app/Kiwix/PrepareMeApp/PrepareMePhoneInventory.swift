// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 7, slice 5).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import PrepareMeShared
import SwiftUI

/// The inventory on the phone (build plan phase 7, slice 5): the Mac's copy for the phones (never a Private item),
/// kept here so it reads away from home, with this phone's own edits shown on top until the Mac has answered them.
/// An adult's phone edits (the Mac's service says so); a child's reads only. Edits wait in the outbox, go to the Mac
/// whenever it answers, and are applied there by the Mac app with the same checks as its own; a refused one is listed.
@MainActor
final class PhoneInventoryModel: ObservableObject {
    static let shared = PhoneInventoryModel()

    @Published private(set) var copy: PhoneInventory? { didSet { revision.bump() } }
    /// The role the Mac last gave this phone. A change redraws Today's band at once (B3-04): a phone paired before its
    /// role was known has read as a child's, and says so in the adult's words the moment the Mac's answer arrives. The
    /// pages already open get the new role's marks too (F-092: a guide's walk-through button), and pages opened from
    /// now on in tabs made before start with them.
    @Published private(set) var canEdit = false {
        didSet { if oldValue != canEdit { roleChanged() } }
    }

    private func roleChanged() {
        PrepareMeRedNight.shared.layScripts()
        let marks = WalkthroughRole.phoneMarks(canEdit: canEdit, child: isChild)
        for webView in BrowserViewModel.everyWebView() { webView.evaluateJavaScript(marks) }
        Task { await LiveConditions.shared.showNow() }
    }
    @Published private(set) var outbox: PhoneOutbox { didSet { revision.bump() } }
    /// Counts every setting of the copy and every change to the outbox, so the screens' caches (copyKey) never keep
    /// what a changed copy with the same date and size made
    private var revision = CopyRevision()
    @Published private(set) var lastLook: Date?
    /// The waiting-changes file was there at launch but couldn't be read: never saved over until it reads, and then
    /// the changes made since join it (offline fixes, task 1.1)
    @Published private(set) var outboxUnreadable = false
    /// The last save of the waiting changes failed (a full phone): said under the waiting line until one works
    @Published private(set) var saveFailed = false
    /// The Mac's copy is in a newer format than this build reads (audit P2h): the copy held stays, and Inventory asks
    /// for an update at its foot until a look reads the Mac's copy again
    @Published private(set) var newerMac = false
    /// The copy came from the PrepareMe Backup (Add from Files, beta run 2, B2-04): read only, never edited from, until
    /// a look returns the Mac's own copy, which replaces it (it stays through pairing: checkpoint 1)
    @Published private(set) var fromBackup = false
    @Published private(set) var problem: String?
    @Published private(set) var busy = false
    /// A bin label's place, opened by its link (the Camera, or a scan in the app): shown over every screen.
    @Published var openedPlace: Int64?
    /// A tapped expiry reminder: Inventory opens on Expiring soon (Task 12.6; F38).
    @Published var openExpiring = false
    /// A guide's "In the house" (phase 14, F57): Inventory opens on the items whose names hold one of its words.
    @Published var openHouse: GuideHouse?
    /// This phone's answer for the reminders' notifications, kept current on each look and return to the app.
    @Published private(set) var reminders: LocationAsk.Status = .allowed
    /// Whether the copy has anything to remind of, worked out once per copy, not on every redraw (the review).
    var remindable: Bool {
        if remindableFor != copy?.writtenAt {
            remindableFor = copy?.writtenAt
            remindableFound = copy.map { !ExpiryReminders.make($0).isEmpty } ?? false
        }
        return remindableFound
    }
    private var remindableFor: String?
    private var remindableFound = false

    func refreshReminders() async { reminders = await PhoneExpiryReminders.status() }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrepareMe")
    }
    static var cacheURL: URL { folder.appendingPathComponent("inventory-cache.json") }
    static var outboxURL: URL { folder.appendingPathComponent("inventory-outbox.json") }

    private init() {
        do { outbox = try PhoneOutbox.read(Self.outboxURL) } catch {
            outbox = PhoneOutbox()
            outboxUnreadable = true
        }
        readCache()
    }

    /// The saved copy, when this run holds none: at launch, and again on coming forward, since a launch before the
    /// first unlock after a restart can't read it yet (audit D2). PhoneInventoryCache (PrepareMeShared, PhoneTests)
    /// holds the rule: a backup copy never edits and has no look.
    private func readCache() {
        guard copy == nil, let cache = PhoneInventoryCache.read(Self.cacheURL) else { return }
        copy = cache.copy
        fromBackup = cache.isFromBackup
        canEdit = cache.mayEdit
        lastLook = cache.lastLook
    }

    /// Whether this phone may change the inventory now: its role allows it and the copy isn't the backup's
    /// (PhoneInventoryCache.mayEdit, the one rule).
    var mayEdit: Bool { !sample && PhoneInventoryCache.mayEdit(canEdit: canEdit, fromBackup: fromBackup) }

    /// The sample library's made-up inventory is shown (PrepareMeSample): read only, never saved, never sent, no
    /// reminders; what was held before it comes back when it is put away.
    @Published private(set) var sample = false
    private var beforeSample: (copy: PhoneInventory?, fromBackup: Bool, canEdit: Bool, lastLook: Date?)?

    func showSample(_ found: PhoneInventory) {
        if !sample { beforeSample = (copy, fromBackup, canEdit, lastLook) }
        sample = true
        copy = found
        canEdit = false
        lastLook = nil
        problem = nil
    }

    func leaveSample() {
        guard sample else { return }
        sample = false
        copy = beforeSample?.copy
        fromBackup = beforeSample?.fromBackup ?? false
        canEdit = beforeSample?.canEdit ?? false
        lastLook = beforeSample?.lastLook
        beforeSample = nil
    }

    /// The key the screens' caches built from a shown copy keep (the search's and near-miss's index, Add's names,
    /// the supplies): it changes whenever the copy is set or the waiting changes change (CopyRevision).
    func copyKey(_ copy: PhoneInventory) -> String { revision.key(copy) }

    /// Every supply group with its calculators for a shown copy (SupplyCalculators), worked out once per copy and
    /// links rather than on each redraw: the Inventory home's section and the Supplies screen both read it.
    func supplyCalculators(_ copy: PhoneInventory, links: CalculatorLinks) -> [SupplyCalculators] {
        let key = copyKey(copy)
        if let kept = suppliesKept, kept.key == key, kept.links == links { return kept.found }
        let found = copy.supplyCalculators(links: links, figures: copy.supply?.calculators)
        suppliesKept = (key, links, found)
        return found
    }
    private var suppliesKept: (key: String, links: CalculatorLinks, found: [SupplyCalculators])?

    /// What the screens show: the Mac's copy with this phone's waiting edits on top.
    var shown: PhoneInventory? { copy.map(outbox.view) }

    /// The item a product's barcode was linked to, here or on the Mac (never a Private one: those aren't in the copy).
    func item(forCode code: String) -> Int64? {
        guard let copy = shown, let id = copy.barcodes?[code], copy.items.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    // a kind the Mac doesn't read: almost always its PrepareMe is older than this phone's (owner, 2026-11-18, by click)
    static let unreadable = "The Mac couldn't take this change. Update PrepareMe on the Mac, then try again."
    static let tooLong = "The Mac couldn't take this change: it's too long."

    /// Right after pairing (or pairing again): forget the last pairing's copy and role, then look at once, so a child's
    /// phone knows it is one before anyone opens Inventory; until the look answers it is treated as having no copy
    /// (the beta run's F58; owner, 2026-10-16). Waiting edits stay: a child's pairing refuses them, as any edit.
    /// A copy from the PrepareMe Backup stays, read only, until a look returns the Mac's copy (checkpoint 1): a new
    /// Mac that hasn't written its copy yet (404) or a first look that fails never leaves the phone without its rally
    /// points.
    func paired() async {
        await PrepareMeSample.shared.putAway()  // a family's device: the sample goes first, whole
        forgotten = false  // known again: waiting changes may be tried
        if !fromBackup {
            copy = nil
            try? FileManager.default.removeItem(at: Self.cacheURL)
        }
        canEdit = false
        lastLook = nil
        problem = nil
        await look()
        await LiveConditions.shared.showNow()  // Today's Event mode line in the new role's words (phase 2 review)
    }

    /// Send what's waiting, then fetch the Mac's copy and settle the answers. Away from home this fails quietly: the
    /// last copy stays, and the edits keep waiting.
    private var followUp: Task<Void, Never>?  // the one look 12 seconds after a look that sent, or while answers wait

    func look() async {
        guard !busy, !sample else { return }
        busy = true
        defer { busy = false }
        var posted = false
        // all that waits, up to a Used 1 or 1 more still held for its Undo (B2-08), in the order they were made
        let sent = Array(outbox.toSend().prefix(PhoneEdits.maxEdits))  // never one just sent again (phase 4)
        if !sent.isEmpty {
            posted = true
            let marked = outbox.markSent(sent.map(\.id))  // from here the Mac may have them: Undo never takes them back
            saveOutbox()  // kept as sent, even if the app is closed while they go
            sending = true
            let delivery = await PhoneDelivery.run(sent) { await MacLink.send($0) }
            forgotten = delivery.status == 401  // the Mac no longer knows this phone: the tries stop until it pairs again
            if !delivery.readOnly.isEmpty {
                outbox.refuse(delivery.readOnly, message: HomeMacWords.readOnlyInventory)
            }
            if !delivery.unreadable.isEmpty { outbox.refuse(delivery.unreadable, message: Self.unreadable) }
            if !delivery.tooLong.isEmpty { outbox.refuse(delivery.tooLong, message: Self.tooLong) }
            // never reached the Mac (away from home, the Mac off, its inbox full, or left out when the one-at-a-time
            // sends stopped): those this look marked wait as never sent, so quick add's Undo last takes them back again
            // (checkpoint 2); one an earlier look delivered stays sent (re-review)
            outbox.unsend(delivery, marked: marked)
            sending = false
            saveOutbox()
        }
        switch await MacLink.inventory() {
        case .success(let (found, edits)):
            // most looks (every library check) find the copy held, from the Mac, in the same role: the copy isn't set
            // again (no redraw of every screen) and the cache isn't written again; the reminders (today's date, a
            // yes given since) and the name lookup still run on every look
            let unchanged = found == copy && edits == canEdit && !fromBackup
            if !unchanged {
                copy = found
                fromBackup = false  // the Mac's own copy wins over a backup's
                canEdit = edits
            }
            PhoneExpiryReminders.schedule(found)  // plan phase 7, part 2
            await refreshReminders()
            lastLook = Date()
            problem = nil
            newerMac = false
            outbox.settle(with: found)
            saveOutbox()
            if !unchanged { saveCache() }
            await Self.takePlayers()
            await MacLookupKeys.refresh(adult: edits)  // the Mac's barcode keys, once a day (Unlisted plan, phase 4)
            await ProductLookupClient.shared.nameWaiting(self)  // items saved before a name was found (2026-10-14)
            sendHeldOnes(found)
            // the Mac applies within about 10 seconds: look again then for its answers, and again while a sent change
            // still waits for one (a send isn't repeated within 30 seconds now, so it no longer drives this; phase 4)
            // one follow-up at a time: every look used to start its own, so the chains grew with each trigger (the
            // re-post storm, 2026-11-18)
            if posted || !heldOnes.isEmpty || outbox.awaitingAnswer, followUp == nil {
                followUp = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    self?.followUp = nil
                    await self?.look()
                }
            }
        case .failure(let why):
            newerMac = why == .newer
            // a 404 is the Mac not having written the phones' copy yet, said plainly (Task 12.4; F35)
            if why == .newer {
                problem = FileFormat.newerInventory(device: ThisDevice.word)
            } else if case .answered(let status) = why,
               HomeMacWords.inventoryWait(paired: true, status: status) == .notWritten {
                problem = HomeMacWords.inventoryNotWritten
            } else {
                problem = why == .notFound || why == .notPaired || why == .cut ? nil : why.words
            }
        }
    }

    /// Players plan, stage 2: the Mac's player list, fetched with the inventory at each look at home and kept whole in
    /// the app's own folder beside the game saves, where the game bridge reads it; written only when it changed. Not
    /// there yet (404), unreadable, or away from home: the copy held stays. Never logged: nicknames are household details.
    static func takePlayers() async {
        guard case .success(let list) = await MacLink.players() else { return }
        let folder = PrepareMeGameSaves.folder
        if PlayerList.load(folder) != list { try? list.save(folder) }
    }

    /// A look at a library check or the street map's opening, unless one seconds ago has it (`HouseholdLook`; beta run
    /// 2, B2-01): the rally points reach every phone, a child's too, without anyone opening Inventory. A look already
    /// under way is the one (look's `busy`).
    func lookIfDue(_ moment: HouseholdLook.Moment) async {
        guard HouseholdLook.due(moment, hasCopy: copy != nil, lastLook: lastLook) else { return }
        await look()
    }

    /// The PrepareMe Backup's copy, after Add from Files' three checks (beta run 2, B2-04, choice a): taken by a device
    /// that isn't paired when it is newer than the one held, and by a paired one only while it holds none or holds a
    /// backup's copy itself (FolderOffer.inventoryState: a paired device keeps its Mac's, which its Mac keeps current;
    /// whole-plan review). Read only: no edit is
    /// made from it, and a look that returns the Mac's copy replaces it. False when it was kept out.
    func takeFromBackup(_ found: PhoneInventory) -> Bool {
        leaveSample()  // Add from Files puts the whole sample away before it reads the folder; this is the backstop
        guard FolderOffer.inventoryState(paired: MacLink.pairing != nil, held: copy?.writtenAt,
                                         backup: found.writtenAt, fromBackup: fromBackup) != nil else { return false }
        copy = found
        fromBackup = true
        canEdit = false
        lastLook = nil
        problem = nil
        saveCache()
        return true
    }

    /// New Place… or New Category… on this phone (entry fixes plan, Task 1.6): it waits for the Mac like any change,
    /// its cells by name (the copy has no Locations or Categories column ids), and its waiting number is picked meanwhile.
    func addPlace(_ name: String, _ keptIn: Int64, _ vehicle: Bool) async -> (row: Int64?, why: String?) {
        var values: [String: SQLValue] = [Inventory.Label.name: .text(name)]
        if keptIn != 0 { values[Inventory.Label.keptIn] = .int(keptIn) }
        if vehicle { values[Inventory.Label.vehicle] = .int(1) }
        guard let id = edit(.add(table: "Locations", values: values), what: "New place: \(name)") else {
            return (nil, HomeMacWords.readOnlyInventory)
        }
        return (PhoneOutbox.temporaryID(id), nil)
    }

    func addCategory(_ name: String, _ countsAs: String) async -> (row: Int64?, why: String?) {
        let values: [String: SQLValue] = [Inventory.Label.name: .text(name), Inventory.Label.countsAs: .text(countsAs)]
        guard let id = edit(.add(table: "Categories", values: values), what: "New category: \(name)") else {
            return (nil, HomeMacWords.readOnlyInventory)
        }
        return (PhoneOutbox.temporaryID(id), nil)
    }

    /// Send a change (it waits in the outbox until the Mac answers); its id. `withUndo` (the item screen's Used 1 and
    /// 1 more, B2-08): it stays on this phone for its few seconds' Undo first (longer with VoiceOver running), then
    /// goes. `correction`: the item screen's 1 more, or quick add's 1 less (PhoneEdit.correction).
    @discardableResult
    func edit(_ change: InventoryChange, what: String, withUndo: Bool = false, correction: Bool = false) -> String? {
        guard mayEdit else { return nil }
        return enqueue(change, what: what, withUndo: withUndo, correction: correction)
    }

    /// Whether pins are shared through the Mac (the shared marks plan, phase 3): the Mac's own copy holds them (a Mac
    /// from before them sends none, and a backup's copy never edits). Until then a phone's pins stay its own, as before.
    var sharesPins: Bool { copy?.pins != nil && !fromBackup && !sample }

    /// A change to a rally point, route or pin: an adult's phone any (the Mac's rules decide), a child's only a pin
    /// added or one of its own removed (owner, 2026-11-12; the Mac's PhoneRules.childRefusal holds the same line).
    /// Nil when this phone may not.
    @discardableResult
    func editMark(_ change: InventoryChange, what: String) -> String? {
        if mayEdit { return enqueue(change, what: what) }
        guard sharesPins else { return nil }
        switch change {
        case .addMark(let mark) where mark.kind == .pin:
            return enqueue(change, what: what)
        case .removeMark(_, let expected) where expected.removable(adult: false, phone: MapMark.by(device: MacLink.device)):
            return enqueue(change, what: what)
        default:
            return nil
        }
    }

    private func enqueue(_ change: InventoryChange, what: String, withUndo: Bool = false, correction: Bool = false) -> String {
        // a Used 1 valued now, from what this phone shows and its copy's shares (step 8c, section 4)
        let id = outbox.add(change, what: what, item: shown.flatMap { Self.itemLabel(for: change, in: $0) }, use: shown.flatMap { RunsOut.use(of: change, in: $0) },
                            withUndo: withUndo,
                            holdFor: UIAccessibility.isVoiceOverRunning ? PhoneOutbox.undoForVoiceOver
                                : PhoneOutbox.undoFor,
                            correction: correction,
                            seen: copy?.writtenAt)  // the Mac's copy shown as it was made (S4.4, B2-13)
        saveOutbox()
        if withUndo { sendAfterHold() } else { Task { await look() } }
        keepTrying()
        return id
    }

    /// The item a change is to and where it is, as this phone knows them now ("Headlamp (Bin 29)"), kept with the
    /// change so a refusal for an item since removed can still name it (R4.3, B2-11); nil for a change to no one item.
    static func itemLabel(for change: InventoryChange, in copy: PhoneInventory) -> String? {
        let id: Int64
        switch change {
        case .set(table: "Inventory", let row, _, _), .revert(table: "Inventory", let row, _, _, _): id = row
        case .adjust(let row, _): id = row
        case .linkBarcode(_, let row): id = row
        default: return nil
        }
        guard let row = copy.items.first(where: { $0.id == id }) else { return nil }
        let name = copy.shownName(row), place = PhoneText.whereKept(copy, row)
        return place.isEmpty ? name : "\(name) (\(place))"
    }

    /// The item screen's Undo for `row`: its latest Used 1 or 1 more still in its few seconds; nil on a phone that
    /// can't edit (a child's, or a copy from the backup).
    func undoable(_ row: Int64) -> PhoneOutbox.Entry? {
        mayEdit ? outbox.undoable(row: row) : nil
    }

    /// Undo (B2-08): the change leaves the outbox unsent and the number goes back; nothing once its seconds are over.
    func undo(_ id: String) {
        guard mayEdit, outbox.undo(id) else { return }
        saveOutbox()
    }

    /// When a held change's Undo ends: the Undo leaves the screen and the change goes to the Mac, one wait at a time
    /// for every change held.
    private var holding: Task<Void, Never>?

    private func sendAfterHold() {
        guard holding == nil else { return }
        holding = Task { [weak self] in
            while let self, let ends = self.outbox.holdEnds() {
                try? await Task.sleep(for: .seconds(max(0, ends.timeIntervalSinceNow) + 0.2))
                self.objectWillChange.send()  // its Undo goes
                while self.busy { try? await Task.sleep(for: .milliseconds(250)) }
                await self.look()
            }
            self?.holding = nil
        }
    }

    /// While changes wait and the app is open, a look every 30 seconds wherever the app is (Task 12.3; F34); it ends
    /// when nothing waits, or the app goes to the background.
    private var trying: Task<Void, Never>?
    private var open = true
    private var forgotten = false  // the last send's 401 (the phase 12 review)

    func becameActive() {
        open = true
        if outboxUnreadable { saveOutbox() }  // read at last after the first unlock, say: kept whole again
        readCache()
        keepTrying()
        Task {  // back from Settings, say: a yes there schedules from the copy kept, away from home too (review)
            await refreshReminders()
            if reminders == .allowed, !sample, let copy { PhoneExpiryReminders.schedule(copy) }
        }
    }

    func wentToBackground() {
        open = false
        trying?.cancel()
        trying = nil
    }

    private func keepTrying() {
        guard open, trying == nil else { return }
        trying = Task { [weak self] in
            while let self, !Task.isCancelled, !self.forgotten,
                  let wait = WaitingChanges.next(waiting: self.outbox.pending.count) {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { break }
                await self.look()
            }
            if !Task.isCancelled { self?.trying = nil }  // a cancelled one never clears the next one's place
        }
    }

    /// Repeat scans of a product whose new item the Mac hasn't answered yet (quick add), by its code: sent as "1 more"
    /// as soon as the Mac's copy has the item.
    @Published private(set) var heldOnes: [String: Int] = UserDefaults.standard.dictionary(forKey: "PrepareMe.heldOnes")
        as? [String: Int] ?? [:]

    func holdOneMore(_ code: String) {
        heldOnes[code, default: 0] += 1
        UserDefaults.standard.set(heldOnes, forKey: "PrepareMe.heldOnes")
    }

    /// A repeat scan of a new item still on this phone (quick add; entry fixes, Task 2.5): its Quantity raised in its
    /// waiting add, so it reaches the Mac as one item. A send of it under way is waited for first (with the Mac off it
    /// fails, and the add is this phone's again: the review of phase 2). False once it may have reached the Mac: the
    /// scan is held instead.
    func raiseWaitingAdd(_ item: Int64, by: Double) async -> Bool {
        await sendEnds(item)
        guard mayEdit, let quantity = copy?.column(Inventory.Label.quantity),
              outbox.raiseWaitingAdd(item, by: by, quantity: quantity) else { return false }
        saveOutbox()
        return true
    }

    /// Edit on a new item still on this phone: its waiting add saved over with `values` (Task 2.5), once any send of it
    /// under way has ended. False once it may have reached the Mac.
    func changeWaitingAdd(_ item: Int64, to values: [String: SQLValue]) async -> Bool {
        await sendEnds(item)
        guard mayEdit, outbox.changeWaitingAdd(item, { _ in values }) else { return false }
        saveOutbox()
        Task { await look() }
        return true
    }

    /// Whether the new item `item` (below 0) is still an add in this phone's outbox, sent or not: its screen offers Edit.
    func addWaits(_ item: Int64) -> Bool {
        item < 0 && outbox.pending.contains { PhoneOutbox.temporaryID($0.id) == item }
    }

    /// Up to a minute, as `withdraw` waits, for a send of the new item `item`'s add to end.
    private func sendEnds(_ item: Int64) async {
        guard let entry = outbox.pending.first(where: { PhoneOutbox.temporaryID($0.id) == item }) else { return }
        let until = Date().addingTimeInterval(60)
        while isSending(entry.id), Date() < until { try? await Task.sleep(for: .milliseconds(250)) }
    }

    enum TakeBack { case deleted, gone, notYet }

    /// Quick add's Undo last on a new item whose add reached the Mac (owner, 2026-11-18: an adult's phone deletes
    /// items; owner check 107 found a can it couldn't take back): the row the Mac's answer to that add made is deleted
    /// (PhoneInventory.takeBack), a few looks first while the answer comes; `.gone` when the add was refused or its row
    /// is gone. The delete says what this phone saw, so an item changed since stays and is listed as Not saved.
    func takeBackSentAdd(edit id: String, what: String) async -> TakeBack {
        let until = Date().addingTimeInterval(20)
        while true {
            switch shown?.takeBack(add: id) ?? .wait {  // with this phone's waiting changes on top: what the Mac will hold
            case .gone: return .gone
            case .delete(let change): return edit(change, what: "\(what): deleted") == nil ? .notYet : .deleted
            case .wait:
                guard Date() < until else { return .notYet }
                await look()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Take back one held 1 more (quick add's Undo last).
    func unholdOne(_ code: String) {
        guard let count = heldOnes[code] else { return }
        heldOnes[code] = count > 1 ? count - 1 : nil
        UserDefaults.standard.set(heldOnes, forKey: "PrepareMe.heldOnes")
    }

    /// Forget a code's held 1 mores (its new item was taken back).
    func dropHeld(_ code: String) {
        heldOnes[code] = nil
        UserDefaults.standard.set(heldOnes, forKey: "PrepareMe.heldOnes")
    }

    private func sendHeldOnes(_ copy: PhoneInventory) {
        for (code, count) in heldOnes {
            guard let id = copy.barcodes?[code], id > 0, let row = copy.items.first(where: { $0.id == id }) else {
                // not on the Mac yet: kept while its new item waits to be sent; dropped once that was refused or
                // taken back, so nothing is held (or looked again for) for good
                if shown?.barcodes?[code] == nil { heldOnes[code] = nil }
                continue
            }
            edit(.adjust(row: id, by: Double(count)), what: "\(copy.shownName(row)): \(count) more")
            heldOnes[code] = nil
        }
        UserDefaults.standard.set(heldOnes, forKey: "PrepareMe.heldOnes")
    }

    /// A look's send is under way (its changes are marked sent until it ends: checkpoint 2).
    private(set) var sending = false

    /// Whether a send of the change `id` is under way now (quick add's Undo last waits for it to end).
    func isSending(_ id: String) -> Bool {
        sending && outbox.pending.contains { $0.id == id && $0.sentAt != nil }
    }

    enum Withdrawal { case done, sent, stillSending }

    /// Take back a change still waiting (quick add's Undo last): `.sent` once a send of it may have reached the Mac
    /// (fix round 1). A send of it under way is waited for first, up to a minute (two addresses' 15 seconds each, and
    /// the one-at-a-time sends): one that never reached the Mac leaves it waiting, to be taken back (checkpoint 2);
    /// `.stillSending` when it hasn't ended by then (re-review), so nothing untrue is said.
    func withdraw(_ id: String) async -> Withdrawal {
        let until = Date().addingTimeInterval(60)
        while isSending(id), Date() < until { try? await Task.sleep(for: .milliseconds(250)) }
        if isSending(id) { return .stillSending }
        guard outbox.withdraw(id) else { return .sent }
        saveOutbox()
        return .done
    }

    /// Event mode switched on this phone (plan phase 7, part 2): sent like any change, and shown on this phone's front
    /// page at once (PhoneEventSwitch), away from home too.
    func switchEventMode(_ value: String) {
        guard canEdit, let lists = shown?.lists, lists.eventMode != value else { return }
        UserDefaults.standard.set(value, forKey: Self.localSwitchKey)
        UserDefaults.standard.set(Date(), forKey: Self.localSwitchAtKey)
        edit(lists.eventModeChange(value), what: "Event mode: \(value)")
        Task { await LiveConditions.shared.showNow() }
    }

    static let localSwitchKey = "PrepareMe.eventModeLocal"
    static let localSwitchAtKey = "PrepareMe.eventModeLocalAt"

    /// The switch this phone's front page shows over the Mac's, or nil.
    var localEventMode: String? {
        PhoneEventSwitch.value(waiting: outbox.waitingEventMode,
                               local: UserDefaults.standard.string(forKey: Self.localSwitchKey),
                               setAt: UserDefaults.standard.object(forKey: Self.localSwitchAtKey) as? Date,
                               copy: shown?.lists?.eventMode,
                               copyAt: shown.flatMap { ISO8601DateFormatter().date(from: $0.writtenAt) })
    }

    func clearRefused() {
        outbox.refused = []
        saveOutbox()
    }

    /// One refusal put away: its edit was made again from the form.
    func forgetRefusal(_ id: String) {
        outbox.forgetRefusal(id)
        saveOutbox()
    }

    /// The waiting and refused changes, written after every change to them (small: written often)
    private func saveOutbox() {
        if outboxUnreadable {
            // never over the file it couldn't read
            guard var kept = try? PhoneOutbox.read(Self.outboxURL) else { return }
            kept.takeIn(outbox)
            outbox = kept
            outboxUnreadable = false
        }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try outbox.write(Self.outboxURL)
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }

    /// The copy, its role and its look's time, written only when the copy or its role changed (large: the whole copy)
    private func saveCache() {
        guard !sample else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        // the role as held; the cache's reader applies the edit rule (PhoneInventoryCache.mayEdit), once
        if let copy, let data = try? JSONEncoder().encode(PhoneInventoryCache(
            copy: copy, canEdit: canEdit, at: lastLook ?? Date(), fromBackup: fromBackup)) {
            try? DurableFile.write(data, to: Self.cacheURL)
        }
    }
}

// MARK: The tab

struct PhoneInventoryTab: View {
    @ObservedObject private var model = PhoneInventoryModel.shared
    @State private var search = ""
    @State private var nearIndex = PhoneSearch.KeyedCache<PhoneSearch.Index>()  // the near-miss words, built once per copy (B2-09)
    @State private var scanning = false
    @State private var adding = false
    @State private var quickAdding = false
    @State private var pairing = false  // Pair with the Mac, before pairing (Task 12.4; F35)
    @State private var throwingAway = false  // "Throw these away" asks first (B2-11)
    @State private var calculatorLinks: CalculatorLinks?  // the daily library's, for every supply's calculators (B2-30)
    @ObservedObject private var libraryStore = PrepareMeLibrary.shared.store
    @State private var countOpen: PhoneInventoryCounts.Opens?  // the count tapped (look 3)
    @AppStorage("PrepareMe.grabVehicles") private var grabVehicles = ""  // the checklist's vehicles going, as it counts

    func grabCount(_ copy: PhoneInventory) -> Int {
        GrabChecklist(copy, going: Set(grabVehicles.split(separator: "\n").compactMap { Int64($0) })).all.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if let copy = model.shown {
                    PMList {
                        status(searching: !PhoneSearch.showsNotes(search: search))  // notes hide while searching (B2-09)
                        if search.isEmpty { PhoneSuppliesSection(copy: copy, links: calculatorLinks) }  // plan phase 7, part 2; R9.2
                        if !search.isEmpty {
                            let rows = found(copy)
                            if rows.isEmpty {  // not a bare heading over nothing (B2-09)
                                Section {
                                    Text(PhoneSearch.nothingFound)
                                    if let near = PhoneSearch.nearMiss(search: search, index: { nearIndexFor(copy) }) {
                                        Button(PhoneSearch.didYouMean(near)) { search = near }.pmAction()
                                    }
                                }
                            } else {
                                Section(pmTitle: "Found") {
                                    ForEach(rows) { row in ItemLink(copy: copy, row: row) }
                                }
                            }
                        } else {
                            // cards as the guide list's groups (owner, 2026-10-25, by click; InventoryLook); look 3
                            // (spec section 4, owner 2026-11-11) makes the counts tiles and the locations fold rows
                            if model.canEdit {  // owner, 2026-10-14: hundreds of items, quickly
                                PMCard {
                                    Button { quickAdding = true } label: {
                                        PMCardLabel(emoji: InventoryLook.Row.quickAdd, title: "Quick Add with the Camera")
                                    }
                                    .foregroundStyle(PrepareMeColors.ink)
                                }
                            }
                            PMCard {  // look 3: the four counts, two short rows of two, each opening its list
                                PhoneInventoryCounts(toBuy: copy.toBuy.count, expiring: expiring(copy).count,
                                                     all: copy.items.count, grab: grabCount(copy), open: $countOpen)
                            }
                            if let lists = copy.lists { PhoneListsSection(lists: lists) }  // plan phase 7, part 2
                            // Locations and Vehicles (step 8a; owner, 2026-10-19, by click: A1 and A3): a vehicle
                            // shows under Vehicles only; look 3: rows in one panel, each folding open in place
                            let places = copy.shownLocations.sorted(by: byName)
                            if !places.isEmpty {
                                Section(pmTitle: InventoryWords.locations) {
                                    ForEach(places) { PlaceFold(copy: copy, place: $0, emoji: InventoryLook.Row.place) }
                                }
                            }
                            let vehicles = copy.vehicles.sorted(by: byName)
                            if !vehicles.isEmpty {
                                Section(pmTitle: InventoryWords.vehicles) {
                                    ForEach(vehicles) {
                                        PlaceFold(copy: copy, place: $0, emoji: InventoryLook.vehicleEmoji($0.name))
                                    }
                                }
                            }
                            let categories = copy.categories
                                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                                .compactMap { category in
                                    let rows = rows(copy, category: category.id)
                                    return rows.isEmpty ? nil : (category: category, rows: rows)
                                }
                            ForEach(categories, id: \.category.id) { category, rows in
                                let emoji = InventoryLook.emoji(category: category.name, group: category.group)
                                let name = InventoryLook.title(category.name)
                                PMCard(title: category.id == categories.first?.category.id ? "Categories" : nil) {
                                    PMCardLink(emoji: emoji, title: "\(name) (\(rows.count))") {
                                        ItemList(title: name, rows: rows, group: category.group, emoji: emoji)
                                    }
                                }
                            }
                        }
                        footer(searching: !PhoneSearch.showsNotes(search: search))  // the copy's source, last (owner, 2026-10-21)
                    }
                    // Add: one labeled button in thumb reach (R9.2), the one every Add on the phone shares (change 13)
                    .pmAddBar(show: model.canEdit && PhoneSearch.showsNotes(search: search)) {  // not while a search has words
                        Button { adding = true } label: { Label(InventoryHome.addLabel, systemImage: "plus") }.pmAction()
                    }
                    // a sheet, as on the Mac (the owner's answer, 2026-10-22: the Apple guidelines plan, phase 9)
                    .sheet(isPresented: $adding) { NavigationStack { ItemForm(copy: copy, row: nil) } }
                    // the drawer under the title, always showing: the default hid it until the list was pulled down on
                    // an adult's iPhone and collapsed to a bare magnifying glass on the iPad (beta run 3, B3-03)
                    .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: "Search the inventory")
                    .autocorrectionDisabled(!PhoneSearch.boxAutocorrects)  // it changed "water" on the SE (B2-09)
                    .textInputAutocapitalization(PhoneSearch.boxCapitalizes ? .sentences : .never)
                    .scrollDismissesKeyboard(.immediately)  // the results, not the keyboard, on a scroll (F32)
                    .listSectionSpacing(12)  // the guide list's gap between its cards (PMCard)
                    .refreshable { await model.look() }
                    .task(id: libraryStore.record.held) {
                        calculatorLinks = await PrepareMeKeptTabs.calculatorLinks(held: libraryStore.record.held)
                    }
                } else {
                    PMStateScreen {  // look 3's one look for "not here yet" (spec section 10)
                        let heading = NoCopyYet.heading
                        if MacLink.pairing == nil {  // as every other tab: pair first (Task 12.4; F35)
                            PMState(symbol: "shippingbox", heading: heading,
                                    line: HomeMacWords.inventoryNotPaired(device: ThisDevice.word),
                                    action: ("Pair with the Mac", { pairing = true }))
                            // the Mac lost: the backup's copy (B2-04)
                            Text(HomeMacWords.inventoryFromBackup).foregroundStyle(PrepareMeColors.text2)
                                .padding(.horizontal, 24)
                        } else {  // a reason it couldn't read is for your attention, amber (spec section 10, rule 3)
                            PMState(symbol: "shippingbox", heading: heading,
                                    line: model.problem ?? NoCopyYet.openAtHome,
                                    kind: model.problem == nil ? .info : .attention,
                                    action: (model.busy ? "Checking…" : "Check now", { Task { await model.look() } }))
                                .disabled(model.busy)
                        }
                    }
                    .sheet(isPresented: $pairing) { PairView { pairing = false } }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { if model.sample { SampleStrip() } }
            .pmBandBar()  // look 3
            .navigationTitle("Inventory")
            .pmTitleSmall()
            .navigationDestination(item: $countOpen) { opens in  // a count tapped (look 3)
                if let copy = model.shown {
                    switch opens {
                    case .toBuy: PhoneToBuyView()
                    case .expiring: ItemList(title: "Expiring Soon", rows: expiring(copy), dated: true)
                    case .all: ItemList(title: "All Items", rows: copy.items)
                    case .grab: PhoneGrabChecklistView()  // one Grab entry, its two tiers inside (Task 12.1; F31)
                    }
                }
            }
            .navigationDestination(isPresented: $model.openExpiring) {  // a tapped reminder (Task 12.6; F38)
                if let copy = model.shown {
                    ItemList(title: ExpiryReminders.title, rows: expiring(copy), dated: true)
                }
            }
            .navigationDestination(isPresented: Binding(get: { model.openHouse != nil },
                                                        set: { if !$0 { model.openHouse = nil } })) {
                if let copy = model.shown, let house = model.openHouse {  // a guide's In the house (phase 14; F57)
                    ItemList(title: GuideLinks.houseTitle,
                             rows: copy.items.filter { GuideLinks.matches(copy.shownName($0), house.words) },
                             note: house.title, empty: GuideLinks.noneInTheHouse)
                }
            }
            .toolbar {
                // Scan is a labeled button on every device (a bare toolbar item folded into a ••• menu on the iPad: beta
                // run 2, B2-12; R4.3); Add is the labeled button at the bottom (R9.2)
                ToolbarItem(placement: .topBarTrailing) {
                    if model.shown != nil, !model.sample {  // a scan looks the code up online: the sample sends nothing
                        Button { scanning = true } label: { Label(InventoryHome.scanLabel, systemImage: "barcode.viewfinder") }
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .homeMacButton()
            .sheet(isPresented: $scanning) { ScanSheet() }
            .fullScreenCover(isPresented: $quickAdding) { QuickAddView() }
            #if targetEnvironment(simulator)
            .task {  // a session's simulator check only: PREPAREME_CHECK_QUICK_ADD=type opens Quick Add 4 s in (its box after)
                guard ProcessInfo.processInfo.environment["PREPAREME_CHECK_QUICK_ADD"] != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                if model.shown != nil { quickAdding = true }
            }
            #endif
        }
        .task {
            while !Task.isCancelled {  // every 2 minutes while it shows; waiting changes are keepTrying's (12.3)
                await model.look()
                try? await Task.sleep(for: .seconds(WaitingChanges.lookEvery))
            }
        }
    }

    @ViewBuilder func status(searching: Bool) -> some View {
        // One status line (R9.2, B2-14): that reminders are off, over their button; the copy's source and a read-only
        // phone's words moved to the foot (footer(searching:); owner, 2026-10-21). None of it while a search has words (B2-09)
        let reminders = searching || model.shown == nil || model.sample ? LocationAsk.Offer.none
            : ReminderAsk.offer(model.reminders, hasReminders: model.remindable)
        let line = InventoryHome.statusLine(reminders: reminders)
        // only what Send now sends: a change held for its Undo isn't waiting yet (whole-plan review); the screen is
        // drawn again when its hold ends (sendAfterHold), so it joins the line then if the send that starts doesn't go
        let waiting = WaitingChanges.waiting(model.outbox)
        let hasPending = waiting > 0
        let hasRefused = !model.outbox.refused.isEmpty
        let outboxProblem = model.outboxUnreadable || model.saveFailed
        if !line.isEmpty || hasPending || hasRefused || outboxProblem {  // not an empty section
            Section {
                if !line.isEmpty {
                    Text(line).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
                if model.outboxUnreadable {  // offline fixes, task 1.1
                    Text(WaitingChanges.unreadable(device: ThisDevice.word)).font(.pmNote)
                        .foregroundStyle(PrepareMeColors.red)  // damaged (spec section 10, rule 3)
                }
                // the reminders' ask, after the line, on any phone, a child's too (Task 12.6; F38)
                if let copy = model.shown {
                    switch reminders {
                    case .ask:
                        Button(ReminderAsk.allow) {
                            Task {
                                await PhoneExpiryReminders.ask(copy)
                                await model.refreshReminders()
                            }
                        }
                        .pmAction(fullWidth: false)
                        Text(ReminderAsk.why).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    case .settings:
                        Button(ReminderAsk.openSettings) {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .pmAction(fullWidth: false)
                        .accessibilityHint(ReminderAsk.refused)
                    case .none: EmptyView()
                    }
                }
                if hasPending {  // and Send now, for a phone back home (Task 12.3; F34)
                    Text(WaitingChanges.line(waiting, taken: model.outbox.takenUnapplied(copy: model.copy,
                                                                                lookedAt: model.fromBackup ? nil : model.lastLook),
                                             device: ThisDevice.word)).font(.pmNote)
                    Button(model.busy ? WaitingChanges.sending : WaitingChanges.sendNow) { Task { await model.look() } }
                        .pmAction(fullWidth: false)
                        .disabled(model.busy)
                }
                if model.saveFailed {
                    Text(WaitingChanges.notSaved(device: ThisDevice.word)).font(.pmNote)
                        .foregroundStyle(PrepareMeColors.caution)
                }
                // the copy to edit again, worked out once for every refusal, and only on a phone that may edit
                let editable = model.canEdit && !model.outbox.refused.isEmpty ? model.shown : nil
                ForEach(model.outbox.refused) { refused in  // the item, the Mac's reason in plain words (beta run F21)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not saved: \(refused.what)").font(.pmNote.bold())
                        Text(PhoneEditRules.refusalLine(message: refused.message, item: refused.item, what: refused.what))
                            .font(.pmNote)
                            .foregroundStyle(PrepareMeColors.red)
                        if let copy = editable, let again = refused.again(in: copy) {
                            NavigationLink("Edit again") {
                                ItemForm(copy: copy, row: again.row, barcode: again.barcode, prefill: again.values,
                                         onSaved: { model.forgetRefusal(refused.id) }, bought: again.bought)
                            }
                            .font(.pmNote)
                        }
                    }
                }
                if !model.outbox.refused.isEmpty {
                    // asks first: nothing brings the changes back (beta run 2, B2-11; R4.3)
                    Button("Throw these away…", role: .destructive) { throwingAway = true }.pmAction(fullWidth: false)
                        .confirmationDialog(HomeMacWords.throwAwayTitle(count: model.outbox.refused.count),
                                            isPresented: $throwingAway, titleVisibility: .visible) {
                            Button(HomeMacWords.throwAwayButton, role: .destructive) { model.clearRefused() }
                            Button(HomeMacWords.throwAwayKeep, role: .cancel) {}
                        } message: { Text(HomeMacWords.throwAwayMessage) }
                }
            }
        }
    }

    /// The quiet line at the list's foot (owner, 2026-10-21): where the copy came from and when, and a read-only
    /// phone's words. A plain row on the page's ground, so the bottom Add button's inset (the list's safe area) leaves
    /// it clear when scrolled to the end; none while a search has words (B2-09).
    @ViewBuilder func footer(searching: Bool) -> some View {
        let line = searching ? "" : model.sample ? SampleLibrary.inventoryFoot : InventoryHome.footerLine(
            written: model.copy.flatMap { ISO8601DateFormatter().date(from: $0.writtenAt) }?
                .formatted(date: .abbreviated, time: .shortened),
            fromBackup: model.fromBackup, canEdit: model.canEdit, paired: MacLink.pairing != nil,
            device: ThisDevice.word)
        if model.newerMac, model.copy != nil, !searching {  // audit P2h: caution, amber
            Section {
                Text(FileFormat.newerInventory(device: ThisDevice.word)).font(.pmNote)
                    .foregroundStyle(PrepareMeColors.caution)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        if !line.isEmpty {
            Section {
                Text(line).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
    }

    func byName(_ a: PhoneInventory.Place, _ b: PhoneInventory.Place) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// The near-miss words and the text the search matches, for this copy (rebuilt when the copy, its size or the
    /// waiting changes change).
    func nearIndexFor(_ copy: PhoneInventory) -> PhoneSearch.Index {
        nearIndex.value(key: model.copyKey(copy)) {
            PhoneSearch.Index(names: copy.items.map { copy.shownName($0) }, texts: copy.items.map { searchText(copy, $0) })
        }
    }

    func searchText(_ copy: PhoneInventory, _ row: PhoneInventory.Row) -> String {
        (copy.columns.map { copy.cell(row, $0) } + [PhoneText.whereKept(copy, row)]).joined(separator: " ")
    }

    func found(_ copy: PhoneInventory) -> [PhoneInventory.Row] {
        // items named for the words first, then those matching elsewhere (a category, a note: Task 12.2; F32); each
        // row's name and search text read from the index built once per copy, not again on each keystroke
        let index = nearIndexFor(copy)
        return PhoneSearch.ranked(Array(copy.items.indices), search: search, name: { index.names[$0] }) { n in
            index.searchTexts[n]  // "truck" finds what's in the truck's drawers and bags too
        }.map { copy.items[$0] }
    }

    func expiring(_ copy: PhoneInventory) -> [PhoneInventory.Row] {
        guard let column = copy.column("Expires") else { return [] }
        let limit = Date().addingTimeInterval(Double(copy.headsUpDays) * 86_400).timeIntervalSince1970
        let day: (PhoneInventory.Row) -> Double? = { $0.values[column.colId]?.number }
        return copy.items.filter { !copy.keptPastDate($0) && (day($0).map { $0 <= limit } ?? false) }  // expired first (F24)
            .sorted { ExpiryWords.earlier(day($0) ?? 0, day($1) ?? 0) }
    }

    func rows(_ copy: PhoneInventory, category: Int64) -> [PhoneInventory.Row] {
        guard let column = copy.column("Category") else { return [] }
        return copy.items.filter { $0.values[column.colId]?.whole == category }
    }
}

/// Values as the Mac shows them.
enum PhoneText {
    /// Where an item is, as its whole path ("Truck › Truck Drawer › Truck Go-Bag"; plan phase 7, part 2), in title
    /// case (InventoryLook).
    static func whereKept(_ copy: PhoneInventory, _ row: PhoneInventory.Row) -> String {
        guard let column = copy.column("Location") else { return "" }
        if let id = row.values[column.colId]?.whole, copy.places.contains(where: { $0.id == id }) {
            return InventoryLook.title(copy.path(id))
        }
        return InventoryLook.title(copy.cell(row, column))
    }

    /// The row's expiry date in words (ExpiryWords), or nil without one.
    static func expiry(_ copy: PhoneInventory, _ row: PhoneInventory.Row) -> ExpiryWords.Line? {
        guard let column = copy.column("Expires"), let seconds = row.values[column.colId]?.number else { return nil }
        return ExpiryWords.line(seconds)
    }

    static func amount(_ copy: PhoneInventory, _ row: PhoneInventory.Row) -> String {
        [copy.column("Quantity"), copy.column("Unit")].compactMap { $0.map { copy.cell(row, $0) } }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct PlaceLink: View {
    let copy: PhoneInventory
    let place: PhoneInventory.Place

    /// What's kept in it, in the bins inside too.
    var rows: [PhoneInventory.Row] {
        let inside = copy.within(place.id)
        return copy.column("Location").map { column in
            copy.items.filter { ($0.values[column.colId]?.whole).map(inside.contains) ?? false }
        } ?? []
    }

    var body: some View {
        let rows = rows
        NavigationLink { screen(rows) } label: {
            VStack(alignment: .leading) {
                Text(name(rows))
                if !place.label.isEmpty { Text(place.label).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
            }
        }
    }

    func name(_ rows: [PhoneInventory.Row]) -> String { "\(InventoryLook.title(place.name)) (\(rows.count))" }

    func screen(_ rows: [PhoneInventory.Row]) -> some View {
        PMList {
            let bins = bins
            if !bins.isEmpty {
                Section(pmTitle: "Bins") { ForEach(bins) { PlaceLink(copy: copy, place: $0) } }
            }
            Section(pmTitle: "Items") {
                ForEach(rows) { ItemLink(copy: copy, row: $0) }
            }
        }
        .navigationTitle(InventoryLook.title(place.name))
        .pmTitleSmall()
    }

    /// The bins inside, less a vehicle parked in it: under Vehicles (step 8a).
    var bins: [PhoneInventory.Place] {
        copy.shownInside(place.id).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A location or vehicle on the Inventory home as a row that folds open in place (look 3, spec section 4): its bins,
/// each opening its own screen, then its items. The system's fold says open or closed to VoiceOver and keeps the
/// whole row a tap target (spec section 8).
struct PlaceFold: View {
    let copy: PhoneInventory
    let place: PhoneInventory.Place
    let emoji: String

    var body: some View {
        let link = PlaceLink(copy: copy, place: place)
        let rows = link.rows
        DisclosureGroup {
            ForEach(link.bins) { PlaceLink(copy: copy, place: $0) }
            ForEach(rows) { ItemLink(copy: copy, row: $0) }
        } label: {
            PMCardLabel(emoji: emoji, title: link.name(rows), note: place.label)
        }
    }
}

/// Inventory's four counts (look 3, spec section 4): two short rows of two, one to a row from the xxxLarge text size,
/// so nothing shrinks to fit; each opens its list. Their words are the cards' they replace.
struct PhoneInventoryCounts: View {
    enum Opens: Hashable { case toBuy, expiring, all, grab }

    let toBuy: Int, expiring: Int, all: Int, grab: Int
    @Binding var open: Opens?
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let pair = size >= .xxxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        VStack(alignment: .leading, spacing: 16) {
            pair {
                PMCount(toBuy, "To Buy") { open = .toBuy }
                PMCount(expiring, "Expiring Soon", kind: expiring > 0 ? .attention : .info) { open = .expiring }
            }
            pair {
                PMCount(all, "All Items") { open = .all }
                PMCount(grab, "Grab-and-Go Checklist") { open = .grab }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Every supply with its calculators, whether or not anything is stocked (beta run 2, B2-30; mockup 5): "none entered"
/// says why a group's days are missing. Self-contained, so the Inventory home can move it (R9.2). The calculators are
/// pages of the daily library, so a child's phone shows them too.
struct PhoneSupplyCalculators: View {
    let copy: PhoneInventory
    let links: CalculatorLinks?  // the daily library's (step 8b), read by the tab where a task always runs
    @Environment(\.dynamicTypeSize) private var size
    @ObservedObject private var store = PrepareMeLibrary.shared.store

    var body: some View {
        let supplies = links.map { PhoneInventoryModel.shared.supplyCalculators(copy, links: $0) } ?? []
        if !supplies.isEmpty {
            Section(pmTitle: "Supplies and their calculators") {
                Text("\"None entered\" means nothing is stocked for it yet.").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            }
        }
        ForEach(supplies, id: \.group) { supply in
            Section {
                ForEach(supply.line.links, id: \.calculator.page) { link in
                    if let url = PrepareMeKeptTabs.calculatorURL(link, held: store.record.held) {
                        Button { PrepareMeTabs.shared.open(url, in: .guides) } label: {
                            Label(link.calculator.name, systemImage: "function")
                        }
                        .pmAction()
                    } else {
                        Label(link.calculator.name, systemImage: "function").foregroundStyle(PrepareMeColors.text2)
                    }
                }
                ForEach(supply.line.notes, id: \.self) { Text($0).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
            } header: {
                // side by side, or stacked at the accessibility text sizes, where they would cut each other short
                let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout())
                layout {  // BASE's grey, as every section title (PrepareMeColors.text2)
                    Text(InventoryLook.title(supply.group))
                    if !size.isAccessibilitySize { Spacer() }
                    Text(supply.stocked)
                }
                .foregroundStyle(PrepareMeColors.text2)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
    }
}

/// Supplies' calculators on a screen of their own, one tap from the Inventory home's Supplies (R9.2): every group, with
/// "none entered" where nothing is stocked (B2-30).
struct PhoneSupplyCalculatorsScreen: View {
    let links: CalculatorLinks?
    @ObservedObject private var model = PhoneInventoryModel.shared

    var body: some View {
        PMList {
            if let copy = model.shown { PhoneSupplyCalculators(copy: copy, links: links) }
        }
        .navigationTitle(InventoryHome.suppliesTitle)
        .pmTitleSmall()
    }
}

/// A guide's "In the house" request (phase 14, F57; GuideLinks.houseLink): its title and item words.
struct GuideHouse: Equatable {
    let title: String
    let words: [String]
}

struct ItemList: View {
    let title: String
    let rows: [PhoneInventory.Row]
    var dated = false  // Expiring soon: each row says when (ItemLink)
    var note: String?  // a line above the rows: In the house's guide (phase 14)
    var empty = "None."
    var group: String?  // a category's Counts as: its Calculators line on top (step 8b)
    var emoji: String?  // a category's (InventoryLook), before the title's words as a guide category page's heading
    @ObservedObject private var model = PhoneInventoryModel.shared
    @ObservedObject private var store = PrepareMeLibrary.shared.store
    @State private var calculators: CalculatorLinks?  // the daily library's (step 8b)

    var body: some View {
        PMList {
            if let note { Text(note).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
            if let copy = model.shown {
                let current = rows.compactMap { row in copy.items.first { $0.id == row.id } }
                // the figures are the lists job's, in the copy's shares (the Mac's last count): the same on every phone
                if let group, let line = calculators?.line(group: group,
                                                           itemNames: current.map { copy.shownName($0) },
                                                           figures: copy.supply?.calculators), !line.links.isEmpty {
                    CalculatorsLine(line: line, held: store.record.held) { PrepareMeTabs.shared.open($0, in: .guides) }
                }
                if current.isEmpty { Text(empty).foregroundStyle(PrepareMeColors.text2) }
                ForEach(current) { ItemLink(copy: copy, row: $0, dated: dated) }
            }
        }
        .navigationTitle(title)
        .pmTitleSmall()
        .toolbar {
            if let emoji {  // the title's words alone stay the back button's and VoiceOver's
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 4) {
                        Text(emoji).accessibilityHidden(true)
                        Text(title).font(.pmHeadline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .task(id: store.record.held) {
            if group != nil { calculators = await PrepareMeKeptTabs.calculatorLinks(held: store.record.held) }
        }
    }
}

struct ItemLink: View {
    let copy: PhoneInventory
    let row: PhoneInventory.Row
    var dated = false  // the expiry date first on the second line: red when gone by, amber when soon (beta run F24)

    var body: some View {
        NavigationLink { ItemDetail(id: row.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.shownName(row))
                let line = [PhoneText.amount(copy, row), PhoneText.whereKept(copy, row)].filter { !$0.isEmpty }
                if dated, let expiry = PhoneText.expiry(copy, row) {
                    (expiryText(expiry) + Text(line.isEmpty ? "" : " · " + line.joined(separator: ", "))
                        .foregroundStyle(PrepareMeColors.text2))
                        .font(.pmNote)
                } else if !line.isEmpty {
                    Text(line.joined(separator: ", ")).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
            }
        }
    }

    func expiryText(_ line: ExpiryWords.Line) -> Text {
        switch line {
        case .expired(let words): Text(words).bold().foregroundStyle(PrepareMeColors.red)
        case .soon(let words): Text(words).foregroundStyle(PrepareMeColors.caution)
        }
    }
}

/// One item: every column, and for an adult's phone "Used 1" and "1 more" (each with a few seconds' Undo), Edit and
/// Delete… (owner, 2026-11-18: adults' phones delete items, children's never).
struct ItemDetail: View {
    let opened: Int64
    @ObservedObject private var model = PhoneInventoryModel.shared
    @ObservedObject private var store = PrepareMeLibrary.shared.store
    @Environment(\.dynamicTypeSize) private var size
    @State private var links: GuideLinks?  // the daily library's, for How to use it (phase 14, F57)
    @State private var editing = false  // Edit's sheet (the Apple guidelines plan, phase 9)
    @State private var deleting = false  // Delete…'s question
    @Environment(\.dismiss) private var dismiss

    init(id: Int64) { opened = id }

    var body: some View {
        // a new item's id is below 0 until the Mac files it, then the Mac's own (Task 2.5)
        let copy = model.shown
        let id = copy?.settledID(opened) ?? opened
        if let copy, let row = copy.items.first(where: { $0.id == id }) {
            // an added item not yet on the Mac (id below 0), or any change to this one the Mac hasn't taken (B3-07)
            let waiting = id < 0 || model.outbox.hasWaitingChange(forItem: id)
            let underNumber = model.canEdit && copy.column("Quantity") != nil && id > 0
            PMList {
                if underNumber {
                    Section {
                        Text(PhoneText.amount(copy, row).isEmpty ? "No amount" : PhoneText.amount(copy, row))
                            .font(.pmCount)
                        if waiting {
                            Text(WaitingChanges.itemLine).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                        }
                        // another phone changed it too while apart, and the Mac kept both: for a day (S4.4, B2-13)
                        if model.outbox.alsoChanged(forItem: id, in: copy) {
                            Text(PhoneInventory.AlsoChanged.line).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                        }
                        // side by side, or stacked at the accessibility text sizes, where side by side cut both to
                        // "…" (Task 12.5; F36)
                        let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12))
                            : AnyLayout(HStackLayout(spacing: 12))
                        layout {
                            let unit = copy.unitWord(of: row)  // "Used 1 gallon": one of the item's own unit
                            Button(UnitWords.used(unit), systemImage: "minus.circle") { change(-1, copy, row) }
                                .pmAction()
                            Button(UnitWords.more(unit), systemImage: "plus.circle") { change(1, copy, row) }
                                .pmAction()
                        }
                        if let held = model.undoable(row.id) {  // a few seconds, before it goes to the Mac (B2-08)
                            Button(PhoneOutbox.undoLabel(held, unit: copy.unitWord(of: row)), systemImage: "arrow.uturn.backward") {
                                model.undo(held.id)
                            }
                            .pmAction()
                        }
                    }
                }
                Section {  // what it counts toward, as the last count found it (entry fixes plan, Task 3.4)
                    Text(SupplyShares.countedLine(copy.supply, row: row.position, item: copy.itemName(row)))
                        .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
                Section {
                    ForEach(copy.columns, id: \.colId) { column in
                        // its name, place and category in title case, as everywhere on the phone (InventoryLook)
                        let text = InventoryFile.same(column.label, "Location") ? PhoneText.whereKept(copy, row)
                            : InventoryFile.same(column.label, "Item") ? copy.itemName(row).isEmpty ? "" : copy.shownName(row)
                            : InventoryFile.same(column.label, "Category") ? InventoryLook.title(copy.cell(row, column))
                            : copy.cell(row, column)
                        // no empty values, nor a blank number's 0 ("Calories each 0" on batteries: Task 12.2; F32)
                        if PhoneSearch.shows(text, label: column.label) { LabeledContent(column.label, value: text) }
                    }
                }
                if let manual = row.manual {  // top-ten plan, phase 7
                    Section { ManualLink(path: manual) }
                }
                if let guides = links?.guides(forItem: copy.shownName(row)), !guides.isEmpty {
                    Section {  // phase 14 (F57): the guides its name has words of
                        HowToUseButtons(guides: guides, held: store.record.held) {
                            PrepareMeTabs.shared.open($0, in: .guides)
                        }
                    }
                }
                if waiting, !underNumber {
                    Text(WaitingChanges.itemLine).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                }
                if model.mayEdit, id > 0 {  // the destroying command last, its trash can red too (docs/design/menus.md)
                    Section {
                        PMMenuDelete("Delete…", systemImage: "trash") { deleting = true }
                            .foregroundStyle(PrepareMeColors.red)
                            .confirmationDialog("Delete \(copy.shownName(row))?", isPresented: $deleting,
                                                titleVisibility: .visible) {
                                Button("Delete", role: .destructive) {
                                    model.edit(PhoneInventory.delete(row), what: "\(copy.shownName(row)): deleted")
                                    dismiss()
                                }
                            } message: {
                                Text("It comes off the Mac and every phone, and can't be undone.")
                            }
                    }
                }
            }
            .navigationTitle(copy.shownName(row))
            .pmTitleSmall()
            .task(id: store.record.held) { links = await PrepareMeKeptTabs.guideLinks(held: store.record.held) }
            .toolbar {
                // a new item still on this phone can be edited too, until a send of it begins (Task 2.5)
                if model.canEdit, id > 0 || model.addWaits(id) { Button("Edit") { editing = true } }
            }
            .sheet(isPresented: $editing) { NavigationStack { ItemForm(copy: copy, row: row) } }
        } else {
            Text("That item is no longer in the inventory.").foregroundStyle(PrepareMeColors.text2)
        }
    }

    func change(_ by: Double, _ copy: PhoneInventory, _ row: PhoneInventory.Row) {
        let what = "\(copy.shownName(row)): \(by < 0 ? "used 1" : "1 more")"
        // a 1 more is marked: it may put right a Used 1 just before it in the storm log (B2-08)
        model.edit(.adjust(row: row.id, by: by), what: what, withUndo: true, correction: by > 0)
    }
}

/// An item's "Read the manual" (top-ten plan, phase 7): the PDF from the manuals library on this phone, opened in
/// Guides, with no network; until that library (or the copy of it holding this manual) is here, a line saying where it
/// comes from.
struct ManualLink: View {
    let path: String
    @ObservedObject private var store = PrepareMeLibrary.shared.store
    @State private var url: URL?
    @State private var looked = false

    var body: some View {
        Group {
            if let url {
                Button("Read the manual", systemImage: "book") { PrepareMeTabs.shared.open(url, in: .guides) }
                    .pmAction()
            } else if looked {
                Text(ItemManuals.notOnThisDevice).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            } else {  // something to draw while it looks: an empty row in a List never starts its task
                Label("Read the manual", systemImage: "book").foregroundStyle(PrepareMeColors.text2)
            }
        }
        .task(id: store.record.held) {
            url = await PrepareMeKeptTabs.manualURL(path, held: store.record.held)
            looked = true
        }
    }
}

/// Add an item, or change one: the columns a phone may edit, stored the Mac's way (InventoryValues). Each field has
/// its name beside it, Grab is a choice, a date has a date picker, Save checks what the Mac would refuse
/// (PhoneEditRules) and shows each problem in red under its field, and Back with changes asks first (the beta run's
/// F20, F21; plan 2026-10-16, Task 4.1).
struct ItemForm: View {
    let copy: PhoneInventory
    let row: PhoneInventory.Row?
    var barcode: String?  // a new item started from a scanned code: the code is linked in the same save
    var prefill: [String: SQLValue] = [:]  // a refused edit's values, opened again ("Edit again")
    var onSaved: () -> Void = {}
    var quick: QuickRun? = nil  // Quick add's form (Task 2.4): in place of its own short card
    var bought: ToBuyList.Item? = nil  // To Buy's Bought… (Task 2.5): in place of its own short form
    @ObservedObject private var model = PhoneInventoryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var typed: [String: String] = [:]
    @State private var picked: [String: Int64] = [:]
    @State private var dated: [String: Date] = [:]  // a date column with a date; none when "Has a date" is off
    @State private var problems: [String: String] = [:]
    @State private var first: Snapshot?  // as the form opened: what Back compares against
    @State private var base: Snapshot?  // the item's own values as the form shows them: Save sends only what differs
    @State private var openedValues: [String: SQLValue]?  // the item as the form opened: each cell change's `expected`
    @State private var openedID: Int64?  // and its id then: a waiting add's below 0, until the Mac answers (review, 1)
    @State private var asking = false
    @State private var names = PhoneSearch.KeyedCache<ItemMatch.Names>()  // "Already in the inventory" (checkpoint 2)
    @FocusState private var focus: String?  // the field being typed in
    @State private var moreOpen = false  // More details (the entry redesign): open when any of its fields is filled
    @State private var addedNote: String?  // "Added Rice. Type the next." after Add Another (Task 2.2)
    @State private var readingDate = false  // Expires' Read the date sheet (plan 2026-10-28, phase 2)
    @State private var screenKeyboard = false  // the on-screen keyboard is up (not a hardware keyboard's bar)
    @State private var lookup = LookupFill()  // what the code's lookup put in, beside the fields (Task 2.4)
    @State private var saving = false  // an add or a save is on its way: a second tap sends nothing
    @Environment(\.dynamicTypeSize) private var textSize
    // One memory (spec 5.3, Task 2.5): the last new item's place, category and unit, Quick add's and Add's, so the next
    // new one starts with them (owner, 2026-10-22, by click; one memory since 2026-11-18)
    @AppStorage(QuickForm.Memory.placeKey) private var lastPlace = 0
    @AppStorage(QuickForm.Memory.categoryKey) private var lastCategory = 0
    @AppStorage(QuickForm.Memory.unitKey) private var lastUnit = QuickForm.Memory.quickUnit  // Quick add's default

    struct Snapshot: Equatable {
        var typed: [String: String]
        var picked: [String: Int64]
        var dated: [String: Date]
    }

    /// Quick add's run of scans (inventory fresh look, spec 5.3, Task 2.4): its place, category and unit start the form,
    /// and Add hands back what it sent, so the next scans go there too (owner, 2026-10-23), and what was added for its
    /// count. Its camera pauses while Read the date is up. Its sheet grows to full height when the line turns amber
    /// (addition C), and Add 1 to it hands the item already there back to Quick add's own 1 more (addition D).
    struct QuickRun {
        let place: Binding<Int>
        let category: Binding<Int>
        let unit: Binding<String>
        let readingDate: Binding<Bool>  // pauses Quick add's camera while Read the date is up
        let grow: () -> Void
        let addOne: (PhoneInventory.Row) -> Void
        let done: (QuickAddView.Done) -> Void
    }

    /// Quick add's, and Scan's "A new item with this code" (owner, 2026-11-17, in chat); never "Edit again" on a refused
    /// add, which opens with what was typed.
    var looksUp: Bool { QuickForm.looksUp(barcode: barcode, isNew: row == nil, prefill: prefill) }
    var reading: Binding<Bool> { quick?.readingDate ?? $readingDate }

    /// The item already in the inventory under the name being typed (a new item only; ItemMatch's rule), looked up
    /// in the names folded once per copy, not every name folded again on each keystroke (checkpoint 2)
    var alreadyThere: PhoneInventory.Row? {
        guard let name = copy.column("Item") else { return nil }
        let folded = names.value(key: model.copyKey(copy)) {
            ItemMatch.Names(copy.items.map { ($0.id, copy.itemName($0)) })  // waiting adds too (Task 2.5)
        }
        guard let id = folded.existing(named: typed[name.colId] ?? "") else { return nil }
        return copy.items.first { $0.id == id }
    }

    /// The item's name, "New Item" when adding (B2-11; it said "Edit"; title case since phase 4's words, as "Quick
    /// Add"), "Bought" for a To Buy line, "Quick Add" in Quick add (board 4)
    var title: String {
        row.map { copy.shownName($0) } ?? (quick != nil ? "Quick Add" : bought == nil ? "New Item" : "Bought")
    }
    /// Quick add and Bought… have one Add at the foot, in place of Add Another and Done: Bought…'s in its own form's
    /// words, Quick add's Add (`QuickForm.addWord`)
    var addWord: String { QuickForm.addWord(bought: bought != nil, quick: quick != nil) }
    /// The editable columns; of the on/off ones, only the two switches (spec 5.3; Private never reaches a phone)
    var columns: [PhoneInventory.Column] {
        copy.columns.filter { $0.editable && ($0.kind != "bool" || PhoneEditRules.isSwitch($0.label)) }
    }
    var now: Snapshot { Snapshot(typed: typed, picked: picked, dated: dated) }
    var changed: Bool { first != nil && first != now }

    var body: some View {
        ScrollViewReader { reader in
            PMForm {
                if let addedNote {
                    Section { Text(addedNote).font(.pmNote).foregroundStyle(PrepareMeColors.text2).id("added") }
                }
                // fresh eyes: six cans of soup, and soup exists already; not in Bought…, whose line is ticked only by its
                // own Add (a 1 more there would leave the line on To Buy)
                if row == nil, bought == nil, let same = alreadyThere {
                    Section {
                        Text(ItemMatch.line(name: copy.shownName(same), amount: PhoneText.amount(copy, same),
                                            place: PhoneText.whereKept(copy, same)))
                            .font(.pmNote)
                        NavigationLink(ItemMatch.goTo) { ItemDetail(id: same.id) }
                        // Quick add only (addition D): the repeat scan's 1 more, counted and undone as a scan; once, and
                        // only for an item in the place being scanned into, as the repeat scan (phase 2 review, M4)
                        if let quick, QuickForm.offersAddOne(itemPlace: copy.column(Inventory.Label.location)
                            .flatMap { same.values[$0.colId]?.whole }, place: quick.place.wrappedValue) {
                            Button(ItemMatch.addOne) { guard !saving else { return }; saving = true; quick.addOne(same) }
                        }
                    }
                }
                // the entry redesign (docs/plans/2026-10-22-item-entry-redesign.md): the shared groups, Food only for
                // food, More details folded, a big Save at the bottom
                ForEach(groups, id: \.group) { entry in
                    switch entry.group {
                    case .more:
                        EntryFold(open: $moreOpen) { rows(entry.columns) }
                    case .howMany:
                        EntrySection(group: .howMany) { amountRow(entry.columns) }
                    case .food:
                        if showsFood { EntrySection(group: .food) { servingsRows; rows(entry.columns) } }
                    default:
                        EntrySection(group: entry.group) { rows(entry.columns) }
                    }
                }
                // at the accessibility text sizes the line sits here, above the form's end, and the bar keeps only
                // the buttons: in the bar it covered more than half an iPhone's form (screen proof, fix wave)
                if textSize.isAccessibilitySize, let needs {
                    Section { PMNeedsLine(line: needs) }
                }
                if row != nil {  // a new item's buttons are on the bar at the bottom
                    Section {
                        Button("Save") {
                            focus = nil
                            DispatchQueue.main.async {
                                if let problem = save() { withAnimation { reader.scrollTo(problem, anchor: .top) } }
                            }
                        }
                        .pmAction()
                    }
                }
            }
            .sheet(isPresented: reading) {
                DateReadSheet { date in copy.column("Expires").map { dated[$0.colId] = date } }
            }
            .navigationTitle(title)
            .pmTitleSmall()
            // the last field scrolls clear of the floating tab bar (beta run 2, B2-11; R4.3): a tap there switched to Maps.
            // A fixed 60 (about the bar's height): SwiftUI gives no measured height for the floating bar, and the
            // system's own inset left the last field under it on the beta run's phones (checkpoint 2)
            .safeAreaPadding(.bottom, 60)
            // a new item: Add Another and Done always in reach (owner, 2026-10-23, at the phase 2 gate), one bar only
            // (owner, same day: two stacked bars over the keyboard took too much room): above the keyboard while typing,
            // with Next, else a small floating bar at the bottom. Done adds and closes, as Add at the top right does
            // The what's-missing line (spec 5.3) on that bar, above the buttons, on an edit too. It goes while the
            // on-screen keyboard is up (one bar over the keyboard, the owner's ruling above) and comes back with what
            // was typed when it goes down; with an iPad's hardware keyboard it stays and changes as you type
            .pmBar(.bottom) {
                let buttons = row == nil && focus == nil
                let line = screenKeyboard || textSize.isAccessibilitySize ? nil : needs
                if buttons || line != nil {  // nothing at all on an edit no supply counts
                    VStack(spacing: 6) {
                        if let line { PMNeedsLine(line: line).padding(.horizontal, 16) }
                        if buttons {
                            HStack(spacing: 12) {
                                if addsAnother {
                                    Button(InventoryWords.addAnother) { addAnother(reader) }.pmAction(fullWidth: false)
                                }
                                // Quick add: one Add, so a product that needs nothing more is scan, Add (spec 5.3)
                                Button(addWord) { finish(reader) }
                                    .pmAction(fullWidth: false)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
                screenKeyboard = PhoneEditRules.screenKeyboardUp(shownHeight: Self.keyboardShown($0))
            }
            .scrollDismissesKeyboard(.interactively)  // a swipe down the form puts the keyboard away
            // The form's own Cancel, always there: swapping the system's Back for it at the first change redrew the form
            // while typing, and a keystroke typed then was shown but never kept ("-5" kept as "-"; simulator, phase 4)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {  // Cancel, as Apple's edit sheets (owner, 2026-10-22)
                    Button("Cancel") {
                        focus = nil  // as Save, below: the last character typed reaches the form once the field lets go
                        DispatchQueue.main.async { if changed { asking = true } else { dismiss() } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(QuickForm.confirmWord(isEdit: row != nil, bought: bought != nil)) {  // as the one at the bottom
                        // the field typed in last hands over its last character only when it loses focus: "-5" was
                        // checked as "-" (simulator, phase 4), so Save ends the typing first, then checks
                        focus = nil
                        DispatchQueue.main.async {
                            if let problem = save() { withAnimation { reader.scrollTo(problem, anchor: .top) } }
                        }
                    }
                }
            }
            // a swipe down doesn't drop typed changes: Cancel asks first (Apple's Sheets page; guidelines plan, 9)
            .toolbar {  // a number pad has no Return: Next and Done above the keyboard (Task 2.2)
                ToolbarItemGroup(placement: .keyboard) {
                    if let focus, let next = ItemFieldGroup.next(after: focus, in: typedOrder) {
                        Button("Next") { self.focus = next }
                    }
                    Spacer()
                    if quick != nil {  // the card's Done: only hides the keyboard, so the expiry can be set next
                        Button("Done") { focus = nil }.fontWeight(.semibold)
                    } else if row == nil {
                        if addsAnother { Button(InventoryWords.addAnother) { addAnother(reader) } }
                        Button(addWord) { finish(reader) }.fontWeight(.semibold)
                    } else {
                        Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { focus = nil }
                    }
                }
            }
            // and Quick add's held once it had a name, a looked-up one included (phase 4 entry fixes); Bought's name is
            // its line's, so it holds only once changed, as its own form did
            .interactiveDismissDisabled(QuickForm.holdsSwipe(changed: changed, isNew: row == nil && bought == nil,
                                                             name: typedText(Inventory.Label.item)))
            .confirmationDialog("Discard your changes?", isPresented: $asking, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .onAppear {
            fill()
            // a new item: its name is what to type first (Task 2.2); Bought's comes from its line, but a shortfall's
            // starts blank, and an expiry's (addition A; round 2, 2)
            if row == nil, barcode == nil, bought?.isListSentence ?? true { focusName() }
        }
        // Quick add: full height once the line turns amber, at open or when the lookup's category makes it so (C)
        .onChange(of: QuickForm.opensTall(needs), initial: true) { _, tall in if tall { quick?.grow() } }
        .announcesNeeds(needs)  // VoiceOver hears the line as its state changes (phase 2 review, M3)
        // a waiting add opened here reached the Mac: its row then is the base, so a later Mac change is refused (M5)
        .onChange(of: row?.id) {
            let base = QuickForm.arrived(openedID: openedID, openedValues: openedValues, row: row)
            openedID = base.id
            openedValues = base.values
        }
        .task { if looksUp, lookup.looking { await look() } }  // the form is usable at once; the answer fills blanks
        .onChange(of: typedText("Unit")) { _, unit in
            unitChanged()
            quick?.unit.wrappedValue = unit
        }
        // Quick add: a place, category or unit picked here is where the next scans go too, even if this item is
        // cancelled, as its card did (spec 5.3; owner, 2026-10-23)
        .onChange(of: pickedID(Inventory.Label.location)) { _, id in quick?.place.wrappedValue = Int(id) }
        .onChange(of: pickedID(Inventory.Label.category)) { _, id in quick?.category.wrappedValue = Int(id) }
    }

    /// Add Another is offered on a new item typed in, not one from a barcode, a refused add opened again (2.2) or
    /// Bought… (one item per line).
    var addsAnother: Bool { barcode == nil && prefill.isEmpty && bought == nil }

    /// Add Another: saves, then a fresh form with the place, category and unit kept, scrolled to its top ("Added …" over
    /// Name), or to a problem's field. The list draws only rows in sight, and focus can land only on a drawn one.
    func addAnother(_ reader: ScrollViewProxy) {
        focus = nil  // the field typed in last hands over its last character only when it loses focus
        DispatchQueue.main.async {
            let to = save(another: true) ?? "added"
            DispatchQueue.main.async { withAnimation { reader.scrollTo(to, anchor: .top) } }
        }
    }

    /// Done: adds and closes, or shows the problem.
    func finish(_ reader: ScrollViewProxy) {
        focus = nil
        DispatchQueue.main.async {
            if let problem = save() { withAnimation { reader.scrollTo(problem, anchor: .top) } }
        }
    }

    /// The typed fields in their groups' order, the order Return and Next move through (Task 2.2).
    var typedOrder: [String] {
        groups.filter { $0.group != .more || moreOpen }.flatMap(\.columns).filter { column in
            !["reference", "date", "bool"].contains(column.kind) && !PhoneEditRules.isPicked(column.label)
                && !PhoneEditRules.isPickOnly(column.label)
                && (column.label != Inventory.Label.caloriesEach || showsFood)
        }.map(\.colId)
    }

    func focusName() {
        guard let name = copy.column("Item")?.colId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focus = name }  // once the sheet has risen
    }

    /// Return moves to the next field, and says Done on the last (Task 2.2).
    func returnKey(_ column: PhoneInventory.Column) -> SubmitLabel {
        ItemFieldGroup.next(after: column.colId, in: typedOrder) == nil ? .done : .next
    }

    func submitted(_ column: PhoneInventory.Column) { focus = ItemFieldGroup.next(after: column.colId, in: typedOrder) }

    /// The columns in their groups (`ItemFieldGroup`), groups in order: those that show for the item as now typed
    /// (entry fixes plan, phase 3: Each holds, Pet food for and a generator's watts only where they count).
    var groups: [(group: ItemFieldGroup, columns: [PhoneInventory.Column])] {
        let id = copy.column(Inventory.Label.category).flatMap { picked[$0.colId] } ?? 0
        let group = copy.categories.first { $0.id == id }?.group
        let unit = copy.column("Unit").map { typed[$0.colId] ?? "" } ?? ""
        let item = copy.column(Inventory.Label.item).map { typed[$0.colId] ?? "" } ?? ""
        return ItemFieldGroup.grouped(columns.filter {
            let now = (typed[$0.colId] ?? "").trimmingCharacters(in: .whitespaces)
            return ItemFieldGroup.shows($0.label, group: group, unit: unit, item: item,
                                        filled: !now.isEmpty && now != "0" || (picked[$0.colId] ?? 0) != 0)
        }, label: \.label)
    }

    /// The what's-missing line (spec 5.3) from the fields as typed, the picked category's group and the units the lists
    /// job counts in; nil for an item no supply counts, or from a lists job before `units` (a blank Quantity is amber).
    var needs: ItemNeeds.Line? {
        func text(_ label: String) -> String { copy.column(label).map { typed[$0.colId] ?? "" } ?? "" }
        let id = copy.column(Inventory.Label.category).flatMap { picked[$0.colId] } ?? 0
        return ItemNeeds.line(group: copy.categories.first { $0.id == id }?.group,
                              quantity: InventoryValues.parseNumber(
                                  text(Inventory.Label.quantity).trimmingCharacters(in: .whitespaces)),
                              unit: text("Unit"),
                              holds: InventoryValues.parseNumber(text(Inventory.Label.eachHolds)),
                              holdsUnit: text(Inventory.Label.holdsUnit),
                              calories: InventoryValues.parseNumber(text(Inventory.Label.caloriesEach)),
                              petFoodFor: text(Inventory.Label.petFoodFor),
                              emptyUntilNeeded: PhoneEditRules.isOn(text(Inventory.Label.emptyUntilNeeded)),
                              units: copy.supply?.units)
    }

    /// Food only for food: the category picked is Food, or Calories each holds a figure.
    var showsFood: Bool {
        let id = copy.column(Inventory.Label.category).flatMap { picked[$0.colId] } ?? 0
        let calories = copy.column(Inventory.Label.caloriesEach).map { typed[$0.colId] ?? "" } ?? ""
        return ItemFieldGroup.showsFood(group: copy.categories.first { $0.id == id }?.group, calories: calories,
                                        scannedFood: looksUp && lookup.scannedFood)
    }

    // MARK: The code's lookup (moved from Quick add's card, Task 2.4)

    /// Under the name: "Looking it up…", then where it was found or why not, and what the food services have.
    @ViewBuilder var lookupLines: some View {
        if lookup.looking {
            Label(ProductLookup.lookingUp, systemImage: "magnifyingglass").foregroundStyle(PrepareMeColors.text2)
        } else if !lookup.heard.isEmpty {
            Text(lookup.heard).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
        }
        if let figures = lookup.figures { Text(figures).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
    }

    /// A found food's two boxes over Calories each ("Calories, whole package"), filled with what was found (USDA's
    /// first); they fill it with the two multiplied, on a package's Unit only, and Notes with how (2026-10-22).
    @ViewBuilder var servingsRows: some View {
        if looksUp, lookup.servingsShown {
            LabeledContent(ProductLookup.perServingLabel) {
                TextField(ProductLookup.perServingLabel, text: $lookup.perServing).keyboardType(.decimalPad)
                    .focused($focus, equals: Self.perServingFocus)
                    .multilineTextAlignment(.trailing).pmBox().frame(maxWidth: 110)
            }
            .onChange(of: lookup.perServing) { servingsChanged() }
            LabeledContent(ProductLookup.servingsLabel) {
                TextField(ProductLookup.servingsLabel, text: $lookup.servings).keyboardType(.decimalPad)
                    .focused($focus, equals: Self.servingsFocus)
                    .multilineTextAlignment(.trailing).pmBox().frame(maxWidth: 110)
            }
            .onChange(of: lookup.servings) { servingsChanged() }
            Text(ProductLookup.servingsHint).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
        }
    }

    static let perServingFocus = "lookup.perServing", servingsFocus = "lookup.servings"  // no column has these ids

    func typedText(_ label: String) -> String { copy.column(label).map { typed[$0.colId] ?? "" } ?? "" }
    func pickedID(_ label: String) -> Int64 { copy.column(label).flatMap { picked[$0.colId] } ?? 0 }

    var lookupFields: LookupFill.Fields {
        LookupFill.Fields(name: typedText(Inventory.Label.item), brand: typedText("Brand"),
                          model: typedText(Inventory.Label.model), notes: typedText("Notes"),
                          calories: typedText(Inventory.Label.caloriesEach), unit: typedText("Unit"),
                          category: copy.column(Inventory.Label.category).flatMap { picked[$0.colId] } ?? 0)
    }

    /// Asks once the form shows; the answer fills only the fields still blank then, so nothing typed meanwhile is
    /// written over, and Not found or no signal leave the form as typed. A lookup cut short (the form left for an item's
    /// page) puts nothing in and asks again on coming back.
    func look() async {
        fill()  // the form's own values first, so the answer lands on them
        guard let barcode else { return }
        let outcome = await ProductLookupClient.shared.lookup(barcode)
        guard !Task.isCancelled else { return }
        var fields = lookupFields
        let was = fields
        switch outcome {
        case .found(let info):
            lookup.found(info, fields: &fields,
                         categories: copy.categories.map { LookupFill.Category(id: $0.id, name: $0.name, group: $0.group) },
                         opened: copy.column(Inventory.Label.category).flatMap { first?.picked[$0.colId] } ?? 0)
        case .notFound: lookup.notFound()
        case .later: lookup.later(quick: quick != nil)
        }
        put(fields, was: was, asOpened: true)
        if fields != was, ItemFieldGroup.opensMore([fields.notes, fields.model]) { moreOpen = true }
    }

    /// A servings box changed: Calories each and Notes follow while they hold what the boxes last put there.
    func servingsChanged() {
        var fields = lookupFields
        let was = fields
        lookup.servingsChanged(&fields)
        put(fields, was: was, asOpened: false)
    }

    /// The Unit changed: the looked-up figure goes in on a package's Unit and comes out on any other.
    func unitChanged() {
        guard looksUp else { return }
        var fields = lookupFields
        let was = fields
        fields.calories = lookup.unitChanged(calories: fields.calories, unit: fields.unit)
        put(fields, was: was, asOpened: false)
    }

    /// Writes what changed. The lookup's own fill (`asOpened`) also goes into what Cancel compares against, wherever the
    /// field was still as the form opened, so it alone never asks "Discard your changes?"; anything typed still does.
    func put(_ fields: LookupFill.Fields, was: LookupFill.Fields, asOpened: Bool) {
        var opened = first
        for (label, new, old) in [(Inventory.Label.item, fields.name, was.name), ("Brand", fields.brand, was.brand),
                                  (Inventory.Label.model, fields.model, was.model), ("Notes", fields.notes, was.notes),
                                  (Inventory.Label.caloriesEach, fields.calories, was.calories)] {
            guard new != old, let column = copy.column(label) else { continue }
            typed[column.colId] = new
            if asOpened, (opened?.typed[column.colId] ?? "") == old { opened?.typed[column.colId] = new }
        }
        if fields.category != was.category, let column = copy.column(Inventory.Label.category) {
            picked[column.colId] = fields.category
            if asOpened, (opened?.picked[column.colId] ?? 0) == was.category {
                opened?.picked[column.colId] = fields.category
            }
        }
        if asOpened { first = opened }
    }

    /// A group's fields, each with its hint and its problem under it.
    @ViewBuilder func rows(_ columns: [PhoneInventory.Column]) -> some View {
        ForEach(columns, id: \.colId) { column in
            if column.kind == "date" {
                // the switch and the date each on a row of their own: in one row they sat too close (owner,
                // phase 4 gate)
                Toggle(column.label == "Expires" ? "Has an expiry date" : "Has a date",
                       isOn: Binding(get: { dated[column.colId] != nil },
                                     set: { dated[column.colId] = $0 ? (dated[column.colId] ?? Date()) : nil }))
                    .pmSwitch()
                if let day = dated[column.colId] {
                    VStack(alignment: .leading, spacing: 4) {
                        DatePicker(column.label, selection: Binding(get: { day }, set: { dated[column.colId] = $0 }),
                                   in: Self.days, displayedComponents: .date)
                        problem(column)
                    }
                }
                if column.label == "Expires" {
                    Button("Read the date", systemImage: "text.viewfinder") { reading.wrappedValue = true }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    field(column)
                    if let hint = PhoneEditRules.hint(columnLabel: column.label) {
                        Text(hint).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                            .fixedSize(horizontal: false, vertical: true)  // whole at the largest text sizes, never cut to "…"
                    }
                    problem(column)
                }
                .id(column.colId)
            }
        }
    }

    /// How many: Quantity as − n + with the Unit's box beside it, on one row.
    @ViewBuilder func amountRow(_ columns: [PhoneInventory.Column]) -> some View {
        let quantity = columns.first { InventoryFile.same($0.label, Inventory.Label.quantity) }
        let unit = columns.first { InventoryFile.same($0.label, "Unit") }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let quantity {
                    Button { step(quantity, by: -1) } label: { Image(systemName: "minus") }
                        .pmAction(fullWidth: false).accessibilityLabel("One less")
                    box(quantity, prompt: "0").frame(width: 64).multilineTextAlignment(.center)
                    Button { step(quantity, by: 1) } label: { Image(systemName: "plus") }
                        .pmAction(fullWidth: false).accessibilityLabel("One more")
                }
                Spacer(minLength: 8)
                if let unit { box(unit, prompt: "Unit").frame(maxWidth: 130) }
            }
            if let hint = unit.flatMap({ PhoneEditRules.hint(columnLabel: $0.label) }) {
                Text(hint).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)  // whole at the largest text sizes, never cut to "…"
            }
            ForEach([quantity, unit].compactMap { $0 }, id: \.colId) { problem($0) }
        }
        .id(quantity?.colId ?? "amount")
        // Each holds and the rest with their hint, their problem in red and a place to scroll to, as every other field:
        // a refused Each holds was a silent no-op (fix wave)
        rows(columns.filter { $0.colId != quantity?.colId && $0.colId != unit?.colId })
    }

    /// Quantity up or down by one, never under 0 nor over 10,000 (`PhoneEditRules.stepped`).
    func step(_ column: PhoneInventory.Column, by: Double) {
        typed[column.colId] = PhoneEditRules.stepped(typed[column.colId] ?? "", by: by)
    }

    /// A typed field: an outlined box, with its choices (Brand, Unit, Year's years) a tap away beside it.
    @ViewBuilder func box(_ column: PhoneInventory.Column, prompt: String? = nil) -> some View {
        HStack(spacing: 4) {
            TextField(prompt ?? column.label, text: Binding(get: { typed[column.colId] ?? "" },
                                                            set: { typed[column.colId] = $0 }))
                .accessibilityLabel(column.label)  // its column, even once it holds a number (entry fixes, phase 4)
                .focused($focus, equals: column.colId)
                .keyboardType(["numeric", "int"].contains(column.kind) || PhoneEditRules.isAmount(column.label)
                              ? .decimalPad : .default)
                .textInputAutocapitalization(PhoneEditRules.typedAsIs(column.label) ? .never : .sentences)
                .autocorrectionDisabled(PhoneEditRules.typedAsIs(column.label))
                .submitLabel(returnKey(column))
                .onSubmit { submitted(column) }
            // Year's offered years, with the item's own after them; none for an amount (spec 5.4)
            let offered = PhoneEditRules.boxChoices(table: "Inventory", columnLabel: column.label,
                                                    choices: column.choices,
                                                    current: first?.typed[column.colId] ?? "", now: .now)
            if !offered.isEmpty {
                Menu {
                    ForEach(offered, id: \.self) { choice in Button(choice) { typed[column.colId] = choice } }
                } label: {
                    Image(systemName: "chevron.down").foregroundStyle(PrepareMeColors.edge)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())  // Apple's 44-point target
                }
                .accessibilityLabel("\(column.label) choices")
            }
        }
        .pmBox()
    }

    @ViewBuilder func field(_ column: PhoneInventory.Column) -> some View {
        switch column.kind {
        case "reference":  // a pick from a list: a place, a category
            let names = copy.names(column)
            let id = picked[column.colId] ?? 0
            let place = column.target == "Locations"
            // shown in title case, as the item's page and the Mac show them; the pick sends the id (fix round 1)
            let shown = { (key: Int64) in InventoryLook.title(place ? copy.path(key) : names[key] ?? "") }
            LabeledContent(column.label) {  // a place by its path: "Garage › Shelf 2", searchable (Task 1.6)
                PickListButton(title: column.label, value: id == 0 ? "" : shown(id),
                               choices: names.map { PickChoice(id: $0.key, title: shown($0.key)) },
                               picked: Binding(get: { picked[column.colId] ?? 0 }, set: { picked[column.colId] = $0 }),
                               newTitle: !model.mayEdit ? nil : place ? PickLists.newPlaceTitle
                                   : column.target == "Categories" ? PickLists.newCategoryTitle : nil) { done in
                    if place {
                        NewPlaceForm(places: copy.places.map { PickChoice(id: $0.id, title: InventoryLook.title(copy.path($0.id))) },
                                     others: copy.places.map { (id: $0.id, name: $0.name, keptIn: $0.keptIn) },
                                     keptIn: id, add: model.addPlace, done: done)
                    } else {
                        NewCategoryForm(others: copy.categories.map(\.name), add: model.addCategory, done: done)
                    }
                }
            }
        case _ where PhoneEditRules.isPicked(column.label):  // Grab: "10 min", "1 hour", none, or the item's own
            let options = PhoneEditRules.grabOptions(Self.grabChoices(column), current: first?.typed[column.colId] ?? "")
            VStack(alignment: .leading, spacing: 6) {
                Text(column.label)
                Picker(column.label, selection: Binding(get: { typed[column.colId] ?? "" },
                                                        set: { typed[column.colId] = $0 })) {
                    Text("None").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        case "bool":  // Empty until needed, Keep past date (spec 5.3): kept as the Mac shows a tick, sent as 1 or 0
            Toggle(column.label, isOn: Binding(get: { PhoneEditRules.isOn(typed[column.colId] ?? "") },
                                               set: { typed[column.colId] = $0 ? "Yes" : "" }))
                .pmSwitch()
        case _ where PhoneEditRules.isPickOnly(column.label):  // Manual, Holds unit: a pick, never typed (spec 5.4)
            let options = PhoneEditRules.pickChoices(column.label, choices: column.choices,
                                                     stored: first?.typed[column.colId] ?? "")
            Picker(column.label, selection: Binding(get: { typed[column.colId] ?? "" },
                                                    set: { typed[column.colId] = $0 })) {
                ForEach(options, id: \.self) {  // Holds unit's blank as the form's other picks show one
                    Text($0.isEmpty ? "None" : $0).tag(PhoneEditRules.pickStored(column.label, shown: $0))
                }
            }
            .pickerStyle(.menu)
        case _ where InventoryFile.same(column.label, Inventory.Label.item):  // the name: its own large box
            TextField("Name", text: Binding(get: { typed[column.colId] ?? "" }, set: { typed[column.colId] = $0 }))
                .focused($focus, equals: column.colId)
                .submitLabel(returnKey(column))
                .onSubmit { submitted(column) }
                .font(.pmEntry)
                .pmBox()
            if looksUp { lookupLines }
        case _ where InventoryFile.same(column.label, Inventory.Label.caloriesEach):  // the one key fact, in blue
            WholeCalories(calories: Binding(get: { typed[column.colId] ?? "" }, set: { typed[column.colId] = $0 }),
                          how: looksUp ? lookup.caloriesNote(calories: typed[column.colId] ?? "",
                                                             unit: typedText("Unit")) : nil)
                .focused($focus, equals: column.colId)
        default:
            LabeledContent(column.label) {
                box(column).frame(maxWidth: 190).multilineTextAlignment(.trailing)
            }
        }
    }

    /// A field's problem, in red under it.
    @ViewBuilder func problem(_ column: PhoneInventory.Column) -> some View {
        if let problem = problems[column.colId] {
            Text(problem).font(.pmNote).foregroundStyle(PrepareMeColors.red)
        }
    }

    /// The item's own values, then a refused edit's on top.
    func fill() {
        guard first == nil else { return }
        base = shown(row?.values ?? [:], typedAs: [])
        openedValues = row?.values
        openedID = row?.id
        var values = row?.values ?? [:]
        values.merge(prefill) { _, refused in refused }
        // Edit again on a refused add shows exactly what was typed, no blank filled (fix wave)
        if QuickForm.fillsBlanks(isNew: row == nil, prefill: prefill) {
            if let quick {  // Quick add's own place, category and unit, carried from scan to scan
                for (label, value) in [(Inventory.Label.location, SQLValue.int(Int64(quick.place.wrappedValue))),
                                       (Inventory.Label.category, .int(Int64(quick.category.wrappedValue))),
                                       ("Unit", .text(QuickForm.Memory.startUnit(quick.unit.wrappedValue)))] {
                    if let column = copy.column(label) { values[column.colId] = value }
                }
            } else if let bought {  // the To Buy line's name, need, unit and category, each changeable
                values.merge(QuickForm.boughtValues(bought, colId: { copy.column($0)?.colId },
                                                    categories: copy.categories)) { own, _ in own }
            } else {  // Add: the one memory, Quick add's and Add's, a removed place or category forgotten
                let memory = QuickForm.Memory.forAdd(place: lastPlace, category: lastCategory, unit: lastUnit,
                                                     places: copy.places.map(\.id),
                                                     categories: copy.categories.map(\.id))
                for (label, value) in [(Inventory.Label.location, SQLValue.int(Int64(memory.place))),
                                       (Inventory.Label.category, .int(Int64(memory.category))),
                                       ("Unit", .text(memory.unit))] {
                    if let column = copy.column(label), values[column.colId] == nil { values[column.colId] = value }
                }
            }
            if let quantity = copy.column(Inventory.Label.quantity), values[quantity.colId] == nil {
                values[quantity.colId] = .int(1)  // a new item counts 1 until changed (owner, 2026-10-23)
            }
        }
        let opened = shown(values, typedAs: Set(prefill.keys))
        typed = opened.typed
        picked = opened.picked
        dated = opened.dated
        first = opened
        let more = groups.first { $0.group == .more }?.columns ?? []
        moreOpen = ItemFieldGroup.opensMore(more.map { asText($0, in: opened) }.filter { $0 != "0" })
    }

    /// Values as the form shows them: a cell as the item's page shows it, a stored day as that day (a date the Mac
    /// keeps as text too), a Grab as its choice, and a refused edit's or a new item's value as it was typed.
    func shown(_ values: [String: SQLValue], typedAs prefilled: Set<String>) -> Snapshot {
        var typed: [String: String] = [:], picked: [String: Int64] = [:], dated: [String: Date] = [:]
        for column in columns {
            let value = values[column.colId] ?? .null
            switch column.kind {
            case "reference": picked[column.colId] = value.whole ?? 0
            case "date":
                if let seconds = PhoneEditRules.storedDay(value), let day = InventoryValues.day(seconds) {
                    dated[column.colId] = Self.local(day)
                }
            default:
                var text = row.map { copy.cell($0, column) } ?? ""
                if prefilled.contains(column.colId) || row == nil { text = InventoryValues.plain(value) }
                if PhoneEditRules.isPicked(column.label) { text = PhoneEditRules.grabShown(text, choices: Self.grabChoices(column)) }
                if PhoneEditRules.isPickOnly(column.label) {  // as its menu's choice, so it shows selected
                    text = PhoneEditRules.pickShown(column.label, stored: text, choices: column.choices)
                }
                typed[column.colId] = text
            }
        }
        return Snapshot(typed: typed, picked: picked, dated: dated)
    }

    /// A column's value in a snapshot as one piece of text, to tell which columns Save must send.
    func asText(_ column: PhoneInventory.Column, in snapshot: Snapshot) -> String {
        switch column.kind {
        case "reference": String(snapshot.picked[column.colId] ?? 0)
        case "date": snapshot.dated[column.colId].map(Self.day) ?? ""
        default: snapshot.typed[column.colId] ?? ""
        }
    }

    /// How much of the screen the keyboard's frame covers, from its frame-change notice (the notice's object is the
    /// screen, iOS 16.1 and later); its whole height where none is given.
    static func keyboardShown(_ note: Notification) -> Double {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return 0 }
        guard let screen = (note.object as? UIScreen)?.bounds else { return end.height }
        return end.intersection(screen).height
    }

    static func grabChoices(_ column: PhoneInventory.Column) -> [String] {
        column.choices.isEmpty ? Inventory.grabChoices : column.choices
    }

    /// The days the Mac reads (InventoryValues.parseDay: 1900 to 2200).
    static let days = local("1900-01-01")!...local("2200-12-31")!

    /// "2026-11-15" as that day on this phone's calendar, at noon, so no time zone moves it to another day.
    static func local(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// The day picked, as the Mac stores a typed day.
    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The edits, or the first field with a problem (every problem is shown under its field). What is sent, and what
    /// is checked, is `QuickForm.sent`'s (phase 2 review, 12); the form sends it and remembers.
    func save(another: Bool = false) -> String? {
        func texts(_ snapshot: Snapshot) -> [String: String] {
            Dictionary(columns.map { ($0.colId, asText($0, in: snapshot)) }) { kept, _ in kept }
        }
        let new: QuickForm.NewItem = if let quick {
            .quick(place: quick.place.wrappedValue, category: quick.category.wrappedValue)
        } else if let bought { .bought(bought) } else { .add(editAgain: !prefill.isEmpty) }
        let sent = QuickForm.sent(copy: copy, columns: columns, row: row, openedID: openedID,
                                  openedValues: openedValues, was: base.map(texts), now: texts(now), new: new,
                                  barcode: barcode, saving: &saving)
        problems = [:]
        var queued = true  // every edit is waiting for the Mac; a phone that may not edit queues none
        switch sent {
        case .problems(let found):
            problems = found
            return columns.first { found[$0.colId] != nil }?.colId
        case .busy: return nil
        case .waitingAdd(let id, let all):
            let name = copy.column(Inventory.Label.item)?.colId ?? ""
            Task {  // a send of it under way is waited for first
                if await model.changeWaitingAdd(id, to: all) {
                    onSaved()
                    dismiss()
                } else {
                    problems = [name: WaitingChanges.sentWhileEditing]
                    saving = false
                }
            }
            return nil
        case .cells(let cells):
            for cell in cells {
                if model.edit(cell.change, what: cell.what) == nil { queued = false }
            }
        case .nothing:
            dismiss()
            return nil
        case .new(let change, let what, let name, let remember, let namesLater):
            if let remember {  // Add's and Scan's new item: only what was picked or typed (review, 2)
                if let place = remember.place { lastPlace = place }
                if let category = remember.category { lastCategory = category }
                if let unit = remember.unit { lastUnit = unit }
            }
            let id = model.edit(change, what: what)
            queued = id != nil
            if let quick, let barcode, let id {
                if namesLater { ProductLookupClient.shared.waitForName(barcode) }
                quick.done(QuickAddView.Done(edit: id, what: name, plusOne: nil, code: barcode))
            }
        }
        if queued { onSaved() }  // "Edit again" forgets the refusal only once its edit is waiting again
        if another, row == nil, queued {  // Add Another: a fresh form, the last place, category and unit kept (2.2)
            let name = typedText(Inventory.Label.item).trimmingCharacters(in: .whitespacesAndNewlines)
            first = nil
            fill()
            saving = false
            addedNote = InventoryWords.addedTypeNext(name)
            focusName()
            return nil
        }
        dismiss()
        return nil
    }
}

/// A sheet whose copy went away (pairing again clears it until the next look answers): why, and Close, never a
/// blank sheet with no way out (fix wave).
struct NoCopyYet: View {
    static let heading = "The inventory comes from the Mac."
    static let openAtHome = "Open this at home, on the Mac's Wi-Fi, once; after that it reads anywhere."
    let close: () -> Void
    @ObservedObject private var model = PhoneInventoryModel.shared

    /// The why in one line, for a note: the look's problem, or where to open it.
    static func line(_ problem: String?) -> String { "\(heading) \(problem ?? openAtHome)" }

    var body: some View {
        NavigationStack {
            PMStateScreen {
                PMState(symbol: "shippingbox", heading: Self.heading, line: model.problem ?? Self.openAtHome,
                        kind: model.problem == nil ? .info : .attention)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: close) } }
        }
    }
}

/// To buy on the phone: the lists' ranked list; an adult's phone marks Bought (adding the item) or Not needed, or adds
/// its own.
struct PhoneToBuyView: View {
    @ObservedObject private var model = PhoneInventoryModel.shared
    @State private var buying: ToBuyList.Item?
    @State private var adding = false

    var body: some View {
        PMList {
            if let copy = model.shown {
                if copy.toBuy.isEmpty {  // what to do next (the Apple guidelines plan, phase 9)
                    Text(model.canEdit ? "Nothing to buy. Add your own with the button at the bottom." : "Nothing to buy.")
                        .foregroundStyle(PrepareMeColors.text2)
                }
                ForEach(copy.toBuy) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(InventoryLook.title(item.text)).font(.pmHeadline)
                        if item.lifeSafety { LifeSafetyTag() }
                        let line = [[item.need.map(InventoryValues.number), item.unit].compactMap { $0 }
                                        .filter { !$0.isEmpty }.joined(separator: " "),
                                    InventoryLook.title(item.category ?? "")].filter { !$0.isEmpty }
                        if !line.isEmpty { Text(line.joined(separator: ", ")).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
                        if model.canEdit {
                            HStack {
                                Button("Bought…") { buying = item }.pmAction()
                                Button("Not needed") { notNeeded(item) }.pmAction()
                            }
                        }
                    }
                    // the buttons, by swipe too (the Apple guidelines plan, phase 9); written apart from the buttons
                    // above, which PaletteTests finds by their words
                    .swipeActions(edge: .leading) {
                        if model.canEdit { Button { buying = item } label: { Text("Bought…") }.tint(PrepareMeColors.okMark) }
                    }
                    .swipeActions(edge: .trailing) {
                        if model.canEdit { Button { notNeeded(item) } label: { Text("Not needed") } }
                    }
                }
                let own = model.outbox.ownItems
                if !own.isEmpty {
                    Section(pmTitle: "Yours, waiting for the Mac") { ForEach(own) { Text($0.text) } }
                }
            }
        }
        .navigationTitle("To Buy")
        .pmTitleSmall()
        .pmAddBar(show: model.canEdit) {
            Button { adding = true } label: { Label("Add your own", systemImage: "plus") }.pmAction()
        }
        .sheet(item: $buying) { item in  // the full item form, filled in from the line (spec 5.3, Task 2.5)
            if let copy = model.shown {
                NavigationStack { ItemForm(copy: copy, row: nil, bought: item) }
            } else {
                NoCopyYet { buying = nil }
            }
        }
        .sheet(isPresented: $adding) { NavigationStack { PhoneOwnItemForm() } }
    }

    private func notNeeded(_ item: ToBuyList.Item) {
        model.edit(.tick(ToBuyTick(kind: .notNeeded, item: item.id)), what: "\(item.text): not needed")
    }
}

struct PhoneOwnItemForm: View {
    @ObservedObject private var model = PhoneInventoryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var need = ""
    @State private var unit = ""
    @State private var group = "Other"

    var body: some View {
        PMForm {
            TextField("Item", text: $text)
            TextField("How many", text: $need).keyboardType(.decimalPad)
            TextField("Unit", text: $unit)
            Picker("Group", selection: $group) { ForEach(ToBuyList.groups, id: \.self) { Text(InventoryLook.title($0)).tag($0) } }
        }
        .navigationTitle("Add to To Buy")
        .pmTitleSmall()
        .interactiveDismissDisabled(!(text + need + unit).isEmpty)  // as Bought: Cancel, not a stray swipe
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let amount = InventoryValues.parseNumber(need.trimmingCharacters(in: .whitespaces))
                    model.edit(.tick(ToBuyTick(kind: .add, text: text.trimmingCharacters(in: .whitespaces),
                                               need: amount.map { max(0, $0) }, unit: unit, category: group)),
                               what: "To Buy: \(text)")
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
#endif
