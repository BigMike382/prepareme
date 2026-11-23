import Foundation

/// The printed turn lists (hand-off improvements plan, phase 3): the lists job's `turn-lists.json` in the inventory
/// folder (readiness/turns.py), from the Start point to each rally point and along each drawn route, by car and on
/// foot, or why one was left out. Mac only: never in the phones' copy. The marks panel shows a line under each mark
/// (`line`), and warns when a list names where the household lives (`namesHome`). Both, and anything that prints the
/// lists, go through `madeFor`: a mark's id is used again once the newest mark is deleted (InventoryFile.addMark), so
/// an id alone would put a deleted mark's turns under a new mark's name.
public struct TurnLists: Codable, Equatable, Sendable {
    public struct Turn: Codable, Equatable, Sendable {
        public let say: String
        public let miles: Double
    }

    public struct List: Codable, Equatable, Sendable {
        public let mark: Int64
        public let travel: String  // "car" or "foot"
        public let miles: Double
        public let minutes: Int
        public let turns: [Turn]
    }

    public struct LeftOut: Codable, Equatable, Sendable {
        public let mark: Int64
        public let travel: String
        public let why: String
    }

    /// A mark as the lists were made for it.
    public struct Routed: Codable, Equatable, Sendable {
        public let mark: Int64
        public let kind: String
        public let points: [[Double]]
    }

    public let madeAt: String
    public let dataDate: String?
    public let start: Int64?
    public let lists: [List]
    public let leftOut: [LeftOut]
    public let whyNone: String?
    /// nil in a file made before 2026-10-31: every line then waits for the next run, which makes it again.
    public var marks: [Routed]?

    enum CodingKeys: String, CodingKey {
        case start, lists, marks
        case madeAt = "made_at", dataDate = "data_date", leftOut = "left_out", whyNone = "why_none"
    }

    public static let fileName = "turn-lists.json"
    static let travels = [("car", "by car"), ("foot", "on foot")]
    public static let notYet = "Turn lists come with the lists job's next hourly run."
    public static let namesHomeWarning = "This list names your street: move the printed directions' start."
    public static let namesHomeRouteWarning = "This list names your street: move the route's first click."

    /// The lists in `folder`, or nil when there are none yet or they can't be read.
    public static func read(in folder: URL) -> TurnLists? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(TurnLists.self, from: data)
    }

    /// Whether the lists under `mark`'s id were made for it as it is now: the same kind and points, and for a rally
    /// point the same Start point (`start`: the mark of that kind now, if any). Otherwise they are another mark's, or
    /// from before it moved, and wait for the next run.
    public func madeFor(_ mark: MapMark, start: MapMark?) -> Bool {
        guard let marks else { return false }
        func same(_ id: Int64?, _ now: MapMark?) -> Bool {
            guard let now else { return id == nil }
            guard let then = marks.first(where: { $0.mark == id }), then.kind == now.kind.rawValue,
                  then.points.count == now.points.count else { return false }
            return zip(then.points, now.points).allSatisfy { a, b in
                a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
            }
        }
        return same(mark.id, mark) && (mark.kind != .rally || same(self.start, start))
    }

    /// Under a rally point or route on the Mac: "Turns made Oct 30, 6:52 PM: 1.1 mi by car, 0.8 mi on foot", what was
    /// left out and why, or why there are none.
    public func line(for mark: MapMark, start: MapMark?, timeZone: TimeZone = .current) -> String {
        if let whyNone { return "No turn lists: \(whyNone)." }
        guard madeFor(mark, start: start) else { return Self.notYet }
        let made = Self.travels.compactMap { travel, words in
            lists.first { $0.mark == mark.id && $0.travel == travel }
                .map { String(format: "%.1f mi %@", $0.miles, words) }
        }
        let left = Self.travels.compactMap { travel, words in
            leftOut.first { $0.mark == mark.id && $0.travel == travel }.map { (words: words, why: $0.why) }
        }
        if made.isEmpty, let first = left.first, left.allSatisfy({ $0.why == first.why }) {
            return "No turn lists: \(first.why)."
        }
        let reasons = left.map { "\($0.words), \($0.why)" }.joined(separator: "; ")
        if made.isEmpty { return left.isEmpty ? Self.notYet : "No turn lists \(reasons)." }
        return "Turns made \(Self.when(madeAt, timeZone)): \(made.joined(separator: ", "))."
            + (left.isEmpty ? "" : " None \(reasons).")
    }

    /// Whether a list for `mark` holds one of the owner's words for where the household lives (the words household
    /// pages are checked against, kept on this Mac only): the Start point is then too close to home to print.
    public func namesHome(_ mark: MapMark, start: MapMark?, words: [String]) -> Bool {
        madeFor(mark, start: start) && lists.contains {
            $0.mark == mark.id && $0.turns.contains { HouseholdMedia.holdsOwnWord($0.say, words: words) }
        }
    }

    static func when(_ stamp: String, _ timeZone: TimeZone) -> String {
        guard let date = ISO8601DateFormatter().date(from: stamp) else { return stamp }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "MMM d, h:mm a"
        return format.string(from: date)
    }
}
