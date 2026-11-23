import Foundation
import PrepareMeShared
import Testing

/// The Other Sites list the daily library carries (librarian/outside.py's list_json; library redesign, Task 5.2).
struct OutsideListTests {
    static let line = #"{"category":"reference","description":"A made-up handbook.","host":"www.fema.gov","#
        + #""key":"sample-handbook","kind":"pdf","license":"Public domain","page":"https://www.fema.gov/p","#
        + #""sha256":"\#(String(repeating: "b", count: 64))","size":10,"title":"SAMPLE Handbook","#
        + #""url":"https://www.fema.gov/h.pdf","vetted":"2026-11-13"}"#

    @Test func outsideListDecodes() throws {
        let list = try OutsideList.decode(Data(#"{"entries":[\#(Self.line)],"format":1}"#.utf8))
        #expect(list.entries.map(\.key) == ["sample-handbook"])
        #expect(list.entries[0].size == 10)
        #expect(list.entries[0].category == "reference")
        #expect(try OutsideList.decode(Data(#"{"entries":[],"format":1}"#.utf8)).entries.isEmpty)
    }

    /// Phase 5 review, minors: what a kept file or a stopped download matches on the current list: the same key and
    /// the same vetted file. A list that couldn't be read matches nothing and drops nothing.
    @Test func matchingKeptAndStoppedAgainstTheList() throws {
        let list = try OutsideList.decode(Data(#"{"entries":[\#(Self.line)],"format":1}"#.utf8))
        let entry = list.entries[0]
        #expect(list.entry(key: entry.key, sha256: entry.sha256) == entry)
        #expect(list.entry(key: entry.key, sha256: String(repeating: "c", count: 64)) == nil, "re-checked since")
        #expect(list.entry(key: "gone", sha256: entry.sha256) == nil)
        #expect(!OutsideList.dropped(key: entry.key, sha256: entry.sha256, from: list))
        #expect(OutsideList.dropped(key: "gone", sha256: entry.sha256, from: list))
        #expect(OutsideList.dropped(key: entry.key, sha256: String(repeating: "c", count: 64), from: list))
        #expect(!OutsideList.dropped(key: "gone", sha256: entry.sha256, from: nil), "unread: nothing is called dropped")
    }

    /// Resume of a stopped Other Sites download (phase 6 review): only as vetted now; a list that couldn't be read is
    /// "try later", never "dropped", so the partial file isn't discarded on a false word.
    @Test func resumeDecision() throws {
        let list = try OutsideList.decode(Data(#"{"entries":[\#(Self.line)],"format":1}"#.utf8))
        let entry = list.entries[0]
        #expect(OutsideList.resume(key: entry.key, sha256: entry.sha256, list: list) == .entry(entry))
        #expect(OutsideList.resume(key: "gone", sha256: entry.sha256, list: list) == .notListed)
        #expect(OutsideList.resume(key: entry.key, sha256: entry.sha256, list: nil) == .listUnread)
    }

    @Test func outsideListUnknownFormatRefused() {
        #expect(throws: (any Error).self) { try OutsideList.decode(Data(#"{"entries":[],"format":2}"#.utf8)) }
        #expect(throws: (any Error).self) { try OutsideList.decode(Data("not json".utf8)) }
    }

    /// The Mac check build's made-up item is served from this Mac (plan 5.4's end-to-end check): http on 127.0.0.1 only,
    /// and only when the check build asks.
    @Test func loopbackOnlyForTheCheckBuild() throws {
        let local = Self.line.replacingOccurrences(of: "https://www.fema.gov/h.pdf", with: "http://127.0.0.1:8811/h.pdf")
            .replacingOccurrences(of: #""host":"www.fema.gov""#, with: #""host":"127.0.0.1""#)
        let text = Data(#"{"entries":[\#(local)],"format":1}"#.utf8)
        #expect(throws: (any Error).self) { try OutsideList.decode(text) }
        #expect(try OutsideList.decode(text, loopback: true).entries.count == 1)
        let elsewhere = Data(#"{"entries":[\#(local.replacingOccurrences(of: "127.0.0.1", with: "10.0.0.2"))],"format":1}"#.utf8)
        #expect(throws: (any Error).self) { try OutsideList.decode(elsewhere, loopback: true) }
    }

    @Test func outsideListBadEntryRefused() {
        for (old, new) in [("https://www.fema.gov/h.pdf", "http://www.fema.gov/h.pdf"),
                           (#""host":"www.fema.gov""#, #""host":"www.cdc.gov""#),
                           ("sample-handbook", "../escape"), (#""kind":"pdf""#, #""kind":"exe""#),
                           (#""size":10"#, #""size":0"#), (String(repeating: "b", count: 64), "b")] {
            let text = #"{"entries":[\#(Self.line.replacingOccurrences(of: old, with: new))],"format":1}"#
            #expect(throws: (any Error).self, "\(new)") { try OutsideList.decode(Data(text.utf8)) }
        }
    }
}
