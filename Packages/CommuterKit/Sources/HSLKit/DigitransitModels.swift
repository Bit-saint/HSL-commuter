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
    /// HSL fare zone: "A", "B", "C" or "D".
    public var zone: String?

    public init(id: String, name: String, code: String? = nil, platform: String? = nil, location: GeoPoint,
                mode: TransitMode? = nil, zone: String? = nil) {
        self.id = id
        self.name = name
        self.code = code
        self.platform = platform
        self.location = location
        self.mode = mode
        self.zone = zone
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

    /// HFP key for this leg's vehicle, when the trip's first departure is known.
    public var hfpKey: HFP.TripKey? {
        guard let trip, let route, let first = trip.firstDepartureSeconds else { return nil }
        return HFP.TripKey(routeGtfsId: route.id, gtfsDirectionId: trip.directionId,
                           firstDepartureSeconds: first, serviceDay: trip.serviceDate)
    }
    public var end: Date { estimatedEnd ?? scheduledEnd }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct TripRef: Sendable, Codable, Hashable {
    public var tripId: String          // "HSL:2550_20261015_Ti_2_0715"
    public var directionId: Int
    public var serviceDate: String     // "yyyyMMdd"
    public var headsign: String?
    /// Scheduled departure of the trip's first stop, seconds after service-day midnight.
    public var firstDepartureSeconds: Int?

    public init(tripId: String, directionId: Int, serviceDate: String, headsign: String? = nil,
                firstDepartureSeconds: Int? = nil) {
        self.tripId = tripId
        self.directionId = directionId
        self.serviceDate = serviceDate
        self.headsign = headsign
        self.firstDepartureSeconds = firstDepartureSeconds
    }
}

public struct Itinerary: Sendable, Codable, Hashable, Identifiable {
    public var id: String { legs.map(\.id).joined(separator: "|") }
    public var start: Date
    public var end: Date
    public var legs: [Leg]
    public var walkDistance: Double
    /// Ticket price from HSL's fare data, when Digitransit provides it.
    public var fare: Fare?

    public init(start: Date, end: Date, legs: [Leg], walkDistance: Double, fare: Fare? = nil) {
        self.start = start
        self.end = end
        self.legs = legs
        self.walkDistance = walkDistance
        self.fare = fare
    }

    /// Zones the ticket must cover, e.g. "AB" or "ABC" (HSL zones are nested rings A–D).
    public var zones: String? { FareZones.ticketZones(legs.filter(\.mode.isTransit).flatMap { [$0.from.stop?.zone, $0.to.stop?.zone] }) }

    public var transitLegs: [Leg] { legs.filter { $0.mode.isTransit } }
    public var firstTransitLeg: Leg? { legs.first { $0.mode.isTransit } }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct Fare: Sendable, Codable, Hashable {
    public var name: String?
    public var price: Double
    public var currency: String

    public init(name: String?, price: Double, currency: String) {
        self.name = name
        self.price = price
        self.currency = currency
    }

    public var priceText: String {
        price.formatted(.currency(code: currency).locale(Locale(identifier: "fi_FI")))
    }
}

public enum FareZones {
    static let order = ["A", "B", "C", "D"]

    /// Smallest valid HSL ticket covering every zone touched: the continuous range of rings between
    /// the innermost and outermost one. One zone alone: A or B → AB, C → BC, D → D.
    public static func ticketZones(_ zones: [String?]) -> String? {
        let idx = zones.compactMap { z in z.flatMap { order.firstIndex(of: $0.uppercased()) } }
        guard let lo = idx.min(), let hi = idx.max() else { return nil }
        if lo == hi {
            switch lo {
            case 0, 1: return "AB"
            case 2: return "BC"
            default: return "D"
            }
        }
        return order[lo...hi].joined()
    }
}

/// Full detail of a trip, enough to build a `TripPattern`.
public struct TripDetails: Sendable, Codable {
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
