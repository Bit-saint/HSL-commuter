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
    /// Minutes after midnight to arrive by; nil = "leave now"-style commute.
    var arriveByMinutes: Int?
    /// Calendar weekdays (1 = Sunday … 7 = Saturday).
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var remindersEnabled = true

    func arriveBy(on day: Date) -> Date? {
        guard let m = arriveByMinutes else { return nil }
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day)
    }

    func isActive(on day: Date) -> Bool {
        weekdays.contains(Calendar.current.component(.weekday, from: day))
    }

    var reversed: Commute {
        var c = self
        c.id = UUID()
        c.name = "\(destination.name) → \(origin.name)"
        c.origin = destination
        c.destination = origin
        c.arriveByMinutes = nil
        return c
    }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    init(_ c: CLLocationCoordinate2D) { self.init(latitude: c.latitude, longitude: c.longitude) }
}
