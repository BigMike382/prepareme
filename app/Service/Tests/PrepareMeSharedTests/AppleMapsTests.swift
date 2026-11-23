import Foundation
import Testing
@testable import PrepareMeShared

/// The hand-off plan, 3.1: Apple Maps' link in Apple's unified form, pinned as OrganicMaps.url is. Made-up places in
/// Washington, DC.
struct AppleMapsTests {
    @Test func aRouteFromHereNamesBothEndsAndTheMode() throws {
        let drive = try #require(AppleMaps.url(from: (38.8951, -77.0364), to: (38.8899, -77.009), travel: .drive))
        let expected = "https://maps.apple.com/directions?source=38.895100,-77.036400"
            + "&destination=38.889900,-77.009000&mode=driving"
        #expect(drive.absoluteString == expected)
        let walk = try #require(AppleMaps.url(from: (1, 2), to: (3, 4), travel: .walk))
        #expect(walk.absoluteString.hasSuffix("&mode=walking"))
    }

    @Test func withoutAFreshFixAppleMapsStartsWhereItFindsTheDevice() throws {
        let url = try #require(AppleMaps.url(from: nil, to: (38.8899, -77.009), travel: .walk))
        #expect(url.absoluteString == "https://maps.apple.com/directions?destination=38.889900,-77.009000&mode=walking")
        let offGlobe = try #require(AppleMaps.url(from: (95, 0), to: (3, 4), travel: .drive))
        #expect(!offGlobe.absoluteString.contains("source"))
        #expect(AppleMaps.url(from: nil, to: (95, 0), travel: .drive) == nil)
    }

    /// Apple Maps routes only to the road nearest a spot, online or offline (the owner's check, 2026-10-30: Organic Maps
    /// reached a pin in a field, Apple Maps stopped at the road's end), so its buttons say so (owner, by click).
    @Test func theButtonsSayItStopsAtTheRoad() {
        #expect(AppleMaps.inAppleMaps == "In Apple Maps (to the nearest road)")
        #expect(AppleMaps.openInAppleMaps == "Open in Apple Maps (to the nearest road)")
    }

    @Test func theInstalledLine() {
        #expect(OrganicMaps.installedWords(true, device: "phone") == "Directions: Organic Maps is on this phone.")
        let missing = "Directions: Organic Maps isn't on this iPad. " + OrganicMaps.installLine
        #expect(OrganicMaps.installedWords(false, device: "iPad") == missing)
    }
}
