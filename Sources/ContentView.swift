import SwiftUI

struct ContentView: View {
    @StateObject private var beacon = BeaconMonitor.shared
    @StateObject private var ble = BleClient.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("iBeacon → Auto scan & pair")
                    .font(.title3)
                    .padding(.top, 12)

                Text("Beacon status: \(beacon.status)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("BLE status: \(ble.stateText)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Divider().padding(.vertical, 4)

                VStack(spacing: 8) {
                    Text("Ręcznie: Skanuj i sparuj")
                        .font(.headline)

                    Text("Kliknięcie poniżej uruchamia skan po 0xFFF0, łączy z urządzeniem, zapisuje identyfikator i wysyła \"test\" do 0x5678.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("🔗 Skanuj i sparuj urządzenie BLE") {
                        ble.initialPairingScan()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)

                Divider().padding(.vertical, 4)

                VStack(spacing: 8) {
                    Text("Automatycznie po iBeaconie")
                        .font(.headline)

                    Text("Po włączeniu monitoringu, wejście w zasięg iBeacona wywoła dokładnie tę samą logikę, co przycisk powyżej (scan+connect+write).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("📡 Uruchom monitoring iBeacon") {
                        BeaconMonitor.shared.start()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 20)
            }
            .padding(.bottom, 20)
        }
    }
}
