import Foundation

/// Beta run 2, B2-19 (choice a): a phone where PrepareMe was deleted and installed again forgets its pairing. The
/// pairing and the phone's role live in the Keychain, which iOS keeps when an app is deleted; the app's settings and
/// files go with it. So a marker kept in the app's settings says this install has run before: a launch without it
/// is a fresh install, whose Keychain pairing (if any) is an earlier install's and is forgotten.
///
/// An upgrade has no marker yet either, and must keep its pairing: every earlier build of the phone app set Kiwix's
/// `hasSeenCategories` setting at each launch (plan phase 4 on), and the library and inventory live in Application
/// Support › PrepareMe, so either one present means the app ran here before. Before the first unlock the Keychain
/// can't be read and neither can the settings: then nothing is decided until a later launch.
public enum InstallMarker {
    public static let key = "PrepareMe.installMarked"
    /// Settings an earlier build wrote at every launch: present means this install ran before the marker existed.
    public static let earlierKeys = ["hasSeenCategories"]

    /// The Keychain's pairing as this launch found it: none, held, or not readable yet (before the first unlock).
    public enum Pairing: Equatable, Sendable { case none, held, locked }

    public enum Step: Equatable, Sendable {
        case keep  // marked: this install has run before
        case keepAndMark  // an upgrade from a build before the marker
        case forgetAndMark  // a fresh install: an earlier install's pairing is forgotten
        case wait  // before the first unlock: decided at a later launch
    }

    public static func step(marked: Bool, earlierData: Bool, pairing: Pairing) -> Step {
        if marked { return .keep }
        if pairing == .locked { return .wait }
        return earlierData ? .keepAndMark : .forgetAndMark
    }

    public static func isMarked(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }

    /// Also set on pairing: a pairing made by this install is this install's.
    public static func mark(_ defaults: UserDefaults) { defaults.set(true, forKey: key) }

    /// At launch, before anything reads the pairing or writes a setting: the step for this launch, carried out
    /// (`forget` clears the Keychain's pairing and role), and the marker written unless it waits. `domain` is the
    /// settings' own name (the bundle ID for `.standard`): only what was saved there counts, never a registered default
    /// (Kiwix's Defaults library registers a key's default when it is first touched; fix round 1).
    @discardableResult
    public static func settle(defaults: UserDefaults, domain: String, earlierFolders: [URL], pairing: Pairing,
                              forget: () -> Void) -> Step {
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        let earlier = earlierKeys.contains { saved[$0] != nil }
            || earlierFolders.contains { FileManager.default.fileExists(atPath: $0.path) }
        let step = step(marked: isMarked(defaults), earlierData: earlier, pairing: pairing)
        switch step {
        case .keep, .wait: break
        case .keepAndMark: mark(defaults)
        case .forgetAndMark:
            forget()
            mark(defaults)
        }
        return step
    }
}
