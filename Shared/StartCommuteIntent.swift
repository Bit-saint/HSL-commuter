import AppIntents
import Foundation

/// "Start commute" from a widget, Shortcuts or Siri. Opens the app, which starts
/// live tracking (background location needs the session to begin in the foreground).
struct StartCommuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Commute"
    static let description = IntentDescription("Start live tracking for your next commute.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        SharedStore.defaults.set(Date().timeIntervalSince1970, forKey: SharedStore.pendingStartKey)
        return .result()
    }
}

/// "How full is it?" answered from the Live Activity on the Lock Screen.
/// Runs in the app process; the app installs `handler` at launch.
struct ReportOccupancyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Report How Full"
    static let isDiscoverable = false

    /// 0 = seats, 1 = standing, 2 = full
    @Parameter(title: "Level") var level: Int

    /// Set by the app target; nil in the widget extension.
    nonisolated(unsafe) static var handler: (@MainActor (Int) -> Void)?

    init() {}
    init(level: Int) { self.level = level }

    func perform() async throws -> some IntentResult {
        let level = self.level
        await MainActor.run { Self.handler?(level) }
        return .result()
    }
}
