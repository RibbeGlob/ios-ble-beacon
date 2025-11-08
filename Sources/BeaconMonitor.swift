import Foundation
import CoreLocation
import UserNotifications
import UIKit

final class BeaconMonitor: NSObject, ObservableObject {
    static let shared = BeaconMonitor()

    @Published var status: String = "idle"

    private let manager = CLLocationManager()

    // Ustaw zgodnie z konfiguracją iBeacon w urządzeniu
    private let uuid = UUID(uuidString: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")!
    private lazy var region = CLBeaconRegion(
        uuid: uuid,
        major: 1,
        minor: 1,
        identifier: "ibeacon-target"
    )

    // MARK: - Public API

    func start() {
        manager.delegate = self
        requestNotificationPermissionIfNeeded()

        guard CLLocationManager.locationServicesEnabled() else {
            update("location services disabled — włącz w Ustawieniach")
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            update("request WhenInUse")
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            update("request Always")
        case .authorizedAlways:
            startMonitoring()
        case .denied, .restricted:
            update("location denied/restricted — otwórz Ustawienia")
        @unknown default:
            update("location unknown")
        }
    }

    func stop() {
        manager.stopMonitoring(for: region)
        update("stopped monitoring \(region.identifier)")
    }

    func refreshState() {
        manager.requestState(for: region)
    }

    // MARK: - Private

    private func startMonitoring() {
        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true

        manager.startMonitoring(for: region)
        manager.requestState(for: region)

        update("monitoring \(region.identifier)")
        print("[BeaconMonitor] Monitoring started")
    }

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: c,
                trigger: nil
            )
        )
    }

    private func update(_ text: String) {
        if Thread.isMainThread {
            self.status = text
        } else {
            DispatchQueue.main.async { self.status = text }
        }
        print("[BeaconMonitor] \(text)")
    }
}

// MARK: - CLLocationManagerDelegate
extension BeaconMonitor: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager,
                         didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            switch status {
            case .authorizedAlways:
                self.startMonitoring()
            case .authorizedWhenInUse:
                manager.requestAlwaysAuthorization()
                self.update("request Always")
            case .denied, .restricted:
                self.update("location denied/restricted")
            case .notDetermined:
                self.update("request WhenInUse")
            @unknown default:
                self.update("auth unknown")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didStartMonitoringFor region: CLRegion) {
        manager.requestState(for: region)
    }

    func locationManager(_ manager: CLLocationManager,
                         didEnterRegion region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }
        update("didEnterRegion")
        notify("iBeacon", "Weszliśmy w zasięg beacona 🎉")

        // 🔽 DOKŁADNIE TA SAMA LOGIKA CO PRZYCISK "Skanuj i sparuj urządzenie BLE"
        BleClient.shared.initialPairingScan()
    }

    func locationManager(_ manager: CLLocationManager,
                         didExitRegion region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }
        update("didExitRegion")
        notify("iBeacon", "Opuściliśmy zasięg beacona")
    }

    func locationManager(_ manager: CLLocationManager,
                         didDetermineState state: CLRegionState,
                         for region: CLRegion) {
        let txt: String = {
            switch state {
            case .inside:  return "state: inside"
            case .outside: return "state: outside"
            case .unknown: return "state: unknown"
            @unknown default: return "state: ?"
            }
        }()
        update(txt)
    }

    func locationManager(_ manager: CLLocationManager,
                         monitoringDidFailFor region: CLRegion?,
                         withError error: Error) {
        update("monitoring fail: \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        update("location error: \(error.localizedDescription)")
    }
}
