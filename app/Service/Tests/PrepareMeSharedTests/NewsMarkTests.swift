import Foundation
import Testing
@testable import PrepareMeShared

/// The owner's News marks (news plan Task 3.4): the page's links read back, and the request file news/marks.py takes.
struct NewsMarkTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("news-mark-\(UUID().uuidString)")
    }

    @Test func theThreeKindsAreRead() {
        #expect(NewsMark.parse(url("prepareme://news/wrong?story=g101")) == NewsMark(kind: .wrong, story: "g101"))
        #expect(NewsMark.parse(url("prepareme://news/down?story=i0123456789abcdef"))
                == NewsMark(kind: .down, story: "i0123456789abcdef"))
        #expect(NewsMark.parse(url("prepareme://news/missed")) == NewsMark(kind: .missed, story: nil))
    }

    @Test(arguments: ["prepareme://news/delete?story=g101", "prepareme://news/wrong", "prepareme://news/down?story=",
                      "prepareme://news/down?story=g1x", "prepareme://news/down?story=G101",
                      "prepareme://news/down?story=i0123", "prepareme://news/down?story=g1234567890123",
                      "prepareme://news/down?story=g1&story=g2", "prepareme://news/wrong?story=g1&x=1",
                      "prepareme://news/missed?text=hello", "prepareme://home/wrong?story=g101",
                      "https://news/wrong?story=g101", "prepareme://news/wrong/extra?story=g101",
                      "prepareme://user@news/wrong?story=g101", "prepareme://news:80/wrong?story=g101",
                      "prepareme://news/down?story=g1%0A", "prepareme://news/opened"])
    func anythingElseIsRefused(_ text: String) {
        #expect(NewsMark.parse(url(text)) == nil, "\(text)")
    }

    @Test func aStoryOfAnotherShapeMakesNoMark() {
        #expect(NewsMark(kind: .down, story: "../../x") == nil)
        #expect(NewsMark(kind: .wrong, story: nil) == nil)
    }

    @Test func aStoryIsTheWholeTextNeverOneBeforeAFinalNewline() {
        #expect(NewsMark.isStory("g1"))
        for text in ["g1\n", "g1\r\n", "\ng1", "g1 ", "g1\ng2"] { #expect(!NewsMark.isStory(text), "\(text.debugDescription)") }
    }

    @Test func theTextIsCountedAsNewsCountsIt() {
        let thumb = "\u{1F44D}\u{1F3FD}"  // one character, two code points: news/marks.py counts two
        #expect(NewsMark.cleaned(String(repeating: thumb, count: NewsMark.textMax / 2)) != nil)
        #expect(NewsMark.cleaned(String(repeating: thumb, count: NewsMark.textMax / 2 + 1)) == nil)
    }

    /// news/marks.py's FILE_MAX (4096 bytes) holds the longest request: a control character is written as \\u0001,
    /// six bytes, the most any one code point takes (the second review's finding 8)
    @Test func theLongestRequestFitsNewsSizeLimit() throws {
        let marks = try String(contentsOf: MapWordsTests.repo.appendingPathComponent("news/marks.py"), encoding: .utf8)
        #expect(marks.contains("FILE_MAX = 4096"))
        let mark = try #require(NewsMark(kind: .missed, story: nil))
        for worst in ["\u{1}", "/", "\"", "\u{1F600}"] {
            let data = try #require(mark.request(text: String(repeating: worst, count: NewsMark.textMax)))
            #expect(data.count <= 4096, "\(worst.debugDescription): \(data.count)")
        }
    }

    @Test func aStoppedSavesLeftoverOfAnEarlierMarkIsSwept() throws {
        let requests = scratch()
        defer { try? FileManager.default.removeItem(at: requests) }
        let folder = requests.appendingPathComponent(NewsMark.folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent(".1-wrong-A.json.tmp-B"), fresh = folder.appendingPathComponent(".2-down-C.json.tmp-D")
        let other = folder.appendingPathComponent(".hidden-file")
        for file in [old, fresh, other] { try Data("{}".utf8).write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: other.path)
        let mark = try #require(NewsMark(kind: .wrong, story: "g1"))
        let written = try mark.write(in: requests)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == [fresh.lastPathComponent, other.lastPathComponent, written.lastPathComponent],
                "the old leftover gone; one still being written, and any other file, kept")
    }

    @Test func theShapeMatchesNewsAndThePage() throws {
        let marks = try String(contentsOf: MapWordsTests.repo.appendingPathComponent("news/marks.py"), encoding: .utf8)
        let board = try String(contentsOf: MapWordsTests.repo.appendingPathComponent("dashboard/news_board.py"),
                               encoding: .utf8)
        #expect(marks.contains("STORY_SHAPE = re.compile(r\"\(NewsMark.storyShape)\")"))
        #expect(board.contains("STORY_ID_SHAPE = r\"\(NewsMark.storyShape)\""))
        #expect(marks.contains("TEXT_MAX = \(NewsMark.textMax)"))
        #expect(marks.contains("FOLDER = jobs.REQUESTS_DIR / \"\(NewsMark.folderName)\""))
    }

    @Test func theRequestFileIsWrittenWholeInTheRequestsFolder() throws {
        let requests = scratch()
        defer { try? FileManager.default.removeItem(at: requests) }
        let mark = try #require(NewsMark(kind: .down, story: "g101"))
        let written = try mark.write(in: requests, now: Date(timeIntervalSince1970: 1_800_000_000))
        let folder = written.deletingLastPathComponent()
        #expect(folder.lastPathComponent == "news-marks")
        #expect(folder.deletingLastPathComponent().standardizedFileURL == requests.standardizedFileURL)
        #expect(written.lastPathComponent.hasPrefix("1800000000000-down-"))
        #expect(written.pathExtension == "json")
        let body = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? [String: Any])
        #expect(body as NSDictionary == ["format": 1, "kind": "down", "story": "g101"] as NSDictionary)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [written.lastPathComponent],
                "no temporary copy left beside it")
        let mode = try FileManager.default.attributesOfItem(atPath: written.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func shouldHaveBeenHereCarriesItsTextFolded() throws {
        let requests = scratch()
        defer { try? FileManager.default.removeItem(at: requests) }
        let mark = try #require(NewsMark.parse(url("prepareme://news/missed")))
        let written = try mark.write(in: requests, text: "  Port strike\nends   on the Gulf Coast ")
        let body = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? [String: Any])
        #expect(body as NSDictionary
                == ["format": 1, "kind": "missed", "text": "Port strike ends on the Gulf Coast"] as NSDictionary)
        #expect(mark.request(text: "   ") == nil)
        #expect(mark.request(text: String(repeating: "x", count: NewsMark.textMax + 1)) == nil)
        #expect(mark.request(text: String(repeating: "x", count: NewsMark.textMax)) != nil)
        #expect(throws: (any Error).self) { try mark.write(in: requests, text: "") }
    }

    @Test func theDayOpenedIsNewYorksDay() throws {
        let requests = scratch()
        defer { try? FileManager.default.removeItem(at: requests) }
        let mark = try #require(NewsMark(kind: .opened, story: "g101"))
        #expect(mark.story == nil)
        let late = Date(timeIntervalSince1970: 1_795_060_800)  // Thu Nov 19 2026, 4:00 AM UTC: 11 PM Nov 18 in New York
        let written = try mark.write(in: requests, now: late)
        let body = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? [String: Any])
        #expect(body as NSDictionary == ["format": 1, "kind": "opened", "day": "2026-11-18"] as NSDictionary)
        #expect(NewsMark.day(late.addingTimeInterval(3600)) == "2026-11-19")
        let marks = try String(contentsOf: MapWordsTests.repo.appendingPathComponent("news/marks.py"), encoding: .utf8)
        #expect(marks.contains(#"DAY_SHAPE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")"#))
    }

    @Test func theAnswersAreReadFromNewsOwnFile() throws {
        let page: [String: Any] = ["format": 1, "marks": [
            ["kind": "missed", "text": "A made-up story", "at": "2026-11-18T12:00:00+00:00", "answer": "News found nothing."],
            ["kind": "aside", "text": "a mark", "at": "2026-11-18T11:00:00+00:00", "answer": "Nothing changed."],
            ["kind": "delete", "text": "x", "answer": "y"], ["kind": "wrong", "text": "", "answer": "Kept."],
            ["kind": "down", "text": "A made-up headline", "answer": ""]]]
        let rows = NewsAnswers.rows(try JSONSerialization.data(withJSONObject: page))
        #expect(rows.map(\.0) == ["Should have been here: “A made-up story”", "A mark News couldn't read"])
        #expect(rows.map(\.1) == ["News found nothing.", "Nothing changed."])
        #expect(NewsAnswers.rows(nil).isEmpty)
        #expect(NewsAnswers.rows(Data("{not json".utf8)).isEmpty)
        #expect(NewsAnswers.rows(Data("{\"marks\": 3}".utf8)).isEmpty)
    }

    @Test func theAnswersGoInAsTextNeverMarkup() {
        let script = NewsAnswers.script([("Should have been here: “</script><b>x\")", "a\nb")])
        #expect(script.contains("textContent = r[0]"))
        #expect(!script.contains("innerHTML"))
        #expect(script.contains(#"“<\/script><b>x\")"#), "JSON's escaped slash and quote: one string, never markup")
    }

    @Test func everyKindNewsWritesHasALine() throws {
        let marks = try String(contentsOf: MapWordsTests.repo.appendingPathComponent("news/marks.py"), encoding: .utf8)
        #expect(marks.contains(#"KINDS = ("wrong", "down", "missed", "opened")"#))
        #expect(marks.contains(#"kind != 'opened'"#), "a day opened is never shown as a mark")
        #expect(marks.contains(#""aside", "", AS_SENT"#))
        #expect(Set(NewsAnswers.heads.keys) == ["wrong", "down", "missed", "aside"])
        let run = try String(contentsOf: MapWordsTests.repo.appendingPathComponent("news/run.py"), encoding: .utf8)
        #expect(run.contains("NEWS_DIR = APP_SUPPORT / \"\(NewsAnswers.folderName)\""))
        #expect(run.contains("PAGE_NAME = \"\(NewsAnswers.fileName)\""))
        #expect(marks.contains("SHOWN_DAYS, SHOWN_MAX = 7, \(NewsAnswers.shownMax)"))
    }
}
