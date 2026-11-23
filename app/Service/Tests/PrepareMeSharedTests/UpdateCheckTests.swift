import Foundation
import Testing
@testable import PrepareMeShared

/// The update self-check (owner, by click, 2026-11-14): counts kept per build, compared at a different build's first
/// opening, its words, the room report's copy and the Mac's line.
struct UpdateCheckTests {
    let before = ["library files": 40, "inventory items": 124, "places": 12, "rally points and routes": 3, "pins": 5,
                  "Essential Documents files": 9, "pairing with the Mac": 1]

    @Test func theSameBuildOrNoBuildBeforeIsNoResult() {
        let counts = UpdateCheck.Counts(build: "250", counts: before)
        #expect(UpdateCheck.compare(nil, counts) == nil)
        #expect(UpdateCheck.compare(counts, counts) == nil)
    }

    @Test func nothingLostAndMoreIsNothingLost() throws {
        var more = before
        more["inventory items"] = 130
        let result = try #require(UpdateCheck.compare(.init(build: "250", counts: before),
                                                      .init(build: "2026.1114.1701", counts: more)))
        #expect(result.dropped.isEmpty)
        #expect(UpdateCheck.words(result) == "Nothing lost in this update (from build 250).")
        #expect(UpdateCheck.macLine(name: "Mike's iPhone", build: "2026.1114.1701", result) == nil)
    }

    @Test func eachDropIsNamedInOrderWithItsCounts() throws {
        var after = before
        after["pins"] = 0
        after["inventory items"] = 120
        after["pairing with the Mac"] = 0
        after.removeValue(forKey: "places")  // a count that's missing reads as none
        let result = try #require(UpdateCheck.compare(.init(build: "250", counts: before),
                                                      .init(build: "2026.1114.1701", counts: after)))
        #expect(result.dropped == ["inventory items", "places", "pins", "pairing with the Mac"])
        #expect(UpdateCheck.words(result) == "Something is missing since the update from build 250: inventory items "
                + "(124 before, 120 now), places (12 before, 0 now), pins (5 before, 0 now), the pairing with the Mac. "
                + "Hold off updating anyone else, and check it at the Mac.")
        #expect(UpdateCheck.macLine(name: "phone 1", build: "2026.1114.1701", result)
                == "phone 1 lost inventory items, places, pins, pairing with the Mac in its update from build 250 to "
                + "2026.1114.1701. Hold off updating the other devices; its Downloads screen says what changed.")
    }

    @Test func theRoomReportCarriesItAndRefusesOddOnes() throws {
        let result = UpdateCheck.Result(from: "250", dropped: ["pins"], before: ["pins": 5], now: ["pins": 0])
        let report = PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [], update: result)
        #expect(try PhoneStorage.read(JSONEncoder().encode(report)) == report)
        for odd in [UpdateCheck.Result(from: "250", dropped: ["a typed name"], before: [:], now: [:]),
                    UpdateCheck.Result(from: "25<0", dropped: [], before: [:], now: [:]),
                    UpdateCheck.Result(from: "250", dropped: [], before: ["pins": -1], now: [:])] {
            let sent = try JSONEncoder().encode(PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [],
                                                             update: odd))
            #expect(throws: PhoneStorage.Problem.self) { try PhoneStorage.read(sent) }
        }
    }
}
