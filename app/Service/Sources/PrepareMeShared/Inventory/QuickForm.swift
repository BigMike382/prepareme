import Foundation

/// The phone item form's Quick add rules (inventory fresh look, spec 5.3, Task 2.4): after a scan, Quick add opens the
/// full item form in place of its own short card, and the card's rules came with it. A nameless product is added and
/// named later by itself (`ProductLookupClient.waitForName`), so the name isn't asked for, but a blank Quantity is
/// refused in the card's words.
public enum QuickForm {
    /// Whether the form looks the barcode up as it opens: a new item from a scanned code, Quick add's or Scan's "A new
    /// item with this code" (owner, 2026-11-17, in chat). Never "Edit again" on a refused add: it opens with what was
    /// typed, and its code was looked up then.
    public static func looksUp(barcode: String?, isNew: Bool, prefill: [String: SQLValue]) -> Bool {
        barcode != nil && isNew && prefill.isEmpty
    }

    /// Whether a new item's blanks start filled: Quick add's place, category and unit, Bought…'s line, or Add's one
    /// memory, and a Quantity of 1. Never "Edit again" on a refused add, which shows exactly what was typed (fix wave,
    /// M2): a memory of days ago would be sent with an item it was never chosen for.
    public static func fillsBlanks(isNew: Bool, prefill: [String: SQLValue]) -> Bool { isNew && prefill.isEmpty }

    /// The form's name check (`PhoneEditRules.nameProblem`), skipped in Quick add, where a nameless product is named
    /// later from its barcode.
    public static func nameProblem(quick: Bool, columnLabel: String, typed: String, was: String?) -> String? {
        quick ? nil : PhoneEditRules.nameProblem(columnLabel: columnLabel, typed: typed, was: was)
    }

    /// A blank Quantity, refused where one is `required`, in the card's words ("Quantity: write a number, like 6 or
    /// 2.5."): in Quick add, and in a shortfall's Bought on both apps, whose tick takes the line off To Buy for an item
    /// that would count nothing (phase 2 review, M1). Anything typed is checked as on every form
    /// (`PhoneEditRules.problem`).
    public static func quantityProblem(required: Bool, typed: String) -> String? {
        guard required, typed.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "\(Inventory.Label.quantity): \(PhoneEditRules.lowered(InputProblem.notANumber.description))"
    }

    /// The added item as Quick add's count and its note name it: its name as typed, or "an item to name later".
    public static func shownName(_ name: String) -> String {
        waitsForName(name) ? "an item to name later" : name
    }

    /// Whether the code waits to be named later (`ProductLookupClient.waitForName`).
    public static func waitsForName(_ name: String) -> Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A code waiting to be named, as the phone's copy (`shown`, waiting adds included) holds it: no item holds it, so it
    /// stops waiting (its add refused and thrown away, taken back, or its item deleted on the Mac; phase 2 review, M2);
    /// its add is still on this phone; its item has a name now; or it is on the Mac with none, to look up.
    public enum NameWait: Equatable, Sendable { case gone, waiting, named, unnamed(Int64) }

    /// `item` is the Item column's id.
    public static func nameWait(_ code: String, in copy: PhoneInventory, item: String) -> NameWait {
        guard let id = copy.barcodes?[code], let row = copy.items.first(where: { $0.id == id }) else { return .gone }
        guard id > 0 else { return .waiting }
        return waitsForName(InventoryValues.plain(row.values[item] ?? .null)) ? .unnamed(id) : .named
    }

    /// Quick add's Add 1 to it (addition D) is the repeat scan's 1 more, which adds only to an item kept in the place
    /// being scanned into (`ItemMatch.inPlace`), so it is offered only for one (phase 2 review, M4).
    public static func offersAddOne(itemPlace: Int64?, place: Int) -> Bool { place != 0 && itemPlace == Int64(place) }

    /// Bought…'s button words, its own form's (phase 2 review, 9: no command renamed).
    public static let boughtAdd = "Add to the inventory"
    /// The bar's button: Bought…'s words, Quick add's one Add, or Add's Done beside Add Another (phase 2 review, M8).
    public static func addWord(bought: Bool, quick: Bool) -> String {
        bought ? boughtAdd : quick ? "Add" : InventoryWords.doneAdding
    }
    /// The top right's: Save on an edit, else as the one at the bottom.
    public static func confirmWord(isEdit: Bool, bought: Bool) -> String { isEdit ? "Save" : bought ? boughtAdd : "Add" }

    /// A new item's values as sent (review of Task 2.4): a blank or a zero is left out (an empty box, a pick of none),
    /// but a Quantity typed as 0 is kept as 0, as Quick add's card sent it. A blank Quantity stays blank: the lists job
    /// leaves out an item with no Quantity for lack of one (`readiness/supply.py`, `_left_out`), while a 0 counts as
    /// none. `quantity` is the Quantity column's id and the text typed in it.
    public static func newItemKept(_ values: [String: SQLValue], quantity: (colId: String, typed: String)?)
        -> [String: SQLValue] {
        let blank: (SQLValue) -> Bool = { $0 == .text("") || $0 == .null || $0 == .int(0) || $0 == .real(0) }
        let typedQuantity = !(quantity?.typed ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return values.filter { key, value in !blank(value) || typedQuantity && key == quantity?.colId }
    }

    /// Quick add's form goes to full height when the what's-missing line is amber (addition C, owner 2026-11-18): a
    /// supply field is missing, Each holds say, below the half-height sheet's Name and Brand. Green or no line leaves the
    /// sheet as it is; the form never shrinks it.
    public static func opensTall(_ needs: ItemNeeds.Line?) -> Bool {
        if case .missing = needs { true } else { false }
    }

    /// Whether a swipe down is held on a new item (Cancel is the way out): once anything is changed, or once it has a
    /// name, a looked-up one included, as Quick add's card held it (phase 4 entry fixes; review of Task 2.4).
    public static func holdsSwipe(changed: Bool, isNew: Bool, name: String) -> Bool {
        changed || isNew && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A waiting add (a new item still on this phone) edited: its values as now typed. A cell changed to blank leaves,
    /// a 0 the add already had stays, and a Quantity typed as 0 is kept as 0, as on a new item (`newItemKept`; review
    /// of Task 2.4). `changed` is what the form sends, `quantity` the Quantity column's id and its text.
    public static func waitingAddKept(_ add: [String: SQLValue], changed: [String: SQLValue],
                                      quantity: (colId: String, typed: String)?) -> [String: SQLValue] {
        add.filter { changed[$0.key] == nil }.merging(newItemKept(changed, quantity: quantity)) { $1 }
    }

    /// One memory (spec 5.3, Task 2.5): the last place, category and unit a new item was added with, by Quick add or
    /// Add (never Bought…, whose line fills in its own: a water line's gallons would become the next scan's unit), kept
    /// in the settings Quick add has kept them in since 2026-10-23, so the next new item, either way, starts with them.
    public struct Memory: Equatable, Sendable {
        public static let placeKey = "PrepareMe.quickPlace", categoryKey = "PrepareMe.quickCategory"
        public static let unitKey = "PrepareMe.quickUnit"
        /// The Unit with nothing remembered, Quick add's and Add's alike (phase 2 review, 2): Quick add has always
        /// started there and its setting is the one memory; the count, Used 1's words and the calorie rules read "each"
        /// as they read a blank
        public static let quickUnit = "each"

        /// What a new item leaves for the next (phase 2 review, 2): only a place, category or unit picked or typed,
        /// never 0 for no place or category, nor a blank Unit, so one Add with none never clears Quick add's bin or its
        /// "each". Nil is left as it is.
        public struct Write: Equatable, Sendable {
            public var place: Int?
            public var category: Int?
            public var unit: String?

            public init(place: Int64, category: Int64, unit: String) {
                self.place = place != 0 ? Int(place) : nil
                self.category = category != 0 ? Int(category) : nil
                self.unit = unit.trimmingCharacters(in: .whitespaces).isEmpty ? nil : unit
            }
        }

        public var place: Int
        public var category: Int
        public var unit: String

        public init(place: Int, category: Int, unit: String) {
            self.place = place
            self.category = category
            self.unit = unit
        }

        /// What Add's new item starts with: the remembered place, category and unit (`startUnit`), a place or category
        /// the Mac has since removed forgotten.
        public static func forAdd(place: Int, category: Int, unit: String, places: [Int64],
                                  categories: [Int64]) -> Memory {
            Memory(place: place, category: category, unit: startUnit(unit))
                .forgettingGone(places: places, categories: categories)
        }

        /// The remembered unit a new item starts with, `quickUnit` for a blank one (phase 2 review, M6): the setting's
        /// default reaches only a phone that never stored it, and an earlier build's Add stored blanks.
        public static func startUnit(_ stored: String) -> String {
            stored.trimmingCharacters(in: .whitespaces).isEmpty ? quickUnit : stored
        }

        /// A remembered place or category the Mac has since removed is forgotten (2026-10-23), never sent with an item.
        public func forgettingGone(places: [Int64], categories: [Int64]) -> Memory {
            Memory(place: places.contains(Int64(place)) ? place : 0,
                   category: categories.contains(Int64(category)) ? category : 0, unit: unit)
        }
    }

    /// Bought…'s new item (Task 2.5): the To Buy line's name, what it still needs, its unit and the first category in
    /// its group, all changeable in the form; no place. A shortfall line's Name and Quantity start blank (addition A,
    /// owner 2026-11-18): its text is the list's sentence and its need the whole shortfall, so an Add as it opened
    /// would record what was never bought; an expiry line's Name starts blank too, its Quantity as before (round 2, 2).
    /// `colId` is a column's id by its label, nil when the copy has none.
    public static func boughtValues(_ line: ToBuyList.Item, colId: (String) -> String?,
                                    categories: [PhoneInventory.Category]) -> [String: SQLValue] {
        var values: [String: SQLValue] = [:]
        let category = line.category.flatMap { group in categories.first { $0.group == group } }
        let clean = line.isShortfall  // blank text, so the form's Quantity of 1 doesn't fill it either
        for (label, value) in [(Inventory.Label.item, SQLValue.text(line.isListSentence ? "" : line.text)),
                               (Inventory.Label.quantity, clean ? SQLValue.text("") : line.need.map(SQLValue.real)),
                               ("Unit", .text(line.unit)),
                               (Inventory.Label.category, category.map { SQLValue.int($0.id) })] {
            if let value, let id = colId(label) { values[id] = value }
        }
        return values
    }

    // MARK: What a save sends (phase 2 review, 12: moved from the phone's `ItemForm.save`, so it is tested by behavior)

    /// An edit opened on a waiting add (its id below 0) whose add has reached the Mac (`row` has its real id now): the
    /// Mac's row then becomes what the form opened with, so a cell the Mac changes after that, while the form is still
    /// open, is refused as on any edit (phase 2 review, M5). Only for the cells the add left out (null or missing): a
    /// cell the add carried stays the add's, so a Mac change to it before this phone's copy caught up is refused too,
    /// never written over (round 2, 1). Otherwise the base is left as it is.
    public static func arrived(openedID: Int64?, openedValues: [String: SQLValue]?, row: PhoneInventory.Row?)
        -> (id: Int64?, values: [String: SQLValue]?) {
        guard (openedID ?? 0) < 0, let row, row.id > 0 else { return (openedID, openedValues) }
        return (row.id, row.values.merging((openedValues ?? [:]).filter { $0.value != .null }) { _, added in added })
    }

    /// A new item's kind: Add's (Scan's "A new item with this code" too) or "Edit again" on a refused add, Quick add's
    /// with its run's place and category read live, or Bought…'s with its To Buy line. An edit ignores it.
    public enum NewItem: Equatable, Sendable {
        case add(editAgain: Bool)
        case quick(place: Int, category: Int)
        case bought(ToBuyList.Item)
    }

    public struct Cell: Equatable, Sendable {
        public let change: InventoryChange
        public let what: String
    }

    /// What Save or Add sends: the problems to show under their fields; nothing, for a second tap while one is on its
    /// way; a waiting add's values as now typed; an edit's cell changes; nothing to add; or the new item's one change,
    /// with what its count names it, what the one memory keeps and whether its code waits to be named.
    public enum Sent: Equatable, Sendable {
        case problems([String: String])
        case busy
        case waitingAdd(id: Int64, values: [String: SQLValue])
        case cells([Cell])
        case nothing
        case new(change: InventoryChange, what: String, name: String, remember: Memory.Write?, namesLater: Bool)
    }

    public static let longest = 1000  // characters in one field, well inside what a post to the Mac may carry

    /// The form's Save or Add. Only the fields changed from the item's own (`was`, as the form showed them; nil for a
    /// new item) are checked and sent: a column left alone is never rewritten (review of phase 4). `now` is each
    /// column's text as typed: a reference's picked id, a date's day, a switch's "Yes" or blank. An edit says what the
    /// form opened with (`openedID`, `openedValues`), so a cell the Mac changed meanwhile is refused, never overwritten
    /// (stale edit base fix, 2026-11-18); but an edit opened on a waiting add that the Mac has applied since (its id
    /// below 0 then, its real one now) says the Mac's row, where a blank is the file's blank text, not the add's
    /// missing null (phase 2 review, 1). `saving` is the double-tap guard: set once something goes, so a second tap
    /// sends nothing; the form clears it when it stays open.
    public static func sent(copy: PhoneInventory, columns: [PhoneInventory.Column], row: PhoneInventory.Row?,
                            openedID: Int64?, openedValues: [String: SQLValue]?, was: [String: String]?,
                            now: [String: String], new: NewItem, barcode: String?, saving: inout Bool) -> Sent {
        var found: [String: String] = [:]
        var values: [String: SQLValue] = [:]
        let quick: Bool = if case .quick = new { true } else { false }
        let shortfall: Bool = if case .bought(let line) = new { line.isShortfall } else { false }
        let send = Set(PhoneEditRules.changed(columns.map(\.colId), was: was, now: now))
        for column in columns where send.contains(column.colId) {
            let text = now[column.colId] ?? ""
            if column.kind == "reference" {
                values[column.colId] = .int(Int64(text) ?? 0)
                continue
            }
            if text.count > longest {
                found[column.colId] = "\(column.label): keep it under \(longest) characters."
            } else if let problem = PhoneEditRules.problem(columnLabel: column.label, kind: column.kind, typed: text,
                                                           choices: column.choices) {
                found[column.colId] = problem
            } else {
                switch InventoryValues.stored(text, in: copy.inventoryColumn(column)) {
                case .success(let value): values[column.colId] = value
                case .failure(let why): found[column.colId] = "\(column.label): \(PhoneEditRules.lowered(why.description))"
                }
            }
        }
        // the Mac's editor refuses a nameless add (R4.1) and a name blanked (checkpoint 2), so they are stopped here,
        // under the Item field; Quick add's nameless product is added with its barcode and named later by itself
        for column in columns {
            let typed = now[column.colId] ?? ""
            if let problem = nameProblem(quick: quick, columnLabel: column.label, typed: typed,
                                         was: row.map { InventoryValues.plain($0.values[column.colId] ?? .null) }) {
                found[column.colId] = problem
            }
            if InventoryFile.same(column.label, Inventory.Label.quantity),  // Quick add's card refused a blank one
               let problem = quantityProblem(required: quick || shortfall, typed: typed) {
                found[column.colId] = problem
            }
        }
        guard found.isEmpty else { return .problems(found) }
        guard !saving else { return .busy }  // a fast second tap, or one while this one finishes: one add, never two
        saving = true
        let quantity = copy.column(Inventory.Label.quantity).map { (colId: $0.colId, typed: now[$0.colId] ?? "") }
        if let row, row.id < 0 {  // a new item still on this phone: its waiting add, as now typed (Task 2.5)
            return .waitingAdd(id: row.id, values: waitingAddKept(row.values, changed: values, quantity: quantity))
        }
        if let row {
            let name = copy.shownName(row)
            let base = arrived(openedID: openedID, openedValues: openedValues, row: row)  // its base not moved yet
            let opened = base.id == row.id ? base.values ?? row.values : row.values
            return .cells(columns.compactMap { column in
                PhoneEditRules.cellChange(row: row.id, colId: column.colId, value: values[column.colId],
                                          opened: opened, latest: row.values)
                    .map { Cell(change: $0, what: "\(name): \(column.label)") }
            })
        }
        if case .quick(let place, let category) = new {  // read live: one the Mac removed is 0 (forgetGone), never sent
            for (label, id) in [(Inventory.Label.location, place), (Inventory.Label.category, category)] {
                if let column = copy.column(label) { values[column.colId] = .int(Int64(id)) }
            }
        }
        let kept = newItemKept(values, quantity: quantity)  // a typed 0 Quantity goes as 0
        guard !kept.isEmpty || quick else { return .nothing }  // Quick add: the code is kept at least
        let typedName = copy.column(Inventory.Label.item).flatMap { kept[$0.colId] }.map(InventoryValues.plain)
        let name = quick ? shownName(typedName ?? "") : typedName ?? "A new item"
        switch new {
        case .bought(let line):  // the item and the line's Bought tick in one change, as its own form sent them
            return .new(change: .bought(values: kept, tick: ToBuyTick(kind: .bought, item: line.id)),
                        what: "Bought \(typedName ?? line.text)", name: name, remember: nil, namesLater: false)
        case .quick, .add:
            // Quick add writes the memory as each is picked (its bindings); Edit again and Bought never write it
            var remember: Memory.Write?
            if case .add(editAgain: false) = new {
                func text(_ label: String) -> String { copy.column(label).flatMap { now[$0.colId] } ?? "" }
                remember = Memory.Write(place: Int64(text(Inventory.Label.location)) ?? 0,
                                        category: Int64(text(Inventory.Label.category)) ?? 0, unit: text("Unit"))
            }
            return .new(change: barcode.map { .addItem(values: kept, barcode: $0) } ?? .add(table: "Inventory", values: kept),
                        what: barcode == nil ? "Added \(name)" : "Added \(name), with its barcode", name: name,
                        remember: remember, namesLater: quick && barcode != nil && waitsForName(typedName ?? ""))
        }
    }
}

extension PhoneOutbox.Refusal {
    /// What "Edit again" on a refused add or change of an item opens in its form: the item (nil for a new one), what
    /// was typed, a new item's barcode, and a refused Bought…'s To Buy line, so its Add still ticks the line in one
    /// `.bought` (fix wave, M1); nil for any other kind of edit (used 1, To buy) or an item no longer there. A
    /// Bought… whose line has left To Buy since opens as a plain add: there is no line left to tick. Moved from the
    /// phone's Inventory tab (fix wave).
    public func again(in copy: PhoneInventory)
        -> (row: PhoneInventory.Row?, values: [String: SQLValue], barcode: String?, bought: ToBuyList.Item?)? {
        switch edit?.change {
        // a new place it was in, refused since, is no place (entry fixes' final review, 2), never sent to be refused
        // again
        case .add(table: "Inventory", let values): return (nil, copy.withoutGoneWaiting(values), nil, nil)
        case .addItem(let values, let barcode):  // a code another item holds is left off (entry fixes, phase 4)
            return (nil, copy.withoutGoneWaiting(values), keptBarcode(barcode), nil)
        case .bought(let values, let tick):
            return (nil, copy.withoutGoneWaiting(values), nil, copy.toBuy.first { $0.id == tick.item })
        case .set(table: "Inventory", let id, let colId, let value),
             .revert(table: "Inventory", let id, let colId, let value, _):
            guard let row = copy.items.first(where: { $0.id == id }) else { return nil }
            return (row, [colId: value], nil, nil)
        default: return nil
        }
    }
}

/// What a scanned code's lookup put in the form, beside the fields themselves: the line under the name, the food
/// services' figures, the two servings boxes and the whole package's figure, so the note under Calories each can say
/// how it was reached and a Unit change can put it in or take it out. Moved from Quick add's card (2026-11-18, Task
/// 2.4); each field is filled only while blank, so nothing typed meanwhile is ever written over.
public struct LookupFill: Equatable, Sendable {
    /// The form's fields the lookup reads and fills.
    public struct Fields: Equatable, Sendable {
        public var name, brand, model, notes, calories, unit: String
        public var category: Int64

        public init(name: String = "", brand: String = "", model: String = "", notes: String = "",
                    calories: String = "", unit: String = "", category: Int64 = 0) {
            self.name = name
            self.brand = brand
            self.model = model
            self.notes = notes
            self.calories = calories
            self.unit = unit
            self.category = category
        }
    }

    public struct Category: Sendable {
        public let id: Int64
        public let name: String
        public let group: String?

        public init(id: Int64, name: String, group: String?) {
            self.id = id
            self.name = name
            self.group = group
        }
    }

    public struct Offer: Equatable, Sendable { public let value: String, calories: Int, source: String }
    public struct Prefilled: Equatable, Sendable { public let perServing: String, servings: String, from: String }
    public struct Worked: Equatable, Sendable { public let calories: Int, note: String }

    public var looking = true
    public var heard = ""
    public var figures: String?  // what the food services have, under the name (2026-10-22)
    public var servingsShown = false  // a food: the two boxes
    public var perServing = "", servings = ""
    public var offered: Offer?  // the lookup's whole-package figure
    public var prefilled: Prefilled?  // what the lookup put in the boxes
    public var worked: Worked?  // the boxes' figure, last put in

    public init() {}

    /// "From USDA. Change anything that's wrong."
    public static func heardFrom(_ source: String) -> String { "From \(source). Change anything that's wrong." }
    public static let notFound = "Not found online: type its name."
    /// Quick add adds a nameless product and names it later; Scan's form asks for a name.
    public static func later(quick: Bool) -> String {
        // Scan's: only Quick add's nameless codes are tried again by themselves; a cancelled form leaves nothing, so
        // a later scan looks the code up again (phase 2 review, 15)
        quick ? "Couldn't look it up now. Add it anyway and it's named later by itself, or type its name."
            : "Couldn't look it up now. Type its name, or cancel and scan it again later."
    }

    /// Whether the Food group shows for the lookup's sake: a food was found.
    public var scannedFood: Bool { servingsShown || offered != nil }

    /// A product found: name, brand, model and Notes (the package size) filled only while blank; for a food, the boxes
    /// and Calories each; the Food category chosen when none is kept, and a food category kept from the last scan
    /// taken off a product that isn't food (rubbing alcohol, owner 2026-10-23), only while it is still the category the
    /// form opened with (`opened`): one picked while the lookup ran stays (review of Task 2.4).
    public mutating func found(_ info: ProductInfo, fields: inout Fields, categories: [Category], opened: Int64) {
        if fields.name.isEmpty { fields.name = info.name }
        if fields.brand.isEmpty { fields.brand = info.brand }
        if fields.model.isEmpty, !info.model.isEmpty { fields.model = info.model }
        heard = Self.heardFrom(info.source)
        figures = ProductLookup.figures(info)
        if ProductLookup.showsServings(info), fields.calories.isEmpty {
            servingsShown = true
            if perServing.isEmpty { perServing = info.perServing.map(String.init) ?? "" }
            if servings.isEmpty { servings = info.servings.map(ProductLookup.number) ?? "" }
            prefilled = Prefilled(perServing: perServing, servings: servings, from: info.figuresFrom)
            servingsChanged(&fields)
        }
        if worked == nil, fields.calories.isEmpty, let found = info.calories {  // a whole package's with no serving
            offered = Offer(value: String(found), calories: found, source: info.figuresFrom)
            if let fits = ProductLookup.caloriesToFill(found, unit: fields.unit) { fields.calories = String(fits) }
        }
        if fields.notes.isEmpty { fields.notes = info.size }
        if fields.category == 0, ProductLookup.isFood(info.source),
           let food = categories.first(where: { InventoryFile.same($0.name, "Food") }) {
            fields.category = food.id
        }
        if !ProductLookup.isFood(info.source), fields.category == opened,
           let kept = categories.first(where: { $0.id == fields.category }),
           ItemFieldGroup.showsFood(group: kept.group, calories: "") {
            fields.category = 0
        }
        looking = false
    }

    public mutating func notFound() {
        heard = Self.notFound
        looking = false
    }

    public mutating func later(quick: Bool) {
        heard = Self.later(quick: quick)
        looking = false
    }

    /// How the whole package's calories were reached, under its box: the servings, or the service's figure, or why
    /// it wasn't put in on this Unit; nil once typed over.
    public func caloriesNote(calories: String, unit: String) -> String? {
        if let worked, calories == String(worked.calories) { return worked.note }
        if let worked, calories.isEmpty, !ProductLookup.isPackageUnit(unit) {
            return ProductLookup.servingsNotFilled(worked.calories, unit: unit)
        }
        if let offered, offered.value == calories {
            return ProductLookup.caloriesOffer(offered.calories, source: offered.source)
        }
        if let offered, calories.isEmpty, !ProductLookup.isPackageUnit(unit) {
            return ProductLookup.caloriesNotFilled(offered.calories, source: offered.source, unit: unit)
        }
        return nil
    }

    /// The Unit changed: the looked-up figure (or the boxes') goes in on a package's Unit and comes out on any other.
    /// Returns Calories each as it should now read.
    public func unitChanged(calories: String, unit: String) -> String {
        guard let value = worked.map({ String($0.calories) }) ?? offered?.value else { return calories }
        if ProductLookup.isPackageUnit(unit) { return calories.isEmpty ? value : calories }
        return calories == value ? "" : calories
    }

    /// A servings box changed: Calories each and Notes take the new figure and words while they still hold the last
    /// ones the boxes put there (or nothing), so a figure or note typed over them stays. The words name the source
    /// while the boxes still hold what it gave.
    public mutating func servingsChanged(_ fields: inout Fields) {
        let last = worked
        let from = prefilled.flatMap { $0.perServing == perServing && $0.servings == servings ? $0.from : nil }
        let note = ProductLookup.servingsNote(perServing: perServing, servings: servings, from: from)
        worked = ProductLookup.caloriesFromServings(perServing: perServing, servings: servings)
            .flatMap { figure in note.map { Worked(calories: figure, note: $0) } }
        if fields.calories.isEmpty || fields.calories == last.map({ String($0.calories) }) {
            fields.calories = worked.flatMap { ProductLookup.caloriesToFill($0.calories, unit: fields.unit) }
                .map(String.init) ?? ""
        }
        if fields.notes.isEmpty || fields.notes == last?.note { fields.notes = worked?.note ?? "" }
    }
}
