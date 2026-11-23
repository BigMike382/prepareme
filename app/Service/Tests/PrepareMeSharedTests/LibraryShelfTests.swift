import Foundation
import PrepareMeShared
import Testing

/// The Library's shelf (Library plan, tasks 1.1 and 1.2; owner, 2026-11-12): categories, the date-free key a file is
/// placed by, the starting set, grouping, New and the not-checked mark.
struct LibraryShelfTests {
    // MARK: Task 1.1

    @Test func keyDropsExtensionAndDate() {
        #expect(LibraryShelf.key(fileName: "medlineplus.gov_en_all_2025-01.zim") == "medlineplus.gov_en_all")
        #expect(LibraryShelf.key(fileName: "appropedia_en_all_maxi_2026-02.zim") == "appropedia_en_all_maxi")
        #expect(LibraryShelf.key(fileName: "prepareme-reference.zim") == "prepareme-reference")
        #expect(LibraryShelf.key(fileName: "usda-2015_en_2025-04-11.zim") == "usda-2015_en")
    }

    @Test func newerEditionKeepsItsKey() {
        #expect(LibraryShelf.key(fileName: "wikivet.net_en_all_maxi_2026-07.zim")
                == LibraryShelf.key(fileName: "wikivet.net_en_all_maxi_2027-01.zim"))
    }

    @Test func startingSetOrderAndEmoji() {
        #expect(LibraryShelf.starting.categories.map(\.name) == ["Medical", "Vehicles and Repair", "Food and Garden",
                                                                 "Water and Shelter", "Skills", "Animals", "Reference"])
        #expect(LibraryShelf.starting.categories.allSatisfy { LibraryShelf.emojiGrid.contains($0.emoji) })
        #expect(LibraryShelf.emojiGrid.count == 24 && Set(LibraryShelf.emojiGrid).count == 24)
        #expect(LibraryShelf.starting.placed.isEmpty)
    }

    @Test func roundTripsAndRefusesJunk() {
        #expect(LibraryShelf.read(LibraryShelf.starting.encoded()) == LibraryShelf.starting)
        #expect(LibraryShelf.read(Data("not json".utf8)) == nil)
        #expect(LibraryShelf.read(nil) == nil)
    }

    // MARK: Task 1.2

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func item(_ key: String, _ title: String, notChecked: Bool = false, daysAgo: Double? = nil)
        -> LibraryShelf.Item {
        LibraryShelf.Item(id: UUID(), title: title, key: key, notChecked: notChecked,
                          arrived: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    @Test func startingPrefixesPlaceTheKnownFiles() {
        let shelf = LibraryShelf.starting
        #expect(shelf.category(for: "prepareme-reference") == "medical")
        #expect(shelf.category(for: "medlineplus.gov_en_all") == "medical")
        #expect(shelf.category(for: "appropedia_en_all_maxi") == "water")
        #expect(shelf.category(for: "wikipedia_en_100") == "reference")
        #expect(shelf.category(for: "prepareme-item-manuals") == "vehicles")
    }

    @Test func groupsInCategoryOrderSkippingEmpty() {
        let items = [Self.item("wikipedia_en_100", "Wikipedia 100"), Self.item("zimgit-knots_en", "Knots"),
                     Self.item("medlineplus.gov_en_all", "MedlinePlus"),
                     Self.item("irp.fas.org_en_military-medicine", "Military Medicine")]
        let groups = LibraryShelf.starting.grouped(items)
        #expect(groups.map(\.category.id) == ["medical", "skills", "reference"])
        #expect(groups[0].items.map(\.title) == ["MedlinePlus", "Military Medicine"])
    }

    @Test func placedBeatsStartingPrefix() {
        var shelf = LibraryShelf.starting
        shelf.placed["medlineplus.gov_en_all"] = "reference"
        #expect(shelf.category(for: "medlineplus.gov_en_all") == "reference")
    }

    @Test func unknownFileIsUnsortedNotLost() {
        let odd = Self.item("something_en_all", "Something")
        let shelf = LibraryShelf.starting
        #expect(shelf.category(for: odd.key) == nil)
        #expect(shelf.unsorted([odd]) == [odd])
        #expect(shelf.grouped([odd]).isEmpty)
    }

    @Test func placedToRemovedCategoryIsUnsorted() {
        var shelf = LibraryShelf.starting
        shelf.placed["medlineplus.gov_en_all"] = "gone"
        #expect(shelf.category(for: "medlineplus.gov_en_all") == nil)
        shelf.placed = [:]
        shelf.categories.removeAll { $0.id == "medical" }
        #expect(shelf.category(for: "medlineplus.gov_en_all") == nil, "a starting prefix whose category was removed")
    }

    @Test func newIsThirtyDaysNewestFirst() {
        let items = [Self.item("a", "Old", daysAgo: 31), Self.item("b", "Month", daysAgo: 29),
                     Self.item("c", "Yesterday", daysAgo: 1), Self.item("d", "Unknown")]
        #expect(LibraryShelf.newItems(items, now: Self.now).map(\.title) == ["Yesterday", "Month"])
    }

    @Test func onlyDownloadsAreNotChecked() {
        func held(_ name: String, _ kind: String) -> HeldFile {
            HeldFile(entry: Manifest.Entry(name: name, id: UUID().uuidString, kind: kind, size: 1,
                                           sha256: String(repeating: "0", count: 64),
                                           deliveredAt: "2026-11-01T00:00:00Z"), file: name)
        }
        let all = ["prepareme-daily.zim": held("prepareme-daily.zim", "library"),
                   "prepareme-vehicles.zim": held("prepareme-vehicles.zim", "library"),
                   "phet_en_all_2026-08.zim": held("phet_en_all_2026-08.zim", "download")]
        let items = LibraryShelf.items(all, dailyFile: "prepareme-daily.zim", arrived: { _ in nil }, named: { _ in nil })
        #expect(items.count == 2, "the daily library is Guides, never the Library")
        #expect(items.first { $0.key == "phet_en_all" }?.notChecked == true)
        #expect(items.first { $0.key == "prepareme-vehicles" }?.notChecked == false)
    }

    // MARK: Library redesign plan 2.4: the owner's descriptions

    @Test func oldShelfFileReads() throws {
        let old = #"{"categories":[{"id":"medical","name":"Medical","emoji":"⛑️"}],"placed":{"a":"medical"}}"#
        let shelf = try #require(LibraryShelf.read(Data(old.utf8)), "a shelf written before descriptions still reads")
        #expect(shelf.descriptions.isEmpty)
        #expect(shelf.placed == ["a": "medical"])
    }

    static func described(_ key: String, about: String?) -> LibraryShelf.Item {
        LibraryShelf.Item(id: UUID(), title: "T", key: key, notChecked: false, arrived: nil, about: about)
    }

    @Test func editWinsOverFile() {
        let item = Self.described("cdc-water_en", about: "The file's own line.")
        #expect(LibraryShelf.starting.description(for: item) == "The file's own line.")
        let shelf = LibraryShelf.starting.describing(key: "cdc-water_en", as: "  Water treatment from the CDC.  ")
        #expect(shelf.description(for: item) == "Water treatment from the CDC.")
        #expect(LibraryShelf.read(shelf.encoded()) == shelf, "kept in the file")
    }

    /// One fallback for the card, the picker and the editor (phase 2 review, a deferred minor): the owner's words,
    /// else the manifest's, else Kiwix's record; an empty line is none.
    @Test func descriptionFallsBackToTheRecord() {
        let none = Self.described("k", about: nil), blank = Self.described("k", about: "")
        #expect(LibraryShelf.starting.description(for: none, recorded: "Kiwix's line.") == "Kiwix's line.")
        #expect(LibraryShelf.starting.description(for: blank, recorded: "Kiwix's line.") == nil, "the manifest's empty")
        #expect(LibraryShelf.original(none, recorded: "") == nil)
        let mine = LibraryShelf.starting.describing(key: "k", as: "Mine.")
        #expect(mine.description(for: none, recorded: "Kiwix's line.") == "Mine.")
    }

    @Test func blankEditRemoves() {
        let shelf = LibraryShelf.starting.describing(key: "k", as: "Mine.")
        #expect(shelf.describing(key: "k", as: "   ").descriptions.isEmpty)
        #expect(shelf.describing(key: "k", as: nil).descriptions.isEmpty)
    }

    @Test func editKeepsToOneLine() {
        let shelf = LibraryShelf.starting.describing(key: "k", as: "Knots for camp.\n\nAnd   rescue.\n")
        #expect(shelf.descriptions["k"] == "Knots for camp. And rescue.", "a card line on every phone, never broken")
    }

    @Test func editCutTo160() {
        let shelf = LibraryShelf.starting.describing(key: "k", as: String(repeating: "a", count: 200))
        #expect(shelf.descriptions["k"]?.count == LibraryShelf.descriptionLimit)
        #expect(LibraryShelf.descriptionLimit == 160)
    }

    @Test func editKeptForNewerEdition() {
        let shelf = LibraryShelf.starting.describing(key: LibraryShelf.key(fileName: "wikivet.net_en_all_maxi_2026-07.zim"),
                                                    as: "Animal care.")
        let newer = Self.described(LibraryShelf.key(fileName: "wikivet.net_en_all_maxi_2027-01.zim"), about: "Kiwix's.")
        #expect(shelf.description(for: newer) == "Animal care.")
    }

    @Test func itemFamilyAndCard() {
        func held(_ name: String, _ kind: String, family: Bool? = nil) -> HeldFile {
            HeldFile(entry: Manifest.Entry(name: name, id: UUID().uuidString, kind: kind, size: 1,
                                           sha256: String(repeating: "0", count: 64), deliveredAt: "2026-11-01T00:00:00Z",
                                           family: family, about: "About \(name)", inside: "3 pages",
                                           source: "Kiwix"), file: name)
        }
        let all = ["prepareme-vehicles.zim": held("prepareme-vehicles.zim", "library"),
                   "a_en_2026-08.zim": held("a_en_2026-08.zim", "download", family: true),
                   "b_en_2026-08.zim": held("b_en_2026-08.zim", "download")]
        let items = LibraryShelf.items(all, dailyFile: "prepareme-daily.zim", arrived: { _ in nil }, named: { _ in nil })
        let by = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        #expect(by["prepareme-vehicles"]?.family == true, "our own volumes go to every phone")
        #expect(by["a_en"]?.family == true)
        #expect(by["b_en"]?.family == false, "a download the Mac keeps for itself")
        #expect(by["a_en"]?.about == "About a_en_2026-08.zim")
        #expect(by["a_en"]?.inside == "3 pages")
        #expect(by["a_en"]?.source == "Kiwix")
    }

    // MARK: Phase 3: the owner's edits on the Mac

    @Test func addingPutsANewCategoryLast() throws {
        let (shelf, id) = try #require(LibraryShelf.starting.adding(name: "Radio", emoji: "📻"))
        #expect(shelf.categories.last == LibraryShelf.Category(id: id, name: "Radio", emoji: "📻"))
        #expect(id == "radio")
    }

    @Test func addingRefusesDuplicateIgnoringCase() {
        #expect(LibraryShelf.starting.adding(name: "medical", emoji: "💊") == nil)
        #expect(LibraryShelf.starting.adding(name: "  Skills ", emoji: "💊") == nil)
    }

    @Test func addingRefusesEmptyOver20OrAnEmojiOffTheGrid() {
        #expect(LibraryShelf.starting.adding(name: "   ", emoji: "📻") == nil)
        #expect(LibraryShelf.starting.adding(name: String(repeating: "a", count: 21), emoji: "📻") == nil)
        #expect(LibraryShelf.starting.adding(name: String(repeating: "a", count: 20), emoji: "📻") != nil)
        #expect(LibraryShelf.starting.adding(name: "Radio", emoji: "x") == nil)
    }

    @Test func addingMakesAUniqueID() throws {
        var shelf = LibraryShelf.starting
        shelf.categories.append(.init(id: "food-and-fuel", name: "Old name", emoji: "🔥"))
        let (_, id) = try #require(shelf.adding(name: "Food and Fuel", emoji: "🔥"))
        #expect(id == "food-and-fuel-2")
    }

    @Test func movingPlacesTheKey() {
        let shelf = LibraryShelf.starting.moving(key: "medlineplus.gov_en_all", to: "reference")
        #expect(shelf.category(for: "medlineplus.gov_en_all") == "reference")
    }

    @Test func renamingKeepsIDAndFiles() throws {
        let shelf = try #require(LibraryShelf.starting.renaming(id: "skills", to: "Know-How", emoji: "🧭"))
        #expect(shelf.categories.first { $0.id == "skills" } == .init(id: "skills", name: "Know-How", emoji: "🧭"))
        #expect(shelf.category(for: "zimgit-knots_en") == "skills")
        #expect(LibraryShelf.starting.renaming(id: "skills", to: "Medical", emoji: "🧭") == nil, "a name already used")
        #expect(LibraryShelf.starting.renaming(id: "skills", to: "Skills", emoji: "📖") != nil, "its own name, new emoji")
        #expect(LibraryShelf.starting.renaming(id: "gone", to: "X", emoji: "📖") == nil)
    }

    @Test func removingMovesItsFilesFirst() throws {
        let keys = ["zimgit-knots_en", "phet_en_all", "medlineplus.gov_en_all"]
        let shelf = try #require(LibraryShelf.starting.removing(id: "skills", movingFilesTo: "reference", keys: keys))
        #expect(!shelf.categories.contains { $0.id == "skills" })
        #expect(shelf.category(for: "zimgit-knots_en") == "reference")
        #expect(shelf.category(for: "phet_en_all") == "reference")
        #expect(shelf.category(for: "medlineplus.gov_en_all") == "medical", "another category's file stays")
    }

    @Test func removingRefusesItselfOrAMissingTarget() {
        #expect(LibraryShelf.starting.removing(id: "skills", movingFilesTo: "skills", keys: []) == nil)
        #expect(LibraryShelf.starting.removing(id: "skills", movingFilesTo: "gone", keys: []) == nil)
        #expect(LibraryShelf.starting.removing(id: "gone", movingFilesTo: "reference", keys: []) == nil)
    }

    @Test func laterNeedsACategoryEvenWhereTheStartingSetPlacesIt() {
        let later = LibraryShelf.starting.moving(key: "medlineplus.gov_en_all", to: LibraryShelf.needsCategory)
        let item = Self.item("medlineplus.gov_en_all", "MedlinePlus")
        #expect(later.category(for: item.key) == nil)
        #expect(later.unsorted([item]) == [item])
        #expect(later.moving(key: item.key, to: "reference").category(for: item.key) == "reference")
        #expect(later.removing(id: "skills", movingFilesTo: "reference", keys: [item.key])?.unsorted([item]) == [item])
    }

    @Test func removingTheLastCategoryIsRefused() {
        let one = LibraryShelf(categories: [.init(id: "reference", name: "Reference", emoji: "📚")])
        #expect(one.removing(id: "reference", movingFilesTo: "reference", keys: []) == nil)
    }

    // MARK: Library redesign plan 4.1: subcategories, one level

    /// A shelf with Books (top level) holding Homesteading and Repair, and Vehicles holding its own Repair.
    static func books() throws -> LibraryShelf {
        let (one, books) = try #require(LibraryShelf.starting.adding(name: "Books", emoji: "📖"))
        let (two, _) = try #require(one.addingSub(name: "Homesteading", to: books))
        let (three, _) = try #require(two.addingSub(name: "Repair", to: books))
        return try #require(three.addingSub(name: "Repair", to: "vehicles")).0
    }

    @Test func oldShelfHasNoParents() throws {
        let old = Data(#"{"categories":[{"id":"medical","name":"Medical","emoji":"⛑️"}],"placed":{}}"#.utf8)
        let shelf = try #require(LibraryShelf.read(old))
        #expect(shelf.categories.allSatisfy { $0.parent == nil })
        #expect(shelf.descriptions.isEmpty)
        #expect(!String(decoding: LibraryShelf.starting.encoded(), as: UTF8.self).contains("parent"))
    }

    /// A subcategory whose category is gone (a hand-edited file only) hid its collections everywhere; they show under
    /// Needs a category instead (library redesign phase 4 review, a deferred minor).
    @Test func orphanSubIsUnsorted() throws {
        let text = #"{"categories":[{"id":"medical","name":"Medical","emoji":"⛑️"},"#
            + #"{"id":"knots","name":"Knots","emoji":"","parent":"gone"}],"placed":{"rope_en":"knots"}}"#
        let shelf = try #require(LibraryShelf.read(Data(text.utf8)))
        #expect(shelf.category(for: "rope_en") == nil)
    }

    @Test func addSub() throws {
        let shelf = try Self.books()
        let sub = try #require(shelf.categories.first { $0.name == "Homesteading" })
        #expect(sub.parent == "books")
        #expect(shelf.children(of: "books").map(\.name) == ["Homesteading", "Repair"])
        #expect(shelf.emoji(of: sub.id) == "📖")  // a subcategory shows its category's emoji
        #expect(LibraryShelf.read(shelf.encoded()) == shelf)
    }

    @Test func subNameUniqueInParentOnly() throws {
        let shelf = try Self.books()
        #expect(shelf.children(of: "vehicles").map(\.name) == ["Repair"])
        #expect(shelf.addingSub(name: "repair", to: "books") == nil)
        #expect(shelf.addingSub(name: "  ", to: "books") == nil)
        #expect(shelf.addingSub(name: "Gear", to: "nowhere") == nil)
        #expect(Set(shelf.categories.map(\.id)).count == shelf.categories.count)
    }

    @Test func noSubOfSub() throws {
        let shelf = try Self.books()
        let sub = try #require(shelf.categories.first { $0.name == "Homesteading" })
        #expect(shelf.addingSub(name: "Goats", to: sub.id) == nil)
    }

    @Test func removeSubMovesFiles() throws {
        var shelf = try Self.books()
        let sub = try #require(shelf.categories.first { $0.name == "Homesteading" }).id
        shelf = shelf.moving(key: "homestead_en", to: sub)
        let after = try #require(shelf.removing(id: sub, movingFilesTo: "books", keys: ["homestead_en"]))
        #expect(after.category(for: "homestead_en") == "books")
        #expect(!after.categories.contains { $0.id == sub })
        #expect(after.children(of: "books").map(\.name) == ["Repair"])
    }

    @Test func removeCategoryWithSubsMovesAll() throws {
        var shelf = try Self.books()
        let subs = shelf.children(of: "books").map(\.id)
        shelf = shelf.moving(key: "own_en", to: "books").moving(key: "a_en", to: subs[0]).moving(key: "b_en", to: subs[1])
        let keys = ["own_en", "a_en", "b_en"]
        let after = try #require(shelf.removing(id: "books", movingFilesTo: "reference", keys: keys))
        #expect(keys.allSatisfy { after.category(for: $0) == "reference" })
        #expect(!after.categories.contains { $0.id == "books" || subs.contains($0.id) })
        #expect(!after.placed.values.contains { $0 == "books" || subs.contains($0) })
        // never into itself or one of its own subcategories
        #expect(shelf.removing(id: "books", movingFilesTo: subs[0], keys: keys) == nil)
    }

    @Test func groupedTopLevelOnly() throws {
        var shelf = try Self.books()
        let sub = try #require(shelf.categories.first { $0.name == "Homesteading" }).id
        shelf = shelf.moving(key: "homestead_en", to: sub)
        let items = [Self.item("homestead_en", "Homestead"), Self.item("wikipedia_en_100", "Wikipedia")]
        let groups = shelf.grouped(items)
        // Books shows (its subcategory holds a file) with none of its own; no subcategory is a group of its own
        #expect(groups.map(\.category.id) == ["reference", "books"])  // Books was added after the starting set
        #expect(groups[1].items.isEmpty)
        #expect(shelf.subGroups(items, in: "books").map(\.category.id) == [sub])
        #expect(shelf.subGroups(items, in: "books")[0].items.map(\.title) == ["Homestead"])
        #expect(shelf.total(items, in: "books") == 1)
        #expect(shelf.unsorted(items).isEmpty)
        // a folder holds its own; its category holds none loose (owner, 2026-11-14: subcategories as folders)
        #expect(shelf.own(items, in: sub).map(\.title) == ["Homestead"])
        #expect(shelf.own(items, in: "books").isEmpty)
        #expect(shelf.total(items, in: sub) == 1)
    }

    @Test func pathWords() throws {
        let shelf = try Self.books()
        let sub = try #require(shelf.categories.first { $0.name == "Homesteading" }).id
        #expect(shelf.path(of: sub) == "📖 Books › Homesteading")
        #expect(shelf.path(of: "books") == "📖 Books")
        #expect(shelf.path(of: "nowhere") == "")
    }

    @Test func newItemsCarryParentEmoji() throws {
        var shelf = try Self.books()
        let sub = try #require(shelf.categories.first { $0.name == "Repair" && $0.parent == "vehicles" }).id
        shelf = shelf.moving(key: "fixit_en", to: sub)
        #expect(shelf.category(for: "fixit_en").map(shelf.emoji(of:)) == "🔧")
    }

    @Test func renameSubKeepsItsParent() throws {
        let shelf = try Self.books()
        let sub = try #require(shelf.categories.first { $0.name == "Homesteading" }).id
        let renamed = try #require(shelf.renaming(id: sub, to: "Farming", emoji: ""))
        let after = try #require(renamed.categories.first { $0.id == sub })
        #expect(after.name == "Farming" && after.parent == "books" && renamed.emoji(of: sub) == "📖")
        #expect(shelf.renaming(id: sub, to: "Repair", emoji: "") == nil)  // its sibling's name
    }
}
