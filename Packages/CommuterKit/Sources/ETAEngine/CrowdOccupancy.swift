import Foundation

/// How full a vehicle is, as reported by riders.
public enum CrowdLevel: Int, Codable, Sendable, CaseIterable {
    case seats = 0
    case standing = 1
    case full = 2

    public var title: String {
        switch self {
        case .seats: return "Seats"
        case .standing: return "Standing"
        case .full: return "Full"
        }
    }
}

/// One rider's answer for one trip.
public struct CrowdReport: Codable, Sendable, Equatable {
    /// Stable id of the trip (route|direction|start|day), shared by all riders.
    public var tripKey: String
    public var level: CrowdLevel
    public var time: Date

    public init(tripKey: String, level: CrowdLevel, time: Date) {
        self.tripKey = tripKey
        self.level = level
        self.time = time
    }
}

public struct CrowdEstimate: Sendable, Hashable {
    public var level: CrowdLevel
    public var reports: Int
    public var newest: Date

    /// "Standing · 3 riders, 4 min ago"
    public func label(now: Date) -> String {
        let mins = max(Int(now.timeIntervalSince(newest) / 60), 0)
        let who = reports == 1 ? "1 rider" : "\(reports) riders"
        return "\(level.title) · \(who), \(mins == 0 ? "just now" : "\(mins) min ago")"
    }
}

public enum CrowdOccupancy {
    /// Recent reports weigh more (half-life ~7 min); older than `maxAge` are ignored.
    public static func estimate(_ reports: [CrowdReport], now: Date,
                                maxAge: TimeInterval = 30 * 60) -> CrowdEstimate? {
        let fresh = reports.filter { now.timeIntervalSince($0.time) <= maxAge && $0.time <= now.addingTimeInterval(60) }
        guard let newest = fresh.map(\.time).max() else { return nil }
        var weight: [CrowdLevel: Double] = [:]
        for r in fresh {
            let age = max(now.timeIntervalSince(r.time), 0)
            weight[r.level, default: 0] += exp(-age / 600)
        }
        // Ties go to the fuller level: better to warn than to disappoint.
        guard let level = weight.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue < $1.key.rawValue })?.key
        else { return nil }
        return CrowdEstimate(level: level, reports: fresh.count, newest: newest)
    }

    /// Whether to ask the rider now. Asks at most once per ride, only after they've been on board
    /// for a minute (so they've seen the vehicle), and only on a random share of rides.
    public static func shouldAsk(onBoardFor seconds: TimeInterval, alreadyDecided: Bool,
                                 roll: Double, probability: Double = 0.35) -> Bool? {
        guard !alreadyDecided, seconds >= 60 else { return nil }   // nil = not yet decided
        return roll < probability
    }

    /// Maps the HFP sensor percentage to the same levels.
    public static func level(fromPercent p: Int) -> CrowdLevel {
        p < 40 ? .seats : (p < 80 ? .standing : .full)
    }
}
