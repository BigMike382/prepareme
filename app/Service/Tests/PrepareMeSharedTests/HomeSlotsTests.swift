import Foundation
import Testing
@testable import PrepareMeShared

/// What fills an Our Home page's slots (Our Home plan, Task 2.4; the Review focus's first two conditions): made-up
/// items and the made-up rehearsal copy only.
@MainActor
struct HomeSlotsTests {
    let items: [(name: String, place: String, manual: String)] = [
        ("SAMPLE Lantern", "SAMPLE Garage › SAMPLE Shelf", "zim://m/item-3.pdf"),
        ("SAMPLE pipe wrench", "SAMPLE Pegboard", ""),
        ("SAMPLE camp lantern, \"big\" <one>\nnew", "SAMPLE Hall", ""),
    ]

    @Test func nothingToShowLeavesTheFallbackWords() {
        let script = HomeSlots.script(meet: [], kept: [:])
        #expect(script.contains("})([], {}, "), "no values: every slot keeps its fallback words")
        #expect(HomeSlots.kept(words: ["sample flashlight"], in: items) == [])
        #expect(HomeSlots.kept(words: ["sample lantern"], in: []) == [])
    }

    @Test func severalMatchesComeInTheListsOrder() {
        let found = HomeSlots.kept(words: ["lantern"], in: items)
        #expect(found.map(\.name) == ["SAMPLE Lantern", "SAMPLE camp lantern, \"big\" <one>\nnew"])
        #expect(found[0] == .init(name: "SAMPLE Lantern", place: "SAMPLE Garage › SAMPLE Shelf",
                                  manual: "zim://m/item-3.pdf"))
        #expect(HomeSlots.kept(words: ["pipe wrench", "lantern"], in: items).count == 3)
    }

    @Test func valuesAreEscapedAndOnlyEverText() {
        let script = HomeSlots.script(meet: ["SAMPLE park \u{2028}</script>"],
                                      kept: ["lantern": HomeSlots.kept(words: ["lantern"], in: items)])
        #expect(!script.contains("<one>") && !script.contains("</script>") && !script.contains("\u{2028}"))
        #expect(script.contains("\\\"big\\\" \\u003cone>\\nnew"), "quote, < and line break escaped")
        #expect(!script.contains("innerHTML"), "every value reaches the page as textContent")
        #expect(script.contains(#""manual":"Read the manual""#))
    }

    /// The Mac's values come from the phones' copy: a Mac-only item that matches a slot's words never reaches it
    /// (proving.md, "What phase 2 should change", 2.4 point 2). The rehearsal copy's "Indoor propane heater" is
    /// Mac only; its "Dual fuel generator" isn't.
    @Test func aMacOnlyItemNeverReachesASlot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-slots-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        let editor = try InventoryEditor(file: try InventoryFile(url: url), checker: FakeCheck())
        #expect(editor.inventory.itemRows.contains { editor.inventory.isPrivate($0) }, "the fixture still has one")
        let copy = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
        let found = HomeSlots.items(copy)
        #expect(HomeSlots.kept(words: ["propane heater"], in: found) == [])
        #expect(HomeSlots.kept(words: ["generator"], in: found).map(\.name) == ["Dual fuel generator"])
        #expect(HomeSlots.meet(copy).allSatisfy { !$0.isEmpty })
    }

    // MARK: the editor's picked places, manuals and things (docs/plans/2026-11-20-our-home-editor.md, Task 2)

    /// A made-up phones' copy: places Garage › Utility shelf and Garage › Tool chest, and Basement; items with and
    /// without a manual. HomePickTests uses it too.
    static func copy(places: [PhoneInventory.Place]? = nil, items: [(Int64, String, Int64, String?)]? = nil) -> PhoneInventory {
        let columns = [PhoneInventory.Column(colId: "Item", label: "Item", kind: "text", target: nil, choices: [], editable: true),
                       PhoneInventory.Column(colId: "Location", label: "Location", kind: "reference", target: "Locations",
                                             choices: [], editable: true)]
        let rows = (items ?? [(7, "SAMPLE Generator", 2, "item-7.pdf"), (8, "SAMPLE wrench", 3, nil),
                              (9, "SAMPLE flashlight", 2, nil), (10, "SAMPLE Generator transfer switch", 2, "item-10.pdf")])
            .enumerated().map { n, item in
                PhoneInventory.Row(id: item.0, position: n + 1, values: ["Item": .text(item.1), "Location": .int(item.2)],
                                   manual: item.3)
            }
        return PhoneInventory(writtenAt: "", columns: columns, items: rows, places: places ?? [
            .init(id: 1, name: "SAMPLE Garage", label: "", grab: "", keptIn: nil),
            .init(id: 2, name: "SAMPLE Utility shelf", label: "", grab: "", keptIn: 1),
            .init(id: 3, name: "SAMPLE Tool chest", label: "", grab: "", keptIn: 1),
            .init(id: 4, name: "SAMPLE Basement", label: "", grab: "", keptIn: nil),
        ], categories: [], headsUpDays: 30, toBuy: [], results: [:])
    }

    @Test func testPlaceFillsItsCurrentPath() {
        #expect(HomeSlots.place(id: 2, in: Self.copy()) == "SAMPLE Garage › SAMPLE Utility shelf")
        let moved = Self.copy(places: [.init(id: 2, name: "SAMPLE Utility shelf", label: "", grab: "", keptIn: 4),
                                       .init(id: 4, name: "SAMPLE Basement", label: "", grab: "", keptIn: nil)])
        #expect(HomeSlots.place(id: 2, in: moved) == "SAMPLE Basement › SAMPLE Utility shelf")
    }

    /// Owner, 2026-11-20, by click: a renamed place is followed, as the inventory never gives an id to another
    /// (InventoryFile.numberedForGood); the page shows its new name.
    @Test func testRenamedPlaceFillsWithItsNewName() {
        let renamed = Self.copy(places: [.init(id: 2, name: "SAMPLE Freezer", label: "", grab: "", keptIn: nil)])
        #expect(HomeSlots.place(id: 2, in: renamed) == "SAMPLE Freezer")
    }

    @Test func testPlaceGoneIsNotFilled() {
        #expect(HomeSlots.place(id: 99, in: Self.copy()) == nil)
    }

    @Test func testItemFillsItsCurrentPlace() {
        let found = HomeSlots.item(id: 7, in: Self.copy())
        #expect(found == .init(name: "SAMPLE Generator", place: "SAMPLE Garage › SAMPLE Utility shelf",
                               manual: "zim://\(ItemManuals.volumeID)/item-7.pdf"))
        let moved = Self.copy(items: [(7, "SAMPLE Generator", 4, nil)])
        #expect(HomeSlots.item(id: 7, in: moved)?.place == "SAMPLE Basement")
    }

    @Test func testRenamedItemFillsWithItsNewName() {
        let renamed = Self.copy(items: [(7, "SAMPLE Heater", 2, "item-7.pdf")])
        #expect(HomeSlots.item(id: 7, in: renamed)?.name == "SAMPLE Heater")
    }

    @Test func testItemGoneIsNotFilled() {
        #expect(HomeSlots.item(id: 99, in: Self.copy()) == nil)
    }

    /// The review, 2026-11-20: keyed by id, never by the slot's place in the page, which a reload between the trips
    /// can shift; a place link only where asked.
    @Test func testPickedIsKeyedById() {
        let slots = [["meet", "", ""], ["place", "", "2"], ["manual", "", "7"], ["thing", "", "8"], ["place", "", "99"],
                     ["items", "sample wrench", ""], ["place", "", "x"]]
        let found = HomeSlots.picked(slots, in: Self.copy(), links: true)
        #expect(found.places == ["2": .init(path: "SAMPLE Garage › SAMPLE Utility shelf", link: "prepareme://place/2")])
        #expect(Set(found.items.keys) == ["7", "8"])
        #expect(HomeSlots.picked(slots, in: Self.copy(), links: false).places["2"]?.link == "")
        #expect(HomeSlots.picked(slots, in: nil, links: true).places.isEmpty)
    }

    /// The place link is the bin label's own (Barcode.placeURL), read by Barcode.place(in:).
    @Test func testPlaceLinkIsTheBinLabels() {
        #expect(HomeSlots.placeLink(14) == Barcode.placeURL(14).absoluteString)
        #expect(Barcode.place(in: HomeSlots.placeLink(14)) == 14)
    }

    /// An app before the editor's fresh look shows every `.pm-slot` (main's fill script sets hidden = false on each):
    /// the picked kinds carry their own class, and this app reads both.
    @Test func testPickedSlotsAreNotPmSlots() {
        #expect(HomeSlots.readScript.contains("'.home-page .pm-slot, .home-page .pm-pick'"))
        #expect(HomeSlots.script(meet: [], kept: [:]).contains("'.home-page .pm-slot, .home-page .pm-pick'"))
        let page = HouseholdPage.Picked(id: 7, words: "SAMPLE Generator")
        #expect(HomePage.pickedSlot("manual", page) == #"<p class="pm-pick" data-slot="manual" data-id="7" hidden></p>"#)
        #expect(HomePage.placeLine(page).hasPrefix(#"<p class="hp-place pm-pick" data-slot="place" data-id="7">"#))
    }

    @Test func testScriptCarriesValuesAsJSON() {
        let script = HomeSlots.script(meet: [], kept: [:],
                                      places: ["2": .init(path: "SAMPLE </script><b>", link: HomeSlots.placeLink(2))],
                                      items: ["7": .init(name: "SAMPLE <b>", place: "x", manual: "")])
        #expect(!script.contains("</script>") && !script.contains("<b>"))
        #expect(script.contains(#"\u003c\/script>\u003cb>"#), "< escaped, as the encoder writes / too")
        #expect(!script.contains("innerHTML"), "every value reaches the page as textContent")
        #expect(script.contains(#""link":"prepareme:\/\/place\/2""#))
    }
}
