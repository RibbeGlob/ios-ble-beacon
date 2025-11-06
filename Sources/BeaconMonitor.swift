import Foundation
import CoreLocation
import UserNotifications
import UIKit

final class BeaconMonitor: NSObject, ObservableObject {
    static let shared = BeaconMonitor()

    @Published var status = "idle"

    private let manager = CLLocationManager()

    // ← PODMIEŃ na swój UUID/major/minor
    private let uuid = UUID(uuidString: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")!
    private lazy var region = CLBeaconRegion(
        uuid: uuid,
        major: 1, minor: 1,
        identifier: "ibeacon-target"
    )

    func start() {
        manager.delegate = self

        // 1) Jeśli brak decyzji → poproś WhenInUse, potem Always
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            status = "request WhenInUse"
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            status = "request Always"
        case .authorizedAlways:
            startMonitoring()
        case .denied, .restricted:
            status = "location denied/restricted — otwórz Ustawienia"
        @unknown default:
            status = "location unknown"
        }
    }

    private func startMonitoring() {
        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true

        manager.startMonitoring(for: region)
        manager.requestState(for: region)

        status = "monitoring \(region.identifier)"
        print("[BeaconMonitor] Monitoring started")
    }

    private func notify(_ title: String, _ body: String) {
        Notifications.send(title, body)
    }
}

extension BeaconMonitor: CLLocationManagerDelegate {

    @MainActor
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            startMonitoring()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            self.status = "request Always"
        case .denied, .restricted:
            self.status = "location denied/restricted"
        case .notDetermined:
            self.status = "request WhenInUse"
        @unknown default:
            self.status = "auth unknown"
        }
    }

    @MainActor
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }
        self.status = "didEnterRegion"
        notify("iBeacon", "Weszliśmy w zasięg beacona 🎉")

        // (opcjonalnie) krótki background task, jeśli kiedyś dodasz BLE:
        // var bg = UIBackgroundTaskIdentifier.invalid
        // bg = UIApplication.shared.beginBackgroundTask(withName: "ibeacon-enter") { UIApplication.shared.endBackgroundTask(bg) }
        // ... zrób szybkie działania ...
        // DispatchQueue.main.asyncAfter(deadline: .now() + 8) { UIApplication.shared.endBackgroundTask(bg) }
    }

    @MainActor
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }
        self.status = "didExitRegion"
        notify("iBeacon", "Opuściliśmy zasięg beacona")
    }

    @MainActor
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        switch state {
        case .inside:  self.status = "state: inside"
        case .outside: self.status = "state: outside"
        case .unknown: self.status = "state: unknown"
        @unknown default: self.status = "state: ?"
        }
    }

    // Dla czytelniejszych błędów (np. brak Always)
    @MainActor
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        self.status = "monitoring fail: \(error.localizedDescription)"
    }
}
