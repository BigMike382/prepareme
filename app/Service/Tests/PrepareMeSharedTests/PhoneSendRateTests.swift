import Foundation
import PrepareMeShared
import Testing

/// The two send-path fixes of 2026-11-18, found by inventory phase 2's review: the re-post storm (a waiting change
/// went to the Mac's inbox at every look once its first 30 seconds were over) and the stale edit base (an edit said
/// what the phone's copy held at Save, not what the form opened with).
struct PhoneSendRateTests {
    /// The phone looking every 3 seconds for 5 minutes with the Mac app closed (each post reaches the service, no
    /// answer comes): each waiting change goes at most once per 30 seconds, the first at once.
    @Test func eachWaitingChangeGoesAtMostOncePerThirtySeconds() {
        var outbox = PhoneOutbox()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (1...3).map { outbox.add(.adjust(row: Int64($0), by: -1), what: "used 1", now: start) }
        var sends: [String: [TimeInterval]] = [:]
        for second in stride(from: 0.0, through: 300, by: 3) {
            let now = start.addingTimeInterval(second)
            let sent = outbox.toSend(now: now).map(\.id)
            outbox.markSent(sent, now: now)
            for id in sent { sends[id, default: []].append(second) }
        }
        for id in ids {
            let times = sends[id] ?? []
            #expect(times.first == 0, "sent at once")
            #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= PhoneOutbox.resendAfter })
            #expect((10...11).contains(times.count), "about every 30 seconds, never at every look: \(times)")
        }
        #expect(outbox.awaitingAnswer)
    }

    /// The first send's time stays for "PrepareMe on the Mac needs to be open" (takenUnapplied), however often the
    /// change goes again.
    @Test func aRepeatSendKeepsTheFirstSendForTheMacClosedLine() {
        var outbox = PhoneOutbox()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        outbox.add(.adjust(row: 1, by: -1), what: "used 1", now: start)
        for second in stride(from: 0.0, through: 300, by: 30) {
            let now = start.addingTimeInterval(second)
            outbox.markSent(outbox.toSend(now: now).map(\.id), now: now)
        }
        let copy = PhoneInventory(writtenAt: ISO8601DateFormatter().string(from: start.addingTimeInterval(-3600)),
                                  columns: [], items: [], places: [], categories: [], headsUpDays: 60, toBuy: [],
                                  results: [:])
        #expect(outbox.takenUnapplied(copy: copy, lookedAt: start.addingTimeInterval(300)) == 1)
    }

    /// A change sent again that never reached the Mac waits its 30 seconds like any repeat; one a send marked first
    /// and that never reached the Mac goes at the next look, as before.
    @Test func neverReachedGoesAtTheNextLookOnlyWhenNeverSentBefore() {
        var outbox = PhoneOutbox()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = outbox.add(.adjust(row: 1, by: -1), what: "used 1", now: start)
        let marked = outbox.markSent([id], now: start)
        outbox.unsend(PhoneDelivery(notReached: [id]), marked: marked)
        #expect(outbox.toSend(now: start.addingTimeInterval(3)).map(\.id) == [id])
    }

    /// Save's cell change says what the form opened with: the Mac's 4, arrived while the form was open on 6, makes the
    /// phone's 5 say "expected 6", which the Mac refuses (PhoneTests.testAStalePhoneChangeIsRefused applies it).
    @Test func aCellChangeSaysWhatTheFormOpenedWith() {
        let change = PhoneEditRules.cellChange(row: 7, colId: "Quantity", value: .text("5"),
                                               opened: ["Quantity": .text("6")], latest: ["Quantity": .text("4")])
        #expect(change == .revert(table: "Inventory", row: 7, colId: "Quantity", value: .text("5"),
                                  expected: .text("6")))
        #expect(PhoneEditRules.cellChange(row: 7, colId: "Quantity", value: nil, opened: [:], latest: [:]) == nil,
                "a field not typed in sends nothing")
        #expect(PhoneEditRules.cellChange(row: 7, colId: "Quantity", value: .text("4"),
                                          opened: ["Quantity": .text("6")], latest: ["Quantity": .text("4")]) == nil,
                "the item holds it already: nothing to send")
        #expect(PhoneEditRules.cellChange(row: 7, colId: "Notes", value: .text("x"), opened: [:], latest: [:])
                == .revert(table: "Inventory", row: 7, colId: "Notes", value: .text("x"), expected: .null))
    }
}
