import SwiftUI

struct ContentView: View {
    @StateObject private var beacon = BeaconMonitor.shared
    @StateObject private var ble = BleClient.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("iBeacon → BLE GATT demo")
                    .font(.title2)
                    .padding(.top, 12)

                // Statusy
                VStack(spacing: 4) {
                    Text("Beacon status: \(beacon.status)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Text("BLE status: \(ble.stateText)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                Divider().padding(.vertical, 4)

                // 1) Pierwsze podłączenie / sparowanie
                VStack(spacing: 8) {
                    Text("Krok 1: Pierwsze podłączenie")
                        .font(.headline)

                    Text("Będąc przy urządzeniu, uruchom skan, aby appka znalazła je po usłudze 0x1234 i zapamiętała jego identyfikator. To jest iOS-owy odpowiednik zapamiętania MAC.")
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

                // 2) Monitoring iBeacon
                VStack(spacing: 8) {
                    Text("Krok 2: Monitoring iBeacon")
                        .font(.headline)

                    Text("Po sparowaniu, włącz monitoring iBeacon. Po wejściu w region appka spróbuje połączyć się z zapamiętanym urządzeniem i zapisać \"test\" do charakterystyki 0x5678.")
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
