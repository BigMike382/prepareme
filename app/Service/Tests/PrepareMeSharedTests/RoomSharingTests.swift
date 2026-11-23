import Foundation
import PrepareMeShared
import Testing

/// Unlisted plan, phase 4 (decision 6): a device sends its free space rounded, and only with its person's yes; the
/// report keeps both fields, so a Mac one version older still reads it, and this Mac reads 0 and 0 as not shared.
@Suite struct RoomSharingTests {
    let gb: Int64 = 1_000_000_000

    @Test func freeGoesDownToTheGigabyteCapacityUpToTheSoldSize() {
        #expect(PhoneStorage.shared(free: 23_456_789_012, capacity: 127_800_000_000, allowed: true)
                == (23 * gb, 128 * gb))
        #expect(PhoneStorage.shared(free: 9_999_999_999, capacity: 63_900_000_000, allowed: true) == (9 * gb, 64 * gb))
        #expect(PhoneStorage.shared(free: 400_000_000, capacity: 994_500_000_000, allowed: true) == (0, 1_000 * gb))
        #expect(PhoneStorage.shared(free: 1, capacity: 9_000 * gb + 1, allowed: true).capacity == 9_001 * gb)
        #expect(PhoneStorage.shared(free: 5 * gb, capacity: 4 * gb, allowed: true).free == 4 * gb, "never above capacity")
    }

    @Test func theTenGigabyteLineStaysWhereItWas() {
        // the Mac's "no more maps until there's room" falls at 10 GB, a whole number of gigabytes
        for free in [9_999_999_999, 10_000_000_000, 10_400_000_000] as [Int64] {
            let sent = PhoneStorage.shared(free: free, capacity: 128 * gb, allowed: true)
            #expect((sent.free < LibraryPlan.reserve(capacity: sent.capacity)) == (free < LibraryPlan.reserve(capacity: 0)))
        }
    }

    @Test func withoutAYesBothAreZeroAndTheMacSaysSo() throws {
        let sent = PhoneStorage.shared(free: 50 * gb, capacity: 128 * gb, allowed: false)
        #expect(sent == (0, 0))
        let report = PhoneStorage(free: sent.free, capacity: sent.capacity, held: [], waiting: [], cantUpdate: [])
        let read = try PhoneStorage.read(try JSONEncoder().encode(report))
        #expect(!read.sharesRoom)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(json.contains("\"free\":0") && json.contains("\"capacity\":0"), "both fields still sent")
        #expect(PhoneStorage.notSharedLine.hasPrefix("Doesn't share its free space"))
    }

    @Test func anOlderPhonesExactReportStillReadsAndShares() throws {
        let older = Data(#"{"free":23456789012,"capacity":127800000000,"held":[],"waiting":[],"cant_update":[]}"#.utf8)
        let read = try PhoneStorage.read(older)
        #expect(read.sharesRoom)
        #expect(read.free == 23_456_789_012)
    }
}
