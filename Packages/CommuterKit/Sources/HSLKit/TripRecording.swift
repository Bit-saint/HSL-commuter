import Foundation
import ETAEngine

/// A commute captured for replay: the plan, the trips' stops and shapes, every live vehicle
/// fix and your GPS track. The demo mode plays one back on a virtual clock.
public struct TripRecording: Codable, Sendable {
    public struct Observation: Codable, Sendable {
        public var tripId: String
        public var observation: VehicleObservation

        public init(tripId: String, observation: VehicleObservation) {
            self.tripId = tripId
            self.observation = observation
        }
    }

    /// One GPS fix. Speed m/s and course degrees are negative when unknown, as in Core Location.
    public struct Location: Codable, Sendable {
        public var time: Date
        public var latitude: Double
        public var longitude: Double
        public var accuracy: Double
        public var speed: Double
        public var course: Double

        public init(time: Date, latitude: Double, longitude: Double, accuracy: Double, speed: Double, course: Double) {
            self.time = time
            self.latitude = latitude
            self.longitude = longitude
            self.accuracy = accuracy
            self.speed = speed
            self.course = course
        }
    }

    public var version = 1
    public var name: String
    public var destinationName: String
    public var startedAt: Date
    public var endedAt: Date
    public var itinerary: Itinerary
    public var trips: [TripDetails]
    public var vehicles: [Observation]
    public var locations: [Location]

    public init(name: String, destinationName: String, startedAt: Date, endedAt: Date, itinerary: Itinerary,
                trips: [TripDetails], vehicles: [Observation], locations: [Location]) {
        self.name = name
        self.destinationName = destinationName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.itinerary = itinerary
        self.trips = trips
        self.vehicles = vehicles
        self.locations = locations
    }

    public static func decode(_ data: Data) throws -> TripRecording {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var r = try decoder.decode(TripRecording.self, from: data)
        r.vehicles.sort { $0.observation.timestamp < $1.observation.timestamp }
        r.locations.sort { $0.time < $1.time }
        return r
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }
}
