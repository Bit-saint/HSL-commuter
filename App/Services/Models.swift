import Foundation
import CoreLocation
import ETAEngine

struct SavedPlace: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var point: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// A saved commute, e.g. Home → Work, weekdays, arrive by 8:30.
struct Commute: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var origin: SavedPlace
    var destination: SavedPlace
    /// Minutes after midnight to arrive by.
    var arriveByMinutes: Int?
    /// Minutes after midnight to leave at (e.g. leaving work). Used when there's no arrive-by time.
    var leaveAtMinutes: Int?
    /// Calendar weekdays (1 = Sunday … 7 = Saturday).
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var remindersEnabled = true

    func arriveBy(on day: Date) -> Date? {
        guard let m = arriveByMinutes else { return nil }
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day)
    }

    func leaveAt(on day: Date) -> Date? {
        guard let m = leaveAtMinutes else { return nil }
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day)
    }

    func isActive(on day: Date) -> Bool {
        weekdays.contains(Calendar.current.component(.weekday, from: day))
    }

    var reversed: Commute {
        var c = self
        // Stable id derived from the original, so views don't treat every render as a new commute.
        var bytes = id.uuid
        bytes.0 ^= 0xFF
        c.id = UUID(uuid: bytes)
        c.name = "\(destination.name) → \(origin.name)"
        c.origin = destination
        c.destination = origin
        c.arriveByMinutes = nil
        c.leaveAtMinutes = nil
        return c
    }
}

/// Arrive-at-work and leave-work times for one day, in minutes after midnight.
struct DayTimes: Codable, Hashable {
    var arriveAtWork: Int
    var leaveWork: Int
}

/// The user's home, work and working hours. Generates the two daily commutes.
struct HomeWorkSetup: Codable, Hashable {
    var home: SavedPlace?
    var work: SavedPlace?
    var defaultTimes = DayTimes(arriveAtWork: 8 * 60 + 30, leaveWork: 16 * 60 + 30)
    /// Per-weekday times (1 = Sunday … 7 = Saturday) when "different times per day" is on.
    var perDayTimes: [Int: DayTimes] = [:]
    var usesPerDayTimes = false
    var workdays: Set<Int> = [2, 3, 4, 5, 6]
    var remindersEnabled = true

    static let toWorkID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
    static let toHomeID = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!

    var isComplete: Bool { home != nil && work != nil }

    func times(forWeekday weekday: Int) -> DayTimes {
        usesPerDayTimes ? (perDayTimes[weekday] ?? defaultTimes) : defaultTimes
    }

    func times(on date: Date) -> DayTimes {
        times(forWeekday: Calendar.current.component(.weekday, from: date))
    }

    /// Home → Work (arrive by) and Work → Home (leave at) for the given day.
    func commutes(on date: Date) -> [Commute] {
        guard let home, let work else { return [] }
        let t = times(on: date)
        return [
            Commute(id: Self.toWorkID, name: "To work", origin: home, destination: work,
                    arriveByMinutes: t.arriveAtWork, leaveAtMinutes: nil,
                    weekdays: workdays, remindersEnabled: remindersEnabled),
            Commute(id: Self.toHomeID, name: "To home", origin: work, destination: home,
                    arriveByMinutes: nil, leaveAtMinutes: t.leaveWork,
                    weekdays: workdays, remindersEnabled: remindersEnabled),
        ]
    }

    /// Before the middle of the working day you're heading to work, after it home.
    func isMorning(_ date: Date) -> Bool {
        let t = times(on: date)
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minutes < (t.arriveAtWork + t.leaveWork) / 2
    }
}

extension Int {
    /// Minutes after midnight as "8:30".
    var clockString: String { String(format: "%d:%02d", self / 60, self % 60) }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    init(_ c: CLLocationCoordinate2D) { self.init(latitude: c.latitude, longitude: c.longitude) }
}
