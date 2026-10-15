import CoreLocation
import Foundation
import Observation
import ETAEngine
import HSLKit

/// Plays a `TripRecording` back on a virtual clock (demo mode): vehicle fixes and your GPS track
/// come out exactly as they were recorded, faster than real time if you like.
@MainActor
@Observable
final class TripReplay {
    let recording: TripRecording
    private(set) var speed: Double
    private(set) var paused = false
    @ObservationIgnored private var anchorReal = Date()
    @ObservationIgnored private var anchorVirtual: Date
    @ObservationIgnored private var cursor = 0

    static let speeds: [Double] = [1, 4, 10, 20]

    init(recording: TripRecording, speed: Double = 10) {
        self.recording = recording
        self.speed = speed
        self.anchorVirtual = recording.startedAt
    }

    /// The recording's time right now. Stops at the end.
    var now: Date {
        let t = paused ? anchorVirtual : anchorVirtual.addingTimeInterval(Date().timeIntervalSince(anchorReal) * speed)
        return min(t, recording.endedAt)
    }

    var isFinished: Bool { now >= recording.endedAt }
    var progress: Double {
        let total = recording.endedAt.timeIntervalSince(recording.startedAt)
        return total > 0 ? now.timeIntervalSince(recording.startedAt) / total : 1
    }

    func setSpeed(_ s: Double) {
        rebase()
        speed = s
    }

    func togglePause() {
        rebase()
        paused.toggle()
    }

    /// Jump ahead, e.g. to skip waiting.
    func skip(_ seconds: TimeInterval) {
        rebase()
        anchorVirtual = min(anchorVirtual.addingTimeInterval(seconds), recording.endedAt)
    }

    private func rebase() {
        anchorVirtual = now
        anchorReal = Date()
    }

    func details(for tripId: String) -> TripDetails? { recording.trips.first { $0.tripId == tripId } }

    /// Vehicle fixes recorded up to `time` that haven't been handed out yet.
    func observations(until time: Date) -> [TripRecording.Observation] {
        let all = recording.vehicles
        var out: [TripRecording.Observation] = []
        while cursor < all.count, all[cursor].observation.timestamp <= time {
            out.append(all[cursor])
            cursor += 1
        }
        return out
    }

    /// Your position at `time`, interpolated between recorded fixes.
    func location(at time: Date) -> CLLocation? {
        let fixes = recording.locations
        guard let first = fixes.first, time >= first.time else { return nil }
        var lo = 0, hi = fixes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fixes[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        let a = fixes[lo]
        let b = lo + 1 < fixes.count ? fixes[lo + 1] : a
        let span = b.time.timeIntervalSince(a.time)
        let f = span > 0 ? min(max(time.timeIntervalSince(a.time) / span, 0), 1) : 0
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                               longitude: a.longitude + (b.longitude - a.longitude) * f),
            altitude: 0, horizontalAccuracy: a.accuracy, verticalAccuracy: -1,
            course: a.course, speed: a.speed, timestamp: time)
    }
}

/// Captures a real commute as a `TripRecording` (Settings › Demo › Record my trips).
@MainActor
final class TripRecorder {
    private let startedAt = Date()
    private var trips: [String: TripDetails] = [:]
    private var vehicles: [TripRecording.Observation] = []
    private var locations: [TripRecording.Location] = []

    func add(_ details: TripDetails) { trips[details.tripId] = details }

    func add(tripId: String, observation: VehicleObservation) {
        guard vehicles.count < 20_000 else { return }
        vehicles.append(.init(tripId: tripId, observation: observation))
    }

    func add(_ location: CLLocation) {
        guard locations.count < 20_000 else { return }
        locations.append(.init(time: location.timestamp, latitude: location.coordinate.latitude,
                               longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy,
                               speed: location.speed, course: location.course))
    }

    /// Writes the recording if there's enough of it to be worth replaying.
    func save(itinerary: Itinerary, destinationName: String) {
        guard locations.count >= 60 || vehicles.count >= 30 else { return }
        let end = Date()
        let name = "\(destinationName) · \(startedAt.formatted(date: .abbreviated, time: .shortened))"
        let rec = TripRecording(name: name, destinationName: destinationName, startedAt: startedAt, endedAt: end,
                                itinerary: itinerary, trips: Array(trips.values), vehicles: vehicles, locations: locations)
        guard let data = try? rec.encoded() else { return }
        let dir = TripRecorder.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("trip-\(Int(startedAt.timeIntervalSince1970)).json")
        try? data.write(to: file, options: .atomic)
    }

    static var directory: URL {
        URL.documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Saved recordings, newest first.
    static func saved() -> [(url: URL, recording: TripRecording)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? TripRecording.decode($0) }.map { (url: url, recording: $0) } }
            .sorted { $0.recording.startedAt > $1.recording.startedAt }
    }

    static var sample: TripRecording? {
        guard let url = Bundle.main.url(forResource: "sample-trip", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? TripRecording.decode(data)
    }
}
