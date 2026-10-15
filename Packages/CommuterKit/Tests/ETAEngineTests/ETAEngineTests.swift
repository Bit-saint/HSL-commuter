import XCTest
@testable import ETAEngine

/// A straight east-west line in Helsinki with stops every 500 m.
func makePattern(start: Date, stops: Int = 5, segmentSeconds: TimeInterval = 60, mode: TransitMode = .bus,
                 timingPoint: Int? = nil) -> TripPattern {
    let origin = GeoPoint(latitude: 60.17, longitude: 24.90)
    // Exactly 500 m of longitude at this latitude.
    let step = 500 / (GeoPoint.earthRadius * .pi / 180 * cos(60.17 * .pi / 180))
    let points = (0..<stops).map { GeoPoint(latitude: origin.latitude, longitude: origin.longitude + Double($0) * step) }
    let ps = points.enumerated().map { i, p in
        PatternStop(id: "HSL:\(1000 + i)", name: "Stop \(i)", location: p,
                    scheduledArrival: start.addingTimeInterval(Double(i) * segmentSeconds),
                    scheduledDeparture: start.addingTimeInterval(Double(i) * segmentSeconds),
                    isTimingPoint: i == timingPoint)
    }
    return TripPattern(tripId: "HSL:test", routeId: "HSL:1001", routeShortName: "1", headsign: "End",
                       mode: mode, shape: points, stops: ps)
}

final class GeoTests: XCTestCase {
    func testDistanceAndBearing() {
        let a = GeoPoint(latitude: 60.17, longitude: 24.94)
        let b = GeoPoint(latitude: 60.18, longitude: 24.94)
        XCTAssertEqual(a.distance(to: b), 1112, accuracy: 3)
        XCTAssertEqual(a.bearing(to: b), 0, accuracy: 0.5)
    }

    func testPolylineProjection() {
        let p = makePattern(start: Date())
        let line = p.polyline
        XCTAssertEqual(line.length, 2000, accuracy: 5)
        let mid = line.point(at: 750)
        let offset = GeoPoint(latitude: mid.latitude + 0.0002, longitude: mid.longitude) // ~22 m north
        let proj = line.project(offset)
        XCTAssertNotNil(proj)
        XCTAssertEqual(proj!.distanceAlong, 750, accuracy: 3)
        XCTAssertEqual(proj!.lateralDistance, 22, accuracy: 2)
        XCTAssertEqual(line.bearing(at: 100), 90, accuracy: 1)
    }

    func testGooglePolylineDecode() {
        // Example from Google's documentation.
        let pts = Polyline.decodeGoogle("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].latitude, 38.5, accuracy: 1e-6)
        XCTAssertEqual(pts[0].longitude, -120.2, accuracy: 1e-6)
        XCTAssertEqual(pts[2].latitude, 43.252, accuracy: 1e-6)
        XCTAssertEqual(pts[2].longitude, -126.453, accuracy: 1e-6)
    }

    func testStopsPlacedAlongShape() {
        let p = makePattern(start: Date())
        for (stop, expected) in zip(p.stops, [0.0, 500, 1000, 1500, 2000]) {
            XCTAssertEqual(stop.distanceAlong, expected, accuracy: 2)
        }
    }
}

final class FilterTests: XCTestCase {
    func testConvergesToConstantSpeed() {
        let t0 = Date()
        var f = ProgressFilter(distance: 0, at: t0)
        for i in 1...20 {
            f.update(distance: Double(i) * 10 + Double.random(in: -5...5), at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(f.speed, 10, accuracy: 1.5)
        XCTAssertEqual(f.predictedDistance(at: t0.addingTimeInterval(22)), 220, accuracy: 15)
    }

    func testRejectsSingleOutlier() {
        let t0 = Date()
        var f = ProgressFilter(distance: 0, at: t0)
        for i in 1...10 { f.update(distance: Double(i) * 10, at: t0.addingTimeInterval(Double(i))) }
        let accepted = f.update(distance: 2_000, at: t0.addingTimeInterval(11))
        XCTAssertFalse(accepted)
        XCTAssertLessThan(f.distance, 200)
    }
}

final class ETATests: XCTestCase {
    func testScheduleFallbackWithoutLiveData() {
        let now = Date()
        let p = makePattern(start: now.addingTimeInterval(120))
        let tracker = TripTracker(pattern: p)
        let eta = ETAEstimator().estimate(tracker, stop: 2, now: now)
        XCTAssertEqual(eta.source, .schedule)
        XCTAssertEqual(eta.expected.timeIntervalSince(now), 240, accuracy: 1)
    }

    func testLiveVehicleBetweenStops() {
        let now = Date()
        let p = makePattern(start: now.addingTimeInterval(-60))
        let tracker = TripTracker(pattern: p)
        // Vehicle at 750 m (halfway between stop 1 and 2), moving 8 m/s.
        for i in 0..<5 {
            let d = 718.0 + Double(i) * 8
            tracker.ingest(VehicleObservation(vehicleId: "v", timestamp: now.addingTimeInterval(Double(i - 4)),
                                              event: .vp, location: p.polyline.point(at: d), speed: 8,
                                              locationSource: "GPS"))
        }
        let eta = ETAEstimator().estimate(tracker, stop: 3, now: now)
        XCTAssertEqual(eta.source, .liveVehicle)
        // ~250 m to stop 2, a dwell, then a full 500 m segment. Roughly 1.5 segments plus dwell.
        let secs = eta.expected.timeIntervalSince(now)
        XCTAssertGreaterThan(secs, 60)
        XCTAssertLessThan(secs, 140)
        XCTAssertLessThanOrEqual(eta.earliest, eta.expected)
        XCTAssertGreaterThanOrEqual(eta.latest, eta.expected)
    }

    func testPassedStop() {
        let now = Date()
        let p = makePattern(start: now.addingTimeInterval(-300))
        let tracker = TripTracker(pattern: p)
        tracker.ingest(VehicleObservation(vehicleId: "v", timestamp: now, event: .dep, stopId: "1001"))
        XCTAssertTrue(tracker.hasPassed(stop: 1))
        XCTAssertTrue(ETAEstimator().estimate(tracker, stop: 1, now: now).isPassed)
    }

    func testTimingPointHoldsEarlyVehicle() {
        let now = Date()
        // Stop 2 is a timing point scheduled 10 min out; vehicle is way early at stop 1.
        let p = makePattern(start: now.addingTimeInterval(540), segmentSeconds: 30, timingPoint: 2)
        let tracker = TripTracker(pattern: p)
        tracker.ingest(VehicleObservation(vehicleId: "v", timestamp: now, event: .vp,
                                          location: p.polyline.point(at: 520), speed: 10, locationSource: "GPS"))
        let eta = ETAEstimator().estimate(tracker, stop: 3, now: now)
        // Can't reach stop 3 before the timing point's departure (now + 600) plus the run.
        XCTAssertGreaterThan(eta.expected.timeIntervalSince(now), 600)
    }

    func testLearnedModelBlendsTowardsObservations() {
        let store = LearnedSegmentStore()
        let p = makePattern(start: Date())
        let now = Date()
        for _ in 0..<20 { store.record(route: p.routeId, from: p.stops[0].id, to: p.stops[1].id, seconds: 120, at: now) }
        let model = LearnedSegmentModel(store: store)
        let t = model.runTime(pattern: p, from: 0, at: now)
        XCTAssertGreaterThan(t, 100)
    }
}

final class PaceTests: XCTestCase {
    func eta(_ seconds: TimeInterval, now: Date) -> ETAEstimate {
        let d = now.addingTimeInterval(seconds)
        return ETAEstimate(expected: d, earliest: d, latest: d, source: .liveVehicle, computedAt: now)
    }

    func testStates() {
        let now = Date()
        let advisor = PaceAdvisor(walkingSpeed: 1.4)
        // 280 m = 200 s walk, buffer 30 s.
        XCTAssertEqual(advisor.advise(walkDistance: 280, eta: eta(900, now: now), buffer: 30, now: now).state, .relax)
        XCTAssertEqual(advisor.advise(walkDistance: 280, eta: eta(350, now: now), buffer: 30, now: now).state, .leaveSoon)
        XCTAssertEqual(advisor.advise(walkDistance: 280, eta: eta(260, now: now), buffer: 30, now: now).state, .goNow)
        XCTAssertEqual(advisor.advise(walkDistance: 280, eta: eta(200, now: now), buffer: 30, now: now).state, .walkBriskly)
        XCTAssertEqual(advisor.advise(walkDistance: 280, eta: eta(130, now: now), buffer: 30, now: now).state, .run)
        XCTAssertEqual(advisor.advise(walkDistance: 280, eta: eta(60, now: now), buffer: 30, now: now).state, .willMiss)
        XCTAssertEqual(advisor.advise(walkDistance: 20, eta: eta(60, now: now), buffer: 30, now: now).state, .atStop)
    }

    func testHysteresis() {
        let now = Date()
        let advisor = PaceAdvisor(walkingSpeed: 1.4)
        // Barely "goNow" territory, but previously "walkBriskly": stay brisk.
        let a = advisor.advise(walkDistance: 280, eta: eta(232, now: now), buffer: 30, now: now, previous: .walkBriskly)
        XCTAssertEqual(a.state, .walkBriskly)
    }

    func testTransferGuard() {
        let now = Date()
        let arrive = eta(300, now: now)
        XCTAssertEqual(TransferGuard.assess(arrival: arrive, departure: eta(600, now: now), walkDistance: 100,
                                            walkingSpeed: 1.4).risk, .comfortable)
        XCTAssertEqual(TransferGuard.assess(arrival: arrive, departure: eta(420, now: now), walkDistance: 100,
                                            walkingSpeed: 1.4).risk, .tight)
        XCTAssertEqual(TransferGuard.assess(arrival: arrive, departure: eta(310, now: now), walkDistance: 300,
                                            walkingSpeed: 1.4).risk, .missed)
    }
}

final class RecoveryTests: XCTestCase {
    func testFastestReachableWins() {
        let now = Date()
        let c = [
            // Leaves in 1 min but 500 m away: unreachable.
            ConnectionRecovery.Candidate(id: "gone", firstDeparture: now.addingTimeInterval(60),
                                         arrival: now.addingTimeInterval(900), walkDistance: 500, transfers: 0),
            // Reachable, arrives later.
            ConnectionRecovery.Candidate(id: "slow", firstDeparture: now.addingTimeInterval(300),
                                         arrival: now.addingTimeInterval(1800), walkDistance: 100, transfers: 0),
            // Reachable, arrives first.
            ConnectionRecovery.Candidate(id: "fast", firstDeparture: now.addingTimeInterval(400),
                                         arrival: now.addingTimeInterval(1500), walkDistance: 250, transfers: 1),
        ]
        let ranked = ConnectionRecovery.rank(c, readyAt: now, walkingSpeed: 1.4)
        XCTAssertEqual(ranked.map(\.candidate.id), ["fast", "slow"])
        XCTAssertTrue(ranked[0].isFastest)
        XCTAssertFalse(ranked[1].isFastest)
    }

    func testTieBreaksOnEasierPace() {
        let now = Date()
        let arrive = now.addingTimeInterval(1500)
        let c = [
            ConnectionRecovery.Candidate(id: "run", firstDeparture: now.addingTimeInterval(130),
                                         arrival: arrive, walkDistance: 280, transfers: 0),
            ConnectionRecovery.Candidate(id: "calm", firstDeparture: now.addingTimeInterval(600),
                                         arrival: arrive.addingTimeInterval(20), walkDistance: 280, transfers: 0),
        ]
        XCTAssertEqual(ConnectionRecovery.rank(c, readyAt: now, walkingSpeed: 1.4).first?.candidate.id, "calm")
    }

    func testCompass() {
        XCTAssertEqual(ConnectionRecovery.compassDirection(0), "north")
        XCTAssertEqual(ConnectionRecovery.compassDirection(50), "northeast")
        XCTAssertEqual(ConnectionRecovery.compassDirection(359), "north")
        XCTAssertEqual(ConnectionRecovery.compassDirection(200), "south")
    }
}
