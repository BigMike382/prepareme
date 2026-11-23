import Foundation

/// The phone's grab-and-go checklist (plan phase 7, part 2; owner 2026-10-14): what to take in 10 minutes and in an
/// hour, as ticks kept on that phone only. A place (a bin, a drawer, a go-bag) marked Grab is one tick, everything in it
/// going with it; an item marked Grab on its own is a tick of its own unless its bin already goes as soon or sooner. The
/// tiers are the lists job's: "10 min" is 1, "1 hour" is 2 (readiness/inventory.py, GRAB_CHOICES).
///
/// Vehicles (owner 2026-10-14: gear kept loaded in the household's vehicles, in drawers, cabinets and go-bags):
/// a location ticked Vehicle is asked about first, going or not. Whatever sits in a vehicle that's going, at any
/// depth, is loaded already and leaves the list (counted in `loaded`); a Grab-marked bag or item in a vehicle staying
/// behind stays on it, "from" that vehicle, to move over. Where each thing is kept is its whole path.
public struct GrabChecklist: Equatable, Sendable {
    public struct Entry: Equatable, Identifiable, Sendable {
        public let id: String  // "bin-<place id>" or "item-<row id>": the tick's key on this phone
        public let name: String
        public let whereKept: String  // the whole path of the place it sits in ("" when none), so it can be found
        public let contents: [String]  // a bin's items, by name, those in the bins inside it too
        public let vehicle: Int64?  // the vehicle it sits in (staying behind), or nil
        /// An item's quantity with its unit ("8 pack"), "" when none is kept or it is 0; a bin has none.
        public var quantity: String = ""

        /// How many items a bin holds (its `contents`); 0 for an item.
        public var count: Int { id.hasPrefix("bin-") ? contents.count : 0 }

        /// The entry's second line (remaining-findings plan, Task 12.1; F31; owner, 2026-10-18, by click): a bin's
        /// count, its names a tap away; an item's quantity. A list of 829 names had made the checklist unusable.
        public var detail: String {
            if id.hasPrefix("bin-") {
                return count == 0 ? "Nothing listed in it" : "\(count) item\(count == 1 ? "" : "s")"
            }
            return quantity.isEmpty ? "" : "Quantity \(quantity)"
        }
    }

    public struct Vehicle: Equatable, Identifiable, Sendable {
        public let id: Int64
        public let name: String
        public let items: Int  // everything in it, at any depth
    }

    public let vehicles: [Vehicle]
    public let tenMinutes: [Entry]
    public let anHour: [Entry]
    public let loaded: Int  // items already in the vehicles going

    public static let choices = ["10 min", "1 hour"]

    static func tier(_ text: String) -> Int {
        (choices.firstIndex { InventoryFile.same($0, text) }).map { $0 + 1 } ?? 0
    }

    public init(_ copy: PhoneInventory, going: Set<Int64> = []) {
        let own = copy.column("Grab"), location = copy.column("Location"), item = copy.column("Item")
        let amount = copy.column(Inventory.Label.quantity), unit = copy.column("Unit")
        func quantity(_ row: PhoneInventory.Row) -> String {  // "" in a copy written before quantities showed
            let found = amount.map { InventoryValues.plain(row.values[$0.colId] ?? .null) } ?? ""
            guard !found.isEmpty, Double(found) != 0 else { return "" }
            let per = unit.map { InventoryValues.plain(row.values[$0.colId] ?? .null) } ?? ""
            return per.isEmpty ? found : "\(found) \(per)"
        }
        let places = Dictionary(uniqueKeysWithValues: copy.places.map { ($0.id, $0) })
        func name(_ row: PhoneInventory.Row) -> String {
            let found = item.map { InventoryValues.plain(row.values[$0.colId] ?? .null) } ?? ""
            return found.isEmpty ? "Unnamed item" : found
        }
        func placeOf(_ row: PhoneInventory.Row) -> Int64? {
            location.flatMap { row.values[$0.colId]?.whole }.flatMap { places[$0]?.id }
        }
        func byName(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        let vehicleIDs = copy.places.filter { $0.vehicle == true }.map(\.id)
        func vehicle(_ place: Int64?) -> Int64? { place.flatMap(copy.vehicle(holding:)) }
        var lists: [Int: [Entry]] = [1: [], 2: []]
        for place in copy.places where !vehicleIDs.contains(place.id) {
            let tier = Self.tier(place.grab)
            let inVehicle = vehicle(place.id)
            guard tier > 0, !(inVehicle.map(going.contains) ?? false) else { continue }
            // a bag inside a bin that already goes as soon or sooner goes with it
            let around = Array(copy.chain(place.id).dropFirst()).compactMap { places[$0] }
                .filter { !vehicleIDs.contains($0.id) }.map { Self.tier($0.grab) }.filter { $0 > 0 }
            guard around.min().map({ tier < $0 }) ?? true else { continue }
            let inside = copy.within(place.id)
            let contents = copy.items.filter { placeOf($0).map(inside.contains) ?? false }.map(name).sorted(by: byName)
            let shown = place.label.isEmpty ? place.name : "\(place.name) (\(place.label))"
            let parent = place.keptIn.map(copy.path) ?? ""
            lists[tier]?.append(Entry(id: "bin-\(place.id)", name: shown, whereKept: parent, contents: contents,
                                      vehicle: inVehicle))
        }
        var loaded = 0
        for row in copy.items {
            let place = placeOf(row)
            if let inVehicle = vehicle(place), going.contains(inVehicle) {
                loaded += 1
                continue
            }
            let mine = own.map { Self.tier(InventoryValues.plain(row.values[$0.colId] ?? .null)) } ?? 0
            guard mine > 0 else { continue }
            // its own bin, or one around it, already goes as soon or sooner
            let around = place.map(copy.chain) ?? []
            let soonest = around.compactMap { places[$0] }.filter { !vehicleIDs.contains($0.id) }
                .map { Self.tier($0.grab) }.filter { $0 > 0 }.min()
            guard soonest.map({ mine < $0 }) ?? true else { continue }
            lists[mine]?.append(Entry(id: "item-\(row.id)", name: name(row), whereKept: place.map(copy.path) ?? "",
                                      contents: [], vehicle: vehicle(place), quantity: quantity(row)))
        }
        vehicles = vehicleIDs.compactMap { places[$0] }.map { place in
            let inside = copy.within(place.id)
            return Vehicle(id: place.id, name: place.name,
                           items: copy.items.filter { placeOf($0).map(inside.contains) ?? false }.count)
        }.sorted { byName($0.name, $1.name) }
        tenMinutes = (lists[1] ?? []).sorted { byName($0.name, $1.name) }
        anHour = (lists[2] ?? []).sorted { byName($0.name, $1.name) }
        self.loaded = loaded
    }

    public var all: [Entry] { tenMinutes + anHour }
}

/// Expiry reminders on the phone (plan phase 7, part 2; owner 2026-10-14: a count only, since they show on a locked
/// phone): for each coming day on which items reach their heads-up date (their Expires less the heads-up days), one
/// notification at 9 in the morning saying how many, never which.
public enum ExpiryReminders {
    public static let identifierPrefix = "prepareme-expiry-"
    public static let daysAhead = 60
    public static let hour = 9

    public struct Reminder: Equatable, Sendable {
        public let day: DateComponents  // year, month, day, hour
        public let count: Int
        public var identifier: String {
            String(format: "\(identifierPrefix)%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        }
        public var body: String {
            count == 1 ? "1 item in the inventory reaches its heads-up date today. Open Expiring soon to see it."
                : "\(count) items in the inventory reach their heads-up date today. Open Expiring soon to see them."
        }
    }

    public static let title = "Expiring soon"

    /// Whether a tapped notification is one of these (it opens Expiring soon: Task 12.6; F38), not a download's.
    public static func isReminder(_ identifier: String) -> Bool { identifier.hasPrefix(identifierPrefix) }

    /// The reminders from `now` on: items whose heads-up date falls after today (in the household's time zone) and
    /// within `daysAhead` days. An Expires date is kept as its day's midnight UTC (Grist's dates), so days are counted
    /// in UTC from it, never shifted into the evening before.
    public static func make(_ copy: PhoneInventory, now: Date = Date()) -> [Reminder] {
        guard let column = copy.column("Expires"), let utcZone = TimeZone(identifier: "UTC") else { return [] }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = utcZone
        var home = utc
        home.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        guard let today = utc.date(from: home.dateComponents([.year, .month, .day], from: now)),
              let last = utc.date(byAdding: .day, value: daysAhead, to: today) else { return [] }
        var counts: [Date: Int] = [:]
        for row in copy.items {
            guard !copy.keptPastDate(row), let seconds = row.values[column.colId]?.number,
                  let headsUp = utc.date(byAdding: .day, value: -copy.headsUpDays,
                                         to: utc.startOfDay(for: Date(timeIntervalSince1970: seconds))) else { continue }
            if headsUp > today && headsUp <= last { counts[headsUp, default: 0] += 1 }
        }
        return counts.keys.sorted().map { day in
            var parts = utc.dateComponents([.year, .month, .day], from: day)
            parts.hour = hour
            return Reminder(day: parts, count: counts[day] ?? 0)
        }
    }
}

/// The phone's notifications ask for expiry reminders (remaining-findings plan, Task 12.6; F38; owner, 2026-10-18, by
/// click). iOS's question had come the moment the inventory first arrived, with no word from the app; now the app's own
/// line comes first, with Turn on reminders, on any paired phone (a child's too), only while there is something to
/// remind of; a refusal says where to turn them on, with Open Settings.
public enum ReminderAsk {
    public static func offer(_ status: LocationAsk.Status, hasReminders: Bool) -> LocationAsk.Offer {
        hasReminders ? LocationAsk.offer(status) : .none
    }

    public static let why = "Get a reminder when food or medicine is about to expire (it shows a count, never what)."
    public static let allow = "Turn on reminders"
    public static let refused = "Expiry reminders are off for PrepareMe. Turn them on in Settings › PrepareMe › "
        + "Notifications."
    public static let openSettings = "Open Settings"
}
