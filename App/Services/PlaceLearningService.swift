import CoreLocation
import Foundation
import Observation
import ETAEngine

/// Learns home, work and your usual times from iOS visit monitoring.
/// Visits stay on the phone (Application Support), capped at 60 days.
@MainActor
@Observable
final class PlaceLearningService: NSObject, CLLocationManagerDelegate {
    enum Suggestion: Equatable, Identifiable {
        case home(SavedPlace)
        case work(SavedPlace)
        case times(arrive: Int?, leave: Int?)

        var id: String {
            switch self {
            case .home(let p): return "home-\(Int(p.latitude * 1000))-\(Int(p.longitude * 1000))"
            case .work(let p): return "work-\(Int(p.latitude * 1000))-\(Int(p.longitude * 1000))"
            case .times(let a, let l): return "times-\(a ?? 0)-\(l ?? 0)"
            }
        }
    }

    /// The one suggestion to show right now, if any.
    private(set) var suggestion: Suggestion?

    private let manager = CLLocationManager()
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var visits: [Visit] = []
    private let dismissedKey = "dismissedSuggestions"

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("visits.json")
    }

    override init() {
        super.init()
        manager.delegate = self
        if let data = try? Data(contentsOf: Self.url), let v = try? JSONDecoder().decode([Visit].self, from: data) {
            visits = v
        }
    }

    func start(app: AppModel) {
        self.app = app
        // Needs "Always" location; iOS wakes the app for visits even when it isn't running.
        manager.startMonitoringVisits()
        Task { await evaluate() }
    }

    func stop() {
        manager.stopMonitoringVisits()
        suggestion = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // Ignore the open-ended "arrived, not left yet" reports; the departure report follows.
        guard visit.arrivalDate != .distantPast, visit.departureDate != .distantFuture else { return }
        let v = Visit(arrival: visit.arrivalDate, departure: visit.departureDate,
                      location: GeoPoint(visit.coordinate))
        Task { @MainActor in
            self.visits.append(v)
            let cutoff = Date().addingTimeInterval(-60 * 86_400)
            self.visits.removeAll { $0.departure < cutoff }
            if let data = try? JSONEncoder().encode(self.visits) { try? data.write(to: Self.url, options: .atomic) }
            await self.evaluate()
        }
    }

    private var dismissed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: dismissedKey) }
    }

    func dismiss(_ s: Suggestion) {
        dismissed.insert(s.id)
        suggestion = nil
        Task { await evaluate() }
    }

    /// Applies a suggestion to the Home & Work setup.
    func accept(_ s: Suggestion) {
        guard let app else { return }
        switch s {
        case .home(let p): app.homeWork.home = p
        case .work(let p): app.homeWork.work = p
        case .times(let a, let l):
            app.homeWork.usesPerDayTimes = false
            if let a { app.homeWork.defaultTimes.arriveAtWork = a }
            if let l { app.homeWork.defaultTimes.leaveWork = l }
        }
        dismissed.insert(s.id)
        suggestion = nil
        Task { await evaluate() }
    }

    func evaluate() async {
        guard let app, app.smart.learnPlaces else { suggestion = nil; return }
        let hw = app.homeWork
        var next: Suggestion?

        if let h = VisitLearner.suggestHome(from: visits),
           hw.home.map({ $0.point.distance(to: h) > 250 }) ?? true {
            next = .home(await place(named: "Home", at: h))
        } else if let w = VisitLearner.suggestWork(from: visits, home: hw.home?.point ?? VisitLearner.suggestHome(from: visits)),
                  hw.work.map({ $0.point.distance(to: w) > 250 }) ?? true {
            next = .work(await place(named: "Work", at: w))
        } else if let work = hw.work, !hw.usesPerDayTimes {
            let t = VisitLearner.typicalTimes(from: visits, work: work.point)
            // Only bother you when it's 10+ minutes off.
            let arrive = t.arrive.flatMap { abs($0 - hw.defaultTimes.arriveAtWork) >= 10 ? $0 : nil }
            let leave = t.leave.flatMap { abs($0 - hw.defaultTimes.leaveWork) >= 10 ? $0 : nil }
            if arrive != nil || leave != nil { next = .times(arrive: arrive, leave: leave) }
        }
        if let n = next, dismissed.contains(n.id) { next = nil }
        suggestion = next
    }

    private func place(named fallback: String, at p: GeoPoint) async -> SavedPlace {
        let loc = CLLocation(latitude: p.latitude, longitude: p.longitude)
        let mark = try? await CLGeocoder().reverseGeocodeLocation(loc).first
        let street = [mark?.thoroughfare, mark?.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        return SavedPlace(name: street.isEmpty ? (mark?.name ?? fallback) : street, latitude: p.latitude, longitude: p.longitude)
    }
}
