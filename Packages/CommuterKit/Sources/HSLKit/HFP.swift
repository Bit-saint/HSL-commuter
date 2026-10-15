import Foundation
import ETAEngine

/// HSL High-Frequency Positioning (HFP v2).
/// Docs: https://digitransit.fi/en/developers/apis/5-realtime-api/vehicle-positions/high-frequency-positioning/
public enum HFP {
    public static let brokerURL = URL(string: "wss://mqtt.hsl.fi:443/")!

    /// Identifies one trip in HFP terms.
    public struct TripKey: Hashable, Sendable, Codable {
        /// Route id without feed prefix, e.g. "2550", "31M1", "1015".
        public var route: String
        /// HFP direction "1" or "2" (GTFS directionId + 1).
        public var direction: String
        /// Scheduled start time at the first stop, "HH:mm" local time.
        public var startTime: String
        /// Operating day, "yyyy-MM-dd".
        public var operatingDay: String

        public init(route: String, direction: String, startTime: String, operatingDay: String) {
            self.route = route
            self.direction = direction
            self.startTime = startTime
            self.operatingDay = operatingDay
        }

        /// Builds the key from Digitransit data.
        /// - Parameters:
        ///   - routeGtfsId: "HSL:2550"
        ///   - gtfsDirectionId: 0 or 1
        ///   - firstDepartureSeconds: scheduled departure at the first stop, seconds after service-day midnight (may exceed 24 h)
        ///   - serviceDay: "yyyyMMdd" or "yyyy-MM-dd"
        public init(routeGtfsId: String, gtfsDirectionId: Int, firstDepartureSeconds: Int, serviceDay: String) {
            route = routeGtfsId.split(separator: ":").last.map(String.init) ?? routeGtfsId
            direction = String(gtfsDirectionId + 1)
            let minutes = (firstDepartureSeconds / 60) % (24 * 60)
            startTime = String(format: "%02d:%02d", minutes / 60, minutes % 60)
            let digits = serviceDay.filter(\.isNumber)
            if digits.count == 8 {
                let y = digits.prefix(4), m = digits.dropFirst(4).prefix(2), d = digits.suffix(2)
                operatingDay = "\(y)-\(m)-\(d)"
            } else {
                operatingDay = serviceDay
            }
        }

        /// Topic filter that only matches this trip's vehicle (all event types).
        /// /hfp/v2/journey/ongoing/<event>/<mode>/<oper>/<veh>/<route>/<dir>/<headsign>/<start>/<next_stop>/<geohash…>
        public var topicFilter: String {
            "/hfp/v2/journey/ongoing/+/+/+/+/\(route)/\(direction)/+/\(startTime)/#"
        }
    }

    public struct Topic: Sendable, Equatable {
        public var temporalType: String
        public var eventType: String
        public var transportMode: String
        public var operatorId: String
        public var vehicleNumber: String
        public var routeId: String
        public var directionId: String
        public var headsign: String
        public var startTime: String
        public var nextStop: String

        public var vehicleId: String { "\(operatorId)/\(vehicleNumber)" }

        public init?(_ topic: String) {
            let parts = topic.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            // ["", "hfp", "v2", "journey", temporal, event, mode, oper, veh, route, dir, headsign, start, next_stop, ...]
            guard parts.count >= 14, parts[1] == "hfp" else { return nil }
            temporalType = parts[4]
            eventType = parts[5]
            transportMode = parts[6]
            operatorId = parts[7]
            vehicleNumber = parts[8]
            routeId = parts[9]
            directionId = parts[10]
            headsign = parts[11]
            startTime = parts[12]
            nextStop = parts[13]
        }
    }

    struct Payload: Decodable {
        var tst: String?
        var spd: Double?
        var hdg: Double?
        var lat: Double?
        var long: Double?
        var dl: Double?
        var drst: Double?
        var occu: Double?
        var stop: String?
        var loc: String?
        var oday: String?
        var start: String?

        enum CodingKeys: String, CodingKey { case tst, spd, hdg, lat, long, dl, drst, occu, stop, loc, oday, start }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func num(_ k: CodingKeys) -> Double? {
                if let d = try? c.decodeIfPresent(Double.self, forKey: k) { return d }
                if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Double(s) }
                return nil
            }
            func str(_ k: CodingKeys) -> String? {
                if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
                if let i = try? c.decodeIfPresent(Int.self, forKey: k) { return String(i) }
                return nil
            }
            tst = str(.tst)
            spd = num(.spd); hdg = num(.hdg); lat = num(.lat); long = num(.long)
            dl = num(.dl); drst = num(.drst); occu = num(.occu)
            stop = str(.stop); loc = str(.loc); oday = str(.oday); start = str(.start)
        }
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Decodes an HFP MQTT message into a normalized observation.
    public static func decode(topic: String, payload: Data, receivedAt: Date = Date()) -> VehicleObservation? {
        guard let t = Topic(topic),
              let dict = try? JSONDecoder().decode([String: Payload].self, from: payload),
              let entry = dict.first
        else { return nil }
        let eventKey = entry.key, p = entry.value

        let timestamp = p.tst.flatMap { isoFractional.date(from: $0) ?? iso.date(from: $0) } ?? receivedAt
        var location: GeoPoint?
        if let lat = p.lat, let lon = p.long { location = GeoPoint(latitude: lat, longitude: lon) }
        let nextStop = (t.nextStop == "EOL" || t.nextStop.isEmpty) ? nil : t.nextStop
        return VehicleObservation(
            vehicleId: t.vehicleId,
            timestamp: timestamp,
            event: VehicleEventKind(hfp: eventKey),
            location: location,
            speed: p.spd,
            heading: p.hdg,
            scheduleOffset: p.dl.map { Int($0) },
            doorsOpen: p.drst.map { $0 != 0 },
            occupancyPercent: p.occu.map { Int($0) },
            stopId: p.stop,
            nextStopId: nextStop,
            locationSource: p.loc
        )
    }
}

/// Streams observations for the trips you subscribe to.
public final class HFPClient: @unchecked Sendable {
    private let mqtt: MQTTClient

    public init(url: URL = HFP.brokerURL) {
        mqtt = MQTTClient(url: url)
    }

    public func start() async { await mqtt.connect() }
    public func stop() async { await mqtt.disconnect() }

    public func subscribe(_ key: HFP.TripKey) async { await mqtt.subscribe(key.topicFilter) }
    public func unsubscribe(_ key: HFP.TripKey) async { await mqtt.unsubscribe(key.topicFilter) }

    /// Decoded observations with their parsed topic. Consume from a single task only.
    public var observations: AsyncStream<(HFP.Topic, VehicleObservation)> {
        let source = mqtt.messages
        return AsyncStream { continuation in
            let task = Task {
                for await message in source {
                    guard let topic = HFP.Topic(message.topic),
                          let obs = HFP.decode(topic: message.topic, payload: message.payload) else { continue }
                    continuation.yield((topic, obs))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
