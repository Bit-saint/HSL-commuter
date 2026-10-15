import Foundation

/// What the user should do right now to catch the vehicle.
public enum PaceState: String, Codable, Sendable, CaseIterable {
    case relax          // plenty of time, stay where you are
    case leaveSoon      // leave within a few minutes
    case goNow          // start walking now at normal pace
    case walkBriskly
    case run
    case willMiss
    case atStop         // you're at the stop, just wait
    case onBoard

    /// Higher = more urgent. Used for hysteresis and notification escalation.
    public var urgency: Int {
        switch self {
        case .onBoard, .atStop: return 0
        case .relax: return 1
        case .leaveSoon: return 2
        case .goNow: return 3
        case .walkBriskly: return 4
        case .run: return 5
        case .willMiss: return 6
        }
    }

    public var title: String {
        switch self {
        case .relax: return "Relax"
        case .leaveSoon: return "Leave soon"
        case .goNow: return "Start walking"
        case .walkBriskly: return "Walk briskly"
        case .run: return "Run!"
        case .willMiss: return "You'll miss it"
        case .atStop: return "At the stop"
        case .onBoard: return "On board"
        }
    }
}

public struct PaceAdvice: Sendable, Codable, Equatable {
    public var state: PaceState
    /// When to start walking at normal pace.
    public var leaveAt: Date?
    /// Seconds of slack if leaving now at normal pace (negative = late).
    public var margin: TimeInterval
    public var requiredSpeed: Double?
    public var walkDistance: Double
    public var walkDuration: TimeInterval

    public func message(now: Date) -> String {
        let m = Int((leaveAt?.timeIntervalSince(now) ?? 0) / 60)
        let dist = walkDistance >= 1000 ? String(format: "%.1f km", walkDistance / 1000) : "\(Int(walkDistance.rounded())) m"
        switch state {
        case .relax: return m > 0 ? "Leave in \(m) min" : "Plenty of time"
        case .leaveSoon: return m > 0 ? "Leave in \(m) min" : "Leave in under a minute"
        case .goNow: return "Start walking now · \(dist)"
        case .walkBriskly: return "Walk briskly · \(dist)"
        case .run: return "Run! · \(dist)"
        case .willMiss: return "You won't make this one"
        case .atStop: return "You're at the stop"
        case .onBoard: return "On board"
        }
    }
}

public struct PaceAdvisor: Sendable {
    /// The user's normal walking speed, m/s.
    public var walkingSpeed: Double
    public var briskFactor = 1.3
    public var runFactor = 2.2
    /// Nobody commutes faster than this on foot, m/s.
    public var maxRunSpeed = 4.0
    public var atStopRadius: Double = 35
    public var leaveSoonWindow: TimeInterval = 180
    /// Extra margin needed before de-escalating (prevents flip-flopping).
    public var hysteresis: TimeInterval = 15

    public init(walkingSpeed: Double = 1.35) {
        self.walkingSpeed = walkingSpeed
    }

    /// - Parameters:
    ///   - walkDistance: route distance from the user to the boarding stop, meters.
    ///   - eta: vehicle arrival estimate at the boarding stop.
    ///   - buffer: how early to be at the stop (mode dependent).
    public func advise(walkDistance: Double, eta: ETAEstimate, buffer: TimeInterval,
                       now: Date, previous: PaceState? = nil) -> PaceAdvice {
        let walkDuration = walkDistance / walkingSpeed
        if eta.isPassed {
            return PaceAdvice(state: .willMiss, leaveAt: nil, margin: -9_999, requiredSpeed: nil,
                              walkDistance: walkDistance, walkDuration: walkDuration)
        }
        // Plan against the early bound: being early at the stop is cheap, missing is expensive.
        let deadline = eta.earliest.addingTimeInterval(-buffer)
        let leaveAt = deadline.addingTimeInterval(-walkDuration)
        let available = deadline.timeIntervalSince(now)
        let margin = leaveAt.timeIntervalSince(now)

        if walkDistance <= atStopRadius {
            return PaceAdvice(state: .atStop, leaveAt: nil, margin: available, requiredSpeed: 0,
                              walkDistance: walkDistance, walkDuration: 0)
        }

        var state = classify(walkDistance: walkDistance, available: available, margin: margin)
        if let previous, previous.urgency > state.urgency, previous != .atStop, previous != .onBoard {
            // Only relax if we'd still relax with some extra margin.
            state = classify(walkDistance: walkDistance, available: available - hysteresis, margin: margin - hysteresis)
        }
        let required = available > 0 ? walkDistance / available : nil
        return PaceAdvice(state: state, leaveAt: leaveAt, margin: margin, requiredSpeed: required,
                          walkDistance: walkDistance, walkDuration: walkDuration)
    }

    private func classify(walkDistance: Double, available: TimeInterval, margin: TimeInterval) -> PaceState {
        if margin > leaveSoonWindow { return .relax }
        if margin > 60 { return .leaveSoon }
        guard available > 0 else { return .willMiss }
        let required = walkDistance / available
        if required <= walkingSpeed { return .goNow }
        if required <= walkingSpeed * briskFactor { return .walkBriskly }
        if required <= min(walkingSpeed * runFactor, maxRunSpeed) { return .run }
        return .willMiss
    }
}
