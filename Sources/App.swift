import SwiftUI

@main
struct BLEBeaconApp: App {
    init() {
        Notifications.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
