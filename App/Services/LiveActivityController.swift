import ActivityKit
import Foundation

/// Starts, updates and ends the commute Live Activity. Updates are local (no push server):
/// the app keeps running during a commute thanks to the background location session.
@MainActor
final class LiveActivityController {
    private var activity: Activity<CommuteActivityAttributes>?
    private var lastState: CommuteActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(destination: String, state: CommuteActivityAttributes.ContentState) {
        guard isAvailable else { return }
        // Only one commute activity at a time.
        for a in Activity<CommuteActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        let attributes = CommuteActivityAttributes(destinationName: destination, startedAt: Date())
        activity = try? Activity.request(attributes: attributes,
                                         content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(180)),
                                         pushType: nil)
        lastState = state
        lastUpdate = Date()
    }

    /// Pushes a new state when something visible changed. The countdown itself ticks on its own
    /// via `Text(timerInterval:)`, so we don't need per-second updates.
    func update(_ state: CommuteActivityAttributes.ContentState, alert: (title: String, body: String)? = nil) {
        guard let activity else { return }
        let now = Date()
        let significant = lastState.map { old in
            old.phase != state.phase || old.pace != state.pace || old.line != state.line ||
                abs(old.eta.timeIntervalSince(state.eta)) >= 20 || old.stopName != state.stopName ||
                old.transferNote != state.transferNote || old.nextStopName != state.nextStopName ||
                abs(old.progress - state.progress) > 0.05
        } ?? true
        guard significant || alert != nil || now.timeIntervalSince(lastUpdate) > 60 else { return }
        lastState = state
        lastUpdate = now
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(180))
        let alertConfig = alert.map {
            AlertConfiguration(title: LocalizedStringResource(stringLiteral: $0.title),
                               body: LocalizedStringResource(stringLiteral: $0.body), sound: .default)
        }
        Task { await activity.update(content, alertConfiguration: alertConfig) }
    }

    func end(final state: CommuteActivityAttributes.ContentState?) {
        guard let activity else { return }
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(120))) }
        self.activity = nil
        lastState = nil
    }
}
