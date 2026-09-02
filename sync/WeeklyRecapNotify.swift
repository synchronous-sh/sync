import Foundation
import UserNotifications

enum WeeklyRecapNotify {
    static let requestID = "sync.weekly-recap"
    static let enabledKey = "weeklyRecapEnabled"

    static func apply(enabled: Bool, saveCount: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        guard enabled else { return }

        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Your week in sync"
            if saveCount == 0 {
                content.body = "A quiet recap of what you saved is waiting."
            } else {
                content.body = "\(saveCount) saves in your library. Open sync to see what stood out."
            }
            content.sound = .default

            var date = DateComponents()
            date.weekday = 1
            date.hour = 10
            date.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
            let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    static func sendPreview(saveCount: Int) {
        let center = UNUserNotificationCenter.current()
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            let content = UNMutableNotificationContent()
            content.title = "Your week in sync"
            content.body = saveCount == 0
                ? "A quiet recap of what you saved is waiting."
                : "\(saveCount) saves in your library. Here’s a look at the week."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(requestID).preview",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }
}
