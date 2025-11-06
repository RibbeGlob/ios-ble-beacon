import SwiftUI

@main
struct BLEBeaconApp: App {
    init() {
        // Poproś o powiadomienia na starcie (możesz też przenieść na przycisk)
        Notifications.requestPermission()

        // Start monitoringu beacona od razu (możesz też zrobić to z przycisku)
        BeaconMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
