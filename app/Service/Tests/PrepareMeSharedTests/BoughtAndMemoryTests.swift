import Foundation
import Testing
@testable import PrepareMeShared

/// Task 2.5 (inventory fresh look, spec 5.3): To Buy's Bought… opens the phone's item form filled in from its line, and
/// Quick add and Add share one memory of the last place, category and unit. Made-up lines and categories only.
struct BoughtAndMemoryTests {
    static let categories = [PhoneInventory.Category(id: 7, name: "Drinks", group: "Water"),
                             PhoneInventory.Category(id: 8, name: "Water", group: "Water"),
                             PhoneInventory.Category(id: 9, name: "First aid", group: nil)]
    static let columns = ["Item": "A", "Quantity": "Q", "Unit": "U", "Category": "C", "Location": "L"]

    static func line(need: Double?, unit: String = "gallons", group: String? = "Water") -> ToBuyList.Item {
        ToBuyList.Item(id: "tb-1", text: "Water jugs", why: "", need: need, unit: unit, category: group, horizon: nil,
                       lifeSafety: false, cost: nil)
    }

    @Test func boughtStartsFromItsLine() {
        let values = QuickForm.boughtValues(Self.line(need: 3), colId: { Self.columns[$0] }, categories: Self.categories)
        #expect(values == ["A": .text("Water jugs"), "Q": .real(3), "U": .text("gallons"), "C": .int(7)],
                "the name, what it still needs, its unit and the first category in its group; no place")
        #expect(InventoryValues.plain(values["Q"]!) == "3", "shown as the line shows it")
    }

    @Test func boughtLeavesOutWhatTheLineDoesntHave() {
        let none = QuickForm.boughtValues(Self.line(need: nil, group: nil), colId: { Self.columns[$0] },
                                          categories: Self.categories)
        #expect(none["Q"] == nil, "no need: the form's own 1")
        #expect(none["C"] == nil, "no group never matches a category with none")
        let other = QuickForm.boughtValues(Self.line(need: 1, group: "Pets"), colId: { Self.columns[$0] },
                                           categories: Self.categories)
        #expect(other["C"] == nil, "no category in that group")
        let bare = QuickForm.boughtValues(Self.line(need: 2), colId: { $0 == "Item" ? "A" : nil },
                                          categories: Self.categories)
        #expect(bare == ["A": .text("Water jugs")], "a copy without the column gets nothing for it")
    }

    /// Addition A (owner, 2026-11-18, in chat, after the review): a supply-shortfall line, told by its ID (S-…, the
    /// lists job's own form for one), starts with Name and Quantity blank, so its Add never records water never bought;
    /// its unit and category stay. A line naming a thing to buy (the owner's O-…, a review's P-…) opens as before; an
    /// expiry's E-… is the list's sentence too (round 2, 2: `anExpiryLineStartsWithNoName`).
    @Test func aShortfallLineStartsClean() {
        let water = ToBuyList.Item(id: "S-G-water-n1", text: "Water: 1.3 of 30 days; 126 gallons short", why: "",
                                   need: 126, unit: "gallons", category: "Water", horizon: nil, lifeSafety: true,
                                   cost: nil)
        #expect(water.isShortfall)
        #expect(QuickForm.boughtValues(water, colId: { Self.columns[$0] }, categories: Self.categories)
                == ["A": .text(""), "Q": .text(""), "U": .text("gallons"), "C": .int(7)],
                "blank, never the list's sentence or the form's 1")
        for id in ["O-12", "P-3", "tb-1"] {
            let own = ToBuyList.Item(id: id, text: "Water jugs", why: "", need: 3, unit: "gallons", category: "Water",
                                     horizon: nil, lifeSafety: false, cost: nil)
            #expect(!own.isShortfall && !own.isListSentence, "\(id)")
            #expect(QuickForm.boughtValues(own, colId: { Self.columns[$0] }, categories: Self.categories)["A"]
                    == .text("Water jugs"), "\(id)")
        }
    }

    /// Phase 2 review, round 2, 2: an expiry line (E-…, readiness/propose.py `_expiring`) is the list's sentence
    /// ("Replace or use up: … (expires …)") and carries no item name as data (its ID is a hash, its why another
    /// sentence), so Bought starts with Name blank, never the sentence or words cut out of it; Quantity, unit and
    /// category as before (no need: the form's own 1).
    @Test func anExpiryLineStartsWithNoName() {
        #expect(ToBuyList.Item(id: "S-G-water-n1", text: "", why: "", need: nil, unit: "", category: nil, horizon: nil,
                               lifeSafety: false, cost: nil).isListSentence)
        let rice = ToBuyList.Item(id: "E-abcdefghij", text: "Replace or use up: Zorvex rice (expires Dec 1, 2026)",
                                  why: "From Inventory row 4; the heads-up is 60 days.", need: nil, unit: "",
                                  category: "Food", horizon: nil, lifeSafety: false, cost: nil)
        #expect(rice.isListSentence && !rice.isShortfall, "its Quantity isn't a shortfall's")
        let food = [PhoneInventory.Category(id: 3, name: "Pantry", group: "Food")]
        #expect(QuickForm.boughtValues(rice, colId: { Self.columns[$0] }, categories: food)
                == ["A": .text(""), "U": .text(""), "C": .int(3)], "no name; no need, so the form's 1; its category")
        let jugs = ToBuyList.Item(id: "E-ponmlkjihg", text: "Zorvex jugs expired Nov 1, 2026; it isn't counted",
                                  why: "", need: 2, unit: "gallons", category: "Water", horizon: nil, lifeSafety: false,
                                  cost: nil)
        #expect(QuickForm.boughtValues(jugs, colId: { Self.columns[$0] }, categories: Self.categories)
                == ["A": .text(""), "Q": .real(2), "U": .text("gallons"), "C": .int(7)], "a need it has: kept")
    }

    @Test func addStartsFromTheMemoryWithAGonePlaceOrCategoryForgotten() {
        let memory = QuickForm.Memory(place: 4, category: 8, unit: "cans")
        #expect(QuickForm.Memory.forAdd(place: 4, category: 8, unit: "cans", places: [4, 5], categories: [7, 8]) == memory)
        #expect(QuickForm.Memory.forAdd(place: 4, category: 8, unit: "cans", places: [5], categories: [7])
                == QuickForm.Memory(place: 0, category: 0, unit: "cans"), "the Mac removed both since")
        #expect(memory.forgettingGone(places: [], categories: [8]) == QuickForm.Memory(place: 0, category: 8, unit: "cans"))
    }

    /// Phase 2 review, M6: a blank Unit an earlier build stored reads as the default, in Add and in Quick add alike, so
    /// that phone's next scan doesn't start blank (blanks are no longer written, so nothing else would clear it).
    @Test func aBlankRememberedUnitReadsAsTheDefault() {
        #expect(QuickForm.Memory.forAdd(place: 0, category: 0, unit: "", places: [4], categories: [8])
                == QuickForm.Memory(place: 0, category: 0, unit: "each"))
        #expect(QuickForm.Memory.startUnit(" ") == "each" && QuickForm.Memory.startUnit("") == "each")
        #expect(QuickForm.Memory.startUnit("cans") == "cans")
    }

    /// With nothing remembered, Add and Quick add start alike (phase 2 review, 2): one default for the one setting,
    /// Quick add's "each", which the app declares as each @AppStorage's default and Add reads through `forAdd`.
    @Test func nothingRememberedStartsAtOneDefault() {
        #expect(QuickForm.Memory.quickUnit == "each")
        #expect(QuickForm.Memory.forAdd(place: 0, category: 0, unit: QuickForm.Memory.quickUnit, places: [4],
                                        categories: [8]) == QuickForm.Memory(place: 0, category: 0, unit: "each"))
    }

    /// One memory: Quick add and Add read and write the same three settings, Quick add's names since 2026-10-23.
    @Test func theMemoryKeepsQuickAddsSettings() {
        #expect([QuickForm.Memory.placeKey, QuickForm.Memory.categoryKey, QuickForm.Memory.unitKey]
                == ["PrepareMe.quickPlace", "PrepareMe.quickCategory", "PrepareMe.quickUnit"])
    }

    /// Carried from Task 2.4's review: editing a waiting add keeps a Quantity changed to 0, as a new item's add does.
    @Test func editingAWaitingAddKeepsATypedZeroQuantity() {
        let add: [String: SQLValue] = ["A": .text("Rice"), "Q": .int(4), "U": .text("bags"), "C": .int(0)]
        #expect(QuickForm.waitingAddKept(add, changed: ["Q": .int(0)], quantity: ("Q", "0"))
                == ["A": .text("Rice"), "Q": .int(0), "U": .text("bags"), "C": .int(0)],
                "the 0 typed is kept; a 0 the add already had stays")
        #expect(QuickForm.waitingAddKept(add, changed: ["Q": .real(0)], quantity: ("Q", ""))
                == ["A": .text("Rice"), "U": .text("bags"), "C": .int(0)], "a Quantity blanked leaves")
        #expect(QuickForm.waitingAddKept(add, changed: ["U": .text(""), "A": .text("Brown rice")], quantity: ("Q", "4"))
                == ["A": .text("Brown rice"), "Q": .int(4), "C": .int(0)], "a cell changed to blank leaves")
    }

    /// Fix wave: "Edit again" on a refused add shows exactly what was typed; only a fresh new item starts filled in.
    @Test func editAgainNeverFillsBlanks() {
        #expect(QuickForm.fillsBlanks(isNew: true, prefill: [:]))
        #expect(!QuickForm.fillsBlanks(isNew: true, prefill: ["A": .text("Rice")]), "Edit again")
        #expect(!QuickForm.fillsBlanks(isNew: false, prefill: [:]), "an edit")
    }

    /// Fix wave (M1): a refused Bought… opens again with what was typed and its To Buy line, so Add still ticks it in
    /// one `.bought`; with the line gone from To Buy, as a plain add.
    @Test func aRefusedBoughtOpensAgainWithItsLine() throws {
        let line = Self.line(need: 3)
        func copy(_ toBuy: [ToBuyList.Item]) -> PhoneInventory {
            PhoneInventory(writtenAt: "", columns: [], items: [], places: [], categories: [], headsUpDays: 60,
                           toBuy: toBuy, results: [:])
        }
        let values: [String: SQLValue] = ["A": .text("Water jugs"), "Q": .int(2), "N": .text("By the door")]
        let refused = PhoneOutbox.Refusal(id: "e1", what: "Bought Water jugs", message: "No.", edit: PhoneEdit(
            change: .bought(values: values, tick: ToBuyTick(kind: .bought, item: line.id))))
        let again = try #require(refused.again(in: copy([line])))
        #expect(again.row == nil && again.barcode == nil)
        #expect(again.values == values, "what was typed, every field")
        #expect(again.bought == line)
        let gone = try #require(refused.again(in: copy([])))
        #expect(gone.bought == nil && gone.values == values, "the line left To Buy: a plain add")
        let add = PhoneOutbox.Refusal(id: "e2", what: "Added Rice", message: "No.",
                                      edit: PhoneEdit(change: .add(table: "Inventory", values: values)))
        #expect(try #require(add.again(in: copy([line]))).bought == nil)
        let used = PhoneOutbox.Refusal(id: "e3", what: "Used 1", message: "No.", edit: PhoneEdit(change: .adjust(row: 4, by: -1)))
        #expect(used.again(in: copy([line])) == nil)
    }

    /// Fix wave (M3): a Bought… item still on this phone is edited in place like any waiting add, its tick kept.
    @Test func aWaitingBoughtCanBeEdited() throws {
        var outbox = PhoneOutbox()
        let tick = ToBuyTick(kind: .bought, item: "tb-1")
        let id = outbox.add(.bought(values: ["A": .text("Water jugs"), "Q": .int(3)], tick: tick), what: "Bought")
        let waiting = PhoneOutbox.temporaryID(id)
        #expect(outbox.waitingAdd(waiting) != nil)
        #expect(outbox.changeWaitingAdd(waiting) { $0.merging(["Q": .int(4)]) { $1 } })
        #expect(outbox.pending.count == 1 && outbox.pending.first?.id == id)
        #expect(outbox.pending.first?.edit.change == .bought(values: ["A": .text("Water jugs"), "Q": .int(4)], tick: tick))
        outbox.markSent([id])
        #expect(!outbox.changeWaitingAdd(waiting) { $0 }, "a send began: the Mac may have it")
    }
}
