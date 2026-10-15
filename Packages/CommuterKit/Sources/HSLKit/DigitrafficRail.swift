import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ETAEngine

/// Fintraffic Digitraffic rail API, for commuter trains (HSL's HFP coverage for trains is limited).
/// Docs: https://www.digitraffic.fi/en/railway-traffic/
public struct DigitrafficRailClient: Sendable {
    public static let mqttURL = URL(string: "wss://rata.digitraffic.fi:443/mqtt")!
    public var baseURL = URL(string: "https://rata.digitraffic.fi/api/v1/")!
    private let session: URLSession
    private let userAgent = "HSLCommuter/1.0"

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public struct Station: Decodable, Sendable {
        public var stationShortCode: String
        public var stationName: String
        public var latitude: Double
        public var longitude: Double
        public var passengerTraffic: Bool
        public var location: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
    }

    public struct TimeTableRow: Decodable, Sendable {
        public var stationShortCode: String
        public var type: String               // "ARRIVAL" / "DEPARTURE"
        public var scheduledTime: String
        public var liveEstimateTime: String?
        public var actualTime: String?
        public var commercialTrack: String?
        public var cancelled: Bool
        public var trainStopping: Bool

        public var scheduled: Date? { DigitrafficRailClient.parse(scheduledTime) }
        public var estimate: Date? { DigitrafficRailClient.parse(actualTime) ?? DigitrafficRailClient.parse(liveEstimateTime) }
    }

    public struct Train: Decodable, Sendable {
        public var trainNumber: Int
        public var departureDate: String      // "yyyy-MM-dd"
        public var commuterLineID: String?
        public var cancelled: Bool
        public var timeTableRows: [TimeTableRow]
    }

    public struct TrainLocation: Decodable, Sendable {
        public struct Point: Decodable, Sendable { public var coordinates: [Double] } // [lon, lat]
        public var trainNumber: Int
        public var departureDate: String
        public var timestamp: String
        public var location: Point
        public var speed: Double?             // km/h

        public func observation() -> VehicleObservation? {
            guard location.coordinates.count >= 2 else { return nil }
            return VehicleObservation(
                vehicleId: "train/\(trainNumber)",
                timestamp: DigitrafficRailClient.parse(timestamp) ?? Date(),
                event: .vp,
                location: GeoPoint(latitude: location.coordinates[1], longitude: location.coordinates[0]),
                speed: speed.map { $0 / 3.6 },
                locationSource: "GPS")
        }
    }

    // MARK: - Calls

    public func stations() async throws -> [Station] {
        try await get("metadata/stations")
    }

    /// Commuter trains departing from a station soon.
    public func departures(station: String, count: Int = 30) async throws -> [Train] {
        try await get("live-trains/station/\(station)?arrived_trains=0&arriving_trains=0&departed_trains=0&departing_trains=\(count)&include_nonstopping=false&train_categories=Commuter")
    }

    public func train(number: Int, date: String) async throws -> Train? {
        let list: [Train] = try await get("trains/\(date)/\(number)")
        return list.first
    }

    public func latestLocation(trainNumber: Int) async throws -> TrainLocation? {
        let list: [TrainLocation] = try await get("train-locations/latest/\(trainNumber)")
        return list.first
    }

    /// MQTT topic for a train's live location.
    public static func locationTopic(trainNumber: Int, date: String) -> String {
        "train-locations/\(date)/\(trainNumber)"
    }

    /// Finds the Digitraffic train matching an HSL commuter rail leg:
    /// same line letter, departing the nearest station at the scheduled time.
    public func matchTrain(line: String, near stop: GeoPoint, scheduledDeparture: Date,
                           stations: [Station]) async throws -> (train: Train, station: Station)? {
        guard let station = stations.filter(\.passengerTraffic)
            .min(by: { $0.location.distance(to: stop) < $1.location.distance(to: stop) }),
              station.location.distance(to: stop) < 1_500 else { return nil }
        let trains = try await departures(station: station.stationShortCode)
        let match = trains.first { t in
            guard t.commuterLineID?.uppercased() == line.uppercased() else { return false }
            return t.timeTableRows.contains { r in
                r.stationShortCode == station.stationShortCode && r.type == "DEPARTURE" &&
                    abs((r.scheduled ?? .distantPast).timeIntervalSince(scheduledDeparture)) < 120
            }
        }
        return match.map { (train: $0, station: station) }
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "Digitraffic-User")
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
