import Foundation

/// Sunrise, sunset, dark and the moon (concept-doc plan, phase E; step 6, part 4), the phone's own copy of the Mac's
/// dashboard/sky.py for where the phone is: the line "Where you are" on Today away from home, and the street map's
/// "You'd arrive after dark". The same formulas: the sun is NOAA's solar calculator's (Meeus), each event worked out three
/// times; sunrise and sunset at 90.833 degrees from overhead, dark at the end of civil twilight (96); the moon is Meeus's
/// short series. Both are checked against the US Naval Observatory's tables, the fixtures the Mac's tests read too
/// (Tests/PrepareMeSharedTests/Fixtures/sky). The position is used here and never kept.
public enum Sky {
    public static let riseSet = 90.833
    public static let civil = 96.0

    public struct Day: Equatable, Sendable {
        public let sunrise: Date?
        public let sunset: Date?
        public let dark: Date?
        public let lightAllNight: Bool
        public let upAllDay: Bool
        public let phase: String
        public let emoji: String
        public let lit: Int
    }

    static func julian(_ date: Date) -> Double { date.timeIntervalSince1970 / 86400 + 2440587.5 }

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// (the sun's declination, degrees; the equation of time, minutes) at Julian day `jd`, by NOAA's formulas.
    static func sun(_ jd: Double) -> (declination: Double, equation: Double) {
        let t = (jd - 2451545) / 36525
        let meanLong = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let anomaly = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let ecc = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let center = sin(radians(anomaly)) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(radians(2 * anomaly)) * (0.019993 - 0.000101 * t) + sin(radians(3 * anomaly)) * 0.000289
        let apparent = meanLong + center - 0.00569 - 0.00478 * sin(radians(125.04 - 1934.136 * t))
        let obliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
            + 0.00256 * cos(radians(125.04 - 1934.136 * t))
        let declination = degrees(asin(sin(radians(obliquity)) * sin(radians(apparent))))
        let y = pow(tan(radians(obliquity / 2)), 2)
        let equation = 4 * degrees(y * sin(2 * radians(meanLong)) - 2 * ecc * sin(radians(anomaly))
                                   + 4 * ecc * y * sin(radians(anomaly)) * cos(2 * radians(meanLong))
                                   - 0.5 * y * y * sin(4 * radians(meanLong)) - 1.25 * ecc * ecc * sin(2 * radians(anomaly)))
        return (declination, equation)
    }

    /// Midnight UTC of the solar day around the local noon of the calendar day `day` holds in `zone`: the UTC date of
    /// the place's own clock time then (local noon plus 4 minutes a degree of longitude), so a zone across the date line
    /// from its longitude (Samoa, Kiribati) gets its own day's events, not the next (the review). The Mac's sun_event.
    static func utcMidnight(of day: Date, in zone: TimeZone, longitude: Double) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let noon = local.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.startOfDay(for: noon.addingTimeInterval(4 * longitude * 60))
    }

    /// When on the calendar day `day` holds in `zone` the sun's center crosses `zenith` degrees from overhead, rising
    /// or setting; nil when it doesn't that day.
    public static func sunEvent(on day: Date, in zone: TimeZone, latitude: Double, longitude: Double, zenith: Double,
                                rising: Bool) -> Date? {
        let midnight = utcMidnight(of: day, in: zone, longitude: longitude)
        var minutes = 720 - 4 * longitude
        for _ in 0..<3 {
            let (declination, equation) = sun(julian(midnight.addingTimeInterval(minutes * 60)))
            let cosAngle = cos(radians(zenith)) / (cos(radians(latitude)) * cos(radians(declination)))
                - tan(radians(latitude)) * tan(radians(declination))
            guard abs(cosAngle) <= 1 else { return nil }
            let angle = degrees(acos(cosAngle))
            minutes = 720 - 4 * longitude - equation + (rising ? -4 * angle : 4 * angle)
        }
        return midnight.addingTimeInterval(minutes * 60)
    }

    /// (the moon's phase angle, its true elongation from the sun) in degrees at `date` (Meeus, chapter 48).
    static func moonTerms(_ date: Date) -> (angle: Double, elongation: Double) {
        func turn(_ value: Double) -> Double { let x = value.truncatingRemainder(dividingBy: 360); return x < 0 ? x + 360 : x }
        let t = (julian(date) - 2451545) / 36525
        let elongation = turn(297.8501921 + 445267.1114034 * t - 0.0018819 * t * t)
        let sunAnomaly = turn(357.5291092 + 35999.0502909 * t)
        let moonAnomaly = turn(134.9633964 + 477198.8675055 * t + 0.0087414 * t * t)
        let terms = 6.289 * sin(radians(moonAnomaly)) - 2.1 * sin(radians(sunAnomaly))
            + 1.274 * sin(radians(2 * elongation - moonAnomaly)) + 0.658 * sin(radians(2 * elongation))
            + 0.214 * sin(radians(2 * moonAnomaly)) + 0.11 * sin(radians(elongation))
        let trueElongation = turn(elongation + terms)
        return (180 - trueElongation, trueElongation)
    }

    public static func moonLit(_ date: Date) -> Double { (1 + cos(radians(moonTerms(date).angle))) / 2 }

    /// 0 new, 90 first quarter, 180 full, 270 last quarter.
    public static func moonAge(_ date: Date) -> Double { moonTerms(date).elongation }

    /// The phase's name and emoji on the calendar day `day` holds in `zone`, as the Mac names it.
    public static func moonPhase(on day: Date, in zone: TimeZone) -> (name: String, emoji: String) {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let start = local.startOfDay(for: day)
        let end = local.date(byAdding: .day, value: 1, to: start)!
        let first = moonAge(start)
        var span = (moonAge(end) - first).truncatingRemainder(dividingBy: 360)
        if span < 0 { span += 360 }
        for (target, name, emoji) in [(0.0, "new moon", "🌑"), (90, "first quarter", "🌓"), (180, "full moon", "🌕"),
                                      (270, "last quarter", "🌗")] {
            var gap = (target - first).truncatingRemainder(dividingBy: 360)
            if gap < 0 { gap += 360 }
            if gap < span { return (name, emoji) }
        }
        let age = moonAge(start.addingTimeInterval(12 * 3600))
        switch age {
        case ..<90: return ("waxing crescent", "🌒")
        case ..<180: return ("waxing gibbous", "🌔")
        case ..<270: return ("waning gibbous", "🌖")
        default: return ("waning crescent", "🌘")
        }
    }

    public static func day(_ day: Date, in zone: TimeZone, latitude: Double, longitude: Double) -> Day {
        let rise = sunEvent(on: day, in: zone, latitude: latitude, longitude: longitude, zenith: riseSet, rising: true)
        let set = sunEvent(on: day, in: zone, latitude: latitude, longitude: longitude, zenith: riseSet, rising: false)
        let dark = sunEvent(on: day, in: zone, latitude: latitude, longitude: longitude, zenith: civil, rising: false)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let noon = local.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        let declination = sun(julian(noon)).declination
        let sunUp = 90 - abs(latitude - declination) > 0
        let phase = moonPhase(on: day, in: zone)
        return Day(sunrise: rise, sunset: set, dark: dark, lightAllNight: dark == nil && (set != nil || sunUp),
                   upAllDay: rise == nil && set == nil && sunUp, phase: phase.name, emoji: phase.emoji,
                   lit: Int((moonLit(noon) * 100).rounded()))
    }

    /// "7:22 AM" in `zone`, rounded to the minute.
    public static func clock(_ date: Date, in zone: TimeZone) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "h:mm a"
        return format.string(from: date.addingTimeInterval(30))
    }

    /// "Sunrise 7:22 AM, sunset 6:24 PM, dark by 6:51 PM", or what happens instead: the Mac's sun_line.
    public static func sunLine(_ sky: Day, in zone: TimeZone) -> String {
        if sky.sunrise == nil && sky.sunset == nil {
            return sky.upAllDay ? "The sun stays up all day" : "The sun stays down all day"
        }
        var parts = [sky.sunrise.map { "Sunrise \(clock($0, in: zone))" }, sky.sunset.map { "sunset \(clock($0, in: zone))" }]
            .compactMap { $0 }
        if let dark = sky.dark {
            parts.append("dark by \(clock(dark, in: zone))")
        } else if sky.lightAllNight {
            parts.append("light all night")
        }
        let words = parts.joined(separator: ", ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// "Moon: waxing gibbous, 60% lit": the Mac's moon_line.
    public static func moonLine(_ sky: Day) -> String { "Moon: \(sky.phase), \(sky.lit)% lit" }

    /// Whether `moment` falls in the dark where the place is: before that day's dawn or after its dark (the start and
    /// end of civil twilight), or on a day the sun never gets within 6 degrees of the horizon. Never on a night that
    /// stays light, nor before the previous evening's dark when that falls after midnight (Anchorage in June: the
    /// review).
    public static func inTheDark(_ moment: Date, in zone: TimeZone, latitude: Double, longitude: Double) -> Bool {
        let dawn = sunEvent(on: moment, in: zone, latitude: latitude, longitude: longitude, zenith: civil, rising: true)
        let dusk = sunEvent(on: moment, in: zone, latitude: latitude, longitude: longitude, zenith: civil, rising: false)
        if let before = sunEvent(on: moment.addingTimeInterval(-86400), in: zone, latitude: latitude,
                                 longitude: longitude, zenith: civil, rising: false), moment < before {
            return false
        }
        if dawn == nil && dusk == nil {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = zone
            let noon = local.date(bySettingHour: 12, minute: 0, second: 0, of: moment)!
            return 90 - abs(latitude - sun(julian(noon)).declination) < 90 - civil  // dark all day
        }
        if let dawn, moment < dawn { return true }
        if let dusk, moment >= dusk { return true }
        return false
    }

    /// Whether someone setting out at `now` and walking `minutes` would arrive in the dark, or walk through dark on
    /// the way (setting out at 6 PM to arrive at 8 AM: the review): the street map's "You'd arrive after dark".
    public static func arrivesAfterDark(now: Date, minutes: Double, in zone: TimeZone, latitude: Double,
                                        longitude: Double) -> Bool {
        let arrival = now.addingTimeInterval(minutes * 60)
        if inTheDark(arrival, in: zone, latitude: latitude, longitude: longitude) { return true }
        var day = now.addingTimeInterval(-86400)
        while day <= arrival {
            if let dusk = sunEvent(on: day, in: zone, latitude: latitude, longitude: longitude, zenith: civil,
                                   rising: false), dusk > now, dusk <= arrival {
                return true
            }
            day = day.addingTimeInterval(86400)
        }
        return false
    }

    /// Under a rally point or route on the street map when walking there at the slower rate (Position.walkingKPH.slow,
    /// to where a route is joined and then along it to its end) from where the phone is, setting out now, would arrive
    /// in the dark.
    public static let afterDark = "You'd arrive after dark"

    /// `afterDark` for `way` from (`latitude`, `longitude`) at `now`, or nil when the walk ends in daylight.
    public static func afterDark(_ way: Position.Way, latitude: Double, longitude: Double, now: Date,
                                 in zone: TimeZone = .current) -> String? {
        let minutes = (way.meters + (way.toEnd ?? 0)) / 1000 / Position.walkingKPH.slow * 60
        return arrivesAfterDark(now: now, minutes: minutes, in: zone, latitude: latitude, longitude: longitude)
            ? afterDark : nil
    }

    /// Minutes after midnight in `zone` ("7:22 AM" is 442), rounded as `clock` rounds; nil for none.
    public static func minutes(_ date: Date?, in zone: TimeZone) -> Int? {
        guard let date else { return nil }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let parts = local.dateComponents([.hour, .minute], from: date.addingTimeInterval(30))
        return parts.hour! * 60 + parts.minute!
    }

    /// The line "Where this phone is" on Today away from home, for the live script (prepareme-live.js) to show under
    /// home's own when any of the times is `apart` minutes or more from home's.
    public static func here(latitude: Double, longitude: Double, now: Date, in zone: TimeZone = .current,
                            device: String = "phone") -> HereSky {
        let sky = day(now, in: zone, latitude: latitude, longitude: longitude)
        return HereSky(day: dayKey(now, in: zone),
                       line: LiveBlock.own(hereLine, device) + sunLine(sky, in: zone),
                       at: [minutes(sky.sunrise, in: zone), minutes(sky.sunset, in: zone), minutes(sky.dark, in: zone)])
    }

    /// "2026-10-19": the date `date` holds in `zone`, as the page marks its sky lines (data-sky-day).
    public static func dayKey(_ date: Date, in zone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }

    public static let hereLine = "Where this phone is: "
    /// About 70 miles east or west of home at home's latitude, or another time zone (judgment call, 2026-10-19: the
    /// phone never holds home's position, so it compares times, which works with no signal).
    public static let apart = 5
}

/// The phone's own sunrise, sunset and dark for the date it is (`day`, "2026-10-19"), worked out from where it is and
/// never kept: only the times and the line go into the payload, never the position.
public struct HereSky: Codable, Equatable, Sendable {
    public var day: String
    public var line: String
    /// Sunrise, sunset and dark as minutes after midnight, nil for one that doesn't happen.
    public var at: [Int?]
    public var apart: Int = Sky.apart
}
