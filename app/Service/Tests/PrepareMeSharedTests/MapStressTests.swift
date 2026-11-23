import Foundation
@testable import PrepareMeShared
import XCTest

/// The street map at its limits (a stress test, 2026-10-14): the most rally points and routes the editor keeps, a
/// grid over the widest area, and the conditions file at its caps. Made-up places in open ocean only.
final class MapStressTests: XCTestCase {
    /// 500 marks, half of them routes of 5,000 points: the strip, the list and the kids' view each read every way on
    /// each new fix, so one reading must stay well under a second.
    func testEveryWayFromAFullSetIsQuick() {
        var marks: [MapMark] = []
        for i in 0..<MapMark.markLimit {
            let lon = -40 + Double(i % 25) * 0.01, lat = 10 + Double(i / 25) * 0.01
            if i % 2 == 0 {
                marks.append(MapMark(id: Int64(i + 1), kind: .rally, name: "Point \(i)", points: [[lon, lat]]))
            } else {
                let points = (0..<MapMark.routePoints).map { [lon + Double($0) * 0.00001, lat + Double($0) * 0.00001] }
                marks.append(MapMark(id: Int64(i + 1), kind: .route, name: "Route \(i)", points: points))
            }
        }
        let start = Date()
        let ways = Position.ways(from: (10.1, -39.9), to: marks)
        let took = Date().timeIntervalSince(start)
        XCTAssertEqual(ways.count, MapMark.markLimit)
        #if DEBUG
        let limit = 2.0  // unoptimized: about 0.7 s on this Mac; the phone's Release build about 0.04 s here
        #else
        let limit = 0.2
        #endif
        XCTAssertLessThan(took, limit, "one reading of every way took \(took) s")
        print("STRESS ways: \(took) s")
    }

    /// The grid over an area of several states (100 km lines) and a town (1 km): quick, and every line inside it.
    func testTheGridOverAWideAreaIsQuickAndInside() {
        for (box, step) in [([-90.0, 30.0, -75.0, 40.0], 100_000), ([-77.03, 38.88, -76.99, 38.90], 1000),
                            ([-84.2, 35.0, -83.8, 35.3], 10_000)] {  // the last spans the zone 16/17 line at 84° W
            let start = Date()
            let grid = Position.grid(west: box[0], south: box[1], east: box[2], north: box[3], step: step)
            let took = Date().timeIntervalSince(start)
            XCTAssertLessThan(took, 1, "\(box): \(took) s")
            XCTAssertFalse(grid.lines.isEmpty, "\(box)")
            for line in grid.lines {
                for p in line.points {
                    XCTAssertTrue((box[0] - 1e-6...box[2] + 1e-6).contains(p[0]) && (box[1] - 1e-6...box[3] + 1e-6).contains(p[1]))
                }
            }
            print("STRESS grid \(box) step \(step): \(grid.lines.count) lines in \(took) s")
        }
    }

    /// The conditions file at its caps, 500 road events and 6 gauges, drawn with old ones hidden and shown.
    func testConditionsAtTheirCapsDrawQuickly() throws {
        let road = #"{"text":"Made Up St is closed.","detail":"","closure":true,"when":null,"place":[-40.1,10.9,-40.2,11.0],"as_of":"2026-10-14T10:07:00-04:00"}"#
        let gauge = #"{"text":"Made Up Creek","flag":"warn","code":"","place":[-40.2,11.0],"as_of":"2026-10-14T10:07:00-04:00"}"#
        let json = #"{"format":1,"roads":["# + Array(repeating: road, count: MapConditions.maxRoads).joined(separator: ",")
            + #"],"gauges":["# + Array(repeating: gauge, count: MapConditions.maxGauges).joined(separator: ",") + "]}"
        let read = try MapConditions(Data(json.utf8))
        let now = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00-04:00")!
        let start = Date()
        for _ in 0..<60 { _ = read.geoJSON(now: now) }  // an hour of the phone's minute-by-minute refresh
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertThrowsError(try MapConditions(Data(json.replacingOccurrences(of: #""gauges":["#, with: #""gauges":["# + gauge + ",").utf8)),
                             "one gauge over the cap is refused whole")
    }

    /// The real place list, when a session points at the Mac's own map file (it holds only public OpenStreetMap
    /// names): `PREPAREME_REAL_MAP=… swift test --filter MapStressTests`. Every search a person might type, each well
    /// under the 200 ms the search box waits.
    func testTheRealPlaceListIsQuick() throws {
        guard let path = ProcessInfo.processInfo.environment["PREPAREME_REAL_MAP"] else { throw XCTSkip("no real map") }
        let before = Self.resident(), heapBefore = Self.inUse()
        let box = Sampler(peak: before)
        let sampler = Thread {
            while !box.stop {
                box.peak = max(box.peak, Self.resident())
                usleep(20_000)
            }
        }
        sampler.start()
        var start = Date()
        let found = autoreleasepool { PlaceIndex(mapFile: URL(fileURLWithPath: path)) }
        box.stop = true
        let index = try XCTUnwrap(found)
        print("STRESS place list: \(index.places.count) places read in \(Date().timeIntervalSince(start)) s, "
              + "peak \(Int(box.peak - before)) MB resident, heap kept \(Int(Self.inUse() - heapBefore)) MB")
        let bytes = index.names.count + index.keys.count + 4 * (index.nameStarts.count + index.keyStarts.count)
            + 2 * index.kindOf.count + 4 * (index.longitudes.count + index.latitudes.count)
        print("STRESS place list holds \(bytes / 1_000_000) MB; malloc in use \(Int(Self.inUse())) MB")
        XCTAssertLessThan(bytes, 150_000_000)
        // the same list as JSONSerialization reads it, every place
        let list = try XCTUnwrap(Self.placeList(path))
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: list) as? [String: Any])
        let kinds = try XCTUnwrap(top["kinds"] as? [String]), rows = try XCTUnwrap(top["places"] as? [[Any]])
        XCTAssertEqual(rows.count, index.count)
        for n in stride(from: 0, to: rows.count, by: 997) {
            let row = rows[n], place = index[n]
            XCTAssertEqual(place.name, row[0] as? String)
            XCTAssertEqual(place.kind, kinds[(row[1] as! NSNumber).intValue])
            XCTAssertEqual(place.longitude, (row[2] as! NSNumber).doubleValue, accuracy: 1e-5)
            XCTAssertEqual(place.latitude, (row[3] as! NSNumber).doubleValue, accuracy: 1e-5)
        }
        for query in ["a", "water", "pharm", "gas", "hospital", "main st", "o'", "o\u{2019}", "zzzzqqq", "restroom", "shelter",
                      String(repeating: "a", count: 200)] {
            start = Date()
            let found = index.search(query, near: (35.5, -80.0), limit: 8)
            let took = Date().timeIntervalSince(start)
            print("STRESS search \(query.prefix(12)): \(found.count) found in \(took) s; first: \(found.first?.kind ?? "-")")
            XCTAssertLessThan(took, 1.5, query)
        }
    }

    final class Sampler: @unchecked Sendable {
        var peak: Double
        var stop = false
        init(peak: Double) { self.peak = peak }
    }

    static func resident() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return Double(info.resident_size) / 1e6
    }

    /// The place list's JSON out of a map file, as PlaceIndex(mapFile:) finds it.
    static func placeList(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path), let head = try? handle.read(upToCount: 127) else {
            return nil
        }
        func number(_ at: Int) -> UInt64 {
            head.subdata(in: at..<at + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }
        try? handle.seek(toOffset: number(24))
        guard let raw = try? handle.read(upToCount: Int(number(32))),
              let unpacked = Gzip.inflate(raw), let meta = try? JSONSerialization.jsonObject(with: unpacked) as? [String: Any],
              let pointer = meta["prepareme_places"] as? [String: Any],
              let offset = (pointer["offset"] as? NSNumber)?.uint64Value,
              let length = (pointer["length"] as? NSNumber)?.intValue else { return nil }
        try? handle.seek(toOffset: number(56) + offset)
        return (try? handle.read(upToCount: length)).flatMap(Gzip.inflate)
    }

    static func inUse() -> Double {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Double(stats.size_in_use) / 1e6
    }
}
