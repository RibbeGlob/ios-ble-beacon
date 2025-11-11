import Foundation
import CoreLocation
import UserNotifications
import UIKit

final class BeaconMonitor: NSObject, ObservableObject {
    static let shared = BeaconMonitor()

    @Published var status: String = "idle"

    private let manager = CLLocationManager()

    private let uuid = UUID(uuidString: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")!
    private lazy var region = CLBeaconRegion(
        uuid: uuid,
        major: 1,
        minor: 1,
        identifier: "ibeacon-target"
    )

    // ID dla cyklicznego powiadomienia "jesteś w strefie"
    private let periodicNotificationId = "ibeacon-periodic-notification"

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
        cancelPeriodicInsideNotifications()
        update("stopped monitoring \(region.identifier)")
    }

    func refreshState() {
        manager.requestState(for: region)
        update("requestState for \(region.identifier)")
    }

    // MARK: - Private

    private func startMonitoring() {
        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true

        manager.startMonitoring(for: region)
        manager.requestState(for: region)

        update("monitoring \(region.identifier)")
    }

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    // Jednorazowe powiadomienie (wejście/wyjście)
    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body

        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: c,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(req)
    }

    /// Cykliczne powiadomienie co 60s gdy jesteśmy "inside"
    private func schedulePeriodicInsideNotifications() {
        let center = UNUserNotificationCenter.current()

        // wyczyść poprzednie, żeby nie duplikować
        center.removePendingNotificationRequests(withIdentifiers: [periodicNotificationId])

        let content = UNMutableNotificationContent()
        content.title = "iBeacon"
        content.body = "Jesteś w zasięgu. Stuknij, aby zsynchronizować urządzenie."
        content.sound = .default

        // min. 60 sekund dla repeats = true
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: true)

        let request = UNNotificationRequest(
            identifier: periodicNotificationId,
            content: content,
            trigger: trigger
        )

        center.add(request) { [weak self] error in
            if let error = error {
                self?.update("schedulePeriodicInsideNotifications error: \(error.localizedDescription)")
            } else {
                self?.update("schedulePeriodicInsideNotifications: co 60s, while inside")
            }
        }
    }

    /// Kasujemy powtarzające się powiadomienia gdy wychodzimy ze strefy
    private func cancelPeriodicInsideNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [periodicNotificationId])
        center.removeDeliveredNotifications(withIdentifiers: [periodicNotificationId])
        update("cancelPeriodicInsideNotifications")
    }

    private func update(_ text: String) {
        if Thread.isMainThread {
            self.status = text
        } else {
            DispatchQueue.main.async { self.status = text }
        }
        DebugLog.shared.add("BEACON", text)
    }
}

// MARK: - CLLocationManagerDelegate

extension BeaconMonitor: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager,
                         didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            switch status {
            case .authorizedAlways:
                self.update("auth: Always — startMonitoring")
                self.startMonitoring()
            case .authorizedWhenInUse:
                self.update("auth: WhenInUse — request Always")
                manager.requestAlwaysAuthorization()
            case .denied, .restricted:
                self.update("location denied/restricted")
                self.cancelPeriodicInsideNotifications()
            case .notDetermined:
                self.update("request WhenInUse")
            @unknown default:
                self.update("auth unknown")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didStartMonitoringFor region: CLRegion) {
        update("didStartMonitoringFor \(region.identifier)")
        manager.requestState(for: region)
    }

    func locationManager(_ manager: CLLocationManager,
                         didEnterRegion region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }
        update("didEnterRegion")
        notify("iBeacon", "Weszliśmy w zasięg beacona 🎉")

        // Spróbuj od razu podłączyć po iBeaconie (Twoja obecna logika)
        BleClient.shared.autoConnectFromBeacon(reason: "didEnterRegion")

        // I włącz cykliczne powiadomienia co 60s, dopóki jesteśmy inside
        schedulePeriodicInsideNotifications()
    }

    func locationManager(_ manager: CLLocationManager,
                         didExitRegion region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }
        update("didExitRegion")
        notify("iBeacon", "Opuściliśmy zasięg beacona")

        // Po wyjściu ze strefy nie spamujemy już powiadomieniami
        cancelPeriodicInsideNotifications()
    }

    func locationManager(_ manager: CLLocationManager,
                         didDetermineState state: CLRegionState,
                         for region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }

        let txt: String = {
            switch state {
            case .inside:  return "state: inside"
            case .outside: return "state: outside"
            case .unknown: return "state: unknown"
            @unknown default: return "state: ?"
            }
        }()
        update(txt)

        switch state {
        case .inside:
            // Jeśli appka startuje już w środku regionu:
            // - spróbuj auto-connect
            // - i ustaw cykliczne powiadomienia
            BleClient.shared.autoConnectFromBeacon(reason: "didDetermineStateInside")
            schedulePeriodicInsideNotifications()
        case .outside, .unknown:
            cancelPeriodicInsideNotifications()
        @unknown default:
            break
        }
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
