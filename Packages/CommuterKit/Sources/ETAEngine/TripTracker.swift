import Foundation

/// Follows one vehicle running one trip: filters its position along the route,
/// tracks dwell state and stop passages, and feeds the learned segment store.
public final class TripTracker: @unchecked Sendable {
    public private(set) var pattern: TripPattern
    public private(set) var filter: ProgressFilter?
    public private(set) var lastObservation: VehicleObservation?
    public private(set) var lastFixTime: Date?
    /// Stop index the vehicle is currently standing at, if any.
    public private(set) var dwellingAt: Int?
    public private(set) var dwellStart: Date?
    public private(set) var arrivals: [Int: Date] = [:]
    public private(set) var departures: [Int: Date] = [:]
    public private(set) var occupancyPercent: Int?
    public private(set) var heading: Double?
    public private(set) var scheduleOffset: Int?
    public private(set) var reportedSpeed: Double?

    private let learner: LearnedSegmentStore?
    /// Fixes further than this from the route are ignored (vehicle off route / deadheading).
    public var maxLateralError: Double = 200

    public init(pattern: TripPattern, learner: LearnedSegmentStore? = nil) {
        self.pattern = pattern
        self.learner = learner
    }

    public var hasLiveData: Bool { filter != nil }

    /// Refreshes Digitransit realtime predictions without touching the geometry.
    public func updateFeedPredictions(_ stops: [PatternStop]) {
        let byId = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in pattern.stops.indices {
            guard let s = byId[pattern.stops[i].id] else { continue }
            pattern.stops[i].feedArrival = s.feedArrival
            pattern.stops[i].feedDeparture = s.feedDeparture
        }
    }

    public func ingest(_ obs: VehicleObservation) {
        if let last = lastObservation, obs.timestamp < last.timestamp.addingTimeInterval(-30) { return }
        lastObservation = obs
        if let o = obs.occupancyPercent { occupancyPercent = o }
        if let h = obs.heading { heading = h }
        if let d = obs.scheduleOffset { scheduleOffset = d }
        if let v = obs.speed { reportedSpeed = v }

        let previousDistance = filter?.distance
        if obs.hasUsableLocation, let loc = obs.location,
           let proj = pattern.polyline.project(loc, near: filter?.distance),
           proj.lateralDistance <= maxLateralError {
            let accuracy: Double = (obs.locationSource?.uppercased() == "GPS" || obs.locationSource == nil) ? 15 : 35
            if filter == nil {
                filter = ProgressFilter(distance: proj.distanceAlong, speed: obs.speed ?? 0, at: obs.timestamp)
                filter?.maxSpeed = pattern.profile.maxSpeed * 1.2
            } else {
                filter?.update(distance: proj.distanceAlong, accuracy: accuracy, speed: obs.speed, at: obs.timestamp)
            }
            lastFixTime = obs.timestamp
        }

        handleEvent(obs)
        inferPassages(from: previousDistance, at: obs.timestamp)
        inferDwell(at: obs.timestamp)
    }

    private func handleEvent(_ obs: VehicleObservation) {
        let idx = obs.stopId.flatMap { pattern.stopIndex(id: $0) }
        switch obs.event {
        case .arr, .ars:
            guard let idx else { return }
            markArrival(idx, at: obs.timestamp)
            dwellingAt = idx
            dwellStart = obs.timestamp
            snap(to: idx, at: obs.timestamp)
        case .doo:
            if let i = idx ?? nearestStop(within: 40) {
                if dwellingAt != i { dwellStart = obs.timestamp }
                dwellingAt = i
                markArrival(i, at: obs.timestamp)
            }
        case .dep, .pde:
            guard let idx else { return }
            markDeparture(idx, at: obs.timestamp)
            if dwellingAt == idx { dwellingAt = nil; dwellStart = nil }
        case .pas:
            guard let idx else { return }
            markArrival(idx, at: obs.timestamp)
            markDeparture(idx, at: obs.timestamp)
            snap(to: idx, at: obs.timestamp)
        default:
            break
        }
    }

    private func snap(to idx: Int, at time: Date) {
        let d = pattern.stops[idx].distanceAlong
        if filter == nil {
            filter = ProgressFilter(distance: d, at: time)
        } else {
            filter?.update(distance: d, accuracy: 10, at: time)
        }
        lastFixTime = max(lastFixTime ?? time, time)
    }

    /// For sources without stop events (metro, trains): treat crossing a stop's distance as passing it.
    private func inferPassages(from previous: Double?, at time: Date) {
        guard let previous, let now = filter?.distance, now > previous else { return }
        for (i, stop) in pattern.stops.enumerated() where stop.distanceAlong > previous && stop.distanceAlong <= now {
            if arrivals[i] == nil { markArrival(i, at: time) }
            if departures[i] == nil, now - stop.distanceAlong > 30 { markDeparture(i, at: time) }
        }
        // Departure from a stop we dwelled at, once clearly moving away.
        if let d = dwellingAt, now - pattern.stops[d].distanceAlong > 30 {
            if departures[d] == nil { markDeparture(d, at: time) }
            dwellingAt = nil
            dwellStart = nil
        }
    }

    private func inferDwell(at time: Date) {
        guard let f = filter else { return }
        let v = reportedSpeed ?? f.speed
        if v < 0.7, let i = nearestStop(within: 30) {
            if dwellingAt != i {
                dwellingAt = i
                dwellStart = time
                markArrival(i, at: time)
            }
        } else if v > 2.5, let d = dwellingAt, f.distance > pattern.stops[d].distanceAlong + 15 {
            markDeparture(d, at: time)
            dwellingAt = nil
            dwellStart = nil
        }
    }

    private func nearestStop(within meters: Double) -> Int? {
        guard let s = filter?.distance else { return nil }
        var best: (Int, Double)?
        for (i, stop) in pattern.stops.enumerated() {
            let d = abs(stop.distanceAlong - s)
            if d <= meters, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    private func markArrival(_ i: Int, at time: Date) {
        guard arrivals[i] == nil else { return }
        arrivals[i] = time
        // Learn the running time of the segment that just ended.
        if i > 0, let dep = departures[i - 1] {
            learner?.record(route: pattern.routeId, from: pattern.stops[i - 1].id, to: pattern.stops[i].id,
                            seconds: time.timeIntervalSince(dep), at: dep)
        }
    }

    private func markDeparture(_ i: Int, at time: Date) {
        if arrivals[i] == nil { arrivals[i] = time }
        guard departures[i] == nil else { return }
        departures[i] = time
    }

    // MARK: - Queries

    /// True once the vehicle has left (or driven past) stop `i`.
    public func hasPassed(stop i: Int) -> Bool {
        if departures[i] != nil { return true }
        guard let f = filter, dwellingAt != i else { return false }
        return f.distance > pattern.stops[i].distanceAlong + 40
    }

    /// Smoothed position for drawing, predicted to `time`.
    public func displayDistance(at time: Date) -> Double? {
        guard let f = filter else { return nil }
        if let d = dwellingAt { return pattern.stops[d].distanceAlong }
        return f.predictedDistance(at: time, maxHorizon: 6)
    }

    public func displayLocation(at time: Date) -> GeoPoint? {
        if let d = displayDistance(at: time) { return pattern.polyline.point(at: d) }
        return lastObservation?.location
    }

    public func displayHeading(at time: Date) -> Double? {
        if let d = displayDistance(at: time) { return pattern.polyline.bearing(at: d) }
        return heading
    }

    /// The next stop ahead of the vehicle.
    public func nextStopIndex(at time: Date) -> Int? {
        guard let s = displayDistance(at: time) else { return nil }
        if let d = dwellingAt { return d }
        return pattern.stops.firstIndex { $0.distanceAlong > s + 5 }
    }

    public var currentSpeed: Double? { reportedSpeed ?? filter?.speed }
}
