import Foundation

/// A button's spoken name holds the word shown on it (look 3, spec section 8, fix 10; plan Task 4.4), so VoiceOver says
/// what the screen shows and Voice Control's "tap Find me" finds it. A longer label that already holds the word stays;
/// one that doesn't gives way to the word and is kept as the hint, so nothing it said is lost.
public enum SpokenName {
    public static func of(_ label: String, word: String) -> (label: String, hint: String?) {
        label.localizedCaseInsensitiveContains(word) ? (label, nil) : (word, label)
    }
}
