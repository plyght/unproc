import CoreLocation
import Foundation
import Synchronization
import os

/// Where photos and videos were taken, for the Photos library's location
/// metadata. The app asks for "while using" access the first time the camera
/// opens; the lock-screen extension never prompts and only uses access that
/// was already granted. Updates run only while the camera is on screen.
final class LocationProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = LocationProvider()

    /// A fix older than this isn't attached (you've probably moved).
    static let maxAge: TimeInterval = 300

    private let latest = Mutex<CLLocation?>(nil)
    private var manager: CLLocationManager?   // main thread only

    /// The most recent fix, if it's fresh enough to describe this shot.
    var recentLocation: CLLocation? {
        latest.withLock { location in
            guard let location, -location.timestamp.timeIntervalSinceNow < Self.maxAge else { return nil }
            return location
        }
    }

    /// Starts updates, asking for access first when `prompt` and undecided.
    func start(prompt: Bool) {
        DispatchQueue.main.async { [self] in
            let manager = self.manager ?? makeManager()
            switch manager.authorizationStatus {
            case .notDetermined:
                if prompt {
                    Log.app.notice("location: requesting when-in-use access")
                    manager.requestWhenInUseAuthorization()
                } else {
                    Log.app.info("location: undecided; not prompting here")
                }
            case .authorizedWhenInUse, .authorizedAlways:
                manager.startUpdatingLocation()
                Log.app.info("location: updating")
            case .denied, .restricted:
                Log.app.info("location: access denied/restricted; shots saved without location")
            @unknown default:
                break
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            manager?.stopUpdatingLocation()
        }
    }

    private func makeManager() -> CLLocationManager {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        self.manager = manager
        return manager
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Log.app.notice("location: authorization \(status.rawValue, privacy: .public)")
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.horizontalAccuracy >= 0 else { return }
        latest.withLock { $0 = last }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.app.error("location: \(Log.describe(error), privacy: .public)")
    }
}
