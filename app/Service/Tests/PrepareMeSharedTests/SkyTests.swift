import Foundation
@testable import PrepareMeShared
import XCTest

/// The phone's sunrise, sunset, dark and moon (step 6, part 4) against the US Naval Observatory's published tables: the
/// same fixtures the Mac's dashboard/tests/test_sky.py reads (Fixtures/sky), so the Mac and the phone agree with the
/// Observatory and with each other. Washington, DC, Anchorage and Sydney on 15 days of 2026 and 2027 (the daylight saving
/// time changes and both solstices among them), and every new, quarter and full moon of both years.
final class SkyTests: XCTestCase {
    struct Case: Decodable {
        let place: String
        let latitude: Double
        let longitude: Double
        let zone: String
        let date: String
        let sunrise: String?
        let sunset: String?
        let dark: String?
        let light_all_night: Bool
        let phase: String
        let lit: Int
    }

    struct Phase: Decodable {
        let phase: String
        let utc: String
    }

    struct Cases: Decodable { let cases: [Case] }
    struct Phases: Decodable { let phases: [Phase] }

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sky")
    let cases = try! JSONDecoder().decode(Cases.self, from: Data(contentsOf: folder.appendingPathComponent("sky-cases.json"))).cases
    let phases = try! JSONDecoder().decode(Phases.self, from: Data(contentsOf: folder.appendingPathComponent("moon-phases.json"))).phases

    /// Noon on `date` ("2026-10-19") in `zone`.
    func noon(_ date: String, _ zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = date.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    /// "2026-01-03T10:03Z" as a moment.
    func utc(_ text: String) -> Date {
        let format = ISO8601DateFormatter()
        return format.date(from: text.replacingOccurrences(of: "Z", with: ":00Z"))!
    }

    func testTheSunWithinAMinuteOfTheNavalObservatory() {
        for found in cases {
            let zone = TimeZone(identifier: found.zone)!
            let day = noon(found.date, zone)
            for (key, expected, zenith, rising) in [("sunrise", found.sunrise, Sky.riseSet, true),
                                                    ("sunset", found.sunset, Sky.riseSet, false),
                                                    ("dark", found.dark, Sky.civil, false)] {
                let what = "\(found.place) \(found.date) \(key)"
                let event = Sky.sunEvent(on: day, in: zone, latitude: found.latitude, longitude: found.longitude,
                                         zenith: zenith, rising: rising)
                guard let expected else {
                    XCTAssertNil(event, what)
                    continue
                }
                guard let event else { return XCTFail(what) }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                XCTAssertTrue(calendar.isDate(event, inSameDayAs: day), what)
                let parts = calendar.dateComponents([.hour, .minute, .second], from: event)
                let minute = Double(parts.hour! * 60 + parts.minute!) + Double(parts.second!) / 60
                let hm = expected.split(separator: ":").map { Double($0)! }
                XCTAssertLessThanOrEqual(abs(minute - (hm[0] * 60 + hm[1])), 1.0, what)
            }
        }
    }

    func testLightAllNightFarNorthInSummer() {
        let north = cases.filter(\.light_all_night)
        XCTAssertEqual(Set(north.map(\.date)), ["2026-06-21", "2027-07-04"])
        for found in north {
            let zone = TimeZone(identifier: found.zone)!
            let day = Sky.day(noon(found.date, zone), in: zone, latitude: found.latitude, longitude: found.longitude)
            XCTAssertTrue(day.lightAllNight)
            XCTAssertTrue(Sky.sunLine(day, in: zone).contains("light all night"))
        }
    }

    func testTheMoonLitWithinAPointAtNoon() {
        for found in cases {
            let zone = TimeZone(identifier: found.zone)!
            let day = Sky.day(noon(found.date, zone), in: zone, latitude: found.latitude, longitude: found.longitude)
            XCTAssertLessThanOrEqual(abs(day.lit - found.lit), 1, "\(found.place) \(found.date)")
        }
    }

    func testEveryNewQuarterAndFullMoonWithinAnHour() {
        let target = ["New Moon": 0.0, "First Quarter": 90, "Full Moon": 180, "Last Quarter": 270]
        XCTAssertEqual(phases.count, 99)
        for phase in phases {
            let when = utc(phase.utc)
            var low = when.addingTimeInterval(-12 * 3600), high = when.addingTimeInterval(12 * 3600)
            for _ in 0..<40 {
                let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                var gap = (Sky.moonAge(middle) - target[phase.phase]! + 180).truncatingRemainder(dividingBy: 360)
                if gap < 0 { gap += 360 }
                if gap - 180 < 0 { low = middle } else { high = middle }
            }
            XCTAssertLessThanOrEqual(abs(low.timeIntervalSince(when)), 3600, "\(phase.phase) \(phase.utc)")
        }
    }

    func testADayAwayFromAPhaseIsNamedAsTheNavalObservatoryNamesIt() {
        let moments = phases.map { utc($0.utc) }
        var checked = 0
        for found in cases {
            let zone = TimeZone(identifier: found.zone)!
            let day = noon(found.date, zone)
            guard moments.map({ abs($0.timeIntervalSince(day)) }).min()! >= 36 * 3600 else { continue }
            checked += 1
            XCTAssertEqual(Sky.moonPhase(on: day, in: zone).name, found.phase.lowercased(), "\(found.place) \(found.date)")
        }
        XCTAssertGreaterThan(checked, 20)
    }

    /// The Mac's own lines for the same day (dashboard/tests/test_sky.py's test_the_lines), word for word.
    func testTheLinesMatchTheMacs() {
        let zone = TimeZone(identifier: "America/New_York")!
        let today = Sky.day(noon("2026-10-19", zone), in: zone, latitude: 38.8951, longitude: -77.0364)
        XCTAssertEqual(Sky.sunLine(today, in: zone), "Sunrise 7:22 AM, sunset 6:24 PM, dark by 6:51 PM")
        XCTAssertEqual(Sky.moonLine(today), "Moon: waxing gibbous, 59% lit")
        XCTAssertEqual(today.emoji, "🌔")
        let october = Sky.day(noon("2026-10-31", zone), in: zone, latitude: 38.8951, longitude: -77.0364)
        let november = Sky.day(noon("2026-11-01", zone), in: zone, latitude: 38.8951, longitude: -77.0364)
        XCTAssertEqual(october.sunrise.map { Sky.clock($0, in: zone) }, "7:34 AM")
        XCTAssertEqual(november.sunrise.map { Sky.clock($0, in: zone) }, "6:35 AM", "daylight saving time over")
        let north = TimeZone(identifier: "America/Anchorage")!
        let winter = Sky.day(noon("2026-12-21", north), in: north, latitude: 71.29, longitude: -156.79)
        XCTAssertEqual(Sky.sunLine(winter, in: north), "The sun stays down all day")
        let summer = Sky.day(noon("2026-06-21", north), in: north, latitude: 71.29, longitude: -156.79)
        XCTAssertEqual(Sky.sunLine(summer, in: north), "The sun stays up all day")
    }

    /// The line "Where this phone is" (Chicago, in its own zone, as dashboard/sky.py gives it): its date, its words and
    /// its times as minutes, never the position; an iPad says so.
    func testThePhonesOwnLineHoldsTimesOnly() throws {
        let zone = TimeZone(identifier: "America/Chicago")!
        let here = Sky.here(latitude: 41.8781, longitude: -87.6298, now: noon("2026-10-06", zone), in: zone)
        XCTAssertEqual(here, HereSky(day: "2026-10-06",
                                     line: "Where this phone is: Sunrise 6:53 AM, sunset 6:24 PM, dark by 6:51 PM",
                                     at: [413, 1104, 1131]))
        let json = String(decoding: try JSONEncoder().encode(here), as: UTF8.self)
        XCTAssertFalse(json.contains("41.8") || json.contains("87.6"), json)
        let iPad = Sky.here(latitude: 41.8781, longitude: -87.6298, now: noon("2026-10-06", zone), in: zone, device: "iPad")
        XCTAssertTrue(iPad.line.hasPrefix("Where this iPad is: "))
        let north = TimeZone(identifier: "America/Anchorage")!
        XCTAssertEqual(Sky.here(latitude: 71.29, longitude: -156.79, now: noon("2026-12-21", north), in: north).at,
                       [nil, nil, 895], "no sunrise, but twilight ends at 2:55 PM: \"- - 895\" on the Mac")
    }

    /// "You'd arrive after dark" only when the arrival falls after that evening's dark (6:51 PM in Washington on
    /// 2026-10-19) or before the next dawn; never on a night that stays light.
    func testArrivingAfterDark() {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func at(_ hour: Int, _ minute: Int, _ day: Int = 19) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        func arrives(_ now: Date, _ minutes: Double) -> Bool {
            Sky.arrivesAfterDark(now: now, minutes: minutes, in: zone, latitude: 38.8951, longitude: -77.0364)
        }
        XCTAssertFalse(arrives(at(12, 0), 60), "1 PM: daylight")
        XCTAssertFalse(arrives(at(18, 0), 45), "6:45 PM: before dark")
        XCTAssertTrue(arrives(at(18, 0), 55), "6:55 PM: after dark")
        XCTAssertTrue(arrives(at(22, 0), 180), "1 AM the next day")
        XCTAssertTrue(arrives(at(5, 0), 30), "5:30 AM: before dawn")
        XCTAssertFalse(arrives(at(7, 0), 30), "7:30 AM: light")
        // The street map's line: 4.8 km at the slower 2.4 km/h is 2 hours, so setting out at 5 PM arrives at 7 PM,
        // after 6:51 PM; a route counts its way along to its end too.
        let mark = MapMark(kind: .rally, name: "SAMPLE Meet at the big oak", points: [[-77.0, 38.9]])
        let far = Position.Way(mark: mark, meters: 4800, bearing: 0, nearest: [-77.0, 38.9])
        func line(_ way: Position.Way, _ now: Date) -> String? {
            Sky.afterDark(way, latitude: 38.8951, longitude: -77.0364, now: now, in: zone)
        }
        XCTAssertEqual(line(far, at(17, 0)), "You'd arrive after dark")
        XCTAssertNil(line(far, at(16, 0)), "6 PM: light")
        let route = Position.Way(mark: mark, meters: 1200, bearing: 0, nearest: [-77.0, 38.9], toEnd: 3600)
        XCTAssertEqual(line(route, at(17, 0)), Sky.afterDark, "joining it, then along it")
        // Setting out at 6 PM on a 14-hour walk arrives in daylight but walks through the night
        XCTAssertTrue(arrives(at(18, 0), 14 * 60), "through the night")
        // Samoa keeps UTC+13 at 171.8 degrees west (the review): its own day's dawn and dark, so noon there is light
        let apia = TimeZone(identifier: "Pacific/Apia")!
        var samoa = Calendar(identifier: .gregorian)
        samoa.timeZone = apia
        let samoaNoon = samoa.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        XCTAssertFalse(Sky.inTheDark(samoaNoon, in: apia, latitude: -13.83, longitude: -171.76), "Samoa at noon")
        XCTAssertTrue(Sky.inTheDark(samoaNoon.addingTimeInterval(9 * 3600), in: apia, latitude: -13.83,
                                    longitude: -171.76), "Samoa at 9 PM")
        let dusk = try! XCTUnwrap(Sky.sunEvent(on: samoaNoon, in: apia, latitude: -13.83, longitude: -171.76,
                                               zenith: Sky.civil, rising: false))
        XCTAssertTrue(samoa.isDate(dusk, inSameDayAs: samoaNoon))
        let north = TimeZone(identifier: "America/Anchorage")!
        // Anchorage on June 1: dark by 1:09 AM, so 12:30 AM on June 2 is still the evening's twilight (the review)
        var alaska = Calendar(identifier: .gregorian)
        alaska.timeZone = north
        let late = alaska.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 0, minute: 30))!
        XCTAssertFalse(Sky.inTheDark(late, in: north, latitude: 61.22, longitude: -149.9), "12:30 AM: twilight")
        XCTAssertTrue(Sky.inTheDark(late.addingTimeInterval(3600), in: north, latitude: 61.22, longitude: -149.9),
                      "1:30 AM: dark")
        let midsummer = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: north, year: 2026, month: 6,
                                                                                    day: 21, hour: 23, minute: 30))!
        XCTAssertFalse(Sky.arrivesAfterDark(now: midsummer, minutes: 60, in: north, latitude: 71.29, longitude: -156.79),
                       "light all night: never after dark")
        let midwinter = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: north, year: 2026, month: 12,
                                                                                    day: 21, hour: 12))!
        XCTAssertFalse(Sky.inTheDark(midwinter, in: north, latitude: 61.22, longitude: -149.9), "Anchorage at noon")
    }
}
