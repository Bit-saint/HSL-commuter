import Foundation
import ETAEngine

/// Data shared between the app and its widgets through the App Group.
/// Falls back to standard defaults when the App Group isn't available
/// (e.g. some free-account signing setups); widgets then show a placeholder.
enum SharedStore {
    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "group.fi.hslcommuter"
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// Snapshot of the next recommended departure for the home/lock-screen widget.
    struct NextDeparture: Codable, Hashable {
        var commuteName: String
        var line: String
        var mode: TransitMode
        var stopName: String
        var departure: Date
        var leaveAt: Date
        var arrival: Date
        var isRealtime: Bool
        var updatedAt: Date
    }

    private static let nextDepartureKey = "nextDeparture"

    static var nextDeparture: NextDeparture? {
        get {
            guard let data = defaults.data(forKey: nextDepartureKey) else { return nil }
            return try? JSONDecoder().decode(NextDeparture.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: nextDepartureKey)
            } else {
                defaults.removeObject(forKey: nextDepartureKey)
            }
        }
    }

    /// Set by the widget's "Start" button; the app picks it up on launch.
    static let pendingStartKey = "pendingStartCommute"
}
