import Foundation

/// When a tap on the phone's street map opens "This spot" (remaining-findings plan, Task 11.2; F23; owner, 2026-10-18,
/// by click): a tap opens it only on something (a pin, a rally point, a route, a road event, a gauge), so a stray tap
/// or one to close the keyboard does nothing; a long press opens it anywhere, to drop a pin. A storm warning's shading
/// doesn't count for a tap: it covers the whole map just when the map matters most (the phase 11 review); a long press
/// still lists it.
public enum MapTap {
    /// How long a still finger is a long press, in seconds (the map's script waits this long).
    public static let longPress = 0.5

    /// The map's layer for a warning's shading (streetmap.js).
    public static let warningLayer = "pm-warning-fill"

    /// `layers`: the map's layers under the finger, one per thing found.
    public static func opensSpot(layers: [String], longPress: Bool) -> Bool {
        longPress || layers.contains { $0 != warningLayer }
    }
}
