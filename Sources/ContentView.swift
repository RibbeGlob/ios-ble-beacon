import SwiftUI

struct ContentView: View {
    @StateObject private var beacon = BeaconMonitor.shared
    @StateObject private var ble = BleClient.shared

    var body: some View {
        VStack(spacing: 14) {
            Text("iBeacon → BLE GATT").font(.headline)
            Text("Beacon: \(beacon.status)")
            Text("BLE: \(ble.stateText)")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Rozpocznij krótkie skanowanie BLE") {
                ble.shortScanAndConnect()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .padding()
        .onAppear { beacon.start() }
    }
}
