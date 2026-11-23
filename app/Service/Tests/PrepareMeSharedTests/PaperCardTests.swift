import Foundation
import XCTest
@testable import PrepareMeShared

/// Printable References (docs/plans/2026-10-21-printable-references-screen.md): the app reads the card's own answers
/// (Fixtures/paper/card-cases.json, written by `python -m paper.tests.app_cases` from paper/cardtext.py) and the print
/// job's status file (Fixtures/paper/paper-status.json) with its own types, and counts characters as the card does.
/// Made-up cards only.
final class PaperCardTests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/paper")

    struct Case: Decodable {
        let name: String
        let toml: String
        let read: PaperCard.Form
        let checkInput: PaperCard.CheckInput
        let checkExit: Int
        let check: PaperCard.Checked

        enum CodingKeys: String, CodingKey {
            case name, toml, read, checkInput = "check_input", checkExit = "check_exit", check
        }
    }

    struct Count: Decodable {
        let text: String
        let count: Int
    }

    struct Cases: Decodable {
        let cases: [Case]
        let counts: [Count]
    }

    func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: Data(contentsOf: Self.folder.appendingPathComponent("card-cases.json")))
    }

    func testTheCountIsTheCards() throws {
        let found = try cases().counts
        XCTAssertGreaterThan(found.count, 10)
        for each in found {
            XCTAssertEqual(PaperCard.count(each.text), each.count, each.text.debugDescription)
        }
    }

    func testEveryBoxCountsAsTheCardRefuses() throws {
        // A box the card says is N characters too long reads "N over" here, and a box it takes reads "… left".
        let over = try NSRegularExpression(pattern: "is ([0-9]+) characters too long")
        for each in try cases().cases where each.read.readable {
            for field in each.read.fields {
                let left = PaperCard.left(field.value, limit: field.limit)
                let problem = each.read.problems.first { $0.field == field.id && $0.message.contains("too long") }
                if let problem {
                    let range = NSRange(problem.message.startIndex..., in: problem.message)
                    let match = try XCTUnwrap(over.firstMatch(in: problem.message, range: range))
                    let n = (problem.message as NSString).substring(with: match.range(at: 1))
                    XCTAssertEqual(left.words, "\(n) over", "\(each.name): \(field.id)")
                    XCTAssertTrue(left.over)
                } else {
                    XCTAssertFalse(left.over, "\(each.name): \(field.id)")
                }
            }
        }
    }

    func testEveryProblemNamesABoxTheScreenHas() throws {
        for each in try cases().cases {
            let ids = Set(each.read.fields.map(\.id))
            for problem in each.read.problems + each.check.problems {
                guard let field = problem.field else { continue }
                XCTAssertTrue(ids.contains(field) || field.hasPrefix("number."), "\(each.name): \(field)")
            }
        }
    }

    func testTheCasesReadAsTheScreenUsesThem() throws {
        let found = Dictionary(uniqueKeysWithValues: try cases().cases.map { ($0.name, $0) })
        let sample = try XCTUnwrap(found["the made-up sample"])
        XCTAssertTrue(sample.read.readable)
        XCTAssertFalse(sample.read.inForm, "its own comments: saving would drop them")
        XCTAssertEqual(sample.read.numbers.count, sample.read.maxNumbers)
        XCTAssertEqual(sample.read.fields.first { $0.id == "rally.r1" }?.value, "The big oak by the mailbox")
        XCTAssertEqual(sample.checkExit, 0)
        XCTAssertNotNil(sample.check.toml)
        XCTAssertTrue(try XCTUnwrap(found["no card file yet"]).read.inForm)
        let code = try XCTUnwrap(found["a code in the repeater"])
        XCTAssertEqual(code.checkExit, 1)
        XCTAssertNil(code.check.toml, "nothing is saved with a problem")
        XCTAssertEqual(code.check.problems.map(\.field), ["radio.repeater"])
        XCTAssertFalse(code.check.problems[0].message.contains("ducks"), "never the box's text")
        XCTAssertFalse(try XCTUnwrap(found["a file that isn't TOML"]).read.readable)
        // the check's input round-trips through the app's own type
        let again = try JSONDecoder().decode(PaperCard.CheckInput.self,
                                             from: JSONEncoder().encode(sample.checkInput))
        XCTAssertEqual(again, sample.checkInput)
    }

    func testTheStatusFileReads() throws {
        let status = try XCTUnwrap(PaperStatus.read(in: Self.folder))
        let card = try XCTUnwrap(status.results?[PaperStatus.card])
        XCTAssertEqual(card.exit, 1)
        XCTAssertNil(card.pdf)
        XCTAssertEqual(card.lines.last, "- Meeting place 2 is 4 characters too long (at most 40)")
        XCTAssertNotNil(card.finishedAt)
        XCTAssertNotNil(card.pressed, "each answer names the press it answers")
        let binder = try XCTUnwrap(status.results?[PaperStatus.binder])
        XCTAssertEqual(binder.exit, 0)
        XCTAssertEqual(binder.pdf, "booklet.pdf")
        XCTAssertNil(status.running)
        let list = try XCTUnwrap(status.binder)
        XCTAssertEqual(list.changed?.count, 1)
        XCTAssertEqual(list.sections?.map(\.name), ["Fire and carbon monoxide", "Water"])
        XCTAssertEqual(list.sections?.last?.guides.first?.state, "changed")
        XCTAssertEqual(list.sheets, 4)
        XCTAssertEqual(list.problems, [])
    }

    func testAMissingOrDamagedStatusFileIsNone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(PaperStatus.read(in: folder))
        try Data("{not json".utf8).write(to: folder.appendingPathComponent(PaperStatus.fileName))
        XCTAssertNil(PaperStatus.read(in: folder))
    }

    #if os(macOS)
    /// The card's own code, when this Mac has the venv: what the app runs, read and checked for real.
    func testTheRealCardCode() async throws {
        guard let python = PythonTextCheck.venvPython(),
              FileManager.default.isExecutableFile(atPath: python.path) else { return }
        let text = PaperCardText(python: python, code: InventoryTests.repo)
        let sample = try Data(contentsOf: InventoryTests.repo.appendingPathComponent("paper/tests/fixtures/card-sample.toml"))
        let form = try await text.read(sample)
        XCTAssertEqual(form.problems, [])
        var fields = Dictionary(uniqueKeysWithValues: form.fields.map { ($0.id, $0.value) })
        let input = PaperCard.CheckInput(fields: fields, numbers: form.numbers, printed: "2026-10-21",
                                         changed: nil, focus: "rally.r1")
        let checked = try await text.check(input)
        XCTAssertEqual(checked.printsIn, 3)
        XCTAssertEqual(checked.problems, [])
        XCTAssertTrue(try XCTUnwrap(checked.page).contains("<mark class=\"pm-focus\">The big oak by the mailbox</mark>"))
        fields["rally.r2"] = String(repeating: "Wagon ", count: 8)
        let refused = try await text.check(PaperCard.CheckInput(fields: fields, numbers: form.numbers,
                                                                 printed: "2026-10-21", changed: nil, focus: nil))
        XCTAssertNil(refused.toml)
        XCTAssertEqual(refused.problems.map(\.field), ["rally.r2"])
    }
    #endif
}
