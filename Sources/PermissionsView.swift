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
                // uruchamia flow WhenInUse -> Always wewnątrz BeaconMonitor
                beacon.start()
            }
            .buttonStyle(.bordered)

            Button("3) Bluetooth (pokaże prompt przy 1. skanowaniu)") {
                ble.shortScanAndConnect()
            }
            .buttonStyle(.bordered)

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
