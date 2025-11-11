import Foundation
import UserNotifications

enum Notifications {
    static func requestPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func send(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil),
                 withCompletionHandler: nil)
    }
}

final class NotificationsDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationsDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {

        // Możesz rozpoznać po identifierze, czy to nasze beaconowe powtarzane
        if response.notification.request.identifier == "ibeacon-periodic-notification" {
            // po tapnięciu spróbuj od razu połączyć z urządzeniem
            BleClient.shared.autoConnectFromBeacon(reason: "notif-tap")
        }

        completionHandler()
    }
}