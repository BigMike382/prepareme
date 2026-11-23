import Foundation

/// Our Home pages in the app (docs/plans/2026-11-16-our-home.md, Task 2.6; phase D's picks): the screen kept awake
/// while one is on a step, and the link `prepareme://home/<page name>` (a label's QR code, a Shortcut's Open URL),
/// which opens that page of the daily library at its start screen, or the section's own page for any other name.
public enum HomeLinks {
    public static let host = "home"
    /// The Our Home section's page in the daily library (packer/steps.py's BACK_HOME_PAGE, through HomePage's words)
    public static var section: String { HomePage.word("BACK_HOME_PAGE") }

    /// Whether the shown address keeps the phone from locking by itself: a page of the daily library on one of its
    /// steps (`#step-N`, the address only an Our Home page's script uses), never its start or end screen or any other page.
    public static func keepsAwake(_ url: URL?, dailyID: UUID?) -> Bool {
        guard let url, let dailyID, url.scheme == "zim", UUID(uuidString: url.host ?? "") == dailyID,
              let fragment = url.fragment else { return false }
        return GuideTopics.matches(fragment, "step-[1-9][0-9]?")
    }

    /// Whether `name` is an Our Home page's: a starter, or one the Mac named `house-…` (never a guide's id).
    public static func isHomeName(_ name: String) -> Bool {
        HouseholdPage.starterNames.contains(name) || GuideTopics.matches(name, "house-[a-z0-9]+")
    }

    /// Whether `url` shows an Our Home page of the daily library, on any of its screens (the Mac's sidebar marks Our
    /// Home then).
    public static func isHomePage(_ url: URL?, dailyID: UUID?) -> Bool {
        guard let url, let dailyID, url.scheme == "zim", UUID(uuidString: url.host ?? "") == dailyID,
              url.pathExtension == "html" else { return false }
        return isHomeName(url.deletingPathExtension().lastPathComponent)
    }

    /// The page `prepareme://home/<name>` opens in the daily library: "<name>.html" for an Our Home page's name (a
    /// starter, or a page the Mac named `house-…`), the section's page for anything else (a guide's id, a path, an
    /// empty name), nil when it isn't this link. The page's own existence is the caller's to check.
    public static func page(_ url: URL) -> String? {
        guard url.scheme == "prepareme", url.host == host else { return nil }
        let name = String(url.path.dropFirst())  // the path, percent-decoded: a "/" inside a name stays a "/"
        return isHomeName(name) ? "\(name).html" : section
    }
}
