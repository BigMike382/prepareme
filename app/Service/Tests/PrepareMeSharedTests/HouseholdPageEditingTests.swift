import Foundation
import Testing
@testable import PrepareMeShared

/// The Mac editor's changes to a page (docs/plans/2026-11-16-our-home.md, Task 2.5).
struct HouseholdPageEditingTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    func fourSteps() -> HouseholdPage {
        HouseholdPage(title: "SAMPLE", steps: [
            .init(words: "SAMPLE one?", yes: 2, no: 3), .init(words: "SAMPLE two"), .init(words: "SAMPLE three"),
            .init(words: "SAMPLE four?", yes: 1, no: 3),
        ])
    }

    @Test func movingAStepRenumbersEveryYesAndNo() {
        var page = fourSteps()
        page.moveStep(from: 2, to: 0)  // "three" first
        #expect(page.steps.map(\.words) == ["SAMPLE three", "SAMPLE one?", "SAMPLE two", "SAMPLE four?"])
        #expect((page.steps[1].yes, page.steps[1].no) == (3, 1))
        #expect((page.steps[3].yes, page.steps[3].no) == (2, 1))
        #expect(page.problem == nil)
        page.moveStep(from: 0, to: 3)  // back to the end
        #expect(page.steps.map(\.words) == ["SAMPLE one?", "SAMPLE two", "SAMPLE four?", "SAMPLE three"])
        #expect((page.steps[0].yes, page.steps[0].no) == (2, 4))
        #expect((page.steps[2].yes, page.steps[2].no) == (1, 4))
    }

    @Test func deletingAStepRenumbersAndOneLeftPointingAtItBlocksSave() {
        var page = fourSteps()
        page.removeStep(at: 1)  // "two"
        #expect((page.steps[0].yes, page.steps[0].no) == (0, 2))
        #expect((page.steps[2].yes, page.steps[2].no) == (1, 2))
        #expect(page.problem == "Step 1: choose the step Yes goes to.")
        page.steps[0].yes = 3
        #expect(page.problem == nil)
    }

    @Test func fillingABlankWritesItsAnswerAndNeverTheCheckedMark() throws {
        var page = try HouseholdPage(markdown: String(contentsOf: Self.fixtures.appendingPathComponent("our-home-page.md"),
                                                      encoding: .utf8))
        let checked = page.steps.map(\.checked)
        let open = page.unfilledBlanks
        #expect(open.map(\.question) == ["left or right?"])
        page.fill(open[0], with: "  turn it [left] {now}\n")
        #expect(page.tidied.steps[2].words == "SAMPLE turn the handle a quarter turn [Fill in: left or right?]{turn it left now}, so it lies across the pipe.")
        #expect(page.steps.map(\.checked) == checked)
        #expect(page.unfilledBlanks.isEmpty)
        #expect(page.blanks.count == 2)  // the when's, filled, and this one
        page.fill(open[0], with: " ")
        #expect(page.unfilledBlanks.map(\.question) == ["left or right?"])
    }

    /// Owner check 95 (the owner's Mac, 2026-11-20): "Call" then a space, for a power company's two-word name, lost the
    /// space at each key, as each key tidied the answer. The box keeps what is typed; Save's `tidied` trims it.
    @Test func typingABlanksAnswerKeepsItsSpaces() throws {
        var page = try HouseholdPage(markdown: String(contentsOf: Self.fixtures.appendingPathComponent("our-home-page.md"),
                                                      encoding: .utf8))
        let blank = page.unfilledBlanks[0]
        for typed in ["C", "Call", "Call ", "Call S", "Call SAMPLE  power "] {
            page.fill(blank, with: typed)
            #expect(page.blanks.first { $0.index == blank.index && $0.field == blank.field }?.answer == typed)
        }
        page.fill(blank, with: " ")
        #expect(page.unfilledBlanks.count == 1, "spaces alone leave it open")
        page.fill(blank, with: "Call SAMPLE  power ")
        let saved = page.tidied
        #expect(saved.steps[2].words.contains("{Call SAMPLE power}"))
        #expect(saved.markdown == (try HouseholdPage(markdown: saved.markdown)).markdown)
    }

    /// The design session's sweep after owner check 95: every box the editor binds to the page, typed "two words" one
    /// key at a time, reads back "two words" at each key. The boxes' own bindings pass the text straight through
    /// (PrepareMeHouseholdPages.swift's binding, stepBinding, partBinding, callBinding and the checklist's lines); a
    /// blank's box goes through `fill`, in Page details' Use this when, a step's words and a caution.
    @Test func typingTwoWordsKeyByKeyKeepsThemInEveryBox() {
        var page = HouseholdPage(title: "", when: "SAMPLE [Fill in: a]", steps: [
            .init(words: "SAMPLE [Fill in: b]", caution: "SAMPLE [Fill in: c]"),
        ])
        let typed = Array("two words").indices.map { String(Array("two words")[...$0]) }
        let pageKeys: [WritableKeyPath<HouseholdPage, String>] = [\.title, \.danger, \.next]
        let stepKeys: [WritableKeyPath<HouseholdPage.Step, String>] = [\.name, \.danger]
        let callKeys: [WritableKeyPath<HouseholdPage.Call, String>] = [\.number, \.label]
        for key in pageKeys { for t in typed { page[keyPath: key] = t; #expect(page[keyPath: key] == t) } }
        for key in stepKeys { for t in typed { page.steps[0][keyPath: key] = t; #expect(page.steps[0][keyPath: key] == t) } }
        for key in callKeys {
            for t in typed {
                var call = page.steps[0].call ?? .init(number: "", label: "")
                call[keyPath: key] = t
                page.steps[0].call = call
                #expect(page.steps[0].call?[keyPath: key] == t)
            }
        }
        for t in typed {  // the checklist's lines, one box of lines
            page.steps[0].ticks = ("SAMPLE first\n" + t).components(separatedBy: "\n")
            #expect(page.steps[0].ticks.joined(separator: "\n") == "SAMPLE first\n" + t)
        }
        for field in [HouseholdPage.Blank.Field.when, .words(0), .caution(0)] {
            for t in typed {
                page.fill(page.blanks.first { $0.field == field }!, with: t)
                #expect(page.blanks.first { $0.field == field }?.answer == t, "\(field)")
            }
        }
        // a blank's words and its step's own words, typed after the blank, stay as typed too
        for t in typed { page.steps[0].words = "SAMPLE [Fill in: b]{two words} " + t; #expect(page.steps[0].words.hasSuffix(t)) }
    }

    @Test func rewordingAStepKeepsItsCheckedMarkSoThePageShowsItChanged() throws {
        var page = try HouseholdPage(markdown: String(contentsOf: Self.fixtures.appendingPathComponent("our-home-page.md"),
                                                      encoding: .utf8))
        page.steps[0].words = "SAMPLE do you smell gas anywhere?"
        #expect(page.steps[0].checked == "c276b32d")
        #expect(page.markdown.contains("  checked: c276b32d\n"))
        #expect(HomePage.body(page, mediaID: "", guideTitles: [:]).contains("hp-changed"))
    }

    @Test func theNewFieldsWriteTheirLinesAndAnEmptyOneNone() {
        var page = HouseholdPage(title: "SAMPLE", steps: [.init(words: "SAMPLE go")])
        #expect(!page.markdown.contains("danger:") && !page.markdown.contains("need:") && !page.markdown.contains("next:"))
        page.danger = "SAMPLE gas"
        page.need = ["sample wrench", " "]
        page.next = "SAMPLE call"
        page.steps[0].danger = "SAMPLE hot"
        page.steps[0].wanted = "SAMPLE the valve"
        let text = page.markdown
        for line in ["danger: SAMPLE gas\n", "need: sample wrench\n", "next: SAMPLE call\n", "  danger: SAMPLE hot\n",
                     "  wanted: SAMPLE the valve\n"] {
            #expect(text.contains(line))
        }
        page.steps[0].wanted = "  "
        #expect(!page.markdown.contains("wanted:"))
    }

    func blanked() -> HouseholdPage {
        HouseholdPage(title: "SAMPLE", when: "SAMPLE [Fill in: a]", steps: [
            .init(words: "SAMPLE [Fill in: b] and [Fill in: x]{done} and [Fill in: c]", caution: "SAMPLE [Fill in: d]"),
            .init(words: "SAMPLE [Fill in: e]"),
        ])
    }

    /// Board 7 (the editor plan, Task 6): Go to the next visits the blanks left in the screen's order, Use this when
    /// first, then each step's words and its warning's row.
    @Test func testNextBlankGoesInPageOrder() {
        let page = blanked()
        var seen: [String] = []
        var at: HouseholdPage.Blank? = nil
        for _ in 0..<4 {
            at = page.nextBlank(after: at)
            seen.append(at?.question ?? "none")
        }
        #expect(seen == ["a", "b", "c", "d"])
        #expect(page.unfilledBlanks.count == 5 && page.unfilledBlanks.count == page.blanksLeft)
        #expect(page.blanks.map(\.question).sorted() == ["a", "b", "c", "d", "e", "x"])
    }

    @Test func testNextBlankWrapsToTheFirst() {
        var page = blanked()
        let last = page.nextBlank(after: page.unfilledBlanks.first { $0.question == "d" })
        #expect(last?.question == "e")
        #expect(page.nextBlank(after: last)?.question == "a", "past the last, back to the first")
        // a blank filled meanwhile is passed over
        page.fill(page.unfilledBlanks.first { $0.question == "a" }!, with: "SAMPLE answer")
        #expect(page.nextBlank(after: last)?.question == "b")
    }

    @Test func testNoBarWithoutBlanks() {
        var page = HouseholdPage(title: "SAMPLE", steps: [.init(words: "SAMPLE go")])
        #expect(page.nextBlank(after: nil) == nil)
        #expect(HomeEditorWords.leftToFill(page.blanksLeft) == nil)
        page.steps[0].words = "SAMPLE [Fill in: q]"
        #expect(HomeEditorWords.leftToFill(page.blanksLeft) == "1 left to fill in")
        page.steps.append(.init(words: "SAMPLE [Fill in: r]"))
        #expect(HomeEditorWords.leftToFill(page.blanksLeft) == "2 left to fill in")
    }

    @Test func theKindOfAStep() {
        var page = fourSteps()
        #expect(page.steps.map(\.kind) == [.yesNo, .next, .next, .yesNo])
        page.setKind(.checklist, step: 1)
        #expect(page.steps[1].kind == .checklist)
        #expect(page.markdown == fourSteps().markdown)  // an empty checklist writes no line
        page.setKind(.yesNo, step: 1)
        #expect((page.steps[1].yes, page.steps[1].no, page.steps[1].ticks) == (0, 0, []))
        #expect(page.problem == "Step 2: choose the step Yes goes to.")
        page.setKind(.next, step: 1)
        #expect(page.steps[1] == fourSteps().steps[1])
    }

    @Test func theWords() {
        // the page list says it as the bar does (the review, 2026-11-20)
        #expect(HomeEditorWords.leftToFill(1) == "1 left to fill in")
        #expect(HomeEditorWords.leftToFill(3) == "3 left to fill in")
        #expect(HomeEditorWords.leftToFill(0) == nil)
        #expect(HomeEditorWords.answerReplaces("left or right?") == "Your answer takes the place of [Fill in: left or right?] above.")
        #expect(HomeEditorWords.stale == "No longer in your inventory")
        #expect(HomeEditorWords.walked("2026-10-04") == "Walked through Oct 4")
        #expect(HomeEditorWords.answerTo(2, "SAMPLE get out") == "Step 2: SAMPLE get out")
    }

    /// Boards 1 and 2 (the editor plan, Task 5): a part set on a step is one row the editor shows; taking it away
    /// clears that part alone, and "Add to this step" offers each part only while the step lacks it.
    @Test func testAddAndRemoveEachPart() {
        let bare = HouseholdPage.Step(words: "SAMPLE turn it", name: "SAMPLE valve", checked: "c276b32d")
        #expect(bare.offered(showing: []) == [.danger, .place, .call, .guide, .manual, .photo, .video])
        let set: [(HouseholdPage.Part, (inout HouseholdPage.Step) -> Void)] = [
            (.danger, { $0.danger = "SAMPLE hot" }), (.caution, { $0.caution = "SAMPLE slippery" }),
            (.place, { $0.place = .init(id: 2, words: "SAMPLE Garage › SAMPLE Utility shelf") }),
            (.call, { $0.call = .init(number: "911", label: "SAMPLE emergency") }), (.guide, { $0.guide = "radio" }),
            (.manual, { $0.manual = .init(id: 7, words: "SAMPLE Generator") }), (.photo, { $0.photo = "sample-1.jpg" }),
            (.video, { $0.video = "sample-1.mp4" }), (.items, { $0.items = ["SAMPLE wrench"] }),
        ]
        for (part, apply) in set {
            var step = bare
            #expect(!step.has(part))
            apply(&step)
            #expect(step.has(part), "\(part)")
            #expect(HouseholdPage.Part.allCases.filter { step.has($0) } == [part], "only \(part)")
            if part != .items, part != .caution { #expect(!step.offered(showing: []).contains(part)) }
            step.remove(part)
            #expect(step == bare, "taking \(part) away leaves the step as it was")
        }
        // a row added and still empty is shown, so it isn't offered again while it's typed in
        #expect(bare.offered(showing: [.place, .call]) == [.danger, .guide, .manual, .photo, .video])
        // an old items: line is never offered, only removed
        #expect(!bare.offered(showing: []).contains(.items))
    }

    /// A step holds one Danger and one Caution, as before; Warning is offered while it lacks either, and a warning
    /// switches kind only to the kind the step doesn't hold.
    @Test func testAStepCanHoldADangerAndACaution() {
        var step = HouseholdPage.Step(words: "SAMPLE go", danger: "SAMPLE hot")
        #expect(step.offered(showing: []).first == .caution, "Warning, as the kind it lacks")
        #expect(step.canSwitch(.danger))
        step.switchWarning(.danger)
        #expect((step.danger, step.caution) == ("", "SAMPLE hot"))
        #expect(step.offered(showing: []).first == .danger)
        step.danger = "SAMPLE live wire"
        #expect(!step.canSwitch(.danger) && !step.canSwitch(.caution))
        #expect(!step.offered(showing: []).contains(.danger) && !step.offered(showing: []).contains(.caution))
        step.switchWarning(.caution)  // refused: it already holds a Danger
        #expect((step.danger, step.caution) == ("SAMPLE live wire", "SAMPLE hot"))
        let page = HouseholdPage(title: "SAMPLE", steps: [step])
        #expect(page.markdown.contains("  caution: SAMPLE hot\n") && page.markdown.contains("  danger: SAMPLE live wire\n"))
        #expect(page.problem == nil)
    }

    @Test func thePageListKnowsBlanksAndTheWalk() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = HouseholdPagesFolder(home: home)
        try FileManager.default.createDirectory(at: folder.daily, withIntermediateDirectories: true)
        try folder.save(HouseholdPage(title: "SAMPLE A", walked: "2026-10-04", steps: [.init(words: "SAMPLE [Fill in: q]")]),
                        as: "house-sample")
        let row = try #require(folder.list().first { $0.name == "house-sample" })
        #expect((row.blanksLeft, row.walked) == (1, "2026-10-04"))
    }
}
