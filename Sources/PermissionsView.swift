// Sources/PermissionsView.swift
import SwiftUI
import UserNotifications

struct PermissionsView: View {
    @State private var lpmOn = ProcessInfo.processInfo.isLowPowerModeEnabled
    @StateObject private var beacon = BeaconMonitor.shared
    @StateObject private var ble = BleClient.shared

    var body: some View {
        VStack(spacing: 14) {
            Text("Wymagane zgody").font(.title3).bold()

            Button("1) Powiadomienia") {
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
            .buttonStyle(.borderedProminent)

            Button("2) Lokalizacja (Always → iBeacon)") {
                BeaconMonitor.shared.start()   // odpali flow WhenInUse → Always
            }
            .buttonStyle(.bordered)

            Button("3) Bluetooth (tylko prompt)") {
                BleClient.shared.requestBluetoothPermissionOnly() // ⬅️ zamiast shortScanAndConnect()
            }
            .buttonStyle(.bordered)

            // Dodatkowy przycisk, gdy chcesz faktycznie zacząć skan:
            Button("4) Krótkie skanowanie BLE") {
                BleClient.shared.shortScanAndConnect()
            }
            .buttonStyle(.borderedProminent)


            if lpmOn {
                Text("Masz włączony Tryb niskiego zużycia energii.\nWyłącz w Ustawienia → Bateria dla lepszej pracy w tle.")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            // statusy pomocnicze
            Text("BT auth: \(ble.btAuthStatus)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lpmOn = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}
