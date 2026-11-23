import Foundation

/// The game bridge (players-and-scoreboard plan, stage 1: `docs/plans/2026-11-18-players-and-scoreboard.md`): one
/// message path from a page of our own games to the app, with an answer back, and the app's own store for each game's
/// save. Shared so `swift test` runs the page script and the checks in a real web view (GameSavesTests); WebKit stays
/// out of this module (the service links it), so the app's handler (`PrepareMeGameSaves`) hands in the sender's
/// facts as a `Frame`.
///
/// Who may use it: every page of the games file shares one web address, so a third-party game in it could otherwise
/// reach the bridge (the plan's finding 1). The handler and its page script live in a content world of their own
/// (`world`), which no page script can see; the script runs at document start, main frame only, and joins only a page
/// inside a folder of our own games (`kit/ours.json` in the games file, built by the packer from
/// `games/release.toml`), judged before any script of the page runs, so a page can't move itself into one of our
/// folders (pushState) first. The app checks the sender again (`answer`): main frame, the games file, one of our folders.
public enum GameBridge {
    /// The content world the handler and its page script live in, apart from the page's own scripts.
    public static let world = "PrepareMeGames"
    /// The handler's name, inside `world` only.
    public static let handler = "pmGame"
    /// The one message version. Each stage adds asks, never fields to an ask already known (stage 2: "players" and
    /// "usual"; stage 3: "line", "lines"), so a page that sends a newer ask to an older app gets "a message it doesn't
    /// know" and carries on as before (page storage, a typed name). (Stage 1b added `n` to keep before anything
    /// shipped, so the version stayed 1.)
    public static let version = 1
    /// A save's count's largest value: JavaScript counts exactly up to here.
    public static let countMost = 9_007_199_254_740_991
    /// A save's largest size, in bytes of UTF-8 (the card table's whole save, records included, is a few kilobytes).
    public static let saveLimit = 1_048_576
    /// Our own games' list in the games file, and its limits.
    public static let oursPath = "kit/ours.json"
    public static let oursLimit = 16_384
    public static let oursMost = 64

    /// The sender, as WebKit gives it (`WKScriptMessage.frameInfo`).
    public struct Frame: Sendable {
        public var isMain: Bool
        public var scheme: String
        public var host: String
        public var path: String  // the frame's address's path, percent-decoded
        public init(isMain: Bool, scheme: String, host: String, path: String) {
            self.isMain = isMain
            self.scheme = scheme
            self.host = host
            self.path = path
        }
    }

    /// Why a message was refused: fixed words, the only thing about a message the app ever logs.
    public enum Refusal: String, CaseIterable, Error, Sendable {
        case framed = "a framed page"
        case elsewhere = "a page outside the games file"
        case notOurs = "a page outside our own games"
        case unknown = "a message it doesn't know"
        case tooBig = "a save over the limit"
        case older = "an older save than the one kept"
        case notSaved = "the save couldn't be written"
        case noPlayer = "a player not on the list"
        /// Stage 3's lines.
        case badLine = "a line that breaks the rules"
        case lineTooBig = "a line over the limit"
        case full = "the store of lines is full"
    }

    public enum Ask: Equatable, Sendable {
        case keep(key: String, save: String, n: Int)
        case give(key: String)
        /// Stage 2: the players not retired, and this device's usual player.
        case players(key: String)
        /// Stage 2: this device's usual player, from now on.
        case usual(key: String, id: Int)
        /// Stage 3: a finished game's line to keep (the page's fields, checked; the app's are filled in when kept).
        case line(key: String, line: GameLine)
        /// Stage 3: the kept lines, a page of them from `from`.
        case lines(key: String, from: Int)
    }

    /// Our own games' keys from `kit/ours.json`, or nil for anything but `{"ours": [keys]}` within the limits.
    public static func ours(from data: Data?) -> [String]? {
        guard let data, data.count <= oursLimit,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1, let keys = object["ours"] as? [String],
              keys.count <= oursMost, Set(keys).count == keys.count,
              keys.allSatisfy(isKey) else { return nil }
        return keys
    }

    /// A game's key, as the packer allows it (librarian.games `_KEY`), and never the kit's or the rules' folder.
    static func isKey(_ key: String) -> Bool {
        (1...40).contains(key.count) && !["kit", "rules"].contains(key)
            && key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The folder of ours a page at `path` (within the games file, percent-decoded) is inside, or nil: a page in
    /// `<key>/…`, no `.` or `..` part. The page script holds the same rule in its own words (`pageScript`).
    public static func folder(of path: String, ours: [String]) -> String? {
        let parts = path.drop { $0 == "/" }.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts.contains("."), !parts.contains(".."), ours.contains(parts[0]) else { return nil }
        return parts[0]
    }

    /// The save's key for a game: `pm-` and its folder, as the card table's `pm-cardtable`.
    public static func key(of folder: String) -> String { "pm-\(folder)" }

    /// What `body` asks, if the sender may ask it and the message is one stage 1 knows; else why not.
    public static func check(_ body: Any, from frame: Frame, gamesID: UUID?, ours: [String]) -> Result<Ask, Refusal> {
        guard frame.isMain else { return .failure(.framed) }
        guard let gamesID, frame.scheme == "zim", UUID(uuidString: frame.host) == gamesID else {
            return .failure(.elsewhere)
        }
        guard let folder = folder(of: frame.path, ours: ours) else { return .failure(.notOurs) }
        guard let message = body as? [String: Any], isOne(message["v"]),
              let ask = message["ask"] as? String, message["key"] as? String == key(of: folder) else {
            return .failure(.unknown)
        }
        let key = key(of: folder)
        switch ask {
        case "give" where Set(message.keys) == ["v", "ask", "key"]:
            return .success(.give(key: key))
        case "keep" where Set(message.keys) == ["v", "ask", "key", "save", "n"]:
            guard let save = message["save"] as? String, let n = count(message["n"]) else { return .failure(.unknown) }
            guard save.utf8.count <= saveLimit else { return .failure(.tooBig) }
            guard (try? JSONSerialization.jsonObject(with: Data(save.utf8), options: .fragmentsAllowed)) != nil else {
                return .failure(.unknown)
            }
            return .success(.keep(key: key, save: save, n: n))
        case "players" where Set(message.keys) == ["v", "ask", "key"]:
            return .success(.players(key: key))
        case "usual" where Set(message.keys) == ["v", "ask", "key", "player"]:  // `id` is the page script's own
            guard let id = count(message["player"]), id >= 1 else { return .failure(.unknown) }
            return .success(.usual(key: key, id: id))
        case "line" where Set(message.keys) == ["v", "ask", "key", "line"]:
            if let page = message["line"] as? [String: Any], JSONSerialization.isValidJSONObject(page),
               let data = try? JSONSerialization.data(withJSONObject: page), data.count > GameLines.lineLimit {
                return .failure(.lineTooBig)
            }
            guard let line = GameLine.page(message["line"], folder: folder) else { return .failure(.badLine) }
            return .success(.line(key: key, line: line))
        case "lines" where Set(message.keys) == ["v", "ask", "key", "from"]:
            guard let from = count(message["from"]) else { return .failure(.unknown) }
            return .success(.lines(key: key, from: from))
        default:
            return .failure(.unknown)
        }
    }

    /// The number 1 and nothing else: JavaScript's `true` arrives as an NSNumber that reads as 1 too.
    private static func isOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == Double(version)
    }

    /// A save's count: a whole number from 0 to `countMost`, never `true` or a fraction.
    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double >= 0, double <= Double(countMost), double.rounded() == double else { return nil }
        return Int(double)
    }

    /// The answer the page gets: `{ok: true}` for a kept save or a usual player set, `{ok: true, save: text or null,
    /// n: its count or null}` for a save asked for, `{ok: true, players: [{id, name, color}], usual: id or null}` for
    /// the players (those not retired; `usual` only when it is one of them), `{ok: false, why: words}` for a refusal.
    /// Stage 3: `{ok: true}` for a line kept (`again: true` when it was kept before), `{ok: true, lines: the JSON
    /// array's text, next: where the next page starts or null, total, most, skipped, players}` for the lines, with
    /// every player on the list, retired ones too (`retired`), so a board can name the numbers in old lines.
    public static func reply(_ result: Result<Ask, Refusal>, saves: [String: GameSaves.Kept], players: [Player] = [],
                             usual: Int? = nil, again: Bool = false, lines: GameLines? = nil) -> [String: Any] {
        switch result {
        case .success(.keep), .success(.usual): return ["ok": true]
        case .success(.line): return again ? ["ok": true, "again": true] : ["ok": true]
        case .success(.lines(_, let from)):
            let page = lines?.page(from: from) ?? (text: "[]", next: nil)
            return ["ok": true, "lines": page.text, "next": page.next.map { $0 as Any } ?? NSNull(),
                    "total": lines?.texts.count ?? 0, "most": GameLines.most, "skipped": lines?.skipped ?? 0,
                    "players": players.map { ["id": $0.id, "name": $0.name, "color": $0.color.rawValue, "retired": $0.retired] }]
        case .success(.players):
            let shown = players.filter { !$0.retired }
            return ["ok": true, "players": shown.map { ["id": $0.id, "name": $0.name, "color": $0.color.rawValue] },
                    "usual": shown.contains { $0.id == usual } ? usual as Any : NSNull()]
        case .success(.give(let key)):
            return ["ok": true, "save": saves[key].map { $0.save as Any } ?? NSNull(),
                    "n": saves[key].map { $0.n as Any } ?? NSNull()]
        case .failure(let why): return ["ok": false, "why": why.rawValue]
        }
    }

    /// Run at each main-frame page's start, inside `world`: on a page in one of our folders (the rule of `folder`) it
    /// puts the game's save key on `<html>` as `data-pm-games` and the app's copy of the save, if it holds one, as
    /// `data-pm-save`, with its count as `data-pm-n` (kit.js reads them before the game's own scripts and removes
    /// them), then carries the page's
    /// asks (a `pm-game-ask` event, its detail the ask as JSON text) to the app and the answers back (`pm-game-answer`,
    /// the same `id`). Any other page is left as built, and its asks go nowhere.
    public static func pageScript(gamesID: UUID?, ours: [String], saves: [String: GameSaves.Kept]) -> String {
        let held = saves.filter { key, _ in ours.contains { Self.key(of: $0) == key } }
            .mapValues { ["save": $0.save, "n": $0.n] as [String: Any] }
        let json = { (value: Any) -> String in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
        return """
            (function () {
              var host = "\(gamesID?.uuidString.lowercased() ?? "")", ours = \(json(ours)), saves = \(json(held));
              if (!host || location.protocol !== "zim:" || location.host.toLowerCase() !== host) return;
              var parts;
              try { parts = decodeURIComponent(location.pathname).replace(/^\\/+/, "").split("/"); } catch (e) { return; }
              if (parts.length < 2 || parts.indexOf(".") >= 0 || parts.indexOf("..") >= 0 || ours.indexOf(parts[0]) < 0) return;
              var key = "pm-" + parts[0], root = document.documentElement;
              root.setAttribute("data-pm-games", key);
              if (Object.prototype.hasOwnProperty.call(saves, key)) {
                root.setAttribute("data-pm-save", saves[key].save);
                root.setAttribute("data-pm-n", String(saves[key].n));
              }
              function answer(id, said) {
                said = said && typeof said === "object" ? said : { ok: false, why: "no answer" };
                said.id = id;
                document.dispatchEvent(new CustomEvent("pm-game-answer", { detail: JSON.stringify(said) }));
              }
              document.addEventListener("pm-game-ask", function (event) {
                var ask;
                try { ask = JSON.parse(event.detail); } catch (e) { return; }
                if (!ask || typeof ask !== "object" || Array.isArray(ask)) return;
                var id = ask.id;
                delete ask.id;
                window.webkit.messageHandlers.\(handler).postMessage(ask)
                  .then(function (said) { answer(id, said); }, function () { answer(id, null); });
              });
            })();
            """
    }
}

/// The app's own store of our games' saves, one file in the app's own folder on each device (Application Support ›
/// PrepareMe in the app's container; never the service's folder, never iCloud, kept out of the device's backup, sent
/// nowhere), saved whole (DurableFile). It also keeps the games file's ID and its list of our own games as last read,
/// so the bridge is there from a launch's first page, before the games file has been opened and read again: a game
/// page that met no bridge would fall back to the page's storage, where the save may be an older one.
public struct GameSaves: Codable, Equatable, Sendable {
    public static let fileName = "game-saves.json"

    /// 2 since stage 1b (each save with its count); a version 1 file (stage 1, never shipped) is read with count 0.
    /// A later build adds fields (stage 2's players, stage 3's lines) and keeps reading these.
    public static let current = 2
    public var version = current
    /// The games file the list was read from.
    public var gamesID: String?
    /// Our own games' keys, from that file's `kit/ours.json`.
    public var ours: [String] = []
    /// Each game's whole save, by its key (`pm-<folder>`).
    public var saves: [String: Kept] = [:]
    /// Stage 2: this device's usual player's number (PlayerList), set by a game's first pick on the device. Read by
    /// a version 2 file's older reader too, which leaves it out.
    public var usual: Int?
    /// A file that read but made no sense was renamed to this (in the same folder), and the store started empty.
    public private(set) var setAside: String?
    /// The file couldn't be read now (still locked after a restart, say), or couldn't be renamed: this store never
    /// writes, so nothing overwrites it.
    public private(set) var blocked = false

    /// A save as the page's JSON text, and its count: the kit adds one each time it saves, and the higher count wins
    /// wherever it is (here, in the page's storage).
    public struct Kept: Codable, Equatable, Sendable {
        public var n: Int
        public var save: String
        public init(n: Int, save: String) {
            self.n = n
            self.save = save
        }
    }

    enum CodingKeys: String, CodingKey { case version, gamesID, ours, saves, usual }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard (1...Self.current).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "a later build's file")
        }
        gamesID = try c.decodeIfPresent(String.self, forKey: .gamesID)
        ours = try c.decodeIfPresent([String].self, forKey: .ours) ?? []
        if version == 1 {
            saves = (try c.decodeIfPresent([String: String].self, forKey: .saves) ?? [:]).mapValues { Kept(n: 0, save: $0) }
        } else {
            saves = try c.decodeIfPresent([String: Kept].self, forKey: .saves) ?? [:]
        }
        usual = try c.decodeIfPresent(Int.self, forKey: .usual)
        version = Self.current
    }

    public var games: UUID? { gamesID.flatMap(UUID.init(uuidString:)) }

    /// The store in `folder`: an empty one when there is no file. A file that reads but makes no sense (damaged, or a
    /// later build's) is never overwritten: it is renamed aside with the date (`setAside`) and the store starts empty,
    /// so the page's own copies, which carry their counts, win back each game; if even the rename fails, or the file
    /// can't be read at all now, the store is `blocked` and never writes.
    public static func load(_ folder: URL, now: Date = Date()) -> GameSaves {
        let url = folder.appendingPathComponent(fileName)
        var store = GameSaves()
        switch read(url, as: GameSaves.self) {
        case .none: break
        case .found(let found):
            LibraryStore.excludeFromBackup(url, false)  // in the device's backup since D1 (owner, 2026-11-22)
            return found
        case .unreadable:
            store.blocked = true  // a file that isn't readable yet isn't damaged: never set aside (audit D3)
        case .damaged:
            store.setAside = setAside(url, stem: "game-saves", now: now)
            store.blocked = store.setAside == nil
        }
        return store
    }

    /// What a kept file held: none, a value, a file that couldn't be read now (locked before the first unlock, an
    /// I/O error: left alone), or one that read but made no sense (set aside). Pins read theirs the same way.
    enum Read<T> { case none, found(T), unreadable, damaged }

    static func read<T: Decodable>(_ url: URL, as type: T.Type, decoder: JSONDecoder = JSONDecoder()) -> Read<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return (try? decoder.decode(type, from: data)).map { .found($0) } ?? .damaged
    }

    /// An unreadable file renamed `<stem>-unreadable-<date and time>.json` beside it (`-1`, `-2` if taken): the new
    /// name, or nil when it couldn't be renamed. The player list sets its own aside the same way.
    static func setAside(_ url: URL, stem: String, ext: String = "json", now: Date) -> String? {
        let stamp = ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withFullDate, .withTime])
        for n in 0..<100 {
            let name = "\(stem)-unreadable-\(stamp)\(n == 0 ? "" : "-\(n)").\(ext)"
            let aside = url.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: aside.path) { continue }
            return (try? FileManager.default.moveItem(at: url, to: aside)) != nil ? name : nil
        }
        return nil
    }

    /// Saved whole, in the device's backup (D1; owner, 2026-11-22, by click). The player list and the lines stay out.
    public func save(_ folder: URL) throws {
        if blocked { throw CocoaError(.fileWriteNoPermission) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DurableFile.write(try encoder.encode(self), to: folder.appendingPathComponent(Self.fileName))
    }

    /// A message from a page: checked (`GameBridge.check`), a kept save taken in, and the answer. A save is taken only
    /// over an older one (a lower count); the same save again is answered yes and changes nothing; any other save at
    /// or under the count held is refused as older, so a page behind another page of the same game never rolls it
    /// back. `changed`: the store now differs, to be saved (and the page script laid again once the saves stop).
    /// `players`: the device's player list, read only for an ask about players; a usual player must be one not retired.
    /// `lines`: the device's lines (stage 3), read only for an ask about lines; none (an older app's test stand-in) answers
    /// those asks as unknown. A line's players must be on the list (retired ones too: a game begun before the Mac retired
    /// them still ends), and no computer opponent may carry a player's nickname. A line is written by `lines` itself.
    public mutating func answer(_ body: Any, from frame: GameBridge.Frame,
                                players: @autoclosure () -> PlayerList = PlayerList(),
                                lines: @autoclosure () -> GameLines? = nil)
        -> (reply: [String: Any], changed: Bool, refused: GameBridge.Refusal?) {
        var result = GameBridge.check(body, from: frame, gamesID: games, ours: ours)
        var changed = false
        var list: [Player] = []
        var again = false, kept: GameLines?
        switch result {
        case .success(.players): list = players().players
        case .success(.usual(_, let id)):
            if players().active.contains(where: { $0.id == id }) {
                changed = usual != id
                usual = id
            } else {
                result = .failure(.noPlayer)
            }
        case .success(.line(_, let line)):
            guard let store = lines() else { result = .failure(.unknown); break }
            let known = players().players
            for seat in line.seats {
                switch seat {
                case .player(let id) where !known.contains(where: { $0.id == id }): result = .failure(.noPlayer)
                case .computer(let name) where known.contains(where: {
                    $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }):
                    result = .failure(.badLine)
                default: break
                }
            }
            guard case .success = result else { break }
            do { again = try !store.keep(line) } catch GameLines.Problem.full { result = .failure(.full) } catch {
                result = .failure(.notSaved)
            }
        case .success(.lines):
            guard let store = lines() else { result = .failure(.unknown); break }
            kept = store
            list = players().players
        default: break
        }
        if case .success(.keep(let key, let save, let n)) = result {
            if let held = saves[key], n <= held.n {
                if n != held.n || save != held.save { result = .failure(.older) }
            } else {
                saves[key] = Kept(n: n, save: save)
                changed = true
            }
        }
        if case .failure(let why) = result { return (GameBridge.reply(result, saves: saves), false, why) }
        return (GameBridge.reply(result, saves: saves, players: list, usual: usual, again: again, lines: kept), changed, nil)
    }

    /// The games file's list, read again: whether anything changed.
    public mutating func read(gamesID: UUID, ours: [String]) -> Bool {
        let before = self
        self.gamesID = gamesID.uuidString
        self.ours = ours
        return self != before
    }
}
