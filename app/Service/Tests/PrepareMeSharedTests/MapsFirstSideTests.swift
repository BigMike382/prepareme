@testable import PrepareMeShared
import XCTest

/// Which side Maps opens on (beta run 2, B2-22) and how the street map's round buttons wrap (B2-23).
final class MapsFirstSideTests: XCTestCase {
    func testAChildsPhoneOpensOnTheStreetMapWhenNothingWasChosen() {
        XCTAssertEqual(MapsFirstSide.pane(stored: nil, isChild: true), .street)
    }

    func testAnAdultsPhoneOpensOnFindAMapWhenNothingWasChosen() {
        XCTAssertEqual(MapsFirstSide.pane(stored: nil, isChild: false), .find)
    }

    func testAChosenSideIsKeptForAnAdult() {
        XCTAssertEqual(MapsFirstSide.pane(stored: "street", isChild: false), .street)
        XCTAssertEqual(MapsFirstSide.pane(stored: "find", isChild: false), .find)
    }

    func testAChildCanStillPickFindAMapAndItStays() {
        XCTAssertEqual(MapsFirstSide.pane(stored: "find", isChild: true), .find)
    }

    func testAnUnknownStoredWordFallsBackToTheDefault() {
        XCTAssertEqual(MapsFirstSide.pane(stored: "nonsense", isChild: true), .street)
        XCTAssertEqual(MapsFirstSide.pane(stored: "nonsense", isChild: false), .find)
    }

    func testRetappingMapsGoesToTheChildsStreetMapAndAnAdultsFindAMap() {
        XCTAssertEqual(MapsFirstSide.retap(isChild: true), .street)
        XCTAssertEqual(MapsFirstSide.retap(isChild: false), .find)
    }

    // The buttons: five, each about 62 wide (the circle and its word), 4 apart.
    func testFiveButtonsOnAnSEWrapIntoTwoRows() {
        let widths = Array(repeating: 62.0, count: 5)  // 5 x 62 + 4 x 4 = 326, more than the 300 left
        let rows = ButtonRows.split(widths: widths, spacing: 4, available: 300)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.flatMap { $0 }, [0, 1, 2, 3, 4])
        XCTAssertTrue(rows.allSatisfy { row in
            Double(row.count) * 62 + Double(row.count - 1) * 4 <= 300
        })
    }

    func testRoomEnoughKeepsOneRow() {
        let rows = ButtonRows.split(widths: Array(repeating: 62.0, count: 5), spacing: 4, available: 400)
        XCTAssertEqual(rows, [[0, 1, 2, 3, 4]])
    }

    func testAWideButtonIsNeverDroppedEvenWhenItAloneIsTooWide() {
        let rows = ButtonRows.split(widths: [80, 500, 80], spacing: 4, available: 200)
        XCTAssertEqual(rows.flatMap { $0 }, [0, 1, 2])
    }

    /// R6.2 minor (checkpoint 3): the width the measure reports comes back to placement rounded (a layout pass can
    /// hand it a hair less), and float sums of the buttons' widths can come out a hair over; neither may add a row.
    func testPlacementAtTheMeasuredWidthLessAHairKeepsTheRows() {
        let widths = [62.1, 62.2, 62.3, 61.7]
        let measured = ButtonRows.size(widths: widths, heights: Array(repeating: 66.0, count: 4), spacing: 4,
                                       available: 400).width
        XCTAssertEqual(ButtonRows.split(widths: widths, spacing: 4, available: measured - 0.25).count, 1)
        XCTAssertEqual(ButtonRows.split(widths: [62.1, 62.2], spacing: 0, available: 124.3).count, 1,
                       "62.1 + 62.2 sums to 124.30000000000001: still 124.3")
        XCTAssertEqual(ButtonRows.split(widths: widths, spacing: 4, available: measured - 1).count, 2,
                       "a whole point short is a real shortfall")
    }

    func testNoButtonsNoRows() {
        XCTAssertEqual(ButtonRows.split(widths: [], spacing: 4, available: 300), [])
    }

    // One side per launch (fix round 1)
    func testAChildsStoredSideIsIgnoredAtLaunch() {
        var state = MapsSideState()
        XCTAssertEqual(state.resolve(stored: "find", isChild: true), .street)
    }

    func testAnAdultsPickedSideIsKeptAtLaunch() {
        var state = MapsSideState()
        XCTAssertEqual(state.resolve(stored: "street", isChild: false), .street)
    }

    func testTheSideIsNotSwappedLaterInTheRunWhenTheRoleBecomesKnown() {
        var state = MapsSideState()
        XCTAssertEqual(state.resolve(stored: nil, isChild: true), .street)  // not yet known: a child's
        XCTAssertEqual(state.resolve(stored: nil, isChild: false), .street)  // the adult answer arrives: no swap
    }

    // B3-04: the role arriving after pairing, in one session
    func testAnAdultsPhonePairedBeforeItsRoleWasKnownOpensOnFindAMapTheNextTimeMapsOpens() {
        var state = MapsSideState()
        XCTAssertEqual(state.resolve(stored: nil, isChild: true), .street)  // role unknown: the child's rule holds
        XCTAssertEqual(state.resolve(stored: nil, isChild: false), .street)  // while Maps is shown, no swap
        XCTAssertTrue(state.reopen(stored: nil, isChild: false))  // Maps opened again: the adult answer is in
        XCTAssertEqual(state.side, .find)
    }

    func testReopeningWithTheRoleStillUnknownChangesNothing() {
        var state = MapsSideState()
        _ = state.resolve(stored: nil, isChild: true)
        XCTAssertFalse(state.reopen(stored: nil, isChild: true))
        XCTAssertEqual(state.side, .street)
    }

    func testAnAdultsStoredSideIsUsedWhenTheRoleArrives() {
        var state = MapsSideState()
        _ = state.resolve(stored: "street", isChild: true)
        // the adult had chosen the street map: same side
        XCTAssertFalse(state.reopen(stored: "street", isChild: false))
        XCTAssertEqual(state.side, .street)
    }

    func testASidePickedInTheSessionIsNeverSwappedByTheRole() {
        var state = MapsSideState()
        _ = state.resolve(stored: nil, isChild: true)
        state.pick(.find)
        XCTAssertFalse(state.reopen(stored: nil, isChild: false))
        XCTAssertEqual(state.side, .find)
        var other = MapsSideState()
        _ = other.resolve(stored: nil, isChild: false)
        other.pick(.street)
        XCTAssertFalse(other.reopen(stored: nil, isChild: true))
        XCTAssertEqual(other.side, .street)
    }

    func testAnAdultPhoneTheMacCallsAChildMovesToTheStreetMapNextTimeMapsOpens() {
        var state = MapsSideState()
        XCTAssertEqual(state.resolve(stored: nil, isChild: false), .find)
        XCTAssertTrue(state.reopen(stored: "find", isChild: true))  // a child's stored side is ignored
        XCTAssertEqual(state.side, .street)
    }

    func testReopenBeforeAnySideWasSettledDoesNothing() {
        var state = MapsSideState()
        XCTAssertFalse(state.reopen(stored: nil, isChild: false))
        XCTAssertNil(state.side)
    }

    func testAPageOpenedInMapsMovesAChildToFindAMapOnlyForTheRun() {
        var state = MapsSideState()
        _ = state.resolve(stored: nil, isChild: true)
        state.pick(.find)  // a topo map opened from a link
        XCTAssertEqual(state.resolve(stored: "find", isChild: true), .find)
        var next = MapsSideState()  // the next launch: the stored side is ignored for a child
        XCTAssertEqual(next.resolve(stored: "find", isChild: true), .street)
    }

    // ButtonWrap's measure: the rows it reports
    func testWrappedSizeIsTwoRowsHighAndAsWideAsTheWidestRow() {
        let size = ButtonRows.size(widths: Array(repeating: 62.0, count: 5), heights: Array(repeating: 66.0, count: 5),
                                   spacing: 4, available: 300)
        XCTAssertEqual(size.height, 66 * 2 + 4)
        XCTAssertEqual(size.width, 62 * 4 + 4 * 3)  // four to a row
    }

    // S4.1 (B2-23): the rally strip folds on a narrow phone only
    func testTheStripFoldsOnAnSEAndAnythingNarrower() {
        XCTAssertTrue(StripFold.folded(width: 375, height: 667))  // iPhone SE
        XCTAssertTrue(StripFold.folded(width: 320, height: 568))
    }

    func testTheStripStaysWholeOnWiderPhonesAndTheiPad() {
        XCTAssertFalse(StripFold.folded(width: 390, height: 844))
        XCTAssertFalse(StripFold.folded(width: 440, height: 956))  // a Pro Max
        XCTAssertFalse(StripFold.folded(width: 834, height: 1194))  // an iPad
    }

    func testTheStripFoldsOnAPhoneOnItsSide() {
        XCTAssertTrue(StripFold.folded(width: 844, height: 390))
        XCTAssertFalse(StripFold.folded(width: 1194, height: 834))  // an iPad on its side
    }

    func testTheNameIsAlwaysReadAndTheDarkCautionIsNotHiddenByTheFold() {
        XCTAssertEqual(StripFold.spoken(name: "Oak Park", brief: "0.4 miles northeast", afterDark: false),
                       "Oak Park, 0.4 miles northeast")
        XCTAssertEqual(StripFold.spoken(name: "Oak Park", brief: nil, afterDark: false), "Oak Park")
        XCTAssertTrue(StripFold.spoken(name: "Oak Park", brief: "0.4 miles northeast", afterDark: true)
            .hasSuffix("you would arrive after dark"))
        XCTAssertEqual(StripFold.spoken(name: "Oak Park", brief: "0.4 miles northeast", afterDark: false,
                                        offRoute: "Off route by 300 feet, head west"),
                       "Oak Park, 0.4 miles northeast, Off route by 300 feet, head west", "the fold never hides it (W9)")
    }

    func testTheFoldControlsWords() {
        XCTAssertEqual(StripFold.more, "More")
        XCTAssertEqual(StripFold.less, "Less")
    }
}
