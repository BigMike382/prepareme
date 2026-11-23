import Foundation
import Testing
@testable import PrepareMeShared

/// The editor's preview draws an Our Home page byte for byte as packer/steps.py's body() does, on the shared cases
/// packer/tests/test_steps.py writes (PREPAREME_WRITE_FIXTURE=1 writes them and the resource again).
struct HomePageTests {
    struct Case: Decodable {
        let page, media_id, body: String
        let guide_titles: [String: String]
        let back_home: String?
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    @Test func theBodyIsThePackers() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.fixtures
            .appendingPathComponent("our-home-previews.json")))
        #expect(cases.count == 3)
        for c in cases {
            let text = try String(contentsOf: Self.fixtures.appendingPathComponent(c.page), encoding: .utf8)
            let page = try HouseholdPage(markdown: text)
            let drawn = HomePage.body(page, mediaID: c.media_id, guideTitles: c.guide_titles, backHome: c.back_home)
            #expect(drawn == c.body, "\(c.page): \(firstDifference(drawn, c.body))")
        }
    }

    @Test func theDocumentCarriesTheStylesAndTheScript() throws {
        let page = HouseholdPage(title: "SAMPLE <page>", steps: [.init(words: "SAMPLE call 911.")])
        let doc = HomePage.document(page, guideTitles: [:])
        #expect(doc.contains("<title>SAMPLE &lt;page&gt;</title>"))
        #expect(doc.contains(".home-page"))
        #expect(doc.contains("<body class='steps-page home-page'>"))
        #expect(doc.contains("pm-home-step:"))
        #expect(doc.contains("<span class=\"tel\" data-tel=\"911\">911</span>"))
    }

    @Test func aStepTheEditorHasntPointedYetStillDraws() {
        let page = HouseholdPage(title: "SAMPLE", steps: [.init(words: "SAMPLE ask?", yes: 5, no: 1)])
        #expect(HomePage.body(page, mediaID: "", guideTitles: [:]).contains("href=\"#step-5\""))
    }

    @Test func aStepWithNoNameGoesByItsWordsWithABlankAsWords() {  // packer's test_steps has the same case
        let page = HouseholdPage(title: "SAMPLE", steps: [.init(words: "SAMPLE turn it [Fill in: left or right?]."),
                                                          .init(words: "SAMPLE then [Fill in: which one?]{the red one}.")])
        let body = HomePage.body(page, mediaID: "", guideTitles: [:])
        #expect(!body.contains("[Fill in"))
        #expect(body.contains("SAMPLE turn it Fill in: left or right?.</a>"))
        #expect(body.contains("SAMPLE then the red one.</a>"))
    }

    @Test func formatIsOnePass() {
        #expect(HomePage.format("{a} and {b}", ["a": "{b}", "b": "x"]) == "{b} and x")
    }

    func firstDifference(_ a: String, _ b: String) -> String {
        let x = Array(a), y = Array(b)
        let i = (0..<min(x.count, y.count)).first { x[$0] != y[$0] } ?? min(x.count, y.count)
        return "at \(i): \(String(x[max(0, i - 40)..<min(x.count, i + 60)])) | \(String(y[max(0, i - 40)..<min(y.count, i + 60)]))"
    }
}
