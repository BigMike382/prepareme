// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 5).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import CoreLocation
import Foundation
import PrepareMeShared
import WebKit

/// The phone's own reading of the life-safety feeds (build plan phase 5), shown at the top of the daily library's
/// front page by prepareme-live.js.
///
/// - What: NWS alerts and the zone forecast (api.weather.gov), the river gauges (api.water.noaa.gov), the Atlantic
///   outlook and storms (nhc.noaa.gov), and the home state's power outages and evacuations, by the codes the Mac packs
///   into the daily library (ConditionsSettings; no coordinates leave the Mac) and the state's feeds packed beside
///   them (ConditionsArea; none built in, so the published app names no state). Air quality stays the Mac's
///   (owner, 2026-10-13). The readers and rules are app/Service's, held to the Mac's.
/// - When: only while the app is in front (owner, 2026-10-13): when it comes forward, every few minutes while it is
///   open, and when the front page loads; each feed no more often than its own spacing.
/// - Where the phone is (D2, owner 2026-10-13): the phone's location, asked for once per read with the system's
///   permission, goes to api.weather.gov's lookup only, to 2 decimals; it is never kept, logged or sent to the Mac.
///   Refused permission means home only. What it reads for "here" is kept in memory only.
/// - Home's readings are kept in Application Support › PrepareMe › live, so a reading under 2 hours old still shows
///   after the app is reopened; LiveBlock judges every reading's age.
/// - Each request goes to its feed's own host only, over https, with the project's User-Agent; an answer from
///   anywhere else, too big, or not the shape its reader knows is "couldn't read", never "none".
@MainActor
final class LiveConditions: ObservableObject {
    static let shared = LiveConditions()
    /// Today's page is in event mode or says something needs action (TodayMark; look 3, spec section 9): the Today
    /// tab's red mark, read each time the live block shows, and cleared when the page shows calm again.
    @Published private(set) var needsAction = false
    static let whileOpenEvery: TimeInterval = 5 * 60
    nonisolated static let limit = 5_000_000
    nonisolated static let hereEvery: TimeInterval = 10 * 60
    // The DC test area (ConditionsSettings.testArea) reads on a simulator only: a phone's build never has it
    #if targetEnvironment(simulator)
    static let allowsTestArea = true
    #else
    static let allowsTestArea = false
    #endif
    static let script: String = {
        guard let url = Bundle.main.url(forResource: "prepareme-live", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    private var readings: [String: LiveReading] = [:]  // home's, from disk; "here", in memory only
    private var shapes: [String: [WarningShape]] = [:]  // the storm warnings' outlines, by feed (plan phase 9), in memory
    private var readingsFor: String?  // the settings home's readings were read under (review M1)
    // The phone's own sun times where it last was (step 6, part 4), and when that fix came; never the position
    private var hereSky: (sky: HereSky, at: Date)?
    private static let hereSkyFor: TimeInterval = 30 * 60  // then dropped: the phone may have moved (the review)
    private var lookedAt: Date?  // the last time it asked where the phone is (whole-branch review M4)
    private var settings: ConditionsSettings?
    private var guidePages: Set<String> = []  // the guides that library holds, for the band's guide buttons
    private var timer: Timer?
    private var running = false
    private let here = HereLocation()
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": NWSAlerts.userAgent]
        session = URLSession(configuration: configuration, delegate: SameHostOnly(), delegateQueue: nil)
        (readings, readingsFor) = Self.load()
    }

    // MARK: When

    func becameActive() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.whileOpenEvery, repeats: true) { _ in
            Task { @MainActor in await LiveConditions.shared.refresh() }
        }
        Task { await refresh() }
    }

    func wentToBackground() {
        timer?.invalidate()
        timer = nil
    }

    /// A page finished loading: a library's front page gets the live block (the script does nothing on a page
    /// without the conditions section).
    func pageFinished(_ webView: WKWebView) {
        Task {
            guard let url = webView.url, let id = url.zimFileID,
                  let front = await ZimFileService.shared.getMainPageURL(zimFileID: id),
                  url.contentPath == front.contentPath else { return }
            await settle()
            await show(in: webView)
            await refresh()
        }
    }

    // MARK: Reading

    /// Reads each feed that is due, then shows the result on every open front page.
    func refresh() async {
        guard !running else { return }
        running = true
        // A read begun in front finishes if the app goes to the background meanwhile (whole-branch review I2), so a
        // quick glance never shows or counts as "couldn't read"; iOS ends the extra time if it runs long.
        let time = BackgroundTime(named: "PrepareMe conditions")
        defer {
            running = false
            time.end()
        }
        await settle()
        guard let settings else {
            await showEverywhere()
            return
        }
        let now = Date()
        var due = Feed.home(settings).filter { $0.due(readings[$0.sid], now) }
        if let place = await lookHere(settings, now) {  // its alerts only while the phone's own alerts show
            due += Feed.here(place).filter { (settings.liveAlerts || $0.sid != "here-alerts")
                && $0.due(readings[$0.sid], now) }
        }
        let read = await withTaskGroup(of: (Feed, Result<[ConditionItem], ReadFailure>, Data?).self) { group in
            for feed in due {
                group.addTask { [session] in
                    let (result, data) = await Self.readKeeping(feed, session: session)
                    return (feed, result, data)
                }
            }
            var found: [(Feed, Result<[ConditionItem], ReadFailure>, Data?)] = []
            for await result in group { found.append(result) }
            return found
        }
        let stamp = ISO8601DateFormatter().string(from: now)
        for (feed, _, data) in read where feed.sid.hasSuffix("-alerts") {  // the street map's warning outlines
            if let data, let found = try? NWSAPI.shapes(data, asOf: stamp) { shapes[feed.sid] = found }
        }
        let results = read.map { ($0.0, $0.1) }
        for (feed, result) in results {
            var reading = readings[feed.sid] ?? LiveReading()
            reading.triedAt = now
            switch result {
            case .success(let items):
                reading.goodAt = now
                reading.items = items
                reading.failure = nil
            case .failure(let why):
                reading.failure = why.words
            }
            if let place = feed.place {
                reading.area = place.area
                reading.zone = place.zone
            }
            readings[feed.sid] = reading
        }
        save()
        await showEverywhere()
        await post(results.map { ($0.0.sid, $0.1) }, at: now)
    }

    /// The counts of what this read tried, to the Mac (the 14-day check): each feed read, and each it couldn't; the
    /// gauges as one feed, read when every gauge was. "Here" and the forecasts aren't counted.
    private func post(_ tried: [(String, Result<[ConditionItem], ReadFailure>)], at now: Date) async {
        var feeds: [String: [String: Int]] = [:], unread: [String] = []
        var gauges: [ConditionItem] = [], gaugesTried = false, gaugesFailed = false
        for (sid, result) in tried {
            if sid.hasPrefix("gauge-") {
                gaugesTried = true
                if case .success(let items) = result { gauges += items } else { gaugesFailed = true }
                continue
            }
            guard FeedCounts.keys[sid] != nil else { continue }
            switch result {
            case .success(let items): feeds[sid] = FeedCounts.counts(sid, items)
            case .failure: unread.append(sid)
            }
        }
        if gaugesTried {
            if gaugesFailed { unread.append("gauges") } else { feeds["gauges"] = FeedCounts.counts("gauges", gauges) }
        }
        guard !feeds.isEmpty || !unread.isEmpty else { return }
        _ = await MacLink.post(FeedCountsReport(at: CountsReport.minute(now), feeds: feeds, unread: unread))
    }

    /// The settings from the daily library: the first library on the phone that carries the settings file, and the
    /// guides it holds (its guide list's pages), so the band's guide buttons link only to those (whole-plan review).
    private func settle() async {
        var found: ConditionsSettings?, pages: Set<String> = []
        for held in PrepareMeLibrary.shared.record.held.values where held.entry.kind == "library" {
            guard let content = await ZimFileService.shared.getURLContent(zimFileID: held.entry.id,
                                                                          contentPath: ConditionsSettings.path),
                  let read = try? ConditionsSettings(content.data, area: await ZimFileService.shared.getURLContent(
                      zimFileID: held.entry.id, contentPath: ConditionsArea.path)?.data,
                                                     allowingTestArea: Self.allowsTestArea)
            else { continue }
            found = read
            if let list = await ZimFileService.shared.getURLContent(zimFileID: held.entry.id,
                                                                    contentPath: GuideList.path),
               let guides = try? GuideList(list.data) {
                pages = Set(guides.guides.map(\.page))
            }
            break
        }
        guidePages = pages
        if let found, Self.key(found) != readingsFor {  // another home: its old readings aren't home's
            readings = readings.filter { $0.key.hasPrefix("here-") }
            readingsFor = Self.key(found)
        }
        settings = found
    }

    /// Where the phone is, by the lookup (D2): at most every 10 minutes, tried or not, and only with the system's
    /// permission. A refused permission drops what was read for "here"; a fix or lookup that doesn't come keeps it,
    /// to age out. In home's zone it gives nothing ("here" is home).
    private func lookHere(_ settings: ConditionsSettings, _ now: Date) async -> NWSAPI.Place? {
        if let lookedAt, now.timeIntervalSince(lookedAt) < Self.hereEvery, now >= lookedAt { return nil }
        lookedAt = now
        guard here.allowed else {  // never asks: the street map asks, under its why line (Task 11.3; F25)
            readings["here-alerts"] = nil
            readings["here-forecast"] = nil
            readings["here-hours"] = nil
            hereSky = nil
            return nil
        }
        guard let spot = await here.once() else { return nil }
        // Worked out on the phone before any lookup, so it shows with no signal (step 6, part 4)
        hereSky = (Sky.here(latitude: spot.coordinate.latitude, longitude: spot.coordinate.longitude, now: now,
                            device: ThisDevice.word), now)
        let url = NWSAPI.pointsURL(latitude: spot.coordinate.latitude, longitude: spot.coordinate.longitude)
        guard case .success(let data) = await Self.fetch(url, session: session),
              let place = try? NWSAPI.points(data) else { return nil }
        if readings["here-alerts"]?.zone != place.zone && readings["here-forecast"]?.zone != place.zone {
            readings["here-alerts"] = nil  // moved: the last place's readings aren't here's
            readings["here-forecast"] = nil
            readings["here-hours"] = nil
        }
        return place.zone == settings.zone ? nil : place
    }

    // MARK: Showing

    private func payload(macAt: [String: Date]?) -> LivePayload {
        let host = LiveBlock.host(canEdit: PhoneInventoryModel.shared.canEdit)  // where Event mode is switched
        var made = settings.map { LiveBlock.payload($0, readings, now: Date(), host: host, device: ThisDevice.word,
                                                    guides: guidePages, macAt: macAt) }
            ?? LiveBlock.limitsOnly(host: host, device: ThisDevice.word)
        // Today's only, from a fix under 30 minutes old, while location is allowed: past midnight, or moved with no
        // new fix, or location turned off, it shows nothing rather than another day's or place's times
        let now = Date()
        if let hereSky, here.allowed, hereSky.sky.day == Sky.dayKey(now),
           now.timeIntervalSince(hereSky.at) < Self.hereSkyFor, now >= hereSky.at {
            made.sky = hereSky.sky
        }
        made.rally = Self.rallyName()
        made.inventoryAge = LiveBlock.inventoryAgeLine(
            copy: PhoneInventoryModel.shared.copy.flatMap { ISO8601DateFormatter().date(from: $0.writtenAt) },
            reached: PrepareMeLibrary.shared.lastReached, now: now)  // offline fixes, task 3.2
        return made
    }

    /// The rally point Today's rally line names (beta run 2, R9.1): the one the street map's arrow points to before it
    /// knows where the phone is (Position.plannedOrFirst with this phone's Event mode, as StreetMapModel's), from this
    /// phone's copy of the lists; nil with no copy or no rally point. On the page only, never kept or sent anywhere.
    static func rallyName() -> String? {
        let model = PhoneInventoryModel.shared
        let named = Position.plannedOrFirst(model.shown?.marks ?? [], eventOn: model.eventModeOn)
        return named.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func show(in webView: WKWebView) async {
        guard !Self.script.isEmpty, !PrepareMeSample.shared.on else { return }  // the sample has no live conditions
        // the times of the Mac's copies on this page, so a phone reading newer than them stays (offline fixes, 4.1)
        let found = (try? await webView.evaluateJavaScript(Self.script + "\n;window.PrepareMeLive.macTimes();"))
            as? [String: String]
        let macAt = found.map { $0.compactMapValues { ConditionTime.moment($0) } }
        guard let json = try? JSONEncoder().encode(payload(macAt: macAt)) else { return }
        let ready = "window.PrepareMeStreetMap = \(StreetMap.viewReady);"  // the event-mode button (plan phase 9)
        // This phone's own Event mode switch, until the Mac's pack carries it (plan phase 7, part 2)
        let local = PhoneInventoryModel.shared.localEventMode.map(PhoneEventSwitch.script) ?? ""
        let mode = try? await webView.evaluateJavaScript(ready + local + Self.script + "\n;window.PrepareMeLive.apply("
                                                          + String(decoding: json, as: UTF8.self) + ");\n"
                                                          + TodayMark.probe)  // the page's own mode, once applied
        if let on = TodayMark.needsAction(mode), on != needsAction { needsAction = on }
    }

    /// Show the block again on every front page now (after this phone's Event mode switch).
    func showNow() async {
        await showEverywhere()
    }

    private func showEverywhere() async {
        let shown = await BrowserViewModel.frontPageWebViews()
        for webView in shown { await show(in: webView) }
        await showOnTodaysFrontPage(skipping: shown)
    }

    /// Today's front page out of sight, for the tab's mark while Today's own view is on another page or never loaded
    /// (the phase 4 review: someone who followed a guide from Today, then went to Maps, saw no mark for a warning that
    /// began after). One view, kept, sharing Today's configuration so it reads the same library.
    private var probe: (view: WKWebView, wait: PageWait)?

    private func showOnTodaysFrontPage(skipping shown: [WKWebView]) async {
        let tabs = PrepareMeTabs.shared
        let today = tabs.browser(.today).webView
        guard !shown.contains(today), let front = await tabs.startURL(.today) else { return }
        let probe = self.probe ?? (WKWebView(frame: .zero, configuration: today.configuration), PageWait())
        self.probe = probe
        probe.view.navigationDelegate = probe.wait
        guard await probe.wait.load(front, in: probe.view) else { return }
        await show(in: probe.view)
    }

    /// Waits for one page to finish loading, or to fail.
    @MainActor final class PageWait: NSObject, WKNavigationDelegate {
        private var done: CheckedContinuation<Bool, Never>?

        func load(_ url: URL, in view: WKWebView) async -> Bool {
            finish(false)  // a load still waiting gives way to this one
            return await withCheckedContinuation { done in
                self.done = done
                view.load(URLRequest(url: url))
            }
        }

        private func finish(_ loaded: Bool) {
            done?.resume(returning: loaded)
            done = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) { finish(false) }
    }

    // MARK: The store of home's readings

    private static var file: URL {
        PrepareMeLibrary.root.appendingPathComponent("live", isDirectory: true).appendingPathComponent("readings.json")
    }

    struct Saved: Codable {
        var settings: String
        var readings: [String: LiveReading]
    }

    /// Home's codes and gauges, in order: readings saved under other ones are another home's.
    static func key(_ settings: ConditionsSettings) -> String {
        ([settings.zone, settings.county, settings.fireZone, settings.countyName] + settings.gauges).joined(separator: " ")
    }

    private static func load() -> ([String: LiveReading], String?) {
        guard let data = try? Data(contentsOf: file), let found = try? JSONDecoder().decode(Saved.self, from: data)
        else { return ([:], nil) }
        return (found.readings.filter { !$0.key.hasPrefix("here-") }, found.settings)
    }

    private func save() {
        let home = readings.filter { !$0.key.hasPrefix("here-") }
        guard let settings, let data = try? JSONEncoder().encode(Saved(settings: Self.key(settings), readings: home))
        else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var url = Self.file
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Fetching

    struct ReadFailure: Error, Sendable {
        let words: String
    }

    nonisolated static func read(_ feed: Feed, session: URLSession) async -> Result<[ConditionItem], ReadFailure> {
        await readKeeping(feed, session: session).0
    }

    /// The feed read, and its answer as it came (the street map draws the alerts' outlines from it).
    nonisolated static func readKeeping(_ feed: Feed, session: URLSession)
        async -> (Result<[ConditionItem], ReadFailure>, Data?) {
        switch await fetch(feed.url, session: session) {
        case .failure(let why): return (.failure(why), nil)
        case .success(let data):
            do {
                return (.success(try feed.parse(data)), data)
            } catch let error as FeedFormatError {
                return (.failure(ReadFailure(words: error.message)), nil)
            } catch {
                return (.failure(ReadFailure(words: "the answer couldn't be read")), nil)
            }
        }
    }

    /// The storm warnings' outlines for the street map (plan phase 9, item 5): home's and where the phone is, only
    /// while the phone's own alerts show (ConditionsSettings.liveAlerts, until check f is ruled on), and only those
    /// still in force (MapConditions draws none past its end).
    func warningShapes() -> [WarningShape] {
        guard settings?.liveAlerts == true else { return [] }
        var seen = Set<String>()
        return ((shapes["home-alerts"] ?? []) + (shapes["here-alerts"] ?? [])).filter {
            seen.insert($0.code + $0.title + ($0.expires ?? "")).inserted  // one warning over home and here, drawn once
        }
    }

    nonisolated static func fetch(_ url: URL, session: URLSession) async -> Result<Data, ReadFailure> {
        var request = URLRequest(url: url)
        if url.host == NWSAPI.host { request.setValue("application/geo+json", forHTTPHeaderField: "Accept") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url?.host == url.host else {
                return .failure(ReadFailure(words: "the site sent it elsewhere"))
            }
            guard http.statusCode == 200 else { return .failure(ReadFailure(words: "the site answered \(http.statusCode)")) }
            guard data.count <= limit else { return .failure(ReadFailure(words: "the answer was too big")) }
            return .success(data)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .failure(ReadFailure(words: "no internet connection"))
            case .timedOut: return .failure(ReadFailure(words: "timed out"))
            case .cancelled: return .failure(ReadFailure(words: "the site sent it elsewhere"))
            default: return .failure(ReadFailure(words: "the site couldn't be reached"))
            }
        } catch {
            return .failure(ReadFailure(words: "the site couldn't be reached"))
        }
    }
}

/// One feed the phone reads: the Mac's source id, its address, how often at most, and its reader.
struct Feed: Sendable {
    let sid: String
    let url: URL
    let every: TimeInterval
    let place: NWSAPI.Place?
    let parse: @Sendable (Data) throws -> [ConditionItem]

    func due(_ reading: LiveReading?, _ now: Date) -> Bool {
        guard let tried = reading?.triedAt else { return true }
        return now.timeIntervalSince(tried) >= every - 30 || now < tried
    }

    static let nwps = "https://api.water.noaa.gov/nwps/v1/gauges/"
    static let outlook = URL(string: "https://www.nhc.noaa.gov/xml/TWOAT.xml")!
    static let storms = URL(string: "https://www.nhc.noaa.gov/CurrentStorms.json")!

    /// Home's feeds, at the spacing each changes on (the Mac reads hourly; a phone open now wants fresher). The state's
    /// outages and evacuations only from the library's state file (Unlisted plan, phase 4); without one, neither.
    static func home(_ settings: ConditionsSettings) -> [Feed] {
        let county = settings.countyName
        var feeds = [
            Feed(sid: "home-alerts", url: NWSAPI.alertsURL(settings.alertCodes), every: 10 * 60, place: nil,
                 parse: { try NWSAPI.alerts($0) }),
            Feed(sid: "home-forecast", url: NWSAPI.forecastURL(zone: settings.zone), every: 30 * 60, place: nil,
                 parse: { try NWSAPI.zoneForecast($0) }),
            Feed(sid: "tropical-outlook", url: outlook, every: 60 * 60, place: nil,
                 parse: { try MacFeeds.tropicalOutlook($0) }),
            Feed(sid: "storms", url: storms, every: 60 * 60, place: nil, parse: { try MacFeeds.storms($0) }),
        ]
        if let area = settings.area {
            feeds += [Feed(sid: "outages", url: area.outages, every: 15 * 60, place: nil,
                           parse: { try MacFeeds.outages($0, county: county, area: area) }),
                      Feed(sid: "evacuations", url: area.evacuations, every: 10 * 60, place: nil,
                           parse: { try MacFeeds.evacuations($0, county: county) })]
        }
        for (n, id) in settings.gauges.enumerated() {
            let address = URL(string: nwps + id)!
            feeds.append(Feed(sid: "gauge-\(n + 1)", url: address, every: 30 * 60, place: nil,
                              parse: { try MacFeeds.gauge($0, now: Date()) }))
            feeds.append(Feed(sid: "crest-\(n + 1)", url: address.appendingPathComponent("stageflow/forecast"),
                              every: 60 * 60, place: nil, parse: { try MacFeeds.crest($0, now: Date()) }))
        }
        return feeds
    }

    /// Where the phone is (D2): its place's alerts and forecast, and its hours from the grid the lookup named
    /// (forecast-detail plan, phase 3; the address in memory only, with the lookup).
    static func here(_ place: NWSAPI.Place) -> [Feed] {
        [Feed(sid: "here-alerts", url: NWSAPI.alertsURL(place.codes), every: 10 * 60, place: place,
              parse: { try NWSAPI.alerts($0) }),
         Feed(sid: "here-forecast", url: NWSAPI.forecastURL(zone: place.zone), every: 30 * 60, place: place,
              parse: { try NWSAPI.zoneForecast($0) })]
            + (place.grid.map { [Feed(sid: "here-hours", url: $0, every: 30 * 60, place: place,
                                      parse: { try NWSAPI.hours($0, zone: .current) })] } ?? [])
    }
}

/// The phone's location, once (D2): with the system's permission ("while using the app"), to about a kilometer, given
/// to the caller and never kept. nil when permission is refused or not given yet, or no fix comes in 15 seconds. It
/// never asks: the street map does, under its why line (Task 11.3; F25: the question popped up on Home Mac).
@MainActor
final class HereLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?
    private var call = 0  // each request's own number, so one's timeout never ends the next (review M3)

    /// Whether the system lets the app ask where the phone is.
    var allowed: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func once() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            return nil
        }
        guard waiting == nil else { return nil }
        call += 1
        let mine = call
        return await withCheckedContinuation { continuation in
            waiting = continuation
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                if self.call == mine { self.finish(nil) }
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        waiting?.resume(returning: location)
        waiting = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        MainActor.assumeIsolated { finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
#endif
