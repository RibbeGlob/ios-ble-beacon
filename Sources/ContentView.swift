import SwiftUI

struct ContentView: View {
    @StateObject private var beacon = BeaconMonitor.shared
    @StateObject private var ble = BleClient.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("iBeacon → Auto BLE write")
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
                    Text("Krok 1: Skanuj i sparuj")
                        .font(.headline)

                    Text("Będąc przy urządzeniu kliknij poniżej. Appka zeskanuje po 0xFFF0, połączy się i zapamięta identyfikator urządzenia (zamiast MAC).")
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
                    Text("Krok 2: Włącz monitoring iBeacon")
                        .font(.headline)

                    Text("Po wejściu w zasięg iBeacona aplikacja automatycznie połączy się z zapamiętanym urządzeniem i wyśle \"test\" do charakterystyki 0x5678.")
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
