import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ETAEngine

public enum DigitransitError: Error, LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case graphQL([String])
    case notFound

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add your Digitransit API key in Settings."
        case .http(let code, let body): return "Digitransit HTTP \(code): \(body.prefix(200))"
        case .graphQL(let messages): return messages.joined(separator: "\n")
        case .notFound: return "Not found"
        }
    }
}

/// Digitransit Routing API v2 (HSL). Requires a free key from https://portal-api.digitransit.fi
public struct DigitransitClient: Sendable {
    public var apiKey: String
    public var endpoint = URL(string: "https://api.digitransit.fi/routing/v2/hsl/gtfs/v1")!
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    static let helsinki = TimeZone(identifier: "Europe/Helsinki")!

    // MARK: - Public API

    public enum TimeConstraint: Sendable {
        case departAt(Date)
        case arriveBy(Date)
    }

    public func plan(from origin: GeoPoint, to destination: GeoPoint, time: TimeConstraint = .departAt(Date()),
                     count: Int = 5, walkSpeed: Double = 1.35) async throws -> [Itinerary] {
        let iso = Self.offsetFormatter.string(from: {
            switch time { case .departAt(let d), .arriveBy(let d): return d }
        }())
        let dateTime: [String: Any] = {
            switch time {
            case .departAt: return ["earliestDeparture": iso]
            case .arriveBy: return ["latestArrival": iso]
            }
        }()
        let vars: [String: Any] = [
            "origin": ["location": ["coordinate": ["latitude": origin.latitude, "longitude": origin.longitude]]],
            "destination": ["location": ["coordinate": ["latitude": destination.latitude, "longitude": destination.longitude]]],
            "dateTime": dateTime,
            "first": count,
            "walkSpeed": walkSpeed,
        ]
        // Fare zones and prices come from newer schema fields; if the API refuses them, plan without.
        if !Self.faresUnsupported {
            do {
                let data: GQLPlanData = try await query(Queries.planWithFares, variables: vars)
                return data.planConnection.edges.compactMap { $0.node.toDomain() }
            } catch DigitransitError.graphQL {
                Self.faresUnsupported = true
            } catch DigitransitError.http(let code, _) where code == 400 {
                Self.faresUnsupported = true
            }
        }
        let data: GQLPlanData = try await query(Queries.plan, variables: vars)
        return data.planConnection.edges.compactMap { $0.node.toDomain() }
    }

    nonisolated(unsafe) static var faresUnsupported = false

    public func tripDetails(tripId: String, serviceDate: String) async throws -> TripDetails {
        let date = serviceDate.filter(\.isNumber)
        let data: GQLTripData = try await query(Queries.trip, variables: ["id": tripId, "date": date])
        guard let trip = data.trip else { throw DigitransitError.notFound }
        return try trip.toDomain(serviceDate: date)
    }

    public func departures(stopId: String, count: Int = 12) async throws -> (StopRef, [Departure]) {
        let data: GQLStopData = try await query(Queries.departures, variables: ["id": stopId, "n": count])
        guard let stop = data.stop else { throw DigitransitError.notFound }
        return (stop.ref, stop.stoptimesWithoutPatterns?.compactMap { $0.toDeparture() } ?? [])
    }

    public func nearbyStops(around point: GeoPoint, radius: Int = 600) async throws -> [NearbyStop] {
        let data: GQLNearbyData = try await query(Queries.nearby,
                                                   variables: ["lat": point.latitude, "lon": point.longitude, "r": radius])
        return data.stopsByRadius?.edges.compactMap { e in
            guard let s = e.node.stop else { return nil }
            return NearbyStop(stop: s.ref, distance: Double(e.node.distance ?? 0))
        } ?? []
    }

    /// Current HSL service alerts (disruptions, detours, stop changes).
    public func alerts() async throws -> [ServiceAlert] {
        let data: GQLAlertsData = try await query(Queries.alerts, variables: [:])
        return data.alerts?.compactMap { $0.toDomain() } ?? []
    }

    // MARK: - Transport

    func query<T: Decodable>(_ query: String, variables: [String: Any]) async throws -> T {
        guard !apiKey.isEmpty else { throw DigitransitError.missingAPIKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "digitransit-subscription-key")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DigitransitError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        let envelope = try JSONDecoder().decode(GQLEnvelope<T>.self, from: data)
        if let d = envelope.data { return d }
        throw DigitransitError.graphQL(envelope.errors?.map(\.message) ?? ["Empty response"])
    }

    static let offsetFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = helsinki
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = offsetFormatter.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func serviceDate(fromEpoch serviceDay: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = helsinki
        f.dateFormat = "yyyyMMdd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(serviceDay)))
    }
}

// MARK: - Queries

enum Queries {
    static let plan = """
    query Plan($origin: PlanLabeledLocationInput!, $destination: PlanLabeledLocationInput!, $dateTime: PlanDateTimeInput, $first: Int, $walkSpeed: Speed) {
      planConnection(origin: $origin, destination: $destination, dateTime: $dateTime, first: $first,
                     preferences: { street: { walk: { speed: $walkSpeed } } }) {
        edges { node {
          start end walkDistance
          legs {
            mode distance realTime headsign serviceDate
            start { scheduledTime estimated { time } }
            end { scheduledTime estimated { time } }
            from { name lat lon stop { gtfsId name code platformCode lat lon vehicleMode } }
            to { name lat lon stop { gtfsId name code platformCode lat lon vehicleMode } }
            legGeometry { points }
            route { gtfsId shortName longName mode type }
            trip { gtfsId directionId tripHeadsign departureStoptime { scheduledDeparture } }
          }
        } }
      }
    }
    """

    static let planWithFares = """
    query PlanWithFares($origin: PlanLabeledLocationInput!, $destination: PlanLabeledLocationInput!, $dateTime: PlanDateTimeInput, $first: Int, $walkSpeed: Speed) {
      planConnection(origin: $origin, destination: $destination, dateTime: $dateTime, first: $first,
                     preferences: { street: { walk: { speed: $walkSpeed } } }) {
        edges { node {
          start end walkDistance
          legs {
            mode distance realTime headsign serviceDate
            start { scheduledTime estimated { time } }
            end { scheduledTime estimated { time } }
            from { name lat lon stop { gtfsId name code platformCode lat lon vehicleMode zoneId } }
            to { name lat lon stop { gtfsId name code platformCode lat lon vehicleMode zoneId } }
            legGeometry { points }
            route { gtfsId shortName longName mode type }
            trip { gtfsId directionId tripHeadsign departureStoptime { scheduledDeparture } }
            fareProducts { id product { id name riderCategory { name } medium { name }
              ... on DefaultFareProduct { price { amount currency { code } } } } }
          }
        } }
      }
    }
    """

    static let trip = """
    query Trip($id: String!, $date: String!) {
      trip(id: $id) {
        gtfsId directionId tripHeadsign
        route { gtfsId shortName longName mode type }
        pattern { code geometry { lat lon } }
        tripGeometry { points }
        stoptimesForDate(serviceDate: $date) {
          stop { gtfsId name code platformCode lat lon }
          scheduledArrival scheduledDeparture realtimeArrival realtimeDeparture
          realtime realtimeState serviceDay timepoint
        }
      }
    }
    """

    static let departures = """
    query Departures($id: String!, $n: Int!) {
      stop(id: $id) {
        gtfsId name code platformCode lat lon vehicleMode
        stoptimesWithoutPatterns(numberOfDepartures: $n, omitNonPickups: true) {
          scheduledDeparture realtimeDeparture realtime serviceDay headsign
          trip { gtfsId directionId route { gtfsId shortName longName mode type } }
        }
      }
    }
    """

    static let alerts = """
    query Alerts {
      alerts(feeds: ["HSL"]) {
        id alertHeaderText alertDescriptionText alertSeverityLevel alertEffect
        effectiveStartDate effectiveEndDate
        route { gtfsId shortName }
        stop { gtfsId name }
      }
    }
    """

    static let nearby = """
    query Nearby($lat: Float!, $lon: Float!, $r: Int!) {
      stopsByRadius(lat: $lat, lon: $lon, radius: $r, first: 20) {
        edges { node { distance stop { gtfsId name code platformCode lat lon vehicleMode } } }
      }
    }
    """
}

// MARK: - Raw GraphQL shapes

struct GQLEnvelope<T: Decodable>: Decodable {
    struct GQLError: Decodable { var message: String }
    var data: T?
    var errors: [GQLError]?
}

struct GQLStop: Decodable {
    var gtfsId: String
    var name: String
    var code: String?
    var platformCode: String?
    var lat: Double
    var lon: Double
    var vehicleMode: String?
    var zoneId: String?

    var ref: StopRef {
        StopRef(id: gtfsId, name: name, code: code, platform: platformCode,
                location: GeoPoint(latitude: lat, longitude: lon),
                mode: vehicleMode.map { TransitMode.from(digitransitMode: $0) }, zone: zoneId)
    }
}

struct GQLRoute: Decodable {
    var gtfsId: String
    var shortName: String?
    var longName: String?
    var mode: String?
    var type: Int?

    var ref: RouteRef {
        RouteRef(id: gtfsId, shortName: shortName ?? "", longName: longName,
                 mode: TransitMode.from(digitransitMode: mode ?? "", routeType: type, shortName: shortName))
    }
}

struct GQLPlanData: Decodable {
    struct Connection: Decodable { var edges: [Edge] }
    struct Edge: Decodable { var node: GQLItinerary }
    var planConnection: Connection
}

struct GQLLegTime: Decodable {
    struct Estimated: Decodable { var time: String? }
    var scheduledTime: String
    var estimated: Estimated?
}

struct GQLPlace: Decodable {
    var name: String?
    var lat: Double
    var lon: Double
    var stop: GQLStop?

    var place: Place {
        Place(name: stop?.name ?? name ?? "", location: GeoPoint(latitude: lat, longitude: lon), stop: stop?.ref)
    }
}

struct GQLLeg: Decodable {
    struct Geometry: Decodable { var points: String? }
    struct Trip: Decodable {
        struct FirstStop: Decodable { var scheduledDeparture: Int? }
        var gtfsId: String
        var directionId: String?
        var tripHeadsign: String?
        var departureStoptime: FirstStop?
    }
    var mode: String
    var distance: Double?
    var realTime: Bool?
    var headsign: String?
    var serviceDate: String?
    var start: GQLLegTime
    var end: GQLLegTime
    var from: GQLPlace
    var to: GQLPlace
    var legGeometry: Geometry?
    var route: GQLRoute?
    var trip: Trip?
    var fareProducts: [GQLFareProductUse]?

    func toDomain() -> Leg? {
        guard let s = DigitransitClient.parseDate(start.scheduledTime),
              let e = DigitransitClient.parseDate(end.scheduledTime) else { return nil }
        let routeRef = route?.ref
        let mode = routeRef?.mode ?? TransitMode.from(digitransitMode: self.mode)
        let tripRef = trip.map {
            TripRef(tripId: $0.gtfsId, directionId: Int($0.directionId ?? "0") ?? 0,
                    serviceDate: (serviceDate ?? "").filter(\.isNumber), headsign: $0.tripHeadsign,
                    firstDepartureSeconds: $0.departureStoptime?.scheduledDeparture)
        }
        return Leg(mode: mode, scheduledStart: s, scheduledEnd: e,
                   estimatedStart: DigitransitClient.parseDate(start.estimated?.time),
                   estimatedEnd: DigitransitClient.parseDate(end.estimated?.time),
                   distance: distance ?? 0, from: from.place, to: to.place,
                   geometry: legGeometry?.points.map { Polyline.decodeGoogle($0) } ?? [],
                   route: routeRef, trip: tripRef, headsign: headsign ?? trip?.tripHeadsign,
                   isRealtime: realTime ?? false)
    }
}

struct GQLItinerary: Decodable {
    var start: String
    var end: String
    var walkDistance: Double?
    var legs: [GQLLeg]

    func toDomain() -> Itinerary? {
        guard let s = DigitransitClient.parseDate(start), let e = DigitransitClient.parseDate(end) else { return nil }
        return Itinerary(start: s, end: e, legs: legs.compactMap { $0.toDomain() }, walkDistance: walkDistance ?? 0,
                         fare: GQLFareProductUse.fare(for: legs))
    }
}

struct GQLFareProductUse: Decodable {
    struct Named: Decodable { var name: String? }
    struct Product: Decodable {
        struct Price: Decodable {
            struct Currency: Decodable { var code: String? }
            var amount: Double?
            var currency: Currency?
        }
        var id: String?
        var name: String?
        var riderCategory: Named?
        var medium: Named?
        var price: Price?
    }
    var id: String?
    var product: Product?

    /// One adult ticket for the whole itinerary: per leg the adult product (app or card), and each ticket
    /// use counted once even when it covers several legs.
    static func fare(for legs: [GQLLeg]) -> Fare? {
        var seen: Set<String> = []
        var total = 0.0
        var currency = "EUR"
        var names: [String] = []
        for leg in legs {
            guard let uses = leg.fareProducts, !uses.isEmpty else { continue }
            let priced = uses.filter { $0.product?.price?.amount != nil }
            func rank(_ u: GQLFareProductUse) -> Int {
                let rider = u.product?.riderCategory?.name?.lowercased() ?? ""
                let medium = u.product?.medium?.name?.lowercased() ?? ""
                var r = 0
                if rider.isEmpty || ["adult", "aikui", "vuxen"].contains(where: { rider.contains($0) }) { r += 2 }
                if ["app", "mobile", "sovellus"].contains(where: { medium.contains($0) }) { r += 1 }
                return r
            }
            guard let use = priced.max(by: { rank($0) < rank($1) }),
                  let amount = use.product?.price?.amount else { continue }
            let key = use.id ?? use.product?.id ?? UUID().uuidString
            guard seen.insert(key).inserted else { continue }
            total += amount
            currency = use.product?.price?.currency?.code ?? currency
            if let n = use.product?.name { names.append(n) }
        }
        guard total > 0 else { return nil }
        return Fare(name: names.count == 1 ? names[0] : nil, price: total, currency: currency)
    }
}

struct GQLTripData: Decodable {
    struct Trip: Decodable {
        struct Pattern: Decodable {
            struct Coord: Decodable { var lat: Double; var lon: Double }
            var code: String
            var geometry: [Coord]?
        }
        struct Stoptime: Decodable {
            var stop: GQLStop
            var scheduledArrival: Int
            var scheduledDeparture: Int
            var realtimeArrival: Int?
            var realtimeDeparture: Int?
            var realtime: Bool?
            var realtimeState: String?
            var serviceDay: Int
            var timepoint: Bool?
        }
        var gtfsId: String
        var directionId: String?
        var tripHeadsign: String?
        var route: GQLRoute
        struct Geometry: Decodable { var points: String? }
        var pattern: Pattern?
        var tripGeometry: Geometry?
        var stoptimesForDate: [Stoptime]?

        func toDomain(serviceDate: String) throws -> TripDetails {
            guard let times = stoptimesForDate, let first = times.first else { throw DigitransitError.notFound }
            // The trip's own shape follows the actual streets/tracks; fall back to the pattern's.
            let tripShape = tripGeometry?.points.map { Polyline.decodeGoogle($0) } ?? []
            let patternShape = pattern?.geometry?.map { GeoPoint(latitude: $0.lat, longitude: $0.lon) } ?? []
            let bestShape = tripShape.count >= patternShape.count ? tripShape : patternShape
            let stops: [PatternStop] = times.map { st in
                let day = TimeInterval(st.serviceDay)
                let hasRealtime = (st.realtime ?? false) && st.realtimeState != "CANCELED"
                return PatternStop(
                    id: st.stop.gtfsId, name: st.stop.name, code: st.stop.code,
                    location: GeoPoint(latitude: st.stop.lat, longitude: st.stop.lon),
                    scheduledArrival: Date(timeIntervalSince1970: day + TimeInterval(st.scheduledArrival)),
                    scheduledDeparture: Date(timeIntervalSince1970: day + TimeInterval(st.scheduledDeparture)),
                    isTimingPoint: st.timepoint ?? false,
                    feedArrival: hasRealtime ? st.realtimeArrival.map { Date(timeIntervalSince1970: day + TimeInterval($0)) } : nil,
                    feedDeparture: hasRealtime ? st.realtimeDeparture.map { Date(timeIntervalSince1970: day + TimeInterval($0)) } : nil)
            }
            return TripDetails(
                tripId: gtfsId, route: route.ref, directionId: Int(directionId ?? "0") ?? 0,
                headsign: tripHeadsign ?? stops.last?.name ?? "", serviceDate: serviceDate,
                shape: bestShape,
                stops: stops, firstDepartureSeconds: first.scheduledDeparture)
        }
    }
    var trip: Trip?
}

struct GQLStopData: Decodable {
    struct Stop: Decodable {
        struct Stoptime: Decodable {
            struct Trip: Decodable { var gtfsId: String; var directionId: String?; var route: GQLRoute }
            var scheduledDeparture: Int
            var realtimeDeparture: Int?
            var realtime: Bool?
            var serviceDay: Int
            var headsign: String?
            var trip: Trip?

            func toDeparture() -> Departure? {
                guard let trip else { return nil }
                let day = TimeInterval(serviceDay)
                return Departure(
                    tripId: trip.gtfsId, route: trip.route.ref, headsign: headsign ?? "",
                    scheduled: Date(timeIntervalSince1970: day + TimeInterval(scheduledDeparture)),
                    realtime: Date(timeIntervalSince1970: day + TimeInterval(realtimeDeparture ?? scheduledDeparture)),
                    isRealtime: realtime ?? false, directionId: Int(trip.directionId ?? "0") ?? 0,
                    serviceDate: DigitransitClient.serviceDate(fromEpoch: serviceDay))
            }
        }
        var gtfsId: String
        var name: String
        var code: String?
        var platformCode: String?
        var lat: Double
        var lon: Double
        var vehicleMode: String?
        var stoptimesWithoutPatterns: [Stoptime]?

        var ref: StopRef {
            GQLStop(gtfsId: gtfsId, name: name, code: code, platformCode: platformCode, lat: lat, lon: lon,
                    vehicleMode: vehicleMode).ref
        }
    }
    var stop: Stop?
}

struct GQLNearbyData: Decodable {
    struct Connection: Decodable { var edges: [Edge] }
    struct Edge: Decodable { var node: Node }
    struct Node: Decodable { var distance: Int?; var stop: GQLStop? }
    var stopsByRadius: Connection?
}


struct GQLAlertsData: Decodable {
    struct Alert: Decodable {
        struct Route: Decodable { var gtfsId: String; var shortName: String? }
        struct Stop: Decodable { var gtfsId: String; var name: String? }
        var id: String
        var alertHeaderText: String?
        var alertDescriptionText: String?
        var alertSeverityLevel: String?
        var alertEffect: String?
        var effectiveStartDate: Double?
        var effectiveEndDate: Double?
        var route: Route?
        var stop: Stop?

        func toDomain() -> ServiceAlert? {
            guard let header = alertHeaderText ?? alertDescriptionText else { return nil }
            return ServiceAlert(
                id: id, header: header, description: alertDescriptionText ?? "",
                severity: ServiceAlert.Severity(raw: alertSeverityLevel), effect: alertEffect,
                routeId: route?.gtfsId, routeName: route?.shortName, stopId: stop?.gtfsId, stopName: stop?.name,
                start: effectiveStartDate.map { Date(timeIntervalSince1970: $0) },
                end: effectiveEndDate.map { Date(timeIntervalSince1970: $0) })
        }
    }
    var alerts: [Alert]?
}
