import Foundation
import CoreLocation
import UserNotifications

final class BeaconMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BeaconMonitor()

    @Published var status = "idle"
    private let manager = CLLocationManager()

    // iBeacon docelowy (jak w Androidzie)
    private let uuid = UUID(uuidString: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")!
    private lazy var region = CLBeaconRegion(uuid: uuid, major: 1, minor: 1, identifier: "ibeacon-target")

    // MARK: - Public
    func start() {
        manager.delegate = self
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            startMonitoringIfAuthorized()
        default:
            status = "location auth not Always"
        }
        requestLocalNotificationsIfNeeded()
    }

    // MARK: - Private
    private func startMonitoringIfAuthorized() {
        // Monitoring (budzenie w tle na enter/exit)
        manager.startMonitoring(for: region)
        status = "monitoring"
        log("Monitoring started for region \(region.identifier)")
    }

    private func requestLocalNotificationsIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func log(_ msg: String) {
        print("[BeaconMonitor] \(msg)")
    }

    // MARK: - CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedAlways {
            startMonitoringIfAuthorized()
        } else {
            self.status = "auth=\(status.rawValue)"
            log("Authorization changed: \(status.rawValue)")
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        status = "didEnterRegion"
        log("didEnterRegion → triggering short BLE scan")
        notify("iBeacon", "Wykryto docelowy beacon. Start krótkiego skanu BLE.")
        BleClient.shared.shortScanAndConnect()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        status = "didExitRegion"
        log("didExitRegion")
        notify("iBeacon", "Opuszczono region beacona.")
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        self.status = "state=\(state.rawValue)"
        log("didDetermineState=\(state.rawValue)")
    }
}
