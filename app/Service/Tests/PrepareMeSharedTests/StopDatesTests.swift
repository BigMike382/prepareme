import Foundation
import Testing
@testable import PrepareMeShared

/// Over-the-air plan, phase 3, layer 5: the rows of Dates that can stop PrepareMe.
struct StopDatesTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-14T15:30:00Z")!

    func iso(_ days: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(days * 86400)) }

    @Test func everyRowIsListedAndADate50DaysOutIsAmber() throws {
        let jobs = Data(#"{"at": "\#(iso(0))", "developer_id": "\#(iso(50.5))", "apple_development": "\#(iso(333))"}"#.utf8)
        let phone = PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [], opensUntil: iso(85),
                                 build: "2026.1109.1530", channel: "testflight")
        let rows = StopDates.rows(devices: [("Mike's iPhone", phone), ("A new iPad", nil)],
                                  renewal: now.addingTimeInterval(200 * 86400), jobs: jobs, now: now)
        #expect(rows.map(\.what) == ["Mike's iPhone (TestFlight)", "A new iPad", "Apple Developer Program renewal",
                                     "Developer ID certificate (the Mac install)",
                                     "Apple Development certificate (cable installs)", "Upload signing",
                                     "App Store Connect API key", "The kept cable installer"])
        let developerID = rows[3]
        #expect(developerID.caution && developerID.when.hasSuffix("(50 days)"))
        #expect(!rows[0].caution && !rows[2].caution && !rows[4].caution)
        #expect(rows[1].when == "Not reported yet")
        #expect(rows[7].when == "None kept yet: the monthly installer job makes it" && rows[7].caution)
        #expect(rows[5].when == "Cloud signing: no certificate, no date" && !rows[5].caution)   // phase 4
        // the Mac's table: soonest first (50, 85, 200, 333 days), then the undated rows in their order
        #expect(StopDates.soonestFirst(rows).map(\.days) == [50, 85, 200, 333, nil, nil, nil, nil])
        #expect(StopDates.soonestFirst(rows).suffix(4).map(\.what) == ["A new iPad", "Upload signing",
                                                                      "App Store Connect API key",
                                                                      "The kept cable installer"])
    }

    /// The cable clock: a cable device and the kept installer are amber at six months; the other dates keep 60 days
    @Test func cableDatesAreAmberAtSixMonths() throws {
        let jobs = Data(#"{"at": "\#(iso(0))", "apple_development": "\#(iso(150.5))", "installer": "\#(iso(150.5))"}"#.utf8)
        let cable = PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [], opensUntil: iso(150.5))
        let rows = StopDates.rows(devices: [("An iPad", cable)], renewal: now.addingTimeInterval(150.5 * 86400),
                                  jobs: jobs, now: now)
        #expect(rows[0].what == "An iPad (cable)" && rows[0].caution)
        #expect(!rows[1].caution && !rows[3].caution, "the renewal and the certificate keep 60 days")
        #expect(rows[6].what == "The kept cable installer" && rows[6].caution && rows[6].days == 150)
        let after = iso(Double(PhoneStorage.cableRenewDays) + 1.5)
        let later = Data(#"{"at": "\#(iso(0))", "installer": "\#(after)"}"#.utf8)
        #expect(!StopDates.rows(devices: [], renewal: nil, jobs: later, now: now)[5].caution)
    }

    @Test func beforeTheHourlyCheckAndBeforeTheDateIsTyped() {
        let rows = StopDates.rows(devices: [], renewal: nil, jobs: nil, now: now)
        #expect(rows[0].when == "Not typed yet" && rows[0].caution)  // its date box is in its row (owner, 2026-11-14)
        #expect(rows[0].what == StopDates.renewalWhat)
        #expect(rows[1].when == "Not read yet: the hourly check reads it")
    }

    @Test func theRenewalRoundTripsAsTheMacsDay() throws {
        let day = try #require(StopDates.renewal(Data(#"{"renewal": "2027-03-01"}"#.utf8)))
        #expect(StopDates.renewal(StopDates.renewalData(day)) == day)
        #expect(String(decoding: StopDates.renewalData(day), as: UTF8.self) == #"{"renewal": "2027-03-01"}"#)
        #expect(StopDates.renewal(Data("junk".utf8)) == nil)
    }
}
