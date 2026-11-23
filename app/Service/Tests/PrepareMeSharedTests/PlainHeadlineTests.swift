@testable import PrepareMeShared
import XCTest

/// The phone's plain headlines and signature rule (remaining-findings plan, Task 8.1; F09, owner 2026-10-18), the
/// counterparts of dashboard/tests/test_weather.py's PlainHeadlineTest: the same inputs, the same words.
final class PlainHeadlineTests: XCTestCase {
    func testAnAlertHeadlineInSentenceCase() {
        XCTAssertEqual(NWSTidy.alertHeadline("Tornado Warning", vtec: ["NEW.KLWX.TO.W.0012"]), "Tornado Warning")
        XCTAssertEqual(NWSTidy.alertHeadline("...x...", vtec: ["NEW.KCHS.CF.Y.0038", "CON.KCHS.SU.Y.0003",
                                                               "CON.KCHS.RP.S.0009", "CAN.KCHS.SU.Y.0003"]),
                       "Coastal Flood Advisory, High Surf Advisory, Rip Current Statement")
        XCTAssertEqual(NWSTidy.alertHeadline("...FLASH FLOOD WARNING FOR EXAMPLE COUNTY UNTIL 145 PM EDT...", vtec: []),
                       "Flash Flood Warning for Example County until 1:45 PM EDT")
        XCTAssertEqual(NWSTidy.alertHeadline("...ROAD WORK NEAR I-40 UNTIL 6 PM...", vtec: ["NEW.KLWX.ZZ.Y.0001"]),
                       "Road work near I-40 until 6 PM")
        XCTAssertEqual(NWSTidy.sentenceCase("...HIGH SURF ADVISORY REMAINS IN EFFECT UNTIL 2 PM EDT WEDNESDAY..."),
                       "High Surf Advisory remains in effect until 2 PM EDT Wednesday")
        XCTAssertEqual(NWSTidy.sentenceCase("...ZQX-2 WARNING..."), "ZQX-2 warning")
        XCTAssertEqual(NWSTidy.sentenceCase("High wind on Tuesday"), "High wind on Tuesday")
        XCTAssertEqual(NWSTidy.codeName("FW.W"), "Red Flag Warning")
    }

    func testTheTropicalOutlookLeadsWithAPlainLine() {
        XCTAssertEqual(NWSTidy.tropicalHeadline("Tropical cyclone formation is not expected during the next 7 days."),
                       "No Atlantic storms expected in the next 7 days.")
        XCTAssertEqual(NWSTidy.tropicalHeadline("* Formation chance through 7 days...high...90 percent."),
                       "A storm could form in the Atlantic in the next 7 days.")
    }

    func testServiceMarkersNeverShow() {
        let text = "000\nWWUS52 KLWX 061200\nTORLWX\n\nTornado Warning\nNational Weather Service Baltimore/Washington\n\n"
            + "ZZC183-061300-\n/O.NEW.KLWX.TO.W.0012.261006T1200Z-261006T1300Z/\n\nTake cover now.\n\n$$\n\n"
            + "Forecaster Made-up\n"
        let tidied = NWSTidy.tidy(text)
        for marker in ["$$", "WWUS52", "TORLWX", "ZZC183", "/O.NEW", "Forecaster"] {
            XCTAssertFalse(tidied.contains(marker), marker)
        }
        XCTAssertTrue(tidied.contains("Take cover now."))
        XCTAssertTrue(NWSTidy.tidy("Line one.\n\n$$\n\nThe next segment of the product holds 2 more sentences. Here.")
            .contains("The next segment"))
    }
}
