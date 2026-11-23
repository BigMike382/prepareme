import Foundation

/// Which topo map covers a spot (plan phase 9, item 6): "Topo map for here" on the street map. Read from the overview
/// file's Find a map page, whose every map link carries its corners (packer/map_pages.py `_current`, `data-bounds`:
/// west south east north), so the street map and the topo PDFs are one experience and nobody has to know which file
/// holds which map.
public struct TopoIndex: Equatable, Sendable {
    public struct Map: Equatable, Sendable {
        public let name: String
        public let fileID: String  // the topo file's library ID
        public let path: String  // the PDF's path in that file
        public let west: Double, south: Double, east: Double, north: Double

        public func contains(longitude: Double, latitude: Double) -> Bool {
            (west...east).contains(longitude) && (south...north).contains(latitude)
        }
    }

    public let maps: [Map]

    /// The page Find a map is, in the overview file (packer/map_pages.py's MAP_PAGES["find"]).
    public static let page = "find-a-map.html"

    /// Maps' first page, on the Mac and the phone (phase L, finding 1): Find a map beside the overview's front page
    /// `main`, as Guides opens guides.html beside the daily one; the front page itself is only a title and two links
    /// (packer/build.py's plain front page). An overview without Find a map (`holds` says whether the file has a page)
    /// opens its front page rather than a missing one.
    public static func firstPage(beside main: URL, holds: @Sendable (URL) async -> Bool) async -> URL {
        let find = MacRow.address(page, beside: main)
        return await holds(find) ? find : main
    }

    /// Every map link of the page, once each (a map listed under two counties is one map).
    public init(page html: String) {
        let pattern = #"<a href="zim://([0-9a-fA-F-]{36})/([^"]+\.pdf)" data-bounds="(-?[0-9.]+) (-?[0-9.]+) (-?[0-9.]+) (-?[0-9.]+)">([^<]*)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            maps = []
            return
        }
        var seen = Set<String>(), found: [Map] = []
        let text = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            func part(_ i: Int) -> String { text.substring(with: match.range(at: i)) }
            let numbers = (3...6).compactMap { Double(part($0)) }
            guard numbers.count == 4, numbers[0] < numbers[2], numbers[1] < numbers[3],
                  seen.insert(part(1).lowercased() + "/" + part(2)).inserted else { continue }
            found.append(Map(name: HTMLText.unescaped(part(7)), fileID: part(1).lowercased(), path: part(2),
                             west: numbers[0], south: numbers[1], east: numbers[2], north: numbers[3]))
        }
        maps = found
    }

    /// The maps that cover the spot, the one whose middle is nearest first (a spot on a map's edge is on two).
    public func covering(longitude: Double, latitude: Double) -> [Map] {
        maps.filter { $0.contains(longitude: longitude, latitude: latitude) }.sorted { a, b in
            func off(_ m: Map) -> Double {
                let dx = (m.west + m.east) / 2 - longitude, dy = (m.south + m.north) / 2 - latitude
                return dx * dx + dy * dy
            }
            return (off(a), a.name) < (off(b), b.name)
        }
    }

    /// Those of `covering` in a file this device holds (`held`: library IDs, any case): Find a map lists every topo
    /// file's maps, optional ones included, and a link into a file the phone never took opens nothing (an audit,
    /// 2026-10-14).
    public func covering(longitude: Double, latitude: Double, held: Set<String>) -> [Map] {
        let ids = Set(held.map { $0.lowercased() })
        return covering(longitude: longitude, latitude: latitude).filter { ids.contains($0.fileID) }
    }

    /// The link that opens the map in the reader.
    public static func url(_ map: Map) -> URL? {
        URL(string: "zim://\(map.fileID)/\(map.path)")
    }
}
