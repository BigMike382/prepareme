import Foundation
import Testing
@testable import PrepareMeShared

/// The family downloads plan, phase 2 (owner, 2026-11-15): a child's device has every file button an adult's has, and
/// no screen tells anyone to ask an adult. A view's button can't be unit tested, so this reads the code, as phase 1's
/// DownloadsWordsTests does: `isChild` is used only in the places listed below, none about files, and no string literal
/// says "ask an adult" or its kin.
struct ChildDevicesTests {
    /// Every place `isChild` may appear in code (comments and literals skipped), by file and count: the role itself
    /// (PhoneInventoryModel), walk-through marks, maps' first side and pairing's words (phase 3 replaced `dropNever`,
    /// the last about files, with `letGoDropped` on every device). A new use fails here; if it isn't about files, add
    /// it with its reason.
    static let allowed: [String: Int] = [
        "app/Kiwix/PrepareMeApp/PrepareMeAddFromFiles.swift": 2,  // the role's definition; FolderOffer.make's child rule
        "app/Kiwix/PrepareMeApp/PrepareMeLibrary.swift": 1,  // the walk-through role
        "app/Kiwix/PrepareMeApp/PrepareMePhoneInventory.swift": 1,  // walk-through marks
        "app/Kiwix/PrepareMeApp/PrepareMeTabs.swift": 6,  // maps' first side
        "app/Kiwix/PrepareMeApp/PrepareMeViews.swift": 2,  // Pair again's line and sheet
        "app/Kiwix/Model/WebViewConfig/WebViewConfiguration.swift": 1,  // walk-through marks
        "app/Service/Sources/PrepareMeShared/MapsFirstSide.swift": 13,  // maps' first side
    ]

    static let asks = try! NSRegularExpression(pattern: "ask an adult|an adult adds|an adult can|grown-up",
                                               options: [.caseInsensitive])
    /// A household page draft's school step ("until a grown-up on the list comes"): a fact for the school, not an ask
    static let kept = ["grown-up on the list comes"]

    /// The source with its comments and string literals taken out
    static func code(_ source: String) -> String {
        let s = Array(source)
        var out = "", i = 0
        func at(_ j: Int, _ text: String) -> Bool { j + text.count <= s.count && String(s[j..<j + text.count]) == text }
        while i < s.count {
            if at(i, "\"\"\"") {
                i += 3
                while i < s.count && !at(i, "\"\"\"") { i += 1 }
                i += 3
            } else if at(i, "//") {
                while i < s.count && s[i] != "\n" { i += 1 }
            } else if at(i, "/*") {
                i += 2
                while i < s.count && !at(i, "*/") { i += 1 }
                i += 2
            } else if s[i] == "\"" {
                i += 1
                while i < s.count && s[i] != "\"" && s[i] != "\n" { i += s[i] == "\\" ? 2 : 1 }
                i += 1
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }

    static func uses(_ code: String) -> Int {
        code.components(separatedBy: "isChild").count - 1
    }

    @Test func theReaderCountsOnlyCode() {
        #expect(Self.uses(Self.code("if a.isChild { } // isChild\nlet b = \"isChild\"")) == 1)
        #expect(Self.uses(Self.code("/* isChild */ let c = \"\"\"\n isChild\n \"\"\"")) == 0)
    }

    @Test func isChildOnlyWhereItIsNotAboutFiles() throws {
        let files = DownloadsWordsTests.files()
        #expect(files.count > 100, "the folders were not found")
        var found: [String: Int] = [:]
        for url in files {
            let name = url.path.replacingOccurrences(of: MapWordsTests.repo.path + "/", with: "")
            let count = Self.uses(Self.code(try String(contentsOf: url, encoding: .utf8)))
            if count > 0 { found[name] = count }
        }
        #expect(found == Self.allowed, Comment(rawValue: "isChild by file: \(found.sorted { $0.key < $1.key })"))
    }

    @Test func noScreenSaysAskAnAdult() throws {
        var found: [String] = []
        for url in DownloadsWordsTests.files() {
            let name = url.path.replacingOccurrences(of: MapWordsTests.repo.path + "/", with: "")
            for text in DownloadsWordsTests.literals(try String(contentsOf: url, encoding: .utf8))
            where Self.asks.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                && !Self.kept.contains(where: text.contains) {
                found.append("\(name): \(text)")
            }
        }
        #expect(found.isEmpty, Comment(rawValue: "\(found.count) literals still ask an adult:\n"
                                       + found.joined(separator: "\n")))
    }

    @Test func theNewWords() {
        #expect(HomeMacWords.pairStartsOnMac == "Pairing starts on the Mac at home.")
        #expect(RallyWords.noRallyPoint(.child) == "No meeting place yet. They are added on an adult's phone or on the Mac.")
        #expect(PairingWords.kind(label: "phone 2", readOnly: true, waiting: false) == "Child's device (phone 2)")
        #expect(!Backup.readMe.contains("an adult does it"))
    }
}
