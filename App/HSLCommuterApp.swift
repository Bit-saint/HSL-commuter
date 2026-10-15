import SwiftUI
import UserNotifications
import ETAEngine

@main
struct HSLCommuterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(HSLColorTint.primary)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await model.handlePendingStart()
                await LeaveReminderScheduler.refresh(app: model)
            }
        }
        .backgroundTask(.appRefresh(LeaveReminderScheduler.refreshTaskID)) {
            await LeaveReminderScheduler.refresh(app: AppModel.shared)
        }
    }
}

enum HSLColorTint {
    static let primary = Color(red: 0, green: 122 / 255, blue: 201 / 255)
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Show alerts while the app is open too (e.g. "Run!" with the phone in hand).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.categoryIdentifier == NotificationService.reminderCategory {
            SharedStore.defaults.set(Date().timeIntervalSince1970, forKey: SharedStore.pendingStartKey)
            await AppModel.shared.handlePendingStart()
        }
    }
}

extension AppModel {
    static let shared = AppModel()

    /// Starts tracking the best option when launched from the widget, a reminder or Siri.
    func handlePendingStart() async {
        let stamp = SharedStore.defaults.double(forKey: SharedStore.pendingStartKey)
        guard stamp > 0, Date().timeIntervalSince1970 - stamp < 180 else { return }
        SharedStore.defaults.removeObject(forKey: SharedStore.pendingStartKey)
        guard session == nil, let commute = suggestedCommute() else { return }
        let origin = await location.currentLocation().map { GeoPoint($0.coordinate) }
        guard let best = try? await Planner.options(for: commute, app: self, from: origin).first else { return }
        startSession(itinerary: best.itinerary, destinationName: commute.destination.name)
    }
}
