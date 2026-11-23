import Foundation

/// The household's players (players-and-scoreboard plan, stage 2: `docs/plans/2026-11-18-players-and-scoreboard.md`):
/// a short list, made on the Mac only (choice A8), handed to every paired device (scope, amended 2026-11-18). A player
/// is a number given once and never used again, a nickname, one of `PlayerColor`'s few colors, and retired or not;
/// retiring never deletes, so a later stage's lines always find their player.
///
/// One file in the app's own folder on each device (Application Support › PrepareMe, beside `game-saves.json`): on the
/// Mac the list itself, which only the Players screen changes; on a phone or iPad the Mac's copy, replaced whole at each
/// look at home. The Mac also writes the copy the service hands out (`phoneFileName`, in the inventory folder the
/// service already reads). Nicknames are household details: never logged, never in git or a test (tests build theirs
/// from pieces), kept out of the device's backups and out of the USB drive's (`usbbackup` leaves `phoneFileName` out).
/// Every boundary checks the same limits (`read`): the Mac's own changes, the service before it serves the copy, the
/// phone before it keeps it, and the bridge's answers to a game.
public struct PlayerList: Codable, Equatable, Sendable {
    public static let fileName = "players.json"
    /// The copy the service serves (`GET /players.json`), in the inventory folder.
    public static let phoneFileName = "phone-players.json"
    /// Players not retired, at most.
    public static let most = 12
    /// Players in all, retired ones included: keeps the file small however long the household plays.
    public static let mostInAll = 64
    /// A nickname's length, in characters as a person counts them (the old typed name's limit at the card table).
    public static let nameMost = 12
    /// The file's largest size anywhere: 64 players fit in well under half of it.
    public static let fileLimit = 16_384

    public static let current = 1
    public var version = current
    /// The number the next player gets: numbers only ever go up.
    public private(set) var next = 1
    public private(set) var players: [Player] = []
    /// A file that couldn't be read was renamed to this, beside it, and the list started empty.
    public private(set) var setAside: String?
    /// The unreadable file couldn't even be renamed: this list never writes, so nothing overwrites it.
    public private(set) var blocked = false

    enum CodingKeys: String, CodingKey { case version, next, players }

    public init() {}

    public var active: [Player] { players.filter { !$0.retired } }

    public func player(_ id: Int) -> Player? { players.first { $0.id == id } }

    public enum Problem: String, Error, Sendable {
        case full = "Twelve players is the most; retire one first."
        case allUsed = "The list has no room left for another player."
        case empty = "A nickname needs at least one letter."
        case tooLong = "A nickname is 12 characters at most."
        case odd = "A nickname can't hold a line break or a hidden character."
        case taken = "Another player already has that nickname."
        case unknown = "That player isn't on the list."
        case blocked = "PrepareMe couldn't read its list of players, and couldn't set it aside."
    }

    /// Marks that show nothing, or turn the text around, kept out of a nickname; the joiner a picture of a person needs
    /// stays.
    static let hidden = CharacterSet(charactersIn: "\u{200B}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
                                     + "\u{2060}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}")

    /// The nickname as kept: spaces at either end dropped; nil with the reason when it breaks a rule.
    public static func nickname(_ typed: String) -> Result<String, Problem> {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.empty) }
        guard name.count <= nameMost else { return .failure(.tooLong) }
        guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control  // not the joiner
            || CharacterSet.newlines.contains($0) || hidden.contains($0) }) else {
            return .failure(.odd)
        }
        return .success(name)
    }

    private func taken(_ name: String, besides id: Int?) -> Bool {
        active.contains { $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    @discardableResult
    public mutating func add(_ typed: String, color: PlayerColor) throws -> Player {
        if blocked { throw Problem.blocked }
        guard active.count < Self.most else { throw Problem.full }
        guard players.count < Self.mostInAll else { throw Problem.allUsed }
        let name = try Self.nickname(typed).get()
        guard !taken(name, besides: nil) else { throw Problem.taken }
        let player = Player(id: next, name: name, color: color, retired: false)
        players.append(player)
        next += 1
        return player
    }

    public mutating func rename(_ id: Int, to typed: String) throws {
        if blocked { throw Problem.blocked }
        guard let at = players.firstIndex(where: { $0.id == id }) else { throw Problem.unknown }
        let name = try Self.nickname(typed).get()
        guard !taken(name, besides: id) else { throw Problem.taken }
        players[at].name = name
    }

    public mutating func recolor(_ id: Int, to color: PlayerColor) throws {
        if blocked { throw Problem.blocked }
        guard let at = players.firstIndex(where: { $0.id == id }) else { throw Problem.unknown }
        players[at].color = color
    }

    /// Retired, or brought back (within the cap, and only under a nickname no one else now has).
    public mutating func retire(_ id: Int, _ retired: Bool = true) throws {
        if blocked { throw Problem.blocked }
        guard let at = players.firstIndex(where: { $0.id == id }) else { throw Problem.unknown }
        guard players[at].retired != retired else { return }
        if !retired {
            guard active.count < Self.most else { throw Problem.full }
            guard !taken(players[at].name, besides: id) else { throw Problem.taken }
        }
        players[at].retired = retired
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.current else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "a later build's file")
        }
        next = try c.decode(Int.self, forKey: .next)
        players = try c.decode([Player].self, forKey: .players)
        // the same limits as a change on the Mac: a file that breaks one is unreadable, whoever wrote it
        let ids = players.map(\.id)
        guard players.count <= Self.mostInAll, active.count <= Self.most, Set(ids).count == ids.count,
              ids.allSatisfy({ $0 >= 1 && $0 < next }), next <= GameBridge.countMost,
              players.allSatisfy({ (try? Self.nickname($0.name).get()) == $0.name }),
              Set(active.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }).count
                == active.count else {
            throw DecodingError.dataCorruptedError(forKey: .players, in: c, debugDescription: "outside the limits")
        }
    }

    /// The list in `data`, or nil for anything over the size limit, unreadable, or outside any limit.
    public static func read(_ data: Data?) -> PlayerList? {
        guard let data, data.count <= fileLimit else { return nil }
        return try? JSONDecoder().decode(PlayerList.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// The list in `folder`: an empty one when there is none. A file that is there but can't be read is never
    /// overwritten: it is renamed aside with the date, as the game saves' store does, and the list starts empty (on a
    /// phone the next look at home brings the Mac's again); if even the rename fails, the list is `blocked`.
    public static func load(_ folder: URL, now: Date = Date()) -> PlayerList {
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return PlayerList() }
        if let found = read(try? Data(contentsOf: url)) { return found }
        var list = PlayerList()
        list.setAside = GameSaves.setAside(url, stem: "players", now: now)
        list.blocked = list.setAside == nil
        return list
    }

    /// Saved whole as `name` in `folder` (DurableFile), kept out of the device's backups.
    public func save(_ folder: URL, as name: String = fileName) throws {
        if blocked { throw Problem.blocked }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(name)
        try DurableFile.write(try encoded(), to: url)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

public struct Player: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: Int
    public var name: String
    public var color: PlayerColor
    public var retired: Bool

    public init(id: Int, name: String, color: PlayerColor, retired: Bool) {
        self.id = id
        self.name = name
        self.color = color
        self.retired = retired
    }

    /// The letter shown on the player's color, so a player is never told apart by color alone.
    public var letter: String { name.first.map { String($0).uppercased() } ?? "?" }
}

/// The players' own few colors, kept apart from the pages' meanings (red danger, amber caution, blue a key fact, green
/// fine, teal what you can press): none of those hues is here, and each always comes with the player's letter. Light
/// and dark, as 0xRRGGBB; the letter is `onChip` on it. The games draw the same six (`games/kit/kit.css`).
public enum PlayerColor: String, Codable, CaseIterable, Sendable {
    case violet, pink, plum, brown, slate, olive

    public var pair: Palette.Pair {
        switch self {
        case .violet: Palette.Pair(0x6d28d9, 0xc4b5fd)
        case .pink: Palette.Pair(0xbe185d, 0xf9a8d4)
        case .plum: Palette.Pair(0x86198f, 0xf0abfc)
        case .brown: Palette.Pair(0x7c4a2d, 0xd8b48f)
        case .slate: Palette.Pair(0x475569, 0xcbd5e1)
        case .olive: Palette.Pair(0x5b6118, 0xd4d58a)
        }
    }

    public static let onChip = Palette.Pair(0xffffff, 0x0d171c)

    public var word: String { rawValue.capitalized }
}
