import Foundation

/// A stay at a place (from iOS visit monitoring). Stored only on the device.
public struct Visit: Codable, Sendable, Equatable {
    public var arrival: Date
    public var departure: Date
    public var location: GeoPoint

    public init(arrival: Date, departure: Date, location: GeoPoint) {
        self.arrival = arrival
        self.departure = departure
        self.location = location
    }
}

/// Learns where home and work are, and when you usually arrive at and leave work.
public enum VisitLearner {
    public struct Cluster: Sendable {
        public var center: GeoPoint
        public var visits: [Visit]
    }

    static var calendar: Calendar { FinnishCalendar.calendar }

    /// Greedy clustering: visits within `radius` meters of a cluster's center join it.
    public static func cluster(_ visits: [Visit], radius: Double = 150) -> [Cluster] {
        var clusters: [Cluster] = []
        for v in visits {
            if let i = clusters.firstIndex(where: { $0.center.distance(to: v.location) <= radius }) {
                clusters[i].visits.append(v)
                let n = Double(clusters[i].visits.count)
                let c = clusters[i].center
                clusters[i].center = GeoPoint(latitude: c.latitude + (v.location.latitude - c.latitude) / n,
                                              longitude: c.longitude + (v.location.longitude - c.longitude) / n)
            } else {
                clusters.append(Cluster(center: v.location, visits: [v]))
            }
        }
        return clusters
    }

    private static func covers(_ v: Visit, hour: Int) -> Bool {
        var t = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: v.arrival) ?? v.arrival
        if t < v.arrival { t = calendar.date(byAdding: .day, value: 1, to: t) ?? t }
        return t <= v.departure
    }

    private static func distinctDays(_ visits: [Visit]) -> Int {
        Set(visits.map { FinnishCalendar.dayKey($0.arrival) }).count
    }

    /// Home: where you most often spend the night (3 am), on at least 3 nights.
    public static func suggestHome(from visits: [Visit]) -> GeoPoint? {
        let best = cluster(visits)
            .map { c in (c, distinctDays(c.visits.filter { covers($0, hour: 3) })) }
            .max { $0.1 < $1.1 }
        guard let best, best.1 >= 3 else { return nil }
        return best.0.center
    }

    /// Work: where you spend 3+ hours over midday on weekdays, on at least 3 days, away from home.
    public static func suggestWork(from visits: [Visit], home: GeoPoint?) -> GeoPoint? {
        let weekdayDaytime = visits.filter { v in
            let wd = calendar.component(.weekday, from: v.arrival)
            return (2...6).contains(wd) && covers(v, hour: 12) && v.departure.timeIntervalSince(v.arrival) >= 3 * 3600
        }
        let best = cluster(weekdayDaytime)
            .filter { c in home.map { c.center.distance(to: $0) > 300 } ?? true }
            .max { distinctDays($0.visits) < distinctDays($1.visits) }
        guard let best, distinctDays(best.visits) >= 3 else { return nil }
        return best.center
    }

    /// Median weekday arrival at and departure from `work`, in minutes after midnight (needs 4+ days).
    public static func typicalTimes(from visits: [Visit], work: GeoPoint, radius: Double = 200)
        -> (arrive: Int?, leave: Int?) {
        let atWork = visits.filter { v in
            let wd = calendar.component(.weekday, from: v.arrival)
            return (2...6).contains(wd) && v.location.distance(to: work) <= radius
                && v.departure.timeIntervalSince(v.arrival) >= 2 * 3600
                && v.arrival > Date.distantPast && v.departure < Date.distantFuture
        }
        func minutes(_ d: Date) -> Int {
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        func median(_ xs: [Int]) -> Int? {
            guard xs.count >= 4 else { return nil }
            let s = xs.sorted()
            return s[s.count / 2]
        }
        // First arrival / last departure per day.
        let byDay = Dictionary(grouping: atWork) { FinnishCalendar.dayKey($0.arrival) }
        let arrivals = byDay.values.compactMap { $0.map(\.arrival).min() }.map(minutes)
        let departures = byDay.values.compactMap { $0.map(\.departure).max() }.map(minutes)
        // Round to 5 minutes for friendlier suggestions.
        let round5 = { (m: Int) in Int((Double(m) / 5).rounded()) * 5 }
        return (median(arrivals).map(round5), median(departures).map(round5))
    }
}
