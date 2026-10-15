import CoreMotion
import ETAEngine

/// Walking / in a vehicle / standing still, from the motion coprocessor (low power).
@MainActor
final class MotionService {
    private let manager = CMMotionActivityManager()
    private(set) var activity: BoardingDetector.Activity = .unknown
    private var running = false

    var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    func start() {
        guard isAvailable, !running else { return }
        running = true
        manager.startActivityUpdates(to: .main) { [weak self] a in
            guard let a, a.confidence != .low else { return }
            let mapped: BoardingDetector.Activity
            if a.automotive || a.cycling { mapped = .automotive }
            else if a.running { mapped = .running }
            else if a.walking { mapped = .walking }
            else if a.stationary { mapped = .stationary }
            else { mapped = .unknown }
            MainActor.assumeIsolated { self?.activity = mapped }
        }
    }

    func stop() {
        manager.stopActivityUpdates()
        running = false
        activity = .unknown
    }
}
