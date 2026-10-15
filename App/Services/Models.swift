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
    /// Days marked "working from home" ("yyyy-MM-dd", Helsinki time).
    var wfhDays: Set<String> = []

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
            Commute(id: Self.toWorkID, name: String(localized: "To work"), origin: home, destination: work,
                    arriveByMinutes: t.arriveAtWork, leaveAtMinutes: nil,
                    weekdays: workdays, remindersEnabled: remindersEnabled),
            Commute(id: Self.toHomeID, name: String(localized: "To home"), origin: work, destination: home,
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


/// Toggles for the automatic, "it just knows" features.
struct SmartSettings: Codable, Hashable {
    /// Start live tracking when you leave home/work in your commute window.
    var autoStart = true
    /// Spoken cues ("Walk a bit faster…").
    var voiceCues = true
    /// Only speak when headphones are connected.
    var voiceHeadphonesOnly = true
    /// "en" or "fi"
    var voiceLanguage = "en"
    var haptics = true
    /// Slow walking pace and add margin for snow, ice, rain and wind.
    var weatherAware = true
    /// Skip Finnish public holidays.
    var holidayAware = true
    /// Use the first meeting as arrive-by time, and skip days marked off in the calendar.
    var useCalendar = false
    /// Learn home, work and your usual times from where you spend time.
    var learnPlaces = true
    /// Now and then ask "how full is it?" while you ride.
    var askOccupancy = true
    /// Share those answers with other riders (needs CloudKit, see README).
    var shareOccupancy = true
}

/// Whether today is a commute day, and if not, why.
enum DayStatus: Equatable {
    case workday
    case dayOff(reason: String, symbol: String)

    var isWorkday: Bool { self == .workday }
}

/// Looks up a string that comes from a package (e.g. `CrowdLevel.title`) in the app's String Catalog.
func loc(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: nil, table: nil) }
