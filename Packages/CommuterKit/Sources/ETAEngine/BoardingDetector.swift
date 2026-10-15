import Foundation

/// Decides "you got on" / "you got off" from your position and motion relative
/// to the vehicle, so nobody has to tap "I'm on it".
public struct BoardingDetector: Sendable {
    public enum Activity: Sendable, Equatable {
        case stationary, walking, running, automotive, unknown
    }

    public struct Sample: Sendable {
        public var time: Date
        public var user: GeoPoint?
        /// GPS horizontal accuracy, meters.
        public var userAccuracy: Double
        public var userSpeed: Double?
        public var vehicle: GeoPoint?
        public var vehicleSpeed: Double?
        public var activity: Activity

        public init(time: Date, user: GeoPoint?, userAccuracy: Double = 10, userSpeed: Double?,
                    vehicle: GeoPoint?, vehicleSpeed: Double?, activity: Activity) {
            self.time = time
            self.user = user
            self.userAccuracy = userAccuracy
            self.userSpeed = userSpeed
            self.vehicle = vehicle
            self.vehicleSpeed = vehicleSpeed
            self.activity = activity
        }
    }

    public private(set) var isOnBoard = false
    private var boardStreak = 0
    private var alightStreak = 0
    /// Consecutive agreeing samples (~1 s apart) needed to flip state.
    public var requiredSamples = 4

    public init(onBoard: Bool = false) {
        isOnBoard = onBoard
    }

    /// Returns true when the state changed.
    @discardableResult
    public mutating func update(_ s: Sample) -> Bool {
        guard let user = s.user, let vehicle = s.vehicle else { return false }
        let gap = user.distance(to: vehicle)
        let tolerance = 35 + min(s.userAccuracy, 60)        // GPS is noisy next to big vehicles
        let vehicleMoving = (s.vehicleSpeed ?? 0) > 2
        let userMoving = (s.userSpeed ?? 0) > 2.5 || s.activity == .automotive

        if !isOnBoard {
            // Moving together with the vehicle, close to it.
            let evidence = vehicleMoving && userMoving && gap < tolerance
            boardStreak = evidence ? boardStreak + 1 : 0
            if boardStreak >= requiredSamples {
                isOnBoard = true
                boardStreak = 0
                alightStreak = 0
                return true
            }
        } else {
            // The vehicle drove off without you, or you're walking and it isn't with you.
            let leftBehind = gap > tolerance * 2.5 && vehicleMoving
            let walkingAway = (s.activity == .walking || s.activity == .running) && gap > tolerance
            alightStreak = (leftBehind || walkingAway) ? alightStreak + 1 : 0
            if alightStreak >= requiredSamples {
                isOnBoard = false
                alightStreak = 0
                boardStreak = 0
                return true
            }
        }
        return false
    }
}
