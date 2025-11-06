// import SwiftUI

// struct ContentView: View {
//     @StateObject private var beacon = BeaconMonitor.shared
//     @StateObject private var ble = BleClient.shared

//     var body: some View {
//         ScrollView {
//             PermissionsView()          // ← nowa sekcja u góry
//                 .padding(.bottom, 12)

//             Divider().padding(.vertical, 8)

//             VStack(spacing: 14) {
//                 Text("iBeacon → BLE GATT").font(.headline)
//                 Text("Beacon: \(beacon.status)")
//                 Text("BLE: \(ble.stateText)")
//                     .foregroundColor(.secondary)
//                     .multilineTextAlignment(.center)

//                 Button("Rozpocznij krótkie skanowanie BLE") {
//                     ble.shortScanAndConnect()
//                 }
//                 .buttonStyle(.borderedProminent)
//                 .padding(.top, 6)
//             }
//             .padding(.horizontal)
//         }
//         // ważne: możesz usunąć .onAppear { beacon.start() }
//         // bo teraz wywołujesz to z przycisku w PermissionsView
//     }
// }

import SwiftUI

struct ContentView: View {
    @StateObject private var beacon = BeaconMonitor.shared

    var body: some View {
        VStack(spacing: 12) {
            Text("iBeacon Monitoring").font(.headline)
            Text("Status: \(beacon.status)")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Uruchom monitoring iBeacon") {
                BeaconMonitor.shared.start()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
