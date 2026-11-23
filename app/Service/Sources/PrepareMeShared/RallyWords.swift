/// The rally view's fixed words (the beta run's F04; owner, 2026-10-16: rally points show even when the street map file
/// isn't on the phone, since they come with the inventory).
public enum RallyWords {
    /// Under the rally point, when the map file itself isn't on this phone (`device`: "iPad" on an iPad, ThisDevice).
    public static func mapNotHere(device: String = "phone") -> String {
        "The map itself isn't on this \(device). Get it at home under Downloads."
    }

    /// What the phone knows about itself: a phone with no copy of the Mac's lists yet hasn't been told its rally points
    /// or whether it's a child's (phase 2 review: never a child's line to an adult whose copy hasn't come).
    public enum Role: Equatable, Sendable { case adult, child, noCopy }

    public static func role(hasCopy: Bool, canEdit: Bool) -> Role {
        !hasCopy ? .noCopy : canEdit ? .adult : .child
    }

    /// With no rally point to show: a child's phone and an adult's where they're added, a phone with no copy where they
    /// come from.
    public static func noRallyPoint(_ role: Role, device: String = "phone") -> String {
        switch role {
        case .child: childNone
        case .adult: "No meeting place yet. Add one on the street map, once the map is on this \(device)."
        case .noCopy: "The meeting places haven't reached this \(device) yet. They come from the Mac, at home on Wi-Fi."
        }
    }

    /// Which street map view a phone shows (remaining-findings plan, Task 11.1; F22): no map file, the rally view for
    /// everyone; a child's phone, the rally view, or the full map once asked for, with a way back to the rally view.
    public enum Screen: Equatable, Sendable {
        case rally(Role)
        case map(backToRally: Bool)
    }

    public static let backToRally = "Back to my meeting place"

    /// The phone's strip with no meeting place (the map pins plan, fix 1): an adult's phone adds them since 2026-11-12.
    public static func noneOnMap(canEdit: Bool) -> String {
        canEdit ? "No meeting place yet. Press and hold the map to add one." : childNone
    }

    /// A device that can't add a meeting place (family downloads plan, phase 2: no "ask" line)
    static let childNone = "No meeting place yet. They are added on an adult's phone or on the Mac."

    /// The strip's lead line: "Meet at Big oak".
    public static func meetAt(_ name: String) -> String { "Meet at \(name)" }

    /// Under the planned rally point in the strip when another rally point is nearer (the street map fixes plan, task
    /// 1.3): "Nearest: Library lot, 0.4 miles northwest". Nil when the planned one is the nearest rally point. `ways`
    /// nearest first, as `Position.ways` gives them; routes don't count.
    public static func nearestLine(_ ways: [Position.Way], planned: Int64) -> String? {
        guard let nearest = ways.first(where: { $0.mark.kind == .rally }), nearest.mark.id != planned else { return nil }
        return "Nearest: \(nearest.mark.name), \(Position.distance(nearest.meters)) \(Position.compass(nearest.bearing))"
    }

    /// Under "I'm lost" while it's grey (Task 11.4; F26): why, and what to do.
    public static func lostWaits(device: String = "phone") -> String {
        "This works once the \(device) knows where it is. Go outside if you can and wait a minute."
    }

    public static func screen(hasMapFile: Bool, hasCopy: Bool, canEdit: Bool, mapAsked: Bool) -> Screen {
        let role = role(hasCopy: hasCopy, canEdit: canEdit)
        guard hasMapFile else { return .rally(role) }
        if role == .child { return mapAsked ? .map(backToRally: true) : .rally(.child) }
        return .map(backToRally: false)
    }
}
