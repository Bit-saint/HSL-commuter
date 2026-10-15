import Foundation

/// Predicts stop-to-stop running times and dwell times.
public protocol SegmentTimeModel: Sendable {
    /// Running time from leaving stop `index` to arriving at stop `index + 1`, excluding dwell.
    func runTime(pattern: TripPattern, from index: Int, at time: Date) -> TimeInterval
    /// Expected dwell at stop `index` (already weighted by the chance the vehicle stops).
    func dwellTime(pattern: TripPattern, at index: Int, at time: Date) -> TimeInterval
}

/// Baseline: the timetable, minus the dwell the timetable bakes into each segment.
public struct ScheduleSegmentModel: SegmentTimeModel {
    public init() {}

    public func runTime(pattern: TripPattern, from index: Int, at time: Date) -> TimeInterval {
        guard index + 1 < pattern.stops.count else { return 0 }
        let a = pattern.stops[index], b = pattern.stops[index + 1]
        let scheduled = b.scheduledArrival.timeIntervalSince(a.scheduledDeparture)
        let distance = max(b.distanceAlong - a.distanceAlong, 0)
        let profile = pattern.profile
        // HSL timetables have minute precision; consecutive stops often share a minute.
        // Never go below physics (top speed) and spread zero-minute segments by distance.
        let physical = distance / profile.maxSpeed
        let fallback = distance / (profile.maxSpeed * 0.45)
        let raw = scheduled > 0 ? scheduled - dwellTime(pattern: pattern, at: index, at: time) * 0.5 : fallback
        return max(raw, physical, 5)
    }

    public func dwellTime(pattern: TripPattern, at index: Int, at time: Date) -> TimeInterval {
        let p = pattern.profile
        return p.dwell * p.stopProbability
    }
}

/// Running statistics of observed segment times, keyed by route, stop pair and
/// time-of-day bucket. Persist it with `Codable` between app launches.
public final class LearnedSegmentStore: @unchecked Sendable, Codable {
    public struct Stat: Codable, Sendable {
        public var mean: Double
        public var variance: Double
        public var count: Int
    }

    private var stats: [String: Stat] = [:]
    private let lock = NSLock()
    /// EWMA weight for new samples once warmed up.
    private let alpha = 0.2

    public init() {}

    enum CodingKeys: String, CodingKey { case stats }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stats = try c.decode([String: Stat].self, forKey: .stats)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        lock.lock(); defer { lock.unlock() }
        try c.encode(stats, forKey: .stats)
    }

    static func bucket(for date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Helsinki") ?? .current
        let comps = cal.dateComponents([.hour, .weekday], from: date)
        let weekend = comps.weekday == 1 || comps.weekday == 7
        // Hour of day, with weekends separated.
        return (comps.hour ?? 0) + (weekend ? 100 : 0)
    }

    static func key(route: String, from: String, to: String, bucket: Int) -> String {
        "\(route)|\(from)|\(to)|\(bucket)"
    }

    public func record(route: String, from: String, to: String, seconds: Double, at date: Date) {
        guard seconds > 0, seconds < 3600 else { return }
        let k = Self.key(route: route, from: from, to: to, bucket: Self.bucket(for: date))
        lock.lock(); defer { lock.unlock() }
        if var s = stats[k] {
            let a = s.count < 5 ? 1.0 / Double(s.count + 1) : alpha
            let delta = seconds - s.mean
            s.mean += a * delta
            s.variance = (1 - a) * (s.variance + a * delta * delta)
            s.count += 1
            stats[k] = s
        } else {
            stats[k] = Stat(mean: seconds, variance: 400, count: 1)
        }
    }

    public func stat(route: String, from: String, to: String, at date: Date) -> Stat? {
        let b = Self.bucket(for: date)
        lock.lock(); defer { lock.unlock() }
        // Fall back to neighbouring hours.
        return stats[Self.key(route: route, from: from, to: to, bucket: b)]
            ?? stats[Self.key(route: route, from: from, to: to, bucket: b - 1)]
            ?? stats[Self.key(route: route, from: from, to: to, bucket: b + 1)]
    }
}

/// Learned running times, falling back to the schedule while samples are scarce.
public struct LearnedSegmentModel: SegmentTimeModel {
    public var base: ScheduleSegmentModel
    public var store: LearnedSegmentStore

    public init(store: LearnedSegmentStore, base: ScheduleSegmentModel = .init()) {
        self.store = store
        self.base = base
    }

    public func runTime(pattern: TripPattern, from index: Int, at time: Date) -> TimeInterval {
        let scheduled = base.runTime(pattern: pattern, from: index, at: time)
        guard index + 1 < pattern.stops.count,
              let s = store.stat(route: pattern.routeId, from: pattern.stops[index].id,
                                 to: pattern.stops[index + 1].id, at: time)
        else { return scheduled }
        let w = min(Double(s.count) / 8.0, 0.85)
        return w * s.mean + (1 - w) * scheduled
    }

    public func dwellTime(pattern: TripPattern, at index: Int, at time: Date) -> TimeInterval {
        base.dwellTime(pattern: pattern, at: index, at: time)
    }
}
