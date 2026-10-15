import Foundation
import Observation
import ETAEngine
import HSLKit

/// App-wide state: settings, saved commutes and shared services.
@MainActor
@Observable
final class AppModel {
    // MARK: Settings (persisted)

    var apiKey: String { didSet { save() } }
    /// Personal walking speed, m/s. Calibrated automatically while walking during commutes.
    var walkingSpeed: Double { didSet { save() } }
    /// Extra seconds to be at the stop on top of the mode default.
    var extraBuffer: Double { didSet { save() } }
    /// Home, work and working hours. Drives the two daily commutes.
    var homeWork: HomeWorkSetup { didSet { save() } }
    /// Extra commutes (gym, school…), in addition to home ↔ work.
    var commutes: [Commute] { didSet { save() } }
    var hasCompletedSetup: Bool { didSet { save() } }

    // MARK: Services

    let location = LocationService()
    let walking = WalkingRouter()
    let notifications = NotificationService()
    let liveActivity = LiveActivityController()
    let learnedSegments: LearnedSegmentStore

    /// The running live commute, if any.
    var session: CommuteSession?

    var client: DigitransitClient { DigitransitClient(apiKey: apiKey) }

    private let defaults = UserDefaults.standard

    init() {
        let bundledKey = Bundle.main.object(forInfoDictionaryKey: "DigitransitAPIKey") as? String ?? ""
        apiKey = defaults.string(forKey: "apiKey") ?? (bundledKey.hasPrefix("$(") ? "" : bundledKey)
        walkingSpeed = defaults.object(forKey: "walkingSpeed") as? Double ?? 1.35
        extraBuffer = defaults.object(forKey: "extraBuffer") as? Double ?? 0
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
        if let data = defaults.data(forKey: "homeWork"), let hw = try? JSONDecoder().decode(HomeWorkSetup.self, from: data) {
            homeWork = hw
        } else {
            homeWork = HomeWorkSetup()
        }
        if let data = defaults.data(forKey: "commutes"), let list = try? JSONDecoder().decode([Commute].self, from: data) {
            commutes = list
        } else {
            commutes = []
        }
        learnedSegments = Persistence.loadLearnedSegments()
    }

    private func save() {
        defaults.set(apiKey, forKey: "apiKey")
        defaults.set(walkingSpeed, forKey: "walkingSpeed")
        defaults.set(extraBuffer, forKey: "extraBuffer")
        defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        if let data = try? JSONEncoder().encode(commutes) { defaults.set(data, forKey: "commutes") }
        if let data = try? JSONEncoder().encode(homeWork) { defaults.set(data, forKey: "homeWork") }
    }

    func persistLearning() {
        Persistence.save(learnedSegments)
    }

    /// Home ↔ work for the given day (with that day's times) followed by the extra commutes.
    func allCommutes(on date: Date = Date()) -> [Commute] {
        homeWork.commutes(on: date) + commutes
    }

    /// The commute that makes sense right now: to work in the morning, home after the
    /// middle of the working day. Falls back to the first extra commute.
    func suggestedCommute(now: Date = Date()) -> Commute? {
        let hw = homeWork.commutes(on: now)
        if hw.count == 2 { return homeWork.isMorning(now) ? hw[0] : hw[1] }
        guard let first = commutes.first(where: { $0.isActive(on: now) }) ?? commutes.first else { return nil }
        let hour = Calendar.current.component(.hour, from: now)
        return hour < 12 ? first : first.reversed
    }

    /// The opposite direction: to work ↔ to home keep their own times.
    func counterpart(of commute: Commute, now: Date = Date()) -> Commute {
        let hw = homeWork.commutes(on: now)
        if hw.count == 2 {
            if commute.id == HomeWorkSetup.toWorkID { return hw[1] }
            if commute.id == HomeWorkSetup.toHomeID { return hw[0] }
        }
        return commute.reversed
    }

    // MARK: Live sessions

    func startSession(itinerary: Itinerary, destinationName: String) {
        session?.stop()
        let s = CommuteSession(itinerary: itinerary, destinationName: destinationName, app: self)
        session = s
        Task { await s.start() }
    }

    func stopSession() {
        session?.stop()
        session = nil
        persistLearning()
    }

    /// After a miss: plan again from where the user is now to the same destination.
    func replan() async {
        guard let current = session, let destination = current.itinerary.legs.last?.to.location else { return }
        let origin = await location.currentLocation().map { GeoPoint($0.coordinate) }
            ?? current.itinerary.legs.first?.from.location
        guard let origin,
              let itineraries = try? await client.plan(from: origin, to: destination, count: 4, walkSpeed: walkingSpeed),
              let best = itineraries.map({ Planner.option(for: $0, app: self) })
                .first(where: { $0.leaveAt > Date().addingTimeInterval(-60) }) else { return }
        startSession(itinerary: best.itinerary, destinationName: current.destinationName)
    }

    /// Track a single departure picked from a stop board.
    func track(departure: Departure, at stop: StopRef) {
        let leg = Leg(mode: departure.route.mode, scheduledStart: departure.scheduled, scheduledEnd: departure.scheduled,
                      estimatedStart: departure.realtime, estimatedEnd: nil, distance: 0,
                      from: Place(name: stop.name, location: stop.location, stop: stop),
                      to: Place(name: departure.headsign, location: stop.location, stop: nil),
                      geometry: [], route: departure.route,
                      trip: TripRef(tripId: departure.tripId, directionId: departure.directionId,
                                    serviceDate: departure.serviceDate, headsign: departure.headsign),
                      headsign: departure.headsign, isRealtime: departure.isRealtime)
        let itinerary = Itinerary(start: departure.realtime, end: departure.realtime, legs: [leg], walkDistance: 0)
        startSession(itinerary: itinerary, destinationName: departure.headsign)
    }

    /// Nudges the personal walking speed towards an observed one.
    func observeWalkingSpeed(_ v: Double) {
        guard (0.7...2.3).contains(v) else { return }
        walkingSpeed = walkingSpeed * 0.98 + v * 0.02
    }
}

enum Persistence {
    static var learnedURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("learned-segments.json")
    }

    static func loadLearnedSegments() -> LearnedSegmentStore {
        guard let data = try? Data(contentsOf: learnedURL),
              let store = try? JSONDecoder().decode(LearnedSegmentStore.self, from: data) else {
            return LearnedSegmentStore()
        }
        return store
    }

    static func save(_ store: LearnedSegmentStore) {
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: learnedURL, options: .atomic)
        }
    }
}
