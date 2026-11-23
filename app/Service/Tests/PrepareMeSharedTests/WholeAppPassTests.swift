import Foundation
import XCTest
@testable import PrepareMeShared

/// Look 3 phase 8, the whole-app pass: each fix held where it was made, by reading the screen's source, the project's
/// way to pin app-target changes (`MacCommandsTests`).
final class WholeAppPassTests: XCTestCase {
    static let app = PaletteTests.repo.appendingPathComponent("app/Kiwix")

    func file(_ path: String) throws -> String {
        try String(contentsOf: Self.app.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text from `start` up to the next `end` after it.
    func part(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex)
        else { XCTFail("\(start) wasn't found"); return "" }
        return String(text[a.lowerBound..<b.lowerBound])
    }

    /// Step 1, spec section 10 rule 1: the full-screen "nothing here", "not set up" and "something's wrong" states the
    /// walk found in their own look take the one look, PMState.
    func testWalkedStatesTakeTheOneLook() throws {
        let inventory = try file("PrepareMeApp/PrepareMeInventory.swift")
        let note = part(inventory, from: "struct InventoryNote", to: "\n}\n")
        XCTAssertTrue(note.contains("PMState("), "the Mac's InventoryNote (no inventory, lists, To Buy) isn't PMState")
        XCTAssertTrue(note.contains("PMState(symbol: symbol, heading: text, line: line, kind: kind)"),
                      "InventoryNote drops its line")
        // the reason in the red line under a plain heading, not a raw error as the heading (look 3, after phase 8)
        XCTAssertTrue(inventory.contains("case .problem(let why): InventoryNote(text: \"The inventory couldn't be "
                                         + "read\", line: why, kind: .damaged"),
                      "the Mac inventory's reading problem isn't a heading with its reason red")
        XCTAssertTrue(try file("PrepareMeApp/PrepareMeStreetMapMac.swift")
                        .contains("case .problem(let why): InventoryNote(text: \"The street map couldn't be read\", "
                                  + "line: why, kind: .damaged"),
                      "the Mac street map's reading problem isn't a heading with its reason red")
        let noMap = part(try file("PrepareMeApp/PrepareMeStreetMapMac.swift"), from: "} content: {", to: "}\n")
        XCTAssertTrue(noMap.contains("InventoryNote("), "the Mac's no-street-map pane has its own look")
        let phoneDocs = try file("PrepareMeApp/PrepareMePhoneDocuments.swift")
        XCTAssertTrue(phoneDocs.contains("PMState(symbol: \"folder\", heading: DocumentsWords.emptyHeading"),
                      "the phone's empty Essential Documents isn't PMState, as the Mac's is")
        for path in ["PrepareMeApp/PrepareMePhoneDocuments.swift", "PrepareMeApp/PrepareMeDocuments.swift"] {
            let damaged = part(try file(path), from: "heading: DocumentsWords.damagedHeading,", to: ")")
            XCTAssertTrue(damaged.contains("line: DocumentsWords.damaged, kind: .damaged"),
                          "\(path): a damaged document's words aren't in its red line")
        }
        for path in ["PrepareMeApp/PrepareMeViews.swift", "PrepareMeApp/PrepareMeScan.swift"] {
            XCTAssertTrue(try file(path).contains("heading: StateWords.binNotInCopy(device: ThisDevice.word)"),
                          "\(path): a bin not in the copy isn't PMState")
        }
    }

    /// After phase 8's review: PMState colors its line, not its heading, so a red or amber state with no line showed
    /// its words in ink and only its symbol in color. Every such state carries its words in the line.
    func testNoColoredStateWithoutItsLine() throws {
        let folder = Self.app.appendingPathComponent("PrepareMeApp")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            let text = try file("PrepareMeApp/" + name)
            for kind in [".damaged", ".attention"] {
                XCTAssertFalse(text.contains("line: \"\", kind: \(kind)"), "\(name): a \(kind) state with no line")
            }
        }
    }

    /// Step 1, spec section 10 rule 3: red damaged or refused, amber needs your attention, gray information.
    func testWalkedMessagesTakeTheColorRule() throws {
        let refusal = part(try file("PrepareMeApp/PrepareMeStreetMapMac.swift"),
                           from: "why the last change was refused", to: ".lineLimit")
        XCTAssertTrue(refusal.contains("PrepareMeColors.red"), "the Mac street map's refusal isn't red")
        let pairSheet = try file("PrepareMeApp/PrepareMeViews.swift")
        XCTAssertTrue(pairSheet.contains("if !problem.isEmpty { Text(problem).foregroundStyle(problemKind.color) }"),
                      "the phone's pairing message doesn't take its kind's color")
        let use = part(pairSheet, from: "private func use(_ text: String, scanned: Bool)", to: "\n    }\n")
        XCTAssertTrue(part(use, from: "HomeMacWords.pasteProblem", to: "return").contains("problemKind = .attention"),
                      "an empty box's Paste the code first. is red, though it asks rather than refuses")
        XCTAssertEqual(use.components(separatedBy: "problemKind = .damaged").count - 1, 2,
                       "the two refusals (a code not kept, not a pairing code) aren't red")
        let macPairing = part(try file("PrepareMeApp/PrepareMePairing.swift"), from: "if let problem = pairing.problem",
                              to: ".textSelection")
        XCTAssertTrue(macPairing.contains("PrepareMeColors.red"),
                      "the Mac's pairing refusals (Not paired, nothing changed) aren't red, as the phone's are")
        let outbox = part(try file("PrepareMeApp/PrepareMePhoneInventory.swift"), from: "if model.outboxUnreadable",
                          to: "}")
        XCTAssertTrue(outbox.contains("PrepareMeColors.red"), "the phone's unreadable offline fixes aren't red")
        let mac = try file("PrepareMeApp/PrepareMeMac.swift")
        XCTAssertTrue(mac.contains("PrepareMeStatusLines(lines: mac.notice, kind: .attention)"),
                      "Settings' Needs attention lines aren't amber")
        // each line a button since 2026-11-14 (Mac Settings plan, Task 2.4), drawn in the attention color
        XCTAssertTrue(part(try file("PrepareMeApp/PrepareMeMacSidebar.swift"), from: "ForEach(all, id:",
                           to: ".help(\"Opens Settings").contains(".foregroundStyle(PMMessageKind.attention.color)"),
                      "Show All's lines aren't amber, as the bar is")
    }
}
