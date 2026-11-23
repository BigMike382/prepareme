import Testing
@testable import PrepareMeShared

/// Settings › Devices' space bar (owner, 2026-11-14, by click): three parts that add up to the phone, and the line.
struct RoomBarTests {
    @Test func thePartsAddUpAndUnderTheLineIsShort() {
        let bar = StorageWords.RoomBar(free: 6_000_000_000, capacity: 255_500_000_000, prepareMe: 19_100_000_000)
        #expect(bar.other + bar.prepareMe + bar.free == bar.capacity)
        #expect(bar.otherWords == "230.4 GB" && bar.freeWords == "6.0 GB of 255.5 GB")
        #expect(bar.short && bar.reserveWords == "Maps that come by themselves leave 10.0 GB free")
        #expect(bar.mapsWords == "No more maps come until there's room.")
        #expect(!StorageWords.RoomBar(free: 100_000_000_000, capacity: 255_500_000_000, prepareMe: 0).short)
    }

    @Test func prepareMesPartNeverRunsPastWhatIsUsed() {
        // the Mac's sizes for the phone's files can be newer than the phone's copies: clamped, never negative
        let bar = StorageWords.RoomBar(free: 60, capacity: 100, prepareMe: 70)
        #expect(bar.prepareMe == 40 && bar.other == 0)
        #expect(StorageWords.RoomBar(free: 200, capacity: 100, prepareMe: 5).free == 100)
    }
}
