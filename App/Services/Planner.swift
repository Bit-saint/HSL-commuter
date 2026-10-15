import Foundation
import BackgroundTasks
import WidgetKit
import ETAEngine
import HSLKit

/// One way to do the commute, as shown on the Today screen.
struct PlannedOption: Identifiable, Hashable {
    var itinerary: Itinerary
    /// When to leave the origin at normal pace (realtime-adjusted, with buffer).
    var leaveAt: Date
    var arrival: Date
    var firstTransit: Leg?
    var totalWait: TimeInterval

    var id: String { itinerary.id }
    var isRealtime: Bool { firstTransit?.isRealtime ?? false }
}

@MainActor
enum Planner {
    static func options(for commute: Commute, app: AppModel, from origin: GeoPoint? = nil,
                        now: Date = Date()) async throws -> [PlannedOption] {
        let target = commute.arriveBy(on: now)
        let time: DigitransitClient.TimeConstraint
        if let target, target > now.addingTimeInterval(20 * 60), target < now.addingTimeInterval(4 * 3600) {
            time = .arriveBy(target)
        } else {
            time = .departAt(now)
        }
        let itineraries = try await app.client.plan(from: origin ?? commute.origin.point, to: commute.destination.point,
                                                    time: time, count: 6, walkSpeed: app.walkingSpeed)
        let options = itineraries.map { option(for: $0, app: app) }
        let ranked = DepartureOptimizer.rank(
            options.map { CommuteOption(id: $0.id, leaveAt: $0.leaveAt, arrival: $0.arrival, totalWait: $0.totalWait, risks: []) },
            arriveBy: target, now: now)
        let byId = Dictionary(options.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Ranked by the optimizer, but shown in departure order with the best one first.
        var result = ranked.compactMap { byId[$0.id] }.filter { $0.leaveAt > now.addingTimeInterval(-90) }
        if let best = result.first {
            result = [best] + result.dropFirst().sorted { $0.leaveAt < $1.leaveAt }
        }
        return result
    }

    static func option(for itinerary: Itinerary, app: AppModel) -> PlannedOption {
        let first = itinerary.firstTransitLeg
        // Shift by the realtime delay of the first vehicle, and keep a boarding buffer.
        let delay = first.map { $0.start.timeIntervalSince($0.scheduledStart) } ?? 0
        let buffer = (first.map { ModeProfile.for($0.mode).boardingBuffer } ?? 0) + app.extraBuffer
        let leaveAt = itinerary.start.addingTimeInterval(delay - buffer)
        var wait: TimeInterval = buffer
        var previousEnd: Date?
        for leg in itinerary.legs {
            if leg.mode.isTransit, let prev = previousEnd { wait += max(leg.start.timeIntervalSince(prev), 0) }
            previousEnd = leg.end
        }
        return PlannedOption(itinerary: itinerary, leaveAt: leaveAt, arrival: itinerary.end,
                             firstTransit: first, totalWait: wait)
    }
}

/// "Leave now" reminders without a server: plan ahead, schedule local notifications,
/// and re-plan from background refresh when iOS grants it.
@MainActor
enum LeaveReminderScheduler {
    static let refreshTaskID = "fi.hslcommuter.refresh"

    static func refresh(app: AppModel, now: Date = Date()) async {
        await app.notifications.cancel(prefix: "reminder-")
        var earliestNextLeave: Date?

        for commute in app.commutes where commute.remindersEnabled && commute.isActive(on: now) {
            guard let arriveBy = commute.arriveBy(on: now), arriveBy > now.addingTimeInterval(15 * 60) else { continue }
            guard let best = try? await Planner.options(for: commute, app: app, now: now).first,
                  let leg = best.firstTransit else { continue }
            let line = leg.route?.shortName ?? leg.mode.rawValue
            let stop = leg.from.name
            app.notifications.schedule(
                id: "reminder-\(commute.id)-pre", at: best.leaveAt.addingTimeInterval(-10 * 60),
                title: "Leave in 10 min",
                body: "\(line) from \(stop) to \(commute.destination.name). Tap to start live tracking.",
                category: NotificationService.reminderCategory)
            app.notifications.schedule(
                id: "reminder-\(commute.id)-go", at: best.leaveAt,
                title: "Time to leave for \(line)",
                body: "Departs \(stop) at \(best.firstTransit?.start.formatted(date: .omitted, time: .shortened) ?? ""). Tap for live tracking.",
                category: NotificationService.reminderCategory)
            earliestNextLeave = min(earliestNextLeave ?? best.leaveAt, best.leaveAt)
        }

        await updateWidgetSnapshot(app: app, now: now)
        scheduleBackgroundRefresh(before: earliestNextLeave, now: now)
    }

    static func updateWidgetSnapshot(app: AppModel, now: Date = Date()) async {
        guard let commute = app.suggestedCommute(now: now),
              let best = try? await Planner.options(for: commute, app: app, now: now).first,
              let leg = best.firstTransit else { return }
        SharedStore.nextDeparture = SharedStore.NextDeparture(
            commuteName: commute.destination.name, line: leg.route?.shortName ?? "", mode: leg.mode,
            stopName: leg.from.name, departure: leg.start, leaveAt: best.leaveAt, arrival: best.arrival,
            isRealtime: leg.isRealtime, updatedAt: now)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func scheduleBackgroundRefresh(before leave: Date?, now: Date = Date()) {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        // Re-plan ~25 min before leaving so the reminder uses fresh realtime data.
        let target = leave.map { $0.addingTimeInterval(-25 * 60) } ?? now.addingTimeInterval(60 * 60)
        request.earliestBeginDate = max(target, now.addingTimeInterval(10 * 60))
        try? BGTaskScheduler.shared.submit(request)
    }
}
