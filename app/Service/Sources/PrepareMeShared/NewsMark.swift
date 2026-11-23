import Foundation

/// The owner's three marks on the News page (news plan Task 3.4; docs/news.md, "The marks"), the Mac app's alone: the
/// page's links `prepareme://news/wrong?story=ID` (Doesn't Belong), `prepareme://news/down?story=ID` (Take Down…) and
/// `prepareme://news/missed` (Should Have Been Here…), written by dashboard/news_board.py. Each mark becomes one request
/// file in the requests folder's `news-marks`, which the news job's next run reads once and removes (news/marks.py).
/// The link is refused unless it is one of the three kinds, and a story's id has the record's shape. A fourth kind,
/// opened, is no link: the app writes it the first time each day the News page loads, so the two-week trial counts only
/// the days the owner looked (the owner's word, 2026-11-18, by click).
public struct NewsMark: Equatable, Sendable {
    public enum Kind: String, Sendable { case wrong, down, missed, opened }

    public let kind: Kind
    /// The story's id (wrong and down); nil for missed and opened
    public let story: String?

    public static let host = "news"
    public static let folderName = "news-marks"  // news/marks.py's FOLDER, in the requests folder
    public static let format = 1
    /// A link or a headline (news/marks.py's TEXT_MAX)
    public static let textMax = 500
    /// news.sort's ids: a group's, or an item's (news/marks.py's STORY_SHAPE, dashboard/news_board.py's STORY_ID_SHAPE)
    static let storyShape = "g[0-9]{1,12}|i[0-9a-f]{16}"

    public init?(kind: Kind, story: String?) {
        switch kind {
        case .missed, .opened:
            self.story = nil
        case .wrong, .down:
            guard let story, Self.isStory(story) else { return nil }
            self.story = story
        }
        self.kind = kind
    }

    /// The mark a page's link asks for, or nil for any other link.
    public static func parse(_ url: URL) -> NewsMark? {
        guard url.scheme == "prepareme", url.host == host, url.user == nil, url.port == nil,
              let kind = Kind(rawValue: String(url.path.dropFirst())), kind != .opened else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let stories = items.filter { $0.name == "story" }.compactMap(\.value)
        if kind == .missed { return items.isEmpty ? NewsMark(kind: .missed, story: nil) : nil }
        guard items.count == 1, stories.count == 1 else { return nil }
        return NewsMark(kind: kind, story: stories[0])
    }

    /// The whole text, never a match before a final newline ("$" allows one: the second review's finding 5).
    public static func isStory(_ text: String) -> Bool {
        text.range(of: "\\A(?:\(storyShape))\\z", options: .regularExpression) != nil
    }

    /// `text` as a Should Have Been Here request takes it: its spaces folded, nil when empty or over `textMax`,
    /// counted as news/marks.py counts (Unicode code points, not characters: the second review's finding 8).
    public static func cleaned(_ text: String) -> String? {
        let folded = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.isEmpty || folded.unicodeScalars.count > textMax ? nil : folded
    }

    /// The request file's content: {"format": 1, "kind": …, "story": …}; for missed, {"format": 1, "kind":
    /// "missed", "text": …}; for opened, {"format": 1, "kind": "opened", "day": "2026-11-18"} (`now`'s New York day,
    /// news/marks.py's DAY_SHAPE); nil for a missed mark without a usable text.
    public func request(text: String? = nil, now: Date = Date()) -> Data? {
        var body: [String: Any] = ["format": Self.format, "kind": kind.rawValue]
        if kind == .opened {
            body["day"] = Self.day(now)
        } else if kind == .missed {
            guard let text, let cleaned = Self.cleaned(text) else { return nil }
            body["text"] = cleaned
        } else {
            body["story"] = story
        }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Writes the request whole (DurableFile) in `requests`/news-marks (made 0700), named so the oldest sorts first,
    /// and gives its address.
    @discardableResult
    public func write(in requests: URL, text: String? = nil, now: Date = Date()) throws -> URL {
        guard let data = request(text: text, now: now) else { throw POSIXError(.EINVAL) }
        let folder = requests.appendingPathComponent(Self.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        Self.sweep(folder, now: now)
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        let url = folder.appendingPathComponent("\(stamp)-\(kind.rawValue)-\(UUID().uuidString).json")
        try DurableFile.write(data, to: url)
        return url
    }

    /// `now`'s day in New York, the day News's record keeps (news/marks.py's NEW_YORK), as "2026-11-18".
    public static func day(_ now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let part = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", part.year ?? 0, part.month ?? 0, part.day ?? 0)
    }

    /// Every mark has a name of its own, so DurableFile's own sweep (a file's own leftovers) never meets a stopped
    /// save's copy of an earlier mark: each is swept here by its name, at DurableFile's age (the second review's
    /// finding 12).
    static func sweep(_ folder: URL, now: Date = Date()) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(".") {
            guard let cut = name.range(of: ".tmp-") else { continue }
            DurableFile.sweep(for: folder.appendingPathComponent(String(name[name.index(after: name.startIndex)..<cut.lowerBound])),
                              now: now)
        }
    }
}

/// The owner's marks and News's answers as the Mac app shows them at the News page's end (the owner's word on the
/// second review's finding 7, 2026-11-18, by click): read straight from News's own page.json on the Mac, never from
/// the library, so a mark sends nothing to the phones and what the owner typed never leaves the Mac. page.json's
/// `marks` is already News's last 7 days, newest first, at most 10 (news/marks.py's page_marks).
public enum NewsAnswers {
    /// page.json's place: Application Support › PrepareMe › news (news/run.py's NEWS_DIR and PAGE_NAME)
    public static let folderName = "news"
    public static let fileName = "page.json"
    /// Each kind's line, the mark's text in curly quotes where `%@` is (news/marks.py's KINDS, and "aside" for a
    /// request it set aside)
    public static let heads = ["missed": "Should have been here: “%@”", "wrong": "Doesn't belong: “%@”",
                               "down": "Taken down: “%@”", "aside": "A mark News couldn't read"]
    static let shownMax = 10

    /// (line, answer) for each mark of a known kind with an answer, from page.json's bytes; none for anything else.
    public static func rows(_ data: Data?) -> [(String, String)] {
        guard let data, let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let marks = page["marks"] as? [[String: Any]] else { return [] }
        return marks.prefix(shownMax).compactMap { mark in
            guard let kind = mark["kind"] as? String, let head = heads[kind],
                  let answer = mark["answer"] as? String, !answer.isEmpty else { return nil }
            let text = (mark["text"] as? String) ?? ""
            if head.contains("%@") && text.isEmpty { return nil }
            return (head.replacingOccurrences(of: "%@", with: text), answer)
        }
    }

    /// The page script that writes `rows` into the page's `.nb-answers` as text (never markup), shown only when there
    /// are any; the rows go in as JSON, so nothing in them is read as script.
    public static func script(_ rows: [(String, String)]) -> String {
        let pairs = rows.map { [$0.0, $0.1] }
        let json = (try? JSONSerialization.data(withJSONObject: pairs)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "(function (rows) { var box = document.querySelector('#news-board .nb-answers'); if (!box) return;"
            + " box.textContent = ''; rows.forEach(function (r) { var p = document.createElement('p'),"
            + " b = document.createElement('b'); b.textContent = r[0]; p.appendChild(b);"
            + " p.appendChild(document.createElement('br')); p.appendChild(document.createTextNode(r[1]));"
            + " box.appendChild(p); }); box.hidden = rows.length === 0; })(\(json));"
    }
}
