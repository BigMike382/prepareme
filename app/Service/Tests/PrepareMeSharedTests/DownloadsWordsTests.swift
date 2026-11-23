import Foundation
import Testing
@testable import PrepareMeShared

/// The family downloads plan, phase 1 (owner, 2026-11-15): the family never reads "Home Mac" again; the screen is
/// Downloads and sentences say "the Mac". Reads every Swift file under the app and the shared sources and fails on any
/// string literal (multi-line ones included) that still says it. Type names, function names and comments are not
/// literals here.
struct DownloadsWordsTests {
    static let leftover = try! NSRegularExpression(pattern: "home mac", options: [.caseInsensitive])

    static func files() -> [URL] {
        var found: [URL] = []
        for folder in ["app/Kiwix", "app/Service/Sources"] {
            let walk = FileManager.default.enumerator(at: MapWordsTests.repo.appendingPathComponent(folder),
                                                      includingPropertiesForKeys: nil)
            while let url = walk?.nextObject() as? URL { if url.pathExtension == "swift" { found.append(url) } }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Each string literal's text, comments skipped: `"…"` and `"""…"""`, a backslash escaping the next character.
    static func literals(_ source: String) -> [String] {
        let s = Array(source)
        var out: [String] = [], i = 0
        func at(_ j: Int, _ text: String) -> Bool { j + text.count <= s.count && String(s[j..<j + text.count]) == text }
        while i < s.count {
            if at(i, "\"\"\"") {
                var j = i + 3
                while j < s.count && !at(j, "\"\"\"") { j += 1 }
                out.append(String(s[i + 3..<min(j, s.count)]))
                i = j + 3
            } else if at(i, "//") {
                while i < s.count && s[i] != "\n" { i += 1 }
            } else if at(i, "/*") {
                i += 2
                while i < s.count && !at(i, "*/") { i += 1 }
                i += 2
            } else if s[i] == "\"" {
                var j = i + 1
                while j < s.count && s[j] != "\"" && s[j] != "\n" { j += s[j] == "\\" ? 2 : 1 }
                out.append(String(s[i + 1..<min(j, s.count)]))
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    static func hits(in text: String) -> Bool {
        leftover.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    @Test func theReaderFindsTheWords() {
        #expect(Self.literals("let a = \"Open Home Mac\" // Home Mac in a comment").filter(Self.hits).count == 1)
        #expect(Self.literals("// \"Home Mac\" quoted in a comment").filter(Self.hits).isEmpty)
        #expect(Self.literals("let b = \"\"\"\n  under home Mac\n  \"\"\"").filter(Self.hits).count == 1)
        #expect(Self.literals("let c = \"say \\\"Home Mac\\\"\"").filter(Self.hits).count == 1)
        #expect(Self.literals("let d = \"Downloads\" + \"the Mac\"").filter(Self.hits).isEmpty)
    }

    @Test func theWordsArePhaseOnes() {
        #expect(StateWords.openHomeMac == "Open Downloads")
        #expect(FindAMapWords.getThisFile == "Download")
    }

    @Test func noHomeMacOnAScreen() throws {
        let files = Self.files()
        #expect(files.count > 100, "the folders were not found")
        var found: [String] = []
        for url in files {
            let name = url.path.replacingOccurrences(of: MapWordsTests.repo.path + "/", with: "")
            for text in Self.literals(try String(contentsOf: url, encoding: .utf8)) where Self.hits(in: text) {
                found.append("\(name): \(text)")
            }
        }
        #expect(found.isEmpty, Comment(rawValue: "\(found.count) literals still say Home Mac:\n"
                                       + found.joined(separator: "\n")))
    }
}
