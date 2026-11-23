import Foundation
import PrepareMeShared
import Testing

/// The hours where the phone is (forecast-detail plan, phase 3): the lookup's grid address, the grid forecast read
/// hour by hour, the Mac's hour rows (the shared cases' "hours"), and the fold under the forecast for that place only.
struct HereHoursTests {
    static let dc = "Fixtures/conditions/nws/dc-grid-2026-10-29/"
    static let newYork = TimeZone(identifier: "America/New_York")!

    static func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(path))
    }

    static func cases() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: SharedCases.url)) as! [String: Any]
    }

    /// The DC grid with `change` made to its properties.
    static func grid(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var top = try JSONSerialization.jsonObject(with: fixture(dc + "api-gridpoints.json")) as! [String: Any]
        var properties = top["properties"] as! [String: Any]
        change(&properties)
        top["properties"] = properties
        return try JSONSerialization.data(withJSONObject: top)
    }

    // MARK: The lookup

    @Test func theLookupKeepsItsGridAddress() throws {
        let place = try NWSAPI.points(Self.fixture(Self.dc + "api-points.json"))
        #expect(place.zone == "DCZ001")
        #expect(place.grid == URL(string: "https://api.weather.gov/gridpoints/LWX/97,71"))
    }

    @Test(arguments: ["http://api.weather.gov/gridpoints/LWX/97,71", "https://example.com/gridpoints/LWX/97,71",
                      "https://api.weather.gov/gridpoints/LWX/97,71?x=1", "https://api.weather.gov/zones/LWX/97,71",
                      "https://api.weather.gov/gridpoints/LWX/97,71/forecast", "not a url"])
    func aGridAddressAnywhereElseIsNotKept(_ address: String) throws {
        var top = try JSONSerialization.jsonObject(with: Self.fixture(Self.dc + "api-points.json")) as! [String: Any]
        var properties = top["properties"] as! [String: Any]
        properties["forecastGridData"] = address
        top["properties"] = properties
        let place = try NWSAPI.points(JSONSerialization.data(withJSONObject: top))
        #expect(place.grid == nil)
        #expect(place.zone == "DCZ001", "the rest of the lookup still reads")
    }

    // MARK: The grid, hour by hour

    @Test func theDCGridReadsHourByHour() throws {
        let hours = try NWSAPI.hours(Self.fixture(Self.dc + "api-gridpoints.json"), zone: Self.newYork)
        #expect(hours.count == 181, "every hour the temperatures cover")
        #expect(hours[0].text == "8 AM")
        #expect(hours[0].when == "2026-10-29T08:00:00-04:00")
        #expect(hours[0].hour == ConditionHour(pop: "0", temp: "49", wind: "0"), "calm; a 2 mph gust isn't shown")
        #expect(hours[1].hour == ConditionHour(pop: "0", temp: "52", wind: "S 1"))
        #expect(hours[3].hour == ConditionHour(pop: "0", temp: "62", wind: "SSW 3"))
        #expect(hours.allSatisfy { $0.hour?.rain == "" }, "a dry week")
        #expect(zip(hours, hours.dropFirst()).allSatisfy {
            ConditionTime.moment($1.when)!.timeIntervalSince(ConditionTime.moment($0.when)!) == 3600
        })
    }

    @Test func theClockIsWhereThePhoneIs() throws {
        let hours = try NWSAPI.hours(Self.fixture(Self.dc + "api-gridpoints.json"),
                                     zone: TimeZone(identifier: "America/Denver")!)
        #expect(hours[0].text == "6 AM")
    }

    @Test func rainGoesOnItsSpansFirstHourWithItsLengthAndThunderUnderItsHours() throws {
        let data = try Self.grid { p in
            p["quantitativePrecipitation"] = ["uom": "wmoUnit:mm", "values": [
                ["validTime": "2026-10-29T12:00:00+00:00/PT6H", "value": 5.08],
                ["validTime": "2026-10-29T18:00:00+00:00/PT1H", "value": 0.0254],
            ]]
            p["windGust"] = ["uom": "wmoUnit:km_h-1", "values": [["validTime": "2026-10-29T12:00:00+00:00/PT2H",
                                                                   "value": 40.2336]]]
            p["apparentTemperature"] = ["uom": "wmoUnit:degC", "values": [["validTime": "2026-10-29T12:00:00+00:00/PT1H",
                                                                           "value": 5.0]]]
            p["weather"] = ["values": [
                ["validTime": "2026-10-29T12:00:00+00:00/PT1H",
                 "value": [["coverage": "slight_chance", "weather": "thunderstorms"]]],
                ["validTime": "2026-10-29T13:00:00+00:00/PT1H",
                 "value": [["coverage": "likely", "weather": "rain_showers"], ["weather": "thunderstorms"]]],
            ]]
        }
        let hours = try NWSAPI.hours(data, zone: Self.newYork)
        #expect(hours[0].hour?.rain == "0.2" && hours[0].hour?.rainHours == 6)
        #expect(hours[1].hour?.rain == "", "the span's amount once, on its first hour")
        #expect(hours[6].hour?.rain == "0.001" && hours[6].hour?.rainHours == 1)
        #expect(hours[0].hour?.gust == "25")
        #expect(hours[0].hour?.feels == "41")
        #expect(hours[0].hour?.storm == "slight chance")
        #expect(hours[1].hour?.storm == NWSAPI.stormUnsaid)
        #expect(hours[2].hour?.storm == "")
        let row = LiveBlock.hourRow(hours[0])
        #expect(row.contains("<small>0.20 in over 6 hours</small>"))
        #expect(LiveBlock.hourRow(hours[6]).contains("<small>under 0.01 in</small>"))
    }

    @Test func aGridWithoutTemperaturesOrChancesIsRefused() throws {
        for change: (inout [String: Any]) -> Void in [
            { $0["temperature"] = nil }, { $0["probabilityOfPrecipitation"] = nil },
            { $0["temperature"] = ["uom": "wmoUnit:degF", "values": [["validTime": "2026-10-29T12:00:00+00:00/PT1H",
                                                                      "value": 50]]] },
        ] {
            #expect(throws: FeedFormatError.self) { try NWSAPI.hours(Self.grid(change), zone: Self.newYork) }
        }
        #expect(throws: FeedFormatError.self) { try NWSAPI.hours(Data("nope".utf8), zone: Self.newYork) }
    }

    @Test func aSeriesInAnotherUnitLeavesItsFieldEmpty() throws {
        let data = try Self.grid { $0["windSpeed"] = ["uom": "wmoUnit:m_s-1", "values": [] as [Any]] }
        let hours = try NWSAPI.hours(data, zone: Self.newYork)
        #expect(hours[1].hour?.wind == "")
    }

    // MARK: The Mac's rows

    @Test(.enabled(if: SharedCases.present)) func eachRowIsTheMacsRow() throws {
        let found = try Self.cases()["hours"] as! [[String: Any]]
        #expect(found.count == 5)
        for one in found {
            let f = one["item"] as! [String: String]
            let item = ConditionItem(f["text"]!, when: f["when"], hour: ConditionHour(
                pop: f["pop"]!, temp: f["temp"]!, feels: f["feels"]!, wind: f["wind"]!, gust: f["gust"]!,
                rain: f["rain"]!, storm: f["storm"]!))
            #expect(LiveBlock.hourRow(item) == one["html"] as? String, "\(f["text"]!)")
        }
    }

    @Test(.enabled(if: SharedCases.present)) func theWordsAreTheMacs() throws {
        let copy = try Self.cases()["copy"] as! [String: Any]
        #expect(copy["HOURS_HEAD"] as? [String] == LiveBlock.hoursHead)
        #expect(copy["STORM_UNSAID"] as? String == NWSAPI.stormUnsaid)
    }

    // MARK: The fold

    static let settings = try! ConditionsSettings(Data(#"{"county":"Example","format":1,"gauges":[],"live_alerts":true,"nws_county":"ZZC183","nws_fire_zone":"ZZZ041","nws_zone":"ZZZ041"}"#.utf8))

    static func reading(_ items: [ConditionItem], zone: String = "DCZ001", at: Date) -> LiveReading {
        LiveReading(goodAt: at, items: items, triedAt: at, area: "Washington DC", zone: zone)
    }

    @Test func awayTheForecastWhereThePhoneIsHasTheNextDaysHours() throws {
        let hours = try NWSAPI.hours(Self.fixture(Self.dc + "api-gridpoints.json"), zone: Self.newYork)
        let now = ConditionTime.moment("2026-10-29T14:20:00-04:00")!
        let readings = ["here-forecast": Self.reading([ConditionItem("Tonight: Clear.")], at: now),
                        "here-hours": Self.reading(hours, at: now)]
        let html = LiveBlock.payload(Self.settings, readings, now: now).html
        let fold = try #require(html.range(of: "<details><summary>Hours where").map { String(html[$0.lowerBound...]) })
        #expect(fold.hasPrefix("<details><summary>Hours where this phone is</summary>\n<div><table class=\"hrs\">"))
        let rows = fold.components(separatedBy: "<tr data-hour-end=").count - 1
        #expect(rows == 24)
        #expect(fold.contains("<b>Today</b>") && fold.contains("<b>Thursday</b>") == false)
        #expect(fold.contains("<b>Friday</b>"))
        let first = fold.components(separatedBy: "<tr data-hour-end=")[1]
        #expect(first.contains("<th>2 PM</th>"), "the hour under way first; those gone by left out")
        #expect(fold.components(separatedBy: "<tr data-hour-end=").last!.contains("<th>1 PM</th>"), "a day of them")
        #expect(html.range(of: "Hours where")!.lowerBound > html.range(of: "data-source=\"here-forecast\"")!.lowerBound)
        let ipad = LiveBlock.payload(Self.settings, readings, now: now, device: "iPad").html
        #expect(ipad.contains("<summary>Hours where this iPad is</summary>"))
    }

    @Test func rainUnderWayShowsOnTheFirstHourShown() throws {
        let data = try Self.grid { $0["quantitativePrecipitation"] = ["uom": "wmoUnit:mm", "values": [
            ["validTime": "2026-10-29T12:00:00+00:00/PT6H", "value": 5.08],  // 8 AM to 2 PM where the phone is
            ["validTime": "2026-10-29T18:00:00+00:00/PT6H", "value": 2.54],
        ]] }
        let hours = try NWSAPI.hours(data, zone: Self.newYork)
        func firstRow(at now: Date) throws -> String {
            let html = LiveBlock.payload(Self.settings, ["here-forecast": Self.reading([ConditionItem("Tonight: Clear.")], at: now),
                                                         "here-hours": Self.reading(hours, at: now)], now: now).html
            let fold = try #require(html.range(of: "<details><summary>Hours where").map { String(html[$0.lowerBound...]) })
            return fold.components(separatedBy: "<tr data-hour-end=")[1]
        }
        let first = try firstRow(at: ConditionTime.moment("2026-10-29T10:20:00-04:00")!)
        #expect(first.contains("<th>10 AM</th>") && first.contains("<small>0.20 in over 6 hours</small>"),
                "the block under way keeps its amount")
        let next = try firstRow(at: ConditionTime.moment("2026-10-29T14:20:00-04:00")!)
        #expect(next.contains("<th>2 PM</th>") && next.contains("<small>0.10 in over 6 hours</small>"),
                "its own block, not the one before")
        #expect(hours[2].hour?.rain == "", "the reading itself is unchanged: 10 AM carries no amount of its own")
    }

    @Test func atHomeOrWithoutAForecastThereNoFold() throws {
        let hours = try NWSAPI.hours(Self.fixture(Self.dc + "api-gridpoints.json"), zone: Self.newYork)
        let now = ConditionTime.moment("2026-10-29T14:20:00-04:00")!
        let home = ["here-forecast": Self.reading([ConditionItem("Tonight: Clear.")], zone: "ZZZ041", at: now),
                    "here-hours": Self.reading(hours, zone: "ZZZ041", at: now)]
        #expect(!LiveBlock.payload(Self.settings, home, now: now).html.contains("Hours where"), "in home's zone")
        #expect(!LiveBlock.payload(Self.settings, ["here-hours": Self.reading(hours, at: now)], now: now).html
            .contains("Hours where"), "no forecast where the phone is to put it under")
    }

    @Test func oldOrSpentHoursShowNoFold() throws {
        let hours = try NWSAPI.hours(Self.fixture(Self.dc + "api-gridpoints.json"), zone: Self.newYork)
        let now = ConditionTime.moment("2026-10-29T14:20:00-04:00")!
        let old = now.addingTimeInterval(-13 * 3600)
        let readings = ["here-forecast": Self.reading([ConditionItem("Tonight: Clear.")], at: now),
                        "here-hours": Self.reading(hours, at: old)]
        #expect(!LiveBlock.payload(Self.settings, readings, now: now).html.contains("Hours where"), "past its 12 hours")
        let later = ConditionTime.moment("2026-11-20T12:00:00-05:00")!
        let spent = ["here-forecast": Self.reading([ConditionItem("Tonight: Clear.")], at: later),
                     "here-hours": Self.reading(hours, at: later)]
        #expect(!LiveBlock.payload(Self.settings, spent, now: later).html.contains("Hours where"), "every hour gone by")
    }
}
