import Foundation

/// HFP event types. `vp` = vehicle position; the rest are stop and door events.
public enum VehicleEventKind: String, Codable, Sendable {
    case vp, due, arr, dep, ars, pde, pas, wait, doo, doc, tlr, tla, da, dout, ba, bout, vja, vjout
    case other

    public init(hfp raw: String) {
        self = VehicleEventKind(rawValue: raw.lowercased()) ?? .other
    }
}

/// One normalized observation of a vehicle, from any source (HFP, Digitraffic).
public struct VehicleObservation: Sendable, Codable, Equatable {
    public var vehicleId: String
    public var timestamp: Date
    public var event: VehicleEventKind
    public var location: GeoPoint?
    /// m/s
    public var speed: Double?
    /// Degrees, 0 = north.
    public var heading: Double?
    /// Seconds ahead (+) or behind (-) schedule, as HFP reports it.
    public var scheduleOffset: Int?
    public var doorsOpen: Bool?
    /// 0–100, nil if not reported.
    public var occupancyPercent: Int?
    /// Stop the event refers to (arr/dep/pde...) or the current stop.
    public var stopId: String?
    public var nextStopId: String?
    /// "GPS", "ODO", "MAN", "DR", "N/A"
    public var locationSource: String?

    public init(vehicleId: String, timestamp: Date, event: VehicleEventKind, location: GeoPoint? = nil,
                speed: Double? = nil, heading: Double? = nil, scheduleOffset: Int? = nil, doorsOpen: Bool? = nil,
                occupancyPercent: Int? = nil, stopId: String? = nil, nextStopId: String? = nil,
                locationSource: String? = nil) {
        self.vehicleId = vehicleId
        self.timestamp = timestamp
        self.event = event
        self.location = location
        self.speed = speed
        self.heading = heading
        self.scheduleOffset = scheduleOffset
        self.doorsOpen = doorsOpen
        self.occupancyPercent = occupancyPercent
        self.stopId = stopId
        self.nextStopId = nextStopId
        self.locationSource = locationSource
    }

    /// Positions we trust for the filter.
    public var hasUsableLocation: Bool {
        guard let location, location.latitude != 0 else { return false }
        if let src = locationSource?.uppercased(), src == "N/A" || src == "MAN" { return false }
        return true
    }
}
