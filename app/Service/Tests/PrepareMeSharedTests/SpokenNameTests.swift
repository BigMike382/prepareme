@testable import PrepareMeShared
import Testing

/// Look 3's accessibility fixes on the phone (spec section 8; plan Task 4.4) that rest on shared words: a button's
/// spoken name holds the word under it (fix 10), so Voice Control's "tap Find me" works and VoiceOver says what the
/// screen shows; and the map's visible way to add a pin (fix 6).
struct SpokenNameTests {
    /// A label that already holds the word stays as it is, with no hint.
    @Test(arguments: [("Topo map for here", "Topo map"), ("Map Marks", "Marks"),
                      ("Red night screen", "Red night"), ("Layers", "Layers")])
    func aLabelHoldingItsWordStays(_ label: String, _ word: String) {
        let name = SpokenName.of(label, word: word)
        #expect(name.label == label)
        #expect(name.hint == nil)
    }

    /// A label that doesn't hold the word gives way to it, and is kept as the hint: nothing said before is lost.
    @Test func aLabelWithoutItsWordTakesTheWordAndKeepsItselfAsTheHint() {
        let name = SpokenName.of("Where am I", word: "Find me")
        #expect(name.label == "Find me")
        #expect(name.hint == "Where am I")
    }

    /// Matching folds case only (the words themselves are shown and spoken as written).
    @Test func matchingFoldsCase() {
        #expect(SpokenName.of("Show red night", word: "Red Night").label == "Show red night")
    }

    @Test func theMapsVisibleWayToAddAPin() {
        #expect(PersonalPins.addWhereIAm == "Add a pin where I am")
    }
}
