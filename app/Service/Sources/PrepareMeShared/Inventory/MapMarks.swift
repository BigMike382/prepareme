import Foundation

/// The street map's rally points and routes (plan phase 9; owner, 2026-10-14: placed on the Mac's map, exact, on every
/// phone, a child's included). They live in the inventory file's own PrepareMe_MapMarks table, which no reader of
/// the lists ever reads, so they go into its nightly backup in Household Private › Backups with the rest; the Mac's
/// editor (InventoryEditor) is their only writer, its ID check reading each name and note; the phones get them in
/// their copy of the inventory (`PhoneInventory.marks`), which they keep for use offline, and change them only through
/// the Mac (`PhoneRules`).
///
/// - The Start point (hand-off improvements plan, phase 3, 2026-10-30) is one point, at most one in all: where the
///   printed turn lists begin. It is sent to phones as `PhoneInventory.start`, never among `marks`, since an older
///   app can't read a copy holding a kind it doesn't know.
/// - A rally point is one point; a route is 2 to `routePoints` points, in order. Each point is (longitude, latitude),
///   kept to 6 decimal places (about 10 cm), and must be on the map (longitude -180 to 180, latitude -85 to 85).
/// - A name is 1 to `nameLimit` characters, a note at most `noteLimit`; at most `markLimit` marks in all.
/// - A mark's `uid`, `made`, `by`, `pinSymbol` and `pinColor` are kept in the table's one `extra` column, as JSON.
/// - A pin (docs/plans/2026-11-12-one-shared-marks.md; owner, 2026-11-12: pins and rally points as one shared set) is
///   one point with a name, a symbol and a color (`PinLook`), in the same table, at most `pinLimit` of them apart from
///   `markLimit`. The file reads them as `pins()`, never among `marks()`, and phones get them as `PhoneInventory.pins`,
///   never among `marks`, since an older app can't read a copy holding a kind it doesn't know.
public struct MapMark: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case rally, route, start, pin

        /// The SF Symbol every list and the map's tap details show it with.
        public var symbol: String {
            switch self {
            case .rally: "flag.fill"
            case .route: "point.topleft.down.to.point.bottomright.curvepath.fill"
            case .start: "smallcircle.filled.circle"
            case .pin: "mappin"
            }
        }
    }

    /// A rally point's part in the plan (owner, 2026-10-14, by click; FEMA's family plan keeps a place near home, one
    /// outside the neighborhood and one out of town): the kids' arrow points to Near home, or to Out of town while
    /// Event mode is On, and every list shows them in this order. Routes have none.
    public enum Role: String, Codable, Sendable, CaseIterable, Comparable {
        case nearHome = "near-home", neighborhood = "outside-neighborhood", outOfTown = "out-of-town"

        public var words: String {
            switch self {
            case .nearHome: "Near home"
            case .neighborhood: "Outside the neighborhood"
            case .outOfTown: "Out of town"
            }
        }

        public static func < (a: Role, b: Role) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// A route's part (the street map fixes plan, task 2.1): the strip names the main route, or the alternate once
    /// someone taps Use the alternate. Kept in the table's role column; sent to phones under its own name, as a phone
    /// on an older PrepareMe can't read a copy that holds a role it doesn't know.
    public enum RouteRole: String, Codable, Sendable, CaseIterable {
        case main = "main-route", alternate = "alternate-route"

        public var words: String {
            switch self {
            case .main: "Main route"
            case .alternate: "Alternate route"
            }
        }
    }

    public var id: Int64
    public var kind: Kind
    public var name: String
    public var note: String
    public var points: [[Double]]  // [longitude, latitude] each
    public var role: Role?  // rally points only; nil when none is picked (and in a copy from before roles)
    public var routeRole: RouteRole?  // routes only; nil when none is picked
    /// Made where the mark is made (a UUID, lowercase), so a phone can name a mark the Mac hasn't given a row yet and
    /// the same mark arriving twice (by a shared file, then by the Mac) is kept once. Every pin has one, and any mark
    /// a phone made; nil on the rally points and routes the Mac made.
    public var uid: String?
    /// When it was made (ISO 8601, to the second) and where: `MapMark.byMac`, or the phone as `PhoneInbox.who` names
    /// it. Both are set by the Mac's editor, never taken from what a phone sent, and never change.
    public var made: String?
    public var by: String?
    /// The pairing label of the phone that made it ("phone1", as the service names its inbox files), set by the
    /// editor beside `by`: what the Mac finds the owner's name for that phone with (`makerName`). Kept in the file,
    /// never sent to a phone.
    public var byLabel: String?
    /// The name the owner typed for that phone on the Mac (owner, 2026-11-12: "When I label the phones by persons
    /// name the pins should carry that label"): only in the phones' copy, put there as the Mac writes it
    /// (`PhoneInventory.make`), never kept in the inventory file and never taken from what a phone sent.
    public var byName: String?
    public var pinSymbol: String?  // a pin's look, both from `PinLook`; nil on the rest
    public var pinColor: String?

    public init(id: Int64 = 0, kind: Kind, name: String, note: String = "", points: [[Double]], role: Role? = nil,
                routeRole: RouteRole? = nil, uid: String? = nil, made: String? = nil, by: String? = nil,
                byLabel: String? = nil, byName: String? = nil, pinSymbol: String? = nil, pinColor: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.note = note
        self.points = points
        self.role = role
        self.routeRole = routeRole
        self.uid = uid
        self.made = made
        self.by = by
        self.byLabel = byLabel
        self.byName = byName
        self.pinSymbol = pinSymbol
        self.pinColor = pinColor
    }

    public static let byMac = "mac"
    /// A phone as `by` holds it, from the phone's own id (the one it sends with its changes, F-095), as the Mac's
    /// edits name it (PhoneInbox.who); "" for a phone with none.
    public static func by(device: String?) -> String { PhoneInbox.who(device: device, label: "") }
    public static let pinLimit = 1000

    /// A pin with one of the looks, where it was pressed.
    public static func pin(_ look: PinLook, longitude: Double, latitude: Double, uid: UUID = UUID()) -> MapMark {
        MapMark(kind: .pin, name: look.name, points: [[longitude, latitude]], uid: uid.uuidString.lowercased(),
                pinSymbol: look.symbol, pinColor: look.color)
    }

    /// What a change is judged against: the mark without what never changes and an older phone never knew (`uid`,
    /// `made`, `by`, and the maker's label and name), so its rename of a rally point another phone made isn't taken
    /// for a mark changed since.
    var content: MapMark {
        var copy = rounded
        (copy.uid, copy.made, copy.by, copy.byLabel, copy.byName) = (nil, nil, nil, nil, nil)
        return copy
    }

    /// A paired phone as the Mac's Settings › Phones lists it: its label, when it was paired and the name the owner
    /// typed for it ("" for none).
    public struct PhoneName: Equatable, Sendable {
        public let label: String
        public let added: String
        public let name: String

        public init(label: String, added: String, name: String) {
            self.label = label
            self.added = added
            self.name = name
        }
    }

    /// The owner's name for the phone that made this mark, or nil: the phone now paired under the mark's label, when
    /// it was paired before the mark was made (a label is used again once its phone is removed, and a later phone
    /// is never given an earlier one's pins) and has a name.
    public func makerName(_ phones: [PhoneName]) -> String? {
        let format = ISO8601DateFormatter()
        guard let byLabel, !byLabel.isEmpty, let made = made.flatMap(format.date) else { return nil }
        let phone = phones.first { $0.label.replacingOccurrences(of: " ", with: "") == byLabel }
        guard let phone, !phone.name.isEmpty, let added = format.date(from: phone.added), added <= made else { return nil }
        return phone.name
    }

    /// The mark as a phone gets it: with its maker's name when the owner gave one, and without the label.
    func forPhones(_ phones: [PhoneName]) -> MapMark {
        var copy = self
        copy.byName = makerName(phones)
        copy.byLabel = nil
        return copy
    }

    func with(id: Int64) -> MapMark {
        var copy = self
        copy.id = id
        return copy
    }

    public static let nameLimit = 80
    public static let noteLimit = 300
    public static let routePoints = 5000
    public static let markLimit = 500
    /// No mark: what an undo expects when there was nothing to undo (it is refused).
    public static let gone = MapMark(id: 0, kind: .rally, name: "", points: [])

    /// Why the mark can't be kept, in fixed words, or nil.
    public var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return MapMarkWords.noName }
        if let uid, UUID(uuidString: uid) == nil { return MapMarkWords.notAMark }
        if name.count > Self.nameLimit || note.count > Self.noteLimit { return MapMarkWords.tooLong }
        switch kind {
        case .rally where points.count != 1: return MapMarkWords.onePoint
        case .start where points.count != 1: return MapMarkWords.startOnePoint
        case .route where points.count < 2: return MapMarkWords.twoPoints
        case .route where points.count > Self.routePoints: return MapMarkWords.tooManyPoints
        case .route where role != nil, .start where role != nil: return MapMarkWords.routeRole
        case .rally where routeRole != nil, .start where routeRole != nil: return MapMarkWords.rallyRouteRole
        case .pin where points.count != 1: return MapMarkWords.pinOnePoint
        case .pin where role != nil || routeRole != nil: return MapMarkWords.routeRole
        case .pin where !PinLook.symbols.contains(pinSymbol ?? "") || !PinLook.colors.contains(pinColor ?? ""):
            return MapMarkWords.pinLook
        case .pin where uid == nil: return MapMarkWords.notAMark
        case .rally where pinSymbol != nil || pinColor != nil, .route where pinSymbol != nil || pinColor != nil,
             .start where pinSymbol != nil || pinColor != nil:
            return MapMarkWords.pinLook
        default: break
        }
        let onMap = points.allSatisfy { point in
            point.count == 2 && point.allSatisfy(\.isFinite) && (-180...180).contains(point[0])
                && (-85.0511...85.0511).contains(point[1])
        }
        return onMap ? nil : MapMarkWords.offTheMap
    }

    /// The SF Symbol lists show it with: a pin's own, else its kind's.
    public var symbol: String { pinSymbol ?? kind.symbol }

    /// The same mark with its points kept to 6 decimal places, as it is stored.
    public var rounded: MapMark {
        var copy = self
        copy.points = points.map { $0.map { ($0 * 1_000_000).rounded() / 1_000_000 } }
        return copy
    }

    /// The marks as GeoJSON for the map view (a FeatureCollection of Points and LineStrings, each with its id, kind,
    /// name and note), for whichever engine draws them.
    public static func geoJSON(_ marks: [MapMark]) -> Data {
        let numbers = Position.rallyNumbers(marks)  // drawn on the printed map only (Task 11.6; F29)
        let features: [[String: Any]] = marks.map { mark in
            let geometry: [String: Any] = mark.kind == .route
                ? ["type": "LineString", "coordinates": mark.points]
                : ["type": "Point", "coordinates": mark.points.first ?? []]
            var properties: [String: Any] = ["kind": mark.kind.rawValue, "name": mark.name, "note": mark.note]
            if let role = mark.role { properties["role"] = role.words }
            if let role = mark.routeRole { properties["route"] = role.rawValue }  // the alternate draws dashed
            if let number = numbers[mark.id] { properties["number"] = number }
            if mark.kind == .route, let end = mark.points.last { properties["end"] = end }
            return ["type": "Feature", "id": mark.id, "geometry": geometry, "properties": properties]
        }
        return (try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features],
                                            options: [.sortedKeys])) ?? Data()
    }
}

/// A rally point or route an adult's phone deleted (owner, 2026-11-12, by click: a phone's delete removes it from the
/// Mac and every phone, and the Mac's panel offers Put back for `keptFor`, so a stray tap is undone in one click). Kept
/// in the inventory file's own PrepareMe_DeletedMarks table in the same save as the delete; older ones go at the next.
public struct DeletedMark: Equatable, Sendable {
    public let mark: MapMark
    public let at: Date

    public init(mark: MapMark, at: Date) {
        self.mark = mark
        self.at = at
    }

    public static let keptFor: TimeInterval = 30 * 86_400

    /// What the Mac's panel lists, newest first: deleted within `keptFor` and not on the map again (a Put back takes it
    /// off the list, and Edit › Undo of that Put back brings it back), each mark once.
    public static func shown(_ deleted: [DeletedMark], marks: [MapMark], now: Date = Date()) -> [DeletedMark] {
        var out: [DeletedMark] = []
        for one in deleted.sorted(by: { $0.at > $1.at }) where now.timeIntervalSince(one.at) < keptFor {
            if marks.contains(where: { same($0, one.mark) }) || out.contains(where: { same($0.mark, one.mark) }) { continue }
            out.append(one)
        }
        return out
    }

    /// Put back: at its own id while that is free, else as a new mark (the newest id is used again once it's deleted).
    public func putBack(among marks: [MapMark]) -> InventoryChange {
        if !marks.contains(where: { $0.id == mark.id }) { return .putBackMark(mark) }
        var fresh = mark
        fresh.id = 0
        return .addMark(fresh)
    }

    /// The same mark whatever its id.
    static func same(_ a: MapMark, _ b: MapMark) -> Bool {
        var a = a
        a.id = b.id
        return a.rounded == b.rounded
    }
}

/// The editor's fixed words for a refused meeting place, pin or route.
public enum MapMarkWords {
    public static let noName = "Give it a name."
    public static let tooLong = "Keep a name under 80 characters and a note under 300."
    public static let onePoint = "A meeting place is one place on the map."
    public static let twoPoints = "A route needs at least two points."
    public static let tooManyPoints = "A route can have at most 5,000 points; split it in two."
    public static let offTheMap = "That point isn't on the map."
    public static let full = "There are already 500 meeting places and routes; delete one first."
    public static let routeRole = "Only a meeting place is near home, outside the neighborhood or out of town."
    public static let rallyRouteRole = "Only a route is main or alternate."
    public static let startOnePoint = "The printed directions' start is one place on the map."
    public static let oneStart = "Printed directions already have a start; delete it first."
    public static let pinOnePoint = "A pin is one place on the map."
    public static let pinLook = "That pin's symbol or color isn't one PrepareMe has."
    public static let pinsFull = "There are already 1,000 pins; delete one first."
    public static let notAMark = "That isn't a pin PrepareMe made."
    public static let deletedSince = "This was deleted on another device since. Put back on the Mac's street map "
        + "brings it back."
    /// A child's phone adds pins and removes its own (owner, 2026-11-12); anything else is an adult's.
    public static let adultsOnly = "Only an adult's phone or the Mac can make this change."

    // Select's Delete on an adult's phone, and the Mac's Put back (owner, 2026-11-12, by click)
    public static let pickToShareOrDelete = "Tick the pins, then Share or Delete."
    public static func deleteButton(_ count: Int) -> String { "Delete \(count)" }
    public static func deleteQuestion(_ count: Int) -> String { "Delete \(count) from every device?" }
    public static let deleteWhy = "They leave the Mac and every phone at this phone's next check with the Mac."
    /// The phone's waiting (and refused) change, as its Inventory lists it
    public static func deleted(_ name: String) -> String { "Delete from the street map: \(name)" }
    public static let deletedOnPhones = "Deleted on a phone"
    /// The Mac's folded group of them, closed until opened (owner, 2026-11-15: "collapsed by default")
    public static func deletedHeading(_ count: Int) -> String { "\(deletedOnPhones) (\(count))" }
    public static func deletedOn(_ name: String, _ day: String) -> String { "\(name), \(day)" }
    public static let putBack = "Put back"

    // One rally point's or route's menu: a held finger in the list, a tap on the map (owner, 2026-11-12, by click)
    public static func deleteOneQuestion(_ name: String) -> String { "Delete \(name) from every device?" }
    public static let deleteOneWhy = "It leaves the Mac and every phone at this phone's next check with the Mac."
    public static let editWhy = "It changes on the Mac and every phone at this phone's next check with the Mac."
}

extension InventoryFile {
    static let marksTable = "PrepareMe_MapMarks"

    private func hasMarks() throws -> Bool {
        try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(Self.marksTable)])
            .isEmpty
    }

    /// Every rally point and route (and the Start point), in the order they were made; never a pin.
    public func marks() throws -> [MapMark] {
        try everyMark().filter { $0.kind != .pin }
    }

    /// Every pin, in the order they were made.
    public func pins() throws -> [MapMark] {
        try everyMark().filter { $0.kind == .pin }
    }

    private func everyMark() throws -> [MapMark] {
        guard try hasMarks() else { return [] }
        return try db.query("SELECT id, kind, name, note, points, \(try column("role")), \(try column("extra")) "
                            + "FROM \"\(Self.marksTable)\" ORDER BY id").compactMap(Self.mark)
    }

    public func mark(_ id: Int64) throws -> MapMark? {
        guard try hasMarks() else { return nil }
        return try db.query("SELECT id, kind, name, note, points, \(try column("role")), \(try column("extra")) "
                            + "FROM \"\(Self.marksTable)\" WHERE id = ?", [.int(id)]).first.flatMap(Self.mark)
    }

    /// The role column (2026-10-14) or the extra one (2026-11-12), or '' in a table made before it, which gains it at
    /// its next write.
    private func column(_ name: String) throws -> String {
        try db.query("SELECT name FROM pragma_table_info(?) WHERE name = ?", [.text(Self.marksTable), .text(name)])
            .isEmpty ? "''" : name
    }

    private func addColumns() throws {
        for name in ["role", "extra"] where try column(name) == "''" {
            try db.execute("ALTER TABLE \"\(Self.marksTable)\" ADD COLUMN \(name) TEXT NOT NULL DEFAULT ''")
        }
    }

    /// A mark's `uid`, `made`, `by`, `symbol` and `color` as the extra column keeps them: JSON, or '' with none.
    private struct Extra: Codable {
        var uid, made, by, label, symbol, color: String?
    }

    static func extraText(_ mark: MapMark) -> String {
        let extra = Extra(uid: mark.uid, made: mark.made, by: mark.by, label: mark.byLabel, symbol: mark.pinSymbol,
                          color: mark.pinColor)
        guard extra.uid != nil || extra.made != nil || extra.by != nil || extra.symbol != nil || extra.color != nil,
              let data = try? JSONEncoder().encode(extra) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Keep a mark (at its own id when one is put back, else the next); its id.
    @discardableResult
    public func addMark(_ mark: MapMark, keepID: Bool = false) throws -> Int64 {
        guard !readOnly else { throw InventoryFileError.readOnly }
        return try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS "\(Self.marksTable)" (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, \
                name TEXT NOT NULL, note TEXT NOT NULL, points TEXT NOT NULL, role TEXT NOT NULL DEFAULT '', \
                extra TEXT NOT NULL DEFAULT '')
                """)
            try addColumns()
            let last = try db.query("SELECT max(id) FROM \"\(Self.marksTable)\"").first?.first?.whole ?? 0
            let id = keepID ? mark.id : last + 1
            try db.execute("INSERT INTO \"\(Self.marksTable)\" (id, kind, name, note, points, role, extra) "
                           + "VALUES (?, ?, ?, ?, ?, ?, ?)",
                           [.int(id), .text(mark.kind.rawValue), .text(mark.name), .text(mark.note),
                            .text(Self.pointsText(mark.points)), .text(mark.role?.rawValue ?? mark.routeRole?.rawValue ?? ""),
                            .text(Self.extraText(mark))])
            return id
        }
    }

    /// Change a mark in place; what it was.
    @discardableResult
    public func changeMark(_ mark: MapMark) throws -> MapMark? {
        guard !readOnly else { throw InventoryFileError.readOnly }
        guard let old = try self.mark(mark.id) else { return nil }
        try db.transaction {
            try addColumns()
            try db.execute("UPDATE \"\(Self.marksTable)\" SET kind = ?, name = ?, note = ?, points = ?, role = ?, "
                           + "extra = ? WHERE id = ?",
                           [.text(mark.kind.rawValue), .text(mark.name), .text(mark.note),
                            .text(Self.pointsText(mark.points)), .text(mark.role?.rawValue ?? mark.routeRole?.rawValue ?? ""),
                            .text(Self.extraText(mark)), .int(mark.id)])
        }
        return old
    }

    /// Remove a mark; what it was, or nil when there was none.
    @discardableResult
    public func removeMark(_ id: Int64) throws -> MapMark? {
        guard !readOnly else { throw InventoryFileError.readOnly }
        guard let old = try mark(id) else { return nil }
        try db.transaction { try db.execute("DELETE FROM \"\(Self.marksTable)\" WHERE id = ?", [.int(id)]) }
        return old
    }

    static let deletedMarksTable = "PrepareMe_DeletedMarks"

    /// The rally points and routes phones deleted, as kept (DeletedMark); a row that doesn't read is left out.
    public func deletedMarks() throws -> [DeletedMark] {
        guard try hasTable(Self.deletedMarksTable) else { return [] }
        let format = ISO8601DateFormatter()
        return try db.query("SELECT at, mark FROM \"\(Self.deletedMarksTable)\" ORDER BY rowid").compactMap { row in
            guard let at = Self.text(row[0]).flatMap(format.date), let json = Self.text(row[1]),
                  let mark = try? JSONDecoder().decode(MapMark.self, from: Data(json.utf8)) else { return nil }
            return DeletedMark(mark: mark, at: at)
        }
    }

    /// Keep a mark a phone's edit `edit` deleted (inside the caller's transaction), and drop those past `keptFor`.
    func keepDeletedMark(_ mark: MapMark, edit: String, now: Date = Date()) throws {
        guard !readOnly else { throw InventoryFileError.readOnly }
        let format = ISO8601DateFormatter()
        try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS "\(Self.deletedMarksTable)" (edit TEXT PRIMARY KEY, at TEXT NOT NULL, \
                mark TEXT NOT NULL)
                """)
            try db.execute("DELETE FROM \"\(Self.deletedMarksTable)\" WHERE at < ?",
                           [.text(format.string(from: now.addingTimeInterval(-DeletedMark.keptFor)))])
            try db.execute("INSERT OR IGNORE INTO \"\(Self.deletedMarksTable)\" (edit, at, mark) VALUES (?, ?, ?)",
                           [.text(edit), .text(format.string(from: now)),
                            .text(String(decoding: try JSONEncoder().encode(mark), as: UTF8.self))])
        }
    }

    static func pointsText(_ points: [[Double]]) -> String {
        String(decoding: (try? JSONEncoder().encode(points)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func mark(_ row: [SQLValue]) -> MapMark? {
        guard row.count == 7, let id = row[0].whole, let kind = text(row[1]).flatMap(MapMark.Kind.init(rawValue:)),
              let name = text(row[2]), let points = text(row[4]).flatMap({
                  try? JSONDecoder().decode([[Double]].self, from: Data($0.utf8))
              }) else { return nil }
        let extra = text(row[6]).flatMap { try? JSONDecoder().decode(Extra.self, from: Data($0.utf8)) }
        return MapMark(id: id, kind: kind, name: name, note: text(row[3]) ?? "", points: points,
                       role: kind == .rally ? text(row[5]).flatMap(MapMark.Role.init(rawValue:)) : nil,
                       routeRole: kind == .route ? text(row[5]).flatMap(MapMark.RouteRole.init(rawValue:)) : nil,
                       uid: extra?.uid, made: extra?.made, by: extra?.by, byLabel: extra?.label,
                       pinSymbol: extra?.symbol, pinColor: extra?.color)
    }
}

/// A pin's look (docs/plans/2026-11-12-one-shared-marks.md): its name, an SF Symbol and one of BASE's four color
/// roles. The ready-made ones are the phone's old pin kinds without "Meet here" (somewhere to meet is a rally point);
/// Make your own picks any of `symbols` and `colors` and types the name.
public struct PinLook: Equatable, Hashable, Sendable {
    public let name: String
    public let symbol: String
    public let color: String

    public init(name: String, symbol: String, color: String) {
        self.name = name
        self.symbol = symbol
        self.color = color
    }

    public init(_ label: PersonalPins.Label) {
        self.init(name: label.rawValue, symbol: label.symbol, color: label.color)
    }

    public static let readyMade = PersonalPins.Label.allCases.filter { $0 != .meet }.map(PinLook.init)
    /// Red danger, amber caution, blue a key fact, green fine (CLAUDE.md's color roles), each with the word a picker
    /// shows: the color alone never says what it means.
    public static let colorWords = [("red-mark", "Red: danger"), ("accent", "Amber: caution"),
                                    ("info-mark", "Blue: good to know"), ("ok-mark", "Green: safe")]
    public static let colors = colorWords.map(\.0)
    /// The symbols a pin may have, each with the word a picker and VoiceOver give it: the ready-made looks' own (and
    /// Meet here's, for a pin kept from before), then the rest Make your own offers.
    public static let symbolWords = [
        ("tree.fill", "Tree"), ("water.waves", "Flood"), ("nosign", "Blocked"), ("bolt.fill", "Power"),
        ("exclamationmark.triangle.fill", "Warning"), ("drop.fill", "Water"), ("house.fill", "House"),
        ("person.2.fill", "People"), ("car.fill", "Car"), ("mappin", "Pin"), ("star.fill", "Star"),
        ("cross.case.fill", "First aid"), ("fuelpump.fill", "Fuel"), ("tent.fill", "Tent"),
        ("shippingbox.fill", "Box"), ("fork.knife", "Food"), ("wrench.and.screwdriver.fill", "Tools"),
        ("antenna.radiowaves.left.and.right", "Radio"), ("flame.fill", "Fire"), ("pawprint.fill", "Animal"),
        ("leaf.fill", "Plant"), ("key.fill", "Key"), ("binoculars.fill", "Lookout"), ("building.2.fill", "Building"),
    ]
    public static let symbols = symbolWords.map(\.0)

    /// The map's fill for a color role (its light value on both map themes, dark enough under the white symbol), and
    /// red night's (the W9 review, owner 2026-10-25): a red or amber dot comes out mid red, where a white symbol is
    /// faint, so those draw their symbol dark, and red's dot white, so danger stays the brightest.
    public static func mapColor(_ token: String) -> String { String(format: "#%06x", Palette.tokens[token]?.light ?? 0) }
    public static func nightDark(_ token: String) -> Bool { token == "red-mark" || token == "accent" }
    public static func nightColor(_ token: String) -> String { token == "red-mark" ? "#ffffff" : mapColor(token) }
    /// The page's names for a symbol's two pictures, white and dark (StreetMapController.pinIcons draws them).
    public static func icon(_ symbol: String, dark: Bool = false) -> String { (dark ? "pm-pin-dark-" : "pm-pin-") + symbol }

    /// The looks to offer: the ready-made ones, then any other already on the map, each once, in the order made.
    public static func offered(_ pins: [MapMark]) -> [PinLook] {
        var out = readyMade
        for pin in pins where pin.kind == .pin {
            guard let symbol = pin.pinSymbol, let color = pin.pinColor else { continue }
            let look = PinLook(name: pin.name, symbol: symbol, color: color)
            if !out.contains(look) { out.append(look) }
        }
        return out
    }
}

extension MapMark {
    /// The pins for the map's pin layer: the shared ones, each with its name, look and `uid` (as `pin`: MapLibre turns
    /// a feature's own id into a number, so it travels as a property) and `shared`, after a phone's own pins from
    /// before pins were shared (`own`, until that phone has been asked about them).
    public static func pinsGeoJSON(_ pins: [MapMark], own: PersonalPins = PersonalPins()) -> Data {
        let shared: [[String: Any]] = pins.filter { $0.kind == .pin && $0.points.first?.count == 2 }.map { pin in
            let symbol = pin.pinSymbol ?? "mappin", color = pin.pinColor ?? "accent"
            return ["type": "Feature",
                    "geometry": ["type": "Point", "coordinates": pin.points[0]],
                    "properties": ["kind": "pin", "shared": true, "label": pin.name, "note": pin.note,
                                   "pin": pin.uid ?? "", "color": PinLook.mapColor(color),
                                   "nightColor": PinLook.nightColor(color), "icon": PinLook.icon(symbol),
                                   "nightIcon": PinLook.icon(symbol, dark: PinLook.nightDark(color))]]
        }
        return (try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection",
                                                             "features": own.features + shared],
                                            options: [.sortedKeys])) ?? Data()
    }
}

extension MapMarkWords {
    /// A Pins list row's one gray line (the map pins plan, 2026-11-14), the first that applies: waiting for the Mac;
    /// a meeting place's which one, with the kids line on their target; a route's role; who added it and when.
    public static func rowLine(_ mark: MapMark, waiting: Bool, kidsTarget: Bool, added: String?) -> String? {
        if waiting { return Self.waiting }
        switch mark.kind {
        case .rally:
            let which = mark.role?.words ?? anotherPlace
            return kidsTarget ? which + ". " + kidsPointHere : which
        case .route:
            return mark.routeRole?.words ?? added
        default:
            return added
        }
    }

    /// When a mark was added and where, as the device showing it says it: "Added Nov 12 on this phone", "on the
    /// Mac", "by Sam's iPhone" (the name the owner typed for that phone on the Mac: `name`, the Mac's own lookup,
    /// else the mark's `byName`), or "on another phone" for one with no name. `here` is this device as `by` holds it
    /// (`MapMark.byMac`, or the phone as the Mac's edits name it); nil for a mark with no record of it.
    public static func added(_ mark: MapMark, here: String, device: String, name: String? = nil) -> String? {
        guard let by = mark.by else { return nil }
        let day = mark.made.flatMap { ISO8601DateFormatter().date(from: $0) }
            .map { " " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
        let named = (name ?? mark.byName).flatMap { $0.isEmpty ? nil : $0 }
        let place = by == here ? "on this \(device)" : by == MapMark.byMac ? "on the Mac"
            : named.map { "by \($0)" } ?? (here == MapMark.byMac ? "on a phone" : "on another phone")
        return "Added\(day) \(place)"
    }
}

extension MapMark {
    /// The same mark as the device knows it (the map pins plan, 2026-11-14): by `uid` when both have one, so a pin
    /// still waiting for the Mac (a negative id) matches its row once the Mac gives it one; else by id.
    public func sameMark(_ other: MapMark) -> Bool {
        if let mine = uid, let theirs = other.uid { return mine.lowercased() == theirs.lowercased() }
        return id == other.id
    }

    /// What a child's phone may do to the marks (owner, 2026-11-12): add a pin, and remove a pin it made itself (one
    /// already gone is done). The Mac's rule (PhoneRules.childRefusal) and the phone's own, before it offers either.
    /// `all` is every mark and pin as the asker holds them; `phone` is the phone as `by` names it.
    public static func childMay(_ change: InventoryChange, among all: [MapMark], phone: String) -> Bool {
        switch change {
        case .addMark(let mark):
            return mark.kind == .pin
        case .removeMark(let id, let expected):
            guard let mark = id > 0 ? all.first(where: { $0.id == id })
                    : expected.uid.flatMap({ uid in all.first { $0.uid == uid.lowercased() } }) else {
                return expected.kind == .pin
            }
            // shortcut: `by` rests on the device id the phone itself sends (F-095), not on the pairing; tie it to the
            // pairing if a child's phone is ever not trusted to run PrepareMe as built
            return mark.kind == .pin && !phone.isEmpty && mark.by == phone
        default:
            return false
        }
    }

    /// Whether a phone may remove this mark: an adult's any but the Start point, a child's only a pin it made, or
    /// one it added that is still waiting for the Mac (no `by` yet, numbered below 0).
    public func removable(adult: Bool, phone: String) -> Bool {
        if adult { return kind != .start }
        return kind == .pin && (id < 0 || (!phone.isEmpty && by == phone))
    }
}

/// The file phones hand each other (Share pins, Add pins from a file; the street map fixes plan, task 4.1): version
/// 2 carries the shared pins (the shared marks plan) with their names, looks, notes and `uid`s, so the same pin
/// reaching the Mac from two phones is kept once; version 1, a phone's own pins from before, still reads. It came
/// from outside the app, so it is read with care: anything else is refused whole.
public enum SharedPinsFile {
    private struct File: Codable {
        let prepareme: String
        let version: Int
        let marks: [MapMark]
    }

    public static func encode(_ pins: [MapMark]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(File(prepareme: "pins", version: 2, marks: pins.filter { $0.kind == .pin }.map(clean)))
    }

    /// A pin as it travels and as a phone adds it: no row number, and nothing of who made it or when (the Mac says
    /// both when it takes it).
    static func clean(_ pin: MapMark) -> MapMark {
        var copy = pin.rounded
        (copy.id, copy.made, copy.by, copy.role, copy.routeRole) = (0, nil, nil, nil, nil)
        (copy.byLabel, copy.byName) = (nil, nil)
        copy.uid = pin.uid?.lowercased()
        return copy
    }

    /// The file's pins, or nil for anything that isn't one: too big, another shape or version, a mark that isn't a
    /// pin or wouldn't be kept (`MapMark.problem`), or more than the household may hold.
    public static func read(_ data: Data) -> [MapMark]? {
        guard data.count < PersonalPins.sharedMaxBytes else { return nil }
        if let old = PersonalPins.read(shared: data) { return PersonalPins(pins: Array(old.prefix(PersonalPins.limit))).asShared }
        guard let found = try? JSONDecoder().decode(File.self, from: data), found.prepareme == "pins", found.version == 2,
              found.marks.count <= MapMark.pinLimit,
              found.marks.allSatisfy({ $0.kind == .pin && $0.rounded.problem == nil }) else { return nil }
        return found.marks.map(clean)
    }

    /// The file's pins not already here: one with the same `uid`, or the same name within 5 m, is the same pin.
    public static func new(_ pins: [MapMark], among held: [MapMark]) -> [MapMark] {
        var out: [MapMark] = []
        for pin in pins {
            guard let p = pin.points.first, p.count == 2 else { continue }
            let same = (held + out).contains { other in
                guard let q = other.points.first, q.count == 2 else { return false }
                return other.uid == pin.uid || (other.name == pin.name
                    && Position.meters(from: (q[1], q[0]), to: (p[1], p[0])) <= 5)
            }
            if !same { out.append(pin) }
        }
        return out
    }

    /// What Add pins from a file says once it's done: "Added 3 pins. 1 was already here."
    public static func words(added: Int, already: Int) -> String {
        var words = "Added \(added) \(added == 1 ? "pin" : "pins")."
        if already > 0 { words += " \(already) \(already == 1 ? "was" : "were") already here." }
        return words
    }
}

extension PersonalPins {
    /// A phone's own pins from before pins were shared, as shared pins: each kind's look and word (Meet here too, kept
    /// as a pin of that name), its place, and its own id as the `uid`.
    public var asShared: [MapMark] {
        pins.map { MapMark.pin(PinLook($0.label), longitude: $0.longitude, latitude: $0.latitude, uid: $0.id) }
    }
}

extension MapMarkWords {
    // The phones' shared pins (the shared marks plan, phase 3)
    public static let addPinHere = "Add a pin here"
    public static let makeYourOwn = "Make your own…"
    public static let pinsShared = "Pins are shared with the household: the Mac and every phone get them at this "
        + "phone's next check with the Mac."
    public static let waiting = "Waiting for the Mac."
    public static let rallyShared = "It goes to the Mac and every phone at this phone's next check with the Mac. "
        + "The kids' phones point to the Near home meeting place."
    public static func pinAdded(_ name: String) -> String { "Add to the street map: \(name)" }
    // The map pins plan (2026-11-14): a meeting place is a pin, and its card and form say so
    public static let meetingPlace = "Meeting place"
    public static let meetingPlaceWhy = "Where the family meets."
    public static let kidsPointHere = "The kids' phones point here"
    public static let anotherPlace = "Another place to meet"
    public static let whichOne = "Which one"
    public static func changed(_ name: String) -> String { "Change on the street map: \(name)" }
    /// The one-time question about a phone's own pins from before (plan section 5: none is sent without asking).
    public static let oldPinsTitle = "Pins are now shared"
    public static func oldPinsQuestion(_ count: Int, device: String) -> String {
        "This \(device) has \(count) \(count == 1 ? "pin" : "pins") of its own from before. Shared pins go to the "
            + "Mac and every phone in the household."
    }
    public static let oldPinsShare = "Share them"
    public static let oldPinsDelete = "Delete them"
    public static let oldPinsLater = "Not now"
}
