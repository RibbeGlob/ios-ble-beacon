import Foundation
import CoreLocation
import UserNotifications
import UIKit

final class BeaconMonitor: NSObject, ObservableObject {
    static let shared = BeaconMonitor()

    @Published var status = "idle"

    private let manager = CLLocationManager()

    // TODO: PODMIEŃ na własny UUID/major/minor i identyfikator regionu
    private let uuid = UUID(uuidString: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")!
    private lazy var region = CLBeaconRegion(
        uuid: uuid,
        major: 1,
        minor: 1,
        identifier: "ibeacon-target"
    )

    func start() {
        manager.delegate = self

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
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        )
    }
}

extension BeaconMonitor: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            switch status {
            case .authorizedAlways:
                self.startMonitoring()
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
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }
        DispatchQueue.main.async { self.status = "didEnterRegion" }
        notify("iBeacon", "Weszliśmy w zasięg beacona 🎉")

        BleClient.shared.writeAfterRegionEnter(valueToWrite: Data("test".utf8))
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }
        DispatchQueue.main.async { self.status = "didExitRegion" }
        notify("iBeacon", "Opuściliśmy zasięg beacona")
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        let txt: String = {
            switch state {
            case .inside:  return "state: inside"
            case .outside: return "state: outside"
            case .unknown: return "state: unknown"
            @unknown default: return "state: ?"
            }
        }()
        DispatchQueue.main.async { self.status = txt }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        DispatchQueue.main.async { self.status = "monitoring fail: \(error.localizedDescription)" }
    }
}
