import PrepareMeShared
import Testing

/// Typing an item (owner, 2026-10-30): earlier brands offered as they're typed, and a name's first letter a capital.
struct EntrySuggestionTests {
    let brands = ["Zorvex", "Quillmark", "zorvex", "Brightwell", "", "Zor Haan", " Quill-Kold ", "Crème Co"]

    @Test func earlierEntriesStartingWithWhatIsTyped() {
        #expect(PhoneEditRules.suggestions(typed: "zor", from: brands) == ["Zor Haan", "Zorvex"])
        #expect(PhoneEditRules.suggestions(typed: "QUIL", from: brands) == ["Quill-Kold", "Quillmark"])
        #expect(PhoneEditRules.suggestions(typed: "creme", from: brands) == ["Crème Co"], "accents ignored")
    }

    @Test func noneForAnEmptyBoxOrTheTextTyped() {
        #expect(PhoneEditRules.suggestions(typed: " ", from: brands).isEmpty)
        #expect(PhoneEditRules.suggestions(typed: "Brightwell", from: brands).isEmpty)
        // typed in small letters, the earlier spelling is still offered to pick
        #expect(PhoneEditRules.suggestions(typed: "brightwell", from: brands) == ["Brightwell"])
    }

    @Test func atMostTheLimit() {
        let many = (1...20).map { "Brand \($0)" }
        #expect(PhoneEditRules.suggestions(typed: "b", from: many).count == 8)
    }

    @Test func onlyTheFirstKeystrokeIsCapitalized() {
        #expect(PhoneEditRules.capitalFirst(was: "", now: "r") == "R")
        #expect(PhoneEditRules.capitalFirst(was: "", now: "R") == nil)
        #expect(PhoneEditRules.capitalFirst(was: "", now: "5") == nil)
        #expect(PhoneEditRules.capitalFirst(was: "Phone", now: "iPhone") == nil, "a small letter put back stays")
        #expect(PhoneEditRules.capitalFirst(was: "", now: "rice") == nil, "pasted or filled in: left as it came")
    }
}
