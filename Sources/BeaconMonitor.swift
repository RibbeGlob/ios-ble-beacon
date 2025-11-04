import Foundation
import CoreLocation
import UserNotifications

final class BeaconMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BeaconMonitor()

    @Published var status = "idle"
    private let manager = CLLocationManager()

    private let uuid = UUID(uuidString: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")!
    private lazy var region = CLBeaconRegion(uuid: uuid, major: 1, minor: 1, identifier: "ibeacon-target")

    func start() {
        manager.delegate = self
        // ✅ bez deprecated API
        if manager.authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        } else if manager.authorizationStatus == .authorizedAlways {
            startMonitoringIfAuthorized()
        } else {
            status = "location auth not Always"
        }
        requestLocalNotificationsIfNeeded()
    }

    private func startMonitoringIfAuthorized() {
        manager.startMonitoring(for: region)
        status = "monitoring"
        print("[BeaconMonitor] Monitoring started for region \(region.identifier)")
    }

    private func requestLocalNotificationsIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedAlways { startMonitoringIfAuthorized() }
        else { self.status = "auth=\(status.rawValue)" }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        status = "didEnterRegion"
        notify("iBeacon", "Wykryto docelowy beacon. Start krótkiego skanu BLE.")
        BleClient.shared.shortScanAndConnect()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        status = "didExitRegion"
        notify("iBeacon", "Opuszczono region beacona.")
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        self.status = "state=\(state.rawValue)"
    }
}
