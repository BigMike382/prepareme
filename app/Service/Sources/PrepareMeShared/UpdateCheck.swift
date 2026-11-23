import Foundation

/// The update self-check (owner, by click, 2026-11-14, before the switch to TestFlight): each build keeps this device's
/// counts, numbers only, never a name, each time PrepareMe opens and goes to the background; the first opening of a
/// different build (newer, or an older one from TestFlight's Previous Builds) compares its counts with the last ones
/// the build before kept, before anything is fetched. Home Mac › This install shows "Nothing lost in this update" or
/// what dropped; the room report carries the result, and the Mac's warnings box shows a line when something dropped.
public enum UpdateCheck {
    /// The counts, in the order the words name them (fixed words, each the room report's key too)
    public static let kinds = ["library files", "inventory items", "places", marks, "pins",
                               "Essential Documents files", "pairing with the Mac"]
    static let paired = "pairing with the Mac"
    /// The marks' key stays as older builds and the Mac keep it; a person reads "meeting places and routes" (the map
    /// pins plan, 2026-11-14)
    static let marks = "rally points and routes"
    static func shown(_ kind: String) -> String { kind == marks ? "meeting places and routes" : kind }

    /// One build's counts, kept on the device
    public struct Counts: Codable, Equatable, Sendable {
        public var build: String
        public var counts: [String: Int]

        public init(build: String, counts: [String: Int]) {
            self.build = build
            self.counts = counts
        }
    }

    /// A different build's first opening compared with the build before: its counts then and now, and which dropped
    public struct Result: Codable, Equatable, Sendable {
        public var from: String
        public var dropped: [String]
        public var before: [String: Int]
        public var now: [String: Int]

        public init(from: String, dropped: [String], before: [String: Int], now: [String: Int]) {
            self.from = from
            self.dropped = dropped
            self.before = before
            self.now = now
        }

        /// Sent by a phone: a build number of digits and dots, only `kinds`, never a negative count
        var isPlain: Bool {
            (1...32).contains(from.count) && from.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
                && Set(dropped).isSubset(of: kinds) && Set(before.keys).isSubset(of: kinds)
                && Set(now.keys).isSubset(of: kinds) && (before.values.min() ?? 0) >= 0 && (now.values.min() ?? 0) >= 0
        }
    }

    /// nil on the same build, or with no counts from a build before (the first build that keeps them)
    public static func compare(_ previous: Counts?, _ current: Counts) -> Result? {
        guard let previous, previous.build != current.build else { return nil }
        let dropped = kinds.filter { (current.counts[$0] ?? 0) < (previous.counts[$0] ?? 0) }
        return Result(from: previous.build, dropped: dropped, before: previous.counts, now: current.counts)
    }

    /// Home Mac › This install's line for the result
    public static func words(_ result: Result) -> String {
        guard !result.dropped.isEmpty else { return "Nothing lost in this update (from build \(result.from))." }
        let lost = result.dropped.map { kind in
            kind == paired ? "the pairing with the Mac" : "\(shown(kind)) (\(result.before[kind] ?? 0) before, \(result.now[kind] ?? 0) now)"
        }
        return "Something is missing since the update from build \(result.from): \(lost.joined(separator: ", ")). "
            + "Hold off updating anyone else, and check it at the Mac."
    }

    /// The Mac's warnings-box line for a phone whose report says something dropped; nil otherwise
    public static func macLine(name: String, build: String?, _ result: Result?) -> String? {
        guard let result, !result.dropped.isEmpty else { return nil }
        return "\(name) lost \(result.dropped.map(shown).joined(separator: ", ")) in its update from build \(result.from)"
            + "\(build.map { " to \($0)" } ?? ""). Hold off updating the other devices; its Downloads screen says what "
            + "changed."
    }
}
