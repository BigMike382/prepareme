import Foundation
import PrepareMeShared
import Testing

/// Family downloads plan, phase 5: the files the Mac offers a device and it doesn't hold, as the Library's Not
/// downloaded cards, after the held ones in their category. Made-up lists.
struct LibraryOffersTests {
    static let gb: Int64 = 1_000_000_000

    func entry(_ name: String, kind: String = "download", family: Bool? = true, title: String? = nil) -> Manifest.Entry {
        Manifest.Entry(name: name, id: UUID().uuidString, kind: kind, size: 2 * Self.gb,
                       sha256: String(repeating: "a", count: 64), deliveredAt: "2026-11-15T12:00:00-05:00",
                       family: family, title: title)
    }

    @Test func onlyFamilyDownloadsNotHeldAreOffered() {
        let held = entry("wikivet_en_all_2026-01.zim", title: "WikiVet")
        let list = [entry("prepareme-daily.zim", kind: "library", family: nil), held,
                    entry("medlineplus.gov_en_all_2026-02.zim", title: "MedlinePlus"),
                    entry("mine_2026-01.zim", family: false), entry("prepareme-maps-roads.zim", kind: "map-core"),
                    entry("prepareme-games.zim")]
        var record = LibraryRecord(manifest: Manifest(writtenAt: "x", files: list))
        record.held[held.name] = HeldFile(entry: held, file: held.name)
        let offered = LibraryShelf.offered(record, dailyFile: "prepareme-daily.zim")
        #expect(offered.map(\.title) == ["MedlinePlus"])  // not the Mac's own, a map, the games or one held
        #expect(offered.first?.offer?.name == "medlineplus.gov_en_all_2026-02.zim")
        #expect(offered.first?.key == "medlineplus.gov_en_all")
        #expect(LibraryShelf.offered(LibraryRecord(), dailyFile: "prepareme-daily.zim").isEmpty)  // no list yet
    }

    @Test func aNewEditionOfAHeldFileIsNotOfferedAgain() {
        let old = entry("wikivet_en_all_2026-01.zim")
        var new = entry("wikivet_en_all_2026-03.zim")
        new.id = old.id  // the same collection's newer copy downloads by itself; no Not downloaded card beside it
        var record = LibraryRecord(manifest: Manifest(writtenAt: "x", files: [new]))
        record.held[old.name] = HeldFile(entry: old, file: old.name)
        #expect(LibraryShelf.offered(record, dailyFile: "prepareme-daily.zim").isEmpty)
    }

    @Test func offersComeAfterTheHeldFilesInTheirCategory() {
        let shelf = LibraryShelf.starting
        func item(_ title: String, offer: Bool) -> LibraryShelf.Item {
            LibraryShelf.Item(id: UUID(), title: title, key: "medlineplus.gov_\(title)", notChecked: true,
                              arrived: nil, offer: offer ? entry("x.zim") : nil)
        }
        let items = [item("A offered", offer: true), item("Z held", offer: false), item("B held", offer: false)]
        #expect(shelf.own(items, in: "medical").map(\.title) == ["B held", "Z held", "A offered"])
        #expect(shelf.total(items, in: "medical") == 3)
    }

    @Test func theCardsWords() {
        #expect(HomeMacWords.count(3, toDownload: 2) == "3, 2 to download")
        #expect(HomeMacWords.count(3, toDownload: 0) == "3")
        #expect(HomeMacWords.noRoom(need: 6 * Self.gb) == "Not enough room (needs 6.0 GB free)")
        #expect(HomeMacWords.sizeAndFree(size: 2 * Self.gb, free: 30 * Self.gb, device: "iPad")
                    == "It is 2.0 GB; this iPad has 30.0 GB free.")
    }
}
