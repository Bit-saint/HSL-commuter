import Foundation

public enum TransferRisk: String, Codable, Sendable {
    case comfortable    // > 2 min slack
    case tight          // 0–2 min slack at normal pace
    case needsHurry     // only by walking briskly / running
    case missed         // even running won't make it
}

public struct TransferAssessment: Sendable, Codable, Equatable {
    public var risk: TransferRisk
    /// Slack in seconds at normal walking pace (negative = late).
    public var slack: TimeInterval
    public var walkDuration: TimeInterval
}

/// Checks whether a connection works, using live estimates for both vehicles.
public enum TransferGuard {
    public static func assess(arrival: ETAEstimate, departure: ETAEstimate, walkDistance: Double,
                              walkingSpeed: Double, buffer: TimeInterval = 20,
                              maxRunSpeed: Double = 3.5) -> TransferAssessment {
        let walk = walkDistance / max(walkingSpeed, 0.5)
        if departure.isPassed {
            return TransferAssessment(risk: .missed, slack: -9_999, walkDuration: walk)
        }
        // Realistic: we arrive as expected, the next vehicle comes at its early bound.
        let slack = departure.earliest.timeIntervalSince(arrival.expected) - walk - buffer
        let risk: TransferRisk
        if slack > 120 {
            risk = .comfortable
        } else if slack >= 0 {
            risk = .tight
        } else {
            // Could we make it running, if our vehicle is early and theirs late?
            let runWalk = walkDistance / maxRunSpeed
            let bestCase = departure.latest.timeIntervalSince(arrival.earliest) - runWalk - 5
            risk = bestCase >= 0 ? .needsHurry : .missed
        }
        return TransferAssessment(risk: risk, slack: slack, walkDuration: walk)
    }
}

/// One candidate way of doing the commute right now.
public struct CommuteOption: Sendable, Equatable {
    public var id: String
    /// When the user should leave at normal pace.
    public var leaveAt: Date
    public var arrival: Date
    /// Total expected standing time at stops (first boarding + transfers).
    public var totalWait: TimeInterval
    public var risks: [TransferRisk]

    public init(id: String, leaveAt: Date, arrival: Date, totalWait: TimeInterval, risks: [TransferRisk]) {
        self.id = id
        self.leaveAt = leaveAt
        self.arrival = arrival
        self.totalWait = totalWait
        self.risks = risks
    }
}

/// Picks the departure that wastes the least time standing at stops.
public enum DepartureOptimizer {
    public static func rank(_ options: [CommuteOption], arriveBy: Date?, now: Date) -> [CommuteOption] {
        func score(_ o: CommuteOption) -> Double {
            if o.leaveAt < now.addingTimeInterval(-60) { return .infinity } // already too late to leave
            var s: Double
            if let arriveBy {
                let late = max(o.arrival.timeIntervalSince(arriveBy), 0)
                // Arriving on time matters most, then leaving as late as possible with little waiting.
                s = late * 10 - o.leaveAt.timeIntervalSince(now) * 0.2 + o.totalWait
            } else {
                s = o.arrival.timeIntervalSince(now) + 0.5 * o.totalWait
            }
            for r in o.risks {
                switch r {
                case .comfortable: break
                case .tight: s += 60
                case .needsHurry: s += 300
                case .missed: s += 3600
                }
            }
            return s
        }
        return options.sorted { score($0) < score($1) }
    }
}
