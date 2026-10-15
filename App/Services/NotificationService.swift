import UserNotifications

/// Local notifications for "leave now", "walk faster", "connection at risk" etc.
/// Uses soft custom chimes, groups everything into one commute thread, and replaces
/// earlier alerts instead of stacking them. Time-sensitive delivery needs the
/// Time Sensitive Notifications capability (see README); alerts still work without it.
@MainActor
final class NotificationService {
    static let reminderCategory = "COMMUTE_REMINDER"
    static let startAction = "START_TRACKING"
    static let wfhAction = "WFH_TODAY"
    static let thread = "commute"

    enum Chime {
        case go, hurry, soft

        var sound: UNNotificationSound {
            switch self {
            case .go: return UNNotificationSound(named: UNNotificationSoundName("chime-go.wav"))
            case .hurry: return UNNotificationSound(named: UNNotificationSoundName("chime-hurry.wav"))
            case .soft: return UNNotificationSound(named: UNNotificationSoundName("chime-soft.wav"))
            }
        }
    }

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        let start = UNNotificationAction(identifier: Self.startAction, title: "Start live tracking", options: [.foreground])
        let wfh = UNNotificationAction(identifier: Self.wfhAction, title: "Working from home today", options: [])
        let category = UNNotificationCategory(identifier: Self.reminderCategory, actions: [start, wfh], intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    func post(id: String, title: String, body: String, sound: Chime = .go, timeSensitive: Bool = true,
              category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound.sound
        content.threadIdentifier = Self.thread
        content.interruptionLevel = timeSensitive ? .timeSensitive : .active
        content.relevanceScore = timeSensitive ? 1 : 0.4
        if let category { content.categoryIdentifier = category }
        // Same id replaces the previous alert instead of stacking.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func schedule(id: String, at date: Date, title: String, body: String, sound: Chime = .go, category: String? = nil) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound.sound
        content.threadIdentifier = Self.thread
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
