import CoreLocation
import Foundation
import Observation
import ETAEngine
import HSLKit
import HSLDesign

/// A live commute: follows every vehicle of the itinerary, the user's position,
/// and turns it into pace advice, transfer checks, a Live Activity and alerts.
@MainActor
@Observable
final class CommuteSession {
    enum Phase: Equatable {
        case walking(toLeg: Int)
        case waiting(leg: Int)
        case riding(leg: Int)
        case arrived
    }

    /// Live state of one transit leg.
    struct LiveLeg {
        var index: Int
        var leg: Leg
        var details: TripDetails?
        var tracker: TripTracker?
        var boardIndex: Int?
        var alightIndex: Int?
        var boardingETA: ETAEstimate?
        var alightingETA: ETAEstimate?
        var loadError: String?

        var mode: TransitMode { leg.mode }
        var line: String { leg.route?.shortName ?? mode.displayName }
        var headsign: String { leg.headsign ?? details?.headsign ?? leg.to.name }
    }

    let itinerary: Itinerary
    let destinationName: String
    private(set) var phase: Phase
    private(set) var legs: [Int: LiveLeg] = [:]
    private(set) var pace: PaceAdvice?
    private(set) var transfer: TransferAssessment?
    private(set) var userLocation: CLLocation?
    private(set) var walkDistance: Double?
    private(set) var missedLeg: Int?
    /// Set when a vehicle or connection is missed: the fastest alternatives and where to go.
    private(set) var recovery: RecoveryState?
    /// Bumped every tick so views can animate.
    private(set) var tick = 0
    private(set) var now = Date()

    @ObservationIgnored private weak var app: AppModel?
    private let feed = LiveVehicleFeed()
    private let walkTracker: WalkTracker
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    @ObservationIgnored private var notified: Set<String> = []
    @ObservationIgnored private var lastFeedRefresh = Date.distantPast
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryOrigin: (point: GeoPoint, readyAt: Date)?
    @ObservationIgnored private var lastFasterCheck = Date.distantPast
    /// Minutes saved by a suggestion the user turned down; only suggest again if clearly better.
    @ObservationIgnored private var declinedSaving = 0

    init(itinerary: Itinerary, destinationName: String, app: AppModel) {
        self.itinerary = itinerary
        self.destinationName = destinationName
        self.app = app
        self.walkTracker = WalkTracker(router: app.walking)
        let first = itinerary.legs.firstIndex { $0.mode.isTransit } ?? 0
        self.phase = .walking(toLeg: first)
        for (i, leg) in itinerary.legs.enumerated() where leg.mode.isTransit {
            legs[i] = LiveLeg(index: i, leg: leg)
        }
    }

    var transitIndices: [Int] { legs.keys.sorted() }

    /// The leg the UI should focus on: the one being ridden, or the next one to catch.
    var focusLeg: LiveLeg? {
        switch phase {
        case .walking(let i), .waiting(let i), .riding(let i): return legs[i]
        case .arrived: return nil
        }
    }

    private var estimator: ETAEstimator {
        ETAEstimator(model: LearnedSegmentModel(store: app?.learnedSegments ?? LearnedSegmentStore()))
    }

    // MARK: - Lifecycle

    func start() async {
        guard let app else { return }
        // Keep running in the background like a navigation app.
        backgroundSession = CLBackgroundActivitySession()
        await feed.start()

        tasks.append(Task { [weak self] in await self?.consumeFeed() })
        tasks.append(Task { [weak self] in await self?.consumeLocation() })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.recompute()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        })

        await loadTrips(client: app.client)
        recompute()
        if let state = activityState() {
            app.liveActivity.start(destination: destinationName, state: state)
        }
    }

    func stop() {
        recoveryTask?.cancel()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        backgroundSession?.invalidate()
        backgroundSession = nil
        let feed = self.feed
        Task { await feed.stop() }
        app?.liveActivity.end(final: activityState())
    }

    /// User tapped "I'm on it".
    func confirmOnBoard() {
        switch phase {
        case .walking(let i), .waiting(let i): phase = .riding(leg: i)
        default: break
        }
        recompute()
    }

    /// Skip to the next transit leg (e.g. tracking went wrong).
    func skipLeg() {
        guard case .riding(let i) = phase else { return }
        advance(after: i)
    }

    // MARK: - Loading

    private func loadTrips(client: DigitransitClient) async {
        for i in transitIndices {
            guard let leg = legs[i]?.leg, let trip = leg.trip else { continue }
            do {
                let details = try await client.tripDetails(tripId: trip.tripId, serviceDate: trip.serviceDate)
                let pattern = details.pattern()
                let tracker = TripTracker(pattern: pattern, learner: app?.learnedSegments)
                legs[i]?.details = details
                legs[i]?.tracker = tracker
                legs[i]?.boardIndex = stopIndex(in: pattern, for: leg.from, after: 0)
                let board = legs[i]?.boardIndex ?? 0
                // A departure tracked from a stop board has no destination stop: ride to the end.
                legs[i]?.alightIndex = (leg.to.stop == nil && leg.distance == 0)
                    ? pattern.stops.count - 1
                    : stopIndex(in: pattern, for: leg.to, after: min(board + 1, pattern.stops.count - 1))
                await feed.track(details, boardingStop: leg.from.location, scheduledBoarding: leg.scheduledStart)
            } catch {
                legs[i]?.loadError = error.localizedDescription
            }
        }
    }

    private func stopIndex(in pattern: TripPattern, for place: Place, after start: Int) -> Int? {
        if let id = place.stop?.id,
           let i = pattern.stops.indices.first(where: { $0 >= start && pattern.stops[$0].id == id }) {
            return i
        }
        // Nearest stop by location.
        return pattern.stops.indices.filter { $0 >= start }
            .min { pattern.stops[$0].location.distance(to: place.location) < pattern.stops[$1].location.distance(to: place.location) }
    }

    private func refreshFeedPredictions() async {
        guard let client = app?.client else { return }
        lastFeedRefresh = Date()
        for i in transitIndices {
            guard let trip = legs[i]?.leg.trip, let tracker = legs[i]?.tracker else { continue }
            if let fresh = try? await client.tripDetails(tripId: trip.tripId, serviceDate: trip.serviceDate) {
                tracker.updateFeedPredictions(fresh.stops)
            }
        }
    }

    // MARK: - Streams

    private func consumeFeed() async {
        for await update in feed.updates {
            guard !Task.isCancelled else { return }
            for i in transitIndices where legs[i]?.details?.tripId == update.tripId {
                legs[i]?.tracker?.ingest(update.observation)
            }
        }
    }

    private func consumeLocation() async {
        do {
            for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                guard !Task.isCancelled else { return }
                guard let loc = update.location else { continue }
                userLocation = loc
                if case .walking = phase, loc.horizontalAccuracy < 20, loc.speed > 0 {
                    app?.observeWalkingSpeed(loc.speed)
                }
            }
        } catch {}
    }

    // MARK: - The core loop

    private func recompute() {
        now = Date()
        tick &+= 1
        if now.timeIntervalSince(lastFeedRefresh) > 30 {
            lastFeedRefresh = now
            Task { await refreshFeedPredictions() }
        }

        let est = estimator
        for i in transitIndices {
            guard let tracker = legs[i]?.tracker else { continue }
            if let b = legs[i]?.boardIndex {
                // At a terminus the vehicle waits for its scheduled departure, so that's what counts.
                legs[i]?.boardingETA = est.estimate(tracker, stop: b, target: b == 0 ? .departure : .arrival, now: now)
            }
            if let a = legs[i]?.alightIndex { legs[i]?.alightingETA = est.estimate(tracker, stop: a, target: .arrival, now: now) }
        }

        updatePhase()
        updateAdvice()
        // Alternatives go stale quickly; re-plan every minute while they're shown.
        if let r = recovery, !r.loading, !r.isSuggestion, now.timeIntervalSince(r.updatedAt) > 60 { refreshRecovery() }
        checkForFasterOption()
        publish()
    }

    // MARK: - Missed connection recovery

    /// "I missed it": plan the fastest way on from where you are now.
    func reportMissed() {
        if let live = focusLeg { missedLeg = live.index }
        let here = user ?? focusLeg?.leg.from.location ?? itinerary.legs.first?.from.location
        guard let here else { return }
        startRecovery(.manual, from: here, readyAt: now)
    }

    func selectRecovery(_ option: RecoveryOption) {
        recovery?.selectedId = option.id
        publish()
    }

    /// Switch live tracking to the chosen alternative.
    func takeRecovery(_ option: RecoveryOption) {
        app?.startSession(itinerary: option.itinerary, destinationName: destinationName)
    }

    func dismissRecovery() {
        if case .fasterOption(_, _, let saved)? = recovery?.reason { declinedSaving = saved }
        recoveryTask?.cancel()
        recovery = nil
        recoveryOrigin = nil
    }

    /// When the vehicle you're heading for runs late, look for a route that arrives sooner.
    private func checkForFasterOption() {
        guard recovery == nil, now.timeIntervalSince(lastFasterCheck) > 90, let app,
              let destination = itinerary.legs.last?.to.location else { return }
        let i: Int
        switch phase {
        case .walking(let l), .waiting(let l): i = l
        default: return
        }
        guard let live = legs[i], let eta = live.boardingETA, !eta.isPassed else { return }
        let lateness = eta.expected.timeIntervalSince(live.leg.scheduledStart)
        guard lateness >= 120 else { return }
        lastFasterCheck = now

        let projected = projectedArrival(lateness: lateness)
        let origin = user ?? live.leg.from.location
        let currentTrip = live.leg.trip?.tripId
        let lateMinutes = Int((lateness / 60).rounded())
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            guard let options = try? await RecoveryPlanner.options(from: origin, readyAt: Date(), to: destination,
                                                                   originalArrival: projected, app: app),
                  let self, !Task.isCancelled, self.recovery == nil else { return }
            // Different first vehicle, clearly earlier than staying put.
            let better = options.filter { $0.firstTransit.trip?.tripId != currentTrip && $0.delayVsPlan <= -3 }
            guard let best = better.first else { return }
            let saved = -best.delayVsPlan
            guard saved >= self.declinedSaving + 3 else { return }
            self.recovery = RecoveryState(reason: .fasterOption(line: live.line, minutesLate: lateMinutes, minutesSaved: saved),
                                          options: better, loading: false, updatedAt: Date())
            self.alert(key: "faster-\(best.id)",
                       title: "\(live.line) is \(lateMinutes) min late: \(best.line) is faster",
                       body: "\(best.whereToGo). Arrive \(best.arrival.formatted(date: .omitted, time: .shortened)), \(saved) min sooner.")
        }
    }

    /// When the current plan really gets you there: live estimate of the last ride, or the plan shifted by the delay.
    private func projectedArrival(lateness: TimeInterval) -> Date {
        if let last = transitIndices.last, let live = legs[last], let eta = live.alightingETA, !eta.isPassed {
            let finalWalk = itinerary.end.timeIntervalSince(live.leg.scheduledEnd)
            return eta.expected.addingTimeInterval(max(finalWalk, 0))
        }
        return itinerary.end.addingTimeInterval(lateness)
    }

    private func startRecovery(_ reason: RecoveryState.Reason, from origin: GeoPoint, readyAt: Date) {
        recovery = RecoveryState(reason: reason)
        recoveryOrigin = (origin, readyAt)
        refreshRecovery(notify: true)
    }

    private func refreshRecovery(notify: Bool = false) {
        guard let app, let destination = itinerary.legs.last?.to.location, var origin = recoveryOrigin else { return }
        // Once you're out and walking, plan from where you actually are.
        if let user, origin.readyAt <= now { origin = (user, now) }
        recovery?.loading = true
        recoveryTask?.cancel()
        let originalArrival = itinerary.end
        recoveryTask = Task { [weak self] in
            do {
                let options = try await RecoveryPlanner.options(from: origin.point, readyAt: max(origin.readyAt, Date()),
                                                                to: destination, originalArrival: originalArrival, app: app)
                guard let self, !Task.isCancelled, self.recovery != nil else { return }
                self.recovery?.options = options
                self.recovery?.loading = false
                self.recovery?.error = options.isEmpty ? "No reachable options right now." : nil
                self.recovery?.updatedAt = Date()
                if let id = self.recovery?.selectedId, !options.contains(where: { $0.id == id }) {
                    self.recovery?.selectedId = nil
                }
                if notify, let best = options.first, let title = self.recovery?.title {
                    let later = best.delayVsPlan > 0 ? " (+\(best.delayVsPlan) min)" : ""
                    self.alert(key: "recovery-\(title)",
                               title: "\(title) → fastest: \(best.line) from \(best.boardingStop.name)",
                               body: "\(best.whereToGo). Departs \(best.departure.formatted(date: .omitted, time: .shortened)), arrive \(best.arrival.formatted(date: .omitted, time: .shortened))\(later).")
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.recovery?.loading = false
                self.recovery?.error = error.localizedDescription
                self.recovery?.updatedAt = Date()
            }
        }
    }

    private var user: GeoPoint? { userLocation.map { GeoPoint($0.coordinate) } }

    private func updatePhase() {
        switch phase {
        case .walking(let i), .waiting(let i):
            guard let live = legs[i] else { return }
            let stop = live.leg.from.location
            if let user, user.distance(to: stop) < 35, case .walking = phase {
                phase = .waiting(leg: i)
            }
            // The vehicle left the boarding stop: did we get on?
            if let tracker = live.tracker, let b = live.boardIndex, tracker.hasPassed(stop: b) {
                if userIsAboard(live) {
                    phase = .riding(leg: i)
                } else if missedLeg != i {
                    missedLeg = i
                    startRecovery(.missed(line: live.line, stop: live.leg.from.name),
                                  from: user ?? live.leg.from.location, readyAt: now)
                }
            }
        case .riding(let i):
            guard let live = legs[i], let tracker = live.tracker, let a = live.alightIndex else { return }
            if tracker.hasPassed(stop: a) || (tracker.dwellingAt == a && userNear(live.leg.to.location, 60)) {
                advance(after: i)
            }
        case .arrived:
            break
        }
    }

    private func advance(after i: Int) {
        if let next = transitIndices.first(where: { $0 > i }) {
            phase = .walking(toLeg: next)
            missedLeg = nil
        } else {
            phase = .arrived
        }
    }

    private func userNear(_ p: GeoPoint, _ meters: Double) -> Bool {
        guard let user else { return false }
        return user.distance(to: p) < meters
    }

    private func userIsAboard(_ live: LiveLeg) -> Bool {
        guard let user, let loc = live.tracker?.displayLocation(at: now) else { return false }
        let speed = userLocation?.speed ?? 0
        return user.distance(to: loc) < 80 || (speed > 4 && user.distance(to: live.leg.from.location) > 80)
    }

    private func updateAdvice() {
        guard let app else { return }
        transfer = nil
        switch phase {
        case .walking(let i), .waiting(let i):
            guard let live = legs[i], let eta = live.boardingETA else { pace = nil; return }
            let stop = live.leg.from.location
            let distance = user.map { walkTracker.distance(from: $0, to: stop) } ?? live.leg.from.location.distance(to: stop)
            walkDistance = distance
            let advisor = PaceAdvisor(walkingSpeed: app.walkingSpeed)
            let buffer = ModeProfile.for(live.mode).boardingBuffer + app.extraBuffer
            let previous = pace?.state
            let advice = advisor.advise(walkDistance: user == nil ? 0 : distance, eta: eta, buffer: buffer,
                                        now: now, previous: previous)
            pace = advice
            notifyIfEscalated(advice, live: live, previous: previous)
        case .riding(let i):
            pace = PaceAdvice(state: .onBoard, leaveAt: nil, margin: 0, requiredSpeed: nil, walkDistance: 0, walkDuration: 0)
            // Check the next connection while still on board.
            guard let current = legs[i], let nextIndex = transitIndices.first(where: { $0 > i }),
                  let next = legs[nextIndex], let arrive = current.alightingETA, let depart = next.boardingETA else { return }
            let walk = itinerary.legs[(i + 1)..<nextIndex].reduce(0.0) { $0 + $1.distance }
            let gap = walk > 0 ? walk : current.leg.to.location.distance(to: next.leg.from.location) * WalkingRouter.detourFactor
            let assessment = TransferGuard.assess(arrival: arrive, departure: depart, walkDistance: gap,
                                                  walkingSpeed: app.walkingSpeed)
            transfer = assessment
            switch assessment.risk {
            case .needsHurry:
                alert(key: "transfer-hurry-\(nextIndex)", title: "Hurry for \(next.line)",
                      body: "Connection at \(next.leg.from.name) is tight. Walk fast when you get off.")
            case .missed:
                // Plan from the stop we'll get off at, from the moment we get there.
                if recovery == nil {
                    startRecovery(.connectionAtRisk(line: next.line, stop: next.leg.from.name),
                                  from: current.leg.to.location, readyAt: arrive.expected)
                }
            default: break
            }
        case .arrived:
            pace = nil
        }
    }

    private func notifyIfEscalated(_ advice: PaceAdvice, live: LiveLeg, previous: PaceState?) {
        guard advice.state != previous else { return }
        let stop = live.leg.from.name
        let mins = live.boardingETA.map { $0.minutesLabel(from: now) } ?? "?"
        switch advice.state {
        case .goNow:
            alert(key: "go-\(live.index)", title: "Start walking to \(stop)",
                  body: "\(live.line) arrives in \(mins) min. \(advice.message(now: now)).")
        case .walkBriskly:
            alert(key: "brisk-\(live.index)", title: "Walk briskly",
                  body: "\(live.line) at \(stop) in \(mins) min · \(Int(advice.walkDistance)) m to go.")
        case .run:
            alert(key: "run-\(live.index)", title: "Run! \(live.line) in \(mins) min",
                  body: "\(Int(advice.walkDistance)) m to \(stop).")
        case .willMiss:
            if previous != nil, recovery == nil {
                startRecovery(.connectionAtRisk(line: live.line, stop: live.leg.from.name),
                              from: user ?? live.leg.from.location, readyAt: now)
            }
        default: break
        }
    }

    /// Posts each alert once per session, also as a Live Activity alert.
    private func alert(key: String, title: String, body: String) {
        guard notified.insert(key).inserted, let app else { return }
        app.notifications.post(id: "commute-\(key)", title: title, body: body)
        if let state = activityState() {
            app.liveActivity.update(state, alert: (title, body))
        }
    }

    private func publish() {
        guard let app, let state = activityState() else { return }
        app.liveActivity.update(state)
    }

    // MARK: - Presentation helpers

    /// Vehicle progress for the bar: approaching your stop, or along your ride.
    func progress(for live: LiveLeg) -> Double {
        guard let tracker = live.tracker, let s = tracker.displayDistance(at: now) else { return 0 }
        let stops = tracker.pattern.stops
        if case .riding = phase, let b = live.boardIndex, let a = live.alightIndex, a > b {
            let start = stops[b].distanceAlong, end = stops[a].distanceAlong
            return min(max((s - start) / max(end - start, 1), 0), 1)
        }
        guard let b = live.boardIndex else { return 0 }
        let target = stops[b].distanceAlong
        return target > 0 ? min(max(s / target, 0), 1) : 1
    }

    func nextStopName(for live: LiveLeg) -> String? {
        guard let tracker = live.tracker, let i = tracker.nextStopIndex(at: now) else { return nil }
        return tracker.pattern.stops[i].name
    }

    func activityState() -> CommuteActivityAttributes.ContentState? {
        // Missed: the Live Activity switches to the best way on. A faster-option suggestion
        // keeps showing your current vehicle, with the suggestion as a note.
        if let option = recovery?.selected, recovery?.isSuggestion == false {
            let d = option.departure
            return CommuteActivityAttributes.ContentState(
                phase: .transfer, line: option.line, mode: option.firstTransit.mode,
                headsign: option.firstTransit.headsign ?? option.firstTransit.to.name,
                stopName: option.boardingStop.name, eta: d, etaEarliest: d, etaLatest: d,
                isLive: option.firstTransit.isRealtime, pace: option.advice.state,
                paceMessage: option.whereToGo, leaveAt: option.advice.leaveAt, progress: 0,
                nextStopName: nil, occupancy: nil,
                transferNote: "Arrive \(option.arrival.formatted(date: .omitted, time: .shortened))\(option.isFastest ? " · fastest option" : "")")
        }
        guard let live = focusLeg ?? transitIndices.last.flatMap({ legs[$0] }) else { return nil }
        let riding: Bool = { if case .riding = phase { return true }; return false }()
        let eta = (riding ? live.alightingETA : live.boardingETA)
            ?? ETAEstimate(expected: live.leg.start, earliest: live.leg.start, latest: live.leg.start,
                           source: .schedule, computedAt: now)
        let phaseValue: CommuteActivityAttributes.ContentState.Phase = {
            switch phase {
            case .walking: return missedLeg == nil ? .walking : .transfer
            case .waiting: return .waiting
            case .riding: return .riding
            case .arrived: return .arrived
            }
        }()
        var transferNote: String?
        if let transfer, case .riding(let i) = phase,
           let nextIndex = transitIndices.first(where: { $0 > i }), let next = legs[nextIndex] {
            let label: String
            switch transfer.risk {
            case .comfortable: label = "on track"
            case .tight: label = "tight"
            case .needsHurry: label = "hurry"
            case .missed: label = "at risk"
            }
            transferNote = "Then \(next.line) at \(next.leg.from.name) · \(label)"
        }
        if let r = recovery, r.isSuggestion, let best = r.options.first {
            transferNote = "Faster: \(best.line) from \(best.boardingStop.name) · \(-best.delayVsPlan) min sooner"
        }
        return CommuteActivityAttributes.ContentState(
            phase: phaseValue, line: live.line, mode: live.mode, headsign: live.headsign,
            stopName: riding ? live.leg.to.name : live.leg.from.name,
            eta: eta.expected, etaEarliest: eta.earliest, etaLatest: eta.latest,
            isLive: eta.source == .liveVehicle, pace: pace?.state ?? .relax,
            paceMessage: pace?.message(now: now) ?? "", leaveAt: pace?.leaveAt,
            progress: progress(for: live), nextStopName: nextStopName(for: live),
            occupancy: live.tracker?.occupancyPercent, transferNote: transferNote)
    }
}
