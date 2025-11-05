// Sources/PermissionsView.swift
import SwiftUI
import CoreLocation
import CoreBluetooth
import UserNotifications

struct PermissionsView: View {
    @State private var lpmOn = ProcessInfo.processInfo.isLowPowerModeEnabled
    @StateObject private var beacon = BeaconMonitor.shared
    @StateObject private var ble = BleClient.shared

    // Diagnostyka powiadomień
    @State private var notifStatusText = "Notifications: …"
    // Żeby nie inicjować BT promptu wielokrotnie
    @State private var askedBluetoothOnce = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Wymagane zgody")
                    .font(.title3).bold()

                // 1) Powiadomienia — tylko z przycisku
                Button("1) Powiadomienia") {
                    UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                            refreshNotifStatus()
                        }
                }
                .buttonStyle(.borderedProminent)

                // 2) Lokalizacja — WhenInUse -> Always -> start monitoring iBeacon
                Button("2) Lokalizacja (Always → iBeacon)") {
                    BeaconMonitor.shared.start()
                }
                .buttonStyle(.bordered)

                // 3) Bluetooth — miękki prompt (inicjalizacja tylko centrale, bez skanu)
                Button("3) Bluetooth (tylko prompt)") {
                    BleClient.shared.requestBluetoothPermissionOnly()
                }
                .buttonStyle(.bordered)

                // 4) Faktyczne skanowanie/połączenie
                Button("4) Krótkie skanowanie BLE") {
                    BleClient.shared.shortScanAndConnect()
                }
                .buttonStyle(.borderedProminent)

                if lpmOn {
                    Text("Masz włączony Tryb niskiego zużycia energii.\nWyłącz w Ustawienia → Bateria dla lepszej pracy w tle.")
                        .font(.footnote)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }

                Divider().padding(.vertical, 6)

                // STATUSY – szybka diagnostyka
                VStack(alignment: .leading, spacing: 6) {
                    Text("Statusy").font(.subheadline).bold()
                    Text("Location: \(locationStatusString)")
                    Text("Bluetooth: \(ble.btAuthStatus)")
                    Text(notifStatusText)
                    Text("Beacon: \(beacon.status)")
                    Text("BLE: \(ble.stateText)")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Otwórz ustawienia aplikacji") {
                    openAppSettings()
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .onAppear {
            // BT prompt na starcie ekranu – tylko raz
            if !askedBluetoothOnce {
                askedBluetoothOnce = true
                BleClient.shared.requestBluetoothPermissionOnly()
            }
            refreshNotifStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lpmOn = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    // MARK: - Helpers

    private var locationStatusString: String {
        let st = CLLocationManager().authorizationStatus
        switch st {
        case .notDetermined:         return "notDetermined"
        case .restricted:            return "restricted"
        case .denied:                return "denied"
        case .authorizedAlways:      return "authorizedAlways"
        case .authorizedWhenInUse:   return "authorizedWhenInUse"
        @unknown default:            return "unknown"
        }
    }

    private func refreshNotifStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let txt: String
            switch s.authorizationStatus {
            case .notDetermined: txt = "Notifications: notDetermined"
            case .denied:        txt = "Notifications: denied"
            case .authorized:    txt = "Notifications: authorized"
            case .provisional:   txt = "Notifications: provisional"
            case .ephemeral:     txt = "Notifications: ephemeral"
            @unknown default:    txt = "Notifications: unknown"
            }
            DispatchQueue.main.async { self.notifStatusText = txt }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}
