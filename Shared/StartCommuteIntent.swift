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
