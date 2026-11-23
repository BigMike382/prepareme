import Foundation

/// What the editor shows of the inventory file, read in one go (plan phase 7), and the rules every change keeps: a
/// location or category still in use can't be deleted, a bin can't end up inside itself, and the views (a place with
/// everything in its bins, a bin, a category, a group, a grab tier, Private, expiring soon).
public struct Inventory: Sendable {
    /// The layout's columns, found by the labels the owner sees, as the lists job finds them (inventory/columns.py).
    public enum Label {
        public static let item = "Item", category = "Category", location = "Location", grab = "Grab"
        public static let expires = "Expires", privateRow = "Mac only", quantity = "Quantity", model = "Model"
        public static let name = "Name", countsAs = "Counts as", keptIn = "Kept in", label = "Label"
        public static let setting = "Setting", value = "Value"
        public static let vehicle = "Vehicle"  // Locations' tick (plan phase 7, part 2): a truck, an RV
        public static let caloriesEach = "Calories each"
        // Inventory's ticks (docs/plans/2026-10-23-empty-containers-and-kept-food.md; inventory/columns.py)
        public static let emptyUntilNeeded = "Empty until needed", keepPastDate = "Keep past date"
        // Inventory's fields of the entry fixes plan's phase 3 (2026-10-23; inventory/columns.py)
        public static let eachHolds = "Each holds", holdsUnit = "Holds unit", petFoodFor = "Pet food for"
        public static let runningWatts = "Running watts", startingWatts = "Starting watts"
        public static let holdsUnits = ["gallons", "liters", "fl oz", "pounds", "cords", "watt-hours"]  // columns.HOLDS_UNITS
        public static let petFoodChoices = ["Dog", "Cat"]  // columns.PET_FOR_CHOICES
        // what the Mac adds to an older file's Unit list at open, after its own (spec 5.4, 2026-11-17)
        public static let unitAdds = ["bottles", "bags", "jars", "fl oz"]
    }

    public static let headsUpSetting = "Expiry heads-up (days)"
    public static let headsUpDefault = 60  // the lists' own default (inventory/columns.py SETTINGS)
    public static let grabChoices = ["10 min", "1 hour"]  // tier 1, tier 2 (inventory/columns.py GRAB_CHOICES)

    public let items: InventoryTable, locations: InventoryTable, categories: InventoryTable, settings: InventoryTable
    public let itemRows: [InventoryRow], locationRows: [InventoryRow], categoryRows: [InventoryRow]
    public let settingRows: [InventoryRow]
    public let barcodes: [String: Int64]  // product code → item (slice 6), read with the rest
    public let marks: [MapMark]  // the street map's rally points and routes (plan phase 9), read with the rest
    public let pins: [MapMark]  // the shared pins (2026-11-12), in the marks' table, read apart from `marks`
    public let deletedMarks: [DeletedMark]  // those phones deleted (2026-11-12), for the Mac's Put back; never stops a read
    public let lists: Lists?  // To do, Upkeep and the rest (plan phase 7, part 2; ListsTables.swift); nil until handed over
    public let members: [HouseholdMember]  // the Settings' household members (step 8a; HouseholdMembers.swift)
    public let membersUnreadable: Bool  // their table is there in another shape: shown as none, never changed
    public let pets: [HouseholdPet]  // the Settings' pets (the settings redesign; HouseholdPets.swift)
    public let petsUnreadable: Bool  // likewise: their table in another shape, shown as none, never changed

    public init(file: InventoryFile) throws {
        items = try file.table("Inventory")
        locations = try file.table("Locations")
        categories = try file.table("Categories")
        settings = try file.table("Settings")
        itemRows = try file.rows(items)
        locationRows = try file.rows(locations)
        categoryRows = try file.rows(categories)
        settingRows = try file.rows(settings)
        barcodes = try file.barcodes()
        marks = try file.marks()
        pins = try file.pins()
        deletedMarks = (try? file.deletedMarks()) ?? []
        lists = try file.lists()
        do {  // a members table in another shape never stops the inventory opening (step 8a review)
            members = try file.members()
            membersUnreadable = false
        } catch {
            members = []
            membersUnreadable = true
        }
        do {  // and the pets' likewise (the settings redesign)
            pets = try file.pets()
            petsUnreadable = false
        } catch {
            pets = []
            petsUnreadable = true
        }
    }

    public func table(_ name: String) -> InventoryTable {
        switch name {
        case "Locations": locations
        case "Categories": categories
        case "Settings": settings
        default: items
        }
    }

    public func rows(_ name: String) -> [InventoryRow] {
        switch name {
        case "Locations": locationRows
        case "Categories": categoryRows
        case "Settings": settingRows
        default: itemRows
        }
    }

    // MARK: Names

    /// The shown names of a reference column's target rows, by row id.
    public func names(for column: InventoryColumn) -> [Int64: String] {
        guard case .reference(let target) = column.kind, let shown = column.shownColId else { return [:] }
        let rows = InventoryFile.same(target, locations.tableId) ? locationRows
            : InventoryFile.same(target, categories.tableId) ? categoryRows
            : InventoryFile.same(target, items.tableId) ? itemRows : []
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, InventoryValues.plain($0.values[shown] ?? .null)) })
    }

    public func name(ofLocation id: Int64) -> String {
        locations.column(Label.name).map { InventoryValues.plain(row(locationRows, id)?[$0] ?? .null) } ?? ""
    }

    public func name(ofItem row: InventoryRow) -> String {
        items.column(Label.item).map { InventoryValues.plain(row[$0]) } ?? ""
    }

    // MARK: Places and bins

    /// The location a location is kept in ("Kept in"), when it names one that exists.
    public func keptIn(_ id: Int64) -> Int64? {
        guard let column = locations.column(Label.keptIn), let found = row(locationRows, id)?[column].whole,
              found != 0, found != id, row(locationRows, found) != nil else { return nil }
        return found
    }

    /// `id`, then the place it is kept in, and so on out to a place kept in no other (a loop can't come from the editor;
    /// it is cut here all the same).
    public func chain(ofLocation id: Int64) -> [Int64] {
        var found = [id]
        while let next = keptIn(found[found.count - 1]), !found.contains(next) { found.append(next) }
        return found
    }

    /// Where a location is, from the outside in: "Truck › Truck drawer › Truck go-bag".
    public func path(ofLocation id: Int64) -> String {
        chain(ofLocation: id).reversed().map { name(ofLocation: $0) }.joined(separator: " › ")
    }

    /// Whether a location is ticked as a vehicle (Locations' Vehicle).
    public func isVehicle(_ id: Int64) -> Bool {
        guard let column = locations.column(Label.vehicle), let row = row(locationRows, id) else { return false }
        return switch row[column] {
        case .int(let found): found != 0
        case .real(let found): found != 0
        default: false
        }
    }

    /// The vehicle a location sits in (itself, when it is one), or nil.
    public func vehicle(holding id: Int64) -> Int64? {
        chain(ofLocation: id).first(where: isVehicle)
    }

    /// A place: a location kept in no other. A bin: one kept in another.
    public var places: [InventoryRow] { locationRows.filter { keptIn($0.id) == nil } }

    /// The locations kept directly in `id`, in Grist's order.
    public func bins(in id: Int64) -> [InventoryRow] { locationRows.filter { keptIn($0.id) == id } }

    // The sidebar's Locations and Vehicles (step 8a; owner, 2026-10-19, by click: A1 and A3). The data is unchanged: a
    // vehicle is still a location (a bin can be kept in one, and the grab-and-go list reads its tick); it is only shown
    // under Vehicles instead of Locations, and never inside the place it is parked in.

    /// Locations: the places (kept in no other) that aren't vehicles, in Grist's order.
    public var shownLocations: [InventoryRow] { places.filter { !isVehicle($0.id) } }

    /// Vehicles: every location ticked Vehicle, wherever it is kept, in Grist's order.
    public var vehicleRows: [InventoryRow] { locationRows.filter { isVehicle($0.id) } }

    /// What a location opens to in the sidebar: the places and bins kept directly in it, less any vehicle (listed
    /// under Vehicles itself).
    public func shownInside(_ id: Int64) -> [InventoryRow] { bins(in: id).filter { !isVehicle($0.id) } }

    /// `id` and every location kept in it, at any depth.
    public func within(_ id: Int64) -> Set<Int64> {
        var found: Set<Int64> = [id]
        var added = true
        while added {
            added = false
            for row in locationRows where !found.contains(row.id) {
                if let parent = keptIn(row.id), found.contains(parent) {
                    found.insert(row.id)
                    added = true
                }
            }
        }
        return found
    }

    /// Remove Empty Places (owner, 2026-10-23): the locations holding no item, themselves or in any bin inside them,
    /// in Grist's order.
    public var emptyPlaces: [InventoryRow] {
        let used = Set(items.column(Label.location).map { column in itemRows.compactMap { $0[column].whole } } ?? [])
        return locationRows.filter { within($0.id).isDisjoint(with: used) }
    }

    /// Of the `ticked` empty places, those that can go together: a place stays while any place inside it stays.
    public func removable(_ ticked: Set<Int64>) -> [Int64] {
        locationRows.map(\.id).filter { ticked.contains($0) && within($0).isSubset(of: ticked) }
    }

    /// Whether keeping `bin` in `place` would put it inside itself.
    public func wouldLoop(_ bin: Int64, keptIn place: Int64) -> Bool {
        place != 0 && within(bin).contains(place)
    }

    // MARK: Refused deletes

    /// What still uses a location or category row: the items' names (an unnamed item as its row number), and for a
    /// location the bins kept in it. Empty when it may be deleted.
    /// `besides`: rows deleted along with it (B2-07), whose own Kept in doesn't count.
    public func users(of table: String, row id: Int64, besides: Set<Int64> = []) -> [String] {
        var found: [String] = []
        let target = self.table(table)
        for column in items.columns {
            guard case .reference(let pointsAt) = column.kind, InventoryFile.same(pointsAt, target.tableId) else {
                continue
            }
            for item in itemRows where item[column].whole == id {
                let name = name(ofItem: item)
                found.append(name.isEmpty ? "Inventory row \(item.position)" : name)
            }
        }
        if InventoryFile.same(table, "Locations") {
            for bin in bins(in: id) where !besides.contains(bin.id) {
                let name = name(ofLocation: bin.id)
                found.append(name.isEmpty ? "Locations row \(bin.position)" : name)
            }
        }
        return found
    }

    // MARK: Views

    /// One cell the Mac's Fill in the blanks puts a lookup's answer in (step 8a): its value, and the value it holds
    /// now, which the editor checks again at its turn (`.revert`), so a phone's change made since is never overwritten.
    public struct LookupFill: Equatable, Sendable {
        public let column: InventoryColumn
        public let value: SQLValue
        public let expected: SQLValue
    }

    /// What a lookup's answer fills in on item `row`: Item, Brand, Model (UPCitemdb's; owner, 2026-10-23), Notes (the
    /// package size) and Calories each, each
    /// only while blank (a Calories each of 0 is Grist's blank), and Calories each only on a row that counts packages
    /// (ProductLookup.isPackageUnit). `servings` is the servings boxes' figure and words (owner, 2026-10-22), which go
    /// first: Calories each, and Notes in place of the package size ("About 2.4 servings of 60 calories, from USDA").
    public func lookupFills(_ info: ProductInfo, row id: Int64,
                            servings: (calories: Int, note: String)? = nil) -> [LookupFill] {
        guard let row = itemRows.first(where: { $0.id == id }) else { return [] }
        let unit = items.column("Unit").map { InventoryValues.plain(row[$0]) } ?? ""
        let calories = ProductLookup.caloriesToFill(servings?.calories ?? info.calories, unit: unit).map(String.init)
            ?? ""
        let notes = servings?.note ?? info.size
        let offered = [(Label.item, info.name), ("Brand", info.brand), (Label.model, info.model), ("Notes", notes),
                       (Label.caloriesEach, calories)]
        return offered.compactMap { label, text in
            guard !text.isEmpty, let column = items.column(label), column.editable else { return nil }
            let now = row[column]
            let blank = InventoryValues.plain(now).trimmingCharacters(in: .whitespaces).isEmpty
                || (InventoryFile.same(label, Label.caloriesEach) && now.number == 0)
            guard blank, case .success(let value) = InventoryValues.stored(text, in: column) else { return nil }
            return LookupFill(column: column, value: value, expected: now)
        }
    }

    /// The note in place of the calories offer when item `row`'s Unit isn't a package's, or nil.
    public func caloriesWithheld(_ info: ProductInfo, row id: Int64,
                                 servings: (calories: Int, note: String)? = nil) -> String? {
        guard let row = itemRows.first(where: { $0.id == id }) else { return nil }
        let unit = items.column("Unit").map { InventoryValues.plain(row[$0]) } ?? ""
        guard !ProductLookup.isPackageUnit(unit) else { return nil }
        if let servings { return ProductLookup.servingsNotFilled(servings.calories, unit: unit) }
        return info.calories.map { ProductLookup.caloriesNotFilled($0, source: info.figuresFrom, unit: unit) }
    }


    public enum View: Hashable, Sendable {
        case all
        case location(Int64)  // a place with everything in its bins, or one bin with what's in it
        case category(Int64)
        case group(String)  // a category's Counts as, the lists' group
        case grab(Int)  // 1 for "10 min", 2 for "1 hour": the earlier of the item's own and its location's
        case privateOnly
        case expiringSoon  // within the Settings' heads-up days, already expired included
        case insured  // the insurance record's items: a Price above 0 or a Purchased date (slice 7)
        // A guide's "In the house" (phase 14, F57): the items whose names hold one of its words (GuideLinks.matches)
        case guide(title: String, words: [String])
        // The Not counted notice's Show them (owner, 2026-11-14): the rows a supply left out at the last count
        case leftOut([SupplyShares.LeftOut])
    }

    public func items(in view: View, today: Date = Date(), search: String = "") -> [InventoryRow] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return itemRows.filter { matches($0, view, today: today) && (words.isEmpty || holds($0, words)) }
    }

    /// Whether the items table shows `id` in `view` with `search` typed: Add and Go to that item show an item it leaves
    /// out in All items with no search (checkpoint 2).
    public func shows(item id: Int64, in view: View, search: String) -> Bool {
        items(in: view, search: search).contains { $0.id == id }
    }

    /// Whether `other` holds the same items, places and categories, cell for cell: the Mac reads the file every 10
    /// seconds, and builds its near-miss and add-form words again only when this is false (re-review of checkpoint 2).
    public func sameRows(as other: Inventory) -> Bool {
        itemRows == other.itemRows && locationRows == other.locationRows && categoryRows == other.categoryRows
    }

    /// What the Mac's Did you mean looks in: the items in `view`, the same rows its Nothing found is about (checkpoint
    /// 2), never a word only items elsewhere hold.
    public func nearIndex(in view: View) -> PhoneSearch.Index {
        let rows = items(in: view)
        return PhoneSearch.Index(names: rows.map { name(ofItem: $0) }, texts: rows.map { searchText($0) })
    }

    public func matches(_ item: InventoryRow, _ view: View, today: Date = Date()) -> Bool {
        switch view {
        case .all: return true
        case .location(let id):
            guard let column = items.column(Label.location), let found = item[column].whole else { return false }
            return within(id).contains(found)
        case .category(let id):
            return items.column(Label.category).map { item[$0].whole == id } ?? false
        case .group(let group):
            return self.group(of: item).map { InventoryFile.same($0, group) } ?? false
        case .grab(let tier): return grabTier(of: item) == tier
        case .privateOnly: return isPrivate(item)
        case .insured:  // a price, a purchase date or a serial number (step 6: a serial alone is worth a claim's record)
            let price = items.column(Insurance.price).flatMap { item[$0].number } ?? 0
            let serial = items.column(Insurance.serial).map { !InventoryValues.plain(item[$0]).isEmpty } ?? false
            return price > 0 || items.column(Insurance.purchased).flatMap({ item[$0].number }) != nil || serial
        case .expiringSoon:
            guard !keptPastDate(item), let column = items.column(Label.expires), let seconds = item[column].number
            else { return false }
            let limit = Calendar(identifier: .gregorian).date(byAdding: .day, value: headsUpDays, to: today) ?? today
            return Date(timeIntervalSince1970: seconds) <= limit
        case .guide(_, let words): return GuideLinks.matches(name(ofItem: item), words)
        case .leftOut(let rows):
            let print = SupplyShares.fingerprint(name(ofItem: item))
            return rows.contains { $0.row == item.position && $0.item == print }
        }
    }

    /// Ticked Keep past date: kept on purpose, so never in Expiring soon (the lists job counts it as undated).
    public func keptPastDate(_ item: InventoryRow) -> Bool {
        items.column(Label.keepPastDate).flatMap { item[$0].number }.map { $0 != 0 } ?? false
    }

    /// Private ("Mac only"): fail closed, since a Private row must never reach a phone. A tick, or any cell that isn't
    /// blank or 0: the lists job reads a typed "x", "yes" or "✓" as ticked too (sheets.ticked) and refuses any other text.
    /// Every column labeled Mac only counts, so two of that name never let a row through (the audit, 2026-10-22, 2).
    public func isPrivate(_ item: InventoryRow) -> Bool {
        items.columns.filter { InventoryFile.same($0.label, Label.privateRow) }.contains { column in
            switch item[column] {
            case .null: false
            case .int(let found): found != 0
            case .real(let found): found != 0
            case .text(let found): !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .blob: true
            }
        }
    }

    /// The Counts as of the item's category, as typed; nil when it has none.
    public func group(of item: InventoryRow) -> String? {
        guard let column = items.column(Label.category), let id = item[column].whole, id != 0 else { return nil }
        return group(ofCategory: id)
    }

    /// A category's Counts as, as typed; when blank, the lists' own group for its name (ToBuyList.categoryMap, as the
    /// lists job falls back); nil when neither, or there's no such row.
    public func group(ofCategory id: Int64) -> String? {
        guard let category = row(categoryRows, id) else { return nil }
        let found = categories.column(Label.countsAs).map { InventoryValues.plain(category[$0]) }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !found.isEmpty { return found }
        let name = categories.column(Label.name).map { InventoryValues.plain(category[$0]) } ?? ""
        return ToBuyList.group(ofName: name)
    }

    /// The groups the categories name, in the order first named.
    public var groups: [String] {
        guard let countsAs = categories.column(Label.countsAs) else { return [] }
        var seen: [String] = []
        for row in categoryRows {
            let found = InventoryValues.plain(row[countsAs]).trimmingCharacters(in: .whitespaces)
            if !found.isEmpty, !seen.contains(where: { InventoryFile.same($0, found) }) { seen.append(found) }
        }
        return seen
    }

    /// 1, 2 or 0 (none): the earlier of the item's own Grab and its location's, as the lists job sets it.
    public func grabTier(of item: InventoryRow) -> Int {
        let own = items.column(Label.grab).map { Self.tier(InventoryValues.plain(item[$0])) } ?? 0
        var placed = 0
        if let location = items.column(Label.location), let id = item[location].whole,
           let grab = locations.column(Label.grab), let found = row(locationRows, id) {
            placed = Self.tier(InventoryValues.plain(found[grab]))
        }
        return [own, placed].filter { $0 > 0 }.min() ?? 0
    }

    static func tier(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return (grabChoices.firstIndex { InventoryFile.same($0, trimmed) }).map { $0 + 1 } ?? 0
    }

    /// The Settings' heads-up days, or the lists' default when blank (0, as Grist stores a blank number).
    public var headsUpDays: Int {
        guard let setting = settings.column(Label.setting), let value = settings.column(Label.value),
              let row = settingRows.first(where: { InventoryFile.same(InventoryValues.plain($0[setting]),
                                                                       Self.headsUpSetting) }),
              let found = row[value].number, found > 0, found < 10_000 else { return Self.headsUpDefault }
        return Int(found)
    }

    /// What a search matches in an item: every column as shown, joined.
    public func searchText(_ item: InventoryRow) -> String {
        items.columns.map { column in
            InventoryValues.shown(item[column], in: column, names: names(for: column))
        }.joined(separator: " ")
    }

    private func holds(_ item: InventoryRow, _ words: [String]) -> Bool {
        let text = searchText(item)
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    func row(_ rows: [InventoryRow], _ id: Int64) -> InventoryRow? { rows.first { $0.id == id } }
}
