import Foundation
import Testing
@testable import PrepareMeShared

/// Over-the-air plan, phase 2, layer 3: a TestFlight build's end, its warnings' days and words; a cable install's stay.
struct TestFlightBuildTests {
    let built = ISO8601DateFormatter().date(from: "2026-11-14T15:30:00Z")!

    @Test func aTestFlightBuildEnds90DaysAfterItsStampAndNeverAfterItsProfile() throws {
        let ends = try #require(InstallExpiry.end(channel: "testflight", built: built, profile: nil))
        #expect(ends == built.addingTimeInterval(90 * 86400))
        let sooner = built.addingTimeInterval(30 * 86400)
        #expect(InstallExpiry.end(channel: "testflight", built: built, profile: sooner) == sooner)
    }

    @Test func aCableInstallKeepsItsProfilesDate() {
        let profile = built.addingTimeInterval(365 * 86400)
        #expect(InstallExpiry.end(channel: nil, built: built, profile: profile) == profile)
        #expect(InstallExpiry.end(channel: "", built: built, profile: profile) == profile)
        #expect(InstallExpiry.end(channel: "testflight", built: nil, profile: profile) == profile, "no stamp: the profile")
        #expect(InstallExpiry.end(channel: nil, built: nil, profile: nil) == nil)
    }

    @Test func theStampReadsAndAnEmptyOneIsNone() {
        #expect(InstallExpiry.built("2026-11-14T15:30:00Z") == built)
        #expect(InstallExpiry.built("") == nil)
        #expect(InstallExpiry.built(nil) == nil)
        #expect(InstallExpiry.daysOld(built, now: built.addingTimeInterval(21.5 * 86400)) == 21)
        #expect(InstallExpiry.daysOld(built, now: built.addingTimeInterval(-86400)) == 0)
    }

    @Test func noticeDaysByChannel() {
        #expect(InstallExpiry.noticeDays(channel: "testflight") == [30, 14, 7, 3, 1])
        #expect(InstallExpiry.noticeDays(channel: nil) == [60, 30, 14, 7, 1])
    }

    @Test func theWords() {
        #expect(HomeMacWords.testflightLine(until: "February 12, 2027", days: 87)
                == "This build opens until February 12, 2027 (87 days). It updates itself through TestFlight.")
        let stale = HomeMacWords.notUpdated(days: 21)
        #expect(stale == "PrepareMe hasn't updated itself for 3 weeks. Tap Update, then PrepareMe, then Update.")
        #expect(!stale.contains("build"), "never the word build in the family's sentence")
        #expect(HomeMacWords.notUpdated(days: 34).contains("for 4 weeks"))
        #expect(HomeMacWords.testflightWarning(until: "Line.", device: "iPad").hasSuffix("Files › On My iPad › PrepareMe."))
        #expect(HomeMacWords.endNotice(days: 1, testflight: true) == "PrepareMe opens for 1 more day. Open it and tap Update.")
        #expect(HomeMacWords.endNotice(days: 60, testflight: false).hasPrefix("This install opens for 60 more days."))
    }

    @Test func theRoomReportCarriesTheBuildAndChannelAndRefusesOddOnes() throws {
        let report = PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [], build: "2026.1114.1530",
                                  channel: "testflight")
        let sent = try JSONEncoder().encode(report)
        #expect(try PhoneStorage.read(sent) == report)
        let older = Data(#"{"free":1,"capacity":2,"held":[],"waiting":[],"cant_update":[]}"#.utf8)
        #expect(try PhoneStorage.read(older).build == nil)
        for odd in [#""build":"2026<script>""#, #""build":"""#, #""channel":"future""#, #""channel":"AppStore""#] {
            let data = Data(#"{"free":1,"capacity":2,"held":[],"waiting":[],"cant_update":[],\#(odd)}"#.utf8)
            #expect(throws: PhoneStorage.Problem.self) { try PhoneStorage.read(data) }
        }
    }
}

/// Over-the-air plan, phase 3, layer 4: the Mac's Phones list line for a TestFlight phone.
struct TestFlightPhonesListTests {
    let built = ISO8601DateFormatter().date(from: "2026-11-14T15:30:00Z")!

    func report(build: String = "2026.1114.1530", channel: String? = "testflight") -> PhoneStorage {
        PhoneStorage(free: 1, capacity: 2, held: [], waiting: [], cantUpdate: [],
                     opensUntil: ISO8601DateFormatter().string(from: built.addingTimeInterval(90 * 86400)),
                     build: build, channel: channel)
    }

    @Test func theBuildNumberReadsAsItsUTCTime() {
        #expect(InstallExpiry.buildDate("2026.1114.1530") == built)
        #expect(InstallExpiry.buildDate("2027.101.5") == ISO8601DateFormatter().date(from: "2027-01-01T00:05:00Z"))
        for odd in ["2026.1114", "2026.1314.1530", "2026.1131.1200", "2026.1114.2460", "1.2.3.4", "", nil] as [String?] {
            #expect(InstallExpiry.buildDate(odd) == nil, "\(odd ?? "nil")")
        }
    }

    @Test func aFreshBuildNamesItselfAndIsNotAmber() throws {
        let line = try #require(report().installLine(now: built.addingTimeInterval(5 * 86400)))
        #expect(line.text.hasPrefix("Build 2026.1114.1530, TestFlight, opens until "))
        #expect(!line.caution)
    }

    @Test func aBuild21DaysOldIsAmberWithTheSentence() throws {
        let line = try #require(report().installLine(now: built.addingTimeInterval(21 * 86400 + 60)))
        #expect(line.caution)
        #expect(line.text.hasSuffix("it hasn't updated itself for 3 weeks."))
        let day20 = try #require(report().installLine(now: built.addingTimeInterval(20 * 86400)))
        #expect(!day20.caution, "a TestFlight phone is not amber at 60 days left, as a cable one is")
    }

    @Test func a30DayEndIsAmberWithoutAStaleBuild() throws {
        // An older build number with a profile end 25 days away: the end, not the age, makes it amber
        var short = report(build: "2026.1201.900")
        short.opensUntil = ISO8601DateFormatter().string(from: built.addingTimeInterval(45 * 86400))
        let line = try #require(short.installLine(now: built.addingTimeInterval(20 * 86400)))
        #expect(line.caution)
        #expect(line.text.contains("stops opening on"))
    }

    @Test func aCablePhoneKeepsItsLine() throws {
        let line = try #require(report(channel: nil).installLine(now: built.addingTimeInterval(35 * 86400)))
        #expect(line.text.hasPrefix("Its install stops opening on"))
        #expect(line.caution)
    }
}

/// Unlisted plan, phase 5: the Mac reads a store phone's report and shows it with no end date (the Mac first).
struct StorePhoneOnTheMacTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/store-phone-report.json")

    @Test func theMacReadsAStorePhonesReport() throws {
        let report = try PhoneStorage.read(Data(contentsOf: Self.fixture))
        #expect(report.channel == InstallExpiry.appstore && report.opensUntil == nil && report.build == "2027.115.1530")
    }

    @Test func itsInstallLineHasNoEndAndIsNeverAmber() throws {
        var report = try PhoneStorage.read(Data(contentsOf: Self.fixture))
        let line = try #require(report.installLine())
        #expect(line.text == "From the App Store: no end date." && !line.caution)
        // even if a date came with it, a store copy's line names none
        report.opensUntil = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))
        #expect(report.installLine()?.text == PhoneStorage.storeLine)
        #expect(report.installLine()?.caution == false)
    }

    @Test func itsDatesRowSaysNoEndDateAndSortsWithTheUndated() throws {
        let report = try PhoneStorage.read(Data(contentsOf: Self.fixture))
        let rows = StopDates.rows(devices: [("A spare iPhone", report)], renewal: Date().addingTimeInterval(90 * 86400),
                                  jobs: nil)
        #expect(rows[0] == StopDates.Row(what: "A spare iPhone (App Store)", when: "No end date", caution: false))
        #expect(StopDates.soonestFirst(rows).first?.what == StopDates.renewalWhat)
    }
}

/// Unlisted plan, phase 5: the app knows a store copy by how it was installed, not only by its stamp.
struct StoreCopyRuleTests {
    @Test func onlyOneOfEighteenCombinationsIsAStoreCopy() {
        var stores: [String] = []
        for stamp in ["appstore", "testflight", nil] as [String?] {
            for hasProfile in [true, false] {
                for receipt in ["receipt", "sandboxReceipt", nil] as [String?] {
                    let row = "\(stamp ?? "none"), profile \(hasProfile), \(receipt ?? "none")"
                    let store = InstallExpiry.isStoreCopy(stamp: stamp, hasProfile: hasProfile, receipt: receipt)
                    let channel = InstallExpiry.channel(stamp: stamp, hasProfile: hasProfile, receipt: receipt)
                    if store { stores.append(row) }
                    // never a hidden end: everything stamped that isn't a store copy is TestFlight; unstamped is cable
                    let wanted = store ? "appstore" : stamp == nil ? nil : "testflight"
                    #expect(channel == wanted, "\(row)")
                }
            }
        }
        #expect(stores == ["appstore, profile false, receipt"])
    }

    @Test func aStoreCopyHasNoEndAndNoNotices() {
        let built = ISO8601DateFormatter().date(from: "2027-01-15T15:30:00Z")!
        #expect(InstallExpiry.end(channel: "appstore", built: built, profile: built) == nil)
        #expect(InstallExpiry.noticeDays(channel: "appstore").isEmpty)
        // the same build through TestFlight keeps its 90 days
        #expect(InstallExpiry.end(channel: "testflight", built: built, profile: nil) == built.addingTimeInterval(90 * 86400))
        #expect(HomeMacWords.storeLine == "From the App Store. It doesn't expire.")
        #expect(!HomeMacWords.storeLine.contains("TestFlight") && !HomeMacWords.storeLine.contains("Update"))
    }
}
