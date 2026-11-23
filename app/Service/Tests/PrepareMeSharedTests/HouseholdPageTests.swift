import Foundation
import PrepareMeShared
import Testing
import XCTest

/// Household pages (phase C): the Mac writes the page's file byte for byte as packer/steps.py reads it (the shared
/// fixture household-page.md, which the packer's tests parse), reads it back, and refuses any other shape.
final class HouseholdPageTests: XCTestCase {
    static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/household-page.md")

    static let sample = HouseholdPage(
        title: "SAMPLE Shut-offs", when: "SAMPLE a gas smell or a burst pipe.",
        guides: ["utility-shutoff", "generator-co"], keywords: ["sample shut off", "sample water main"],
        steps: [
            .init(words: "SAMPLE turn the valve a quarter turn.", name: "SAMPLE water main",
                  photo: "sample-shutoffs-1.jpg", caution: "SAMPLE don't force a stuck valve."),
            .init(words: "SAMPLE push the main breaker to Off."),
            .init(words: "SAMPLE watch the made-up video.", photo: "sample-shutoffs-3.jpg",
                  video: "sample-shutoffs-3.mp4"),
        ])

    func testWritesTheSharedFixtureByteForByte() throws {
        XCTAssertEqual(Self.sample.markdown, try String(contentsOf: Self.fixtureURL, encoding: .utf8))
    }

    func testReadsItBack() throws {
        let text = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        XCTAssertTrue(HouseholdPage.isSteps(text))
        XCTAssertEqual(try HouseholdPage(markdown: text), Self.sample)
    }

    func testEveryValueIsOneLine() throws {
        var page = Self.sample
        page.title = "SAMPLE two\nlines  and\tspaces "
        page.steps[1].caution = "SAMPLE\n\na caution"
        let text = page.markdown
        XCTAssertTrue(text.contains("title: SAMPLE two lines and spaces\n"))
        XCTAssertTrue(text.contains("  caution: SAMPLE a caution\n"))
        XCTAssertEqual(try HouseholdPage(markdown: text).steps[1].caution, "SAMPLE a caution")
        var bare = HouseholdPage(title: "SAMPLE", steps: [.init(words: "SAMPLE only words")])
        XCTAssertEqual(bare.markdown, "---\ntitle: SAMPLE\nkind: steps\n---\n- step: SAMPLE only words\n")
        bare.keywords = ["  ", "sample"]
        XCTAssertTrue(bare.markdown.contains("keywords: sample\n"))
    }

    func testRefusesAnyOtherShape() {
        let head = "---\ntitle: SAMPLE\nkind: steps\n---\n"
        for text in ["---\ntitle: SAMPLE\n---\nA hand-written page.\n", head, head + "Some prose.\n",
                     head + "- step: x\n    photo: a.jpg\n", head + "- step: x\n  colour: red\n",
                     head + "- step: x\n  photo: a.jpg\n  photo: b.jpg\n", "---\ntitle: A\ntitle: B\nkind: steps\n---\n- step: x\n",
                     "---\ntitle: S\nkind: steps\nwhen: \n---\n- step: x\n", "no header at all\n"] {
            XCTAssertThrowsError(try HouseholdPage(markdown: text), text)
        }
        XCTAssertFalse(HouseholdPage.isSteps("---\ntitle: SAMPLE\n---\nA hand-written page.\n"))
    }

    func testNames() {
        XCTAssertEqual(HouseholdPage.starterNames, ["shutoffs", "generator", "battery-backup", "evacuation",
                                                    "rally-points", "how-we-reach-each-other", "school-pickup"])
        // a random name, never the title's words: it is the page's path on every phone (the review)
        let name = HouseholdPage.newName(taken: [])
        XCTAssertTrue(name.range(of: "^house-[0-9a-f]{8}$", options: .regularExpression) != nil, name)
        XCTAssertNotEqual(HouseholdPage.newName(taken: []), name)
        let media = HouseholdPage.mediaName(page: "generator", ext: "jpg")
        XCTAssertTrue(media.range(of: "^generator-[0-9a-f]{8}\\.jpg$", options: .regularExpression) != nil, media)
    }

    /// What the packer would refuse is refused before Save, so a page the Mac writes never stops the daily build
    /// (the review, 2026-10-19; the same cases packer/tests/test_steps.py refuses).
    func testTheMacRefusesWhatThePackerWould() {
        var page = Self.sample
        XCTAssertNil(page.problem)
        page.keywords = (0..<13).map { "w\($0)" }
        XCTAssertEqual(page.problem, "At most 12 search words.")
        page.keywords = [String(repeating: "x", count: 61)]
        XCTAssertEqual(page.problem, "A search word can be at most 60 characters.")
        page.keywords = ["the \"main\" valve"]
        XCTAssertEqual(page.problem, "A search word can't hold <, > or a double quote.")
        page.keywords = []
        page.steps[1].caution = "SAMPLE NoIndex"
        XCTAssertEqual(page.problem, "The word noindex would hide the page from search; reword it.")
        page.steps[1].caution = ""
        page.steps[2].words = " \n "
        XCTAssertEqual(page.problem, "Step 3 needs its words.")
        XCTAssertEqual(HouseholdPage(title: " ", steps: [.init(words: "x")]).problem, "The page needs a title.")
        // a file separator Python breaks a line at becomes a space, so the page still reads (the review)
        var pasted = Self.sample
        pasted.steps[0].words = "SAMPLE one\u{1C}two\u{2029}three"
        XCTAssertTrue(pasted.markdown.contains("- step: SAMPLE one two three\n"))
    }

    /// A photo's or video's name is read only in the packer's two forms (packer/steps.py's _PHOTO and _VIDEO, which
    /// packer/tests/test_steps.py compares with these), so a hand-edited path is never moved by Delete and a name the
    /// packer refuses never lists as fine (phase K finding 3). The refusal names the line, never its text.
    func testPhotoAndVideoNamesAreThePackersOnly() throws {
        let head = "---\ntitle: SAMPLE\nkind: steps\n---\n- step: x\n"
        for (part, why) in [("photo: ../media/sample.mp4", "photo isn't a photo's file name"),
                            ("photo: sample.mp4", "photo isn't a photo's file name"),
                            ("photo: Sample.JPG", "photo isn't a photo's file name"),
                            ("photo: sub/sample.jpg", "photo isn't a photo's file name"),
                            ("photo: .jpg", "photo isn't a photo's file name"),
                            ("photo: sample.jpg.jpg", "photo isn't a photo's file name"),
                            ("video: ../daily/sample.mp4", "video isn't a video's file name"),
                            ("video: sample.mov", "video isn't a video's file name"),
                            ("video: ..", "video isn't a video's file name")] {
            XCTAssertThrowsError(try HouseholdPage(markdown: head + "  \(part)\n"), part) {
                XCTAssertEqual($0 as? HouseholdPage.Problem, .notThisForm("Line 6: \(why)."), part)
            }
        }
        for photo in ["sample-1.jpg", "sample.jpeg", "sample.png", "house-0a1b2c3d-9f8e7d6c.jpg"] {
            XCTAssertEqual(try HouseholdPage(markdown: head + "  photo: \(photo)\n  video: sample-2.mp4\n")
                .steps[0].photo, photo)
        }
        XCTAssertEqual(HouseholdPage.photoPattern, "[a-z0-9-]+\\.(jpg|jpeg|png)")
        XCTAssertEqual(HouseholdPage.videoPattern, "[a-z0-9-]+\\.mp4")
    }

    func testStarterPagesRoundTripAndLeanOnTheirGuides() throws {
        for name in HouseholdPage.starterNames {
            let page = try XCTUnwrap(HouseholdPage.starter(name), name)
            XCTAssertEqual(try HouseholdPage(markdown: page.markdown), page, name)
            XCTAssertFalse(page.guides.isEmpty, name)
            XCTAssertGreaterThanOrEqual(page.steps.count, 4, name)
        }
        XCTAssertEqual(HouseholdPage.starter("shutoffs")?.title, "Utility shut-offs")
        XCTAssertEqual(HouseholdPage.starter("generator")?.guides.prefix(2), ["generator-co", "generator-house-connection"])
        XCTAssertEqual(HouseholdPage.starter("rally-points")?.title, "Where we meet")
        XCTAssertNil(HouseholdPage.starter("house-anything"))
    }

    func testTheGuideList() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/guide-list.json")
        let list = try GuideList(try Data(contentsOf: url))
        XCTAssertEqual(GuideList.path, "household/guide-list.json")
        XCTAssertEqual(list.guides.map(\.page), ["generator-co.html", "utility-shutoff.html"])
        XCTAssertEqual(list.guides[0].id, "generator-co")
        XCTAssertThrowsError(try GuideList(Data(#"{"format":1,"guides":[{"page":"a.pdf","title":"T"}]}"#.utf8)))
    }

    /// The editor plan, Task 3: the topics come from their own file beside the list (the shared fixture
    /// guide-list-topics.json, which packer/tests/test_guide_list.py writes too); without it, every topic empty.
    func testGuideListTakesTopicsFromTheirOwnFile() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let list = try GuideList(try Data(contentsOf: dir.appendingPathComponent("guide-list.json")))
        XCTAssertEqual(list.guides.map(\.topic), ["", ""])
        let topics = try Data(contentsOf: dir.appendingPathComponent("guide-list-topics.json"))
        XCTAssertEqual(list.withTopics(topics).guides.map(\.topic), ["SAMPLE Power", "SAMPLE Water and Shelter"])
        let one = try GuideList(Data(#"{"format":1,"guides":[{"page":"a.html","title":"SAMPLE A"}]}"#.utf8))
        XCTAssertEqual(one.withTopics(topics).guides.map(\.topic), ["Other"], "a guide the file doesn't name")
        for bad in [#"{"format":2,"topics":[]}"#, #"{"format":1,"topics":[{"page":"a.html","topic":""}]}"#,
                    #"{"format":1,"topics":[{"page":"a.html","topic":"S","more":1}]}"#,
                    #"{"format":1,"topics":[{"page":"a.html","topic":"S"},{"page":"a.html","topic":"T"}]}"#] {
            XCTAssertEqual(one.withTopics(Data(bad.utf8)), one, bad)
        }
    }

    /// The list stays as an app before the editor's fresh look reads it (main's GuideList.init, written out: format 1,
    /// `page` and `title` exactly): the phone's conditions band reads it during an alert.
    func testGuideListKeepsMainsShape() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let top = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("guide-list.json"))) as! [String: Any]
        XCTAssertEqual(Set(top.keys), ["format", "guides"])
        XCTAssertEqual(top["format"] as? Int, 1)
        XCTAssertTrue((top["guides"] as! [[String: Any]]).allSatisfy { Set($0.keys) == ["page", "title"] })
        for text in [#"{"format":2,"guides":[{"page":"a.html","title":"T","topic":"S"}]}"#,
                     #"{"format":1,"guides":[{"page":"a.html","title":"T","topic":"S"}]}"#] {
            XCTAssertThrowsError(try GuideList(Data(text.utf8)), text)
        }
    }
}

/// Our Home plan, Task 2.2: the form's new lines in Swift, the same bytes as packer/steps.py (the second shared
/// fixture our-home-page.md, which packer/tests/test_steps.py parses too).
@Suite struct OurHomeFormTests {
    static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/our-home-page.md")

    static let sample = HouseholdPage(
        title: "SAMPLE Utility shut-offs", when: "SAMPLE you smell gas or [Fill in: what else]{a pipe bursts}.",
        guides: ["utility-shutoff"], sources: "SAMPLE utility's safety page", checked: "2026-11-16",
        walked: "2026-10-04", danger: "SAMPLE if you smell gas, get everyone out first and call from outside.",
        need: ["sample pipe wrench", "sample flashlight"], next: "SAMPLE call a plumber or the gas company.",
        things: [.init(id: 7, words: "SAMPLE wrench"), .init(words: "SAMPLE old towels")],
        steps: [
            .init(words: "SAMPLE do you smell gas near the meter?", name: "SAMPLE smell gas", yes: 2, no: 3,
                  checked: "c276b32d"),
            .init(words: "SAMPLE get everyone out the front door.", name: "SAMPLE get out",
                  danger: "SAMPLE don't use a light switch inside.", map: true, meet: true,
                  call: .init(number: "5555550142", label: "SAMPLE gas emergency line"), checked: "e4f2e76f"),
            .init(words: "SAMPLE turn the handle a quarter turn [Fill in: left or right?], so it lies across the pipe.",
                  name: "SAMPLE water main", caution: "SAMPLE don't force a stuck valve.",
                  wanted: "SAMPLE the valve with its handle across the pipe", guide: "utility-shutoff",
                  items: ["sample pipe wrench"], checked: "a6a7e98f",
                  place: .init(id: 14, words: "SAMPLE Garage › Utility shelf"), manual: .init(id: 7, words: "SAMPLE Generator")),
            .init(words: "SAMPLE at the panel, do each of these.", name: "SAMPLE breaker panel",
                  photo: "sample-shutoffs-4.jpg", calculator: "calc-outage-load",
                  ticks: ["SAMPLE switch the main breaker down", "SAMPLE write the time on the panel door"],
                  checked: "cb1a5d8a", place: .init(words: "SAMPLE Back yard")),
        ])

    @Test func writesAndReadsTheSecondFixtureByteForByte() throws {
        let text = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        #expect(Self.sample.markdown == text)
        let read = try HouseholdPage(markdown: text)
        #expect(read == Self.sample)
        #expect(read.markdown == text)
        #expect(read.problem == nil)
    }

    @Test func theOldFixtureStillRoundTrips() throws {
        let text = try String(contentsOf: HouseholdPageTests.fixtureURL, encoding: .utf8)
        #expect(try HouseholdPage(markdown: text).markdown == text)
    }

    @Test func checkedHashIsThePackers() {
        for step in Self.sample.steps { #expect(HouseholdPage.checkedHash(step.words) == step.checked) }
        let unfilled = "Turn it [Fill in: left or right?] a quarter turn."
        #expect(HouseholdPage.checkedHash(unfilled) == HouseholdPage.checkedHash(
            "Turn it [Fill in: left or right?]{left} a quarter turn."))
        #expect(HouseholdPage.checkedHash(unfilled) != HouseholdPage.checkedHash(
            unfilled.replacingOccurrences(of: "quarter", with: "half")))
    }

    @Test func blanks() {
        let found = HouseholdPage.blanks("a [Fill in: b] c [Fill in: d]{e}")
        #expect(found.map(\.question) == ["b", "d"])
        #expect(found.map(\.answer) == [nil, "e"])
        #expect(Self.sample.blanksLeft == 1)
    }

    @Test func saveTidiesNumbersAndListWordsAsTypedTheUsualWay() {
        // the owner's test page (2026-11-18) wouldn't save: a number and list words typed as anyone would
        var typed = Self.sample
        typed.steps[1].call?.number = "(555) 555-0142"
        typed.steps[2].items = ["Generator", "Gas Can"]
        typed.need = ["Flashlight"]
        #expect(typed.problem != nil)
        let tidied = typed.tidied
        #expect(tidied.problem == nil)
        #expect(tidied.steps[1].call?.number == "5555550142")
        #expect(tidied.steps[2].items == ["generator", "gas can"])
        #expect(tidied.need == ["flashlight"])
        for number in ["+1 555.555.0142", "1-555-555-0142", "555\u{A0}555 0142"] {
            typed.steps[1].call?.number = number
            #expect(typed.tidied.problem == nil, "\(number)")
        }
        typed.steps[1].call?.number = "555-555-O142"  // a letter O stays, for problem to name
        #expect(typed.tidied.problem == "Step 2: a number to call can only hold digits.")
        #expect(Self.sample.tidied == Self.sample)
    }

    @Test func refusesWhatThePackerRefuses() {
        func problem(_ change: (inout HouseholdPage) -> Void) -> String? {
            var page = Self.sample
            change(&page)
            return page.problem
        }
        #expect(problem { $0.steps[0].no = nil } == "Step 1: Yes goes to and No goes to go together.")
        #expect(problem { $0.steps[0].yes = 0 } == "Step 1: choose the step Yes goes to.")  // removed, or not chosen yet
        #expect(problem { $0.steps[0].yes = -1 } == "Step 1: Yes goes to a step that isn't there.")
        #expect(problem { $0.steps[0].no = 5 } == "Step 1: No goes to a step that isn't there.")
        #expect(problem { $0.steps[0].yes = 1 } == "Step 1: Yes can't go to its own step.")
        #expect(problem { $0.steps[2].items = ["ab"] } == "Step 3: \"ab\" isn't a list word (3 or more letters or digits).")
        #expect(problem { $0.steps[2].items = (0..<7).map { "word\($0)" } } == "Step 3: at most 6 list words.")
        #expect(problem { $0.steps[1].call?.number = "55" } == "Step 2: a number to call needs at least 3 digits.")
        #expect(problem { $0.steps[1].call?.number = String(repeating: "5", count: 16) }
                == "Step 2: a number to call can't be longer than 15 digits.")
        #expect(problem { $0.steps[1].call?.number = "555555014x" } == "Step 2: a number to call can only hold digits.")
        #expect(problem { $0.steps[1].call?.label = " " } == "Step 2: a number to call needs its label.")
        #expect(problem { $0.steps[1].checked = "ABCDEF12" } == "Step 2: its checked mark isn't 8 lowercase hex.")
        #expect(problem { $0.sources = "" } == "Checked needs its sources.")
        #expect(problem { $0.walked = "2026-13-01" } == "Last walked through isn't a date.")
        #expect(problem { $0.steps[0].words = "a [Fill in: b{c}]" } == "Step 1: a blank can't hold [, ], { or }.")
        #expect(problem { $0.when = "[Fill in: x]]" } == "Use this when: a blank can't hold [, ], { or }.")
        #expect(problem { $0.need = (0..<9).map { "word\($0)" } } == "What you need: at most 8 list words.")
        #expect(problem { $0.need = ["ok word", "ab"] }
                == "What you need: \"ab\" isn't a list word (3 or more letters or digits).")
        #expect(problem { $0.danger = String(repeating: "x", count: 201) } == "Danger: at most 200 characters.")
        #expect(problem { $0.next = String(repeating: "x", count: 301) } == "What comes next: at most 300 characters.")
        #expect(problem { $0.steps[1].danger = String(repeating: "x", count: 201) }
                == "Step 2: danger at most 200 characters.")
        #expect(problem { $0.steps[2].wanted = String(repeating: "x", count: 121) }
                == "Step 3: photo wanted at most 120 characters.")
        #expect(problem { $0.steps[3].ticks = ["one"] } == "Step 4: a checklist needs 2 to 12 ticks.")
        #expect(problem { $0.steps[3].ticks = ["one", String(repeating: "x", count: 81)] }
                == "Step 4: a tick can be at most 80 characters.")
        #expect(problem { $0.steps[3].calculator = "Bad" } == "Step 4: the calculator isn't a calculator's page.")
        #expect(problem { $0.steps[2].guide = "Bad Id" } == "Step 3: the guide isn't a guide's id.")
        // an empty list or field writes no line
        var empty = Self.sample
        empty.need = []; empty.danger = " "; empty.steps[2].items = []; empty.steps[2].wanted = ""
        #expect(!empty.markdown.contains("need:") && !empty.markdown.contains("wanted:")
                && !empty.markdown.contains("  items:") && !empty.markdown.contains("\ndanger:"))
    }

    @Test func readingRefusesTheShapesTheWriterCantMake() {
        let head = "---\ntitle: S\nkind: steps\n---\n"
        for text in [head + "- step: a\n  yes: two\n  no: 2\n- step: b\n", head + "- step: a\n  map: no\n",
                     head + "- step: a\n  call: 5555550142\n", head + "- step: a\n  yes: 2\n- step: b\n",
                     "---\ntitle: S\nkind: steps\nchecked: 2026-11-16\n---\n- step: a\n",
                     head + "- step: a\n  checked: abcdef12\n  checked: abcdef12\n"] {
            #expect(throws: HouseholdPage.Problem.self) { try HouseholdPage(markdown: text) }
        }
    }
}

/// The editor's fresh look (docs/plans/2026-11-20-our-home-editor.md, Task 1): place, manual and things, a number of 3
/// to 15 digits and its look; packer/tests/test_steps.py's EditorFormTest has the same cases.
@Suite struct EditorFormTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let head = "---\ntitle: SAMPLE\nkind: steps\n---\n"

    func read(_ text: String) throws -> HouseholdPage { try HouseholdPage(markdown: text) }

    @Test func testPickedLine() {
        let garage = HouseholdPage.Picked(line: "#14 Garage")
        #expect(garage?.id == 14 && garage?.words == "Garage" && garage?.line == "#14 Garage")
        let yard = HouseholdPage.Picked(line: "Back yard")
        #expect(yard?.id == nil && yard?.words == "Back yard" && yard?.line == "Back yard")
        #expect(HouseholdPage.Picked(line: "  ") == nil)
        #expect(HouseholdPage.Picked(line: "#x")?.id == nil, "kept as typed, for the Save check to name")
        #expect(HouseholdPage.Picked(id: 14, words: "Garage › Utility shelf").name == "Utility shelf")
    }

    @Test func placeTypedAndPicked() throws {
        #expect(try read(Self.head + "- step: a\n  place: Back yard\n").steps[0].place == .init(words: "Back yard"))
        #expect(try read(Self.head + "- step: a\n  place: #14 Garage › Utility shelf\n").steps[0].place
                == .init(id: 14, words: "Garage › Utility shelf"))
        for value in ["#x", "#14", "#0 Garage", String(repeating: "x", count: 81), "a [Fill in: q]"] {
            #expect(throws: HouseholdPage.Problem.self, "\(value)") { try read(Self.head + "- step: a\n  place: \(value)\n") }
        }
        var page = HouseholdPage(title: "SAMPLE", steps: [.init(words: "a", place: .init(words: "#x"))])
        #expect(page.problem == "Step 1: a place you type can't start with #.")
        page.steps[0].place = .init(words: String(repeating: "x", count: 81))
        #expect(page.problem == "Step 1: a place can be at most 80 characters.")
        page.steps[0].place = .init(id: 3, words: String(repeating: "x", count: 80))
        #expect(page.problem == nil)
    }

    @Test func manualMustBePicked() throws {
        #expect(throws: HouseholdPage.Problem.self) { try read(Self.head + "- step: a\n  manual: Generator\n") }
        #expect(try read(Self.head + "- step: a\n  manual: #7 SAMPLE Generator\n").steps[0].manual
                == .init(id: 7, words: "SAMPLE Generator"))
    }

    @Test func things() throws {
        let page = try read("---\ntitle: S\nkind: steps\nthings: #7 SAMPLE wrench; SAMPLE old towels\n---\n- step: a\n")
        #expect(page.things == [.init(id: 7, words: "SAMPLE wrench"), .init(words: "SAMPLE old towels")])
        for value in [(0..<9).map { "thing \($0)" }.joined(separator: "; "), "#x wrench", "ok; " + String(repeating: "x", count: 61)] {
            #expect(throws: HouseholdPage.Problem.self, "\(value)") {
                try read("---\ntitle: S\nkind: steps\nthings: \(value)\n---\n- step: a\n")
            }
        }
        func problem(_ things: [HouseholdPage.Picked]) -> String? {
            HouseholdPage(title: "S", things: things, steps: [.init(words: "a")]).problem
        }
        #expect(problem((0..<9).map { .init(words: "thing \($0)") }) == "What you need: at most 8 things.")
        #expect(problem([.init(words: "#x")]) == "What you need: a thing you type can't start with #.")
        #expect(problem([.init(words: String(repeating: "x", count: 61))])
                == "What you need: a thing can be at most 60 characters.")
        #expect(problem([.init(words: "a;b")]) == "What you need: a thing can't hold ;.")
    }

    @Test func callTakes3To15Digits() throws {
        for number in ["911", "5555550142", "15555550142", String(repeating: "5", count: 15)] {
            #expect(try read(Self.head + "- step: a\n  call: \(number); SAMPLE\n").steps[0].call?.number == number)
            #expect(HouseholdPage.callProblem(number) == nil)
        }
        #expect(HouseholdPage.callProblem("55") == "A number to call needs at least 3 digits.")
        #expect(HouseholdPage.callProblem(String(repeating: "5", count: 16)) == "A number to call can't be longer than 15 digits.")
        #expect(HouseholdPage.callProblem("1 (555) 555-0142") == nil, "spaces, dashes and brackets are fine")
        #expect(HouseholdPage.callProblem("555-O142") == "A number to call can only hold digits.")
    }

    @Test func shownNumber() {
        for (digits, shown) in [("5555550142", "(555) 555-0142"), ("15555550142", "1 (555) 555-0142"), ("911", "911"),
                                ("25555550142", "25555550142"), ("555555014", "555555014")] {
            #expect(HomePage.shownNumber(digits) == shown)
        }
    }

    @Test func testOldPageRoundTripsUnchanged() throws {
        let url = Self.fixtures.appendingPathComponent("our-home-page-old.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let page = try read(text)
        #expect(page.markdown == text)
        #expect(page.tidied.markdown == text, "Save with nothing edited writes it back unchanged")
        let before = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("html"), encoding: .utf8)
        #expect(HomePage.body(page, mediaID: "0f1e2d3c-4b5a-4968-8776-6554433221b4",
                              guideTitles: ["utility-shutoff.html": "SAMPLE Shutting off",
                                            "generator-co.html": "SAMPLE Generators"]) == before)
    }

    @Test func theCardPrintsAPlaceAndEachThing() {
        let card = HomeCard(OurHomeFormTests.sample, name: "house-sample", printed: Date(timeIntervalSince1970: 0))
        #expect(card.things == ["SAMPLE wrench", "SAMPLE old towels"])
        #expect(card.steps[2].place == "SAMPLE Garage › Utility shelf")
        #expect(card.steps[3].place == "SAMPLE Back yard")
        #expect(card.steps[1].call == "Call SAMPLE gas emergency line: (555) 555-0142")
    }
}
