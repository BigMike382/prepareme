import Foundation

/// The phone's own reading of one feed (plan phase 5): its last good items and when, and its last try.
/// `failure` is fixed words (a FeedFormatError's, or the app's words for a network failure), never a feed's bytes.
public struct LiveReading: Codable, Equatable, Sendable {
    public var goodAt: Date?
    public var items: [ConditionItem]
    public var triedAt: Date?
    public var failure: String?
    /// "Here" only: where the lookup placed the phone (the town and state, never the spot) and that place's zone.
    public var area: String?
    public var zone: String?

    public init(goodAt: Date? = nil, items: [ConditionItem] = [], triedAt: Date? = nil, failure: String? = nil,
                area: String? = nil, zone: String? = nil) {
        self.goodAt = goodAt
        self.items = items
        self.triedAt = triedAt
        self.failure = failure
        self.area = area
        self.zone = zone
    }
}

/// What the app hands the front page's live script (PrepareMeApp/prepareme-live.js): the live block's HTML and what
/// it stands for, so the script puts it at the top of the conditions section, moves the Mac's own copy of each feed
/// the phone couldn't read lately into it, hides the Mac's copies of these panels elsewhere, and rewrites the answer
/// box's Needs action line.
public struct LivePayload: Codable, Equatable, Sendable {
    public var html: String
    /// The panels the live block holds, in page order; the Mac's own copies of them are hidden.
    public var panels: [String]
    /// The sources shown from the phone's own reading; the Mac's headlines from them leave the band.
    public var live: [String]
    /// Panels whose every source is the phone's own reading: their Needs action comes from the phone alone.
    public var fullyLive: [String]
    /// The live panels the phone's own readings say need action.
    public var needs: [String]
    public var headings: [String: String]
    public var chipLabels: [String: String]
    public var band: String
    public var oldLine: String
    public var needsLine: String
    public var nothingNeeds: String
    /// Every panel of the page, in its order (the Needs action line's), and the answer box's warning mark.
    public var order: [String]
    public var warnMark: String
    /// The band's mark for each kind of event a phone reading can start, and the line under a phone reading that gave
    /// way to a newer Mac copy.
    public var eventEmoji: [String: String]
    public var macNewer: String
    /// Where the page is read (the Today redesign, plan phase 3): "phone", or "phone-readonly" for a phone that may
    /// not change the lists; the live script marks the page's root with it (data-host).
    public var host: String = "phone"
    /// The Worth a look group's words and mark, for the live script to make the group where the Mac's page has none.
    public var worth: String = LiveBlock.worth
    public var lookMark: String = LiveBlock.lookMark
    /// The panels worth a look in the weather, over the 4-day boxes, not in the Worth a look group (render.py
    /// WEATHER_WORTH; the owner's fix 7, 2026-10-16).
    public var weatherWorth: [String] = LiveBlock.weatherWorth
    /// The phone's own sunrise, sunset and dark where it is (step 6, part 4), when it has a fix; the live script
    /// shows the line only away from home's times.
    public var sky: HereSky? = nil
    /// The rally point the phone's street map points to (beta run 2, R9.1), named on Today's rally line in
    /// `rallyNamed`'s words: the app's, from its copy of the lists; never in the library. nil: the line as built.
    public var rally: String? = nil
    public var rallyNamed: String = LiveBlock.rallyNamed
    /// The guide button of each kind of event the phone's own band lines start (LiveBlock.guideButton), for the live
    /// script to put among the first-aid buttons where the Mac's page has none for it; only guides the library holds
    /// (whole-plan review). "" with none.
    public var guides: String = ""
    /// Beta run 3, B3-01 (the owner's answer a): set when the phone's own reading of home's alerts is fresh (isFresh)
    /// and holds no warning in force (none that needs action: a watch or an advisory is no warning), as that reading's
    /// good time (ISO 8601); nil otherwise. The live script reads it only as a yes or no: with the Mac's page still
    /// carrying a warning for home, it puts `disagree` in the band, its {mine} time copied from the phone block's own
    /// age span (`[data-at] .t`, the same good time) and {mac} from the Mac's block's, so the page's script keeps
    /// both in its format (final review).
    public var homeNoneAt: String? = nil
    public var disagree: String = LiveBlock.disagree
    /// F-093 (the owner's click, 2026-10-21): the same for an evacuation order for home: set when the phone's fresh
    /// evacuations reading names none for home (no line with the evacuation event), and `evacDisagree` the line the script
    /// puts under the Mac's order while the Mac's page still carries one.
    public var evacNoneAt: String? = nil
    public var evacDisagree: String = LiveBlock.evacDisagree
    /// Offline fixes, task 3.2: the line the live script puts with the page's quiet notes, in amber, when the phone's
    /// inventory copy or its last reach of the Mac is over `LiveBlock.inventoryAgeDays` old (inventoryAgeLine); nil
    /// otherwise, and with no copy.
    public var inventoryAge: String? = nil
}

/// The live block (plan phase 5): every panel the phone reads, in the Mac's markup and words, each feed from the
/// phone's own reading while it is under 2 hours old (the build plan's combination rule), else the Mac's copy of that
/// feed, judged by its own limit, with a line saying why. The phone's readings never carry `data-core`, so they never
/// count toward the 24-hour outage rule or the 12-hour banner; their warnings carry the event marks, so event mode is
/// on if either the phone's reading or the Mac's copy says so (the page's own script reads both).
public enum LiveBlock {
    public static let freshFor: TimeInterval = 2 * 3600

    /// The page's host word for a phone (B3-04): the editing words only once the phone has been told it may edit, the
    /// read-only (child's) words before that and for a phone that may not. Worked out at every apply, so a role that
    /// arrives after pairing is in the next page's words.
    public static func host(canEdit: Bool) -> String { canEdit ? "phone" : "phone-readonly" }
    public static let panels = ["alerts", "evacuations", "rivers", "power", "forecast", "hurricanes"]

    // The Mac's words (dashboard/render.py, weather.py, local.py, event.py), held to them by the shared cases' `copy`.
    public static let fetched = "fetched {time} ({age})"
    public static let asOf = "{none} as of {time}."
    public static let lastTry = "last try {time} failed: {reason}"
    public static let oldLine = "Older than {n} hours: there may be newer information."
    public static let endedLine = "This alert's own end time, {time}, has passed."
    /// A band headline whose warning has ended becomes this line, below the band (render.py ENDED_HEAD; B2-27).
    public static let endedHead = "Ended: {event} (until {time})"
    /// After a band warning's instruction when any was left out (render.py, weather.INSTRUCTION_MORE; R9.1 fix round 1).
    public static let instructionMore = "More in the full text below."
    /// Today's rally line on the phone (R9.1), linked to the street map, once the app knows the place.
    public static let rallyNamed = "Meet at: {name}"
    /// Offline fixes, task 3.2: Today says so when the phone's inventory copy, or its last reach of the Mac, is days old
    public static let inventoryAgeDays = 3
    public static let inventoryAge = "Inventory copy from {copy}; the Mac was last reached {mac}."
    public static let inventoryAgeNever = "Inventory copy from {copy}; this device hasn't reached the Mac."

    /// The inventory age line (`inventoryAge`), when the copy (`copy`: its writtenAt) or the last reach of the Mac
    /// (`reached`: nil for never, a copy from the backup) is over `inventoryAgeDays` old; nil otherwise and with no copy.
    /// Dates as "Oct 20" in `zone`.
    public static func inventoryAgeLine(copy: Date?, reached: Date?, now: Date, zone: TimeZone = .current) -> String? {
        guard let copy else { return nil }
        let limit = TimeInterval(inventoryAgeDays) * 86400
        guard now.timeIntervalSince(copy) > limit || reached.map({ now.timeIntervalSince($0) > limit }) ?? true else {
            return nil
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = zone
        day.dateFormat = "MMM d"
        guard let reached else { return inventoryAgeNever.replacingOccurrences(of: "{copy}", with: day.string(from: copy)) }
        return inventoryAge.replacingOccurrences(of: "{copy}", with: day.string(from: copy))
            .replacingOccurrences(of: "{mac}", with: day.string(from: reached))
    }
    /// An alert's end under its headline, and the fold of its tidied full text (the Today redesign's ruling 2).
    public static let until = "until {time}"
    public static let fullText = "Full text from the Weather Service"
    public static let forecastFold = "Next {d} days ({n})"
    public static let foldAfter = 4
    public static let needsLine = "Needs action: {links}."
    public static let warnMark = "⚠️"
    /// render.py EVENT_EMOJI's marks for the kinds a phone reading can start.
    public static let eventEmoji = ["tornado": "🌪️", "flash-flood": "🌊", "hurricane": "🌀", "evacuation": "🚗"]
    /// The guide each of those kinds starts with (event.EVENT_PAGES' first page; a hurricane's is the evacuation guide),
    /// and its band button's words (event.GUIDE_WORDS) and mark (emoji.PAGE_EMOJI): held to the Mac's band by the
    /// shared cases' EVENT_GUIDES and GUIDE_BUTTONS (whole-plan review).
    public static let eventGuides = ["tornado": "tornado", "flash-flood": "floodwater", "hurricane": "evacuation",
                                     "evacuation": "evacuation"]
    static let guideWords = ["tornado": "Tornado guide", "floodwater": "Flood guide", "evacuation": "Evacuation guide"]
    static let guideEmoji = ["tornado": "🌪️", "floodwater": "🌊", "evacuation": "🚗"]
    /// The page's panels in order (dashboard/model.py PANELS).
    public static let pageOrder = ["alerts", "evacuations", "rivers", "roads", "power", "forecast", "outlook", "hurricanes",
                                   "readiness", "todo", "tobuy", "now", "notices"]
    public static let nothingNeeds = "Nothing needs action."
    public static let panelEmoji = ["alerts": "🚨", "evacuations": "🚗", "rivers": "🌊", "power": "⚡",
                                    "forecast": "🌧️", "hurricanes": "🌀"]
    public static let headings = ["alerts": "Weather alerts", "evacuations": "Evacuation orders", "rivers": "Rivers",
                                  "power": "Power outages", "forecast": "Forecast", "hurricanes": "Hurricane outlook"]
    public static let chipLabels = ["alerts": "Weather alerts", "evacuations": "Evacuations", "rivers": "Rivers",
                                    "power": "Power", "hurricanes": "Hurricanes"]
    public static let kindReasons = ["tornado": "a Tornado Warning for home",
                                     "flash-flood": "a Flash Flood Warning for home",
                                     "hurricane": "a Hurricane Warning for home"]
    public static let evacOrderReason = "an evacuation order naming {county} County"
    public static let evacOrderUnnamed = "an evacuation order naming home's county"
    public static let alertsNone = "No active weather alerts for home"
    public static let stormsNone = "No Atlantic storms"
    public static let evacNone = "No evacuations are ordered"
    public static let homeLabel = "Home: National Weather Service"
    public static let nhcLabel = "National Hurricane Center"
    public static let gaugeLabel = "NWS river gauges"
    /// Each source's own limit on the Mac (its Source's stale_hours).
    public static let ownStaleHours: [String: Double] = ["home-alerts": 2, "evacuations": 2, "home-forecast": 12,
                                                         "gauge": 12, "crest": 12, "outages": 12,
                                                         "tropical-outlook": 18, "storms": 18]
    static let floodCategories: Set<String> = ["minor", "moderate", "major"]
    static let eventCodes: [String: [String: String]] = [
        "home-alerts": ["TO.W": "tornado", "FF.W": "flash-flood", "HU.W": "hurricane"],
        "evacuations": ["EVAC.HOME": "evacuation"],
    ]

    // The phone's own words; `own` says "this iPad" in them on an iPad.
    public static let group = "Read on this phone"
    public static let note = "This phone reads these itself while PrepareMe is open. Where the Mac's copy is newer, "
        + "it shows instead, with its age."
    public static let phoneFailed = "This phone couldn't read it ({reason}; last try {time}). Above is the Mac's copy."
    public static let phoneNotYet = "This phone hasn't read it in the last 2 hours. Above is the Mac's copy."
    public static let phoneAlertsOff = "This phone doesn't read the alerts itself yet. Above is the Mac's copy."
    /// A state feed with no state file in the library (Unlisted plan, phase 4: an older library, the backup's copy)
    public static let phoneNoState = "This phone doesn't read these: the library has no state feeds. Above is the "
        + "Mac's copy."
    public static let macMissing = "The Mac's copy doesn't have this one either."
    public static let macNewer = "The Mac's copy, above, is newer than this phone's last reading."
    public static let hereLabel = "Where this phone is: {area}"
    public static let hereAlertsNone = "No active weather alerts where this phone is"
    /// The band's line when this phone's fresh reading finds no alert for home and the Mac's page had a warning (beta
    /// run 3, B3-01; the owner's words): {mine} is the phone's reading time, {mac} the Mac's alerts reading's, in that
    /// order, each as the page shows a time.
    public static let disagree = "This phone's reading at {mine} finds no warning for home; the Mac's page from {mac} "
        + "had one. Check the radio or the Weather Service."
    /// The same for an evacuation order for home (F-093; the owner's click, 2026-10-21).
    public static let evacDisagree = "This phone's reading at {mine} finds no evacuation order for home; the Mac's page "
        + "from {mac} had one. Check the radio or local officials."

    /// One of the words above as this device says them: `device` is "iPad" on an iPad (the app's ThisDevice), and
    /// "phone" leaves them as written, as the shared cases pin them.
    public static func own(_ words: String, _ device: String) -> String {
        words.replacingOccurrences(of: "this phone", with: "this \(device)")
            .replacingOccurrences(of: "This phone", with: "This \(device)")
    }
    public static let weatherLink = "https://www.weather.gov/"
    public static let nhcLink = "https://www.nhc.noaa.gov/"
    public static let gaugeLink = "https://water.noaa.gov/gauges/"

    // MARK: The block

    /// The live block for these settings and readings (keyed by the Mac's source ids: home-alerts, here-alerts,
    /// evacuations, gauge-N, crest-N, outages, home-forecast, here-forecast, tropical-outlook, storms) at `now`.
    /// `guides`: the guide pages the library holds (its guide list's, "tornado.html"), the only ones the band's guide
    /// buttons link to. `macAt`: the time of the Mac's copy of each source on the page (none: the page has none), so a
    /// phone reading over 2 hours old still shows while it is newer (offline fixes, task 4.1: with the Mac gone, its
    /// copy is days old); nil when the page's times couldn't be read, and then the 2 hours alone decide.
    public static func payload(_ settings: ConditionsSettings, _ readings: [String: LiveReading], now: Date,
                               host: String = "phone", device: String = "phone",
                               guides held: Set<String> = [], macAt: [String: Date]? = nil) -> LivePayload
    {
        var html = ["<div class=\"pm-live\" id=\"pm-live\">", "<p class=\"group\">\(esc(own(group, device)))</p>",
                    "<p class=\"note\">\(esc(own(note, device)))</p>"]
        var live: [String] = [], fullyLive: [String] = [], needs: [String] = [], band: [String] = []
        var kinds: [String] = []  // of the band's lines, in its order, for their guide buttons
        var homeNoneAt: String?  // B3-01: the phone's fresh home reading that finds no warning in force
        var evacNoneAt: String?  // F-093: the phone's fresh evacuations reading that names no order for home
        let today = day(now)
        let county = settings.countyName
        for panel in panels {
            var blocks: [String] = [], allLive = true, needed = false, read: [ReadBlock] = []
            for source in sources(panel, settings, readings, now: now, device: device) {
                let reading = readings[source.sid]
                let shown = source.capable && reading.map { useOwn($0, macAt: macAt?[source.sid], known: macAt != nil,
                                                                     now: now) } == true
                guard shown, let reading, let goodAt = reading.goodAt else {
                    allLive = false
                    if source.optional { continue }
                    blocks.append(placeholder(source, reading, today, device: device))
                    continue
                }
                live.append(source.sid)
                let lines = Self.lines(source.sid, reading.items, failed: reading.failure != nil, now: now,
                                       county: county)
                let blockNeeds = lines.contains { needsAction(panel, source.sid, $0) }
                let fresh = isFresh(reading, now)  // B3-01's and F-093's lines speak only from a fresh reading
                if fresh && source.sid == "home-alerts" && !blockNeeds { homeNoneAt = iso(goodAt) }
                if fresh && source.sid == "evacuations"
                    && !lines.contains(where: { $0.event == "evacuation" && !$0.over }) {
                    evacNoneAt = iso(goodAt)
                }
                needed = needed || blockNeeds
                read.append(ReadBlock(sid: source.sid, lines: lines, held: reading.items.count, none: source.none,
                                      goodAt: goodAt, failed: reading.failure != nil && reading.triedAt != nil))
                kinds += lines.compactMap { $0.over ? nil : $0.event }
                band += lines.filter { $0.event != nil && !$0.over }.map {
                    "<p class=\"alert\" data-band-of=\"pm-live\" data-pm-src=\"\(esc(source.sid))\" "
                        + "data-band-kind=\"\(esc($0.event ?? ""))\">"  // its kind, for the marks' row rule (checkpoint 4)
                        + "\(markHTML($0))\(lineHTML($0, today))\(instructionHTML($0.item))</p>"
                }
                blocks.append(liveBlock(source, reading, goodAt, lines, now: now, today: today, needs: blockNeeds))
                if source.sid == "here-forecast", let hours = readings["here-hours"], let at = hours.goodAt,
                   now.timeIntervalSince(at) < (ownStaleHours["home-forecast"] ?? 12) * 3600,
                   let fold = hoursFold(hours.items, now: now, device: device) {
                    blocks.append(fold)
                }
            }
            if allLive { fullyLive.append(panel) }
            if needed { needs.append(panel) }
            // The Today redesign's phase 3: each panel goes where the Mac's page would put it, the live script placing
            // it: a problem card, worth a look (headed by its row's words), a condition row (its words from the
            // phone's own readings while every source of it is the phone's, else the Mac's row stands for it), or
            // for the forecast, its fold under Details.
            let emoji = "<span class=\"em\" aria-hidden=\"true\">\(panelEmoji[panel]!)</span>"
            let (status, words) = !allLive ? ("mac", "") : needed ? ("needs", "") : face(panel, read, now: now)
            let heading = status == "look" ? "\(emoji)\n\(words)\n" : "\(emoji)\(esc(headings[panel]!))"
            var made = ["<div class=\"panel\(needed ? " card" : status == "look" ? " look" : "")\" id=\"pm-panel-\(panel)\">",
                        "<h2>\(heading)</h2>"] + blocks
            made.append("<div data-pm-rest=\"\(panel)\"></div>")  // the Mac's other blocks of the panel (FEMA's)
            if panel == "evacuations", let note = settings.area?.evacNote {
                made.append("<p class=\"note\">\(esc(note))</p>")
            }
            made.append("</div>")
            if panel == "forecast" {
                html += made
                continue
            }
            html.append(row(panel, status, words, read, now: now) + "\n" + made.joined(separator: "\n") + "\n</details>")
        }
        html.append("</div>")
        var made = LivePayload(html: html.joined(separator: "\n"), panels: panels, live: live, fullyLive: fullyLive,
                               needs: needs, headings: headings, chipLabels: chipLabels,
                               band: band.joined(separator: "\n"), oldLine: oldLine, needsLine: needsLine,
                               nothingNeeds: nothingNeeds, order: pageOrder, warnMark: warnMark,
                               eventEmoji: eventEmoji, macNewer: own(macNewer, device), host: host)
        made.guides = guideButtons(kinds, held: held)
        made.homeNoneAt = homeNoneAt
        made.disagree = own(disagree, device)
        made.evacNoneAt = evacNoneAt
        made.evacDisagree = own(evacDisagree, device)
        return made
    }

    /// The band's guide buttons for these kinds, as the Mac's band gives them (render.py `_band_chunks`): each kind's
    /// first page once, for the first kind that names it; only a page the library holds.
    static func guideButtons(_ kinds: [String], held: Set<String>) -> String {
        var given = Set<String>(), out = ""
        for kind in kinds {
            guard let page = eventGuides[kind], given.insert(page).inserted, held.contains(page + ".html") else {
                continue
            }
            out += guideButton(kind)
        }
        return out
    }

    /// One band guide button (render.py `guide_button`), linked to the guide's page beside the front page, as the
    /// packer links the Mac's.
    public static func guideButton(_ kind: String) -> String {
        let page = eventGuides[kind] ?? kind
        let mark = guideEmoji[page].map { "<span class=\"em\" aria-hidden=\"true\">\($0)</span>" } ?? ""
        return "<p class=\"guide-go\" data-kind=\"\(esc(kind))\"><a href=\"\(esc(page)).html\">\(mark)"
            + "\(esc(guideWords[page] ?? page))</a></p>"
    }

    /// What the app sends when the library carries no settings it can read: no live block, only the Mac's copy
    /// judged by each block's own limit.
    public static func limitsOnly(host: String = "phone", device: String = "phone") -> LivePayload {
        var made = LivePayload(html: "", panels: [], live: [], fullyLive: [], needs: [], headings: headings,
                               chipLabels: chipLabels, band: "", oldLine: oldLine, needsLine: needsLine,
                               nothingNeeds: nothingNeeds, order: pageOrder, warnMark: warnMark,
                               eventEmoji: eventEmoji, macNewer: own(macNewer, device), host: host)
        made.disagree = own(disagree, device)
        made.evacDisagree = own(evacDisagree, device)
        return made
    }

    public static func isFresh(_ reading: LiveReading, _ now: Date) -> Bool {
        guard let at = reading.goodAt else { return false }
        return now.timeIntervalSince(at) < freshFor && now.timeIntervalSince(at) > -300
    }

    /// Whether the phone's own block shows (offline fixes, task 4.1): fresh, or, with the page's times `known`, newer
    /// than the Mac's copy (`macAt`; none on the page counts as older), its age said by its own old line. A reading from
    /// the future (a clock set back) never is.
    public static func useOwn(_ reading: LiveReading, macAt: Date?, known: Bool, now: Date) -> Bool {
        guard let at = reading.goodAt, now.timeIntervalSince(at) > -300 else { return false }
        if isFresh(reading, now) { return true }
        guard known else { return false }
        return macAt.map { at > $0 } ?? true
    }

    struct Source {
        let sid: String, label: String, link: String, none: String
        let capable: Bool  // the phone reads it (home's alerts only while live_alerts is on)
        let optional: Bool  // shown only from a fresh reading: "here", which the Mac's copy never has
        let foldAll: Bool  // a zone forecast: its periods carry no time, so all fold after the first four
    }

    static func sources(_ panel: String, _ settings: ConditionsSettings, _ readings: [String: LiveReading],
                        now: Date, device: String = "phone") -> [Source] {
        let here = readings["here-alerts"]?.zone ?? readings["here-forecast"]?.zone
        let away = here != nil && here != settings.zone
        func hereLabel(_ sid: String) -> String {
            hereLabelText(readings[sid]?.area ?? "", device: device)
        }
        switch panel {
        case "alerts":
            return [Source(sid: "home-alerts", label: homeLabel, link: weatherLink, none: alertsNone,
                           capable: settings.liveAlerts, optional: false, foldAll: false)]
                + (away && settings.liveAlerts ? [Source(sid: "here-alerts", label: hereLabel("here-alerts"),
                                                         link: weatherLink, none: own(hereAlertsNone, device), capable: true,
                                                         optional: true, foldAll: false)] : [])
        case "evacuations":
            return [Source(sid: "evacuations", label: settings.area?.agency ?? "", link: settings.area?.agencyLink ?? "",
                           none: evacNone, capable: settings.area != nil, optional: false, foldAll: false)]
        case "rivers":
            return settings.gauges.enumerated().flatMap { n, id -> [Source] in
                let link = gaugeLink + id.lowercased()
                return [Source(sid: "gauge-\(n + 1)", label: gaugeLabel, link: link, none: "", capable: true,
                               optional: false, foldAll: false),
                        Source(sid: "crest-\(n + 1)", label: gaugeLabel, link: link, none: "", capable: true,
                               optional: false, foldAll: false)]
            }
        case "power":
            return [Source(sid: "outages", label: settings.area?.agency ?? "", link: settings.area?.agencyLink ?? "",
                           none: "", capable: settings.area != nil, optional: false, foldAll: false)]
        case "forecast":
            return [Source(sid: "home-forecast", label: homeLabel, link: weatherLink, none: "", capable: true,
                           optional: false, foldAll: true)]
                + (away ? [Source(sid: "here-forecast", label: hereLabel("here-forecast"), link: weatherLink, none: "",
                                  capable: true, optional: true, foldAll: true)] : [])
        default:
            return [Source(sid: "tropical-outlook", label: nhcLabel, link: nhcLink, none: "", capable: true,
                           optional: false, foldAll: false),
                    Source(sid: "storms", label: nhcLabel, link: nhcLink, none: stormsNone, capable: true,
                           optional: false, foldAll: false)]
        }
    }

    static func hereLabelText(_ area: String, device: String = "phone") -> String {
        fill(own(hereLabel, device), ["area": esc(area.isEmpty ? "a place the lookup didn't name" : area)])
    }

    /// The Mac's copy of `source`, moved in by the page's live script, with the line saying why.
    static func placeholder(_ source: Source, _ reading: LiveReading?, _ today: String,
                            device: String = "phone") -> String {
        let why: String
        if !source.capable {
            why = esc(own(["outages", "evacuations"].contains(source.sid) ? phoneNoState : phoneAlertsOff, device))
        } else if let reading, let at = reading.triedAt, let failure = reading.failure {
            why = fill(own(phoneFailed, device), ["reason": esc(failure), "time": t(at, today)])
        } else {
            why = esc(own(phoneNotYet, device))
        }
        return "<div class=\"pm-mac\" data-pm-mac=\"\(esc(source.sid))\">\n<p class=\"fail-line mk-miss\">"
            + "\(esc(macMissing))</p>\n</div>\n<p class=\"note pm-why\">\(why)</p>"
    }

    static func liveBlock(_ source: Source, _ reading: LiveReading, _ goodAt: Date, _ lines: [Line], now: Date,
                          today: String, needs: Bool) -> String {
        let hours = NumberText.g(freshFor / 3600)
        let failed = reading.failure != nil && reading.triedAt != nil
        var body = ["<a class=\"label\" href=\"\(esc(source.link))\">\(source.sid.hasPrefix("here-") ? source.label : esc(source.label))</a>",
                    "<p class=\"age\" data-at=\"\(iso(goodAt))\" data-stale-hours=\"\(hours)\" "
                        + "data-old=\"\(esc(oldLine.replacingOccurrences(of: "{n}", with: hours)))\">"
                        + fill(fetched, ["time": t(goodAt, today),
                                         "age": "<span class=\"n\">\(esc(ageWords(now.timeIntervalSince(goodAt))))</span>"])
                        + "</p>"]
        body += content(source.sid, panel: panel(of: source.sid), none: source.none, lines: lines,
                        held: reading.items.count, goodAt: goodAt, today: today, foldAll: source.foldAll)
        if failed {
            body.append("<p class=\"fail-line mk-miss\">"
                        + fill(lastTry, ["time": t(reading.triedAt!, today), "reason": esc(reading.failure!)]) + "</p>")
        }
        return "<div class=\"src\(failed ? " is-failed" : "")\" data-source=\"\(esc(source.sid))\" data-pm-live=\"1\""
            + (needs ? " data-pm-needs=\"1\"" : "") + ">\n"
            + body.joined(separator: "\n") + "\n</div>"
    }

    static func panel(of sid: String) -> String {
        if sid.hasSuffix("-alerts") { return "alerts" }
        if sid.hasSuffix("-forecast") { return "forecast" }
        if sid.hasPrefix("gauge-") || sid.hasPrefix("crest-") { return "rivers" }
        if sid == "outages" { return "power" }
        if sid == "evacuations" { return "evacuations" }
        return "hurricanes"
    }

    /// The Weather Service's critical alerts count for home and for where the phone is (the owner's required fix 6,
    /// 2026-10-16; until then the phone's own place was quiet): a warning, never a watch (NWSTidy.tier; the owner's
    /// choice 1 of phase L, 2026-10-20).
    static func needsAction(_ panel: String, _ sid: String, _ line: Line) -> Bool {
        switch panel {
        case "alerts": return ["home-alerts", "here-alerts"].contains(sid) && line.item.flag == ConditionItem.warn
            && !line.over && !line.look
        case "evacuations": return line.item.flag == ConditionItem.warn && !line.over
        case "rivers": return floodCategories.contains(line.item.code)
        default: return false
        }
    }

    // MARK: A condition row's words (the Today redesign's phase 3; dashboard/render.py's _face)

    public static let rowFine = ["alerts": "Weather alerts: none for home", "evacuations": "Evacuations: none ordered",
                                 "rivers": "Rivers: none at flood stage", "roads": "Roads: no closures on home roads",
                                 "power": "Power: {count} outages in the county",
                                 "hurricanes": "Hurricanes: no Atlantic storms"]
    public static let rowLook = ["alerts": "Weather alerts: {n} for home", "rivers": "Rivers: {n} at action stage"]
    public static let rowOld = "{label}: last checked {age} ago; may be out of date"
    public static let rowFailed = "{label}: couldn't check since {time}; use a weather radio or local news"
    public static let rowNotFetched = "{label}: not checked yet"
    public static let rowWaiting = "{label}: not set up yet; set it up on the Mac"
    public static let rowLine = "{label}: {line}"
    public static let noOutages = "no"
    public static let outagesHome = "{n} outages reported in {county} County"
    public static let outagesNone = "No outages reported in {county} County"
    public static let worth = "Worth a look"
    public static let noSources = "Nothing has been fetched for this panel yet."
    public static let riversEmpty = "No river gauges set in the dashboard settings."
    public static let lookMark = "🟠", okMark = "✅", oldMark = "🕒"
    /// render.py WEATHER_WORTH: worth a look in the weather, over the 4-day boxes (the owner's fix 7, 2026-10-16).
    public static let weatherWorth = ["alerts"]
    static let unreadFlag = "unread"  // weather.NO_READING_FLAG
    static let chance = try! NSRegularExpression(pattern: "Formation chance through 7 days\\.\\.\\.(?:medium|high)")
    static let outageCount = try! NSRegularExpression(pattern: "^([0-9][0-9,]*) outages reported in ")

    /// One fresh phone reading of a panel, as the row's words read it.
    public struct ReadBlock {
        let sid: String
        let lines: [Line]
        let held: Int
        let none: String
        let goodAt: Date
        let failed: Bool
    }

    /// The readings of a live panel, each fresh and the phone's own (`face`'s input, from `payload`).
    public static func readBlocks(_ panel: String, _ settings: ConditionsSettings, _ readings: [String: LiveReading],
                                  now: Date, device: String = "phone") -> [ReadBlock] {
        sources(panel, settings, readings, now: now, device: device).compactMap { source in
            guard let reading = readings[source.sid], let goodAt = reading.goodAt else { return nil }
            let failed = reading.failure != nil && reading.triedAt != nil
            return ReadBlock(sid: source.sid, lines: lines(source.sid, reading.items, failed: failed, now: now,
                                                           county: settings.countyName),
                             held: reading.items.count, none: source.none, goodAt: goodAt, failed: failed)
        }
    }

    /// (status, HTML) of a live panel's row, as dashboard/render.py's `_face` writes it from the same readings (the
    /// shared cases' `faces`): "old" with ROW_FAILED for a reading whose last try failed; with no source, "miss" with
    /// ROW_WAITING for rivers (no gauge set), else ROW_NOT_FETCHED; "look" (🟠) with ROW_LOOK's words, or the line
    /// that turned it after the label, for a flagged line that isn't quiet (past its own end or cancelled, or a
    /// advisory where the phone is); "ok" with ROW_FINE's words where they hold, or the panel's first line after the label, while a
    /// block shows a reading (not a gauge with none, not a crest forecast); else "old" with that first line. A panel
    /// needing action is the page's live script's to place, so its words are never asked for.
    public static func face(_ panel: String, _ blocks: [ReadBlock], now: Date) -> (status: String, html: String) {
        let today = day(now)
        let label = esc(chipLabels[panel] ?? panel)
        func said(_ words: String) -> String { "<span class=\"face\">\(words)</span>" }
        func lineOf(_ html: String) -> String { said(fill(rowLine, ["label": label, "line": html])) }
        if let failed = blocks.first(where: \.failed) {
            return ("old", said(fill(rowFailed, ["label": label, "time": t(failed.goodAt, today)])))
        }
        if blocks.isEmpty {
            return panel == "rivers" ? ("miss", said(fill(rowWaiting, ["label": label])))
                : ("old", said(fill(rowNotFetched, ["label": label])))
        }
        for block in blocks {
            for line in block.lines where line.item.flag == ConditionItem.warn && !quiet(block.sid, line) {
                let words = lookWords(panel, blocks)
                return ("look", words.isEmpty ? lineOf(lookHTML(block.sid, line, today)) : said(esc(words)))
            }
        }
        // The panel's first line (render.py `_first_line`): the first block's that shows one, else the panel's empty
        // text.
        let firstLine = blocks.lazy.map { first($0, today) }.first { !$0.isEmpty }
            ?? esc(panel == "rivers" ? riversEmpty : noSources)
        guard blocks.contains(where: { !first($0, today).isEmpty && !unread($0) && !$0.sid.hasPrefix("crest-") }) else {
            return ("old", lineOf(firstLine))
        }
        let words = fineWords(panel, blocks)
        return ("ok", words.isEmpty ? lineOf(firstLine) : said(esc(words)))
    }

    /// A live panel's condition row, its panel to follow (render.py `_row_chunks`): its emoji, its words and its mark
    /// for the phone's own readings, with the first reading's hidden old face for the page's script to show once it is
    /// past the phone's own limit (`freshFor`); for a panel the Mac's copy stands in ("mac"), its emoji alone, the live
    /// script putting the panel in the Mac's own row instead.
    static func row(_ panel: String, _ status: String, _ words: String, _ read: [ReadBlock], now: Date) -> String {
        let emoji = "<span class=\"em\" aria-hidden=\"true\">\(panelEmoji[panel]!)</span>"
        var parts = [emoji]
        if status == "mac" || status == "needs" {  // the live script puts it elsewhere; its label if it can't
            parts.append("<span class=\"face\">\(esc(chipLabels[panel]!))</span>")
        } else {
            parts.append(words)
        }
        if status == "ok" || status == "look", let first = read.min(by: { $0.goodAt < $1.goodAt }) {
            let at = iso(first.goodAt), hours = NumberText.g(freshFor / 3600)
            let age = "<span class=\"n\">\(esc(ageWords(now.timeIntervalSince(first.goodAt))))</span>"
            parts.append("<span class=\"face\" data-ages=\"pm-row-\(panel)\" data-ages-at=\"\(at)\" "
                         + "data-ages-hours=\"\(hours)\" data-at=\"\(at)\" hidden>"
                         + fill(rowOld, ["label": esc(chipLabels[panel]!), "age": age]) + "</span>")
        }
        if status == "miss" {
            parts.append("<span class=\"em st sq\" aria-hidden=\"true\"></span>")
        } else if ["ok", "look", "old"].contains(status) {
            let mark = status == "ok" ? okMark : status == "look" ? lookMark : oldMark
            parts.append("<span class=\"em st\" aria-hidden=\"true\">\(mark)</span>")
        }
        let style = ["look", "old", "miss"].contains(status) ? " is-\(status)" : ""
        return "<details class=\"row cond\(style)\" id=\"pm-row-\(panel)\" data-pm-row=\"\(panel)\" "
            + "data-pm-status=\"\(status)\" data-mark-look=\"\(lookMark)\" data-mark-old=\"\(oldMark)\"><summary>"
            + parts.joined(separator: "\n") + "</summary>"
    }

    /// Whether a flagged line leaves its row as it is (render.py `_quiet`): past its own end or cancelled, or a
    /// watch, advisory or statement where this phone is. A warning there is critical since the owner's fix 6
    /// (2026-10-16; a watch was too until phase L's choice 1), and nothing else there changed (review I1): its
    /// advisories and watches never count "for home".
    static func quiet(_ sid: String, _ line: Line) -> Bool { line.over || (sid == "here-alerts" && line.look) }

    static func unread(_ block: ReadBlock) -> Bool {
        !block.lines.isEmpty && block.lines.allSatisfy { $0.item.flag == unreadFlag }
    }

    /// The first line a block shows (render.py `_block_first`): its first item's, else its none line, else "".
    static func first(_ block: ReadBlock, _ today: String) -> String {
        if let line = block.lines.first { return rowLineHTML(line, today) }
        if !block.none.isEmpty && block.held == 0 {
            return fill(asOf, ["none": esc(block.none), "time": t(block.goodAt, today)])
        }
        return ""
    }

    /// A 🟠 row's line (render.py `_look_html`): the tropical outlook's own line holding the formation chance, its
    /// list mark left off; any other, as the row shows it.
    static func lookHTML(_ sid: String, _ line: Line, _ today: String) -> String {
        let text = line.item.text
        if sid == "tropical-outlook",
           let found = chance.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(found.range, in: text) {
            let start = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let end = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            var said = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
            if said.hasPrefix("* ") { said.removeFirst(2) }
            return esc(said)
        }
        return rowLineHTML(line, today)
    }

    /// A line's first line as a row shows it (render.py `_line_html`): an item with its own end marked ended, now or
    /// by the page's script once it passes; a cancelled one carries is-ended without the ended line till then.
    static func rowLineHTML(_ line: Line, _ today: String) -> String {
        let text = esc(line.item.text.components(separatedBy: "\n").first ?? "")
        guard let expires = ConditionTime.moment(line.item.expires) else { return text }
        let attrs = " data-expires=\"\(iso(expires))\" data-ended=\"\(esc(endedLine))\""
        if line.ended {
            return "<span class=\"is-ended\"\(attrs)>\(text) <span class=\"ended\">"
                + "\(fill(endedLine, ["time": t(expires, today)]))</span></span>"
        }
        return "<span\(line.cancelled ? " class=\"is-ended\"" : "")\(attrs)>\(text)</span>"
    }

    /// ROW_FINE's words where they hold (render.py `_fine_words`), else "".
    static func fineWords(_ panel: String, _ blocks: [ReadBlock]) -> String {
        switch panel {
        case "alerts":
            guard let home = blocks.first(where: { $0.sid == "home-alerts" }), !home.lines.contains(where: { !$0.over })
            else { return "" }
        case "evacuations":
            if blocks.contains(where: { $0.lines.contains { !$0.over } }) { return "" }
        case "power":
            let text = blocks.first { $0.sid == "outages" }?.lines.first?.item.text ?? ""
            if text.hasPrefix(outagesNone.components(separatedBy: "{county}")[0]) {
                return rowFine[panel]!.replacingOccurrences(of: "{count}", with: noOutages)
            }
            guard let found = outageCount.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(found.range(at: 1), in: text) else { return "" }
            return rowFine[panel]!.replacingOccurrences(of: "{count}", with: String(text[range]))
        default:
            break
        }
        return rowFine[panel] ?? ""
    }

    /// ROW_LOOK's words where they hold (render.py `_look_words`), else "".
    static func lookWords(_ panel: String, _ blocks: [ReadBlock]) -> String {
        func turning(_ block: ReadBlock) -> [Line] {
            block.lines.filter { $0.item.flag == ConditionItem.warn && !quiet(block.sid, $0) }
        }
        let n: Int
        switch panel {
        case "alerts": n = blocks.map { turning($0).count }.reduce(0, +)
        case "rivers": n = blocks.filter { $0.sid.hasPrefix("gauge-") && !turning($0).isEmpty }.count
        default: return ""
        }
        return n > 0 ? rowLook[panel]!.replacingOccurrences(of: "{n}", with: String(n)) : ""
    }

    // MARK: Lines and their markup (dashboard/render.py's _lines, _content and _item_html)

    struct Line {
        let item: ConditionItem
        let ended: Bool
        let cancelled: Bool
        var event: String?
        var reason = ""
        /// An NWS alert's tier (NWSTidy.tier; "" for any other line) and its full text tidied (ruling 2).
        var tier = ""
        var full = ""
        /// Its plain headline (Task 8.1, F09): an NWS alert's hazards by name, NHC's outlook's one line ("" otherwise);
        /// the outlook's text, tidied, is then `full`, folded under it.
        var plain = ""
        var over: Bool { ended || cancelled }
        var look: Bool { tier == NWSTidy.look }
    }

    /// The items as the page shows them: one past its own end is ended, or left out while its source's last try
    /// failed; one whose VTEC lines are all ended is cancelled (NWS alerts only); a warning that starts event mode
    /// carries its kind and reason.
    static func lines(_ sid: String, _ items: [ConditionItem], failed: Bool, now: Date, county: String) -> [Line] {
        let nws = sid.hasSuffix("-alerts")
        var shown: [Line] = []
        for item in items {
            let expires = ConditionTime.moment(item.expires)
            let ended = expires.map { now >= $0 } ?? false
            if ended && failed { continue }
            let kind = eventCodes[sid]?[item.code]
            let alert = nws && item.flag == ConditionItem.warn
            let outlook = sid == "tropical-outlook"
            shown.append(Line(item: item, ended: ended, cancelled: nws && NWSVTEC.allEnded(item.vtec), event: kind,
                              tier: alert ? NWSTidy.tier(item.code) : "",
                              full: alert ? NWSTidy.tidy(item.detail) : outlook ? NWSTidy.tidy(item.text) : "",
                              plain: alert ? NWSTidy.alertHeadline(item.text, vtec: item.vtec, detail: item.detail)
                                  : outlook ? NWSTidy.tropicalHeadline(item.text) : ""))
        }
        let named = sid == "evacuations" ? countyNamed(shown.map(\.item)) : nil
        for n in shown.indices where shown[n].event != nil {
            let kind = shown[n].event!
            shown[n].reason = kindReasons[kind]
                ?? (named.map { evacOrderReason.replacingOccurrences(of: "{county}", with: $0) } ?? evacOrderUnnamed)
        }
        return shown
    }

    /// The county an evacuation order names, from its "Names {county} County." line (event.py `county_named`).
    static func countyNamed(_ items: [ConditionItem]) -> String? {
        for item in items where item.text.hasPrefix("Names ") && item.text.hasSuffix(" County.") {
            let name = item.text.dropFirst("Names ".count).dropLast(" County.".count)
            if !name.isEmpty { return String(name) }
        }
        return nil
    }

    /// A block's items, its none line and its folds (render.py `_content`). `held`: how many items the reading
    /// holds, those hidden included (the none line needs none at all). `foldAll`: every period folds after the
    /// first four whether or not it carries a time (the API's zone forecast gives none).
    public static func content(_ sid: String, panel: String, none: String, items: [ConditionItem], goodAt: Date,
                               now: Date, failed: Bool = false, county: String = "", foldAll: Bool = false) -> [String] {
        content(sid, panel: panel, none: none, lines: lines(sid, items, failed: failed, now: now, county: county),
                held: items.count, goodAt: goodAt, today: day(now), foldAll: foldAll)
    }

    static func content(_ sid: String, panel: String, none: String, lines: [Line], held: Int, goodAt: Date,
                        today: String, foldAll: Bool) -> [String] {
        if lines.isEmpty {
            guard !none.isEmpty, held == 0 else { return [] }
            return ["<p class=\"none mk-none\">\(fill(asOf, ["none": esc(none), "time": t(goodAt, today)]))</p>"]
        }
        if panel == "forecast" {
            let periods = lines.filter { ($0.item.when != nil || foldAll) && $0.item.flag != ConditionItem.warn }
            let others = lines.filter { line in !periods.contains { $0.item == line.item } }
            var out = [items(others + periods.prefix(foldAfter), panel: panel, today: today)]
            let folded = Array(periods.dropFirst(foldAfter))
            if !folded.isEmpty {
                let summary = forecastFold.replacingOccurrences(of: "{d}", with: String((folded.count + 1) / 2))
                    .replacingOccurrences(of: "{n}", with: String(folded.count))
                out.append("<details><summary>\(esc(summary))</summary>\n\(items(folded, panel: panel, today: today))\n</details>")
            }
            return out
        }
        return [items(lines, panel: panel, today: today)]
    }

    static func items(_ lines: [Line], panel: String, today: String) -> String {
        "<ul class=\"items\">\n" + lines.map { itemHTML($0, panel: panel, today: today) }.joined(separator: "\n")
            + "\n</ul>"
    }

    static func itemHTML(_ line: Line, panel: String, today: String) -> String {
        let item = line.item
        // A flagged road event, outage count or official notice is worth a look, never red (render.py _LOOK_PANELS; F10)
        let look = line.look || (["notices", "roads", "power"].contains(panel) && item.flag == ConditionItem.warn)
        let warn = item.flag == ConditionItem.warn && !look
        let classes = [("warn", warn), ("look", look), ("flood", warn && floodCategories.contains(item.code)),
                       ("is-ended", line.over)].filter(\.1).map(\.0)
        var attrs = classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\""
        let expires = ConditionTime.moment(item.expires)
        if let expires {
            attrs += " data-expires=\"\(iso(expires))\" data-ended=\"\(esc(endedLine))\""
        }
        if let kind = line.event {
            attrs += " data-event=\"\(esc(kind))\""
            attrs += expires.map { " data-event-until=\"\(iso($0))\"" } ?? " data-event-open=\"1\""
            attrs += " data-event-reason=\"\(esc(line.reason))\""
        }
        var inner = line.plain.isEmpty ? textHTML(item, panel: panel) : esc(line.plain)
        if let link = item.link { inner = "<a href=\"\(esc(link))\">\(inner)</a>" }
        let head = [("head", !item.detail.isEmpty || item.link != nil || !line.tier.isEmpty || !line.full.isEmpty),
                    ("mk-warn", warn),
                    ("mk-look", look)].filter(\.1).map(\.0)
        var parts = [head.isEmpty ? "<p>\(inner)</p>" : "<p class=\"\(head.joined(separator: " "))\">\(inner)</p>"]
        if !line.tier.isEmpty {  // an NWS alert (render.py `_alert_parts`): its end, its tidied text folded
            if let expires, !line.over {
                parts.append("<p class=\"until\">\(fill(until, ["time": t(expires, today)]))</p>")
            }
            if !line.full.isEmpty { parts.append(fullFold(line.full)) }
            if line.ended, let expires {
                parts.append("<p class=\"ended\">\(fill(endedLine, ["time": t(expires, today)]))</p>")
            }
            return "<li\(attrs)>" + parts.joined(separator: "\n") + "</li>"
        }
        if let when = whenText(item.when) { parts.append("<span class=\"when\">\(esc(when))</span>") }
        if !line.full.isEmpty {  // an outlook's own text, under its plain line and its issue line (Task 8.1)
            if item.text != line.plain && !item.text.contains("\n") { parts.append("<p class=\"when\">\(esc(item.text))</p>") }
            parts.append(fullFold(line.full))
        } else if !item.detail.isEmpty {
            parts.append("<p class=\"detail\">\(multiline(item.detail))</p>")
        }
        if line.ended, let expires {
            parts.append("<p class=\"ended\">\(fill(endedLine, ["time": t(expires, today)]))</p>")
        }
        return "<li\(attrs)>" + parts.joined(separator: "\n") + "</li>"
    }

    /// FULL_TEXT's fold holding tidied text (render.py `_full_fold`).
    static func fullFold(_ full: String) -> String {
        let paragraphs = full.components(separatedBy: "\n\n").map { paragraph in
            "<div>" + paragraph.components(separatedBy: "\n").map { "<p>\(esc($0))</p>" }.joined(separator: "\n") + "</div>"
        }
        return "<details class=\"full\"><summary>\(esc(fullText))</summary>\n<div class=\"full-text\">\n"
            + paragraphs.joined(separator: "\n") + "\n</div>\n</details>"
    }

    static let gaugePattern = try! NSRegularExpression(
        pattern: "^(.+): (-?[0-9]+\\.[0-9] ft), ([^.]+)\\.(.*)$", options: [.dotMatchesLineSeparators])
    static let countPattern = try! NSRegularExpression(
        pattern: "^([0-9]{1,3}(?:,[0-9]{3})*) (outages reported in .*)$", options: [.dotMatchesLineSeparators])

    /// An item's text as HTML (render.py `_text_html`): a gauge's level and stage and the outage count marked for the
    /// style, a forecast period's name in bold; the words unchanged.
    static func textHTML(_ item: ConditionItem, panel: String) -> String {
        let text = item.text
        let range = NSRange(text.startIndex..., in: text)
        func group(_ match: NSTextCheckingResult, _ n: Int) -> String {
            Range(match.range(at: n), in: text).map { String(text[$0]) } ?? ""
        }
        if panel == "rivers", let match = gaugePattern.firstMatch(in: text, range: range) {
            var stage = esc(group(match, 3))
            if !item.code.isEmpty {
                let flood = floodCategories.contains(item.code) ? " stage-flood" : ""
                stage = "<span class=\"stage\(flood)\">\(stage)</span>"
            }
            return "<span class=\"label\">\(esc(group(match, 1))):</span> <span class=\"level\">\(esc(group(match, 2)))"
                + "</span>, \(stage).\(multiline(group(match, 4)))"
        }
        if panel == "power", let match = countPattern.firstMatch(in: text, range: range) {
            return "<span class=\"count\">\(esc(group(match, 1)))</span> \(multiline(group(match, 2)))"
        }
        if panel == "forecast", item.when != nil, item.flag.isEmpty, let colon = text.range(of: ": ") {
            let name = String(text[..<colon.lowerBound])
            if !name.contains("\n") && name.count <= 40 {
                return "<span class=\"head\">\(esc(name)):</span> \(multiline(String(text[colon.upperBound...])))"
            }
        }
        return multiline(text)
    }

    /// A band warning's own instruction under its headline (render.py's band; beta run 2, R9.1), or "" when it gives
    /// none: never words of ours in its place.
    static func instructionHTML(_ item: ConditionItem) -> String {
        let (said, cut) = NWSTidy.instruction(item.instruction ?? "")
        guard !said.isEmpty else { return "" }
        let more = cut ? " <span class=\"more\">\(esc(instructionMore))</span>" : ""
        return " <span class=\"do\">\(esc(said))\(more)</span>"
    }

    /// A band warning's own mark beside its headline (render.py's band; R9.1 fix round 1).
    static func markHTML(_ line: Line) -> String {
        guard let kind = line.event, let mark = eventEmoji[kind] else { return "" }
        return "<span class=\"em mark\" aria-hidden=\"true\">\(mark)</span>"
    }

    /// A band headline (render.py `_line_html`, for a warning's first line): the line's text with its own end for
    /// the page's script.
    static func lineHTML(_ line: Line, _ today: String) -> String {
        let first = line.plain.isEmpty ? (line.item.text.components(separatedBy: "\n").first ?? "") : line.plain
        guard let expires = ConditionTime.moment(line.item.expires) else { return esc(first) }
        return "<span data-expires=\"\(iso(expires))\" data-ended=\"\(esc(endedLine))\" "
            + "data-ended-head=\"\(esc(endedHead))\">\(esc(first))</span>"
    }

    // MARK: The hours where the phone is (forecast-detail plan, phase 3)

    // The Mac's hour rows (render.py, held by the shared cases' "hours" and "copy"), up to a day of them
    public static let hereHours = "Hours where this phone is"
    public static let hoursHead = ["Time", "Rain", "Temp", "Wind"]  // render.py HOURS_HEAD
    static let rainPct = "{p}%", amount = "{a} in", amountTiny = "under 0.01 in"  // RAIN, AMOUNT, AMOUNT_TINY
    static let amountSpan = "{amount} over {h} hours"  // the grid gives rain for spans; MapClick's is the hour's
    static let feelsWords = "feels {t}°", gustsWords = "gusts {g}", calmWord = "Calm", storms = "T-storms: {c}"
    static let hoursShown = 24

    /// The fold under the forecast where the phone is: the next `hoursShown` hours not yet over, each day headed by
    /// its name ("Today", else the weekday where the phone is), every row and heading carrying its end so the page's
    /// minute pass hides it once gone by. A plain fold, so it takes the other folds' chevron, its table in a <div> to
    /// keep their side margins (`.hrs` sets its own). nil when no hour is left.
    static func hoursFold(_ items: [ConditionItem], now: Date, device: String, zone: TimeZone = .current) -> String? {
        var rows = Array(items.compactMap { item -> (ConditionItem, Date)? in
            guard item.hour != nil, let start = ConditionTime.moment(item.when),
                  start.addingTimeInterval(3600) > now else { return nil }
            return (item, start)
        }.prefix(hoursShown))
        guard let first = rows.first?.1 else { return nil }
        // a block's rain sits on its first hour, so a block under way moves its amount to the first hour shown
        if rows[0].0.hour?.rain == "", let under = items.compactMap({ item -> ConditionHour? in
            guard let hour = item.hour, !hour.rain.isEmpty, let start = ConditionTime.moment(item.when), start < first,
                  start.addingTimeInterval(Double(hour.rainHours) * 3600) > first else { return nil }
            return hour
        }).last {
            rows[0].0.hour?.rain = under.rain
            rows[0].0.hour?.rainHours = under.rainHours
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.timeZone = zone
        weekday.dateFormat = "EEEE"
        var body: [String] = [], part: [String] = [], partDay: Date?
        func close() {
            guard let partDay, let last = rows.last(where: { calendar.isDate($0.1, inSameDayAs: partDay) }) else { return }
            let name = calendar.isDate(partDay, inSameDayAs: now) ? "Today" : weekday.string(from: partDay)
            let end = last.1.addingTimeInterval(3600)
            body.append("<tr class=\"part\" data-hour-end=\"\(iso(end))\"><th colspan=\"4\" scope=\"colgroup\">"
                        + "<b>\(esc(name))</b></th></tr>")
            body += part
        }
        for (item, start) in rows {
            if let day = partDay, calendar.isDate(day, inSameDayAs: start) {
                part.append(hourRow(item))
                continue
            }
            close()
            (partDay, part) = (start, [hourRow(item)])
        }
        close()
        return "<details><summary>\(esc(own(hereHours, device)))</summary>\n"
            + "<div><table class=\"hrs\"><thead><tr>" + hoursHead.map { "<th>\(esc($0))</th>" }.joined()
            + "</tr></thead><tbody>\n" + body.joined(separator: "\n") + "\n</tbody></table></div></details>"
    }

    /// One hour (render.py `_hour_row`): its time, with any thunderstorms under it; its chance with a bar of it in
    /// tenths, the amount under them; the temperature, with feels-like under it; the wind, with gusts under it.
    public static func hourRow(_ item: ConditionItem) -> String {
        let hour = item.hour ?? ConditionHour()
        func under(_ words: String) -> String { words.isEmpty ? "" : "<small>\(esc(words))</small>" }
        var words = ""
        if let inches = Double(hour.rain) {
            words = inches < 0.005 ? amountTiny : amount.replacingOccurrences(of: "{a}", with: String(format: "%.2f", inches))
            if hour.rainHours > 1 {
                words = amountSpan.replacingOccurrences(of: "{amount}", with: words)
                    .replacingOccurrences(of: "{h}", with: String(hour.rainHours))
            }
        }
        let storm = hour.storm.isEmpty ? "" : "<small role=\"text\" aria-label=\"\(esc(storms.replacingOccurrences(of: "{c}", with: hour.storm)))\">"
            + "<span class=\"em\" aria-hidden=\"true\">⛈️</span>\(esc(hour.storm))</small>"
        var rain = hour.pop.isEmpty ? "" : "<span class=\"pct\">\(esc(rainPct.replacingOccurrences(of: "{p}", with: hour.pop)))</span>"
        if let pct = Int(hour.pop), pct >= 0 {
            rain += "<span class=\"bar\" aria-hidden=\"true\"><b class=\"p\(min((pct + 5) / 10, 10))\"></b></span>"
        }
        rain += under(words)
        let temp = (hour.temp.isEmpty ? "" : esc("\(hour.temp)°"))
            + under(hour.feels.isEmpty ? "" : feelsWords.replacingOccurrences(of: "{t}", with: hour.feels))
        let wind = esc(hour.wind == "0" ? calmWord : hour.wind)
            + under(hour.gust.isEmpty ? "" : gustsWords.replacingOccurrences(of: "{g}", with: hour.gust))
        let end = ConditionTime.moment(item.when).map { " data-hour-end=\"\(iso($0.addingTimeInterval(3600)))\"" } ?? ""
        return "<tr\(end)><th>\(esc(item.text))\(storm)</th><td>\(rain)</td><td>\(temp)</td><td>\(wind)</td></tr>"
    }

    // MARK: Words and times as the Mac's page writes them

    static func esc(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#x27;"
            default: out.append(c)
            }
        }
        return out
    }

    /// `template` escaped, each {name} replaced by `slots[name]`, which is HTML already (render.py `_fill`).
    static func fill(_ template: String, _ slots: [String: String]) -> String {
        var out = "", rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}"),
              let slot = slots[String(rest[rest.index(after: open)..<close])] {
            out += esc(String(rest[..<open])) + slot
            rest = rest[rest.index(after: close)...]
        }
        return out + esc(String(rest))
    }

    static func multiline(_ text: String) -> String {
        text.components(separatedBy: "\n").map(esc).joined(separator: "<br>\n")
    }

    static func iso(_ moment: Date) -> String { ConditionTime.newYorkISO(moment) }

    static func day(_ moment: Date) -> String { ConditionTime.newYorkDay(moment) }

    /// A time the page's script keeps saying which day it is (render.py `_t`).
    static func t(_ moment: Date, _ today: String) -> String {
        "<span class=\"t\" data-t=\"\(iso(moment))\">\(esc(shownTime(moment, today)))</span>"
    }

    /// "10:58 PM EDT" today, "Sat 10:58 PM EDT" in the six days before, else "Sep 26, 10:58 PM EDT".
    static func shownTime(_ moment: Date, _ today: String) -> String {
        let clock = ConditionTime.formatter("h:mm a zzz").string(from: moment)
        guard let then = dayDate(day(moment)), let now = dayDate(today) else { return clock }
        let back = Calendar(identifier: .gregorian).dateComponents([.day], from: then, to: now).day ?? 0
        if back == 0 { return clock }
        if back > 0 && back < 7 { return ConditionTime.formatter("EEE").string(from: moment) + " " + clock }
        return ConditionTime.formatter("MMM d").string(from: moment) + ", " + clock
    }

    static func dayDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)
    }

    /// An item's own time as the page writes it: "Sun Oct 4, 6:00 PM EDT", or a plain date "Sun Oct 4".
    static func whenText(_ value: String?) -> String? {
        guard let value else { return nil }
        if let moment = ConditionTime.moment(value) {
            return ConditionTime.formatter("EEE MMM d, h:mm a zzz").string(from: moment)
        }
        guard value.count == 10, let date = dayDate(value) else { return nil }
        let f = ConditionTime.formatter("EEE MMM d")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Whole minutes under an hour, hours under 48, then days; never below 0 (render.py `age_words`).
    static func ageWords(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.down)))
        let (count, unit) = minutes < 60 ? (minutes, "minute") : minutes < 48 * 60 ? (minutes / 60, "hour")
            : (minutes / (24 * 60), "day")
        return "\(count) \(unit)" + (count == 1 ? "" : "s")
    }
}
