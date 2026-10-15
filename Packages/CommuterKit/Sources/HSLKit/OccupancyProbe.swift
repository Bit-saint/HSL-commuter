import Foundation
import ETAEngine

/// Peeks at the live feed for a few seconds to see how full upcoming vehicles are.
/// Only vehicles already running report occupancy (HFP `occu`, 0–100).
public enum OccupancyProbe {
    /// - Parameter trips: id → HFP key
    /// - Returns: id → occupancy percent, for the vehicles that reported one
    public static func probe(_ trips: [String: HFP.TripKey], timeout: TimeInterval = 6) async -> [String: Int] {
        guard !trips.isEmpty else { return [:] }
        let client = MQTTClient(url: HFP.brokerURL)
        await client.connect()
        for key in Set(trips.values) {
            // Position messages only; they carry occupancy.
            await client.subscribe("/hfp/v2/journey/ongoing/vp/+/+/+/\(key.route)/\(key.direction)/+/\(key.startTime)/#")
        }
        let stream = client.messages
        let collector = Task { () -> [String: Int] in
            var found: [String: Int] = [:]
            for await message in stream {
                guard let topic = HFP.Topic(message.topic),
                      let obs = HFP.decode(topic: message.topic, payload: message.payload),
                      let occu = obs.occupancyPercent else { continue }
                for (id, key) in trips
                where key.route == topic.routeId && key.direction == topic.directionId && key.startTime == topic.startTime {
                    found[id] = occu
                }
                if found.count == trips.count { break }
            }
            return found
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collector.cancel()
        }
        let result = await collector.value
        timer.cancel()
        await client.disconnect()
        return result
    }
}
