import Foundation
import ETAEngine

/// An HSL service alert as published by Digitransit.
public struct ServiceAlert: Sendable, Hashable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case info, warning, severe

        init(raw: String?) {
            switch raw?.uppercased() {
            case "SEVERE": self = .severe
            case "WARNING": self = .warning
            default: self = .info
            }
        }

        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String
    public var header: String
    public var description: String
    public var severity: Severity
    /// GTFS-RT effect: NO_SERVICE, REDUCED_SERVICE, SIGNIFICANT_DELAYS, DETOUR, STOP_MOVED, …
    public var effect: String?
    public var routeId: String?
    public var routeName: String?
    public var stopId: String?
    public var stopName: String?
    public var start: Date?
    public var end: Date?

    public init(id: String, header: String, description: String, severity: Severity, effect: String?,
                routeId: String?, routeName: String?, stopId: String?, stopName: String?, start: Date?, end: Date?) {
        self.id = id
        self.header = header
        self.description = description
        self.severity = severity
        self.effect = effect
        self.routeId = routeId
        self.routeName = routeName
        self.stopId = stopId
        self.stopName = stopName
        self.start = start
        self.end = end
    }

    public func isActive(at date: Date) -> Bool {
        (start.map { $0 <= date } ?? true) && (end.map { $0 >= date } ?? true)
    }

    /// Whether the vehicle doesn't run at all (vs. just runs differently).
    public var stopsService: Bool { effect?.uppercased() == "NO_SERVICE" }
}

/// A disruption that matters for one specific trip, said plainly.
public struct Disruption: Sendable, Hashable, Identifiable {
    public var alert: ServiceAlert
    /// e.g. "Metro M2 isn't running"
    public var summary: String
    /// What it means for you, e.g. "Your trip uses it. We'll find another way."
    public var consequence: String
    /// The itinerary leg it affects.
    public var legIndex: Int

    public var id: String { "\(alert.id)-\(legIndex)" }
    public var severity: ServiceAlert.Severity { alert.stopsService ? .severe : alert.severity }
}

public enum DisruptionDigest {
    /// Alerts that touch the routes or stops this itinerary uses, in plain language, most severe first.
    public static func relevant(_ alerts: [ServiceAlert], to itinerary: Itinerary, at date: Date = Date()) -> [Disruption] {
        var out: [Disruption] = []
        for (i, leg) in itinerary.legs.enumerated() where leg.mode.isTransit {
            let line = leg.route?.shortName ?? ""
            let noun = modeNoun(leg.mode)
            let stops = [leg.from.stop?.id, leg.to.stop?.id].compactMap { $0 }
            for alert in alerts where alert.isActive(at: date) {
                let routeHit = alert.routeId != nil && alert.routeId == leg.route?.id
                let stopHit = alert.stopId.map { stops.contains($0) } ?? false
                guard routeHit || stopHit else { continue }
                let subject = routeHit ? "\(noun) \(line)" : (alert.stopName ?? leg.from.name)
                out.append(Disruption(alert: alert,
                                      summary: "\(subject) \(effectPhrase(alert.effect, isStop: !routeHit))",
                                      consequence: consequence(alert, leg: leg, routeHit: routeHit),
                                      legIndex: i))
            }
        }
        // One entry per alert, most severe first.
        var seen = Set<String>()
        return out.filter { seen.insert($0.alert.id).inserted }.sorted { $0.severity > $1.severity }
    }

    static func modeNoun(_ mode: TransitMode) -> String {
        switch mode {
        case .bus, .trunkBus, .uBus: return "Bus"
        case .tram, .lightRail: return "Tram"
        case .metro: return "Metro"
        case .rail: return "Train"
        case .ferry: return "Ferry"
        default: return "Line"
        }
    }

    static func effectPhrase(_ effect: String?, isStop: Bool) -> String {
        switch effect?.uppercased() {
        case "NO_SERVICE": return isStop ? "isn't served right now" : "isn't running"
        case "REDUCED_SERVICE": return "is running less often"
        case "SIGNIFICANT_DELAYS": return "has big delays"
        case "DETOUR": return isStop ? "is affected by a detour" : "is on a detour"
        case "STOP_MOVED": return "has moved temporarily"
        case "ADDITIONAL_SERVICE": return "has extra departures"
        case "MODIFIED_SERVICE": return "is running differently"
        default: return isStop ? "has a notice" : "has a disruption"
        }
    }

    static func consequence(_ alert: ServiceAlert, leg: Leg, routeHit: Bool) -> String {
        switch alert.effect?.uppercased() {
        case "NO_SERVICE": return "Your trip uses it. We'll find you another way."
        case "SIGNIFICANT_DELAYS": return "Expect delays. Your countdown already uses live positions."
        case "DETOUR": return "Your stop may not be served. Check where to board."
        case "STOP_MOVED": return "Board at the temporary stop nearby."
        case "REDUCED_SERVICE": return "If you miss one, the next may be a while."
        default: return routeHit ? "Might affect your trip." : "Check the stop before you go."
        }
    }
}
