import Foundation

/// 1D constant-velocity Kalman filter over "distance along route".
/// Smooths GPS jitter and lets us predict position between ~1 Hz fixes.
public struct ProgressFilter: Sendable, Codable {
    public private(set) var distance: Double
    public private(set) var speed: Double
    public private(set) var timestamp: Date
    // Covariance [[p00, p01], [p01, p11]]
    private var p00: Double
    private var p01: Double
    private var p11: Double
    private var consecutiveOutliers = 0

    /// Process noise: acceleration standard deviation, m/s².
    public var accelerationNoise: Double = 1.2
    public var maxSpeed: Double = 40

    public init(distance: Double, speed: Double = 0, at time: Date) {
        self.distance = distance
        self.speed = max(0, speed)
        self.timestamp = time
        p00 = 400      // 20 m std
        p01 = 0
        p11 = 25       // 5 m/s std
    }

    public var distanceStdDev: Double { p00.squareRoot() }

    private mutating func predict(to time: Date) {
        let dt = time.timeIntervalSince(timestamp)
        guard dt > 0 else { return }
        distance += speed * dt
        let q = accelerationNoise * accelerationNoise
        let dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt3 * dt
        let n00 = p00 + 2 * dt * p01 + dt2 * p11 + q * dt4 / 4
        let n01 = p01 + dt * p11 + q * dt3 / 2
        let n11 = p11 + q * dt2
        p00 = n00; p01 = n01; p11 = n11
        timestamp = time
    }

    /// Feeds a measured distance along route (and optionally speed).
    /// Returns false if the measurement was rejected as an outlier.
    @discardableResult
    public mutating func update(distance z: Double, accuracy: Double = 15, speed v: Double? = nil, at time: Date) -> Bool {
        if time < timestamp { return false }
        predict(to: time)

        let r = accuracy * accuracy
        let innovation = z - distance
        let s = p00 + r
        // Gate: a jump of > 4 sigma and > 150 m is suspicious. Accept after 3 in a row (real relocation).
        if abs(innovation) > 4 * s.squareRoot() && abs(innovation) > 150 {
            consecutiveOutliers += 1
            if consecutiveOutliers < 3 { return false }
            self = ProgressFilter(distance: z, speed: v ?? speed, at: time)
            return true
        }
        consecutiveOutliers = 0
        let k0 = p00 / s, k1 = p01 / s
        distance += k0 * innovation
        speed += k1 * innovation
        let n00 = (1 - k0) * p00
        let n01 = (1 - k0) * p01
        let n11 = p11 - k1 * p01
        p00 = n00; p01 = n01; p11 = n11

        if let v {
            // Scalar speed measurement, std 1 m/s.
            let rv = 1.0
            let sv = p11 + rv
            let innov = v - speed
            let g0 = p01 / sv, g1 = p11 / sv
            distance += g0 * innov
            speed += g1 * innov
            let m00 = p00 - g0 * p01
            let m01 = p01 - g0 * p11
            let m11 = (1 - g1) * p11
            p00 = m00; p01 = m01; p11 = m11
        }
        speed = min(max(speed, 0), maxSpeed)
        return true
    }

    /// Position predicted at `time` without mutating. Prediction is capped so a
    /// stale filter doesn't run away, and doesn't pass `limit` (e.g. the next stop
    /// the vehicle is known to stop at).
    public func predictedDistance(at time: Date, maxHorizon: TimeInterval = 8, limit: Double? = nil) -> Double {
        let dt = min(max(time.timeIntervalSince(timestamp), 0), maxHorizon)
        let d = distance + speed * dt
        if let limit { return min(d, max(limit, distance)) }
        return d
    }
}
