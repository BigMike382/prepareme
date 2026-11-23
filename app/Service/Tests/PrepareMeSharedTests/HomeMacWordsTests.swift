import Foundation
import PrepareMeShared
import XCTest

/// Home Mac's words for each file and the pairing line (the beta run's F03 and F40; plan Task 2.1): what the phone
/// knows, never "Up to date" when it couldn't check, and plain names, never a file name or a machine date.
final class HomeMacWordsTests: XCTestCase {
    let zone = TimeZone(identifier: "America/New_York")!
    let now = ISO8601DateFormatter().date(from: "2026-10-16T15:12:00-04:00")!
    let checked = ISO8601DateFormatter().date(from: "2026-10-16T11:12:00-04:00")!

    func entry(_ name: String, kind: String = "library", asOf: String? = "2026-10-06T08:41-04:00",
               title: String? = nil) -> Manifest.Entry {
        Manifest.Entry(name: name, id: "0f1e2d3c-4b5a-4968-8776-000000000001", kind: kind, size: 100,
                       sha256: String(repeating: "a", count: 64), deliveredAt: "2026-10-16T11:12:10-04:00",
                       libraryAsOf: asOf, title: title)
    }

    func words(_ entry: Manifest.Entry, _ check: HomeMacWords.CheckResult, current: Bool = true) -> String {
        HomeMacWords.status(entry: entry, current: current, check: check, now: now, timeZone: zone)
    }

    func testAnsweredAndCurrentSaysSameAsTheMacsWithItsAge() {
        XCTAssertEqual(words(entry("prepareme-daily.zim"), .answered(checked)),
                       "Same as the Mac's copy (checked 11:12 AM). Made Oct 6.")
    }

    func testACheckOnAnotherDayGivesTheDay() {
        let earlier = ISO8601DateFormatter().date(from: "2026-10-14T09:05:00-04:00")!
        XCTAssertEqual(words(entry("prepareme-daily.zim"), .answered(earlier)),
                       "Same as the Mac's copy (checked Oct 14 at 9:05 AM). Made Oct 6.")
    }

    func testMacNotFoundNeverSaysUpToDate() {
        XCTAssertEqual(words(entry("prepareme-daily.zim"), .notFound),
                       "This phone's copy, made Oct 6. Couldn't check with the Mac just now.")
        XCTAssertEqual(words(entry("prepareme-daily.zim"), .failed("the Mac answered with an error")),
                       "This phone's copy, made Oct 6. Couldn't check with the Mac just now.")
    }

    /// Phase K's drills, finding 3: away from home, Home Mac says when the phone last reached the Mac (its record's
    /// checkedAt); never reached, the line as before; a problem other than not found keeps its line
    func testMacNotFoundSaysWhenItLastReachedTheMac() {
        func away(_ reached: String?, device: String = "phone") -> String {
            HomeMacWords.status(entry: entry("prepareme-daily.zim"), current: true, check: .notFound, now: now,
                                timeZone: zone, device: device,
                                lastReached: reached.map { ISO8601DateFormatter().date(from: $0)! })
        }
        XCTAssertEqual(away("2026-10-16T08:00:00-04:00"),
                       "This phone's copy, made Oct 6. Couldn't reach the Mac; last reached today.")
        XCTAssertEqual(away("2026-10-15T22:30:00-04:00"),
                       "This phone's copy, made Oct 6. Couldn't reach the Mac; last reached Oct 15 (1 day ago).")
        XCTAssertEqual(away("2026-09-16T09:00:00-04:00", device: "iPad"),
                       "This iPad's copy, made Oct 6. Couldn't reach the Mac; last reached Sep 16 (30 days ago).")
        XCTAssertEqual(away(nil), "This phone's copy, made Oct 6. Couldn't check with the Mac just now.")
        XCTAssertEqual(away("2025-10-16T09:00:00-04:00"),
                       "This phone's copy, made Oct 6. Couldn't reach the Mac; last reached Oct 16, 2025 (365 days "
                       + "ago).")
        XCTAssertEqual(HomeMacWords.status(entry: entry("prepareme-daily.zim"), current: true,
                                           check: .failed("the Mac answered with an error"), now: now, timeZone: zone,
                                           lastReached: checked),
                       "This phone's copy, made Oct 6. Couldn't check with the Mac just now.")
    }

    func testRemovedPhoneSaysTheMacNoLongerSends() {
        XCTAssertEqual(words(entry("prepareme-daily.zim"), .removed),
                       "This phone's copy, made Oct 6. The Mac no longer sends to this phone.")
    }

    /// An iPad says "iPad" where a phone says "phone" (ThisDevice, 2026-10-18).
    func testAnIPadSaysIPad() {
        XCTAssertEqual(HomeMacWords.status(entry: entry("prepareme-daily.zim"), current: true, check: .removed,
                                           now: now, timeZone: zone, device: "iPad"),
                       "This iPad's copy, made Oct 6. The Mac no longer sends to this iPad.")
        XCTAssertEqual(HomeMacWords.pairedLine(host: "Home-Mac.local", removed: true, device: "iPad"),
                       "Was paired with Home-Mac; the Mac no longer knows this iPad. Pair it again at home.")
    }

    func testNeverChecked() {
        XCTAssertEqual(words(entry("prepareme-daily.zim"), .never),
                       "This phone's copy, made Oct 6. Not checked with the Mac yet.")
    }

    func testWithoutTheLibrarysOwnTimeItSaysWhenItWasMade() {
        XCTAssertEqual(words(entry("prepareme-daily.zim", asOf: nil), .answered(checked)),
                       "Same as the Mac's copy (checked 11:12 AM). Made Oct 16.")
    }

    func testStreetMapSaysItsDataDateInPlainWords() {
        // the packer writes the street map's data date as a bare day (packer/streetmap.py's built; phase 2 review)
        let map = entry("prepareme-street-map.pmtiles", kind: "map", asOf: "2026-10-16", title: "Street map")
        XCTAssertEqual(words(map, .answered(checked)),
                       "Same as the Mac's copy (checked 11:12 AM). OpenStreetMap as of Oct 16.")
        XCTAssertEqual(words(map, .notFound),
                       "This phone's copy, OpenStreetMap as of Oct 16. Couldn't check with the Mac just now.")
    }

    func testABareDayIsThatDayWhereverThePhoneIs() {
        let west = TimeZone(identifier: "America/Los_Angeles")!
        let map = entry("prepareme-street-map.pmtiles", kind: "map", asOf: "2026-10-14", title: "Street map")
        XCTAssertEqual(HomeMacWords.status(entry: map, current: true, check: .notFound, now: now, timeZone: west),
                       "This phone's copy, OpenStreetMap as of Oct 14. Couldn't check with the Mac just now.")
    }

    func testAnUnreadableDateLeavesTheAgeOut() {
        XCTAssertEqual(words(entry("prepareme-daily.zim", asOf: "soon"), .answered(checked)),
                       "Same as the Mac's copy (checked 11:12 AM).")
        XCTAssertEqual(words(entry("prepareme-daily.zim", asOf: "soon"), .notFound),
                       "This phone's copy. Couldn't check with the Mac just now.")
    }

    func testACheckInAnotherYearGivesTheYear() {
        let lastYear = ISO8601DateFormatter().date(from: "2025-10-14T09:05:00-04:00")!
        XCTAssertEqual(words(entry("prepareme-daily.zim"), .answered(lastYear)),
                       "Same as the Mac's copy (checked Oct 14, 2025 at 9:05 AM). Made Oct 6.")
    }

    func testAnotherYearShowsTheYear() {
        XCTAssertEqual(words(entry("prepareme-daily.zim", asOf: "2025-12-30T08:00-05:00"), .answered(checked)),
                       "Same as the Mac's copy (checked 11:12 AM). Made Dec 30, 2025.")
    }

    func testNoFileNamesOrMachineDates() {
        let names = ["prepareme-daily.zim", "prepareme-reference.zim", "prepareme-media.zim", "prepareme-vehicles.zim",
                     "prepareme-item-manuals.zim", "prepareme-maps-roads.zim", "prepareme-maps-updates.zim",
                     "prepareme-maps-reading.zim",
                     "prepareme-maps-home-topo.zim", "prepareme-maps-home.zim", "prepareme-maps-routes.zim",
                     "prepareme-maps-topo-overview.zim", "prepareme-maps-topo-today-3.zim",
                     "prepareme-maps-topo-older-5.zim", "prepareme-maps-border-north.zim", "prepareme-something-new.zim",
                     "prepareme-street-map.pmtiles"]
        for name in names {
            let title = HomeMacWords.title(entry(name))
            for bad in [".zim", ".pmtiles", "prepareme", "maps-", "topo-", "street-map"] {  // a file name's pieces
                XCTAssertFalse(title.lowercased().contains(bad), "\(name): \(title)")
            }
            for check: HomeMacWords.CheckResult in [.answered(checked), .notFound, .removed, .never] {
                let said = words(entry(name), check)
                XCTAssertNil(said.range(of: #"\d{4}-\d\d-\d\dT"#, options: .regularExpression), said)
            }
        }
    }

    /// Beta run 2, B2-17: a library's title in the app is its plain name, the one Home Mac uses, whichever way it
    /// reaches the screen (the ZIM's own title, still "PrepareMe: …" for the App Store Kiwix, or the file's name).
    func testALibraryHasOneNameEverywhere() {
        let titles = ["PrepareMe: guides & household": "Guides and today's page",
                      "PrepareMe: guides and household": "Guides and today's page",
                      "PrepareMe: reference": "Medical references and manuals", "PrepareMe: video": "Videos",
                      "PrepareMe: vehicles": "Vehicle manuals", "PrepareMe: equipment manuals": "Equipment manuals",
                      "PrepareMe: road maps": "Road maps", "PrepareMe: home-area topo": "Home-area topo",
                      "PrepareMe: topo today 3 of 10": "Topo today 3 of 10", "PrepareMe: older topo 2 of 5": "Older topo 2 of 5",
                      "PrepareMe: border topo, north": "Border topo, north", "Wikipedia": "Wikipedia"]
        for (zim, plain) in titles { XCTAssertEqual(HomeMacWords.plainLibraryTitle(zim), plain, zim) }
        for (stem, plain) in [("daily", "Guides and today's page"), ("reference", "Medical references and manuals"),
                              ("media", "Videos"), ("vehicles", "Vehicle manuals")] {
            XCTAssertEqual(HomeMacWords.title(entry("prepareme-\(stem).zim")), plain, "the file's name says the same")
        }
    }

    /// B2-17: the phone's read-only line is short, and the same words say it when a change is refused.
    func testNamesStayOnTheMac() {
        XCTAssertEqual(HomeMacWords.phoneNamesNote, "A name shows on the pins that device adds, on every device.")
    }

    func testReadOnlyInventoryLine() {
        XCTAssertEqual(HomeMacWords.readOnlyInventory, "Read only. An adult's phone or the Mac can change it.")
    }

    func testPlainNamesFollowTheVolumesTitles() {
        XCTAssertEqual(HomeMacWords.title(entry("prepareme-daily.zim")), "Guides and today's page")
        XCTAssertEqual(HomeMacWords.title(entry("prepareme-reference.zim")), "Medical references and manuals")
        XCTAssertEqual(HomeMacWords.title(entry("prepareme-item-manuals.zim")), "Equipment manuals")  // phase 7
        XCTAssertEqual(HomeMacWords.title(entry("prepareme-maps-topo-overview.zim")), "Topo overview")
        XCTAssertEqual(HomeMacWords.title(entry("prepareme-maps-topo-today-3.zim")), "Topo today 3 of 10")
        XCTAssertEqual(HomeMacWords.title(entry("prepareme-maps-topo-older-5.zim")), "Older topo 5 of 5")
        XCTAssertEqual(HomeMacWords.title(entry("prepareme-maps-border-north.zim")), "Border topo, north")
        XCTAssertEqual(HomeMacWords.title(entry("prepareme-something-new.zim")), "Something new")
        XCTAssertEqual(HomeMacWords.title(entry("prepareme-street-map.pmtiles", kind: "map", title: "Street map")),
                       "Street map", "an entry's own title comes first")
    }

    /// Remaining-findings plan, Task 9.3 (F40): a refused copy is named by its library, never its file.
    func testRefusedCopyNamedByTitle() {
        let said = HomeMacWords.refusal(entry("prepareme-maps-topo-overview.zim"), why: "the right size but not the "
                                        + "right bytes", at: checked)
        XCTAssertTrue(said.hasSuffix(", Topo overview: the right size but not the right bytes"), said)
        XCTAssertFalse(said.contains(".zim"), said)
    }

    /// Task 9.3 (F44): an unreachable Mac says what to do next, the same words on a child's phone (family downloads
    /// plan, phase 2).
    func testUnreachableWords() {
        XCTAssertEqual(HomeMacWords.notFound,
                       "The Mac wasn't found on this network (away from home, the Mac asleep, or this phone not allowed "
                       + "on the local network: Settings › Privacy & Security › Local Network). At home, wake the Mac, "
                       + "then tap Check now.")
        XCTAssertEqual(HomeMacWords.connectionCut, "The connection to the Mac was cut partway (a Wi-Fi network with a "
                       + "sign-in page, or a dropped link). At home, tap Check now.")
        XCTAssertTrue(HomeMacWords.pairSteps(device: "iPad").contains("pick whose iPad"))
        XCTAssertEqual(HomeMacWords.pairStartsOnMac, "Pairing starts on the Mac at home.")
        XCTAssertTrue(HomeMacWords.pairSteps(button: "Pair again").hasSuffix("Then tap Pair again and scan the code."))
    }

    /// Beta run 2, B2-21: Pair again's sheet carries the Mac's steps (no longer under the button), ending on the camera
    /// already showing there; B2-19: an empty paste box asks for the code, and a code that isn't one says so plainly.
    func testPairingSheetWords() {
        XCTAssertEqual(HomeMacWords.pairSteps(device: "phone", button: nil),
                       "On the Mac: Settings › Devices, pick whose phone. Then scan the code.")  // B2-17
        XCTAssertEqual(HomeMacWords.pasteProblem(""), "Paste the code first.")
        XCTAssertEqual(HomeMacWords.pasteProblem("  \n "), "Paste the code first.")
        XCTAssertNil(HomeMacWords.pasteProblem("{\"v\":1}"))
        XCTAssertEqual(HomeMacWords.notAPairingCode, "That isn't a pairing code.")
    }

    /// Task 9.3 (F47; owner, 2026-10-18): the yearly warning speaks to the family: who reinstalls, never "by cable",
    /// and where the library still reads if PrepareMe won't open.
    func testYearlyWarningSpeaksToTheFamily() {
        let line = "This install opens until November 1, 2026 (14 days)."
        let said = HomeMacWords.yearlyWarning(until: line, device: "phone")
        XCTAssertTrue(said.hasPrefix(line))
        XCTAssertTrue(said.contains("Reinstall it from the Mac at home before then."))
        XCTAssertTrue(said.hasSuffix("Kiwix: Files › On My iPhone › PrepareMe."), said)
        XCTAssertFalse(said.contains("cable"))
        XCTAssertTrue(HomeMacWords.yearlyWarning(until: line, device: "iPad").hasSuffix("On My iPad › PrepareMe."))
    }

    func testPairedLine() {
        XCTAssertEqual(HomeMacWords.pairedLine(host: "Home-Mac.local", removed: false), "Paired with Home-Mac.")
        XCTAssertEqual(HomeMacWords.pairedLine(host: "Home-Mac.local", removed: true),
                       "Was paired with Home-Mac; the Mac no longer knows this phone. Pair it again at home.")
    }

    /// The phone's Inventory before the Mac has written the phones' copy, and before pairing (remaining-findings plan,
    /// Task 12.4; F35: right after pairing it said "The Mac answered with an error (404)").
    func testNotFoundSaysTheMacHasNotWrittenIt() {
        XCTAssertEqual(HomeMacWords.inventoryWait(paired: true, status: 404), .notWritten)
        XCTAssertEqual(HomeMacWords.inventoryWait(paired: false, status: nil), .notPaired)
        XCTAssertEqual(HomeMacWords.inventoryWait(paired: true, status: 500), .other)
        XCTAssertEqual(HomeMacWords.inventoryWait(paired: true, status: nil), .other)
        XCTAssertEqual(HomeMacWords.inventoryNotWritten,
                       "The Mac hasn't sent the inventory yet. Open PrepareMe on the Mac; once its inventory is set "
                       + "up, it sends it within a minute.")
        XCTAssertFalse(HomeMacWords.inventoryNotWritten.contains("404"))
        XCTAssertEqual(HomeMacWords.inventoryNotPaired(device: "iPad"),
                       "Pair this iPad with the Mac at home to get the inventory.")
    }

    /// Beta run 2, B2-04 (choice a): the inventory from the PrepareMe Backup, read only, and the way to it with the Mac
    /// gone (Inventory had said only to pair, a dead end then)
    func testTheBackupInventorysWords() {
        XCTAssertEqual(HomeMacWords.inventoryFromBackup,
                       "Away from the Mac? Add the inventory and meeting places from the PrepareMe Backup: "
                       + "Downloads \u{203A} Away from the Mac \u{203A} Add from Files.")
        XCTAssertEqual(HomeMacWords.backupCopyReadOnly(device: "iPad"),
                       "Read only until this iPad is paired with the Mac.")
        // a paired device that took it while it held none: its changes open once it reaches the Mac (review, minor a)
        XCTAssertEqual(HomeMacWords.backupCopyReadOnly(device: "phone", paired: true),
                       "Read only until this phone reaches the Mac at home.")
        XCTAssertEqual(HomeMacWords.backupCopyWritten("Oct 20, 2026 at 4:00 PM"),
                       "From the PrepareMe Backup, written Oct 20, 2026 at 4:00 PM.")
        // the backup is named once in the whole line (B3-07)
        let line = HomeMacWords.backupCopyWritten("Oct 20, 2026 at 4:00 PM") + " "
            + HomeMacWords.backupCopyReadOnly(device: "phone")
        XCTAssertEqual(line.components(separatedBy: "PrepareMe Backup").count - 1, 1)
    }

    /// Beta run 2, B2-11 (R4.3): "Throw these away" asks first, naming what it throws away: the changes the Mac didn't
    /// keep (never the items), which nothing brings back.
    func testThrowingAwayRefusedChangesAsksFirst() {
        XCTAssertEqual(HomeMacWords.throwAwayTitle(count: 1), "Throw away 1 change the Mac didn't keep?")
        XCTAssertEqual(HomeMacWords.throwAwayTitle(count: 3), "Throw away 3 changes the Mac didn't keep?")
        XCTAssertEqual(HomeMacWords.throwAwayMessage,
                       "Only these waiting changes go. The items stay as the Mac has them, and nothing brings the "
                       + "changes back.")
        XCTAssertEqual(HomeMacWords.throwAwayButton, "Throw these away")
        XCTAssertEqual(HomeMacWords.throwAwayKeep, "Keep them")
    }

    /// Today's warning when a base file can't update for lack of room (phase M): every phone, a child's too since the
    /// family downloads plan's phase 2, is told to free space or remove a map under Downloads. Its two sizes never
    /// read the same (finding 8).
    func testRoomWarning() {
        let one = HomeMacWords.roomWarning(file: "Topo maps, home area", more: 0, need: 2_400_000_001,
                                           free: 2_400_000_000, device: "phone")
        XCTAssertEqual(one, "Not enough room for Topo maps, home area: it needs 2.5 GB free and this phone has "
                       + "2.4 GB. Free some space, or remove a map under Downloads.")
        let more = HomeMacWords.roomWarning(file: "Topo maps, home area", more: 2, need: 7_120_000_000,
                                            free: 5_090_000_000, device: "iPad")
        XCTAssertEqual(more, "Not enough room for Topo maps, home area (and 2 more): it needs 7.2 GB free and this "
                       + "iPad has 5.0 GB. Free some space, or remove a map under Downloads.")
    }

    func testHomeMacRowsKeepOneOrderWhateverOrderTheyArrive() {  // beta run 2, B2-20
        func file(_ name: String, kind: String, order: Int? = nil) -> Manifest.Entry {
            Manifest.Entry(name: name, id: "0f1e2d3c-4b5a-4968-8776-000000000001", kind: kind, size: 1,
                           sha256: String(repeating: "a", count: 64), deliveredAt: "2026-10-16T11:12:10-04:00",
                           order: order)
        }
        let all = [file("prepareme-daily.zim", kind: "library"), file("prepareme-guides.zim", kind: "library"),
                   file("maps-roads.zim", kind: "map-core", order: 2), file("maps-home.zim", kind: "map-core", order: 1),
                   file("topo.zim", kind: "map-optional"), file("street.pmtiles", kind: "map")]
        let first = HomeMacWords.ordered(all).map(\.name)
        XCTAssertEqual(first, ["prepareme-daily.zim", "prepareme-guides.zim", "maps-home.zim", "maps-roads.zim",
                               "topo.zim", "street.pmtiles"])
        XCTAssertEqual(HomeMacWords.ordered(all.reversed()).map(\.name), first)
        XCTAssertEqual(HomeMacWords.ordered(all.shuffled()).map(\.name), first)
    }

    func testAnAgeIsMadeForALibraryAndOpenStreetMapForTheStreetMap() {
        XCTAssertEqual(HomeMacWords.age(entry("prepareme-daily.zim", asOf: "2026-10-12T08:41-04:00"), now: now,
                                        timeZone: zone), "made Oct 12")
        XCTAssertEqual(HomeMacWords.age(entry(StreetMap.fileName, kind: "map", asOf: "2026-10-06"), now: now,
                                        timeZone: zone), "OpenStreetMap as of Oct 6")
    }

    /// The map's age on the map (the street map fixes plan, task 3.5): its month and year, and past 180 days a
    /// warning in caution amber; nil when the date can't be read.
    func testTheAgeLineWarnsPastSixMonths() throws {
        let day = { (text: String) in ISO8601DateFormatter().date(from: text)! }
        let fresh = try XCTUnwrap(HomeMacWords.mapAgeLine(built: "2026-03-10", now: day("2026-09-05T12:00:00-04:00"),
                                                          timeZone: zone))
        XCTAssertEqual(fresh.words, "Map as of Mar 2026")
        XCTAssertFalse(fresh.old)
        let old = try XCTUnwrap(HomeMacWords.mapAgeLine(built: "2026-03-10", now: day("2026-09-07T12:00:00-04:00"),
                                                        timeZone: zone))
        XCTAssertEqual(old.words, "Map as of Mar 2026: over 6 months old")
        XCTAssertTrue(old.old)
        XCTAssertNil(HomeMacWords.mapAgeLine(built: "soon", now: now, timeZone: zone))
    }
}
