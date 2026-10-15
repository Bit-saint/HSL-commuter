import Foundation
import ETAEngine

// Domain models produced by `DigitransitClient`. Decoding of the raw GraphQL
// shapes lives in DigitransitClient.swift so these stay simple.

public struct StopRef: Sendable, Codable, Hashable, Identifiable {
    public var id: String          // "HSL:1040129"
    public var name: String
    public var code: String?
    public var platform: String?
    public var location: GeoPoint
    public var mode: TransitMode?

    public init(id: String, name: String, code: String? = nil, platform: String? = nil, location: GeoPoint, mode: TransitMode? = nil) {
        self.id = id
        self.name = name
        self.code = code
        self.platform = platform
        self.location = location
        self.mode = mode
    }
}

public struct RouteRef: Sendable, Codable, Hashable {
    public var id: String          // "HSL:2550"
    public var shortName: String
    public var longName: String?
    public var mode: TransitMode

    public init(id: String, shortName: String, longName: String? = nil, mode: TransitMode) {
        self.id = id
        self.shortName = shortName
        self.longName = longName
        self.mode = mode
    }
}

public struct Place: Sendable, Codable, Hashable {
    public var name: String
    public var location: GeoPoint
    public var stop: StopRef?

    public init(name: String, location: GeoPoint, stop: StopRef? = nil) {
        self.name = name
        self.location = location
        self.stop = stop
    }
}

public struct Leg: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(mode.rawValue)-\(trip?.tripId ?? "")-\(scheduledStart.timeIntervalSince1970)" }
    public var mode: TransitMode
    public var scheduledStart: Date
    public var scheduledEnd: Date
    public var estimatedStart: Date?
    public var estimatedEnd: Date?
    public var distance: Double
    public var from: Place
    public var to: Place
    public var geometry: [GeoPoint]
    public var route: RouteRef?
    public var trip: TripRef?
    public var headsign: String?
    public var isRealtime: Bool

    public init(mode: TransitMode, scheduledStart: Date, scheduledEnd: Date, estimatedStart: Date? = nil,
                estimatedEnd: Date? = nil, distance: Double, from: Place, to: Place, geometry: [GeoPoint],
                route: RouteRef? = nil, trip: TripRef? = nil, headsign: String? = nil, isRealtime: Bool = false) {
        self.mode = mode
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.estimatedStart = estimatedStart
        self.estimatedEnd = estimatedEnd
        self.distance = distance
        self.from = from
        self.to = to
        self.geometry = geometry
        self.route = route
        self.trip = trip
        self.headsign = headsign
        self.isRealtime = isRealtime
    }

    public var start: Date { estimatedStart ?? scheduledStart }
    public var end: Date { estimatedEnd ?? scheduledEnd }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct TripRef: Sendable, Codable, Hashable {
    public var tripId: String          // "HSL:2550_20261015_Ti_2_0715"
    public var directionId: Int
    public var serviceDate: String     // "yyyyMMdd"
    public var headsign: String?

    public init(tripId: String, directionId: Int, serviceDate: String, headsign: String? = nil) {
        self.tripId = tripId
        self.directionId = directionId
        self.serviceDate = serviceDate
        self.headsign = headsign
    }
}

public struct Itinerary: Sendable, Codable, Hashable, Identifiable {
    public var id: String { legs.map(\.id).joined(separator: "|") }
    public var start: Date
    public var end: Date
    public var legs: [Leg]
    public var walkDistance: Double

    public init(start: Date, end: Date, legs: [Leg], walkDistance: Double) {
        self.start = start
        self.end = end
        self.legs = legs
        self.walkDistance = walkDistance
    }

    public var transitLegs: [Leg] { legs.filter { $0.mode.isTransit } }
    public var firstTransitLeg: Leg? { legs.first { $0.mode.isTransit } }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Full detail of a trip, enough to build a `TripPattern`.
public struct TripDetails: Sendable {
    public var tripId: String
    public var route: RouteRef
    public var directionId: Int
    public var headsign: String
    public var serviceDate: String
    public var shape: [GeoPoint]
    public var stops: [PatternStop]
    /// Seconds after service-day midnight of the first stop's departure (for HFP matching).
    public var firstDepartureSeconds: Int

    public var hfpKey: HFP.TripKey {
        HFP.TripKey(routeGtfsId: route.id, gtfsDirectionId: directionId,
                    firstDepartureSeconds: firstDepartureSeconds, serviceDay: serviceDate)
    }

    public func pattern() -> TripPattern {
        TripPattern(tripId: tripId, routeId: route.id, routeShortName: route.shortName, headsign: headsign,
                    mode: route.mode, shape: shape, stops: stops)
    }
}

public struct Departure: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(tripId)-\(scheduled.timeIntervalSince1970)" }
    public var tripId: String
    public var route: RouteRef
    public var headsign: String
    public var scheduled: Date
    public var realtime: Date
    public var isRealtime: Bool
    public var directionId: Int
    public var serviceDate: String
}

public struct NearbyStop: Sendable, Hashable, Identifiable {
    public var id: String { stop.id }
    public var stop: StopRef
    public var distance: Double
}
