import Foundation
import Testing
@testable import PrepareMeShared

/// Task 2.4 (inventory fresh look, spec 5.3): Quick add opens the phone's item form, and the card's rules moved with it
/// (`QuickForm`, `LookupFill`). Made-up products and categories only.
struct QuickFormTests {
    static let categories = [LookupFill.Category(id: 1, name: "Food", group: "Food"),
                             LookupFill.Category(id: 2, name: "Canned goods", group: "Food"),
                             LookupFill.Category(id: 3, name: "Water", group: "Water"),
                             LookupFill.Category(id: 4, name: "First aid", group: nil)]
    /// A can of soup: 300 g, a serving of 120 g at 90 calories, so 2.5 servings and 225 calories.
    static let soup = ProductInfo(name: "Tomato soup", brand: "Made Up Kitchen", size: "10.6 oz",
                                  source: ProductLookup.usdaName,
                                  figures: FoodFigures(package: Amount(300, "g"), serving: Amount(120, "g"),
                                                       perServing: 90),
                                  figuresFrom: ProductLookup.usdaName)
    static let alcohol = ProductInfo(name: "Rubbing alcohol", brand: "Made Up Pharmacy", model: "RA-16",
                                     size: "16 fl oz", source: ProductLookup.goodsName)

    @Test func theFormLooksUpANewItemFromACodeAndNeverAnEditAgain() {
        #expect(QuickForm.looksUp(barcode: "0001", isNew: true, prefill: [:]))
        #expect(!QuickForm.looksUp(barcode: nil, isNew: true, prefill: [:]), "Add, typed in: no code to look up")
        #expect(!QuickForm.looksUp(barcode: "0001", isNew: false, prefill: [:]), "an edit")
        #expect(!QuickForm.looksUp(barcode: "0001", isNew: true, prefill: ["A": .text("Soup")]),
                "Edit again on a refused add opens with what was typed")
    }

    @Test func onlyQuickAddSkipsTheNameCheck() {
        #expect(QuickForm.nameProblem(quick: true, columnLabel: Inventory.Label.item, typed: " ", was: nil) == nil)
        #expect(QuickForm.nameProblem(quick: false, columnLabel: Inventory.Label.item, typed: " ", was: nil)
                == PhoneEditRules.nameProblem(columnLabel: Inventory.Label.item, typed: " ", was: nil))
        #expect(QuickForm.nameProblem(quick: false, columnLabel: Inventory.Label.item, typed: "", was: nil) != nil)
    }

    @Test func onlyQuickAddRefusesABlankQuantityInTheCardsWords() {
        #expect(QuickForm.quantityProblem(required: true, typed: "") == "Quantity: write a number, like 6 or 2.5.")
        #expect(QuickForm.quantityProblem(required: true, typed: "  ") == "Quantity: write a number, like 6 or 2.5.")
        #expect(QuickForm.quantityProblem(required: true, typed: "3") == nil)
        #expect(QuickForm.quantityProblem(required: false, typed: "") == nil)
    }

    /// Phase 2 review, M8: each form's button words, by value. Bought…'s keep its own form's words (9: no command
    /// renamed), Quick add's one Add, Add's Done beside Add Another; the top right says Save on an edit.
    @Test func theButtonsWordsByForm() {
        #expect(QuickForm.addWord(bought: true, quick: false) == "Add to the inventory")
        #expect(QuickForm.addWord(bought: false, quick: true) == "Add")
        #expect(QuickForm.addWord(bought: false, quick: false) == InventoryWords.doneAdding)
        #expect(QuickForm.confirmWord(isEdit: true, bought: false) == "Save")
        #expect(QuickForm.confirmWord(isEdit: false, bought: true) == "Add to the inventory")
        #expect(QuickForm.confirmWord(isEdit: false, bought: false) == "Add")
    }

    /// Phase 2 review, M4: Add 1 to it is offered only for an item kept in the place Quick add is scanning into, as the
    /// repeat scan adds 1 (`ItemMatch.inPlace`); with no place chosen, never.
    @Test func addOneOnlyForAnItemInThePlaceBeingScanned() {
        #expect(QuickForm.offersAddOne(itemPlace: 4, place: 4))
        #expect(!QuickForm.offersAddOne(itemPlace: 7, place: 4), "kept somewhere else")
        #expect(!QuickForm.offersAddOne(itemPlace: nil, place: 4), "kept nowhere")
        #expect(!QuickForm.offersAddOne(itemPlace: nil, place: 0) && !QuickForm.offersAddOne(itemPlace: 0, place: 0),
                "no place chosen")
    }

    /// Phase 2 review, M2: a code waiting for its name stops waiting once no item holds it and no waiting add does
    /// (refused and thrown away, taken back, deleted on the Mac), not only on Undo last.
    @Test func aCodeNoItemHoldsStopsWaitingForItsName() {
        let columns = [QuickFormSaveTests.column("A", "Item", "text")]
        let rows = [PhoneInventory.Row(id: 5, position: 1, values: [:]),
                    PhoneInventory.Row(id: 6, position: 2, values: ["A": .text("Zorvex Jar")]),
                    PhoneInventory.Row(id: -2, position: 3, values: [:])]
        let copy = PhoneInventory(writtenAt: "", columns: columns, items: rows, places: [], categories: [],
                                  headsUpDays: 60, toBuy: [], results: [:],
                                  barcodes: ["0001": 5, "0002": 6, "0003": -2, "0004": 9])
        #expect(QuickForm.nameWait("0001", in: copy, item: "A") == .unnamed(5))
        #expect(QuickForm.nameWait("0002", in: copy, item: "A") == .named)
        #expect(QuickForm.nameWait("0003", in: copy, item: "A") == .waiting, "its add is still on this phone")
        #expect(QuickForm.nameWait("0004", in: copy, item: "A") == .gone, "its item was deleted on the Mac")
        #expect(QuickForm.nameWait("0005", in: copy, item: "A") == .gone, "its add was thrown away")
    }

    @Test func aNamelessAddIsNamedLater() {
        #expect(QuickForm.shownName(" ") == "an item to name later")
        #expect(QuickForm.waitsForName(""))
        #expect(QuickForm.shownName("Soup") == "Soup")
        #expect(!QuickForm.waitsForName("Soup"))
    }

    @Test func aFoundProductFillsOnlyWhatIsStillBlank() {
        var fill = LookupFill()
        var fields = LookupFill.Fields(name: "My soup", unit: "each")
        fill.found(Self.soup, fields: &fields, categories: Self.categories, opened: 0)
        #expect(fields.name == "My soup", "typed while the lookup ran: kept")
        #expect(fields.brand == "Made Up Kitchen")
        #expect(fields.model == "", "nothing found for it")
        #expect(fill.heard == "From USDA. Change anything that's wrong.")
        #expect(!fill.looking)
        #expect(fill.figures != nil)

        var typed = LookupFill.Fields(brand: "Own brand", model: "X1", notes: "Top shelf", unit: "each")
        var goods = LookupFill()
        goods.found(Self.alcohol, fields: &typed, categories: Self.categories, opened: 0)
        #expect(typed.name == "Rubbing alcohol", "a name typed and cleared again is blank: filled, as the card did")
        #expect(typed.brand == "Own brand" && typed.model == "X1" && typed.notes == "Top shelf")
        #expect(goods.figures == nil && !goods.servingsShown && goods.offered == nil)

        var blank = LookupFill.Fields(unit: "each")
        LookupFill().found(Self.alcohol, into: &blank)
        #expect(blank.model == "RA-16")
        #expect(blank.notes == "16 fl oz", "the package size in Notes")
    }

    @Test func foodIsChosenWhenNoCategoryIsKeptAndAKeptFoodCategoryLeavesANonFood() {
        var fields = LookupFill.Fields(unit: "each")
        LookupFill().found(Self.soup, into: &fields)
        #expect(fields.category == 1, "Food, when nothing is kept and the lookup says food")

        var kept = LookupFill.Fields(unit: "each", category: 4)
        LookupFill().found(Self.soup, into: &kept)
        #expect(kept.category == 4, "a kept category stays on a food")

        var canned = LookupFill.Fields(unit: "each", category: 2)
        LookupFill().found(Self.alcohol, into: &canned)
        #expect(canned.category == 0, "a food category (by its group) kept from the last scan leaves rubbing alcohol")

        var water = LookupFill.Fields(unit: "each", category: 3)
        LookupFill().found(Self.alcohol, into: &water)
        #expect(water.category == 3, "a kept Water stays (spec 5.3: left as it is)")

        var none = LookupFill.Fields(unit: "each")
        var fill = LookupFill()
        fill.found(Self.soup, fields: &none, categories: [LookupFill.Category(id: 3, name: "Water", group: "Water")],
                   opened: 0)
        #expect(none.category == 0, "no Food category to choose")
    }

    /// Review of Task 2.4: a food category picked while "Looking it up…" shows is the person's, never taken off.
    @Test func aCategoryPickedWhileTheLookupRanStays() {
        var picked = LookupFill.Fields(unit: "each", category: 2)
        var fill = LookupFill()
        fill.found(Self.alcohol, fields: &picked, categories: Self.categories, opened: 0)
        #expect(picked.category == 2)
        var kept = LookupFill.Fields(unit: "each", category: 2)
        fill.found(Self.alcohol, fields: &kept, categories: Self.categories, opened: 2)
        #expect(kept.category == 0, "the one the form opened with, kept from the last scan: taken off")
    }

    /// Review of Task 2.4: a Quantity typed as 0 goes as 0 on any new item; a blank one, and other zeros, stay out.
    @Test func aTypedZeroQuantityIsKeptAndABlankOneIsNot() {
        let values: [String: SQLValue] = ["Q": .real(0), "L": .int(0), "C": .int(3), "N": .text(""), "U": .text("each")]
        #expect(QuickForm.newItemKept(values, quantity: ("Q", "0")) == ["Q": .real(0), "C": .int(3), "U": .text("each")])
        #expect(QuickForm.newItemKept(values, quantity: ("Q", " ")) == ["C": .int(3), "U": .text("each")],
                "a blank box stores as 0 too, and stays out")
        #expect(QuickForm.newItemKept(values, quantity: nil) == ["C": .int(3), "U": .text("each")])
        #expect(QuickForm.newItemKept(["Q": .real(6)], quantity: ("Q", "6")) == ["Q": .real(6)])
    }

    /// The card's swipe hold, restored (review of Task 2.4): a new item with a name, looked up or typed, is held.
    @Test func aNewItemWithANameHoldsTheSwipe() {
        #expect(QuickForm.holdsSwipe(changed: false, isNew: true, name: "Tomato soup"))
        #expect(!QuickForm.holdsSwipe(changed: false, isNew: true, name: " "))
        #expect(QuickForm.holdsSwipe(changed: true, isNew: true, name: ""))
        #expect(!QuickForm.holdsSwipe(changed: false, isNew: false, name: "Flashlight"), "an unchanged edit closes")
        #expect(QuickForm.holdsSwipe(changed: true, isNew: false, name: "Flashlight"))
    }

    /// Wiring only (the rules themselves are the tests above): the phone's item form calls them with its own state.
    /// Addition C (owner, 2026-11-18, in chat, after the review): Quick add's form goes to full height while the
    /// what's-missing line is amber; green or no line leaves it where it is (half height for a plain item).
    @Test func amberMeansTall() {
        #expect(QuickForm.opensTall(.missing(ItemNeeds.waterHolds)))
        #expect(!QuickForm.opensTall(.complete(ItemNeeds.complete("water", "6 gallons"))))
        #expect(!QuickForm.opensTall(nil), "a plain item: no line")
    }

    @Test func thePhoneFormCallsTheRules() throws {
        let form = try String(contentsOf: PaletteTests.repo.appendingPathComponent(
            "app/Kiwix/PrepareMeApp/PrepareMePhoneInventory.swift"), encoding: .utf8)
        for call in ["QuickForm.looksUp(barcode: barcode, isNew: row == nil, prefill: prefill)",
                     "QuickForm.holdsSwipe(changed: changed, isNew: row == nil && bought == nil,",
                     "lookup.found(info, fields: &fields,",
                     // Task 2.5: Bought… from its line, one memory
                     "QuickForm.boughtValues(bought,", "QuickForm.Memory.forAdd(place: lastPlace,",
                     "if row == nil, bought == nil, let same = alreadyThere",
                     "ItemForm(copy: copy, row: nil, bought: item)",
                     // phase 2 review, 12: Save sends what `QuickForm.sent` builds (its behavior: QuickFormSaveTests),
                     // with the id the form opened with (1), its memory written only as `remember` says (2), Quick
                     // add's run and Bought…'s line as the kind of new item
                     "let sent = QuickForm.sent(copy: copy, columns: columns, row: row, openedID: openedID,",
                     "openedValues: openedValues, was: base.map(texts), now: texts(now), new: new,",
                     "barcode: barcode, saving: &saving)", "openedID = row?.id",
                     ".quick(place: quick.place.wrappedValue, category: quick.category.wrappedValue)",
                     "} else if let bought { .bought(bought) } else { .add(editAgain: !prefill.isEmpty) }",
                     "if let place = remember.place { lastPlace = place }",
                     "if let category = remember.category { lastCategory = category }",
                     "if let unit = remember.unit { lastUnit = unit }",
                     "if namesLater { ProductLookupClient.shared.waitForName(barcode) }",
                     "@AppStorage(QuickForm.Memory.unitKey) private var lastUnit = QuickForm.Memory.quickUnit",
                     // 4: the step's rule; 9: Bought…'s own words on its buttons, Quick add's Add
                     "typed[column.colId] = PhoneEditRules.stepped(typed[column.colId] ?? \"\", by: by)",
                     "var addWord: String { QuickForm.addWord(bought: bought != nil, quick: quick != nil) }",
                     "Button(QuickForm.confirmWord(isEdit: row != nil, bought: bought != nil))",
                     // M5: the Mac's row, as the waiting add arrived, becomes the base; M6: a blank remembered unit reads
                     // as the default in Quick add's form too; M3: the line is announced as its state changes
                     ".onChange(of: row?.id) {", "QuickForm.arrived(openedID: openedID, openedValues: openedValues, row: row)",
                     "(\"Unit\", .text(QuickForm.Memory.startUnit(quick.unit.wrappedValue)))", ".announcesNeeds(needs)",
                     // the fix wave: Edit again as typed, a refused Bought… with its line, How many's fields as
                     // rows(), Quick add's title and keyboard Done, the line in the form at the largest sizes, no copy
                     "if QuickForm.fillsBlanks(isNew: row == nil, prefill: prefill) {",
                     "let again = refused.again(in: copy)", "onSaved: { model.forgetRefusal(refused.id) }, bought: again.bought)",
                     "rows(columns.filter { $0.colId != quantity?.colId && $0.colId != unit?.colId })",
                     "quick != nil ? \"Quick Add\"", "if quick != nil {  // the card's Done: only hides the keyboard",
                     "Button(\"Done\") { focus = nil }",
                     "if textSize.isAccessibilitySize, let needs {",
                     "let line = screenKeyboard || textSize.isAccessibilitySize ? nil : needs",
                     "NoCopyYet { buying = nil }"] {
            #expect(form.contains(call), "\(call)")
        }
        #expect(!form.contains("PhoneEditRules.nameProblem("), "the name check goes through QuickForm")
        #expect(form.components(separatedBy: "Button(addWord) { finish(reader) }").count == 3, "the bar and the keyboard's")
        for gone in ["lastPlace = Int(", "QuickForm.newItemKept(", "PhoneEditRules.cellChange("] {
            #expect(!form.contains(gone), "built in QuickForm.sent now: \(gone)")
        }
        #expect(!form.contains("struct PhoneBoughtForm"), "Bought… opens the item form (Task 2.5)")
        let quickAdd = try String(contentsOf: PaletteTests.repo.appendingPathComponent(
            "app/Kiwix/PrepareMeApp/PrepareMeQuickAdd.swift"), encoding: .utf8)
        #expect(quickAdd.contains("ItemForm(copy: copy, row: nil, barcode: found.code,"))
        // addition D: Add 1 to it in Quick add's form is the repeat scan's own 1 more (its log, its Undo last), never a
        // copy; addition C: the form's sheet grows when the line turns amber, and starts at half height for each item
        // M4: once only, and only for an item in the place being scanned into
        #expect(form.contains("if let quick, QuickForm.offersAddOne(itemPlace: copy.column(Inventory.Label.location)"))
        #expect(form.contains("Button(ItemMatch.addOne) { guard !saving else { return }; saving = true; quick.addOne(same) }"))
        #expect(form.contains(".onChange(of: QuickForm.opensTall(needs), initial: true) { _, tall in if tall { quick?.grow() } }"))
        for wiring in ["addOne: { row in", "card = nil  // the form closes", "plusOne(row.id, copy, row)",
                       ".presentationDetents([.medium, .large], selection: $height)", "onDismiss: { height = .medium }",
                       "grow: { height = .large }", ".background(SheetToFull(full: height == .large))"] {
            #expect(quickAdd.contains(wiring), "\(wiring)")
        }
        // addition A: a shortfall's Bought types its name first
        #expect(form.contains("if row == nil, barcode == nil, bought?.isListSentence ?? true { focusName() }"))
        #expect(quickAdd.contains("@AppStorage(QuickForm.Memory.unitKey) private var unit = QuickForm.Memory.quickUnit"))
        #expect(!quickAdd.contains("QuickItemCard"))
        // M2: a code no item holds stops waiting for its name in nameWaiting itself (by value above); Undo last still
        // drops it at once, so Quick add's footer needn't wait for the next look
        #expect(quickAdd.contains("switch QuickForm.nameWait(code, in: copy, item: item.colId) {"))
        #expect(quickAdd.contains("if model.item(forCode: code) == nil { lookups.drop(code) }"),
                "an add taken back stops waiting for its name (phase 2 review, 5)")
        let style = try String(contentsOf: PaletteTests.repo.appendingPathComponent(
            "app/Kiwix/PrepareMeApp/PrepareMeEntryStyle.swift"), encoding: .utf8)
        // M3: announced as its state changes (`ItemNeeds.announcement`), from the form, where its first showing is seen
        #expect(style.contains("if let words = ItemNeeds.announcement(from: old, to: new) {"))
        #expect(!style.contains(".onChange(of: words)"), "never on each keystroke")
        let mac = try String(contentsOf: PaletteTests.repo.appendingPathComponent(
            "app/Kiwix/PrepareMeApp/PrepareMeInventory.swift"), encoding: .utf8)
        #expect(mac.components(separatedBy: ".announcesNeeds(line)").count == 3, "the Mac's item form and New item")
        // I2: the Mac's Bought… starts a shortfall clean too, and M1: refuses its blank Quantity in the same words
        let toBuy = try String(contentsOf: PaletteTests.repo.appendingPathComponent(
            "app/Kiwix/PrepareMeApp/PrepareMeToBuy.swift"), encoding: .utf8)
        for wiring in ["name = item.isListSentence ? \"\" : item.text",
                       "quantity = item.isShortfall ? \"\" : item.need.map(InventoryValues.number) ?? \"\"",
                       "if let problem = QuickForm.quantityProblem(required: item.isShortfall, typed: quantity) {"] {
            #expect(toBuy.contains(wiring), "\(wiring)")
        }
        #expect(quickAdd.contains("NoCopyYet { card = nil }") && quickAdd.contains("show(NoCopyYet.line(model.problem))"))
        let scan = try String(contentsOf: PaletteTests.repo.appendingPathComponent(
            "app/Kiwix/PrepareMeApp/PrepareMeScan.swift"), encoding: .utf8)
        #expect(scan.contains("ItemForm(copy: copy, row: nil, barcode: code)"), "Scan's new item: looked up by looksUp")
        #expect(scan.contains("ProcessInfo.processInfo.environment[\"PREPAREME_CHECK_SCAN_CODE\"]")
                && scan.contains("#if targetEnvironment(simulator)"), "the simulator's code hook, never on a device")
    }

    @Test func theServingsBoxesFillCaloriesAndNotesUntilTypedOver() {
        var fill = LookupFill()
        var fields = LookupFill.Fields(unit: "each")
        fill.found(Self.soup, fields: &fields, categories: Self.categories, opened: 0)
        #expect(fill.servingsShown && fill.scannedFood)
        #expect(fill.perServing == "90" && fill.servings == "2.5")
        #expect(fields.calories == "225")
        #expect(fields.notes == "About 2.5 servings of 90 calories, from USDA", "the boxes' words over the size")
        #expect(fill.caloriesNote(calories: fields.calories, unit: fields.unit) == fields.notes)
        #expect(fill.offered == nil, "the boxes' figure, not the whole package's offer")

        fill.servings = "3"
        fill.servingsChanged(&fields)
        #expect(fields.calories == "270")
        #expect(fields.notes == "3 servings of 90 calories", "no source once a box is changed")

        fields.calories = "300"
        fields.notes = "Mine"
        fill.servings = "4"
        fill.servingsChanged(&fields)
        #expect(fields.calories == "300" && fields.notes == "Mine", "typed over: kept")
        #expect(fill.caloriesNote(calories: fields.calories, unit: fields.unit) == nil)
    }

    @Test func caloriesTypedBeforeTheAnswerKeepTheBoxesAway() {
        var fill = LookupFill()
        var fields = LookupFill.Fields(calories: "500", unit: "each")
        fill.found(Self.soup, fields: &fields, categories: Self.categories, opened: 0)
        #expect(!fill.servingsShown && fill.offered == nil)
        #expect(fields.calories == "500")
    }

    @Test func aUnitThatIsntAPackagesLeavesCaloriesBlankAndSaysWhy() {
        var fill = LookupFill()
        var fields = LookupFill.Fields(unit: "pounds")
        fill.found(Self.soup, fields: &fields, categories: Self.categories, opened: 0)
        #expect(fields.calories == "")
        #expect(fill.caloriesNote(calories: "", unit: "pounds") == ProductLookup.servingsNotFilled(225, unit: "pounds"))
        #expect(fill.unitChanged(calories: "", unit: "cans") == "225", "a package's unit: put in")
        #expect(fill.unitChanged(calories: "225", unit: "pounds") == "", "and out again")
        #expect(fill.unitChanged(calories: "180", unit: "pounds") == "180", "a typed figure stays")
        #expect(LookupFill().unitChanged(calories: "12", unit: "pounds") == "12", "nothing looked up: as typed")
    }

    @Test func aWholePackagesFigureWithNoServingIsOffered() {
        let rice = ProductInfo(name: "Rice", size: "1 kg", source: ProductLookup.foodName,
                               figures: FoodFigures(package: Amount(1000, "g"), per100: 360),
                               figuresFrom: ProductLookup.foodName)
        var fill = LookupFill()
        var fields = LookupFill.Fields(unit: "bags")
        fill.found(rice, fields: &fields, categories: Self.categories, opened: 0)
        #expect(fill.offered == LookupFill.Offer(value: "3600", calories: 3600, source: ProductLookup.foodName))
        #expect(fields.calories == "3600")
        #expect(fill.caloriesNote(calories: "3600", unit: "bags") == ProductLookup.caloriesOffer(3600, source: "Open Food Facts"))
        #expect(fields.notes == "1 kg")

        var pounds = LookupFill.Fields(unit: "pounds")
        var other = LookupFill()
        other.found(rice, fields: &pounds, categories: Self.categories, opened: 0)
        #expect(pounds.calories == "")
        #expect(other.caloriesNote(calories: "", unit: "pounds")
                == ProductLookup.caloriesNotFilled(3600, source: "Open Food Facts", unit: "pounds"))
    }

    @Test func notFoundAndLaterLeaveTheFieldsAsTyped() {
        var fill = LookupFill()
        fill.notFound()
        #expect(fill.heard == "Not found online: type its name." && !fill.looking)
        var quick = LookupFill()
        quick.later(quick: true)
        #expect(quick.heard == "Couldn't look it up now. Add it anyway and it's named later by itself, or type its name.")
        var scan = LookupFill()
        scan.later(quick: false)
        #expect(scan.heard == "Couldn't look it up now. Type its name, or cancel and scan it again later.",
                "Scan's form asks for a name, and nothing tries the code again by itself (item 15)")
        #expect(!scan.looking && scan.figures == nil && !scan.scannedFood)
    }
}

/// Phase 2 review, 12 (and 1, 2 and 4): what the phone's item form sends on Save or Add (`QuickForm.sent`), by
/// behavior. Made-up items and ids only.
struct QuickFormSaveTests {
    static func column(_ colId: String, _ label: String, _ kind: String, target: String? = nil) -> PhoneInventory.Column {
        PhoneInventory.Column(colId: colId, label: label, kind: kind, target: target, choices: [], editable: true)
    }
    static let columns = [column("A", "Item", "text"), column("Q", "Quantity", "numeric"), column("U", "Unit", "text"),
                          column("L", "Location", "reference", target: "Locations"),
                          column("C", "Category", "reference", target: "Categories"), column("N", "Notes", "text"),
                          column("E", Inventory.Label.emptyUntilNeeded, "bool"),
                          column("K", Inventory.Label.keepPastDate, "bool")]
    static func copy(_ items: [PhoneInventory.Row] = []) -> PhoneInventory {
        PhoneInventory(writtenAt: "", columns: columns, items: items, places: [], categories: [], headsUpDays: 60,
                       toBuy: [], results: [:])
    }
    /// The form's texts: every column blank, a reference's "0", then `typed` over them.
    static func texts(_ typed: [String: String] = [:]) -> [String: String] {
        ["A": "", "Q": "", "U": "", "L": "0", "C": "0", "N": "", "E": "", "K": ""].merging(typed) { $1 }
    }
    static let lamp = PhoneInventory.Row(id: 5, position: 1, values: ["A": .text("Zorvex Lamp"), "Q": .real(2),
                                                                     "N": .text(""), "E": .int(0), "K": .int(1)])
    static let lampShown = texts(["A": "Zorvex Lamp", "Q": "2", "K": "Yes"])

    func sent(_ items: [PhoneInventory.Row] = [], row: PhoneInventory.Row? = nil, openedID: Int64? = nil,
              openedValues: [String: SQLValue]? = nil, was: [String: String]? = nil, now: [String: String],
              new: QuickForm.NewItem = .add(editAgain: false), barcode: String? = nil) -> QuickForm.Sent {
        var saving = false
        return QuickForm.sent(copy: Self.copy(items), columns: Self.columns, row: row, openedID: openedID ?? row?.id,
                              openedValues: openedValues ?? row?.values, was: was, now: now, new: new,
                              barcode: barcode, saving: &saving)
    }

    @Test func anEditSendsOnlyTheFieldsChanged() {
        let lamp = Self.lamp
        #expect(sent([lamp], row: lamp, was: Self.lampShown, now: Self.lampShown) == .cells([]), "nothing changed")
        #expect(sent([lamp], row: lamp, was: Self.lampShown, now: Self.lampShown.merging(["N": "Top shelf"]) { $1 })
                == .cells([QuickForm.Cell(change: .revert(table: "Inventory", row: 5, colId: "N", value: .text("Top shelf"),
                                                          expected: .text("")), what: "Zorvex Lamp: Notes")]))
    }

    @Test func theTwoSwitchesGoAsOneOrZeroOnlyWhenChanged() {
        let lamp = Self.lamp
        let on = sent([lamp], row: lamp, was: Self.lampShown, now: Self.lampShown.merging(["E": "Yes", "K": ""]) { $1 })
        #expect(on == .cells([
            QuickForm.Cell(change: .revert(table: "Inventory", row: 5, colId: "E", value: .int(1), expected: .int(0)),
                           what: "Zorvex Lamp: \(Inventory.Label.emptyUntilNeeded)"),
            QuickForm.Cell(change: .revert(table: "Inventory", row: 5, colId: "K", value: .int(0), expected: .int(1)),
                           what: "Zorvex Lamp: \(Inventory.Label.keepPastDate)")]))
        // a switch left alone is never sent, whatever the Mac stores for off (a blank cell here)
        let blank = PhoneInventory.Row(id: 6, position: 2, values: ["A": .text("Zorvex Rope")])
        let shown = Self.texts(["A": "Zorvex Rope"])
        #expect(sent([blank], row: blank, was: shown, now: shown.merging(["N": "Coil"]) { $1 })
                == .cells([QuickForm.Cell(change: .revert(table: "Inventory", row: 6, colId: "N", value: .text("Coil"),
                                                          expected: .null), what: "Zorvex Rope: Notes")]))
    }

    /// Review finding 1: Edit opened on a waiting add (its id below 0); the add reached the Mac, so the row now has its
    /// real id and the Mac's values. A blank the add never had is the Mac's blank text, so `expected` is the Mac's row;
    /// an edit opened on a real row still says what it opened with (8adf477c's stale-edit protection).
    @Test func anEditOpenedOnAWaitingAddSaysTheMacsRowOnceItHasItsRealID() {
        let waiting: [String: SQLValue] = ["A": .text("Zorvex Jar")]
        let applied = PhoneInventory.Row(id: 9, position: 3, values: ["A": .text("Zorvex Jar"), "N": .text("")])
        let shown = Self.texts(["A": "Zorvex Jar"])
        let named = shown.merging(["N": "Top shelf"]) { $1 }
        #expect(sent([applied], row: applied, openedID: -3, openedValues: waiting, was: shown, now: named)
                == .cells([QuickForm.Cell(change: .revert(table: "Inventory", row: 9, colId: "N", value: .text("Top shelf"),
                                                          expected: .text("")), what: "Zorvex Jar: Notes")]))
        // opened on the real row, and the Mac changed Notes before Save: still what the form opened with, so refused
        let stale = PhoneInventory.Row(id: 9, position: 3, values: ["A": .text("Zorvex Jar"), "N": .text("Shelf 2")])
        #expect(sent([stale], row: stale, openedID: 9, openedValues: applied.values, was: shown, now: named)
                == .cells([QuickForm.Cell(change: .revert(table: "Inventory", row: 9, colId: "N", value: .text("Top shelf"),
                                                          expected: .text("")), what: "Zorvex Jar: Notes")]))
        // still waiting: the add itself, as now typed
        let still = PhoneInventory.Row(id: -3, position: 3, values: waiting)
        #expect(sent([still], row: still, openedID: -3, openedValues: waiting, was: shown, now: named)
                == .waitingAdd(id: -3, values: ["A": .text("Zorvex Jar"), "N": .text("Top shelf")]))
    }

    @Test func boughtGoesAsItsItemAndTickInOneChange() {
        let line = ToBuyList.Item(id: "tb-1", text: "Water jugs", why: "", need: 3, unit: "gallons", category: nil,
                                  horizon: nil, lifeSafety: false, cost: nil)
        let result = sent(now: Self.texts(["A": "Water jugs", "Q": "3", "U": "gallons", "L": "4"]), new: .bought(line))
        guard case .new(.bought(let values, let tick), let what, _, let remember, let later) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(values == ["A": .text("Water jugs"), "Q": .real(3), "U": .text("gallons"), "L": .int(4)])
        #expect(tick.kind == .bought && tick.item == "tb-1" && what == "Bought Water jugs" && !later)
        #expect(remember == nil, "never the memory: a water line's gallons would become the next scan's unit")
    }

    /// Addition A: a shortfall line's Bought starts with no name, and a blank name is refused as on any Add.
    @Test func aShortfallsBoughtWithNoNameIsRefused() {
        let line = ToBuyList.Item(id: "S-G-water-n1", text: "Water: 1.3 of 30 days; 126 gallons short", why: "",
                                  need: 126, unit: "gallons", category: nil, horizon: nil, lifeSafety: true, cost: nil)
        guard case .problems(let found) = sent(now: Self.texts(["U": "gallons", "Q": "12"]), new: .bought(line)) else {
            Issue.record("a nameless Bought went")
            return
        }
        #expect(found["A"] != nil)
    }

    /// Phase 2 review, M1: a shortfall's Bought refuses a blank Quantity, in Quick add's words: its tick takes the line
    /// off To Buy, and an item with no Quantity counts nothing. Another line's Bought still goes without one.
    @Test func aShortfallsBoughtWithNoQuantityIsRefused() {
        let shortfall = ToBuyList.Item(id: "S-G-water-n1", text: "Water: 1.3 of 30 days; 126 gallons short", why: "",
                                       need: 126, unit: "gallons", category: nil, horizon: nil, lifeSafety: true, cost: nil)
        #expect(sent(now: Self.texts(["A": "Water jugs", "U": "gallons"]), new: .bought(shortfall))
                == .problems(["Q": "Quantity: write a number, like 6 or 2.5."]))
        let own = ToBuyList.Item(id: "tb-1", text: "Water jugs", why: "", need: 3, unit: "gallons", category: nil,
                                 horizon: nil, lifeSafety: false, cost: nil)
        guard case .new = sent(now: Self.texts(["A": "Water jugs", "U": "gallons"]), new: .bought(own)) else {
            Issue.record("a line of the owner's own went with no Quantity before")
            return
        }
    }

    /// Phase 2 review, M5: once a waiting add the form opened on reaches the Mac, the Mac's row then is the base, so a
    /// cell the Mac changes after that, while the form is still open, is refused, never overwritten.
    @Test func theMacsRowAsTheAddArrivedIsTheBase() {
        let waiting: [String: SQLValue] = ["A": .text("Zorvex Jar")]
        let applied = PhoneInventory.Row(id: 9, position: 3, values: ["A": .text("Zorvex Jar"), "N": .text("")])
        let base = QuickForm.arrived(openedID: -3, openedValues: waiting, row: applied)
        #expect(base.id == 9 && base.values == applied.values)
        let later = PhoneInventory.Row(id: 9, position: 3, values: ["A": .text("Zorvex Jar"), "N": .text("Shelf 2")])
        let shown = Self.texts(["A": "Zorvex Jar"])
        #expect(sent([later], row: later, openedID: base.id, openedValues: base.values, was: shown,
                     now: shown.merging(["N": "Top shelf"]) { $1 })
                == .cells([QuickForm.Cell(change: .revert(table: "Inventory", row: 9, colId: "N", value: .text("Top shelf"),
                                                          expected: .text("")), what: "Zorvex Jar: Notes")]),
                "the Mac's Shelf 2 came after: refused there")
        let still = QuickForm.arrived(openedID: -3, openedValues: waiting, row: PhoneInventory.Row(id: -3, position: 3,
                                                                                                    values: waiting))
        #expect(still.id == -3 && still.values == waiting, "not there yet")
        let real = QuickForm.arrived(openedID: 9, openedValues: applied.values, row: later)
        #expect(real.id == 9 && real.values == applied.values, "opened on a real row: what it opened with, always")
    }

    /// Phase 2 review, round 2, 1: the Mac (or another phone) changed a cell the add carried before this phone's copy
    /// caught up. The add's own cells stay the base, so Save of that field is refused there, never written over the
    /// Mac's change; only the cells the add left out (null or missing) take the Mac's row, so filling one is kept.
    /// Both through `arrived()` and through Save's fallback when the form's base hasn't moved yet.
    @Test func theAddsOwnCellsStayTheBaseOnceItArrives() {
        let waiting: [String: SQLValue] = ["A": .text("Zorvex Jar"), "Q": .real(2), "U": .null]
        let caught = PhoneInventory.Row(id: 9, position: 3, values: ["A": .text("Zorvex Crock"), "Q": .real(2),
                                                                     "U": .text(""), "N": .text("")])
        let base = QuickForm.arrived(openedID: -3, openedValues: waiting, row: caught)
        #expect(base.id == 9 && base.values == ["A": .text("Zorvex Jar"), "Q": .real(2), "U": .text(""), "N": .text("")],
                "the add's name and Quantity; the Mac's blanks for Unit (null in the add) and Notes (not in it)")
        let shown = Self.texts(["A": "Zorvex Jar", "Q": "2"])
        let filled = QuickForm.Sent.cells([QuickForm.Cell(change: .revert(table: "Inventory", row: 9, colId: "N",
                                                                          value: .text("Top shelf"), expected: .text("")),
                                                          what: "Zorvex Crock: Notes")])
        let renamed = QuickForm.Sent.cells([QuickForm.Cell(change: .revert(table: "Inventory", row: 9, colId: "A",
                                                                           value: .text("Zorvex Jar, big"),
                                                                           expected: .text("Zorvex Jar")),
                                                           what: "Zorvex Crock: Item")])
        for (id, values) in [(base.id, base.values), (Int64(-3), waiting)] {  // arrived; Save's own fallback
            #expect(sent([caught], row: caught, openedID: id, openedValues: values, was: shown,
                         now: shown.merging(["N": "Top shelf"]) { $1 }) == filled, "a blank filled: kept there")
            #expect(sent([caught], row: caught, openedID: id, openedValues: values, was: shown,
                         now: shown.merging(["A": "Zorvex Jar, big"]) { $1 }) == renamed,
                    "the add's name, renamed on the Mac since: refused there, never the Mac's Crock as the base")
        }
    }

    @Test func quickAddTakesItsPlaceAndCategoryFromTheRun() {
        let result = sent(now: Self.texts(["Q": "1", "U": "each", "L": "4", "C": "2"]), new: .quick(place: 7, category: 0),
                          barcode: "0001")
        #expect(result == .new(change: .addItem(values: ["Q": .real(1), "U": .text("each"), "L": .int(7)], barcode: "0001"),
                               what: "Added an item to name later, with its barcode", name: "an item to name later",
                               remember: nil, namesLater: true),
                "the run's place read live, its category of none left out, the nameless code named later")
        #expect(sent(now: Self.texts(["U": "each"]), new: .quick(place: 7, category: 0), barcode: "0001")
                == .problems(["Q": "Quantity: write a number, like 6 or 2.5."]), "a blank Quantity, in the card's words")
    }

    /// Review finding 2: Add and Scan's new item remember only a place, category or unit picked or typed; Edit again
    /// never writes the memory.
    @Test func onlyWhatWasPickedOrTypedIsRemembered() {
        func remembered(_ result: QuickForm.Sent) -> QuickForm.Memory.Write?? {
            if case .new(_, _, _, let remember, _) = result { return .some(remember) }
            return nil
        }
        let blank = sent(now: Self.texts(["A": "Zorvex Rope", "Q": "1"]))
        #expect(remembered(blank) == .some(QuickForm.Memory.Write(place: 0, category: 0, unit: " ")))
        let none = QuickForm.Memory.Write(place: 0, category: 0, unit: " ")
        #expect(none.place == nil && none.category == nil && none.unit == nil, "no place, no category, a blank Unit")
        let picked = sent(now: Self.texts(["A": "Zorvex Rope", "Q": "1", "L": "4", "U": "coils"]), barcode: "0002")
        guard case .new(let change, _, _, let remember, let later) = picked else { Issue.record("\(picked)"); return }
        #expect(change == .addItem(values: ["A": .text("Zorvex Rope"), "Q": .real(1), "L": .int(4), "U": .text("coils")],
                                   barcode: "0002"), "Scan's new item")
        #expect(remember?.place == 4 && remember?.category == nil && remember?.unit == "coils" && !later)
        #expect(remembered(sent(now: Self.texts(["A": "Zorvex Rope", "L": "4", "U": "coils"]), new: .add(editAgain: true)))
                == .some(nil), "Edit again on a refused add")
    }

    @Test func aSecondTapSendsNothing() {
        var saving = false
        func save() -> QuickForm.Sent {
            QuickForm.sent(copy: Self.copy(), columns: Self.columns, row: nil, openedID: nil, openedValues: nil, was: nil,
                           now: Self.texts(["A": "Zorvex Rope", "Q": "1"]), new: .add(editAgain: false), barcode: nil,
                           saving: &saving)
        }
        guard case .new = save() else { Issue.record("the first tap adds"); return }
        #expect(save() == .busy && saving)
        var problem = false
        _ = QuickForm.sent(copy: Self.copy(), columns: Self.columns, row: nil, openedID: nil, openedValues: nil, was: nil,
                           now: Self.texts(["Q": "1"]), new: .add(editAgain: false), barcode: nil, saving: &problem)
        #expect(!problem, "a problem shown sends nothing, so the next tap is free")
    }

    @Test func aNewItemWithNothingTypedSendsNothingAndANamelessAddIsStopped() {
        #expect(sent(now: Self.texts(["A": "Zorvex Rope"]).merging(["A": ""]) { $1 }) == .problems(
            ["A": PhoneEditRules.nameProblem(columnLabel: "Item", typed: "", was: nil)!]))
        let columns = [Self.column("N", "Notes", "text")]
        var saving = false
        #expect(QuickForm.sent(copy: Self.copy(), columns: columns, row: nil, openedID: nil, openedValues: nil, was: nil,
                               now: ["N": ""], new: .add(editAgain: false), barcode: nil, saving: &saving) == .nothing)
    }

    /// Review finding 4: − and + stop at 0 and at 10,000, as Quick add's card did; a figure already over 10,000 (a
    /// food counted in calories) is never pulled down to it (phase 2 review, I1): − takes 1 off, + leaves it.
    @Test func theStepStaysBetweenZeroAndTenThousand() {
        #expect(PhoneEditRules.stepped("9999.5", by: 1) == "10000")
        #expect(PhoneEditRules.stepped("10000", by: 1) == "10000")
        #expect(PhoneEditRules.stepped("12000", by: -1) == "11999", "a typed figure over it steps down by 1")
        #expect(PhoneEditRules.stepped("12000", by: 1) == "12000", "and doesn't go up")
        #expect(PhoneEditRules.stepped("0", by: -1) == "0")
        #expect(PhoneEditRules.stepped("", by: 1) == "1" && PhoneEditRules.stepped("lots", by: 1) == "1")
        #expect(PhoneEditRules.stepped("2.5", by: 1) == "3.5")
    }
}

private extension LookupFill {
    func found(_ info: ProductInfo, into fields: inout Fields) {
        var fill = self
        fill.found(info, fields: &fields, categories: QuickFormTests.categories, opened: fields.category)
    }
}
