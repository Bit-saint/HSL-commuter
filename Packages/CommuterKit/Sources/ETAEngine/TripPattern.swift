import Foundation

public struct PatternStop: Sendable, Codable, Hashable, Identifiable {
    public var id: String               // GTFS id, e.g. "HSL:1040129"
    public var name: String
    public var code: String?
    public var location: GeoPoint
    public var distanceAlong: Double    // meters from trip start
    public var scheduledArrival: Date
    public var scheduledDeparture: Date
    /// HSL timing point: a vehicle running early waits here until the scheduled departure.
    public var isTimingPoint: Bool
    /// Latest realtime prediction from Digitransit, if any.
    public var feedArrival: Date?
    public var feedDeparture: Date?

    public init(id: String, name: String, code: String? = nil, location: GeoPoint, distanceAlong: Double = 0,
                scheduledArrival: Date, scheduledDeparture: Date, isTimingPoint: Bool = false,
                feedArrival: Date? = nil, feedDeparture: Date? = nil) {
        self.id = id
        self.name = name
        self.code = code
        self.location = location
        self.distanceAlong = distanceAlong
        self.scheduledArrival = scheduledArrival
        self.scheduledDeparture = scheduledDeparture
        self.isTimingPoint = isTimingPoint
        self.feedArrival = feedArrival
        self.feedDeparture = feedDeparture
    }

    /// Numeric id as used in HFP payloads ("HSL:1040129" -> "1040129").
    public var hfpId: String { id.split(separator: ":").last.map(String.init) ?? id }
}

/// One concrete trip: its shape and the stops with schedule, positioned along the shape.
public struct TripPattern: Sendable {
    public var tripId: String
    public var routeId: String
    public var routeShortName: String
    public var headsign: String
    public var mode: TransitMode
    public var polyline: Polyline
    public var stops: [PatternStop]
    /// Whether `polyline` follows the real road/rail or is just straight lines between stops.
    public var followsRealGeometry: Bool
    /// Physics-based running time between stop i and i+1 along the real geometry, seconds.
    public private(set) var physicsRunTimes: [TimeInterval] = []

    public init(tripId: String, routeId: String, routeShortName: String, headsign: String, mode: TransitMode,
                shape: [GeoPoint], stops: [PatternStop]) {
        self.tripId = tripId
        self.routeId = routeId
        self.routeShortName = routeShortName
        self.headsign = headsign
        self.mode = mode
        // Fall back to a straight-line shape through the stops when no geometry is available.
        // A usable shape has more points than stops (otherwise it's just stop-to-stop lines).
        let real = shape.count >= max(2, stops.count)
        let line = Polyline(real ? shape : stops.map(\.location))
        self.polyline = line
        self.followsRealGeometry = real
        // Place stops along the shape, keeping the order monotonic.
        var placed: [PatternStop] = []
        var hint: Double = 0
        for var stop in stops {
            let proj = line.project(stop.location, near: hint, window: 5_000)
            let d = max(proj?.distanceAlong ?? hint, hint)
            stop.distanceAlong = d
            hint = d
            placed.append(stop)
        }
        self.stops = placed
        let profile = SpeedProfile.for(mode)
        self.physicsRunTimes = placed.indices.dropLast().map { i in
            RouteKinematics.travelTime(along: line, from: placed[i].distanceAlong, to: placed[i + 1].distanceAlong,
                                       profile: profile)
        }
    }

    /// Meters left to drive along the road/rail from `s` to stop `index`.
    public func remainingDistance(from s: Double, to index: Int) -> Double {
        guard stops.indices.contains(index) else { return 0 }
        return max(stops[index].distanceAlong - s, 0)
    }

    public var profile: ModeProfile { .for(mode) }

    public func stopIndex(id: String) -> Int? {
        stops.firstIndex { $0.id == id || $0.hfpId == id }
    }

    /// Index of the last stop at or before distance `s`.
    public func segmentIndex(containing s: Double) -> Int {
        var idx = 0
        for (i, stop) in stops.enumerated() where stop.distanceAlong <= s + 1 {
            idx = i
        }
        return idx
    }
}
