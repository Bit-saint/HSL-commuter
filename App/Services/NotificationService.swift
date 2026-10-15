import UserNotifications

/// Local notifications for "leave now", "run", "connection at risk" etc.
/// Time-sensitive delivery needs the Time Sensitive Notifications capability
/// (see README; remove it if your signing team can't use it, alerts still work).
@MainActor
final class NotificationService {
    static let reminderCategory = "COMMUTE_REMINDER"
    static let startAction = "START_TRACKING"

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        let start = UNNotificationAction(identifier: Self.startAction, title: "Start live tracking", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.reminderCategory, actions: [start], intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    func post(id: String, title: String, body: String, timeSensitive: Bool = true, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = timeSensitive ? .timeSensitive : .active
        if let category { content.categoryIdentifier = category }
        // Same id replaces the previous alert instead of stacking.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func schedule(id: String, at date: Date, title: String, body: String, category: String? = nil) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        if let category { content.categoryIdentifier = category }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(prefix: String) async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
    }
}
