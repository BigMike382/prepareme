import Foundation

/// The words of the phone's empty and error screens that look 3 gave a next step (spec section 10, rule 2; plan Task
/// 4.2), with the words they sit beside, moved here from the screens so a test holds them (`StateWordsTests`).
public enum StateWords {
    /// The welcome once paired: Home Mac, not "the Home Mac tab", since on an adult's iPhone it is a button.
    public static let welcomePaired = "The library comes from the Mac at home, over Wi-Fi. Downloads shows how far it "
        + "has got."
    public static let openHomeMac = "Open Downloads"

    /// A camera turned off for PrepareMe (Settings › Privacy › Camera, or the app's own page), told apart from one
    /// that can't read codes, with the way to turn it on.
    public static let cameraOff = "The camera is turned off for PrepareMe."
    public static let cameraTurnOn = "Turn on Camera in PrepareMe's settings to scan."
    public static let openSettings = "Open Settings"
    public static let cantReadCodes = "This device's camera can't read codes here."
    public static let cantReadDates = "This device's camera can't read dates here."
    public static let cantReadPairing = "The camera can't read codes here; paste the code instead."

    /// The camera's permission as the phone reports it (AVFoundation's authorization status, mapped by the screen).
    public enum Camera: Sendable { case allowed, notAsked, denied, restricted }

    public static func cameraIsOff(_ camera: Camera) -> Bool { camera == .denied || camera == .restricted }

    /// A bin label for a bin the phone's copy doesn't hold, from the scanner or a bin label's link: where to go.
    public static func binNotInCopy(device: String) -> String {
        "That bin isn't in this \(device)'s copy of the inventory yet. Open Inventory at home once to bring it up to date."
    }

    /// The Mac's Event mode row before the lists job's lists are read (look 3, spec section 9): shown grayed with why.
    public static let eventModeWaiting = "Shows once the lists are read"

    /// The Mac's Inventory with no inventory file yet (spec section 10, rule 6): plain words, no tool or file named.
    public static let noInventoryYet = "There's no inventory on this Mac yet. Once there is, you add and change items here."
}

/// Where "Open Home Mac" goes (look 3 phase 0, question 7: choosing a tab that isn't in the bar showed Today): Home
/// Mac's sheet where it is a button in each tab's bar (an adult's iPhone), else its tab.
public enum HomeMacRoute: Equatable, Sendable {
    case sheet, tab

    public static func opens(inBar: Bool) -> HomeMacRoute { inBar ? .sheet : .tab }
}
