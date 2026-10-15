import Foundation

/// How a vehicle type moves: top speed, acceleration and how much traffic,
/// lights and crossings slow it down compared to an empty road.
public struct SpeedProfile: Sendable {
    /// Typical top speed on a straight, m/s.
    public var cruise: Double
    /// m/s²
    public var acceleration: Double
    /// m/s²
    public var deceleration: Double
    /// Share of the ideal speed actually achieved (traffic lights, traffic, crossings).
    public var efficiency: Double
    /// Rail vehicles use gentler curve limits than road vehicles.
    public var isRail: Bool

    public static func `for`(_ mode: TransitMode) -> SpeedProfile {
        switch mode {
        case .bus: return SpeedProfile(cruise: 12.5, acceleration: 1.0, deceleration: 1.2, efficiency: 0.78, isRail: false)
        case .trunkBus: return SpeedProfile(cruise: 13.5, acceleration: 1.0, deceleration: 1.2, efficiency: 0.82, isRail: false)
        case .uBus: return SpeedProfile(cruise: 19, acceleration: 0.9, deceleration: 1.1, efficiency: 0.86, isRail: false)
        case .tram: return SpeedProfile(cruise: 11, acceleration: 1.0, deceleration: 1.2, efficiency: 0.80, isRail: true)
        case .lightRail: return SpeedProfile(cruise: 15, acceleration: 1.1, deceleration: 1.2, efficiency: 0.88, isRail: true)
        case .metro: return SpeedProfile(cruise: 22, acceleration: 1.1, deceleration: 1.1, efficiency: 0.97, isRail: true)
        case .rail: return SpeedProfile(cruise: 30, acceleration: 0.8, deceleration: 0.9, efficiency: 0.97, isRail: true)
        case .ferry: return SpeedProfile(cruise: 6, acceleration: 0.25, deceleration: 0.3, efficiency: 0.95, isRail: false)
        default: return SpeedProfile(cruise: 1.4, acceleration: 1, deceleration: 1, efficiency: 1, isRail: false)
        }
    }
}

/// Travel time along the actual road or rail geometry: the route is sampled every
/// ~20 m, each sample gets a speed limit from how sharply the route turns there,
/// and the vehicle accelerates/brakes between those limits (and to a stop at the end).
public enum RouteKinematics {
    /// Highest comfortable speed through a turn of `degrees` (measured over ~30 m).
    public static func curveLimit(turnDegrees degrees: Double, rail: Bool) -> Double {
        if rail {
            switch degrees {
            case ..<12: return .infinity
            case ..<30: return 15
            case ..<60: return 9
            default: return 5
            }
        }
        switch degrees {
        case ..<15: return .infinity
        case ..<35: return 11      // gentle bend
        case ..<60: return 7.5     // sharp bend
        case ..<100: return 5      // turning at an intersection
        default: return 3.5        // U-turn / roundabout
        }
    }

    /// Change of direction around distance `s`, degrees 0…180.
    static func turn(at s: Double, on line: Polyline, window: Double = 15) -> Double {
        let a = line.bearing(at: max(s - window, 0))
        let b = line.bearing(at: min(s + window, line.length))
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// Seconds to drive from `start` to `end` (distances along `line`), starting at `initialSpeed`.
    public static func travelTime(along line: Polyline, from start: Double, to end: Double,
                                  initialSpeed: Double = 0, profile: SpeedProfile,
                                  stopAtEnd: Bool = true, step: Double = 20) -> TimeInterval {
        let length = end - start
        guard length > 0.5 else { return 0 }
        let n = max(1, Int((length / step).rounded(.up)))
        let ds = length / Double(n)

        var cap = [Double](repeating: profile.cruise, count: n + 1)
        for i in 0...n {
            cap[i] = min(profile.cruise, curveLimit(turnDegrees: turn(at: start + Double(i) * ds, on: line), rail: profile.isRail))
        }
        var v = [Double](repeating: 0, count: n + 1)
        v[0] = min(max(initialSpeed, 0), profile.cruise)
        // Forward: accelerate towards each limit.
        for i in 0..<n {
            v[i + 1] = min(cap[i + 1], (v[i] * v[i] + 2 * profile.acceleration * ds).squareRoot())
        }
        // Backward: brake in time for limits ahead and the stop at the end.
        if stopAtEnd { v[n] = 0 }
        for i in stride(from: n - 1, through: 1, by: -1) {
            v[i] = min(v[i], (v[i + 1] * v[i + 1] + 2 * profile.deceleration * ds).squareRoot())
        }
        var t = 0.0
        for i in 0..<n {
            t += ds / max((v[i] + v[i + 1]) / 2, 0.3)
        }
        return t / profile.efficiency
    }
}
