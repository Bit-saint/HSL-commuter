import Foundation

/// Every vehicle type in the HSL area.
public enum TransitMode: String, Codable, Sendable, CaseIterable {
    case bus
    case trunkBus      // Runkolinja (route type 702), articulated
    case uBus          // Regional U-lines
    case tram
    case lightRail     // Raide-Jokeri (line 15)
    case metro
    case rail          // Commuter trains
    case ferry
    case walk
    case bicycle
    case unknown

    public var isTransit: Bool {
        switch self {
        case .walk, .bicycle, .unknown: return false
        default: return true
        }
    }

    /// Maps Digitransit `mode` plus GTFS `route.type` and short name to our modes.
    public static func from(digitransitMode mode: String, routeType: Int? = nil, shortName: String? = nil) -> TransitMode {
        switch mode.uppercased() {
        case "BUS":
            if routeType == 702 { return .trunkBus }
            if routeType == 701 { return .uBus }
            return .bus
        case "TRAM":
            return shortName == "15" ? .lightRail : .tram
        case "SUBWAY": return .metro
        case "RAIL": return .rail
        case "FERRY": return .ferry
        case "WALK": return .walk
        case "BICYCLE": return .bicycle
        default: return .unknown
        }
    }

    /// HFP `transport_mode` topic level.
    public var hfpMode: String? {
        switch self {
        case .bus, .trunkBus: return "bus"
        case .uBus: return "ubus"
        case .tram, .lightRail: return "tram"
        case .metro: return "metro"
        case .rail: return "train"
        case .ferry: return "ferry"
        default: return nil
        }
    }
}

/// Behaviour defaults per mode, used before the learned model has data.
public struct ModeProfile: Sendable {
    /// Expected dwell when the vehicle stops, seconds.
    public var dwell: TimeInterval
    /// Probability the vehicle actually stops (buses skip request stops).
    public var stopProbability: Double
    /// Margin to be at the stop before departure, seconds.
    public var boardingBuffer: TimeInterval
    /// Plausible top speed, m/s, used to sanity-check schedule data.
    public var maxSpeed: Double

    public static func `for`(_ mode: TransitMode) -> ModeProfile {
        switch mode {
        case .bus, .uBus: return ModeProfile(dwell: 12, stopProbability: 0.7, boardingBuffer: 30, maxSpeed: 25)
        case .trunkBus: return ModeProfile(dwell: 15, stopProbability: 0.85, boardingBuffer: 30, maxSpeed: 25)
        case .tram, .lightRail: return ModeProfile(dwell: 15, stopProbability: 0.95, boardingBuffer: 30, maxSpeed: 20)
        case .metro: return ModeProfile(dwell: 25, stopProbability: 1, boardingBuffer: 30, maxSpeed: 28)
        case .rail: return ModeProfile(dwell: 35, stopProbability: 1, boardingBuffer: 60, maxSpeed: 45)
        case .ferry: return ModeProfile(dwell: 60, stopProbability: 1, boardingBuffer: 120, maxSpeed: 12)
        default: return ModeProfile(dwell: 0, stopProbability: 0, boardingBuffer: 0, maxSpeed: 3)
        }
    }
}
