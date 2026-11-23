import Foundation

/// The inventory on the phones (plan phase 7, slice 5). The Mac app writes `phone-inventory.json` into the inventory
/// folder whenever the inventory or To buy changes; the phones' service serves it (GET /inventory.json) to every paired
/// phone, and takes edits from adults' phones (POST /inventory/edits) into the inventory folder's `inbox`, which the
/// Mac app applies through InventoryEditor, the file's only writer, with the same checks as its own edits. Private
/// ("Mac only") rows and the Mac only column never reach a phone, and no phone edit may touch them.
public struct PhoneInventory: Codable, Equatable, Sendable {
    public struct Column: Codable, Equatable, Sendable {
        public let colId: String
        public let label: String
        public let kind: String  // text, numeric, int, bool, date, choice, reference, other
        public let target: String?  // a reference's table: "Locations" or "Categories"
        public let choices: [String]
        public let editable: Bool
    }

    public struct Row: Codable, Equatable, Identifiable, Sendable {
        public let id: Int64
        public let position: Int
        public let values: [String: SQLValue]
        /// The item's manual: its path in the manuals library (ItemManuals.contentPath), opened as
        /// URL(zimFileID: ItemManuals.volumeID, contentPath:); nil when it has none, and from an older Mac (top-ten
        /// plan, phase 7). Never a Private item's: those rows never reach a phone.
        public let manual: String?

        public init(id: Int64, position: Int, values: [String: SQLValue], manual: String? = nil) {
            self.id = id
            self.position = position
            self.values = values
            self.manual = manual
        }
    }

    public struct Place: Codable, Equatable, Identifiable, Sendable {
        public let id: Int64
        public let name: String
        public let label: String
        public let grab: String
        public let keptIn: Int64?
        public var vehicle: Bool? = nil  // Locations' Vehicle tick (plan phase 7, part 2); nil from an older Mac
    }

    /// A place, then the one it is kept in, and so on out (a loop is cut).
    public func chain(_ id: Int64) -> [Int64] {
        let byID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        guard byID[id] != nil else { return [] }
        var found = [id]
        while let next = byID[found[found.count - 1]]?.keptIn, byID[next] != nil, !found.contains(next) {
            found.append(next)
        }
        return found
    }

    /// Where a place is, from the outside in: "Truck › Truck drawer › Truck go-bag".
    public func path(_ id: Int64) -> String {
        let byID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0.name) })
        return chain(id).reversed().compactMap { byID[$0] }.joined(separator: " › ")
    }

    /// The vehicle a place sits in (itself, when it is one), or nil.
    public func vehicle(holding id: Int64) -> Int64? {
        let vehicles = Set(places.filter { $0.vehicle == true }.map(\.id))
        return chain(id).first(where: vehicles.contains)
    }

    // The Inventory tab's Locations and Vehicles (step 8a), as `Inventory.shownLocations`, `vehicleRows` and
    // `shownInside`: a vehicle is shown under Vehicles only, never under Locations nor inside the place it is parked in.

    /// Locations: the top-level places that aren't vehicles, in the Mac's order.
    public var shownLocations: [Place] { places.filter { $0.keptIn == nil && $0.vehicle != true } }

    /// Vehicles: every place ticked Vehicle, in the Mac's order.
    public var vehicles: [Place] { places.filter { $0.vehicle == true } }

    /// What a place opens to: the places and bins kept directly in it, less any vehicle.
    public func shownInside(_ id: Int64) -> [Place] { places.filter { $0.keptIn == id && $0.vehicle != true } }

    public struct Category: Codable, Equatable, Identifiable, Sendable {
        public let id: Int64
        public let name: String
        public let group: String?
    }

    /// What became of a phone's edit: done (and an added row's id), or refused in the Mac's fixed words.
    public struct Result: Codable, Equatable, Sendable {
        public let at: String
        public let refused: String?
        public let row: Int64?
    }

    /// An item two phones changed, each without the other's change in view (away from home, or with the Mac off), whose
    /// changes the Mac kept both of, as it keeps every change (beta run 3's S4.4, run 2's B2-13; InventoryFile
    /// .alsoChanged). A phone that made one of `edits` says AlsoChanged.line under the item's number until `until`, a
    /// day after the later change reached the Mac (PhoneOutbox.alsoChanged); any other phone says nothing.
    public struct AlsoChanged: Codable, Equatable, Sendable {
        public let item: Int64
        public let until: String
        public let edits: [String]

        public init(item: Int64, until: String, edits: [String]) {
            self.item = item
            self.until = until
            self.edits = edits
        }

        /// Under the item's number on the phone (the owner's words, B2-13)
        public static let line = "Also changed on another phone"
        /// How long the line shows once the later change reached the Mac
        public static let shownFor: TimeInterval = 86_400
    }

    public static let fileName = "phone-inventory.json"

    /// A column as the editor's own, so the phone shows and stores a value exactly as the Mac does (InventoryValues).
    public func inventoryColumn(_ column: Column) -> InventoryColumn {
        let kind: InventoryColumn.Kind = switch column.kind {
        case "text": .text
        case "numeric": .numeric
        case "int": .int
        case "bool": .bool
        case "date": .date
        case "choice": .choice
        case "reference": .reference(table: column.target ?? "")
        default: .other
        }
        return InventoryColumn(ref: 0, colId: column.colId, label: column.label, type: column.kind, kind: kind,
                               isFormula: !column.editable, choices: column.choices,
                               shownColId: column.kind == "reference" ? "Name" : nil, displayColId: nil)
    }

    /// A reference column's names: the places' or the categories', by row id.
    public func names(_ column: Column) -> [Int64: String] {
        switch column.target {
        case "Locations": Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0.name) })
        case "Categories": Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        default: [:]
        }
    }

    public func column(_ label: String) -> Column? {
        columns.first { InventoryFile.same($0.label, label) }
    }

    /// The item to show for `id`: a new item's id below 0 becomes the Mac's own once the Mac has answered its add, so a
    /// screen opened on it while it waited follows it (entry fixes plan, Task 2.5).
    public func settledID(_ id: Int64) -> Int64 {
        guard id < 0, !items.contains(where: { $0.id == id }) else { return id }
        return results.first { PhoneOutbox.temporaryID($0.key) == id }?.value.row ?? id
    }

    /// A phone's delete of `item`: it says what this phone saw, so the Mac keeps an item changed since (owner,
    /// 2026-11-18, by click: "Warn and refuse stale").
    public static func delete(_ item: Row) -> InventoryChange {
        .deleteSeen(row: item.id, cells: item.values)
    }

    /// Undo last on a new item already sent: wait for the Mac's answer to that add (`edit`, the phone's edit id), then
    /// delete the row that answer made, never whichever item holds its code now (the Mac moves a code to its newest
    /// item, so another phone's add of the same product may hold it). A refused add, or its row gone, is nothing to do.
    public enum TakeBack: Equatable, Sendable { case wait, gone, delete(InventoryChange) }
    public func takeBack(add edit: String) -> TakeBack {
        guard let result = results[edit] else { return .wait }
        guard result.refused == nil, let id = result.row, let item = items.first(where: { $0.id == id }) else {
            return .gone
        }
        return .delete(Self.delete(item))
    }

    /// Ticked Keep past date (Inventory.keptPastDate): never in Expiring soon or a reminder.
    public func keptPastDate(_ row: Row) -> Bool {
        column(Inventory.Label.keepPastDate).flatMap { row.values[$0.colId]?.number }.map { $0 != 0 } ?? false
    }

    /// `values` with a place or category cell naming a waiting row this copy no longer has (a new place the Mac refused)
    /// set to none (the final review of the entry fixes' phase 1, 2): Edit again then never sends it to be refused again.
    public func withoutGoneWaiting(_ values: [String: SQLValue]) -> [String: SQLValue] {
        var out = values
        for column in columns where column.kind == "reference" {
            guard let id = values[column.colId]?.whole, id < 0 else { continue }
            let there = column.target == "Locations" ? places.contains { $0.id == id }
                : categories.contains { $0.id == id }
            if !there { out[column.colId] = .int(0) }
        }
        return out
    }

    /// `id` and every place kept in it, at any depth (a loop can't come from the Mac; it is cut here all the same).
    public func within(_ id: Int64) -> Set<Int64> {
        var found: Set<Int64> = [id]
        var added = true
        while added {
            added = false
            for place in places where !found.contains(place.id) {
                if let parent = place.keptIn, found.contains(parent) {
                    found.insert(place.id)
                    added = true
                }
            }
        }
        return found
    }

    public var writtenAt: String
    /// The copy with its time set aside: what the Mac compares to tell whether the phones' copy must be written again.
    /// Every other field counts, so one added later can't be left out (the pins were, and a Put back on the Mac waited
    /// 10 minutes for the phones: owner checks §84, 2026-11-15).
    public var unstamped: PhoneInventory {
        var copy = self
        copy.writtenAt = ""
        return copy
    }
    public let columns: [Column]
    public let items: [Row]
    public let places: [Place]
    public let categories: [Category]
    public let headsUpDays: Int
    public let toBuy: [ToBuyList.Item]
    public let results: [String: Result]  // by the phone's edit id
    public let barcodes: [String: Int64]?  // slice 6: product codes scanned before, by code; never a Private item's
    /// The street map's rally points and routes (plan phase 9), every one: each phone shows them; an adult's may rename
    /// one, change its note or delete it, through the Mac (PhoneRules).
    public let marks: [MapMark]?
    /// The Start point from a Mac before the map pins plan (2026-11-14), which sent it apart from `marks`; still read so
    /// that Mac's copy parses, never shown. An updated Mac sends none: the Start point is Mac only.
    public let start: MapMark?
    /// The shared pins (docs/plans/2026-11-12-one-shared-marks.md), apart from `marks` for the same reason as `start`;
    /// nil from a Mac before them, which a phone reads as "this Mac doesn't take pins yet".
    public var pins: [MapMark]?
    /// What the phone's map and list show: the marks, never a Start point (Mac only since the map pins plan).
    public var mapMarks: [MapMark] { marks ?? [] }
    /// To do, Upkeep and the Event mode switch (plan phase 7, part 2), once the lists are in the app; nil before.
    public let lists: PhoneLists?
    /// Each counted row's share of the days of water and food (plan phase 7, part 2; SupplyShares.swift), so the phone
    /// counts them again from its own copy; nil until the lists job has written them.
    public let supply: SupplyShares?
    /// The Settings' pets (the settings redesign; owner, 2026-10-19: the names go to the phones), each one's name, kind
    /// and weight; nothing on the phone reads them yet (the calculators take the pets' weights from supply.json). Nil
    /// from an older Mac, or while the Mac can't read them.
    public let pets: [HouseholdPet]?
    /// The use log since event mode came on (step 8c, section 4; UseLog.swift): each tap's supply and amount, for the
    /// phone's run-out day. Nil out of event mode, from an older Mac, or while the log can't be read.
    public let useLog: PhoneUseLog?
    /// The items two phones changed apart, for a day after the Mac kept both (AlsoChanged; S4.4). Nil when there are
    /// none, and from an older Mac.
    public let alsoChanged: [AlsoChanged]?
    /// Audit P2h (`FileFormat`): the format the Mac wrote the copy in; nil (format 1) from a Mac before it. A phone that
    /// meets a newer one keeps the copy it holds (MacLink.inventory, `FolderOffer.readInventory`).
    public var format: Int?

    public init(writtenAt: String, columns: [Column], items: [Row], places: [Place], categories: [Category],
                headsUpDays: Int, toBuy: [ToBuyList.Item], results: [String: Result], barcodes: [String: Int64]? = nil,
                marks: [MapMark]? = nil, start: MapMark? = nil, lists: PhoneLists? = nil, supply: SupplyShares? = nil,
                pets: [HouseholdPet]? = nil, useLog: PhoneUseLog? = nil, alsoChanged: [AlsoChanged]? = nil,
                pins: [MapMark]? = nil, format: Int? = nil) {
        self.format = format
        self.alsoChanged = alsoChanged
        self.pins = pins
        self.start = start
        self.barcodes = barcodes
        self.pets = pets
        self.useLog = useLog
        self.marks = marks
        self.lists = lists
        self.supply = supply
        self.writtenAt = writtenAt
        self.columns = columns
        self.items = items
        self.places = places
        self.categories = categories
        self.headsUpDays = headsUpDays
        self.toBuy = toBuy
        self.results = results
    }

    /// The inventory as phones see it: every row but the Private ones, every column but Mac only. `manuals`: the items
    /// with a manual in item-manuals (ItemManuals), by row id; a Private item's never reaches the copy. `useLog`: the
    /// log since event mode came on (PhoneUseLog.make), nil out of event mode; the shares go without their Private
    /// rows' numbers. `alsoChanged`: InventoryFile.alsoChanged's, a Private item's left out, nil when none is left.
    public static func make(_ inventory: Inventory, toBuy: ToBuyList?, waiting: [ToBuyTick], results: [String: Result],
                            barcodes: [String: Int64] = [:], supply: SupplyShares? = nil, manuals: Set<Int64> = [],
                            useLog: PhoneUseLog? = nil, alsoChanged: [AlsoChanged] = [],
                            makers: [MapMark.PhoneName] = [], now: Date = Date()) -> PhoneInventory {
        let shared = Set(inventory.itemRows.filter { !inventory.isPrivate($0) }.map(\.id))
        let macOnly = inventory.macOnlyColumns  // Mac only, and the insurance record's Purchased, Price and Serial number
        let columns = inventory.items.columns.filter { !macOnly.contains($0.colId) }
        let ticked = Set(waiting.map(\.item))
        let merged = alsoChanged.filter { shared.contains($0.item) }
        return PhoneInventory(
            writtenAt: ISO8601DateFormatter().string(from: now),
            columns: columns.map { column in
                let (kind, target): (String, String?) = switch column.kind {
                case .text: ("text", nil)
                case .numeric: ("numeric", nil)
                case .int: ("int", nil)
                case .bool: ("bool", nil)
                case .date: ("date", nil)
                case .choice: ("choice", nil)
                case .reference(let table): ("reference", table)
                case .other: ("other", nil)
                }
                return Column(colId: column.colId, label: column.label, kind: kind, target: target,
                              choices: column.choices, editable: column.editable)
            },
            items: inventory.itemRows.filter { !inventory.isPrivate($0) }.map { row in
                Row(id: row.id, position: row.position,
                    values: row.values.filter { key, _ in columns.contains { $0.colId == key } },
                    manual: manuals.contains(row.id) ? ItemManuals.contentPath(itemID: row.id) : nil)
            },
            places: inventory.locationRows.map { row in
                Place(id: row.id, name: inventory.name(ofLocation: row.id),
                      label: inventory.locations.column(Inventory.Label.label).map { InventoryValues.plain(row[$0]) } ?? "",
                      grab: inventory.locations.column(Inventory.Label.grab).map { InventoryValues.plain(row[$0]) } ?? "",
                      keptIn: inventory.keptIn(row.id), vehicle: inventory.isVehicle(row.id))
            },
            categories: inventory.categoryRows.map { row in
                Category(id: row.id,
                         name: inventory.categories.column(Inventory.Label.name).map { InventoryValues.plain(row[$0]) } ?? "",
                         group: inventory.group(ofCategory: row.id))
            },
            headsUpDays: inventory.headsUpDays,
            toBuy: (toBuy?.items ?? []).filter { !ticked.contains($0.id) },
            results: results,
            barcodes: barcodes.filter { shared.contains($0.value) },
            // each with the owner's name for the phone that made it, when there is one (owner, 2026-11-12)
            marks: inventory.marks.filter { $0.kind != .start }.map { $0.forPhones(makers) },
            start: nil,  // Mac only (the map pins plan, 2026-11-14)
            lists: inventory.lists.map(PhoneLists.init),
            supply: supply?.forPhones,
            pets: inventory.petsUnreadable ? nil : inventory.pets,
            useLog: useLog,
            alsoChanged: merged.isEmpty ? nil : merged,
            pins: inventory.pins.map { $0.forPhones(makers) },
            format: FileFormat.current)
    }

    public static func read(in folder: URL) -> PhoneInventory? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(PhoneInventory.self, from: data)
    }

    public func write(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFile.write(try encoder.encode(self), to: folder.appendingPathComponent(Self.fileName))
    }
}

/// The phone's saved inventory copy (the app's inventory-cache.json): the copy, the role last answered, when it was
/// fetched, and whether it came from the PrepareMe Backup (beta run 2, B2-04). A backup copy reads only: it never
/// allows an edit, whatever role is saved, and has no last look, so the next library check fetches the Mac's copy. The
/// keys are the ones the app's cache always had, so a cache from before `fromBackup` reads as a Mac copy.
public struct PhoneInventoryCache: Codable, Equatable, Sendable {
    public let copy: PhoneInventory
    public let canEdit: Bool
    public let at: Date
    /// nil in a cache from before B2-04, which came from the Mac
    public var fromBackup: Bool?

    public init(copy: PhoneInventory, canEdit: Bool, at: Date, fromBackup: Bool) {
        self.copy = copy
        self.canEdit = canEdit
        self.at = at
        self.fromBackup = fromBackup
    }

    public var isFromBackup: Bool { fromBackup == true }
    public var mayEdit: Bool { Self.mayEdit(canEdit: canEdit, fromBackup: isFromBackup) }
    /// When the Mac's copy was last fetched; nil for a backup copy
    public var lastLook: Date? { isFromBackup ? nil : at }

    /// The one rule for edits on a phone: its role allows them and the copy didn't come from the backup
    public static func mayEdit(canEdit: Bool, fromBackup: Bool) -> Bool { canEdit && !fromBackup }

    /// The saved copy at `url`, or nil when there is none or it can't be read now. A launch before the phone's first
    /// unlock after a restart can't read it, so the app asks again each time it comes forward holding none (audit D2).
    public static func read(_ url: URL) -> PhoneInventoryCache? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PhoneInventoryCache.self, from: $0) }
    }
}

/// One edit from a phone: its own id (so a resend is never applied twice), the change, and when it was made on the
/// phone (step 8c, section 4: a Used 1's tap time for the use log; nil from a phone before it).
public struct PhoneEdit: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let change: InventoryChange
    public let at: String?
    /// Set only when true (B2-08, fix round 1): the item screen's 1 more, which may put right a Used 1 just before it
    /// (UseLog.cancelWithin), or quick add's 1 less taking back a scan, which is never a use. Nil from a phone before
    /// it, and for every other change; an older Mac ignores it.
    public let correction: Bool?
    /// When the Mac wrote the copy the phone showed as the change was made (its `writtenAt`; beta run 3's S4.4, run 2's
    /// B2-13), so the Mac can tell a change made without another phone's, already on the Mac, in view
    /// (PhoneInventory.AlsoChanged). Nil with no copy, and from a phone before it; an older Mac ignores it.
    public let seen: String?

    public init(id: String = UUID().uuidString.lowercased(), change: InventoryChange, at: String? = nil,
                correction: Bool = false, seen: String? = nil) {
        self.id = id
        self.change = change
        self.at = at
        self.correction = correction ? true : nil
        self.seen = seen
    }

    /// The Inventory item whose cells `change` changes (a cell set, Used 1 or 1 more), the ones the item's screen
    /// shows under its number; nil for any other change (S4.4).
    public static func item(of change: InventoryChange) -> Int64? {
        switch change {
        case .set(table: "Inventory", let row, _, _), .revert(table: "Inventory", let row, _, _, _), .adjust(let row, _):
            row
        default: nil
        }
    }
}

public struct PhoneEdits: Codable, Equatable, Sendable {
    public static let maxEdits = 100
    public static let maxBytes = 256 * 1024
    public let edits: [PhoneEdit]
    /// The sending phone's own id (F-095): made once on the phone, kept in its Keychain through every pairing, so the
    /// Mac tells phones apart by device, not by the label each pairing hands out. Nil from a phone before it; the Mac
    /// keeps it in its own file only (PhoneInbox.who) and never in the phones' copy.
    public var device: String?
    /// From a child's phone (2026-11-12: it may add pins and remove its own, PhoneRules). The Mac's service sets it
    /// from the pairing as it saves a POST to the inbox, over whatever was sent; nil from an adult's.
    public var child: Bool?

    public init(edits: [PhoneEdit], device: String? = nil, child: Bool? = nil) {
        self.edits = edits
        self.device = device
        self.child = child
    }

    /// The edits in `data`: refused (nil) over the size or count limits or of any other shape.
    public static func read(_ data: Data) -> PhoneEdits? {
        guard data.count <= maxBytes, let found = try? JSONDecoder().decode(PhoneEdits.self, from: data),
              !found.edits.isEmpty, found.edits.count <= maxEdits,
              found.edits.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 64 }) else { return nil }
        return found
    }
}

/// The lists on the phones (plan phase 7, part 2): To do and Upkeep whole (their text is the lists' own; no Private
/// item's name is ever in them), the Event mode switch, and the open recalls (top-ten plan phase 6, Task 6.4), never a
/// Mac-only item's. Proposed, Targets, the cleared recalls and the other Settings stay on the Mac.
public struct PhoneLists: Codable, Equatable, Sendable {
    public var todo: [ListRow]
    public var upkeep: [ListRow]
    public var eventMode: String
    /// nil in a copy from before Task 6.4
    public var recalls: [PhoneRecall]?

    public init(todo: [ListRow], upkeep: [ListRow], eventMode: String, recalls: [PhoneRecall]? = nil) {
        self.todo = todo
        self.upkeep = upkeep
        self.eventMode = eventMode
        self.recalls = recalls
    }

    public init(_ lists: Lists) {
        todo = lists.rows(ListsLayout.todo)
        upkeep = lists.rows(ListsLayout.upkeep)
        let mode = lists.setting(ListsLayout.eventMode).text
        eventMode = ListsLayout.eventSwitch.contains(mode) ? mode : "Auto"
        recalls = RecallList.split(lists.rows(ListsLayout.recalls)).open
            .filter { !RecallList.isMacOnly($0, in: lists) && !$0.id.isEmpty }.map(PhoneRecall.init)
    }

    /// As a `Lists`, to find a row the way the Mac does (ListRowRef).
    public var asLists: Lists {
        Lists(sheets: [ListsLayout.todo: todo, ListsLayout.upkeep: upkeep,
                       ListsLayout.settings: [ListRow(pos: 0, cells: ["Setting": .text(ListsLayout.eventMode),
                                                                       "Value": .text(eventMode)])]],
              stamp: nil, revision: 0)
    }

    /// The change an adult's phone sends to switch Event mode.
    public func eventModeChange(_ value: String) -> InventoryChange {
        let row = ListRow(pos: 0, cells: ["Setting": .text(ListsLayout.eventMode), "Value": .text(eventMode)])
        return .listSet(sheet: ListsLayout.settings, row: ListRowRef(row), column: "Value", value: .text(value),
                        expected: .text(eventMode))
    }
}

/// An open recall on the phones (top-ten plan phase 6, Task 6.4): what the Mac's Recalls list shows of it, its row ID
/// to answer it by. Never a Mac-only item's (PhoneLists).
public struct PhoneRecall: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let item: String
    public let recall: String
    public let agency: String
    public let date: String
    public let link: String
    public let level: String

    public init(_ row: ListRow) {
        id = row.id
        item = row["Item"].text
        recall = row["Recall"].text
        agency = row["Agency"].text
        date = row["Date"].text
        link = row["Link"].text
        level = row["Level"].text
    }

    /// The answers a phone offers: an adult's the four words, a child's none (it reads the list)
    public static func answers(canEdit: Bool) -> [String] { canEdit ? ListsLayout.recallStatuses : [] }

    /// The change an adult's phone sends to answer it: its Status, the one recall cell a phone may set
    public func answer(_ status: String) -> InventoryChange {
        .listSet(sheet: ListsLayout.recalls, row: ListRowRef(ListRow(pos: 0, cells: ["ID": .text(id)])),
                 column: "Status", value: .text(status), expected: .null)
    }
}

/// Which edits a phone may make, read against the inventory as it is (the Mac's own changes go through the same
/// editor without this): set a cell of a row that isn't Private (the item form's as a revert saying what the phone
/// saw, so a cell the Mac changed since is refused, never overwritten: Task 1.8, 2026-10-23), add a row, minus and
/// plus, Bought, Not needed and an own To buy item; on the lists, a new to-do and any To do cell the Mac may change,
/// Upkeep's Last done and the Event mode switch; a rally point's or route's delete, and any one's name or note, the
/// Start's too (owner, 2026-11-12, by click: through the Mac to every phone; the editor refuses one the Mac changed
/// since), never where it is or its kind and never the Start's delete; a pin or a rally point added, a role or a
/// pin's look changed (the shared marks plan, 2026-11-12); from a child's phone only a pin added and its own pin
/// removed (`childRefusal`); never another delete, never
/// Locations, Categories or Settings, never a Mac only column (Mac only, Purchased, Price, Serial number) or a photo.
public enum PhoneRules {
    public static let notFromAPhone = "Phones can't make this change; make it on the Mac."
    /// The cells a phone may give a place or category it makes, by label (Task 1.6, 2026-10-23); nothing else of theirs.
    public static let newRowColumns = ["Locations": [Inventory.Label.name, Inventory.Label.keptIn, Inventory.Label.vehicle],
                                       "Categories": [Inventory.Label.name, Inventory.Label.countsAs]]
    /// A Private row reads to a phone as any row that's no longer there: a phone's answer never says an item went
    /// Private (every phone sees every phone's answers).
    public static let privateRow = InventoryWords.noRow
    /// A barcode a Private item holds, refused for a phone (entry fixes, phase 4): neutral, never naming the item or
    /// that it is Private, and Edit again opens the item without the code (`Refusal.keptBarcode`).
    public static let codeElsewhere = "That barcode is on another item, so this wasn't kept. Edit again keeps it "
        + "without the barcode."
    /// The same for a code linked to an item already there: the code is the whole change, so there's nothing to edit.
    public static let codeElsewhereLink = "That barcode is on another item, so it wasn't added to this one."

    /// Who is asking: the phone as the edits' table names it, and whether it is paired as a child's.
    public struct Asker: Sendable {
        public let phone: String
        public let child: Bool

        public init(phone: String = "", child: Bool = false) {
            self.phone = phone
            self.child = child
        }
    }

    /// A child's phone (owner, 2026-11-12: "should have limited delete capability but should be able to add pins"):
    /// it adds a pin, and removes a pin it made itself; nothing else. No `default`, so a new kind of change doesn't
    /// compile until someone rules on it here.
    static func childRefusal(_ change: InventoryChange, _ inventory: Inventory, phone: String) -> String? {
        switch change {
        case .addMark, .removeMark:  // the one rule, which the child's phone asks too before it offers either
            return MapMark.childMay(change, among: inventory.marks + inventory.pins, phone: phone)
                ? nil : MapMarkWords.adultsOnly
        case .set, .revert, .add, .addItem, .linkBarcode, .adjust, .bought, .tick, .listSet, .listAdd, .listRemove,
             .listPutBack, .changeMark, .delete, .restore, .unbuy, .untick, .unlinkBarcode, .startInsurance, .addPhoto,
             .removePhoto, .putBackPhoto, .moveBarcode, .putBackMark, .setMembers, .setPets, .revertUse, .deleteRows,
             .restoreRows, .deleteSeen:
            return MapMarkWords.adultsOnly
        }
    }

    public static func refusal(_ change: InventoryChange, _ inventory: Inventory, from asker: Asker = Asker()) -> String? {
        if asker.child { return childRefusal(change, inventory, phone: asker.phone) }
        let macOnly = inventory.macOnlyColumns
        /// A code a Private item holds is never taken from it by a phone (its codes aren't in the phones' copy, so a
        /// phone sees it as new); the answer says only that another item has it (`codeElsewhere`), never which.
        func codeHeldPrivately(_ typed: String, words: String = codeElsewhere) -> String? {
            guard let code = Barcode.valid(typed), let holder = inventory.barcodes[code],
                  let row = inventory.itemRows.first(where: { $0.id == holder }), inventory.isPrivate(row) else {
                return nil
            }
            return words
        }
        func open(_ id: Int64) -> String? {
            guard let row = inventory.itemRows.first(where: { $0.id == id }) else { return InventoryWords.noRow }
            return inventory.isPrivate(row) ? privateRow : nil
        }
        switch change {
        case .set(let table, let row, let colId, _):
            guard table == "Inventory", !macOnly.contains(colId) else { return notFromAPhone }
            return open(row)
        case .revert(let table, let row, let colId, let value, _):  // a cell set saying what it saw (Task 1.8)
            guard table == "Inventory", !macOnly.contains(colId) else { return notFromAPhone }
            // the Mac's own revert may put back a blank name (an Undo); a phone's never blanks one (checkpoint 2)
            if inventory.items.column(Inventory.Label.item)?.colId == colId,
               InventoryValues.plain(value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return InventoryWords.noName
            }
            return open(row)
        case .add(let table, let values):
            if let allowed = newRowColumns[table] {  // a place or category made on the phone (Task 1.6, 2026-10-23)
                let ids = inventory.table(table).columns.filter { column in
                    allowed.contains { InventoryFile.same($0, column.label) }
                }.map(\.colId)
                guard Set(values.keys).isSubset(of: ids) else { return notFromAPhone }
                let table = inventory.table(table)
                func cell(_ label: String) -> String {
                    table.column(label).flatMap { values[$0.colId] }.map(InventoryValues.plain)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                if cell(Inventory.Label.name).isEmpty { return InventoryWords.noPlaceName }  // never a blank one
                if allowed.contains(Inventory.Label.countsAs),
                   !ToBuyList.groups.contains(where: { InventoryFile.same($0, cell(Inventory.Label.countsAs)) }) {
                    return String(format: InventoryWords.countsAsChoices,
                                  ToBuyList.groups.map(InventoryLook.title).joined(separator: ", "))
                }
                return nil
            }
            guard table == "Inventory", macOnly.isDisjoint(with: values.keys) else { return notFromAPhone }
            return nil
        case .addItem(let values, let code):
            guard macOnly.isDisjoint(with: values.keys) else { return notFromAPhone }
            return codeHeldPrivately(code)
        case .linkBarcode(let code, let row):
            return codeHeldPrivately(code, words: codeElsewhereLink) ?? open(row)
        case .adjust(let row, _):
            return open(row)
        case .bought(let values, let tick):
            guard tick.kind == .bought, macOnly.isDisjoint(with: values.keys) else { return notFromAPhone }
            return nil
        case .tick(let tick):
            return tick.kind == .bought ? notFromAPhone : nil
        case .listSet(let sheet, let ref, let column, let value, _):  // the lists (plan phase 7, part 2): ticks, the
            switch (sheet, column) {                                     // switch, a recall's answer (Task 6.4)
            case (ListsLayout.todo, _), (ListsLayout.upkeep, "Last done"):  // To do: any cell the Mac may change
                return nil                                                      // (the editor's `editable`; 2026-10-30)
            case (ListsLayout.recalls, "Status"):
                guard case .text(let word) = value, ListsLayout.recallStatuses.contains(word) else { return notFromAPhone }
                guard let lists = inventory.lists, let row = lists.find(ref, in: sheet),
                      !RecallList.isMacOnly(row, in: lists) else {
                    return InventoryWords.noRow  // a Mac-only recall reads to a phone as no row at all
                }
                return nil
            case (ListsLayout.settings, "Value"):
                let row = inventory.lists?.find(ref, in: sheet)
                return row?["Setting"].text == ListsLayout.eventMode ? nil : notFromAPhone
            default:
                return notFromAPhone
            }
        case .listAdd(let sheet, _):  // an adult's own to-do (owner, 2026-10-30); its cells checked as the Mac's
            return sheet == ListsLayout.todo ? nil : notFromAPhone
        case .listRemove, .listPutBack:
            return notFromAPhone
        case .removeMark(let id, _):  // a rally point, route or pin, never the Start point (owner, 2026-11-12)
            return inventory.marks.first { $0.id == id }?.kind == .start ? notFromAPhone : nil  // one gone: done
        case .changeMark(let mark, let expected):  // a name, note, role or a pin's look, the Start's name and note too
            var same = mark                             // (owner, 2026-11-12); where it is and what kind stay the Mac's
            (same.name, same.note, same.role, same.routeRole) = (expected.name, expected.note, expected.role, expected.routeRole)
            (same.pinSymbol, same.pinColor) = (expected.pinSymbol, expected.pinColor)
            return same == expected ? nil : notFromAPhone  // gone, or changed since: the editor says so
        case .addMark(let mark):  // a pin or a rally point where the phone was pressed; a route and the Start are the Mac's
            return mark.kind == .pin || mark.kind == .rally ? nil : notFromAPhone
        case .deleteSeen(let row, _):  // an adult's phone deletes an item, saying what it saw (owner, 2026-11-18)
            return open(row)
        case .delete, .restore, .unbuy, .untick, .unlinkBarcode, .startInsurance, .addPhoto, .removePhoto,
             .putBackPhoto, .moveBarcode, .putBackMark, .setMembers, .setPets,
             .revertUse, .deleteRows, .restoreRows:
            return notFromAPhone
        }
    }
}

/// The Mac's side: the phones' edits waiting in the inventory folder's `inbox` (one file a POST, `<time>-<phone>-<id>
/// .json`, written whole by the service), applied in the order they came. Each edit's outcome is recorded inside the
/// inventory file, in the same save as the change (InventoryEditor.PhoneTag, the PrepareMe_PhoneEdits table), and kept
/// for good, so an edit sent again, after a lost answer or weeks away, is never applied twice, even across a power cut.
/// The phone's rules are read at the edit's own turn. Only a check that can't run leaves the file waiting (`stuck`
/// counts the tries); any other failure is that edit's answer ("couldn't be saved"), so one bad edit never holds up the
/// rest. A file is removed once every edit in it has its answer.
@MainActor
public enum PhoneInbox {
    nonisolated public static let inboxName = "inbox"
    nonisolated static let couldNotSave = "This change couldn't be saved on the Mac."
    static let leftoverAge: TimeInterval = 3600  // a half-written temporary file older than this is a crash's

    /// Whether anything was applied or answered (so the phones' copy should be written again). Throws
    /// CheckUnavailable, with the rest waiting, when the check can't run.
    @discardableResult
    public static func process(folder: URL, editor: InventoryEditor, now: Date = Date()) async throws -> Bool {
        let inbox = folder.appendingPathComponent(inboxName)
        let all = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        for name in all where name.hasPrefix(".") && name.contains(".tmp-") {
            let url = inbox.appendingPathComponent(name)
            let made = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(made) > leftoverAge { try? FileManager.default.removeItem(at: url) }
        }
        let names = all.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        guard !names.isEmpty else { return false }
        for name in names {
            let file = inbox.appendingPathComponent(name)
            let found = (try? Data(contentsOf: file)).flatMap(PhoneEdits.read)
            let phone = who(device: found?.device, label: phoneLabel(name))
            for edit in found?.edits ?? [] {
                let at = edit.at.flatMap { ISO8601DateFormatter().date(from: $0) }
                let copy = edit.seen.flatMap { ISO8601DateFormatter().date(from: $0) }
                let tag = InventoryEditor.PhoneTag(id: edit.id, phone: phone, at: at,
                                                   correction: edit.correction == true, seen: copy ?? at, copy: copy,
                                                   label: phoneLabel(name))
                do {
                    // a place the phone made goes by its labels; a waiting row's number becomes the row made (Task 1.6)
                    let named = byColumnIds(edit.change, editor.inventory)
                    let change = try resolved(named, editor: editor)
                    _ = try await editor.apply(change ?? named, phone: tag) {
                        change == nil ? InventoryWords.notThere
                            : PhoneRules.refusal(change!, $0, from: .init(phone: phone, child: found?.child == true))
                    }
                } catch let error as CheckUnavailable {
                    throw error
                } catch {
                    if try editor.file.phoneEditResult(edit.id) == nil {
                        try editor.file.recordPhoneEdit(tag, refused: couldNotSave, row: nil)
                    }
                }
            }
            try FileManager.default.removeItem(at: file)
        }
        return true
    }

    /// A phone's new place or category names its cells by label, since the phones' copy carries no Locations or
    /// Categories column ids (Task 1.6, 2026-10-23): each label becomes its column's id. Any other change is as it is.
    public static func byColumnIds(_ change: InventoryChange, _ inventory: Inventory) -> InventoryChange {
        guard case .add(let table, let values) = change, PhoneRules.newRowColumns[table] != nil else { return change }
        let columns = inventory.table(table).columns
        func id(_ key: String) -> String {
            columns.first { $0.colId == key }?.colId ?? columns.first { InventoryFile.same($0.label, key) }?.colId ?? key
        }
        return .add(table: table, values: Dictionary(values.map { (id($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }))
    }

    /// `change` with any of the phone's own waiting rows' numbers (below 0, PhoneOutbox.temporaryID) in a place or
    /// category cell put back as the row the Mac made for it (Task 1.6): a place made away from home, then an item put
    /// in it. nil when one names a row the Mac refused or never made, so the item is refused, never filed nowhere.
    static func resolved(_ change: InventoryChange, editor: InventoryEditor) throws -> InventoryChange? {
        let inventory = editor.inventory
        let references = Set((inventory.items.columns + inventory.locations.columns).filter(\.isReference).map(\.colId))
        var made: [Int64: Int64]?
        func fix(_ values: [String: SQLValue]) throws -> [String: SQLValue]? {
            var out = values
            for (key, value) in values where references.contains(key) {
                guard let waiting = value.whole, waiting < 0 else { continue }
                if made == nil {
                    made = Dictionary(try editor.file.phoneEditResults(since: .distantPast).compactMap { id, result in
                        result.refused == nil ? result.row.map { (PhoneOutbox.temporaryID(id), $0) } : nil
                    }, uniquingKeysWith: { a, _ in a })
                }
                guard let row = made?[waiting] else { return nil }
                out[key] = .int(row)
            }
            return out
        }
        switch change {
        case .add(let table, let values): return try fix(values).map { .add(table: table, values: $0) }
        case .addItem(let values, let barcode): return try fix(values).map { .addItem(values: $0, barcode: barcode) }
        case .bought(let values, let tick): return try fix(values).map { .bought(values: $0, tick: tick) }
        case .set(let table, let row, let colId, let value):
            return try fix([colId: value]).map { .set(table: table, row: row, colId: colId, value: $0[colId]!) }
        case .revert(let table, let row, let colId, let value, let expected):
            return try fix([colId: value]).map {
                .revert(table: table, row: row, colId: colId, value: $0[colId]!, expected: expected)
            }
        default: return change
        }
    }

    nonisolated static let devicePrefix = "device:"

    /// Which phone made a POST's changes, as the phone edits' table keeps it: "device:<id>" for one that sent its own
    /// id (F-095: the same through a new pairing), else its pairing label. An id that isn't a UUID is ignored.
    nonisolated static func who(device: String?, label: String) -> String {
        guard let device, let id = UUID(uuidString: device) else { return label }
        return devicePrefix + id.uuidString.lowercased()
    }

    /// "phone1" from `<time>-phone1-<id>.json` (Router.save's name); "" for any other name.
    static func phoneLabel(_ name: String) -> String {
        let parts = name.split(separator: "-")
        return parts.first { $0.hasPrefix("phone") }.map(String.init) ?? ""
    }
}

extension InventoryFile {
    static let phoneEditsTable = "PrepareMe_PhoneEdits"

    /// `seen` (S4.4): for a kept change to an item's cells (PhoneEdit.item), what its phone had in view as it was made
    /// (PhoneTag.seen), its `row` the item; NULL for any other change, and in a row kept before it (added to an older
    /// table here).
    func ensurePhoneEdits() throws {
        guard !readOnly else { throw InventoryFileError.readOnly }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS "\(Self.phoneEditsTable)" (id TEXT PRIMARY KEY, phone TEXT NOT NULL, \
            at TEXT NOT NULL, refused TEXT, row INTEGER, seen TEXT)
            """)
        if try !phoneEditsHaveSeen() {
            try db.execute("ALTER TABLE \"\(Self.phoneEditsTable)\" ADD COLUMN seen TEXT")
        }
    }

    /// Whether the phone edits' table has its `seen` column (a table made before S4.4 has none until ensurePhoneEdits).
    private func phoneEditsHaveSeen() throws -> Bool {
        try db.query("PRAGMA table_info(\"\(Self.phoneEditsTable)\")").contains { Self.text($0[1]) == "seen" }
    }

    /// Record a phone edit's outcome (inside the caller's transaction when there is one). `item`: the item whose cells
    /// a kept change changed (PhoneEdit.item), for its `seen`.
    func recordPhoneEdit(_ tag: InventoryEditor.PhoneTag, refused: String?, row: Int64?, item: Int64? = nil) throws {
        try ensurePhoneEdits()
        let format = ISO8601DateFormatter()
        let seen = refused == nil && item != nil && item == row ? tag.seen.map { format.string(from: $0) } : nil
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO \"\(Self.phoneEditsTable)\" (id, phone, at, refused, row, seen) "
                           + "VALUES (?, ?, ?, ?, ?, ?)",
                           [.text(tag.id), .text(tag.phone), .text(format.string(from: Date())),
                            refused.map { .text($0) } ?? .null, row.map { .int($0) } ?? .null,
                            seen.map { .text($0) } ?? .null])
        }
    }

    /// The items two phones changed apart, for a day after the Mac kept both (beta run 3's S4.4, run 2's B2-13): two
    /// kept changes to one item's cells from two phones (by their own ids, PhoneInbox.who, so a phone paired again is
    /// still one phone: F-095; by their labels, "phone1", from a phone before that, and a label and an id are never
    /// told apart, as either could be the other; an unknown label is no phone),
    /// the later one made without the earlier in view: its phone's copy written before the earlier one reached the
    /// Mac (`seen`; with no copy known, its tap time). A pair counts only for a day after its later change reached the
    /// Mac, so an older pair never comes back with a new one (fix round 1); only the last day's changes are scanned as
    /// the later one. Each item once, with the edit ids of the pairs still counting and a day after the latest of them
    /// reached the Mac. Nothing about which change won: the Mac applied each in turn, as always. Empty with no record,
    /// or one kept before `seen`.
    public func alsoChanged(now: Date = Date()) throws -> [PhoneInventory.AlsoChanged] {
        guard try hasTable(Self.phoneEditsTable), try phoneEditsHaveSeen() else { return [] }
        let format = ISO8601DateFormatter()
        let day = PhoneInventory.AlsoChanged.shownFor
        let from = format.string(from: now.addingTimeInterval(-day))
        // every kept item change to an item with one kept in the last day, in the order the Mac applied them
        let rows = try db.query("""
            SELECT id, phone, at, row, seen FROM "\(Self.phoneEditsTable)" WHERE refused IS NULL AND seen IS NOT NULL \
            AND row IN (SELECT row FROM "\(Self.phoneEditsTable)" WHERE refused IS NULL AND seen IS NOT NULL \
            AND at >= ?) ORDER BY rowid
            """, [.text(from)])
        struct Kept { let id: String, phone: String, at: Date, seen: Date }
        var byItem: [Int64: [Kept]] = [:]
        var order: [Int64] = []
        for row in rows {
            guard let id = Self.text(row[0]), let phone = Self.text(row[1]), !phone.isEmpty,
                  let at = Self.text(row[2]).flatMap(format.date), let item = row[3].whole,
                  let seen = Self.text(row[4]).flatMap(format.date) else { continue }
            if byItem[item] == nil { order.append(item) }
            byItem[item, default: []].append(Kept(id: id, phone: phone, at: at, seen: seen))
        }
        var found: [PhoneInventory.AlsoChanged] = []
        for item in order {
            let kept = byItem[item] ?? []
            var apart: Set<String> = []
            var latest: Date?
            for (n, later) in kept.enumerated() where later.at.addingTimeInterval(day) > now {  // its day not over
                for earlier in kept[..<n] where Self.twoPhones(earlier.phone, later.phone) && later.seen < earlier.at {
                    apart.formUnion([earlier.id, later.id])
                    latest = max(latest ?? later.at, later.at)
                }
            }
            guard let until = latest?.addingTimeInterval(day) else { continue }
            found.append(.init(item: item, until: format.string(from: until),
                               edits: kept.map(\.id).filter(apart.contains)))
        }
        return found
    }

    /// Whether two of the table's `phone` values are surely two phones: both ids or both labels, and different.
    static func twoPhones(_ one: String, _ other: String) -> Bool {
        one != other && one.hasPrefix(PhoneInbox.devicePrefix) == other.hasPrefix(PhoneInbox.devicePrefix)
    }

    static let copiesTable = "PrepareMe_PhoneCopies"
    /// A run's end is written again once the copies have gone on this long past it (not each copy: one every 10 minutes)
    public static let copyRecordEvery: TimeInterval = 1800
    /// A copy this soon after a run's recorded end is still that run's (its end lags its last copy by under an hour)
    public static let copySlack: TimeInterval = 3600

    /// The phones' copy is about to be written at `at` (its writtenAt), kept here in the file itself, so a backup of
    /// the file carries only the copies written before it (offline fixes, task 1.4). One row per run of the Mac app
    /// (`newRun`: its first copy), from its first copy to within `copyRecordEvery` of its last.
    public func recordCopyWritten(_ at: Date, newRun: Bool) throws {
        guard !readOnly else { throw InventoryFileError.readOnly }
        let when = Int64(at.timeIntervalSince1970.rounded(.down))
        try db.transaction {
            try db.execute("CREATE TABLE IF NOT EXISTS \"\(Self.copiesTable)\" "
                           + "(id INTEGER PRIMARY KEY, first INTEGER NOT NULL, last INTEGER NOT NULL)")
            let latest = try db.query("SELECT id, last FROM \"\(Self.copiesTable)\" ORDER BY id DESC LIMIT 1").first
            if newRun || latest == nil {
                try db.execute("INSERT INTO \"\(Self.copiesTable)\" (first, last) VALUES (?, ?)", [.int(when), .int(when)])
            } else if let latest, let id = latest[0].whole, let last = latest[1].whole,
                      TimeInterval(when - last) >= Self.copyRecordEvery {
                try db.execute("UPDATE \"\(Self.copiesTable)\" SET last = ? WHERE id = ?", [.int(when), .int(id)])
            }
        }
    }

    /// Whether the copy a phone saw (`seen`, its writtenAt) is one no run of this file's Mac wrote: written by a Mac
    /// that had a newer file than this one (an older backup put back). False with no record yet, and for a copy older
    /// than the first recorded (made before the record began).
    public func copyUnknown(_ seen: Date) throws -> Bool {
        guard try hasTable(Self.copiesTable) else { return false }
        let at = Int64(seen.timeIntervalSince1970.rounded(.down))
        guard let first = try db.query("SELECT min(first) FROM \"\(Self.copiesTable)\"").first?.first?.whole,
              at >= first else { return false }
        return try db.query("SELECT 1 FROM \"\(Self.copiesTable)\" WHERE first <= ? AND ? <= last + ? LIMIT 1",
                            [.int(at), .int(at), .int(Int64(Self.copySlack))]).isEmpty
    }

    public func phoneEditResult(_ id: String) throws -> PhoneInventory.Result? {
        guard try hasTable(Self.phoneEditsTable) else { return nil }
        return try db.query("SELECT at, refused, row FROM \"\(Self.phoneEditsTable)\" WHERE id = ?", [.text(id)])
            .first.map { PhoneInventory.Result(at: Self.text($0[0]) ?? "", refused: Self.text($0[1]), row: $0[2].whole) }
    }

    /// The id of the last change `phone` (PhoneInbox.who: its id, else its label) made that the Mac applied to `row`
    /// (by the order they were recorded), or nil: for a "1 more" straight after a Used 1 (B2-08, UseLog.cancelWithin).
    func lastPhoneEdit(phone: String, row: Int64) throws -> String? {
        guard try hasTable(Self.phoneEditsTable) else { return nil }
        return try db.query("SELECT id FROM \"\(Self.phoneEditsTable)\" WHERE phone = ? AND row = ? AND refused IS NULL "
                            + "ORDER BY rowid DESC LIMIT 1", [.text(phone), .int(row)]).first.flatMap { Self.text($0[0]) }
    }

    /// The outcomes recorded since `since`, by edit id (the phones' copy carries these; the table keeps every id).
    public func phoneEditResults(since: Date) throws -> [String: PhoneInventory.Result] {
        guard try hasTable(Self.phoneEditsTable) else { return [:] }
        let format = ISO8601DateFormatter()
        var found: [String: PhoneInventory.Result] = [:]
        for row in try db.query("SELECT id, at, refused, row FROM \"\(Self.phoneEditsTable)\"") {
            guard let id = Self.text(row[0]), let at = Self.text(row[1]),
                  (format.date(from: at) ?? .distantPast) >= since else { continue }
            found[id] = PhoneInventory.Result(at: at, refused: Self.text(row[2]), row: row[3].whole)
        }
        return found
    }

    func hasTable(_ name: String) throws -> Bool {
        try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]).isEmpty
    }
}

/// The phone's side (plan phase 7, slice 5): its edits, kept (Application Support › PrepareMe › inventory-outbox.json,
/// written whole) until the Mac has answered each, sent again on every look until then, and shown on top of the last
/// copy meanwhile, so an edit made away from home, or while the Mac is off, is never lost and never sent twice.
public struct PhoneOutbox: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public let edit: PhoneEdit
        public let what: String  // how the phone describes it ("Water jugs: used 1"), for a refusal's line
        /// The item the change is to and where it is, as the phone knew them when it was made ("Headlamp (Bin 29)"):
        /// a refusal for an item since removed can still name it (R4.3, B2-11); nil for a change to no one item, and in
        /// an entry kept before it.
        public let item: String?
        /// A Used 1's worth to each supply, valued on the phone as it was made (RunsOut.use; step 8c, section 4), for
        /// its run-out lines until the Mac's copy has it; nil for any other change, and in an entry kept before it.
        public let use: Use?
        /// Until when a Used 1 or 1 more made on the item screen stays on this phone for its Undo (B2-08, beta run 2):
        /// nil once sent, for any other change, and in an entry kept before it (sent as before).
        public var holdUntil: String?
        /// When a send of it began (fix round 1): from then the Mac may have it, so it is never withdrawn or undone,
        /// only answered. Nil until then, and in an entry kept before it (a waiting one sent before then may be
        /// withdrawn, as it could be before).
        public var sentAt: String?
        /// When the latest send of it began (the re-post storm fix): `toSend` waits 30 seconds from this, not from
        /// `sentAt`, which stays the first send's for `takenUnapplied` and `settle`. Nil until sent, and in an entry
        /// kept before it (`sentAt` then stands in).
        public var lastSent: String?
        public var id: String { edit.id }

        public init(edit: PhoneEdit, what: String, item: String? = nil, use: Use? = nil, holdUntil: String? = nil) {
            self.edit = edit
            self.what = what
            self.item = item
            self.use = use
            self.holdUntil = holdUntil
        }

        /// Still held for its Undo at `now`, never once a send began. A hold further ahead than the longest Undo is a
        /// clock set back, and holds nothing.
        func isHeld(_ now: Date) -> Bool {
            guard sentAt == nil, let until = holdUntil.flatMap(PhoneOutbox.holdDate) else { return false }
            return until > now && until.timeIntervalSince(now) <= PhoneOutbox.undoForVoiceOver + 1
        }
    }

    /// What a Used 1 was worth to each supply, by kind (nil: it couldn't be valued).
    public struct Use: Codable, Equatable, Sendable {
        public let amounts: [String: Double]?

        public init(amounts: [String: Double]?) {
            self.amounts = amounts
        }
    }

    public struct Refusal: Codable, Equatable, Identifiable, Sendable {
        /// The barcode Edit again opens a refused new item with: none when the code was why (another item holds it).
        public func keptBarcode(_ code: String?) -> String? { message == PhoneRules.codeElsewhere ? nil : code }

        public let id: String
        public let what: String
        public let message: String
        /// The item and its place the change was to (Entry.item); nil when it had none, and in a refusal kept before it.
        public let item: String?
        /// The refused edit, so the item form can open again with what was typed (plan 2026-10-16, Task 4.1); nil in
        /// a refusal kept before it was saved with one.
        public let edit: PhoneEdit?

        public init(id: String, what: String, message: String, edit: PhoneEdit? = nil, item: String? = nil) {
            self.id = id
            self.what = what
            self.message = message
            self.item = item
            self.edit = edit
        }
    }

    public var pending: [Entry] = []
    public var refused: [Refusal] = []
    /// This phone's own changes to an item's cells (PhoneEdit.item) the Mac kept, by edit id, while the Mac's copy
    /// still carries their answers (60 days): for PhoneInventory.AlsoChanged, which names the changes, never the phones
    /// (S4.4). Nil in an outbox kept before it.
    public var kept: Set<String>?

    public init() {}

    /// How long the item screen's Undo shows after Used 1 or 1 more (B2-08, beta run 2; choice a: "a few seconds").
    /// The change stays on the phone meanwhile, so Undo takes it back before the Mac ever has it: nothing to cancel
    /// there, and nothing sent twice.
    public static let undoFor: TimeInterval = 5
    /// With VoiceOver running, the Undo stays longer (fix round 1): reaching a new button by swiping takes longer.
    public static let undoForVoiceOver: TimeInterval = 15

    /// Keep a change to send, with the time it was made; its id. `withUndo` (the item screen's Used 1 and 1 more):
    /// held on the phone for `holdFor` seconds first (`undoFor`, or `undoForVoiceOver`), for its Undo. `correction`:
    /// marked as one (PhoneEdit.correction), and never valued as a use on the phone.
    /// `seen`: the Mac's copy's `writtenAt` as the phone shows it (PhoneEdit.seen).
    @discardableResult
    public mutating func add(_ change: InventoryChange, what: String, item: String? = nil, now: Date = Date(),
                             use: Use? = nil,
                             withUndo: Bool = false, holdFor: TimeInterval = undoFor, correction: Bool = false,
                             seen: String? = nil) -> String {
        let edit = PhoneEdit(change: change, at: Self.plainTime.string(from: now), correction: correction, seen: seen)
        pending.append(Entry(edit: edit, what: what, item: item, use: correction ? nil : use,
                             holdUntil: withUndo ? Self.holdTime.string(from: now.addingTimeInterval(holdFor)) : nil))
        return edit.id
    }

    /// The changes to send now, in order: all of them up to the first still held for its Undo, so a change made after
    /// a held one waits with it (a few seconds) and the Mac applies them in the order they were made.
    public func ready(now: Date = Date()) -> [Entry] {
        Array(pending.prefix { !$0.isHeld(now) })
    }

    /// When the first held change's Undo ends (to send then), or nil when none is held.
    public func holdEnds(now: Date = Date()) -> Date? {
        pending.filter { $0.isHeld(now) }.compactMap { $0.holdUntil.flatMap(Self.holdDate) }.min()
    }

    static func holdDate(_ text: String) -> Date? {
        holdTime.date(from: text) ?? plainTime.date(from: text)
    }

    /// The outbox's times, made once rather than on every redraw's `isHeld` (ISO8601DateFormatter is costly to make,
    /// and safe to share): a hold to the millisecond, not the second, and everything else, older holds included, to
    /// the second.
    nonisolated(unsafe) static let holdTime: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions.insert(.withFractionalSeconds)
        return format
    }()
    nonisolated(unsafe) static let plainTime = ISO8601DateFormatter()

    /// A send of these began: from now the Mac may have them, so neither Undo nor `withdraw` takes them back (they
    /// leave only with the Mac's answer, or a refusal). The ids this marked, not those an earlier send had marked
    /// already (for `unsend`).
    @discardableResult
    public mutating func markSent(_ ids: [String], now: Date = Date()) -> [String] {
        var marked: [String] = []
        for n in pending.indices where ids.contains(pending[n].id) {
            pending[n].holdUntil = nil
            pending[n].lastSent = Self.plainTime.string(from: now)  // every send, a repeat too: the 30 s run from it
            if pending[n].sentAt == nil {
                pending[n].sentAt = Self.plainTime.string(from: now)
                marked.append(pending[n].id)
            }
        }
        return marked
    }

    /// After a send (`delivery`): the changes it never got to the Mac (PhoneDelivery.notReached) go back to unsent,
    /// but only those this send marked (`marked`, markSent's answer), and quick add's Undo last may take them back
    /// again (checkpoint 2). One an earlier send delivered and the Mac hasn't answered yet goes again with the next,
    /// and stays sent if that one fails: the Mac may have it already (re-review of checkpoint 2). A hold already ended
    /// stays ended: they go at the next look.
    public mutating func unsend(_ delivery: PhoneDelivery, marked: [String]) {
        let ids = delivery.notReached.filter(marked.contains)
        for n in pending.indices where ids.contains(pending[n].id) {
            pending[n].sentAt = nil
            pending[n].lastSent = nil
        }
    }

    /// The change the item screen's Undo takes back for `row`: its latest Used 1 or 1 more still held. A phone that
    /// can't edit (a child's, or a copy from the backup) shows no Undo: the phone's model asks only when it may edit.
    public func undoable(row: Int64, now: Date = Date()) -> Entry? {
        pending.last { entry in
            guard case .adjust(row, _) = entry.edit.change else { return false }
            return entry.isHeld(now)
        }
    }

    /// Whether a change to the item `row` is still waiting for the Mac (beta run 3, B3-07): the changes Send now
    /// sends, as the Inventory home counts them, never a Used 1 still held for its Undo. The item's own screen says
    /// "Waiting for the Mac." for it. These are the kinds a phone sends for an existing item (PhoneRules.refusal): a
    /// cell set (or its revert, Task 1.8), a Used 1 or 1 more, a barcode linked. The rest of the item-bound kinds (delete, restore,
    /// unlink or move a barcode, unbuy) are the Mac's alone: a phone never makes one. A row added on the phone
    /// (add, addItem, bought) has no id yet and says so on its own temporary id below 0, not here.
    public func hasWaitingChange(forItem row: Int64, now: Date = Date()) -> Bool {
        ready(now: now).contains { entry in
            switch entry.edit.change {
            case .set(table: "Inventory", let id, _, _), .revert(table: "Inventory", let id, _, _, _), .adjust(let id, _),
                 .linkBarcode(_, let id): id == row
            default: false
            }
        }
    }

    /// Undo: the held change leaves the outbox unsent, and what the phone shows goes back. False, changing nothing,
    /// once its few seconds are over (it has gone, or is going, to the Mac).
    public mutating func undo(_ id: String, now: Date = Date()) -> Bool {
        guard let entry = pending.first(where: { $0.id == id }), entry.isHeld(now) else { return false }
        pending.removeAll { $0.id == id }
        return true
    }

    /// The Undo button's words, with the item's unit as its buttons say it: "Undo Used 1 gallon", "Undo 1 more
    /// gallon" (R4.4); "Undo Used 1" for an item counted in no unit.
    public static func undoLabel(_ entry: Entry, unit: String) -> String {
        guard case .adjust(_, let by) = entry.edit.change else { return "Undo" }
        return "Undo " + (by < 0 ? UnitWords.used(unit) : UnitWords.more(unit))
    }

    /// The new item `item` (its id below 0) while its add is still on this phone, never sent: the one a repeat scan
    /// raises and Edit saves over (entry fixes plan, Task 2.5), a Bought… item's too (its tick kept: fix wave, M3).
    /// Nil once a send of it began, as the Mac may have it.
    public func waitingAdd(_ item: Int64) -> Entry? {
        pending.first { entry in
            guard item < 0, entry.sentAt == nil, Self.temporaryID(entry.id) == item else { return false }
            switch entry.edit.change {
            case .add(table: "Inventory", _), .addItem, .bought: return true
            default: return false
            }
        }
    }

    /// Change a waiting add's values in place (`waitingAdd`): it keeps its id, time and place in line, so the Mac gets
    /// one add, as finally typed. False, changing nothing, once a send of it began, or when `change` gives nil.
    @discardableResult
    public mutating func changeWaitingAdd(_ item: Int64,
                                          _ change: ([String: SQLValue]) -> [String: SQLValue]?) -> Bool {
        guard let entry = waitingAdd(item), let n = pending.firstIndex(where: { $0.id == entry.id }) else { return false }
        let made: InventoryChange
        switch entry.edit.change {
        case .add(table: "Inventory", let values):
            guard let values = change(values) else { return false }
            made = .add(table: "Inventory", values: values)
        case .addItem(let values, let code):
            guard let values = change(values) else { return false }
            made = .addItem(values: values, barcode: code)
        case .bought(let values, let tick):
            guard let values = change(values) else { return false }
            made = .bought(values: values, tick: tick)
        default: return false
        }
        let edit = PhoneEdit(id: entry.edit.id, change: made, at: entry.edit.at, correction: entry.edit.correction == true,
                             seen: entry.edit.seen)
        pending[n] = Entry(edit: edit, what: entry.what, item: entry.item, use: entry.use, holdUntil: entry.holdUntil)
        return true
    }

    /// A repeat scan of a new item still waiting (quick add): its Quantity raised by `by` (a blank one counts as 0), so
    /// six scans with the Mac off send one item of 6, never an item and five held 1 mores. False when it can't be.
    @discardableResult
    public mutating func raiseWaitingAdd(_ item: Int64, by: Double, quantity: PhoneInventory.Column) -> Bool {
        changeWaitingAdd(item) { values in
            let current = InventoryValues.plain(values[quantity.colId] ?? .null).trimmingCharacters(in: .whitespaces)
            guard let found = current.isEmpty ? 0 : InventoryValues.parseNumber(current) else { return nil }
            var values = values
            values[quantity.colId] = Self.quantity(max(0, found + by), kind: quantity.kind)
            return values
        }
    }

    /// A Quantity stored the column's way.
    static func quantity(_ number: Double, kind: String) -> SQLValue {
        switch kind {
        case "numeric": .real(number)
        case "int": .int(Int64(number.rounded()))
        default: .text(InventoryValues.number(number))
        }
    }

    /// What a phone sends now (entry fixes, phase 4): `ready`, less any a send began within the last `resendAfter`
    /// seconds and that is still waiting for the Mac's answer. That send reached the Mac (one that didn't went back to
    /// unsent), so sending it again at once only made the Mac read it twice; after the wait it goes again, as before.
    /// The wait runs from the latest send (`lastSent`), so with the Mac app closed each change goes once per 30
    /// seconds however often the phone looks, never at every look (the re-post storm, 2026-11-18).
    public func toSend(now: Date = Date()) -> [Entry] {  // shortcut: whole-second sent times, so the wait is 29-30 s
        ready(now: now).filter { entry in
            guard entry.sentAt != nil, let began = (entry.lastSent ?? entry.sentAt).flatMap(Self.holdDate) else {
                return true
            }
            return now.timeIntervalSince(began) >= Self.resendAfter || began > now  // a clock set back: sent again
        }
    }

    public static let resendAfter: TimeInterval = 30

    /// Whether a change a send began is still waiting for the Mac's answer: the phone looks again for it.
    public var awaitingAnswer: Bool { pending.contains { $0.sentAt != nil } }

    /// Allowance for the Mac's apply and the two clocks' difference (offline fixes, task 3.1)
    public static let takenSlack: TimeInterval = 120

    /// How many sent changes the Mac's service took but PrepareMe on the Mac hasn't applied: sent, a look reached the
    /// Mac over `takenSlack` later (`lookedAt`), and the copy it has is older than the send by more than `takenSlack`
    /// (the app writes a copy at least every 10 minutes and after applying, so it isn't running). 0 with no copy.
    public func takenUnapplied(copy: PhoneInventory?, lookedAt: Date?) -> Int {
        guard let written = copy.flatMap({ Self.plainTime.date(from: $0.writtenAt) }), let lookedAt else { return 0 }
        return pending.filter { entry in
            guard let sent = entry.sentAt.flatMap(Self.holdDate) else { return false }
            return lookedAt.timeIntervalSince(sent) > Self.takenSlack && sent.timeIntervalSince(written) > Self.takenSlack
        }.count
    }

    /// A refusal put away: its edit was made again, or thrown away.
    public mutating func forgetRefusal(_ id: String) {
        refused.removeAll { $0.id == id }
    }

    /// Take back a change still waiting (quick-add's Undo last); false when it has gone to the Mac already, or a send
    /// of it began (the Mac may apply it still: fix round 1).
    @discardableResult
    public mutating func withdraw(_ id: String) -> Bool {
        guard pending.contains(where: { $0.id == id && $0.sentAt == nil }) else { return false }
        pending.removeAll { $0.id == id }
        return true
    }

    /// Edits the Mac's service will never take (a phone made read-only, a post too large or of a kind it doesn't
    /// read): they leave the outbox and are listed with `message`, never kept waiting for good.
    public mutating func refuse(_ ids: [String], message: String) {
        for entry in pending where ids.contains(entry.id) {
            refused.append(Refusal(id: entry.id, what: entry.what, message: message, edit: entry.edit, item: entry.item))
        }
        pending.removeAll { ids.contains($0.id) }
    }

    /// The Mac's copy carries 60 days of answers (PrepareMeInventory's phone copy); a change sent longer ago than this
    /// has had its answer and lost it, and the Mac applies a change it took once whatever happens (offline fixes, 1.3).
    public static let settleAfter: TimeInterval = 61 * 86_400

    /// Take the Mac's answers in `copy`: an answered edit leaves the outbox, and a refused one is listed; a kept one is
    /// remembered in `kept` while the copy carries its answer. One sent more than `settleAfter` ago leaves it too.
    public mutating func settle(with copy: PhoneInventory, now: Date = Date()) {
        var mine = (kept ?? []).filter { copy.results[$0] != nil }
        for entry in pending {
            if let result = copy.results[entry.id], let message = result.refused {
                refused.append(Refusal(id: entry.id, what: entry.what, message: message, edit: entry.edit, item: entry.item))
            } else if copy.results[entry.id] != nil, PhoneEdit.item(of: entry.edit.change) != nil {
                mine.insert(entry.id)  // only a change to an item's cells can be one of AlsoChanged's
            }
        }
        pending.removeAll { entry in
            copy.results[entry.id] != nil
                || entry.sentAt.flatMap(Self.holdDate).map { now.timeIntervalSince($0) > Self.settleAfter } == true
        }
        kept = mine.isEmpty ? nil : mine
    }

    /// Whether the item `row` says PhoneInventory.AlsoChanged.line under its number at `now` (beta run 3's S4.4, run
    /// 2's B2-13): the Mac's copy lists it as changed by two phones apart, one of those changes this phone's own
    /// (`kept`), and its day isn't over. Never on a phone that made none of them.
    public func alsoChanged(forItem row: Int64, in copy: PhoneInventory, now: Date = Date()) -> Bool {
        guard let mine = kept, !mine.isEmpty else { return false }
        return (copy.alsoChanged ?? []).contains { merged in
            merged.item == row && merged.edits.contains(where: mine.contains)
                && (Self.plainTime.date(from: merged.until).map { now < $0 } ?? false)
        }
    }

    /// `copy` as it will be once the Mac has applied what's waiting: cells set, quantities moved (never below 0),
    /// items added (with ids below 0 until the Mac gives them theirs), To buy items bought or not needed, to-dos added
    /// (at places below 0: `ListRow.waiting`).
    public func view(_ copy: PhoneInventory) -> PhoneInventory {
        var items = copy.items
        var places = copy.places, categories = copy.categories
        var toBuy = copy.toBuy
        var barcodes = copy.barcodes ?? [:]
        var lists = copy.lists
        var marks = copy.marks, start = copy.start, pins = copy.pins
        /// A mark a waiting change means: its row's number, or, for one this phone made and the Mac hasn't numbered,
        /// its `uid`.
        func same(_ a: MapMark, _ id: Int64, _ uid: String?) -> Bool {
            id > 0 ? a.id == id : (uid != nil && a.uid == uid)
        }
        let quantity = copy.columns.first { InventoryFile.same($0.label, Inventory.Label.quantity) }
        var id = ""
        func append(_ values: [String: SQLValue]) {  // a waiting row's id, below 0, stays its own as others settle
            items.append(.init(id: Self.temporaryID(id), position: items.count + 1, values: values))
        }
        for entry in pending {
            id = entry.id
            switch entry.edit.change {
            case .set(_, let row, let colId, let value), .revert(_, let row, let colId, let value, _):
                if let n = items.firstIndex(where: { $0.id == row }) {
                    var values = items[n].values
                    values[colId] = value
                    items[n] = .init(id: row, position: items[n].position, values: values, manual: items[n].manual)
                }
            case .adjust(let row, let by):
                guard let quantity, let n = items.firstIndex(where: { $0.id == row }) else { continue }
                let current = InventoryValues.plain(items[n].values[quantity.colId] ?? .null)
                    .trimmingCharacters(in: .whitespaces)
                guard let found = current.isEmpty ? 0 : InventoryValues.parseNumber(current) else { continue }
                var values = items[n].values
                values[quantity.colId] = Self.quantity(max(0, found + by), kind: quantity.kind)
                items[n] = .init(id: row, position: items[n].position, values: values, manual: items[n].manual)
            case .add("Locations", let values):  // a place made here, in the pick lists while it waits (Task 1.6)
                let keptIn = values[Inventory.Label.keptIn]?.whole ?? 0
                places.append(.init(id: Self.temporaryID(id), name: InventoryValues.plain(values["Name"] ?? .null),
                                    label: "", grab: "", keptIn: keptIn == 0 ? nil : keptIn,
                                    vehicle: values[Inventory.Label.vehicle]?.whole == 1))
            case .add("Categories", let values):
                let group = InventoryValues.plain(values[Inventory.Label.countsAs] ?? .null)
                categories.append(.init(id: Self.temporaryID(id), name: InventoryValues.plain(values["Name"] ?? .null),
                                        group: ToBuyList.groups.first { InventoryFile.same($0, group) }))
            case .add(_, let values):
                append(values)
            case .bought(let values, let tick):
                append(values)
                toBuy.removeAll { $0.id == tick.item }
            case .tick(let tick) where tick.kind == .notNeeded:
                toBuy.removeAll { $0.id == tick.item }
            case .linkBarcode(let code, let row):
                if let code = Barcode.valid(code) { barcodes[code] = row }
            case .addItem(let values, let code):
                append(values)
                if let code = Barcode.valid(code) { barcodes[code] = Self.temporaryID(id) }
            case .deleteSeen(let row, _):  // gone from this phone at once, its codes with it (2026-11-18)
                items.removeAll { $0.id == row }
                barcodes = barcodes.filter { $0.value != row }
            case .listSet(let sheet, let ref, let column, let value, _):  // the lists (plan phase 7, part 2)
                guard var found = lists else { continue }
                if sheet == ListsLayout.settings {
                    if case .text(let mode) = value, ListsLayout.eventSwitch.contains(mode) { found.eventMode = mode }
                } else if sheet == ListsLayout.todo || sheet == ListsLayout.upkeep,
                          let row = found.asLists.find(ref, in: sheet) {
                    func change(_ rows: inout [ListRow]) {
                        if let n = rows.firstIndex(of: row) { rows[n].cells[column] = value }
                    }
                    if sheet == ListsLayout.todo { change(&found.todo) } else { change(&found.upkeep) }
                } else if sheet == ListsLayout.recalls, column == "Status", value != .null {
                    found.recalls?.removeAll { $0.id == ref.id }  // answered: off the list at once (Task 6.4)
                }
                lists = found
            case .removeMark(let id, let expected):  // gone from this phone's map and list while it waits (2026-11-12)
                marks?.removeAll { same($0, id, expected.uid) }
                pins?.removeAll { same($0, id, expected.uid) }
            case .changeMark(let mark, _):  // its new name or note, here while it waits
                // (one this phone made keeps the number it is shown under)
                if let n = marks?.firstIndex(where: { same($0, mark.id, mark.uid) }), let shown = marks?[n].id {
                    marks?[n] = mark.with(id: shown)
                }
                if let n = pins?.firstIndex(where: { same($0, mark.id, mark.uid) }), let shown = pins?[n].id {
                    pins?[n] = mark.with(id: shown)
                }
                if start?.id == mark.id { start = mark }
            case .addMark(var mark):  // here at once, numbered below 0 until the Mac has it (a list tells two apart);
                mark.id = Self.temporaryID(id)  // once only, however often it was sent
                if mark.kind == .pin, pins?.contains(where: { $0.uid == mark.uid }) == false { pins?.append(mark) }
                if mark.kind == .rally, marks?.contains(where: { $0.uid == mark.uid }) == false { marks?.append(mark) }
            case .listAdd(ListsLayout.todo, let cells):  // a phone's own to-do, at a place below 0 until the Mac has it
                let place = -1 - (lists?.todo.count ?? 0)
                lists?.todo.append(ListRow(pos: place, cells: cells))
            default:
                continue
            }
        }
        return PhoneInventory(writtenAt: copy.writtenAt, columns: copy.columns, items: items, places: places,
                              categories: categories, headsUpDays: copy.headsUpDays, toBuy: toBuy,
                              results: copy.results, barcodes: barcodes, marks: marks, start: start, lists: lists,
                              supply: copy.supply, pets: copy.pets, useLog: copy.useLog, alsoChanged: copy.alsoChanged,
                              pins: pins, format: copy.format)
    }

    /// The Event mode this phone switched to and the Mac hasn't answered yet, or nil.
    public var waitingEventMode: String? {
        pending.compactMap { entry -> String? in
            guard case .listSet(ListsLayout.settings, _, "Value", .text(let mode), _) = entry.edit.change,
                  ListsLayout.eventSwitch.contains(mode) else { return nil }
            return mode
        }.last
    }

    /// A waiting added row's id: below 0, from its edit's id, so it never changes while it waits.
    public static func temporaryID(_ editID: String) -> Int64 {
        let digits = editID.filter(\.isHexDigit).prefix(12)
        return -(Int64(digits, radix: 16) ?? 1) - 1
    }

    /// The own To buy items waiting for the Mac.
    public var ownItems: [ToBuyTick] {
        pending.compactMap { if case .tick(let tick) = $0.edit.change, tick.kind == .add { tick } else { nil } }
    }

    public enum Problem: Error, Equatable { case unreadable }

    /// The waiting changes kept on the phone: empty only when there is no file. One that is there but can't be read
    /// (damaged, or still locked before the phone's first unlock) throws, so the phone never saves over it and loses
    /// every change in it (offline fixes, task 1.1; the review's miss 2).
    public static func read(_ url: URL) throws -> PhoneOutbox {
        guard FileManager.default.fileExists(atPath: url.path) else { return PhoneOutbox() }
        do { return try JSONDecoder().decode(PhoneOutbox.self, from: Data(contentsOf: url)) } catch {
            throw Problem.unreadable
        }
    }

    public func write(_ url: URL) throws {
        try DurableFile.write(try JSONEncoder().encode(self), to: url)
        #if os(iOS)  // readable from the first unlock on, so a background launch after a restart reads it (task 1.1)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
        #endif
    }

    /// The changes made since a file that couldn't be read at launch, added to it once it reads: each change once.
    public mutating func takeIn(_ since: PhoneOutbox) {
        pending += since.pending.filter { new in !pending.contains { $0.id == new.id } }
        refused += since.refused.filter { new in !refused.contains { $0.id == new.id } }
    }
}

/// How one post of a phone's changes to the Mac ended (checkpoint 2): what decides whether they stay marked sent.
public enum PhoneSend: Equatable, Sendable {
    /// The Mac's service answered with this status (202: taken).
    case answered(Int)
    /// Nothing of it reached the Mac: not paired, away from home, the Mac off, a certificate refused.
    case notReached
    /// It went out and no answer came (a timeout after the post was sent): the Mac may have it.
    case unsure

    /// An unanswered post: unsure once any of its body went out (URLSession's `countOfBytesSent`: 0 when the Mac
    /// couldn't be reached or the connection never opened, the whole body when it went out and no answer came;
    /// measured on this Mac, checkpoint 2), else never reached.
    public static func unanswered(bodyBytesSent: Int64) -> PhoneSend {
        bodyBytesSent > 0 ? .unsure : .notReached
    }

    /// The tries at the Mac's addresses, in order, as one: an answer first, then a post that went out, else none
    /// reached it (no address tried: not paired).
    public static func first(_ tries: [PhoneSend]) -> PhoneSend {
        if let answer = tries.first(where: { if case .answered = $0 { true } else { false } }) { return answer }
        return tries.contains(.unsure) ? .unsure : .notReached
    }
}

/// One look's send of the waiting changes (checkpoint 2): all at once, and one at a time when the Mac can't read the
/// lot (an older Mac app, say), so one edit it can't read never takes the others down with it. Which changes the Mac
/// refused, and which never reached it: those wait as never sent (PhoneOutbox.unsend), so quick add's Undo last
/// takes them back again; everything else stays sent, as the Mac may have it.
public struct PhoneDelivery: Equatable, Sendable {
    /// The first answer's status, nil when nothing answered (401: the Mac no longer knows this phone, said by the batch
    /// or by any one-at-a-time send, which then stop; whole-plan review).
    public var status: Int?
    /// Refused because this phone reads only (403).
    public var readOnly: [String] = []
    /// Refused as of a kind the Mac doesn't read (400): most likely the Mac's PrepareMe is older than this phone's.
    public var unreadable: [String] = []
    /// Refused as too long (413).
    public var tooLong: [String] = []
    /// Never reached the Mac, not taken by it (503: its inbox full), or never sent once the one-at-a-time sends
    /// stopped.
    public var notReached: [String] = []

    public init(status: Int? = nil, readOnly: [String] = [], unreadable: [String] = [], tooLong: [String] = [],
                notReached: [String] = []) {
        self.status = status
        self.readOnly = readOnly
        self.unreadable = unreadable
        self.tooLong = tooLong
        self.notReached = notReached
    }

    /// Send `entries` (already marked sent) with `send`, on the caller's actor, and say how each ended.
    public static func run(_ entries: [PhoneOutbox.Entry], isolation: isolated (any Actor)? = #isolation,
                           send: (PhoneEdits) async -> PhoneSend) async -> PhoneDelivery {
        var result = PhoneDelivery()
        guard !entries.isEmpty else { return result }
        let ids = entries.map(\.id)
        let first = await send(PhoneEdits(edits: entries.map(\.edit)))
        switch first {
        case .notReached, .answered(503):  // a 503: the Mac's inbox was full and took none (re-review)
            result.notReached = ids
            if case .answered(let status) = first { result.status = status }
        case .unsure:
            break  // the post went out: the Mac may have them
        case .answered(let status):
            result.status = status
            switch status {
            case 403:
                result.readOnly = ids
            case 400 where entries.count == 1:
                result.unreadable = ids
            case 413 where entries.count == 1:
                result.tooLong = ids
            case 400, 413:
                for (n, one) in entries.enumerated() {
                    let answer = await send(PhoneEdits(edits: [one.edit]))
                    if answer == .answered(400) { result.unreadable.append(one.id) }
                    if answer == .answered(413) { result.tooLong.append(one.id) }
                    // this one and the rest never reached the Mac (or its inbox was full)
                    guard answer != .notReached, answer != .answered(503) else {
                        result.notReached = Array(ids[n...])
                        break
                    }
                    // a 401: the Mac forgot this phone meanwhile, so stop as after a batch's 401; a 403 or no answer
                    // stops too
                    if [.answered(401), .answered(403), .unsure].contains(answer) {
                        if answer == .answered(401) { result.status = 401 }
                        result.notReached = Array(ids[(n + 1)...])  // the rest are never sent
                        break
                    }
                }
            default:
                break  // taken, or anything else: they wait for the Mac's answer, or the next look
            }
        }
        return result
    }
}
