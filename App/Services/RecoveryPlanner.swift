import Foundation
import MapKit
import ETAEngine
import HSLKit
import HSLDesign

/// One way to recover from a missed vehicle or connection.
struct RecoveryOption: Identifiable {
    var itinerary: Itinerary
    var firstTransit: Leg
    /// Where you need to go to catch it.
    var boardingStop: Place
    var walkDistance: Double
    /// Walking path from you (or your transfer stop) to the boarding stop.
    var walkPath: [GeoPoint]
    /// Compass direction from you to the stop, e.g. "northeast".
    var direction: String
    var advice: PaceAdvice
    var isFastest: Bool
    /// Minutes later than the original plan (negative = earlier).
    var delayVsPlan: Int

    var id: String { itinerary.id }
    var departure: Date { firstTransit.start }
    var arrival: Date { itinerary.end }
    var line: String { firstTransit.route?.shortName ?? firstTransit.mode.displayName }

    /// "Walk 240 m northeast to Rautatientori, platform 3"
    var whereToGo: String {
        let platform = boardingStop.stop?.platform.map { ", platform \($0)" }
            ?? boardingStop.stop?.code.map { " (\($0))" } ?? ""
        if walkDistance < 35 { return "Stay here: \(boardingStop.name)\(platform)" }
        let dist = walkDistance >= 1000 ? String(format: "%.1f km", walkDistance / 1000) : "\(Int(walkDistance.rounded())) m"
        return "Walk \(dist) \(direction) to \(boardingStop.name)\(platform)"
    }
}

/// Why we're recovering, and the options found.
struct RecoveryState {
    enum Reason: Equatable {
        case missed(line: String, stop: String)
        case connectionAtRisk(line: String, stop: String)
        case manual
        /// Your planned vehicle is running late and another route gets you there sooner.
        case fasterOption(line: String, minutesLate: Int, minutesSaved: Int)
        /// A leg of your trip isn't running (HSL disruption).
        case disruption(summary: String)
    }

    var reason: Reason
    var options: [RecoveryOption] = []
    var loading = true
    var error: String?
    var updatedAt = Date()
    var selectedId: String?

    var title: String {
        switch reason {
        case .missed(let line, let stop): return "Missed \(line) at \(stop)"
        case .connectionAtRisk(let line, let stop): return "You'll likely miss \(line) at \(stop)"
        case .manual: return "Missed your connection?"
        case .fasterOption(let line, let late, _): return "\(line) is running \(late) min late"
        case .disruption(let summary): return summary
        }
    }

    var subtitle: String {
        switch reason {
        case .fasterOption(_, _, let saved): return "There's a faster way: about \(saved) min sooner"
        default: return "Fastest ways to get there from here"
        }
    }

    var isSuggestion: Bool {
        if case .fasterOption = reason { return true }
        return false
    }

    var selected: RecoveryOption? {
        options.first { $0.id == selectedId } ?? options.first
    }
}

@MainActor
enum RecoveryPlanner {
    /// Plans from `origin` (where you are, or the stop you'll get off at) at `readyAt`,
    /// and returns reachable options, fastest first.
    static func options(from origin: GeoPoint, readyAt: Date, to destination: GeoPoint,
                        originalArrival: Date, app: AppModel) async throws -> [RecoveryOption] {
        let itineraries = try await app.client.plan(from: origin, to: destination, time: .departAt(readyAt),
                                                    count: 8, walkSpeed: app.effectiveWalkingSpeed)
        // Measure the real walk to each first stop.
        var walks: [String: (Double, [GeoPoint])] = [:]
        for it in itineraries {
            guard let leg = it.firstTransitLeg else { continue }
            let stopKey = leg.from.stop?.id ?? "\(leg.from.location.latitude),\(leg.from.location.longitude)"
            if walks[stopKey] == nil {
                walks[stopKey] = await app.walking.route(from: origin, to: leg.from.location)
            }
        }
        func stopKey(_ leg: Leg) -> String {
            leg.from.stop?.id ?? "\(leg.from.location.latitude),\(leg.from.location.longitude)"
        }

        let candidates: [ConnectionRecovery.Candidate] = itineraries.compactMap { it in
            guard let leg = it.firstTransitLeg, let walk = walks[stopKey(leg)] else { return nil }
            return ConnectionRecovery.Candidate(
                id: it.id, firstDeparture: leg.start, arrival: it.end, walkDistance: walk.0,
                transfers: max(it.transitLegs.count - 1, 0),
                boardingBuffer: ModeProfile.for(leg.mode).boardingBuffer + app.effectiveBuffer)
        }
        let ranked = ConnectionRecovery.rank(candidates, readyAt: readyAt, walkingSpeed: app.effectiveWalkingSpeed)
        let byId = Dictionary(itineraries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        return ranked.prefix(4).compactMap { r in
            guard let it = byId[r.candidate.id], let leg = it.firstTransitLeg, let walk = walks[stopKey(leg)] else { return nil }
            return RecoveryOption(
                itinerary: it, firstTransit: leg, boardingStop: leg.from,
                walkDistance: walk.0, walkPath: walk.1,
                direction: ConnectionRecovery.compassDirection(origin.bearing(to: leg.from.location)),
                advice: r.advice, isFastest: r.isFastest,
                delayVsPlan: Int((it.end.timeIntervalSince(originalArrival) / 60).rounded()))
        }
    }

    /// Walking directions to the stop in Apple Maps.
    static func openWalkingDirections(to place: Place) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.location.coordinate))
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}
