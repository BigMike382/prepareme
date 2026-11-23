import Foundation
import Testing
@testable import PrepareMeShared

/// The editor's pickers (docs/plans/2026-11-20-our-home-editor.md, Task 4), over made-up data only: HomeSlotsTests'
/// made-up copy, the rehearsal fixture for the Review focus's second condition.
@MainActor
struct HomePickTests {
    let copy = HomeSlotsTests.copy()

    @Test func testPlacesMatchAnyPartOfThePath() {
        #expect(HomePick.places("shelf", in: copy).map(\.path) == ["SAMPLE Garage › SAMPLE Utility shelf"])
        #expect(HomePick.places("garage", in: copy).map(\.path)
                == ["SAMPLE Garage", "SAMPLE Garage › SAMPLE Utility shelf", "SAMPLE Garage › SAMPLE Tool chest"])
        #expect(HomePick.places("GARAGE › sample util", in: copy).map(\.id) == [2])
        #expect(HomePick.places("", in: copy).isEmpty)
        #expect(HomePick.places("  ", in: copy).isEmpty)
        #expect(HomePick.places("back yard", in: copy).isEmpty)
    }

    @Test func testPlacesCountTheirItems() {
        let found = Dictionary(uniqueKeysWithValues: HomePick.places("sample", in: copy).map { ($0.id, $0.count) })
        #expect(found == [1: 4, 2: 3, 3: 1, 4: 0], "a place counts what's kept in it and in the places inside it")
    }

    @Test func testItemsWithManualOnly() {
        #expect(HomePick.items("generator", in: copy, withManual: true).map(\.name)
                == ["SAMPLE Generator", "SAMPLE Generator transfer switch"])
        #expect(HomePick.items("", in: copy, withManual: true).map(\.id) == [7, 10], "the manual picker lists them all")
        #expect(HomePick.items("wrench", in: copy, withManual: true).isEmpty)
        let wrench = HomePick.items("WRENCH", in: copy, withManual: false)
        #expect(wrench.map(\.id) == [8] && wrench.first?.place == "SAMPLE Garage › SAMPLE Tool chest")
        #expect(HomePick.items("", in: copy, withManual: false).isEmpty)
    }

    static let guides = [GuideList.Guide(page: "a.html", title: "SAMPLE Making water safe", topic: "SAMPLE Water"),
                         GuideList.Guide(page: "b.html", title: "SAMPLE Dehydration", topic: "SAMPLE Medical"),
                         GuideList.Guide(page: "c.html", title: "SAMPLE Storing water", topic: "SAMPLE Water"),
                         GuideList.Guide(page: "d.html", title: "SAMPLE Splints", topic: "SAMPLE Medical"),
                         GuideList.Guide(page: "e.html", title: "SAMPLE Odd one", topic: "Other"),
                         GuideList.Guide(page: "f.html", title: "SAMPLE Wells", topic: "SAMPLE Water")]

    @Test func testGuidesGroupByTopicWithTotals() {
        let all = HomePick.guides("", in: Self.guides)
        #expect(all.map(\.topic) == ["SAMPLE Medical", "SAMPLE Water", "Other"], "A to Z, Other last")
        #expect(all.map(\.total) == [2, 3, 1])
        #expect(all.map { $0.guides.count } == [2, 3, 1])
        let water = HomePick.guides("WATER", in: Self.guides)
        #expect(water.map(\.topic) == ["SAMPLE Water"])
        #expect(water[0].total == 3 && water[0].guides.map(\.page) == ["a.html", "c.html"])
        #expect(HomePick.guides("nothing like it", in: Self.guides).isEmpty)
    }

    @Test func testGuidesWithNoTopicsAreOneList() {  // format 1, from an older library
        let plain = Self.guides.map { GuideList.Guide(page: $0.page, title: $0.title) }
        let all = HomePick.guides("", in: plain)
        #expect(all.count == 1 && all[0].topic == "" && all[0].total == 6)
        #expect(HomePick.guides("water", in: plain).first?.guides.count == 2)
    }

    /// Owner, 2026-11-20, by click: renamed or moved is followed, never stale; only an id the copy no longer has is.
    @Test func testStaleOnlyWhenGone() {
        let shelf = HouseholdPage.Picked(id: 2, words: "SAMPLE Garage › SAMPLE Utility shelf")
        #expect(!HomePick.stale(shelf, place: true, in: copy))
        let moved = HomeSlotsTests.copy(places: [.init(id: 2, name: "SAMPLE Utility shelf", label: "", grab: "", keptIn: nil)])
        #expect(!HomePick.stale(shelf, place: true, in: moved))
        let renamed = HomeSlotsTests.copy(places: [.init(id: 2, name: "SAMPLE Freezer", label: "", grab: "", keptIn: nil)])
        #expect(!HomePick.stale(shelf, place: true, in: renamed))
        #expect(HomePick.stale(.init(id: 99, words: "SAMPLE Garage"), place: true, in: copy))
        #expect(!HomePick.stale(.init(words: "SAMPLE Back yard"), place: true, in: copy), "typed words are never stale")
        #expect(!HomePick.stale(.init(id: 7, words: "SAMPLE Heater"), place: false, in: copy))
        #expect(HomePick.stale(.init(id: 99, words: "SAMPLE Generator"), place: false, in: copy))
    }

    /// Save writes each picked place, manual and thing as the copy names it now; typed and gone ones as they are.
    @Test func testSaveFollowsRenames() {
        var page = HouseholdPage(title: "SAMPLE page", steps: [])
        page.things = [.init(id: 7, words: "SAMPLE Old name"), .init(words: "SAMPLE towels"), .init(id: 99, words: "SAMPLE gone")]
        page.steps = [.init(words: "SAMPLE a", place: .init(id: 2, words: "SAMPLE Old shelf"), manual: .init(id: 10, words: "SAMPLE x"))]
        let renamed = HomeSlotsTests.copy(places: [.init(id: 1, name: "SAMPLE Garage", label: "", grab: "", keptIn: nil),
                                                   .init(id: 2, name: "SAMPLE Shelf; top", label: "", grab: "", keptIn: 1)],
                                          items: [(7, "SAMPLE Generator; dual fuel", 2, nil), (10, "SAMPLE Switch", 2, "item-10.pdf")])
        let followed = HomePick.followed(page, in: renamed)
        #expect(followed.things.map(\.line) == ["#7 SAMPLE Generator, dual fuel", "SAMPLE towels", "#99 SAMPLE gone"])
        #expect(followed.steps[0].place?.line == "#2 SAMPLE Garage › SAMPLE Shelf, top")
        #expect(followed.steps[0].manual?.line == "#10 SAMPLE Switch")
        #expect(HomePick.followed(page, in: nil) == page)
    }

    /// The limits and the ";" rule are for typed words: a picked one is the inventory's own name or path, which can
    /// be longer, and the page must still save (the review, 2026-11-20).
    @Test func testLongPickedNamesStillSave() {
        var page = HouseholdPage(title: "SAMPLE page", steps: [])
        let long = String(repeating: "SAMPLE long name ", count: 8)
        page.things = [.init(id: 7, words: long)]
        page.steps = [.init(words: "SAMPLE a", place: .init(id: 2, words: long))]
        #expect(page.problem == nil)
        page.things = [.init(words: long)]
        #expect(page.problem == "What you need: a thing can be at most \(HouseholdPage.maxThing) characters.")
    }

    /// The Review focus's second condition: a Private ("Mac only") item never appears in a picker. The rehearsal
    /// fixture's "Indoor propane heater" is Private.
    @Test func testPickersListOnlyThePhonesCopy() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-pick-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("inventory.sqlite")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        let editor = try InventoryEditor(file: try InventoryFile(url: url), checker: FakeCheck())
        let secret = try #require(editor.inventory.itemRows.first { editor.inventory.isPrivate($0) })
        let name = editor.inventory.items.column(Inventory.Label.item).map { InventoryValues.plain(secret[$0]) } ?? ""
        #expect(!name.isEmpty)
        let phones = PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:], manuals: [secret.id])
        for withManual in [false, true] {
            for query in [name, String(name.prefix(5)), "propane", "heater", ""] {
                #expect(!HomePick.items(query, in: phones, withManual: withManual).contains { $0.id == secret.id || $0.name == name })
            }
        }
        #expect(HomePick.stale(.init(id: secret.id, words: name), place: false, in: phones), "its fill finds nothing")
        // places: the inventory has no Mac-only place (Locations carry no Private mark), so no places half here
    }
}
