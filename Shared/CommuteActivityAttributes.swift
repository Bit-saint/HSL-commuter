import ActivityKit
import Foundation
import ETAEngine

/// Live Activity shown on the Lock Screen and in the Dynamic Island during a commute.
/// Compiled into both the app and the widget extension.
struct CommuteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case walking, waiting, riding, transfer, arrived
        }

        var phase: Phase
        var line: String
        var mode: TransitMode
        var headsign: String
        /// Boarding stop while walking/waiting, alighting stop while riding.
        var stopName: String
        /// Vehicle arrival at `stopName`.
        var eta: Date
        var etaEarliest: Date
        var etaLatest: Date
        var isLive: Bool
        var pace: PaceState
        var paceMessage: String
        var leaveAt: Date?
        /// 0…1 progress bar (vehicle approaching your stop, or your ride).
        var progress: Double
        var nextStopName: String?
        var occupancy: Int?
        /// e.g. "Metro M1 · 3 min to change · tight"
        var transferNote: String?
    }

    var destinationName: String
    var startedAt: Date
}

extension CommuteActivityAttributes.ContentState {
    static let preview = CommuteActivityAttributes.ContentState(
        phase: .walking, line: "550", mode: .trunkBus, headsign: "Itäkeskus", stopName: "Pasila",
        eta: Date().addingTimeInterval(360), etaEarliest: Date().addingTimeInterval(320),
        etaLatest: Date().addingTimeInterval(420), isLive: true, pace: .walkBriskly,
        paceMessage: "Walk briskly · 320 m", leaveAt: Date(), progress: 0.62, nextStopName: "Ilmala",
        occupancy: 31, transferNote: nil)
}
