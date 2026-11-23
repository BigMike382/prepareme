// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (2026-10-28).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import CoreLocation
import Foundation
import PrepareMeShared

/// Where this Mac is, for the hourly job's "where the laptop is" (2026-10-28: in place of the "PrepareMe Location"
/// shortcut, which the owner deleted). Every 15 minutes while Location is allowed it asks for one fix to about a
/// kilometer and saves it, rounded to 2 decimals, as "Latitude,Longitude" in the requests folder's `laptop-location`
/// (dashboard/location.py reads it; over 2 hours old is unavailable there). While Location is refused it saves
/// "refused", so Today says why. It never asks: the street map's Where am I does (F25), or System Settings. The file
/// is the Mac's own, in its owner-only folder, never synced; nothing is logged.
@MainActor
final class MacLocation: NSObject, CLLocationManagerDelegate {
    static let shared = MacLocation()
    static let fileName = "laptop-location"  // dashboard/location.py's FILE
    private let manager = CLLocationManager()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { MacLocation.shared.ask() }
        }
        ask()
    }

    private func ask() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: save("refused\n")
        default: break  // not asked yet: the street map asks
        }
    }

    private func save(_ text: String) {
        guard let folder = PrepareMeMac.folders?.appendingPathComponent("requests") else { return }
        try? DurableFile.write(Data(text.utf8), to: folder.appendingPathComponent(Self.fileName))  // 0600
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.timestamp.timeIntervalSinceNow > -3600,
              CLLocationCoordinate2DIsValid(last.coordinate) else { return }
        let text = String(format: "%.2f,%.2f\n", last.coordinate.latitude, last.coordinate.longitude)
        MainActor.assumeIsolated { save(text) }
    }

    /// No fix this time: the last one saved stays, and goes stale on the page after 2 hours
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}

    /// Allowed or refused (the street map's question, or System Settings): saved at once, not at the next quarter hour
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { ask() }
    }
}
#endif
