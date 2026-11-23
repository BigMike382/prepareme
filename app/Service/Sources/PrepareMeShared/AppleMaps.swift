import Foundation

/// Directions by hand-off to Apple Maps, beside Organic Maps (hand-off improvements plan, 3.1; owner, 2026-10-30: always
/// offered, on every device). Apple Maps is on every iPhone, iPad and Mac and routes offline on areas downloaded by hand
/// (the phone setup list). The link is Apple's unified form, `maps.apple.com/directions` with source, destination and
/// mode (developer.apple.com/documentation/mapkit/unified-map-urls, "Request directions", read 2026-10-30; iOS 18.4
/// and macOS 15.4 and later): the legacy `?daddr=` form stopped routing on recent iOS (Apple forum thread 784030).
/// Coordinates only, never a name, which Apple Maps would search for. Nothing leaves the device.
public enum AppleMaps {
    /// From `from` (latitude, longitude) when the device has a fresh fix, else from wherever Apple Maps finds it (the
    /// source left out); nil for a place off the globe.
    public static func url(from: (Double, Double)?, to: (Double, Double), travel: OrganicMaps.Travel) -> URL? {
        guard OrganicMaps.on(to) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "maps.apple.com"
        parts.path = "/directions"
        var items = [URLQueryItem]()
        if let from, OrganicMaps.on(from) { items.append(URLQueryItem(name: "source", value: OrganicMaps.point(from))) }
        items.append(URLQueryItem(name: "destination", value: OrganicMaps.point(to)))
        items.append(URLQueryItem(name: "mode", value: travel == .drive ? "driving" : "walking"))
        parts.queryItems = items
        return parts.url
    }

    /// The two ways under Drive there and Walk there. Apple Maps routes only to the road nearest a spot, online or
    /// offline (the owner's check, 2026-10-30), so its buttons say so; Organic Maps walks on to the spot itself.
    public static let inOrganicMaps = "In Organic Maps"
    public static let inAppleMaps = "In Apple Maps (to the nearest road)"
    /// The missing-app alert's button beside Show on map.
    public static let openInAppleMaps = "Open in Apple Maps (to the nearest road)"
    /// Under a pin card's More (the map pins plan): Drive and Walk go to Organic Maps, Apple Maps one step in.
    public static let driveInAppleMaps = "Drive in Apple Maps (to the nearest road)"
    public static let walkInAppleMaps = "Walk in Apple Maps (to the nearest road)"
}
