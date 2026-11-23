import Foundation

/// The phone's location ask and its refusal (remaining-findings plan, Task 11.3; F25, F66; owner, 2026-10-18, by click:
/// a one-line why before the first ask). The system's question comes only from the street map, under its why line (Use
/// my location, or Find me); the live conditions never ask, so it no longer pops up on another screen. (Kiwix's own
/// location for a library page that asks the browser can still ask, in iOS's words only; none of PrepareMe's pages do.) A refusal
/// offers Settings, on the line and when Find me is tapped. The Mac keeps its own ask and words (Position.macLocationOff).
public enum LocationAsk {
    /// PrepareMe's location permission, from the system's answer.
    public enum Status: Sendable { case notAsked, refused, allowed }

    /// What the location line offers: the system's question, the way to Settings, or nothing.
    public enum Offer: Equatable, Sendable { case ask, settings, none }

    /// What Find me does while there is no fix.
    public enum WhereAmI: Equatable, Sendable { case ask, explainRefusal, wait }

    public static func offer(_ status: Status) -> Offer {
        switch status {
        case .notAsked: .ask
        case .refused: .settings
        case .allowed: .none
        }
    }

    public static func whereAmI(_ status: Status) -> WhereAmI {
        switch status {
        case .notAsked: .ask
        case .refused: .explainRefusal
        case .allowed: .wait
        }
    }

    /// The line on the street map while it has no fix.
    public static func line(_ status: Status) -> String {
        switch status {
        case .notAsked: why
        case .refused: "\(refusedTitle). \(refused)"
        case .allowed: finding
        }
    }

    public static let why = "This uses your location to show where you are on the map, and the weather there. It works with no signal."
    public static let allow = "Use my location"
    public static let refusedTitle = "Location is off for PrepareMe"
    public static let refused = "Turn it on in Settings › PrepareMe › Location to see where you are."
    public static let turnOn = "Turn on location"
    public static let finding = "Finding where you are… It works with no signal; it can take a minute outdoors."
}
