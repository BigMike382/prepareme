// This file is part of PrepareMe, a local build of Kiwix for one household (build plan phase 9).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Combine
import os
import PrepareMeShared
import SwiftUI
import WebKit

/// The street map's page (the web engine, owner 2026-10-14; app/StreetMapAssets/web/streetmap.js), shown by the
/// phone's Maps tab and the Mac's Street map window. Every file it reads is served by the app (`StreetMapFiles`): the
/// page, MapLibre and the styles, fonts and icons from the bundled StreetMapAssets folder, and the map file by byte
/// range, then each travel map the phone holds (combined step 9), which the page draws where the home file has no
/// tile (`StreetMap.pageFiles`, stack.js). A content rule blocks every http and https load, so the map never asks the
/// internet for anything. The app hands the page what it draws (`show`), hears its moves and taps, and reloads it
/// where it was when the watchdog says the map has stopped loading (`StreetMap.Watchdog`).
@MainActor
final class StreetMapController: NSObject, ObservableObject {
    enum Layer: String { case conditions, marks, pins, draft }

    let file: URL
    /// The travel maps drawn with it, in order; each one whose header reads as a whole map file
    let travel: [URL]
    /// The area the home file and every travel map cover together (`StreetMap.covering`)
    let info: StreetMap.Info
    let printable: Bool  // its picture can be read back: the Mac's printed household map, the phone's Save as PDF
    /// The map's age in its credit corner (task 3.5): "Map as of Mar 2026", in caution amber once over 6 months old
    let age: (words: String, old: Bool)?
    let webView: WKWebView
    private let files: StreetMapFiles
    private let memory = StreetMap.Memory()
    private var watchdog = StreetMap.Watchdog()
    private var layers: [Layer: Data] = [:]
    private var position: (latitude: Double, longitude: Double, accuracy: Double, heading: Double?, stale: Bool)?
    private var dark = false
    private var redNight = false
    private var timer: Timer?
    @Published private(set) var ready = false
    @Published private(set) var camera: StreetMap.Camera
    @Published private(set) var problem: String?
    /// A tap on the map: where, what was under the finger (the page's layer ids and each feature's properties), and
    /// where in the view, in points from its top left (the Mac's details point there).
    var onTap: ((Double, Double, [[String: Any]], CGPoint?, Bool) -> Void)?  // the last: a long press (F23)
    /// The person dragged the map (Follow me ends: task 1.2).
    var onDrag: (() -> Void)?

    init(file: URL, info: StreetMap.Info, travel: [URL] = [], printable: Bool = false, built: String? = nil) {
        let found = travel.compactMap { url in StreetMap.info(url).map { (url, $0) } }
        let info = StreetMap.covering([info] + found.map { $0.1 }) ?? info
        self.file = file
        self.travel = found.map { $0.0 }
        self.info = info
        self.printable = printable
        age = built.flatMap { HomeMacWords.mapAgeLine(built: $0) }
        files = StreetMapFiles(map: file, travel: found.map { $0.0 })
        camera = StreetMap.Memory().camera(for: info)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(files, forURLScheme: StreetMapFiles.scheme)
        config.websiteDataStore = .nonPersistent()  // nothing of the map's kept by WebKit
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakMessages(self), name: "map")
        webView.navigationDelegate = self
        PrepareMeRedNight.surface(webView, red: PrepareMeRedNight.shared.on)  // phase D: no white before the map
        #if DEBUG
        webView.isInspectable = true
        #endif
        #if os(iOS)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "prepareme-map-offline",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}}]"#
        ) { [weak self] list, error in
            guard let self else { return }
            if let list {
                config.userContentController.add(list)
            } else {
                Self.log.error("the offline rule didn't compile: \(error?.localizedDescription ?? "", privacy: .public)")
            }
            load()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let controller = self else { return timer.invalidate() }  // the map has gone: so does its watch
            MainActor.assumeIsolated {
                if controller.watchdog.quiet(watching: controller.onScreen) { controller.reload() }
            }
        }
    }

    private func load() {
        Self.log.info("map page: loading")
        ready = false
        watchdog.started()
        webView.load(URLRequest(url: StreetMapFiles.page))
    }

    /// Whether the map can be seen now: in a window, with the app in front. Only then is a quiet page a stalled one.
    var onScreen: Bool {
        guard webView.window != nil else { return false }
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    /// Start again where the map was: the watchdog's answer to a map that stopped loading.
    func reload() {
        load()
    }

    /// What the page draws on one layer, as GeoJSON (MapConditions, MapMark, PersonalPins and the Mac's draft route).
    func show(_ layer: Layer, _ geoJSON: Data) {
        guard layers[layer] != geoJSON else { return }
        layers[layer] = geoJSON
        if ready { send(layer) }
    }

    /// `stale`: the fix is half a minute old or more (Position.Freshness), drawn gray with a wider circle.
    func showPosition(latitude: Double, longitude: Double, accuracy: Double, heading: Double?, stale: Bool = false) {
        position = (latitude, longitude, accuracy, heading, stale)
        if ready { sendPosition() }
    }

    func clearPosition() {
        position = nil
        if ready { call("pm.clearPosition()") }
    }

    func setDark(_ night: Bool) {
        guard night != dark else { return }
        dark = night
        if ready { call("pm.setDark(\(night))") }
    }

    /// The red night screen (the W9 review): the pins' red night look (PersonalPins.Label.nightIcon).
    func setRed(_ on: Bool) {
        guard on != redNight else { return }
        redNight = on
        if ready { call("pm.setRed(\(on))") }
    }

    func flyTo(longitude: Double, latitude: Double, zoom: Double? = nil) {
        call("pm.flyTo(\(longitude), \(latitude), \(zoom.map { "\($0)" } ?? "undefined"))")
    }

    /// Follow me: the map's middle eased to the fix, keeping the zoom (the page skips it while the map moves).
    func follow(longitude: Double, latitude: Double) {
        if ready { call("pm.follow(\(longitude), \(latitude))") }
    }

    func fit(west: Double, south: Double, east: Double, north: Double) {
        guard ready else { return pendingFit = [west, south, east, north] }  // shown once the map is up
        call("pm.fit(\(west), \(south), \(east), \(north))")
    }

    private var pendingFit: [Double]?

    func resetNorth() {
        call("pm.resetNorth()")
    }

    /// The map drawn over an area, north up, once every tile is in: a PNG for the printed household map, and the area
    /// the whole picture covers (west, south, east, north), padding included, for its grid and scale bar.
    func snapshot(west: Double, south: Double, east: Double, north: Double) async -> (png: Data, bounds: [Double])? {
        await snap(["w": west, "s": south, "e": east, "n": north])
    }

    /// The view on screen, north up, put back as it was after (the phone's Save as PDF, task 4.2).
    func snapshotHere() async -> (png: Data, bounds: [Double])? {
        await snap(["w": NSNull(), "s": NSNull(), "e": NSNull(), "n": NSNull()])
    }

    private func snap(_ area: [String: Any]) async -> (png: Data, bounds: [Double])? {
        guard ready, printable,
              let found = try? await webView.callAsyncJavaScript(
                  "return await pm.snapshot(w, s, e, n)", arguments: area, in: nil, contentWorld: .page) as? String,
              let parsed = try? JSONSerialization.jsonObject(with: Data(found.utf8)) as? [String: Any],
              let url = parsed["png"] as? String, let comma = url.firstIndex(of: ","),
              let bounds = parsed["bounds"] as? [Double], bounds.count == 4,
              let png = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return (png, bounds)
    }

    private func send(_ layer: Layer) {
        guard let geoJSON = layers[layer], let text = String(data: geoJSON, encoding: .utf8) else { return }
        call("pm.setData(\"\(layer.rawValue)\", \(text))")
    }

    private func sendPosition() {
        guard let position else { return }
        call("pm.setPosition(\(position.latitude), \(position.longitude), \(position.accuracy), "
             + "\(position.heading.map { "\($0)" } ?? "null"), \(position.stale))")
    }

    private func call(_ script: String) {
        webView.evaluateJavaScript(script + "; true", completionHandler: nil)
    }

    /// Each pin symbol, white, as a PNG the page draws on its colored dot (task 3.2), as a data URL: by its symbol for
    /// the shared pins ("pm-pin-drop.fill", and black as "pm-pin-dark-drop.fill" for the colors red night draws dark:
    /// PinLook.icon), and by its kind's word for a phone's own pins from before ("pm-pin-Water", "pm-pin-dark-Water";
    /// the W9 review). On the Mac too since the shared marks plan's phase 2.
    static let pinIcons: [String: String] = {
        var icons: [String: String] = [:]
        for symbol in PinLook.symbols {
            icons[PinLook.icon(symbol)] = picture(symbol, white: true)
            icons[PinLook.icon(symbol, dark: true)] = picture(symbol, white: false)
        }
        icons[PinLook.icon("flag.fill")] = picture("flag.fill", white: true)  // a meeting place's flag (map pins, 2.6)
        #if os(iOS)
        for label in PersonalPins.Label.allCases {
            icons["pm-pin-" + label.rawValue] = picture(label.symbol, white: true)
            if label.nightDark { icons[label.nightIcon] = picture(label.symbol, white: false) }
        }
        #endif
        return icons
    }()

    /// An SF Symbol at 11 points bold, white or black, as a PNG data URL at three pixels a point (the page adds them
    /// at pixel ratio 3); nil for a name the system doesn't have.
    private static func picture(_ name: String, white: Bool) -> String? {
        #if os(iOS)
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        guard let symbol = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(white ? .white : .black, renderingMode: .alwaysOriginal) else { return nil }
        let png = UIGraphicsImageRenderer(size: symbol.size, format: format).pngData { _ in symbol.draw(at: .zero) }
        return "data:image/png;base64," + png.base64EncodedString()
        #else
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            .applying(.init(paletteColors: [white ? .white : .black]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(symbol.size.width * 3),
                                            pixelsHigh: Int(symbol.size.height * 3), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // the context counts in the bitmap's pixels: the whole of it, three to a point (drawn at the symbol's own size
        // it filled a ninth, a speck in the dot's corner; seen on the check build, 2026-11-12)
        symbol.draw(in: NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
        #endif
    }

    private static let log = Logger(subsystem: AppCopy.id, category: "streetmap")

    fileprivate func heard(_ body: [String: Any]) {
        let kind = body["kind"] as? String ?? ""
        if kind == "error" {  // the page's own words (a file or a style that didn't load): never a place
            Self.log.error("map page: \(body["message"] as? String ?? "", privacy: .public)")
        } else if ["page", "ready"].contains(kind) {
            Self.log.info("map page: \(kind, privacy: .public)")
        }
        switch body["kind"] as? String {
        case "page":  // the page's script is running: start the map where it was
            let c = camera.held(to: info)
            var start: [String: Any] = [
                "dark": dark, "red": redNight, "longitude": c.longitude, "latitude": c.latitude, "zoom": c.zoom,
                "bearing": c.bearing,
                "pitch": c.pitch, "bounds": [info.west, info.south, info.east, info.north],
                "maxZoom": Double(info.maxZoom) + 3, "printable": printable,
                "files": StreetMap.pageFiles(travel: travel.count), "tileMaxZoom": info.maxZoom,
                "pinIcons": Self.pinIcons,
            ]
            if let age {
                start["age"] = ["words": age.words, "color": age.old ? String(format: "#%06x", Palette.caution.light) : ""]
            }
            if let json = try? JSONSerialization.data(withJSONObject: start),
               let text = String(data: json, encoding: .utf8) {
                call("pm.start(\(text))")
            }
        case "ready":
            ready = true
            problem = nil
            watchdog.up()
            for layer in layers.keys { send(layer) }
            sendPosition()
            if let box = pendingFit {
                pendingFit = nil
                fit(west: box[0], south: box[1], east: box[2], north: box[3])
            }
        case "camera":
            guard let longitude = body["longitude"] as? Double, let latitude = body["latitude"] as? Double,
                  let zoom = body["zoom"] as? Double else { return }
            camera = StreetMap.Camera(longitude: longitude, latitude: latitude, zoom: zoom,
                                      bearing: body["bearing"] as? Double ?? 0, pitch: body["pitch"] as? Double ?? 0)
            memory.keep(camera)
        case "tap":
            guard let longitude = body["longitude"] as? Double, let latitude = body["latitude"] as? Double else { return }
            let point = (body["x"] as? Double).flatMap { x in (body["y"] as? Double).map { CGPoint(x: x, y: $0) } }
            onTap?(longitude, latitude, body["features"] as? [[String: Any]] ?? [], point, body["longPress"] as? Bool ?? false)
        case "drag":
            onDrag?()
        case "health":
            let loaded = body["tiles"] as? Bool ?? true
            if watchdog.report(tilesLoaded: loaded, served: files.tilesServed) { reload() }
        case "error":
            problem = "The map reported a problem; it is reloaded if it stops drawing."
        default:
            break
        }
    }
}

extension StreetMapController: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        if watchdog.ended() {  // iOS ended the page's process: start again where it was, unless it just did
            Self.log.info("map page: its process ended; reloading")
            reload()
        } else {
            Self.log.info("map page: its process ended again; the next try waits")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.log.info("map page: loaded")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Self.log.error("map page didn't load: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        Self.log.error("map page didn't load: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // only the map's own page; a tap on the credit link never leaves it
        decisionHandler(navigationAction.request.url?.scheme == StreetMapFiles.scheme ? .allow : .cancel)
    }
}

/// The page's messages, held weakly so the controller isn't kept alive by its own web view.
private final class WeakMessages: NSObject, WKScriptMessageHandler {
    weak var controller: StreetMapController?

    init(_ controller: StreetMapController) {
        self.controller = controller
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { controller?.heard(body) }
    }
}

/// The map's files, served to its page only: prepareme-map://app/<path> from the bundled StreetMapAssets folder, and
/// prepareme-map://tiles/street.pmtiles from the checked copy of the map file, by HTTP Range, and
/// prepareme-map://tiles/travel/<n>.pmtiles from each travel map's (`StreetMap.served`). Reads happen off the main
/// thread; a request the page has given up on gets no answer.
nonisolated final class StreetMapFiles: NSObject, WKURLSchemeHandler, @unchecked Sendable {  // reads off the main thread
    static let scheme = "prepareme-map"
    static let page = URL(string: "prepareme-map://app/web/streetmap.html")!
    static let assets = Bundle.main.url(forResource: "StreetMapAssets", withExtension: nil)

    let map: URL
    let travel: [URL]
    private let queue = DispatchQueue(label: "prepareme.streetmap.files")
    private let lock = NSLock()
    private var stopped = Set<ObjectIdentifier>()
    private var served = 0

    init(map: URL, travel: [URL] = []) {
        self.map = map
        self.travel = travel
    }

    var tilesServed: Int {
        lock.withLock { served }
    }

    static let types = ["html": "text/html", "mjs": "text/javascript", "js": "text/javascript", "css": "text/css",
                        "json": "application/json", "png": "image/png", "pbf": "application/x-protobuf"]

    /// The file a request names, or nil for anything outside the map's own files.
    func file(for url: URL) -> URL? {
        if url.host == "tiles" { return StreetMap.served(url, home: map, travel: travel) }
        guard url.host == "app", let root = Self.assets?.standardizedFileURL else { return nil }
        let path = url.path.removingPercentEncoding ?? url.path
        let found = root.appendingPathComponent(path).standardizedFileURL
        guard found.path.hasPrefix(root.path + "/") else { return nil }  // never outside the folder
        return found
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let range = task.request.value(forHTTPHeaderField: "Range")
        let key = ObjectIdentifier(task)
        let held = HeldTask(task: task)
        queue.async { [self] in
            let answer = read(url, range: range)
            DispatchQueue.main.async { [self] in
                let gone = lock.withLock { stopped.remove(key) != nil }
                guard !gone else { return }
                held.task.didReceive(answer.response)
                held.task.didReceive(answer.body)
                held.task.didFinish()
                if url.host == "tiles" { lock.withLock { served += 1 } }
            }
        }
    }

    /// A task carried to the reading queue and back to the main thread, where alone it is answered.
    private struct HeldTask: @unchecked Sendable {
        let task: any WKURLSchemeTask
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        _ = lock.withLock { stopped.insert(ObjectIdentifier(task)) }
    }

    private func read(_ url: URL, range: String?) -> (response: URLResponse, body: Data) {
        func status(_ code: Int) -> (URLResponse, Data) {
            (HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!, Data())
        }
        guard let file = file(for: url), let handle = try? FileHandle(forReadingFrom: file),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        else { return status(404) }
        defer { try? handle.close() }
        var start: Int64 = 0, end = size - 1, code = 200
        if let range, range.hasPrefix("bytes=") {
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard let first = parts.first.flatMap({ Int64($0) }), first < size else { return status(416) }
            start = first
            if parts.count > 1, let last = Int64(parts[1]) { end = min(last, size - 1) }
            code = 206
        }
        guard end >= start, (try? handle.seek(toOffset: UInt64(start))) != nil,
              let data = try? handle.read(upToCount: Int(end - start + 1)) else { return status(500) }
        var headers = ["Content-Type": Self.types[file.pathExtension] ?? "application/octet-stream",
                       "Content-Length": "\(data.count)", "Accept-Ranges": "bytes", "Cache-Control": "no-store",
                       "Access-Control-Allow-Origin": "*"]
        if code == 206 { headers["Content-Range"] = "bytes \(start)-\(start + Int64(data.count) - 1)/\(size)" }
        return (HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!, data)
    }
}

/// The page in SwiftUI, on the phone and the Mac.
#if os(iOS)
struct StreetMapWebView: UIViewRepresentable {
    let controller: StreetMapController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct StreetMapWebView: NSViewRepresentable {
    let controller: StreetMapController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
