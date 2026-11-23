import Foundation

/// One tile on the Mac's Inventory home page (the inventory fresh look, phase 3; spec 5.1): a category, a top-level
/// place or a vehicle, with its emoji, its name in title case and what it holds ("14 items", "31 items, 6 bins").
public struct InventoryTile: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let emoji: String
    public let name: String
    public let detail: String

    public init(id: Int64, emoji: String, name: String, detail: String) {
        self.id = id
        self.emoji = emoji
        self.name = name
        self.detail = detail
    }
}

/// What the Mac's Inventory home page lists, in the old list column's order and conditions, so a test pins it.
public enum InventoryHomeTiles {
    /// Each category in the Categories table's order, its emoji the phones' (`InventoryLook.emoji`).
    public static func categories(_ inventory: Inventory) -> [InventoryTile] {
        inventory.sidebarCategories.map { entry in
            InventoryTile(id: entry.id, emoji: InventoryLook.emoji(category: entry.name, group: entry.countsAs ?? entry.name),
                          name: InventoryLook.title(entry.name),
                          detail: items(inventory.items(in: .category(entry.id)).count))
        }
    }

    /// Each top-level place that isn't a vehicle, by name as the list column had them, with everything in it and its
    /// bins counted, and how many bins sit right inside it (the buttons its table shows).
    public static func locations(_ inventory: Inventory) -> [InventoryTile] {
        byName(inventory, inventory.shownLocations).map { place(inventory, $0.id) }
    }

    /// Each vehicle by name, its emoji by the words in its name as on the phones, and how many places sit inside it.
    public static func vehicles(_ inventory: Inventory) -> [InventoryTile] {
        byName(inventory, inventory.vehicleRows).map { place(inventory, $0.id) }
    }

    /// A place's, bin's or vehicle's tile: "31 items, 6 bins", a vehicle's "12 items, 3 inside", counting the bins its
    /// bins row shows (a vehicle kept in it is listed under Vehicles: fix round 1, finding 5).
    static func place(_ inventory: Inventory, _ id: Int64) -> InventoryTile {
        let vehicle = inventory.isVehicle(id)
        let inside = inventory.shownInside(id).count
        let more = inside == 0 ? "" : vehicle ? ", \(inside) inside" : ", \(inside) bin\(inside == 1 ? "" : "s")"
        return InventoryTile(id: id, emoji: vehicle ? InventoryLook.vehicleEmoji(inventory.name(ofLocation: id)) : "📍",
                             name: name(inventory, id), detail: items(inventory.items(in: .location(id)).count) + more)
    }

    /// The slim band over a category's, place's, bin's or vehicle's table: its tile; nil over any other table.
    public static func band(_ inventory: Inventory, view: Inventory.View) -> InventoryTile? {
        switch view {
        case .category(let id): categories(inventory).first { $0.id == id }
        case .location(let id): place(inventory, id)
        default: nil
        }
    }

    /// The row of bins over a place's table: the place (`owner`, "All of …") then the bins kept right in it, by name;
    /// a bin with none of its own shows its place's row, but a vehicle never shows the row of the place it is parked
    /// in (fix round 1, finding 5). Nil when there are no bins to narrow to.
    public static func binsRow(_ inventory: Inventory, location id: Int64) -> (owner: Int64, bins: [InventoryTile])? {
        let owner = !inventory.shownInside(id).isEmpty ? id : inventory.isVehicle(id) ? nil : inventory.keptIn(id)
        guard let owner else { return nil }
        let bins = byName(inventory, inventory.shownInside(owner)).map { place(inventory, $0.id) }
        return bins.isEmpty ? nil : (owner, bins)
    }

    /// The bins row's first button, back to the whole place.
    public static func allOf(_ name: String) -> String { "All of \(name)" }

    /// The less-used lists, one row of buttons, in the spec's order.
    public enum More: Equatable, Sendable {
        case toDo, upkeep, grab(Int), targets, proposed(Int), recalls(Int), privateOnly, insured, bought

        public var title: String {
            switch self {
            case .toDo: "To Do"  // the sidebar rows' words
            case .upkeep: "Upkeep"
            case .grab(let tier): tier == 1 ? "Grab in 10 Minutes" : "Grab in an Hour"
            case .targets: "Targets"
            case .proposed(let count): "Proposed (\(count))"
            case .recalls(let open): "Recalls (\(open))"  // RecallList.sidebar's words
            case .privateOnly: "Private"
            case .insured: "Insurance Record"
            case .bought: "Bought, to Move"
            }
        }
    }

    /// To Do and Upkeep always, as their sidebar rows (the owner's choice B, 2026-11-18: at 800 points tall those rows
    /// sit below the sidebar's fold); the rest only when the old list column showed them: Targets once the lists are
    /// read, Proposed and Bought while they hold a row, Recalls while any is listed (open or cleared), Insurance Record
    /// once it is started.
    public static func more(_ inventory: Inventory) -> [More] {
        more(insured: inventory.hasInsuranceRecord, lists: inventory.lists)
    }

    static func more(insured: Bool, lists: Lists?) -> [More] {
        var found: [More] = [.toDo, .upkeep, .grab(1), .grab(2)]
        if let lists {
            found.append(.targets)
            let proposed = lists.rows(ListsLayout.proposed).count
            if proposed > 0 { found.append(.proposed(proposed)) }
            let recalls = lists.rows(ListsLayout.recalls)
            if !recalls.isEmpty { found.append(.recalls(recalls.filter(RecallList.isOpen).count)) }
        }
        found.append(.privateOnly)
        if insured { found.append(.insured) }
        if let lists, !lists.rows(ListsLayout.bought).isEmpty { found.append(.bought) }
        return found
    }

    /// The band's line under "Inventory": "212 items in 28 places."
    public static func bandLine(items count: Int, places: Int) -> String {
        "\(items(count)) in \(places) place\(places == 1 ? "" : "s")."
    }

    /// The band's second line: the day the lists job last counted (supply.json's `today`, "2026-10-07"), "Counted Oct
    /// 7."; nil when there is no count or its day can't be read.
    public static func countedLine(_ today: String) -> String? {
        let day = Date.ISO8601FormatStyle().year().month().day()
        guard let date = try? day.parse(today) else { return nil }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = TimeZone(identifier: "UTC")!  // the parsed day is midnight UTC
        style.locale = Locale(identifier: "en_US")  // the app's words are English
        return "Counted \(date.formatted(style))."
    }

    static func items(_ count: Int) -> String { "\(count) item\(count == 1 ? "" : "s")" }

    static func name(_ inventory: Inventory, _ id: Int64) -> String {
        let name = inventory.name(ofLocation: id)
        return name.isEmpty ? "Unnamed Location" : InventoryLook.title(name)  // as the list column's row
    }

    static func byName(_ inventory: Inventory, _ rows: [InventoryRow]) -> [InventoryRow] {
        rows.sorted { inventory.name(ofLocation: $0.id).localizedStandardCompare(inventory.name(ofLocation: $1.id))
            == .orderedAscending }
    }
}
