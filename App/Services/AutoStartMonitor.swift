import CoreLocation
import Foundation
import ETAEngine

/// Starts live tracking by itself when you leave home (mornings) or work (afternoons)
/// on a commute day. iOS wakes the app for these geofence exits even when it isn't running.
@MainActor
final class AutoStartMonitor {
    static let monitorName = "fi.hslcommuter.places"
    private var monitor: CLMonitor?
    private var eventsTask: Task<Void, Never>?
    private weak var app: AppModel?

    /// Leaving within this radius of home/work counts as "leaving".
    let radius: CLLocationDistance = 120

    func configure(app: AppModel) async {
        self.app = app
        if monitor == nil { monitor = await CLMonitor(Self.monitorName) }
        guard let monitor else { return }
        for id in await monitor.identifiers { await monitor.remove(id) }

        guard app.smart.autoStart else { eventsTask?.cancel(); eventsTask = nil; return }
        if let home = app.homeWork.home {
            await monitor.add(CLMonitor.CircularGeographicCondition(center: home.coordinate, radius: radius),
                              identifier: "home", assuming: .satisfied)
        }
        if let work = app.homeWork.work {
            await monitor.add(CLMonitor.CircularGeographicCondition(center: work.coordinate, radius: radius),
                              identifier: "work", assuming: .satisfied)
        }
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    // "Unsatisfied" = you're no longer inside the circle.
                    guard event.state == .unsatisfied else { continue }
                    await self?.left(event.identifier)
                }
            } catch {}
        }
    }

    private func left(_ place: String) async {
        guard let app, app.smart.autoStart, app.session == nil, app.dayStatus().isWorkday else { return }
        let now = Date()
        let hw = app.homeWork
        let t = hw.times(on: now)
        let minutes = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
        let commutes = app.allCommutes(on: now)
        guard commutes.count >= 2 else { return }

        let commute: Commute
        switch place {
        case "home":
            // From 2 h before your arrive-by time until it.
            let arrive = commutes[0].arriveByMinutes ?? t.arriveAtWork
            guard (arrive - 120...arrive).contains(minutes) else { return }
            commute = commutes[0]
        case "work":
            // From 45 min before your leave time to 3 h after.
            guard (t.leaveWork - 45...t.leaveWork + 180).contains(minutes) else { return }
            commute = commutes[1]
        default:
            return
        }
        await app.autoStartCommute(commute)
    }
}

extension AppModel {
    /// Plans from where you are and starts tracking without any tap.
    func autoStartCommute(_ commute: Commute) async {
        let origin = await location.currentLocation().map { GeoPoint($0.coordinate) }
        await refreshWeather(near: origin)
        guard let best = try? await Planner.options(for: commute, app: self, from: origin).first,
              let first = best.firstTransit else { return }
        startSession(itinerary: best.itinerary, destinationName: commute.destination.name, automatic: true)
        let line = first.route?.shortName ?? first.mode.rawValue
        notifications.post(id: "autostart", title: "On your way to \(commute.destination.name)",
                           body: "Tracking \(line) from \(first.from.name). We'll tell you if you need to hurry.",
                           sound: .soft, timeSensitive: false)
    }
}
