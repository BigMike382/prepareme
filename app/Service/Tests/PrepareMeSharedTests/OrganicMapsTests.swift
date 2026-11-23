@testable import PrepareMeShared
import XCTest

/// The hand-off to Organic Maps (owner, 2026-10-14): links in the shape its own parser accepts.
final class OrganicMapsTests: XCTestCase {
    /// The shared file goes out as KML the way Organic Maps declares it (com.google.earth.kml, conforming to XML), and
    /// both of PrepareMe's Info.plists import that type, so the share sheet offers Organic Maps (the owner's report,
    /// 2026-10-19: as plain XML it wasn't offered).
    func testTheFileIsTheKMLTypeOrganicMapsOpens() throws {
        XCTAssertEqual(OrganicMaps.kmlType, "com.google.earth.kml")
        let kiwix = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Kiwix")
        for name in ["PrepareMeApp/Info.plist", "PrepareMeApp/Info-macOS.plist"] {
            let data = try Data(contentsOf: kiwix.appendingPathComponent(name))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let types = try XCTUnwrap(plist["UTImportedTypeDeclarations"] as? [[String: Any]], name)
            let kml = try XCTUnwrap(types.first { $0["UTTypeIdentifier"] as? String == OrganicMaps.kmlType }, name)
            XCTAssertEqual(kml["UTTypeConformsTo"] as? [String], ["public.xml"], name)
            let tags = try XCTUnwrap(kml["UTTypeTagSpecification"] as? [String: Any], name)
            XCTAssertEqual(tags["public.filename-extension"] as? [String], ["kml"], name)
        }
        let share = try String(contentsOf: kiwix.appendingPathComponent("PrepareMeApp/PrepareMeStreetMapScreen.swift"),
                               encoding: .utf8)
        XCTAssertTrue(share.contains("UTType(importedAs: OrganicMaps.kmlType"), "the share hands over that type")
        XCTAssertTrue(OrganicMaps.fileName.hasSuffix(".kml"))
    }

    /// Share picked ones (the owner's choice, 2026-10-19: "Pick several, then share"): only the ticked marks, in the
    /// list's order, and a tick for a mark since deleted is left out; the words say how many.
    func testOnlyThePickedMarksGoInTheFile() throws {
        let marks = [
            MapMark(id: 7, kind: .route, name: "SAMPLE Way out north", points: [[-77.0364, 38.8951], [-77.009, 38.8899]]),
            MapMark(id: 3, kind: .rally, name: "SAMPLE Big oak", points: [[-77.0364, 38.8951]], role: .nearHome),
            MapMark(id: 5, kind: .rally, name: "SAMPLE Library", points: [[-77.009, 38.8899]], role: .outOfTown),
        ]
        XCTAssertEqual(OrganicMaps.picked(marks, [7, 3, 99]).map(\.id), [3, 7], "the list's order; 99 is gone")
        XCTAssertEqual(OrganicMaps.picked(marks, []), [])
        let parsed = try XCTUnwrap(KMLRead(OrganicMaps.kml(OrganicMaps.picked(marks, [5]))))
        XCTAssertEqual(parsed.names, ["SAMPLE Library"])
        XCTAssertEqual(OrganicMaps.shareWords(count: nil), "Share to Organic Maps")
        XCTAssertEqual(OrganicMaps.shareWords(count: 1), "Share 1 to Organic Maps")
        XCTAssertEqual(OrganicMaps.shareWords(count: 2), "Share 2 to Organic Maps")
        XCTAssertEqual(OrganicMaps.shareWords(count: nil, gpx: true), "Share as GPX")  // task 3.5
        XCTAssertEqual(OrganicMaps.shareWords(count: 2, gpx: true), "Share 2 as GPX")
    }

    func testARouteHasAllFivePartsInOrder() throws {
        let url = try XCTUnwrap(OrganicMaps.url(from: (38.8951, -77.0364), to: (38.8899, -77.009),
                                                name: "Meet at the big oak", travel: .drive))
        XCTAssertEqual(url.absoluteString, "om://route?sll=38.895100,-77.036400&saddr=My%20location"
                       + "&dll=38.889900,-77.009000&daddr=Meet%20at%20the%20big%20oak&type=vehicle")
        let walk = try XCTUnwrap(OrganicMaps.url(from: (1, 2), to: (3, 4), name: "x", travel: .walk))
        XCTAssertTrue(walk.absoluteString.hasSuffix("&type=pedestrian"))
    }

    func testWithoutAPositionThePlaceIsShown() throws {
        let url = try XCTUnwrap(OrganicMaps.url(from: nil, to: (38.8899, -77.009), name: "Fire station",
                                                travel: .walk))
        XCTAssertEqual(url.absoluteString, "om://map?v=1&ll=38.889900,-77.009000&n=Fire%20station")
    }

    func testANameNeverBreaksTheLink() throws {
        let url = try XCTUnwrap(OrganicMaps.url(from: (1, 2), to: (3, 4), name: "Shop & Save + Gas?=",
                                                travel: .drive))
        let daddr = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "daddr" }?.value
        XCTAssertEqual(daddr, "Shop & Save + Gas?=")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name),
                       ["sll", "saddr", "dll", "daddr", "type"])
        XCTAssertNil(OrganicMaps.url(from: nil, to: (95, 0), name: "x", travel: .drive), "off the globe")
    }

    /// Step 6, part 3: every rally point (a pin) and route (a line) as one KML file Organic Maps imports offline, in
    /// the list's order (roles first), names and notes escaped, nothing else in it. Made-up marks in Washington, DC.
    func testTheMarksAsOneKMLFile() throws {
        let marks = [
            MapMark(id: 7, kind: .route, name: "SAMPLE Way out <north>", points: [[-77.0364, 38.8951], [-77.009, 38.8899]]),
            MapMark(id: 3, kind: .rally, name: "SAMPLE Big oak & bench", note: "SAMPLE by the \"gate\"",
                    points: [[-77.0364, 38.8951]], role: .nearHome),
            MapMark(id: 5, kind: .rally, name: "SAMPLE Library", points: [[-77.009, 38.8899]], role: .outOfTown),
        ]
        let kml = OrganicMaps.kml(marks)
        XCTAssertTrue(kml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\">"))
        XCTAssertEqual(OrganicMaps.fileName, "PrepareMe pins and routes.kml")
        let parsed = try XCTUnwrap(KMLRead(kml), "the file parses as XML")
        XCTAssertEqual(parsed.names, ["SAMPLE Big oak & bench", "SAMPLE Library", "SAMPLE Way out <north>"])
        XCTAssertEqual(parsed.descriptions, ["Near home. SAMPLE by the \"gate\"", "Out of town", ""])
        XCTAssertEqual(parsed.points, ["-77.0364,38.8951", "-77.009,38.8899"])
        XCTAssertEqual(parsed.lines, ["-77.0364,38.8951 -77.009,38.8899"])
        XCTAssertEqual(OrganicMaps.kml([]).contains("<Placemark>"), false)
        // A control character a pasted name might hold is dropped, so the file still parses (the review)
        let odd = [MapMark(kind: .rally, name: "SAMPLE Bob's\u{1}\u{FFFE} spot", note: "SAMPLE line one\nline two",
                           points: [[-77.0364, 38.8951]])]
        let oddRead = try XCTUnwrap(KMLRead(OrganicMaps.kml(odd)), "still parses")
        XCTAssertEqual(oddRead.names, ["SAMPLE Bob's spot"])
        XCTAssertEqual(oddRead.descriptions, ["SAMPLE line one\nline two"])
        let file = try XCTUnwrap(OrganicMaps.file(marks))
        XCTAssertEqual(file.lastPathComponent, OrganicMaps.fileName)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), kml)
    }

    /// No dead end without Organic Maps (the street map fixes plan, task 2.3): the message leads with the way when
    /// the phone knows where it is, then how to get the app; the title as before. Made-up places at sea.
    func testTheMissingAlertLeadsWithTheWayWhenKnown() {
        let known = OrganicMaps.missingWords(device: "phone", from: (10.0, -40.0), to: (10.0058, -40.0))
        XCTAssertEqual(known.title, "Organic Maps isn't on this phone")
        XCTAssertEqual(known.message, "Head north, 0.4 miles, 10 min+ on foot. " + OrganicMaps.installLine)
        let unknown = OrganicMaps.missingWords(device: "iPad", from: nil, to: (10.0, -40.0))
        XCTAssertEqual(unknown.title, "Organic Maps isn't on this iPad")
        XCTAssertEqual(unknown.message, OrganicMaps.installLine)
        XCTAssertTrue(OrganicMaps.installLine.hasPrefix("Directions open in Organic Maps, free in the App Store."))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lost = OrganicMaps.missingWords(device: "phone", from: (10.0, -40.0), to: (10.0058, -40.0),
                                            lostSince: now.addingTimeInterval(-240), now: now)
        XCTAssertEqual(lost.message, "GPS lost 4 minutes ago. Distances are from where you were. "
                       + "Head north, 0.4 miles, 10 min+ on foot. " + OrganicMaps.installLine, "an old fix says so (W9)")
    }

    /// GPX beside KML (task 3.5): each rally point a waypoint, each route a track, names and notes escaped as the KML
    /// file's are, in the list's order. Parsed back. Made-up marks in Washington, DC.
    func testGPXCarriesEveryMark() throws {
        let marks = [
            MapMark(id: 7, kind: .route, name: "SAMPLE Way <out>", points: [[-77.0364, 38.8951], [-77.009, 38.8899]],
                    routeRole: .main),
            MapMark(id: 3, kind: .rally, name: "SAMPLE Oak & bench", note: "SAMPLE by the gate",
                    points: [[-77.0364, 38.8951]], role: .nearHome),
        ]
        let gpx = OrganicMaps.gpx(marks)
        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\""))
        XCTAssertEqual(OrganicMaps.gpxFileName, "PrepareMe pins and routes.gpx")
        XCTAssertTrue(OrganicMaps.kml(marks).contains("<description>Main route</description>"),
                      "the KML file names a route's role too (task 2.1)")
        let read = try XCTUnwrap(GPXRead(gpx), "the file parses as XML")
        XCTAssertEqual(read.waypoints, ["38.8951,-77.0364 SAMPLE Oak & bench (Near home. SAMPLE by the gate)"])
        XCTAssertEqual(read.tracks, ["SAMPLE Way <out> (Main route): 38.8951,-77.0364 38.8899,-77.009"])
        let file = try XCTUnwrap(OrganicMaps.gpxFile(marks))
        XCTAssertEqual(file.lastPathComponent, OrganicMaps.gpxFileName)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), gpx)
    }
}

/// The parts of a KML file the test reads, by Foundation's XML parser: every Placemark's name and description, and
/// each Point's and LineString's coordinates.
private final class KMLRead: NSObject, XMLParserDelegate {
    var names: [String] = [], descriptions: [String] = [], points: [String] = [], lines: [String] = []
    private var path: [String] = [], text = "", about = ""

    init?(_ kml: String) {
        super.init()
        let parser = XMLParser(data: Data(kml.utf8))
        parser.delegate = self
        guard parser.parse() else { return nil }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        path.append(name)
        text = ""
        if name == "Placemark" { about = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let parent = path.dropLast().last
        switch (name, parent) {
        case ("name", "Placemark"): names.append(text)
        case ("description", "Placemark"): about = text
        case ("coordinates", "Point"): points.append(text)
        case ("coordinates", "LineString"): lines.append(text)
        case ("Placemark", _): descriptions.append(about)
        default: break
        }
        path.removeLast()
        text = ""
    }
}

/// The parts of a GPX file the test reads: each waypoint as "lat,lon name (desc)", each track as "name (desc): points".
private final class GPXRead: NSObject, XMLParserDelegate {
    var waypoints: [String] = [], tracks: [String] = []
    private var text = "", name = "", about = "", at = "", points: [String] = []

    init?(_ gpx: String) {
        super.init()
        let parser = XMLParser(data: Data(gpx.utf8))
        parser.delegate = self
        guard parser.parse() else { return nil }
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "wpt": (name, about, at) = ("", "", "\(attributes["lat"] ?? ""),\(attributes["lon"] ?? "")")
        case "trk": (name, about, points) = ("", "", [])
        case "trkpt": points.append("\(attributes["lat"] ?? ""),\(attributes["lon"] ?? "")")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "name": name = text
        case "desc": about = text
        case "wpt": waypoints.append("\(at) \(name)" + (about.isEmpty ? "" : " (\(about))"))
        case "trk": tracks.append(name + (about.isEmpty ? "" : " (\(about))") + ": " + points.joined(separator: " "))
        default: break
        }
        text = ""
    }
}
