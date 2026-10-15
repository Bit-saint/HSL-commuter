import Foundation

public struct ETAEstimate: Sendable, Codable, Equatable {
    public enum Source: String, Codable, Sendable {
        case liveVehicle      // our model from the vehicle's live position
        case realtimeFeed     // Digitransit realtime prediction
        case schedule         // timetable (+ last known offset)
        case passed           // the vehicle has already left
    }

    public var expected: Date
    /// Pessimistic early bound (≈P10): the vehicle could be here this early.
    public var earliest: Date
    /// ≈P90
    public var latest: Date
    public var source: Source
    public var computedAt: Date
    /// Age of the newest vehicle fix used, seconds.
    public var fixAge: TimeInterval?
    /// Distance the vehicle still has to travel, meters.
    public var distanceRemaining: Double?

    public init(expected: Date, earliest: Date, latest: Date, source: Source, computedAt: Date,
                fixAge: TimeInterval? = nil, distanceRemaining: Double? = nil) {
        self.expected = expected
        self.earliest = earliest
        self.latest = latest
        self.source = source
        self.computedAt = computedAt
        self.fixAge = fixAge
        self.distanceRemaining = distanceRemaining
    }

    public var isPassed: Bool { source == .passed }

    /// 0…1, narrower spread = higher confidence.
    public var confidence: Double {
        let spread = latest.timeIntervalSince(earliest)
        return exp(-spread / 240)
    }

    public func seconds(from now: Date) -> TimeInterval { expected.timeIntervalSince(now) }

    /// "<1", "4" or "4–6" minutes.
    public func minutesLabel(from now: Date) -> String {
        let lo = Int((earliest.timeIntervalSince(now) / 60).rounded(.down))
        let mid = Int((expected.timeIntervalSince(now) / 60).rounded())
        let hi = Int((latest.timeIntervalSince(now) / 60).rounded(.up))
        if expected.timeIntervalSince(now) < 60 { return "<1" }
        if hi - lo >= 3, mid >= 5 { return "\(max(lo, 0))–\(hi)" }
        return "\(mid)"
    }
}

/// Combines the live vehicle state, the segment model and the realtime feed into
/// an arrival estimate for a given stop.
public struct ETAEstimator: Sendable {
    public enum Target: Sendable { case arrival, departure }

    public var model: SegmentTimeModel
    /// Live data older than this is not trusted.
    public var maxFixAge: TimeInterval = 120

    public init(model: SegmentTimeModel = ScheduleSegmentModel()) {
        self.model = model
    }

    public func estimate(_ tracker: TripTracker, stop t: Int, target: Target = .arrival, now: Date) -> ETAEstimate {
        let pattern = tracker.pattern
        guard pattern.stops.indices.contains(t) else {
            return ETAEstimate(expected: now, earliest: now, latest: now, source: .schedule, computedAt: now)
        }
        if tracker.hasPassed(stop: t) {
            let when = tracker.departures[t] ?? tracker.arrivals[t] ?? now
            return ETAEstimate(expected: when, earliest: when, latest: when, source: .passed, computedAt: now)
        }

        let stop = pattern.stops[t]
        let feed: Date? = target == .arrival ? (stop.feedArrival ?? stop.feedDeparture) : (stop.feedDeparture ?? stop.feedArrival)

        guard let filter = tracker.filter, let fixTime = tracker.lastFixTime,
              now.timeIntervalSince(fixTime) < maxFixAge else {
            return fallback(tracker, stop: t, target: target, feed: feed, now: now)
        }

        let age = max(now.timeIntervalSince(fixTime), 0)
        let s = filter.predictedDistance(at: now, maxHorizon: 10)
        let speed = tracker.currentSpeed ?? filter.speed
        let profile = pattern.profile
        let stops = pattern.stops

        var cursor: TimeInterval = 0     // seconds from now
        var k: Int                       // last stop index we are at / past

        if s < stops[0].distanceAlong - 20 {
            // Approaching the first stop (e.g. from the depot).
            cursor = (stops[0].distanceAlong - s) / max(speed, 5)
            k = 0
            if t == 0 && target == .arrival { return finish(now: now, cursor: cursor, age: age, feed: feed, remaining: stops[0].distanceAlong - s) }
            cursor = max(cursor + profile.dwell, stops[0].scheduledDeparture.timeIntervalSince(now))
            if t == 0 { return finish(now: now, cursor: cursor, age: age, feed: feed, remaining: stops[0].distanceAlong - s) }
            cursor += model.runTime(pattern: pattern, from: 0, at: now)
        } else if let d = tracker.dwellingAt {
            k = d
            let elapsed = tracker.dwellStart.map { now.timeIntervalSince($0) } ?? 0
            var depart = max(profile.dwell - elapsed, 3)
            // Timing points and the first stop: never leave before the schedule.
            if stops[d].isTimingPoint || d == 0 {
                depart = max(depart, stops[d].scheduledDeparture.timeIntervalSince(now))
            }
            if d == t {
                // Vehicle is at the target stop now.
                return target == .arrival
                    ? finish(now: now, cursor: 0, age: age, feed: nil, remaining: 0)
                    : finish(now: now, cursor: depart, age: age, feed: feed, remaining: 0)
            }
            cursor = depart + model.runTime(pattern: pattern, from: d, at: now)
        } else {
            k = pattern.segmentIndex(containing: s)
            guard k + 1 < stops.count else {
                return ETAEstimate(expected: now, earliest: now, latest: now, source: .passed, computedAt: now)
            }
            let segLen = max(stops[k + 1].distanceAlong - stops[k].distanceAlong, 1)
            let remaining = max(stops[k + 1].distanceAlong - s, 0)
            let modelled = model.runTime(pattern: pattern, from: k, at: now) * (remaining / segLen)
            // Drive the rest of the road/rail from the current speed: curves, braking into the stop.
            let physics = RouteKinematics.travelTime(along: pattern.polyline, from: s, to: stops[k + 1].distanceAlong,
                                                     initialSpeed: speed, profile: .for(pattern.mode))
            // Close to the stop the vehicle's own motion dominates; further away, the learned/scheduled time.
            let w = remaining < 400 ? 0.7 : (pattern.followsRealGeometry ? 0.4 : 0.2)
            cursor = w * physics + (1 - w) * modelled
        }

        // Walk the remaining stops up to the target.
        var j = k + 1
        while j < t {
            let arrival = cursor
            var depart = arrival + model.dwellTime(pattern: pattern, at: j, at: now)
            if stops[j].isTimingPoint {
                depart = max(depart, stops[j].scheduledDeparture.timeIntervalSince(now))
            }
            cursor = depart + model.runTime(pattern: pattern, from: j, at: now)
            j += 1
        }
        if target == .departure {
            var depart = cursor + profile.dwell
            if stops[t].isTimingPoint || t == 0 {
                depart = max(depart, stops[t].scheduledDeparture.timeIntervalSince(now))
            }
            cursor = depart
        }
        return finish(now: now, cursor: cursor, age: age, feed: feed, remaining: max(stop.distanceAlong - s, 0))
    }

    private func finish(now: Date, cursor: TimeInterval, age: TimeInterval, feed: Date?, remaining: Double) -> ETAEstimate {
        var expected = now.addingTimeInterval(max(cursor, 0))
        let horizon = max(cursor, 0)
        var sigma = 6 + 0.08 * horizon + 0.6 * max(0, age - 5)

        if let feed {
            // Blend with the Digitransit prediction; trust ours more when data is fresh and close.
            var wLive = age < 20 ? 0.8 : (age < 60 ? 0.6 : 0.35)
            if horizon < 120 { wLive = max(wLive, 0.9) }
            let blended = wLive * expected.timeIntervalSince1970 + (1 - wLive) * feed.timeIntervalSince1970
            let disagreement = abs(feed.timeIntervalSince(expected))
            expected = Date(timeIntervalSince1970: blended)
            sigma += 0.25 * disagreement * (1 - wLive)
        }
        let earliest = max(expected.addingTimeInterval(-1.0 * sigma), now)
        let latest = expected.addingTimeInterval(1.6 * sigma)
        return ETAEstimate(expected: expected, earliest: earliest, latest: latest, source: .liveVehicle,
                           computedAt: now, fixAge: age, distanceRemaining: remaining)
    }

    /// No live position: realtime feed if present, else timetable shifted by the last known offset.
    private func fallback(_ tracker: TripTracker, stop t: Int, target: Target, feed: Date?, now: Date) -> ETAEstimate {
        let stop = tracker.pattern.stops[t]
        let scheduled = target == .arrival ? stop.scheduledArrival : stop.scheduledDeparture
        let base: Date
        let source: ETAEstimate.Source
        var sigma: Double
        if let feed {
            base = feed
            source = .realtimeFeed
            sigma = 30
        } else {
            // HFP `dl`: positive = ahead of schedule.
            base = scheduled.addingTimeInterval(-Double(tracker.scheduleOffset ?? 0))
            source = .schedule
            sigma = 60
        }
        // A trip that hasn't started can't leave its first stop early.
        var expected = base
        if !tracker.hasLiveData {
            let firstDeparture = tracker.pattern.stops[0].scheduledDeparture
            let offsetFromFirst = scheduled.timeIntervalSince(firstDeparture)
            expected = max(expected, firstDeparture.addingTimeInterval(offsetFromFirst * 0.85))
        }
        let horizon = max(expected.timeIntervalSince(now), 0)
        sigma += 0.12 * horizon
        return ETAEstimate(expected: expected,
                           earliest: max(expected.addingTimeInterval(-sigma), now),
                           latest: expected.addingTimeInterval(1.6 * sigma),
                           source: source, computedAt: now)
    }
}
