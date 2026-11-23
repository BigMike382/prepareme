@testable import PrepareMeShared
import XCTest

/// Remaining-findings plan, Task 8.3 (F13): plain sizes. Phase L (finding 8; owner, 2026-10-20, by click): under 1 MB
/// in whole KB, under 1 GB in whole MB, else GB with one decimal, never "about", in the system's 1000-based units.
final class StorageWordsTests: XCTestCase {
    func testEachUnitAndItsBoundaries() {
        XCTAssertEqual(StorageWords.size(61_000), "61 KB", "a 61 KB file, once \"about 1 MB\"")
        XCTAssertEqual(StorageWords.size(0), "0 KB")
        XCTAssertEqual(StorageWords.size(300), "1 KB", "a few bytes never read as nothing")
        XCTAssertEqual(StorageWords.size(999_000), "999 KB")
        XCTAssertEqual(StorageWords.size(999_600), "1 MB", "what rounds to 1,000 KB is 1 MB")
        XCTAssertEqual(StorageWords.size(1_000_000), "1 MB")
        XCTAssertEqual(StorageWords.size(850_400_000), "850 MB")
        XCTAssertEqual(StorageWords.size(999_400_000), "999 MB")
        XCTAssertEqual(StorageWords.size(999_600_000), "1.0 GB", "what rounds to 1,000 MB is 1.0 GB")
        XCTAssertEqual(StorageWords.size(1_000_000_000), "1.0 GB")
        XCTAssertEqual(StorageWords.size(2_420_000_000), "2.4 GB")
        XCTAssertEqual(StorageWords.size(160_940_000_000), "160.9 GB")
        XCTAssertEqual(StorageWords.size(1_498_760_000_000), "1,498.8 GB")
        XCTAssertEqual(StorageWords.size(-5), "0 KB")
    }

    /// A refusal never reads the same size twice ("needs about 2 GB… has about 2 GB", finding 8): what is needed
    /// rounds up and what is free rounds down, so needing more than is free always reads as more.
    func testARefusalsTwoSizesNeverReadTheSame() {
        let close = StorageWords.room(need: 2_400_000_001, free: 2_400_000_000)
        XCTAssertEqual(close.need, "2.5 GB")
        XCTAssertEqual(close.free, "2.4 GB")
        let apart = StorageWords.room(need: 7_120_000_000, free: 5_090_000_000)
        XCTAssertEqual(apart.need, "7.2 GB")
        XCTAssertEqual(apart.free, "5.0 GB")
        let small = StorageWords.room(need: 61_200, free: 61_100)
        XCTAssertEqual(small.need, "62 KB")
        XCTAssertEqual(small.free, "61 KB")
        let across = StorageWords.room(need: 999_999_999, free: 999_000_001)
        XCTAssertEqual(across.need, "1.0 GB", "rounded up past 999 MB")
        XCTAssertEqual(across.free, "999 MB")
        for (need, free) in [(Int64(1_000_000_001), Int64(1_000_000_000)), (999_500, 999_499), (5, 0), (2, 1)] {
            let words = StorageWords.room(need: need, free: free)
            XCTAssertNotEqual(words.need, words.free, "\(need) against \(free)")
        }
    }

    /// Beta run 2, B2-10 (R4.3): never "has 7.5 GB free and keeps 10.0 GB of it". Free below the reserve says so and
    /// that no more maps come; with room, maps still come in order. The Mac's Phones list reads the same. Family
    /// downloads plan, phase 4: the 10 GB binds only the maps that come by themselves, and the line says so.
    func testTheRoomLineNeverKeepsMoreThanIsFree() {
        let capacity: Int64 = 994_500_000_000  // the reserve is 10 GB whatever the size (owner, 2026-11-15)
        XCTAssertEqual(StorageWords.roomLine(free: 7_500_000_000, capacity: capacity),
                       "Free: 7.5 GB. Maps that come by themselves leave 10.0 GB free, so no more come "
                       + "until there's room.")
        XCTAssertEqual(StorageWords.roomLine(free: 300_000_000_000, capacity: capacity),
                       "Free: 300.0 GB. Maps that come by themselves leave 10.0 GB free; they come in order "
                       + "while there is room.")
        XCTAssertEqual(StorageWords.roomLine(free: 10_000_000_000, capacity: capacity),
                       "Free: 10.0 GB. Maps that come by themselves leave 10.0 GB free; they come in order "
                       + "while there is room.", "exactly the reserve is not below it")
        // a nearly full small phone keeps the same 10 GB
        XCTAssertEqual(StorageWords.roomLine(free: 8_000_000_000, capacity: 128_000_000_000),
                       "Free: 8.0 GB. Maps that come by themselves leave 10.0 GB free, so no more come "
                       + "until there's room.")
        // the Mac's list adds the phone's size
        XCTAssertEqual(StorageWords.roomLine(free: 7_500_000_000, capacity: capacity, showCapacity: true),
                       "Free: 7.5 GB of 994.5 GB. Maps that come by themselves leave 10.0 GB free, so no "
                       + "more come until there's room.")
    }
}
