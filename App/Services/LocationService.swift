import CoreLocation
import Observation
import ETAEngine

/// Permission handling and one-shot "where am I" for planning.
/// Continuous tracking during a commute uses `CLLocationUpdate.liveUpdates` in `CommuteSession`.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var authorization: CLAuthorizationStatus = .notDetermined
    var lastLocation: CLLocation?
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorization = manager.authorizationStatus
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if manager.authorizationStatus == .authorizedWhenInUse {
            // "Always" lets live tracking continue reliably with the screen locked.
            manager.requestAlwaysAuthorization()
        }
    }

    var current: GeoPoint? { lastLocation.map { GeoPoint($0.coordinate) } }

    func currentLocation() async -> CLLocation? {
        if let l = lastLocation, l.timestamp.timeIntervalSinceNow > -30 { return l }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = loc
            self.waiters.forEach { $0.resume(returning: loc) }
            self.waiters.removeAll()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.waiters.forEach { $0.resume(returning: self.lastLocation) }
            self.waiters.removeAll()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }
}
