import Foundation
import PrepareMeShared
import Testing

/// Reading a package's best-by date (plan 2026-10-28, phase 1): each rule with its own cases, and the planted wrong
/// ones, each of which is refused or asked about, never filled.
struct PackageDateTests {
    let utc = TimeZone(identifier: "UTC")!
    let today = Date(timeIntervalSince1970: 1_793_404_800)  // 2026-10-31, UTC midnight

    func read(_ lines: [String]) -> PackageDate.Reading {
        PackageDate.read(lines, today: today, timeZone: utc)
    }

    func day(_ y: Int, _ m: Int, _ d: Int) -> PackageDate.Day { PackageDate.Day(year: y, month: m, day: d) }

    /// The one date read, with the card's words; nil for a choice or a refusal.
    func found(_ lines: [String]) -> PackageDate.Found? {
        if case .found(let found) = read(lines) { return found }
        return nil
    }

    @Test func todayIsTheDayTheTestsSay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        #expect(cal.dateComponents([.year, .month, .day], from: today) == DateComponents(year: 2026, month: 10, day: 31))
    }

    // Rule 1: a labeled line wins; a packed or lot line is never the expiry.

    @Test func everyLabelInAnyCaseOrPunctuation() {
        for label in ["BEST BY", "Best Before", "best if used by", "USE BY", "BB", "B.B.", "BBD", "EXP:", "Exp.",
                      "EXPIRES", "Expiry", "BEST-BY"] {
            let read = found(["\(label) 03/15/2027", "04/20/2027"])
            #expect(read?.day == day(2027, 3, 15), "\(label)")
            #expect(read?.labeled == true, "\(label)")
        }
    }

    @Test func aLabelRunTogetherWithTheDate() {
        #expect(found(["EXP03/2027"])?.day == day(2027, 3, 1))
        #expect(found(["BB15MAR27"])?.day == day(2027, 3, 15))
    }

    @Test func aLabelAloneLabelsTheNextLine() {
        let read = found(["BEST BY", "03/15/2027", "04/20/2027"])
        #expect(read?.day == day(2027, 3, 15))
        #expect(read?.labeled == true)
    }

    @Test func plantedPackedLineBesideABestByLine() {
        #expect(found(["PACKED 2026 01 10", "BEST BY 2027 03 15"])?.day == day(2027, 3, 15))
        #expect(found(["BEST BY 2027 03 15", "PACKED 2026 01 10"])?.day == day(2027, 3, 15))
    }

    @Test func plantedBBWithAPackedDateOnTheNextLine() {
        let read = found(["BB 15MAR27", "PACK 10JAN26"])
        #expect(read?.day == day(2027, 3, 15))
        #expect(read?.labeled == true)
    }

    @Test func plantedPackedOrMadeLinesAloneAreNeverTheExpiry() {
        for line in ["PACKED 01/10/2026", "PACK 10JAN26", "MFG 2026-01-10", "MFD 01/10/26", "PROD 01/10/26",
                     "MADE 01/10/2026", "LOT 01/10/26", "Packed on Jan 10 2026"] {
            #expect(read([line]) == .refused(PackageDate.nothingFound), "\(line)")
        }
    }

    @Test func aLabelAloneDoesNotReachIntoAPackedLine() {
        #expect(read(["BEST BY", "PACKED 01/10/2026"]) == .refused(PackageDate.nothingFound))
    }

    @Test func aWordThatOnlyContainsALabelIsNotOne() {
        // PRODUCT isn't PROD, and EXPORT isn't EXP: the date is read, unlabeled
        let read = found(["PRODUCT OF USA 03/15/2027"])
        #expect(read?.day == day(2027, 3, 15))
        #expect(read?.labeled == false)
        #expect(found(["EXPORT 03/15/2027"])?.labeled == false)
    }

    // Rule 2: the formats read, and bare digit runs not read.

    @Test func monthNames() {
        #expect(found(["BB MAR 15 2027"])?.day == day(2027, 3, 15))
        #expect(found(["BB Mar 15, 2027"])?.day == day(2027, 3, 15))
        #expect(found(["BB 15 MAR 2027"])?.day == day(2027, 3, 15))
        #expect(found(["BB 15MAR27"])?.day == day(2027, 3, 15))
        #expect(found(["BB 15-Mar-2027"])?.day == day(2027, 3, 15))
        #expect(found(["BB March 15 2027"])?.day == day(2027, 3, 15))
        #expect(found(["BB SEPT 5 2027"])?.day == day(2027, 9, 5))
        #expect(found(["BB 5 SEPTEMBER 2027"])?.day == day(2027, 9, 5))
    }

    @Test func numbersWithSeparators() {
        #expect(found(["BB 03/15/2027"])?.day == day(2027, 3, 15))
        #expect(found(["BB 03-15-27"])?.day == day(2027, 3, 15))
        #expect(found(["BB 2027-03-15"])?.day == day(2027, 3, 15))
        #expect(found(["BB 2027/03/15"])?.day == day(2027, 3, 15))
        #expect(found(["BB 15.03.2027"])?.day == day(2027, 3, 15))
        #expect(found(["BB 3/15/27"])?.day == day(2027, 3, 15))
    }

    @Test func plantedBareDigitRunsAreNotRead() {
        #expect(read(["031527"]) == .refused(PackageDate.nothingFound))
        #expect(read(["BEST BY 031527"]) == .refused(PackageDate.nothingFound))
        #expect(read(["26109"]) == .refused(PackageDate.nothingFound))
    }

    @Test func plantedLotCode() {
        #expect(read(["LOT 26109"]) == .refused(PackageDate.nothingFound))
        #expect(read(["LOT 26109", "BEST BY 03/15/2027"]) == .found(PackageDate.Found(day: day(2027, 3, 15),
                                                                                      labeled: true, monthOnly: false)))
    }

    @Test func aNotADayIsNotRead() {
        #expect(read(["BB 02/30/2027"]) == .refused(PackageDate.nothingFound))
        #expect(read(["BB 13/13/2027"]) == .refused(PackageDate.nothingFound))
    }

    @Test func otherNumbersOnALabelAreNotDates() {
        #expect(read(["NET WT 12 OZ (340 g)", "1-800-555-0100"]) == .refused(PackageDate.nothingFound))
        #expect(read(["$10.25", "2.5 OZ"]) == .refused(PackageDate.nothingFound), "dots only in a whole date")
    }

    // Rule 3: a two-digit year is 20xx.

    @Test func twoDigitYears() {
        #expect(found(["BB 03/15/27"])?.day == day(2027, 3, 15))
        #expect(found(["BB 15MAR40"])?.day == day(2040, 3, 15))
    }

    // Rule 4: day and month that can't be told apart ask.

    @Test func plantedDayAndMonthEitherWay() {
        guard case .choice(let first, let second, let question) = read(["BB 03/04/27"]) else {
            Issue.record("expected a choice")
            return
        }
        #expect(first.words == "March 4, 2027")
        #expect(second.words == "April 3, 2027")
        #expect(question == PackageDate.eitherWayRound)
    }

    @Test func aDayOver12SettlesTheOrder() {
        #expect(found(["BB 15/03/2027"])?.day == day(2027, 3, 15))
        #expect(found(["BB 03/15/2027"])?.day == day(2027, 3, 15))
    }

    @Test func theSameDayAndMonthNeedNoChoice() {
        #expect(found(["BB 04/04/27"])?.day == day(2027, 4, 4))
    }

    // Rule 5: month and year only takes the first of the month, and the card says so.

    @Test func monthAndYearOnly() {
        for line in ["BB MAR 2027", "BB MAR27", "BB 03/2027", "BB 03 27", "BB March 2027"] {
            let read = found([line])
            #expect(read?.day == day(2027, 3, 1), "\(line)")
            #expect(read?.monthOnly == true, "\(line)")
            #expect(read?.notes.contains(PackageDate.firstOfTheMonth) == true, "\(line)")
        }
    }

    // Rule 6: a date that can't be a best-by date is refused as a misread.

    @Test func plantedTooFarBackOrAhead() {
        #expect(read(["BEST BY 03/15/2019"]) == .refused(PackageDate.misread))
        #expect(read(["BEST BY 03/15/2090"]) == .refused(PackageDate.misread))
    }

    @Test func theEdgesOfTheRange() {
        #expect(found(["BB 10/31/2024"])?.day == day(2024, 10, 31), "2 years back to the day")
        #expect(read(["BB 10/30/2024"]) == .refused(PackageDate.misread))
        #expect(found(["BB 10/31/2056"])?.day == day(2056, 10, 31), "30 years ahead to the day")
        #expect(read(["BB 2056-11-01"]) == .refused(PackageDate.misread))
        #expect(found(["BB 2055"]) == nil, "a year alone isn't a date")
    }

    @Test func plantedEitherWayWithOneSideOutOfRangeIsNotFilled() {
        // November 1, 2056 is too far ahead and January 11, 2056 isn't: never kept as the one left
        #expect(read(["BB 11/01/2056"]) == .refused(PackageDate.misread))
    }

    @Test func aMisreadBesideAGoodDateLeavesTheGoodOne() {
        #expect(found(["BB 03/15/2090", "BB 03/15/2027"])?.day == day(2027, 3, 15))
    }

    // Rule 7: several dates.

    @Test func oneUnlabeledDateSaysToCheckIt() {
        let read = found(["03/15/2027"])
        #expect(read?.day == day(2027, 3, 15))
        #expect(read?.labeled == false)
        #expect(read?.notes == [PackageDate.noLabel])
    }

    @Test func aLabeledDateWinsOverUnlabeledOnes() {
        #expect(found(["01/10/2027", "EXP 03/15/2027", "05/20/2027"])?.day == day(2027, 3, 15))
    }

    @Test func twoDifferentLabeledDatesAsk() {
        guard case .choice(let first, let second, let question) = read(["BB 03/15/2027", "EXP 04/20/2027"]) else {
            Issue.record("expected a choice")
            return
        }
        #expect([first, second] == [day(2027, 3, 15), day(2027, 4, 20)])
        #expect(question == PackageDate.twoDates)
    }

    @Test func twoDifferentUnlabeledDatesAsk() {
        guard case .choice(let first, let second, _) = read(["03/15/2027", "04/20/2027"]) else {
            Issue.record("expected a choice")
            return
        }
        #expect([first, second] == [day(2027, 3, 15), day(2027, 4, 20)])
    }

    @Test func theSameDateTwiceIsOneDate() {
        #expect(found(["BB 03/15/2027", "BEST BY MAR 15 2027"])?.day == day(2027, 3, 15))
    }

    @Test func moreThanTwoDatesAreRefused() {
        #expect(read(["03/15/2027", "04/20/2027", "05/25/2027"]) == .refused(PackageDate.tooMany))
    }

    // Rule 8: nothing readable.

    @Test func nothingReadable() {
        #expect(read([]) == .refused(PackageDate.nothingFound))
        #expect(read(["NUTRITION FACTS", "Serving size 1 cup"]) == .refused(PackageDate.nothingFound))
        #expect(PackageDate.nothingFound == "Couldn't find a date. Move closer, or type it.")
    }

    // The confirm card's words.

    @Test func theCardsWords() {
        let read = found(["BEST BY 03/15/2027"])
        #expect(read?.headline == "Best by March 15, 2027")
        #expect(read?.notes == [])
        #expect(found(["MAR 2027"])?.notes == [PackageDate.noLabel, PackageDate.firstOfTheMonth])
        #expect(PackageDate.noLabel == "No 'best by' printed next to it: check it's the right date.")
        #expect(PackageDate.useThisDate == "Use this date")
        #expect(PackageDate.tryAgain == "Try again")
    }
}
