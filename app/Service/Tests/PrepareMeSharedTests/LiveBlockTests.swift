import Foundation
@testable import PrepareMeShared
import XCTest

/// The live block (plan phase 5): its markup and words held to the Mac's page (the shared cases' `blocks` and `copy`,
/// which dashboard/tests/phone_cases.py writes from dashboard/render.py), and the build plan's combination rule as a
/// table of cases: the phone's reading while it is under 2 hours old, else the Mac's copy with a line saying why;
/// never a "none" the phone didn't read; never a main reading (`data-core`) from the phone.
final class LiveBlockTests: XCTestCase {
    struct Block: Decodable {
        let name, sid, panel, none, at, now, content: String
        let items: [ConditionItem]
    }

    struct Tidy: Decodable { let text, tidied: String }
    struct FaceBlock: Decodable {
        let sid: String
        let items: [ConditionItem]
        let failed: Bool
    }
    struct Face: Decodable {
        let name, panel, at, now, status, face: String
        let gauges: Bool
        let blocks: [FaceBlock]
    }
    struct Tier: Decodable { let code, tier: String }
    struct Name: Decodable { let code, name: String }
    struct Headline: Decodable {
        let text, detail, plain: String
        let vtec: [String]?
    }
    struct Instruction: Decodable {
        let text, said: String
        let cut: Bool
    }

    struct Cases: Decodable {
        let blocks: [Block]
        let copy: [String: AnyDecodable]
        let tidy: [Tidy]
        let tiers: [Tier]
        let faces: [Face]
        let headlines: [Headline]
        let instructions: [Instruction]
        let names: [Name]
    }

    struct AnyDecodable: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s }
            else if let n = try? c.decode(Double.self) { value = n }
            else if let d = try? c.decode([String: String].self) { value = d }
            else if let d = try? c.decode([String: Double].self) { value = d }
            else if let d = try? c.decode([String: [String: String]].self) { value = d }
            else if let a = try? c.decode([String].self) { value = a }
            else { value = NSNull() }
        }
    }

    static func cases() throws -> Cases {
        let url = try SharedCases.url.skippingWhenAbsent()
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
    }

    /// B3-04: a phone paired before its role was known reads as a child's, then as an adult's once the Mac says so
    func testTheBandsWordsFollowTheRoleAsItArrives() {
        XCTAssertEqual(LiveBlock.host(canEdit: false), "phone-readonly")  // not yet told: the child's words
        XCTAssertEqual(LiveBlock.host(canEdit: true), "phone")  // told it may edit: the adult's
        XCTAssertEqual(LiveBlock.host(canEdit: false), "phone-readonly")  // and a child's again if the Mac says so
        XCTAssertEqual(LiveBlock.limitsOnly(host: LiveBlock.host(canEdit: true)).host, "phone")
    }

    /// The owner's choice 1 of phase L (2026-10-20; F10): a Weather Service watch for home is worth a look, amber,
    /// never Needs action (it was red from fix 6, 2026-10-16), and so is a watch where the phone is; a warning for home
    /// stays red.
    func testAWatchForHomeIsWorthALook() {
        XCTAssertEqual(NWSTidy.tier("TO.A"), NWSTidy.look)
        XCTAssertEqual(NWSTidy.tier("FF.A"), NWSTidy.look)
        XCTAssertEqual(NWSTidy.tier("WI.Y"), NWSTidy.look)
        let watch = LiveBlock.Line(item: ConditionItem("Tornado Watch", flag: "warn", code: "TO.A"), ended: false,
                                   cancelled: false, tier: NWSTidy.tier("TO.A"))
        XCTAssertFalse(LiveBlock.needsAction("alerts", "home-alerts", watch))
        XCTAssertFalse(LiveBlock.needsAction("alerts", "here-alerts", watch), "nor where the phone is")
        XCTAssertTrue(LiveBlock.quiet("here-alerts", watch), "a watch there leaves its row as an advisory does")
        XCTAssertEqual(NWSTidy.tier("TO.W"), NWSTidy.warn)
        let warning = LiveBlock.Line(item: ConditionItem("Tornado Warning", flag: "warn", code: "TO.W"), ended: false,
                                     cancelled: false, tier: NWSTidy.tier("TO.W"))
        XCTAssertTrue(LiveBlock.needsAction("alerts", "home-alerts", warning), "a warning for home stays red")
    }

    func testAWarningWhereThePhoneIsIsCritical() {
        let warning = LiveBlock.Line(item: ConditionItem("Tornado Warning", flag: "warn", code: "TO.W"), ended: false,
                                     cancelled: false, tier: NWSTidy.tier("TO.W"))
        XCTAssertTrue(LiveBlock.needsAction("alerts", "here-alerts", warning))
        XCTAssertFalse(LiveBlock.quiet("here-alerts", warning), "where the phone is counts as home does")
        let advisory = LiveBlock.Line(item: ConditionItem("Wind Advisory", flag: "warn", code: "WI.Y"), ended: false,
                                      cancelled: false, tier: NWSTidy.tier("WI.Y"))
        XCTAssertFalse(LiveBlock.needsAction("alerts", "here-alerts", advisory), "an advisory there is worth a look")
    }

    func testEachBlocksItemsAreWrittenAsTheMacWritesThem() throws {
        let blocks = try Self.cases().blocks
        XCTAssertGreaterThan(blocks.count, 8)
        for block in blocks {
            let at = try XCTUnwrap(ConditionTime.moment(block.at)), now = try XCTUnwrap(ConditionTime.moment(block.now))
            let written = LiveBlock.content(block.sid, panel: block.panel, none: block.none, items: block.items,
                                            goodAt: at, now: now, county: "Example").joined(separator: "\n")
            XCTAssertEqual(written, block.content, block.name)
        }
    }

    /// The Today redesign's rulings 1 and 2: each code's tier and each text's tidy as the Mac's (weather.py).
    func testTiersAndTidyAreTheMacs() throws {
        let cases = try Self.cases()
        XCTAssertGreaterThan(cases.tiers.count, 15)
        for found in cases.tiers { XCTAssertEqual(NWSTidy.tier(found.code), found.tier, found.code) }
        XCTAssertGreaterThan(cases.tidy.count, 10)
        for found in cases.tidy { XCTAssertEqual(NWSTidy.tidy(found.text), found.tidied, found.text) }
    }

    /// Each alert code's name as the Mac's (weather.py `code_name`), both ways: every code the Mac names, and every
    /// code the phone's own tables name is among the cases (the 2026-10-25 review).
    func testAlertNamesAreTheMacs() throws {
        let names = try Self.cases().names
        for found in names { XCTAssertEqual(NWSTidy.codeName(found.code), found.name, found.code) }
        let covered = Set(names.map(\.code))
        let phones = NWSTidy.phenomena.keys.flatMap { p in NWSTidy.significance.keys.map { "\(p).\($0)" } }
            + NWSTidy.namedCodes.keys
        XCTAssertGreaterThan(phones.count, 200)
        for code in phones { XCTAssertTrue(covered.contains(code), "\(code): the phone names it, the Mac doesn't") }
    }

    /// Task 8.1 and the phase 8 review: each plain headline as the Mac's (weather.py `alert_headline`,
    /// `tropical_headline`): the worst words lead, a corrected line is named, an active storm is never called quiet.
    func testPlainHeadlinesAreTheMacs() throws {
        let headlines = try Self.cases().headlines
        XCTAssertGreaterThan(headlines.count, 15)
        for found in headlines {
            let plain = found.vtec.map { NWSTidy.alertHeadline(found.text, vtec: $0, detail: found.detail) }
                ?? NWSTidy.tropicalHeadline(found.text)
            XCTAssertEqual(plain, found.plain, found.text)
        }
    }

    /// The Today redesign's phase 3: each live panel's row words (or worth-a-look heading) as the Mac's page writes
    /// them from the same readings (dashboard/render.py `_face`).
    func testEachRowsWordsAreTheMacs() throws {
        let faces = try Self.cases().faces
        XCTAssertGreaterThan(faces.count, 18)
        for found in faces {
            let at = try XCTUnwrap(ConditionTime.moment(found.at)), now = try XCTUnwrap(ConditionTime.moment(found.now))
            var readings: [String: LiveReading] = [:]
            for block in found.blocks {
                readings[block.sid] = LiveReading(goodAt: at, items: block.items,
                                                  triedAt: block.failed ? now.addingTimeInterval(-60) : at,
                                                  failure: block.failed ? "made-up failure" : nil)
            }
            let settings = found.gauges ? self.settings : noGauges
            let (status, html) = LiveBlock.face(found.panel, LiveBlock.readBlocks(found.panel, settings, readings,
                                                                                    now: now), now: now)
            XCTAssertEqual(status, found.status, found.name)
            XCTAssertEqual(html, found.face, found.name)
        }
    }

    func testTheWordsReusedAreTheMacs() throws {
        let copy = try Self.cases().copy
        func text(_ key: String) -> String? { copy[key]?.value as? String }
        func table(_ key: String) -> [String: String] { copy[key]?.value as? [String: String] ?? [:] }
        XCTAssertEqual(text("FETCHED"), LiveBlock.fetched)
        XCTAssertEqual(text("AS_OF"), LiveBlock.asOf)
        XCTAssertEqual(text("LAST_TRY"), LiveBlock.lastTry)
        XCTAssertEqual(text("OLD_LINE"), LiveBlock.oldLine)
        XCTAssertEqual(text("ENDED_LINE"), LiveBlock.endedLine)
        XCTAssertEqual(text("ENDED_HEAD"), LiveBlock.endedHead)
        XCTAssertEqual(text("INSTRUCTION_MORE"), LiveBlock.instructionMore)
        XCTAssertEqual(text("MISSING_PAGES"), MissingPages.template)
        XCTAssertEqual(text("UNTIL"), LiveBlock.until)
        XCTAssertEqual(text("FULL_TEXT"), LiveBlock.fullText)
        XCTAssertEqual(text("FORECAST_FOLD"), LiveBlock.forecastFold)
        XCTAssertEqual(text("NEEDS_LINE"), LiveBlock.needsLine)
        XCTAssertEqual(text("NOTHING_NEEDS"), LiveBlock.nothingNeeds)
        XCTAssertEqual(text("EVAC_ORDER_REASON"), LiveBlock.evacOrderReason)
        XCTAssertEqual(text("EVAC_ORDER_UNNAMED"), LiveBlock.evacOrderUnnamed)
        XCTAssertEqual(text("ALERTS_NONE"), LiveBlock.alertsNone)
        XCTAssertEqual(text("STORMS_NONE"), LiveBlock.stormsNone)
        XCTAssertEqual(text("EVAC_NONE"), LiveBlock.evacNone)
        XCTAssertEqual(text("HOME_LABEL"), LiveBlock.homeLabel)
        XCTAssertEqual(text("NHC_LABEL"), LiveBlock.nhcLabel)
        XCTAssertEqual(text("GAUGE_LABEL"), LiveBlock.gaugeLabel)
        XCTAssertEqual(table("KIND_REASONS"), LiveBlock.kindReasons)
        XCTAssertEqual(Set(copy["KEEP_CAPS"]?.value as? [String] ?? []), NWSTidy.keepCaps)  // headlines' capitals
        XCTAssertEqual(Set(copy["PROPER"]?.value as? [String] ?? []), NWSTidy.proper)
        let headings = table("HEADINGS"), emoji = table("PANEL_EMOJI"), chips = table("CHIP_LABELS")
        for panel in LiveBlock.panels {
            XCTAssertEqual(headings[panel], LiveBlock.headings[panel], panel)
            XCTAssertEqual(emoji[panel], LiveBlock.panelEmoji[panel], panel)
            XCTAssertEqual(chips[panel], LiveBlock.chipLabels[panel], panel)
        }
        let limits = copy["STALE_HOURS"]?.value as? [String: Double] ?? [:]
        for (sid, hours) in limits {
            let key = sid.hasPrefix("gauge-") ? "gauge" : sid.hasPrefix("crest-") ? "crest" : sid
            XCTAssertEqual(LiveBlock.ownStaleHours[key], hours, sid)
        }
        XCTAssertEqual(limits.count, 8)
        XCTAssertEqual(Array(headings.keys).sorted(), LiveBlock.pageOrder.sorted())
        XCTAssertEqual(table("STATUS_EMOJI")["warn"], LiveBlock.warnMark)
        for (kind, mark) in LiveBlock.eventEmoji { XCTAssertEqual(table("EVENT_EMOJI")[kind], mark, kind) }
        // the band's guide button for each kind a phone reading can start, the Mac's markup with the packer's link
        XCTAssertEqual(table("EVENT_GUIDES"), LiveBlock.eventGuides)
        XCTAssertEqual(Set(table("GUIDE_BUTTONS").keys), Set(LiveBlock.eventEmoji.keys))
        for (kind, button) in table("GUIDE_BUTTONS") {
            let page = try XCTUnwrap(LiveBlock.eventGuides[kind], kind)
            XCTAssertEqual(LiveBlock.guideButton(kind).replacingOccurrences(
                of: "<a href=\"\(page).html\">", with: "<a data-page=\"\(page)\">"), button, kind)
        }
        XCTAssertEqual(copy["ORDER"]?.value as? [String], LiveBlock.pageOrder)
        XCTAssertEqual(copy["WEATHER_WORTH"]?.value as? [String], LiveBlock.weatherWorth)
        XCTAssertEqual(table("ROW_FINE"), LiveBlock.rowFine)
        XCTAssertEqual(table("ROW_LOOK"), LiveBlock.rowLook)
        XCTAssertEqual(text("ROW_OLD"), LiveBlock.rowOld)
        XCTAssertEqual(text("ROW_FAILED"), LiveBlock.rowFailed)
        XCTAssertEqual(text("ROW_NOT_FETCHED"), LiveBlock.rowNotFetched)
        XCTAssertEqual(text("ROW_WAITING"), LiveBlock.rowWaiting)
        XCTAssertEqual(text("ROW_LINE"), LiveBlock.rowLine)
        XCTAssertEqual(text("NO_OUTAGES"), LiveBlock.noOutages)
        XCTAssertEqual(text("OUTAGES_HOME"), LiveBlock.outagesHome)
        XCTAssertEqual(text("OUTAGES_NONE"), LiveBlock.outagesNone)
        XCTAssertEqual(text("WORTH"), LiveBlock.worth)
        XCTAssertEqual(text("NO_SOURCES"), LiveBlock.noSources)
        XCTAssertEqual(text("RIVERS_EMPTY"), LiveBlock.riversEmpty)
        XCTAssertEqual(table("STATUS_EMOJI")["look"], LiveBlock.lookMark)
        XCTAssertEqual(table("STATUS_EMOJI")["ok"], LiveBlock.okMark)
        XCTAssertEqual(table("STATUS_EMOJI")["old"], LiveBlock.oldMark)
    }

    // MARK: The combination rule, as a table of cases

    let now = ConditionTime.moment("2026-10-06T12:00:00-04:00")!
    let settings = try! ConditionsSettings(Data(#"{"county":"Example","format":1,"gauges":["ZZZZ1"],"live_alerts":true,"nws_county":"ZZC183","nws_fire_zone":"ZZZ041","nws_zone":"ZZZ041"}"#.utf8),
                                         area: Data(ConditionsAreaTests.good.utf8))
    let noGauges = try! ConditionsSettings(Data(#"{"county":"Example","format":1,"gauges":[],"live_alerts":true,"nws_county":"ZZC183","nws_fire_zone":"ZZZ041","nws_zone":"ZZZ041"}"#.utf8),
                                         area: Data(ConditionsAreaTests.good.utf8))
    let alertsOff = try! ConditionsSettings(Data(#"{"county":"Example","format":1,"gauges":[],"live_alerts":false,"nws_county":"ZZC183","nws_fire_zone":"ZZZ041","nws_zone":"ZZZ041"}"#.utf8),
                                         area: Data(ConditionsAreaTests.good.utf8))
    let tornado = ConditionItem("...TORNADO WARNING IN EFFECT UNTIL 1:00 PM EDT...", detail: "Take shelter now.",
                                flag: "warn", expires: "2026-10-06T13:00:00-04:00", code: "TO.W",
                                vtec: ["NEW.KLWX.TO.W.0012"])

    func reading(_ minutesAgo: Double, _ items: [ConditionItem] = [], failure: String? = nil) -> LiveReading {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        return LiveReading(goodAt: at, items: items, triedAt: failure == nil ? at : now, failure: failure)
    }

    func block(_ payload: LivePayload, _ sid: String) -> String? {
        guard let start = payload.html.range(of: "data-source=\"\(sid)\" data-pm-live=\"1\"") else { return nil }
        return String(payload.html[start.lowerBound...].prefix { $0 != "\u{0}" }.components(separatedBy: "\n</div>")[0])
    }

    func testAFreshReadingIsShownLiveAndAStaleOneGivesTheMacsCopy() {
        let fresh = LiveBlock.payload(settings, ["home-alerts": reading(119, [tornado])], now: now)
        XCTAssertTrue(fresh.live.contains("home-alerts"))
        XCTAssertNotNil(block(fresh, "home-alerts"))
        let stale = LiveBlock.payload(settings, ["home-alerts": reading(120, [tornado])], now: now)
        XCTAssertFalse(stale.live.contains("home-alerts"))
        XCTAssertNil(block(stale, "home-alerts"))
        XCTAssertTrue(stale.html.contains("data-pm-mac=\"home-alerts\""))
        XCTAssertTrue(stale.html.contains(LiveBlock.phoneNotYet.replacingOccurrences(of: "'", with: "&#x27;")))
        XCTAssertFalse(stale.needs.contains("alerts"), "a stale reading's warning is the Mac's copy's to say")
    }

    /// Offline fixes, task 4.1: with the page's times known, a reading over 2 hours old shows while it is newer than
    /// the Mac's copy (the Mac gone for days), aged by its own old line; the Mac's newer copy still wins.
    func testAnOldReadingNewerThanTheMacsCopyStays() throws {
        let threeHours = ["home-alerts": reading(180, [tornado])]
        let macDaysOld = LiveBlock.payload(settings, threeHours, now: now,
                                           macAt: ["home-alerts": now.addingTimeInterval(-2 * 86400)])
        XCTAssertTrue(macDaysOld.live.contains("home-alerts"))
        let shown = try XCTUnwrap(block(macDaysOld, "home-alerts"))
        XCTAssertTrue(shown.contains("data-stale-hours=\"2\""), "aged by the page's own old line")
        XCTAssertNil(macDaysOld.homeNoneAt, "B3-01's line speaks only from a fresh reading")
        let macNewer = LiveBlock.payload(settings, threeHours, now: now,
                                         macAt: ["home-alerts": now.addingTimeInterval(-3600)])
        XCTAssertNil(block(macNewer, "home-alerts"))
        XCTAssertTrue(macNewer.html.contains("data-pm-mac=\"home-alerts\""))
        let mine = try XCTUnwrap(threeHours["home-alerts"]?.goodAt)
        XCTAssertTrue(LiveBlock.useOwn(threeHours["home-alerts"]!, macAt: mine.addingTimeInterval(-1), known: true, now: now))
        XCTAssertFalse(LiveBlock.useOwn(threeHours["home-alerts"]!, macAt: mine.addingTimeInterval(1), known: true, now: now))
        XCTAssertFalse(LiveBlock.useOwn(threeHours["home-alerts"]!, macAt: mine, known: true, now: now), "a tie: the Mac's")
        XCTAssertTrue(LiveBlock.useOwn(threeHours["home-alerts"]!, macAt: nil, known: true, now: now),
                      "the page has no copy of it")
        XCTAssertFalse(LiveBlock.useOwn(threeHours["home-alerts"]!, macAt: nil, known: false, now: now),
                       "the page's times unread: the 2 hours alone")
        XCTAssertEqual(LiveBlock.note, "This phone reads these itself while PrepareMe is open. Where the Mac's copy is "
                       + "newer, it shows instead, with its age.")
    }

    func testAFailedTryWithNoFreshReadingSaysWhyAndShowsTheMacsCopy() {
        let failed = LiveBlock.payload(settings, ["home-alerts": LiveReading(triedAt: now, failure: "no internet connection")],
                                       now: now)
        XCTAssertTrue(failed.html.contains("data-pm-mac=\"home-alerts\""))
        XCTAssertTrue(failed.html.contains("This phone couldn&#x27;t read it (no internet connection; last try "))
        XCTAssertFalse(failed.html.contains(LiveBlock.alertsNone), "never a none the phone didn't read")
    }

    func testNothingReadAtAllGivesEveryPanelTheMacsCopyAndNoNone() {
        let empty = LiveBlock.payload(settings, [:], now: now)
        XCTAssertEqual(empty.live, [])
        XCTAssertEqual(empty.fullyLive, [])
        XCTAssertEqual(empty.needs, [])
        for sid in ["home-alerts", "evacuations", "gauge-1", "crest-1", "outages", "home-forecast", "tropical-outlook",
                    "storms"] {
            XCTAssertTrue(empty.html.contains("data-pm-mac=\"\(sid)\""), sid)
        }
        for none in [LiveBlock.alertsNone, LiveBlock.stormsNone, LiveBlock.evacNone] {
            XCTAssertFalse(empty.html.contains(none), none)
        }
    }

    func testANoneIsSaidOnlyFromAGoodReadingThatHeldNothing() throws {
        let quiet = LiveBlock.payload(settings, ["home-alerts": reading(5)], now: now)
        XCTAssertTrue(try XCTUnwrap(block(quiet, "home-alerts")).contains("No active weather alerts for home as of"))
        let ended = ConditionItem("Old advisory", flag: "warn", expires: "2026-10-06T11:00:00-04:00")
        let hidden = LiveBlock.payload(settings, ["home-alerts": reading(5, [ended], failure: "timed out")], now: now)
        let shown = try XCTUnwrap(block(hidden, "home-alerts"))
        XCTAssertFalse(shown.contains("No active weather alerts"), "an ended item hidden by a failure is no none")
        XCTAssertTrue(shown.contains("last try"))
    }

    func testThePhonesReadingsAreNeverMainReadings() {
        var all: [String: LiveReading] = [:]
        for sid in ["home-alerts", "evacuations", "gauge-1", "crest-1", "outages", "home-forecast", "tropical-outlook",
                    "storms"] {
            all[sid] = reading(5)
        }
        let payload = LiveBlock.payload(settings, all, now: now)
        XCTAssertEqual(payload.fullyLive, LiveBlock.panels)
        XCTAssertFalse(payload.html.contains("data-core"))
        XCTAssertTrue(payload.html.contains("data-stale-hours=\"2\""))
    }

    func testALiveTornadoWarningNeedsActionStartsEventModeAndHeadsTheBand() throws {
        let payload = LiveBlock.payload(settings, ["home-alerts": reading(5, [tornado])], now: now)
        XCTAssertEqual(payload.needs, ["alerts"])
        let shown = try XCTUnwrap(block(payload, "home-alerts"))
        XCTAssertTrue(shown.contains("data-event=\"tornado\" data-event-until=\"2026-10-06T13:00:00-04:00\" "
                                     + "data-event-reason=\"a Tornado Warning for home\""))
        XCTAssertTrue(payload.html.contains("<div class=\"panel card\" id=\"pm-panel-alerts\">"))
        XCTAssertTrue(payload.band.contains("Tornado Warning"), "named in sentence case (Task 8.1)")
        XCTAssertTrue(payload.band.contains("data-ended-head=\"Ended: {event} (until {time})\""),
                      "the page's script swaps the headline for the Ended line once the warning's end passes (B2-27)")
        let past = LiveBlock.payload(settings, ["home-alerts": reading(5, [tornado])],
                                     now: now.addingTimeInterval(2 * 3600 - 600))
        XCTAssertEqual(past.needs, [], "past its own end it is over")
        XCTAssertEqual(past.band, "")
    }

    /// Beta run 2, R9.1 (mockup 1): the band carries the warning's own instruction, the API's `instruction` field in
    /// the Mac's band words (weather.instruction_words, the shared cases' `instructions`), and nothing in its place
    /// when the warning gives none.
    func testTheInstructionIsInTheMacsWords() throws {
        let found = try Self.cases().instructions
        XCTAssertGreaterThan(found.count, 8)
        for one in found {
            let (said, cut) = NWSTidy.instruction(one.text)
            XCTAssertEqual(said, one.said, one.text)
            XCTAssertEqual(cut, one.cut, one.text)
        }
    }

    func testTheBandCarriesTheWarningsOwnInstruction() {
        var told = tornado
        told.instruction = "TAKE COVER NOW! Move to a basement or an interior room on the lowest\nfloor of a sturdy "
            + "building. Avoid windows. If you are outdoors, in a\nmobile home, or in a vehicle, move to the closest."
        let payload = LiveBlock.payload(settings, ["home-alerts": reading(5, [told])], now: now)
        XCTAssertTrue(payload.band.hasSuffix("</span> <span class=\"do\">TAKE COVER NOW! Move to a basement or an interior "
                                             + "room on the lowest floor of a sturdy building. Avoid windows. <span "
                                             + "class=\"more\">More in the full text below.</span></span></p>"),
                      payload.band)
        XCTAssertTrue(payload.band.contains("<p class=\"alert\" data-band-of=\"pm-live\" data-pm-src=\"home-alerts\" "
                                            + "data-band-kind=\"tornado\"><span class=\"em mark\" aria-hidden=\"true\">"
                                            + "🌪️</span><span "),
                      "beside its own mark, its kind named for the style (checkpoint 4), as the Mac's band writes it")
        let none = LiveBlock.payload(settings, ["home-alerts": reading(5, [tornado])], now: now)
        XCTAssertFalse(none.band.contains("class=\"do\""), "never words of ours in its place")
        var escaped = tornado
        escaped.instruction = "Go <now> & stay."
        XCTAssertTrue(LiveBlock.payload(settings, ["home-alerts": reading(5, [escaped])], now: now).band
            .contains(" <span class=\"do\">Go &lt;now&gt; &amp; stay.</span>"))
    }

    /// Whole-plan review: a warning the phone reads itself gets its kind's guide button, as the Mac's band gives one
    /// (render.py guide_button: the kind's first page in event.EVENT_PAGES, once), linked to the guide only when the
    /// library holds it (its guide list's pages); the page's script puts it among the first-aid buttons.
    func testAWarningThePhoneReadsGetsItsGuideButtonWhenTheLibraryHoldsIt() {
        let held: Set<String> = ["tornado.html", "floodwater.html", "evacuation.html"]
        let payload = LiveBlock.payload(settings, ["home-alerts": reading(5, [tornado])], now: now, guides: held)
        XCTAssertEqual(payload.guides, "<p class=\"guide-go\" data-kind=\"tornado\"><a href=\"tornado.html\">"
                       + "<span class=\"em\" aria-hidden=\"true\">🌪️</span>Tornado guide</a></p>")
        XCTAssertEqual(LiveBlock.payload(settings, ["home-alerts": reading(5, [tornado])], now: now).guides, "",
                       "a guide the library doesn't hold gets no button")
        XCTAssertEqual(LiveBlock.payload(settings, ["home-alerts": reading(5, [tornado])], now: now,
                                         guides: ["floodwater.html"]).guides, "")
        let flood = ConditionItem("...FLASH FLOOD WARNING IN EFFECT UNTIL 1:00 PM EDT...", flag: "warn",
                                  expires: "2026-10-06T13:00:00-04:00", code: "FF.W", vtec: ["NEW.KLWX.FF.W.0003"])
        let hurricane = ConditionItem("...HURRICANE WARNING IN EFFECT...", flag: "warn",
                                      expires: "2026-10-07T13:00:00-04:00", code: "HU.W", vtec: ["NEW.KLWX.HU.W.1001"])
        let order = ConditionItem("Example County", detail: "Leave by noon.", flag: "warn", code: "EVAC.HOME")
        let many = LiveBlock.payload(settings, ["home-alerts": reading(5, [hurricane, tornado, flood]),
                                                "evacuations": reading(5, [order])], now: now, guides: held)
        XCTAssertEqual(many.guides, ["hurricane", "tornado", "flash-flood"].map(LiveBlock.guideButton).joined(),
                       "each guide once, in the band's order: a hurricane's is the evacuation guide, so the order's "
                       + "is not given again")
        XCTAssertTrue(many.guides.contains("data-kind=\"hurricane\"><a href=\"evacuation.html\">"))
        XCTAssertTrue(many.guides.contains(">Flood guide</a>"))
        let alone = LiveBlock.payload(settings, ["evacuations": reading(5, [order])], now: now, guides: held)
        XCTAssertTrue(alone.guides.contains("data-kind=\"evacuation\"><a href=\"evacuation.html\">"
                                            + "<span class=\"em\" aria-hidden=\"true\">🚗</span>Evacuation guide</a>"))
        XCTAssertEqual(LiveBlock.payload(settings, ["home-alerts": reading(5, [tornado])],
                                         now: now.addingTimeInterval(2 * 3600 - 600), guides: held).guides, "",
                       "past its own end: no band line, no button")
        XCTAssertEqual(LiveBlock.payload(settings, ["home-alerts": reading(5)], now: now, guides: held).guides, "")
        XCTAssertEqual(LiveBlock.limitsOnly().guides, "")
    }

    /// R9.1: the rally line's words for the page's script, the place named on the phone only (never in the library).
    func testTheRallyLineWords() {
        XCTAssertEqual(LiveBlock.rallyNamed, "Meet at: {name}")
        let payload = LiveBlock.payload(settings, [:], now: now)
        XCTAssertNil(payload.rally, "the app adds the name, from its copy of the lists")
        XCTAssertEqual(payload.rallyNamed, LiveBlock.rallyNamed)
    }

    func testAnAdvisoryAndACancelledWarningNeedNoAction() {
        let advisory = ConditionItem("Wind Advisory", flag: "warn", code: "WI.Y")
        let cancelled = ConditionItem("Tornado Warning cancelled", flag: "warn", code: "",
                                      vtec: ["CAN.KLWX.TO.W.0012"])
        let payload = LiveBlock.payload(settings, ["home-alerts": reading(5, [cancelled])], now: now)
        XCTAssertEqual(payload.needs, [])
        XCTAssertTrue(payload.html.contains("class=\"warn is-ended\""))
        let windy = LiveBlock.payload(settings, ["home-alerts": reading(5, [advisory])], now: now)
        XCTAssertEqual(windy.needs, [], "an advisory is worth a look, never Needs action (the Today redesign's ruling 1)")
        XCTAssertTrue(windy.html.contains("<div class=\"panel look\" id=\"pm-panel-alerts\">"))
        XCTAssertTrue(windy.html.contains("<li class=\"look\">"))
        XCTAssertEqual(windy.band, "", "only TO.W, FF.W and HU.W start event mode")
        let statement = ConditionItem("Special Weather Statement", flag: "warn")
        let plain = LiveBlock.payload(settings, ["home-alerts": reading(5, [statement])], now: now)
        XCTAssertEqual(plain.needs, ["alerts"], "an alert with no type code stays red, as on the Mac")
    }

    func testAnEvacuationOrderNamingHomeStartsEventModeWithTheCounty() {
        let items = [ConditionItem("Example County", detail: "Leave by noon.", flag: "warn", code: "EVAC.HOME"),
                     ConditionItem("Names Example County.")]
        let payload = LiveBlock.payload(settings, ["evacuations": reading(5, items)], now: now)
        XCTAssertEqual(payload.needs, ["evacuations"])
        XCTAssertTrue(payload.html.contains("data-event=\"evacuation\" data-event-open=\"1\" "
                                            + "data-event-reason=\"an evacuation order naming Example County\""))
    }

    func testAGaugeAtFloodStageNeedsActionAndActionStageDoesNot() {
        let flood = ConditionItem("Creek: 14.2 ft, moderate flooding.", flag: "warn", code: "moderate")
        let action = ConditionItem("Creek: 9.4 ft, action stage.", flag: "warn", code: "action")
        XCTAssertEqual(LiveBlock.payload(settings, ["gauge-1": reading(5, [flood])], now: now).needs, ["rivers"])
        XCTAssertEqual(LiveBlock.payload(settings, ["gauge-1": reading(5, [action])], now: now).needs, [])
    }

    func testWithLiveAlertsOffHomesAlertsAreAlwaysTheMacsCopy() {
        let payload = LiveBlock.payload(alertsOff, ["home-alerts": reading(5, [tornado]),
                                                    "here-alerts": LiveReading(goodAt: now, items: [tornado],
                                                                               area: "Elsewhere ZZ", zone: "ZZZ099")],
                                        now: now)
        XCTAssertFalse(payload.live.contains("home-alerts"))
        XCTAssertFalse(payload.live.contains("here-alerts"))
        XCTAssertTrue(payload.html.contains(LiveBlock.phoneAlertsOff.replacingOccurrences(of: "'", with: "&#x27;")))
        XCTAssertEqual(payload.needs, [])
        XCTAssertEqual(payload.band, "")
        XCTAssertFalse(payload.html.contains("pm-panel-rivers\">\n<h2><span class=\"em\" aria-hidden=\"true\">🌊</span>Rivers</h2>\n<div class=\"pm-mac\""),
                       "no gauges set: no gauge blocks")
    }

    /// Review I1 (phase 5): fix 6 made warnings and watches where the phone is red, nothing more; an advisory there
    /// stays quiet as before, so the row never counts it "for home".
    func testAnAdvisoryWhereThePhoneIsIsNotCountedForHome() {
        let advisory = ConditionItem("...WIND ADVISORY IN EFFECT UNTIL 6 PM EDT...", flag: "warn",
                                     expires: "2026-10-06T18:00:00-04:00", code: "WI.Y")
        let payload = LiveBlock.payload(settings, ["home-alerts": reading(3), "here-alerts": LiveReading(
            goodAt: now, items: [advisory], area: "Elsewhere ZZ", zone: "ZZZ099")], now: now)
        XCTAssertTrue(payload.live.contains("here-alerts"))
        XCTAssertEqual(payload.needs, [])
        XCTAssertTrue(payload.html.contains("Weather alerts: none for home"))
        XCTAssertFalse(payload.html.contains("1 for home"))
    }

    func testHereShowsOnlyAwayFromHomesZoneNeedsActionAndNeverStartsEventMode() {
        let away = LiveReading(goodAt: now, items: [tornado], area: "Elsewhere ZZ", zone: "ZZZ099")
        let payload = LiveBlock.payload(settings, ["here-alerts": away, "here-forecast": LiveReading(
            goodAt: now, items: [ConditionItem("Tonight: Clear.")], area: "Elsewhere ZZ", zone: "ZZZ099")], now: now)
        XCTAssertTrue(payload.live.contains("here-alerts"))
        XCTAssertTrue(payload.live.contains("here-forecast"))
        XCTAssertTrue(payload.html.contains("Where this phone is: Elsewhere ZZ"))
        XCTAssertEqual(payload.needs, ["alerts"], "a warning where the phone is is critical (the owner's fix 6)")
        XCTAssertFalse(payload.html.contains("data-event=\"tornado\""))
        let atHome = LiveReading(goodAt: now, items: [tornado], area: "Home ZZ", zone: "ZZZ041")
        XCTAssertFalse(LiveBlock.payload(settings, ["here-alerts": atHome], now: now).live.contains("here-alerts"))
        let staleHere = LiveReading(goodAt: now.addingTimeInterval(-3 * 3600), items: [tornado], area: "Elsewhere ZZ",
                                    zone: "ZZZ099")
        let stale = LiveBlock.payload(settings, ["here-alerts": staleHere], now: now)
        XCTAssertFalse(stale.html.contains("data-pm-mac=\"here-alerts\""), "the Mac never has here: nothing to stand in")
        XCTAssertFalse(stale.html.contains("Where this phone is"))
    }

    /// Beta run 3, B3-01: the payload says when the phone's own fresh reading of home's alerts finds none, for the live
    /// script's band line (the owner's words, pinned here): an empty reading, one whose warning has ended, or one
    /// holding only a watch or an advisory ("finds no warning"); not a reading holding a warning in force, a stale
    /// one, or none, nor while the alerts are the Mac's.
    func testAFreshHomeReadingThatFindsNoneIsMarkedForTheBandLine() {
        XCTAssertEqual(LiveBlock.disagree, "This phone's reading at {mine} finds no warning for home; the Mac's page "
                       + "from {mac} had one. Check the radio or the Weather Service.")
        let quiet = LiveBlock.payload(settings, ["home-alerts": reading(3)], now: now)
        XCTAssertEqual(quiet.homeNoneAt, "2026-10-06T11:57:00-04:00")
        XCTAssertEqual(quiet.disagree, LiveBlock.disagree)
        let over = now.addingTimeInterval(-3600)
        var ended = tornado
        ended.expires = ConditionTime.newYorkISO(over)
        XCTAssertNotNil(LiveBlock.payload(settings, ["home-alerts": reading(3, [ended])], now: now).homeNoneAt,
                        "its own end has passed: none in force")
        XCTAssertNil(LiveBlock.payload(settings, ["home-alerts": reading(3, [tornado])], now: now).homeNoneAt)
        let advisory = ConditionItem("...WIND ADVISORY IN EFFECT UNTIL 6 PM EDT...", flag: "warn",
                                     expires: "2026-10-06T18:00:00-04:00", code: "WI.Y")
        XCTAssertNotNil(LiveBlock.payload(settings, ["home-alerts": reading(3, [advisory])], now: now).homeNoneAt,
                        "an advisory is no warning")
        let watch = ConditionItem("...TORNADO WATCH IN EFFECT UNTIL 3 PM EDT...", flag: "warn",
                                  expires: "2026-10-06T15:00:00-04:00", code: "TO.A")
        XCTAssertNotNil(LiveBlock.payload(settings, ["home-alerts": reading(3, [watch])], now: now).homeNoneAt,
                        "nor is a watch")
        XCTAssertNil(LiveBlock.payload(settings, ["home-alerts": reading(150)], now: now).homeNoneAt, "stale")
        XCTAssertNil(LiveBlock.payload(settings, [:], now: now).homeNoneAt)
        XCTAssertNil(LiveBlock.payload(alertsOff, ["home-alerts": reading(3)], now: now).homeNoneAt, "the Mac's copy")
        XCTAssertNil(LiveBlock.payload(settings, ["outages": reading(3)], now: now).homeNoneAt)
        XCTAssertEqual(LiveBlock.payload(settings, ["home-alerts": reading(3)], now: now, device: "iPad").disagree,
                       "This iPad's reading at {mine} finds no warning for home; the Mac's page from {mac} had one. "
                       + "Check the radio or the Weather Service.")
    }

    /// F-093 (the owner's click, 2026-10-21): the same mark for an evacuation order for home: a fresh evacuations reading
    /// that names none for home (empty, or only other counties' orders), not one naming home's, a stale one or none;
    /// the line in the owner's words.
    func testAFreshEvacuationReadingThatNamesNoneForHomeIsMarked() {
        XCTAssertEqual(LiveBlock.evacDisagree, "This phone's reading at {mine} finds no evacuation order for home; the "
                       + "Mac's page from {mac} had one. Check the radio or local officials.")
        let quiet = LiveBlock.payload(settings, ["evacuations": reading(3)], now: now)
        XCTAssertEqual(quiet.evacNoneAt, "2026-10-06T11:57:00-04:00")
        XCTAssertEqual(quiet.evacDisagree, LiveBlock.evacDisagree)
        let home = ConditionItem("Example County", detail: "Example County\nLeave by noon.", flag: "warn", code: "EVAC.HOME")
        let elsewhere = ConditionItem("Made-up County", detail: "Made-up County\nLeave now.", flag: "warn")
        XCTAssertNil(LiveBlock.payload(settings, ["evacuations": reading(3, [home])], now: now).evacNoneAt)
        XCTAssertNotNil(LiveBlock.payload(settings, ["evacuations": reading(3, [elsewhere])], now: now).evacNoneAt,
                        "another county's order is none for home")
        XCTAssertNil(LiveBlock.payload(settings, ["evacuations": reading(150)], now: now).evacNoneAt, "stale")
        XCTAssertNil(LiveBlock.payload(settings, [:], now: now).evacNoneAt)
        XCTAssertEqual(LiveBlock.limitsOnly(device: "iPad").evacDisagree, "This iPad's reading at {mine} finds no "
                       + "evacuation order for home; the Mac's page from {mac} had one. Check the radio or local officials.")
    }

    /// An iPad's block says "iPad" in the phone's own words (ThisDevice, 2026-10-18); "phone" is the default.
    func testAnIPadSaysIPadInItsOwnWords() {
        let away = LiveReading(goodAt: now, items: [tornado], area: "Elsewhere ZZ", zone: "ZZZ099")
        let iPad = LiveBlock.payload(settings, ["here-alerts": away], now: now, device: "iPad")
        XCTAssertTrue(iPad.html.contains("Read on this iPad"))
        XCTAssertTrue(iPad.html.contains("Where this iPad is: Elsewhere ZZ"))
        XCTAssertTrue(iPad.html.contains("This iPad hasn&#x27;t read it in the last 2 hours."))
        XCTAssertFalse(iPad.html.contains("this phone") || iPad.html.contains("This phone"))
        XCTAssertEqual(iPad.macNewer, "The Mac's copy, above, is newer than this iPad's last reading.")
        XCTAssertEqual(LiveBlock.limitsOnly(device: "iPad").macNewer, iPad.macNewer)
    }

    func testAZoneForecastFoldsAfterFourPeriods() {
        let periods = (1...14).map { ConditionItem("Period \($0): Sunny.") }
        let payload = LiveBlock.payload(settings, ["home-forecast": reading(5, periods)], now: now)
        XCTAssertTrue(payload.html.contains("<details><summary>Next 5 days (10)</summary>"))
    }

    /// The payloads dashboard/tests/test_live_script.py runs the page's live script on, against the Mac's own
    /// fixture page (dashboard/tests/pages.py, whose NOW this is), in the app's own words: rewritten with
    /// PREPAREME_WRITE_FIXTURE=1 after a deliberate change, otherwise they must be what payload() gives now.
    func testThePayloadsTheScriptTestReadsAreCurrent() throws {
        let quiet = ConditionItem("Tonight: Clear.")
        var fresh: [String: LiveReading] = [:]
        for sid in ["home-alerts", "evacuations", "gauge-1", "crest-1", "outages", "tropical-outlook", "storms"] {
            fresh[sid] = reading(3)
        }
        fresh["home-forecast"] = reading(3, [quiet])
        let payloads: [String: LivePayload] = [
            "all-live-quiet": LiveBlock.payload(settings, fresh, now: now),
            "live-tornado": LiveBlock.payload(settings, ["home-alerts": reading(3, [tornado])], now: now,
                                              guides: ["tornado.html", "evacuation.html"]),
            // R9.1: its own instruction in the band, and the rally point's name the app adds
            "live-tornado-told": { () -> LivePayload in
                var told = tornado
                told.instruction = "TAKE COVER NOW! Move to an interior room. Avoid windows."
                var made = LiveBlock.payload(settings, ["home-alerts": reading(3, [told])], now: now)
                made.rally = "Made-up park meeting spot"
                return made
            }(),
            "live-watch": LiveBlock.payload(settings, ["home-alerts": reading(3, [ConditionItem(
                "...TORNADO WATCH IN EFFECT UNTIL 3 PM EDT...", detail: "Be ready to take shelter.", flag: "warn",
                expires: "2026-10-06T15:00:00-04:00", code: "TO.A", vtec: ["NEW.KSPC.TO.A.0590"])])], now: now),
            "live-advisory": LiveBlock.payload(settings, ["home-alerts": reading(3, [ConditionItem(
                "...WIND ADVISORY IN EFFECT UNTIL 6 PM EDT...", detail: "Gusts to 45 mph.", flag: "warn",
                expires: "2026-10-06T18:00:00-04:00", code: "WI.Y", vtec: ["NEW.KLWX.WI.Y.0003"])])], now: now),
            "nothing-read": LiveBlock.payload(settings, [:], now: now),
            // offline fixes, task 3.2: a copy and a last reach of the Mac 4 days old
            "inventory-old": { () -> LivePayload in
                var made = LiveBlock.payload(settings, [:], now: now)
                made.inventoryAge = LiveBlock.inventoryAgeLine(copy: now.addingTimeInterval(-4 * 86400),
                                                               reached: now.addingTimeInterval(-4 * 86400), now: now,
                                                               zone: TimeZone(identifier: "America/New_York")!)
                return made
            }(),
            "read-only": LiveBlock.payload(settings, [:], now: now, host: "phone-readonly"),
            "alerts-off": LiveBlock.payload(alertsOff.self, fresh, now: now),
            "limits-only": LiveBlock.limitsOnly(),
            // 10:05, older than the Mac fixture page's 11:55 reading (review C1).
            "older-quiet": LiveBlock.payload(settings, ["home-alerts": reading(115)], now: now),
            // offline fixes, task 4.1: a phone reading 3 hours old, the Mac's copy 2 days old (the Mac gone)
            "own-newer-than-mac": LiveBlock.payload(settings, ["home-alerts": reading(180)], now: now,
                                                    macAt: ["home-alerts": now.addingTimeInterval(-2 * 86400)]),
            // B3-01: a phone reading of home's alerts past its 2 hours, so the Mac's copy stands
            "stale-quiet": LiveBlock.payload(settings, ["home-alerts": reading(150)], now: now),
            // Chicago, in its own zone: the phone's own sun times where it is (step 6, part 4)
            "sky-away": { () -> LivePayload in
                var away = LiveBlock.payload(settings, [:], now: now)
                away.sky = Sky.here(latitude: 41.8781, longitude: -87.6298, now: now,
                                    in: TimeZone(identifier: "America/Chicago")!)
                return away
            }(),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(payloads) + Data("\n".utf8)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/conditions/live-payloads.json")
        if ProcessInfo.processInfo.environment["PREPAREME_WRITE_FIXTURE"] == "1" {
            try data.write(to: url)
        }
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), String(decoding: data, as: UTF8.self),
                       "rewrite with PREPAREME_WRITE_FIXTURE=1 swift test --filter LiveBlockTests")
    }

    /// Offline fixes, task 3.2: Today's inventory age line, over 3 days old only, and none with no copy
    func testTheInventoryAgeLine() {
        let now = ISO8601DateFormatter().date(from: "2026-10-23T16:00:00Z")!
        let zone = TimeZone(identifier: "America/New_York")!
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        XCTAssertEqual(LiveBlock.inventoryAgeLine(copy: ago(4), reached: ago(4), now: now, zone: zone),
                       "Inventory copy from Oct 19; the Mac was last reached Oct 19.")
        XCTAssertEqual(LiveBlock.inventoryAgeLine(copy: ago(4), reached: ago(0.1), now: now, zone: zone),
                       "Inventory copy from Oct 19; the Mac was last reached Oct 23.", "the app quit on the Mac")
        XCTAssertNil(LiveBlock.inventoryAgeLine(copy: ago(2), reached: ago(2), now: now, zone: zone))
        XCTAssertEqual(LiveBlock.inventoryAgeLine(copy: ago(1), reached: nil, now: now, zone: zone),
                       "Inventory copy from Oct 22; this device hasn't reached the Mac.", "a copy from the backup")
        XCTAssertNil(LiveBlock.inventoryAgeLine(copy: nil, reached: ago(10), now: now, zone: zone))
    }

    struct CountCase: Decodable {
        let feed: String
        let items: [ConditionItem]
        let counts: [String: Int]
    }

    /// FeedCounts gives the Mac's counts (dashboard/feed_counts.py) for every case in the shared file.
    func testEachFeedIsCountedAsTheMacCountsIt() throws {
        struct Counts: Decodable { let counts: [CountCase] }
        let url = try SharedCases.url.skippingWhenAbsent()
        let cases = try JSONDecoder().decode(Counts.self, from: Data(contentsOf: url)).counts
        XCTAssertGreaterThan(cases.count, 12)
        for found in cases {
            XCTAssertEqual(FeedCounts.counts(found.feed, found.items), found.counts, found.feed)
            XCTAssertEqual(Set(found.counts.keys), Set(FeedCounts.keys[found.feed] ?? []), found.feed)
        }
    }

    func testFeedTextIsEscaped() {
        let odd = ConditionItem("<script>alert(1)</script> & \"quotes\"", flag: "warn")
        let payload = LiveBlock.payload(settings, ["home-alerts": reading(5, [odd])], now: now)
        XCTAssertFalse(payload.html.contains("<script>"))
        XCTAssertTrue(payload.html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quotes&quot;"))
    }
}
