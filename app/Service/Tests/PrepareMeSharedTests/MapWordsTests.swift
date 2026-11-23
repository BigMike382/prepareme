import Foundation
import Testing
@testable import PrepareMeShared

/// The street map pins plan, Task 1.1 (owner, 2026-11-14): a person never reads "rally", "Map Marks", "marks" or
/// "Start point" on a screen again. Reads the app's screens, the shared words and the map page, and fails on any
/// on-screen literal that still holds one. Names in the code, page ids and the owner's own text are not literals here.
struct MapWordsTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // Tests/PrepareMeSharedTests
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Exact literals that may stay, each with its reason. Starts empty.
    static let allowed: Set<String> = [
        "rally points and routes",  // UpdateCheck's stored count key; shown as "meeting places and routes"
    ]

    static let leftover = try! NSRegularExpression(pattern: "rally|map marks|start point|\\bmarks\\b",
                                                   options: [.caseInsensitive])
    static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    /// The scripts write their words in single quotes too (prepareme-live.js's event link slipped past double quotes).
    static let single = try! NSRegularExpression(pattern: #"'((?:[^'\\]|\\.)*)'"#)

    /// Every `.swift` and `.js` directly in the app's folder, every `.swift` under the shared words, and the map page.
    static func files() throws -> [URL] {
        let fm = FileManager.default
        let app = repo.appendingPathComponent("app/Kiwix/PrepareMeApp")
        var found = try fm.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { ["swift", "js"].contains($0.pathExtension) }
        let shared = repo.appendingPathComponent("app/Service/Sources/PrepareMeShared")
        let walk = fm.enumerator(at: shared, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL { if url.pathExtension == "swift" { found.append(url) } }
        found.append(repo.appendingPathComponent("app/StreetMapAssets/web/streetmap.js"))
        return found.sorted { $0.path < $1.path }
    }

    /// The literal without its `\(…)` interpolations, which are code, not words.
    static func withoutCode(_ text: String) -> String {
        var out = "", depth = 0, last: Character = " "
        for c in text {
            if depth > 0 {
                if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            } else if c == "(" && last == "\\" {
                out.removeLast()
                depth = 1
            } else {
                out.append(c)
            }
            last = c
        }
        return out
    }

    /// "file:line: literal" for each on-screen literal that still holds a leftover word.
    static func leftovers(in url: URL) throws -> [String] {
        let name = url.path.replacingOccurrences(of: repo.path + "/", with: "")
        var hits: [String] = []
        for (number, line) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            let range = NSRange(line.startIndex..., in: line)
            let quotes = url.pathExtension == "js" ? [literal, single] : [literal]
            for match in quotes.flatMap({ $0.matches(in: line, range: range) }) {
                let text = Self.withoutCode(String(line[Range(match.range(at: 1), in: line)!]))
                guard text.contains(" ") || text.first?.isUppercase == true, !allowed.contains(text) else { continue }
                if leftover.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    hits.append("\(name):\(number + 1): \(text)")
                }
            }
        }
        return hits
    }

    /// The plan's table, word for word (Task 1.1, step 3).
    @Test func theSharedWordsAreThePlans() {
        #expect(RallyWords.noRallyPoint(.child) == "No meeting place yet. They are added on an adult's phone or on the Mac.")
        #expect(RallyWords.noRallyPoint(.adult, device: "iPad")
                    == "No meeting place yet. Add one on the street map, once the map is on this iPad.")
        #expect(RallyWords.noRallyPoint(.noCopy, device: "iPad")
                    == "The meeting places haven't reached this iPad yet. They come from the Mac, at home on Wi-Fi.")
        #expect(RallyWords.noneOnMap(canEdit: true) == "No meeting place yet. Press and hold the map to add one.")
        #expect(RallyWords.noneOnMap(canEdit: false) == "No meeting place yet. They are added on an adult's phone or on the Mac.")
        #expect(RallyWords.backToRally == "Back to my meeting place")
        #expect(RallyWords.meetAt("Big oak") == "Meet at Big oak")
        #expect(StripFold.lessLabel == "Show less of the meeting place box")
        #expect(Position.kidsPointTo
                    == "The kids' phones point to the Near home meeting place, or to Out of town while Event mode is On.")
        #expect(StreetMap.startPoint
                    == "Where the printed turn lists begin. Put it around the corner, not at the house.")
        #expect(MapMarkWords.onePoint == "A meeting place is one place on the map.")
        #expect(MapMarkWords.full == "There are already 500 meeting places and routes; delete one first.")
        #expect(MapMarkWords.routeRole == "Only a meeting place is near home, outside the neighborhood or out of town.")
        #expect(MapMarkWords.startOnePoint == "The printed directions' start is one place on the map.")
        #expect(MapMarkWords.oneStart == "Printed directions already have a start; delete it first.")
        #expect(MapMarkWords.notAMark == "That isn't a pin PrepareMe made.")
        #expect(MapMarkWords.pickToShareOrDelete == "Tick the pins, then Share or Delete.")
        #expect(MapMarkWords.rallyShared == "It goes to the Mac and every phone at this phone's next check with the "
                    + "Mac. The kids' phones point to the Near home meeting place.")
        #expect(MapMarkWords.meetingPlace == "Meeting place")
        #expect(MapMarkWords.meetingPlaceWhy == "Where the family meets.")
        #expect(MapMarkWords.kidsPointHere == "The kids' phones point here")
        #expect(MapMarkWords.anotherPlace == "Another place to meet")
        #expect(MapMarkWords.whichOne == "Which one")
        #expect(MapMarkWords.changed("Big oak") == "Change on the street map: Big oak")
        #expect(OrganicMaps.fileName == "PrepareMe pins and routes.kml")
        #expect(OrganicMaps.gpxFileName == "PrepareMe pins and routes.gpx")
        #expect(AppleMaps.driveInAppleMaps == "Drive in Apple Maps (to the nearest road)")
        #expect(AppleMaps.walkInAppleMaps == "Walk in Apple Maps (to the nearest road)")
    }

    /// The update self-check keeps its stored key and says the new words (Ruling, Task 1.1).
    @Test func theUpdateCheckSaysMeetingPlaces() {
        let result = UpdateCheck.Result(from: "250", dropped: ["rally points and routes"],
                                        before: ["rally points and routes": 3], now: ["rally points and routes": 1])
        #expect(UpdateCheck.words(result).contains("meeting places and routes (3 before, 1 now)"))
        #expect(UpdateCheck.macLine(name: "Sam's iPhone", build: nil, result)?.contains("lost meeting places and routes")
                    == true)
        #expect(UpdateCheck.kinds.contains("rally points and routes"), "the key older builds keep")
    }

    @Test func noLeftoverWords() throws {
        let files = try Self.files()
        #expect(files.count > 20, "the folders were not found")
        let hits = try files.flatMap(Self.leftovers)
        let report = "\(hits.count) on-screen words still say rally, marks or Start point:\n"
            + hits.joined(separator: "\n")
        #expect(hits.isEmpty, Comment(rawValue: report))
    }
}
