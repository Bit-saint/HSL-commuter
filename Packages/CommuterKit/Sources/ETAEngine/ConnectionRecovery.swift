import Foundation

/// After a missed vehicle or connection: which alternative gets you there fastest,
/// counting only the ones you can still physically reach.
public enum ConnectionRecovery {
    public struct Candidate: Sendable, Equatable {
        public var id: String
        /// When the first vehicle of this alternative leaves its stop (realtime if known).
        public var firstDeparture: Date
        /// Arrival at the destination.
        public var arrival: Date
        /// Walking distance from where you are (or will be) to the first stop, meters.
        public var walkDistance: Double
        public var transfers: Int
        public var boardingBuffer: TimeInterval

        public init(id: String, firstDeparture: Date, arrival: Date, walkDistance: Double,
                    transfers: Int, boardingBuffer: TimeInterval = 30) {
            self.id = id
            self.firstDeparture = firstDeparture
            self.arrival = arrival
            self.walkDistance = walkDistance
            self.transfers = transfers
            self.boardingBuffer = boardingBuffer
        }
    }

    public struct Ranked: Sendable, Equatable {
        public var candidate: Candidate
        public var advice: PaceAdvice
        public var isFastest: Bool
    }

    /// - Parameters:
    ///   - readyAt: when you can start walking (now, or when your current vehicle reaches its stop).
    public static func rank(_ candidates: [Candidate], readyAt: Date, walkingSpeed: Double) -> [Ranked] {
        let advisor = PaceAdvisor(walkingSpeed: walkingSpeed)
        let reachable: [Ranked] = candidates.compactMap { c in
            let eta = ETAEstimate(expected: c.firstDeparture, earliest: c.firstDeparture, latest: c.firstDeparture,
                                  source: .realtimeFeed, computedAt: readyAt)
            let advice = advisor.advise(walkDistance: c.walkDistance, eta: eta, buffer: c.boardingBuffer, now: readyAt)
            guard advice.state != .willMiss else { return nil }
            return Ranked(candidate: c, advice: advice, isFastest: false)
        }
        // Earliest arrival wins; within a minute prefer an easier pace, then fewer changes.
        var sorted = reachable.sorted { a, b in
            let da = a.candidate.arrival.timeIntervalSince(b.candidate.arrival)
            if abs(da) >= 60 { return da < 0 }
            if a.advice.state.urgency != b.advice.state.urgency { return a.advice.state.urgency < b.advice.state.urgency }
            if a.candidate.transfers != b.candidate.transfers { return a.candidate.transfers < b.candidate.transfers }
            return da < 0
        }
        if !sorted.isEmpty { sorted[0].isFastest = true }
        return sorted
    }

    /// "N", "NE", … for a bearing in degrees.
    public static func compassDirection(_ bearing: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let i = Int(((bearing.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45).rounded(.down)) % 8
        return names[i]
    }
}
