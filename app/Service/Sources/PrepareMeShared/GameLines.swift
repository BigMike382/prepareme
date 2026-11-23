import Foundation

/// One finished game (players-and-scoreboard plan, stage 3, section 14 A): written once by the app when a page of our
/// own games sends it (`GameBridge`'s "line" ask), never changed. The page gives the game's facts; the app adds what a
/// page must not choose (`folder`, `device`, `count`, `kept`, `v`). A line never holds a nickname: a person is a
/// player's number or `guest`, and a computer opponent's name is checked against the player list before it is kept.
public struct GameLine: Codable, Equatable, Sendable {
    public static let current = 1
    public var v = current
    /// 128 random bits as 32 lowercase hex digits, made when the game is dealt and kept in its save.
    public var id: String
    /// The asking page's own folder (the app's, from the page's address) and the game's key at its table.
    public var folder: String
    public var game: String
    public var rules: Int
    public var strength: String
    public var players: Int
    public var goal: Int?
    /// The device's clock at the deal and at the end, whole seconds.
    public var began: Int
    public var ended: Int
    public var seats: [Seat]
    public var scores: [Int]
    public var winners: [Int]
    public var how: String
    public var by: Int?
    public var hands: Int
    public var generation: Int
    public var extra: [String: [Int]]
    public var device: String
    public var count: Int
    public var kept: Int

    /// A seat: a player's number, a guest, or a computer opponent by the table's own name for it.
    public enum Seat: Codable, Equatable, Hashable, Sendable {
        case player(Int)
        case guest
        case computer(String)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let id = try? c.decode(Int.self) {
                self = .player(id)
            } else {
                let name = try c.decode(String.self)
                self = name == "guest" ? .guest : .computer(name)
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .player(let id): try c.encode(id)
            case .guest: try c.encode("guest")
            case .computer(let name): try c.encode(name)
            }
        }
    }

    /// The fields a page sends, all of them required but `goal`, `by` and `extra`.
    static let fromPage: Set<String> = ["id", "game", "rules", "strength", "players", "goal", "began", "ended", "seats",
                                        "scores", "winners", "how", "by", "hands", "generation", "extra"]
    static let optional: Set<String> = ["goal", "by", "extra"]
    static let strengths: Set<String> = ["easy", "medium", "hard"]
    /// A game of one (Solitaire) has no computer players: its one seat is a person, and its `strength` is its turning
    /// rule, one card or three (games refresh plan, section 35).
    static let turns: Set<String> = ["one", "three"]
    static let hows: Set<String> = ["finished", "given up"]
    /// 2020-01-01 to 2100-01-01: a clock outside it is wrong.
    static let clock = 1_577_836_800...4_102_444_800
    static let score = -100_000...100_000

    static func isHex32(_ text: String) -> Bool {
        text.utf8.count == 32 && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
    /// A computer opponent's name: 1 to 12 letters, a capital first, and never a guest by another spelling.
    static func isComputer(_ name: String) -> Bool {
        (1...12).contains(name.count) && name.lowercased() != "guest" && name.unicodeScalars.first.map { ("A"..."Z").contains($0) } == true
            && name.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
    }

    /// Whether the line keeps every rule but the player list's (`GameSaves.answer` checks that against the device's list).
    var isSound: Bool {
        guard v == Self.current, Self.isHex32(id), GameBridge.isKey(folder), GameBridge.isKey(game), (1...1000).contains(rules),
              (Self.strengths.contains(strength) && (2...8).contains(players)) || (Self.turns.contains(strength) && players == 1),
              seats.count == players,
              scores.count == players, scores.allSatisfy(Self.score.contains),
              (goal.map { (1...100_000).contains($0) } ?? true),
              Self.clock.contains(began), Self.clock.contains(ended), ended >= began,
              Self.hows.contains(how), (0...10_000).contains(hands), (0...1000).contains(generation),
              Set(winners).count == winners.count, winners.allSatisfy({ (0..<players).contains($0) }),
              extra.count <= 4 else { return false }
        if how == "finished" { guard !winners.isEmpty, by == nil else { return false } }
        else { guard winners.isEmpty, let by, (0..<players).contains(by) else { return false } }
        for (name, counts) in extra {
            guard (1...12).contains(name.count), name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }),
                  counts.count == players, counts.allSatisfy({ (0...100_000).contains($0) }) else { return false }
        }
        var people = Set<Int>()
        for seat in seats {
            switch seat {
            case .player(let n): guard n >= 1, people.insert(n).inserted else { return false }
            case .guest: break
            case .computer(let name): guard Self.isComputer(name) else { return false }
            }
        }
        if let by, case .computer = seats[by] { return false }  // only a person gives up
        if players == 1, case .computer = seats[0] { return false }  // a game of one is a person's
        return true
    }

    /// The page's line, checked: kinds, sizes and the rules above; the app's own fields are filled in later
    /// (`GameLines.keep`). Nil for anything else.
    static func page(_ value: Any?, folder: String) -> GameLine? {
        guard let page = value as? [String: Any], Set(page.keys).isSubset(of: fromPage),
              fromPage.subtracting(optional).isSubset(of: Set(page.keys)),
              !page.values.contains(where: { $0 is NSNull }),
              JSONSerialization.isValidJSONObject(page),
              let data = try? JSONSerialization.data(withJSONObject: page), data.count <= GameLines.lineLimit else { return nil }
        struct Page: Decodable {
            var id, game, strength, how: String
            var rules, players, began, ended, hands, generation: Int
            var goal, by: Int?
            var seats: [Seat]
            var scores, winners: [Int]
            var extra: [String: [Int]]?
        }
        guard noBooleans(page), let p = try? JSONDecoder().decode(Page.self, from: data) else { return nil }
        let line = GameLine(id: p.id, folder: folder, game: p.game, rules: p.rules, strength: p.strength, players: p.players,
                            goal: p.goal, began: p.began, ended: p.ended, seats: p.seats, scores: p.scores, winners: p.winners,
                            how: p.how, by: p.by, hands: p.hands, generation: p.generation, extra: p.extra ?? [:],
                            device: String(repeating: "0", count: 32), count: 1, kept: p.ended)
        return line.isSound ? line : nil
    }

    /// JavaScript's true and false arrive as NSNumbers that would read as 1 and 0: refused anywhere in the line.
    private static func noBooleans(_ value: Any) -> Bool {
        if let number = value as? NSNumber { return CFGetTypeID(number) != CFBooleanGetTypeID() }
        if let list = value as? [Any] { return list.allSatisfy(noBooleans) }
        if let object = value as? [String: Any] { return object.values.allSatisfy(noBooleans) }
        return true
    }
}

/// The app's own store of finished games' lines on one device (stage 3): a file of its own in the app's folder beside
/// `game-saves.json` (whose size must not grow with the lines), one line of text for each game, added at the end and
/// never rewritten, on the phone and the Mac alike. Its first line names this device (`device`, 128 random bits, made
/// once with the file, never its label); each game line follows as JSON. Nothing of it is logged, backed up by the
/// device, put in the iCloud backup or the USB drive's, or sent anywhere in this stage. A session never opens the real
/// file (CLAUDE.md, the players bullet).
///
/// A file that can't be read at all (not UTF-8, or its first line not this store's) is set aside under a dated name and
/// the store starts again with a new device number, so a device's own count never repeats under one number; a bad line
/// of text (a torn last line after a power cut, a damaged one) is skipped and counted, never the whole file. Each line
/// is appended and forced to the disk before the page is answered (`keep`): an append can't be swapped in whole like the
/// saves file, so a torn end is what a cut can leave, and the next append starts on a fresh line.
public final class GameLines {
    public static let fileName = "game-lines.jsonl"
    /// The most lines a device keeps: about five and a half years at ten games a day, and the file stays near 10 MB at
    /// the lines' usual size (20 MB at most at the size limit's half). At the cap a new line is refused (`full`), and
    /// the Scoreboard says newer games aren't counted; stage 4 moves lines to the Mac, which may then make room.
    public static let most = 20_000
    /// A line's largest size, in bytes of UTF-8, the app's fields included.
    public static let lineLimit = 2_048
    /// Lines a "lines" answer carries: about 250 KB at the usual size.
    public static let pageSize = 500

    struct Head: Codable { var v: Int; var device: String }

    public let url: URL
    /// This device's number, from the file's first line; nil until the first line is kept.
    public private(set) var device: String?
    /// Each kept line's JSON text, in the order kept.
    public private(set) var texts: [String] = []
    /// The last line's count: the next is one more.
    public private(set) var last = 0
    /// Lines of text skipped as unreadable when the file was read.
    public private(set) var skipped = 0
    /// A file that couldn't be read was renamed to this, beside it, and the store started empty.
    public private(set) var setAside: String?
    /// The unreadable file couldn't even be renamed: this store never writes, so nothing overwrites it.
    public private(set) var blocked = false
    private var ids: Set<String> = []
    private var cleanEnd = true

    public enum Problem: Error, Equatable { case full, blocked }

    init(url: URL) { self.url = url }

    public var full: Bool { texts.count >= Self.most }

    public static func load(_ folder: URL, now: Date = Date()) -> GameLines {
        let store = GameLines(url: folder.appendingPathComponent(fileName))
        guard FileManager.default.fileExists(atPath: store.url.path) else { return store }
        guard let data = try? Data(contentsOf: store.url), let text = String(data: data, encoding: .utf8),
              let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              let head = try? JSONDecoder().decode(Head.self, from: Data(first.utf8)),
              head.v == GameLine.current, GameLine.isHex32(head.device) else {
            store.setAside = GameSaves.setAside(store.url, stem: "game-lines", ext: "jsonl", now: now)
            store.blocked = store.setAside == nil
            return store
        }
        store.device = head.device
        store.cleanEnd = data.last == UInt8(ascii: "\n")
        let decoder = JSONDecoder()
        for row in text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            guard let line = try? decoder.decode(GameLine.self, from: Data(row.utf8)), line.isSound,
                  line.device == head.device, line.count > store.last, row.utf8.count <= lineLimit,
                  store.texts.count < most, store.ids.insert(line.id).inserted else {
                store.skipped += 1
                continue
            }
            store.texts.append(String(row))
            store.last = line.count
        }
        return store
    }

    /// The page's line kept, with the app's fields: true; false when a line with its `id` is already kept (and nothing
    /// is written). Throws `Problem` at the cap or when blocked, and a file error when the write fails.
    @discardableResult
    public func keep(_ page: GameLine, now: Date = Date()) throws -> Bool {
        if blocked { throw Problem.blocked }
        if ids.contains(page.id) { return false }
        if full { throw Problem.full }
        var line = page
        let made = device == nil
        line.device = device ?? Self.newDevice()
        line.count = last + 1
        line.kept = Int(now.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(line), as: UTF8.self)
        guard text.utf8.count <= Self.lineLimit else { throw CocoaError(.fileWriteInvalidFileName) }
        if made {
            let head = String(decoding: try encoder.encode(Head(v: GameLine.current, device: line.device)), as: UTF8.self)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DurableFile.write(Data((head + "\n").utf8), to: url)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var marked = url
            try? marked.setResourceValues(values)
            device = line.device
            cleanEnd = true
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data(((cleanEnd ? "" : "\n") + text + "\n").utf8))
        try file.synchronize()
        cleanEnd = true
        texts.append(text)
        ids.insert(line.id)
        last = line.count
        return true
    }

    /// The lines from `from` (an index into `texts`), at most `pageSize`, as one JSON array's text, and where the next
    /// page starts (nil: none).
    public func page(from: Int) -> (text: String, next: Int?) {
        let start = min(max(from, 0), texts.count), end = min(start + Self.pageSize, texts.count)
        return ("[" + texts[start..<end].joined(separator: ",") + "]", end < texts.count ? end : nil)
    }

    static func newDevice() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
