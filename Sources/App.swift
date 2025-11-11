import SwiftUI

@main
struct BLEBeaconApp: App {
    init() {
        // Poproś o powiadomienia na starcie
        Notifications.requestPermission()

        // Upewnij się, że BleClient jest zainicjalizowany (central, logger itd.)
        _ = BleClient.shared

        // Start monitoringu beacona od razu
        BeaconMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
