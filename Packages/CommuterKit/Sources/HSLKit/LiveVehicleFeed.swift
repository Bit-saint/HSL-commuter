import Foundation
import ETAEngine

/// One feed for all live vehicle data the app needs: HSL HFP for buses, trams,
/// metro and ferries, plus Digitraffic for commuter trains. Observations come
/// out tagged with the trip id they belong to.
public actor LiveVehicleFeed {
    public struct Update: Sendable {
        public var tripId: String
        public var observation: VehicleObservation
    }

    private let hfp: MQTTClient
    private let rail: MQTTClient
    private let railAPI = DigitrafficRailClient()
    private var hfpTrips: [String: HFP.TripKey] = [:]           // tripId -> key
    private var railTrips: [String: (number: Int, date: String)] = [:]
    private var stationsCache: [DigitrafficRailClient.Station]?
    private var pumps: [Task<Void, Never>] = []
    private var started = false

    private var continuation: AsyncStream<Update>.Continuation?
    public nonisolated let updates: AsyncStream<Update>

    public init() {
        hfp = MQTTClient(url: HFP.brokerURL)
        rail = MQTTClient(url: DigitrafficRailClient.mqttURL)
        var cont: AsyncStream<Update>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(200)) { cont = $0 }
        continuation = cont
    }

    public func start() async {
        guard !started else { return }
        started = true
        let hfpMessages = hfp.messages
        let railMessages = rail.messages
        pumps.append(Task { [weak self] in
            for await m in hfpMessages {
                guard let obs = HFP.decode(topic: m.topic, payload: m.payload),
                      let topic = HFP.Topic(m.topic) else { continue }
                await self?.routeHFP(topic: topic, obs: obs)
            }
        })
        pumps.append(Task { [weak self] in
            for await m in railMessages {
                guard let loc = try? JSONDecoder().decode(DigitrafficRailClient.TrainLocation.self, from: m.payload),
                      let obs = loc.observation() else { continue }
                await self?.routeRail(number: loc.trainNumber, date: loc.departureDate, obs: obs)
            }
        })
        await hfp.connect()
    }

    public func stop() async {
        pumps.forEach { $0.cancel() }
        pumps.removeAll()
        hfpTrips.removeAll()
        railTrips.removeAll()
        await hfp.disconnect()
        await rail.disconnect()
        started = false
    }

    /// Starts following a trip. For trains, also tries to resolve the Digitraffic train.
    public func track(_ details: TripDetails, boardingStop: GeoPoint? = nil, scheduledBoarding: Date? = nil) async {
        let key = details.hfpKey
        hfpTrips[details.tripId] = key
        await hfp.subscribe(key.topicFilter)

        guard details.route.mode == .rail, let boardingStop, let scheduledBoarding else { return }
        do {
            if stationsCache == nil { stationsCache = try await railAPI.stations() }
            if let match = try await railAPI.matchTrain(line: details.route.shortName, near: boardingStop,
                                                        scheduledDeparture: scheduledBoarding,
                                                        stations: stationsCache ?? []) {
                let number = match.train.trainNumber, date = match.train.departureDate
                railTrips[details.tripId] = (number, date)
                await rail.connect()
                await rail.subscribe(DigitrafficRailClient.locationTopic(trainNumber: number, date: date))
                // Seed with the latest known location right away.
                if let loc = try await railAPI.latestLocation(trainNumber: number), let obs = loc.observation() {
                    continuation?.yield(Update(tripId: details.tripId, observation: obs))
                }
            }
        } catch {
            // Train matching is best effort; HFP + Digitransit realtime still apply.
        }
    }

    public func untrack(tripId: String) async {
        if let key = hfpTrips.removeValue(forKey: tripId) {
            await hfp.unsubscribe(key.topicFilter)
        }
        if let t = railTrips.removeValue(forKey: tripId) {
            await rail.unsubscribe(DigitrafficRailClient.locationTopic(trainNumber: t.number, date: t.date))
        }
    }

    private func routeHFP(topic: HFP.Topic, obs: VehicleObservation) {
        for (tripId, key) in hfpTrips
        where key.route == topic.routeId && key.direction == topic.directionId && key.startTime == topic.startTime {
            continuation?.yield(Update(tripId: tripId, observation: obs))
        }
    }

    private func routeRail(number: Int, date: String, obs: VehicleObservation) {
        for (tripId, t) in railTrips where t.number == number && t.date == date {
            continuation?.yield(Update(tripId: tripId, observation: obs))
        }
    }
}
