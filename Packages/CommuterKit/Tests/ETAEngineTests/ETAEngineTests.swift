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

final class KinematicsTests: XCTestCase {
    func testStraightRoadTime() {
        let p = makePattern(start: Date())
        let t = RouteKinematics.travelTime(along: p.polyline, from: 0, to: 1000, profile: .for(.bus))
        // Pure cruise would be 1000 / 12.5 / 0.78 ≈ 103 s; accelerating and braking add a bit.
        XCTAssertGreaterThan(t, 103)
        XCTAssertLessThan(t, 140)
    }

    func testCurvesAreSlowerThanStraight() {
        // Zig-zag through intersections vs a straight road of the same length.
        let o = GeoPoint(latitude: 60.17, longitude: 24.90)
        let dLat = 100 / 111_195.0, dLon = 100 / (111_195.0 * cos(60.17 * .pi / 180))
        var zig: [GeoPoint] = [o]
        for i in 1...10 {
            let last = zig.last!
            zig.append(i % 2 == 1 ? GeoPoint(latitude: last.latitude + dLat, longitude: last.longitude)
                                  : GeoPoint(latitude: last.latitude, longitude: last.longitude + dLon))
        }
        let curvy = Polyline(zig)
        let straight = Polyline([o, GeoPoint(latitude: o.latitude + dLat * 10, longitude: o.longitude)])
        let tc = RouteKinematics.travelTime(along: curvy, from: 0, to: curvy.length, profile: .for(.bus))
        let ts = RouteKinematics.travelTime(along: straight, from: 0, to: straight.length, profile: .for(.bus))
        XCTAssertEqual(curvy.length, straight.length, accuracy: 5)
        XCTAssertGreaterThan(tc, ts * 1.2)
    }

    func testPatternHasPhysicsTimes() {
        let p = makePattern(start: Date())
        XCTAssertEqual(p.physicsRunTimes.count, p.stops.count - 1)
        XCTAssertTrue(p.followsRealGeometry)
    }
}

final class BoardingTests: XCTestCase {
    func testBoardAndAlight() {
        var d = BoardingDetector()
        let base = GeoPoint(latitude: 60.17, longitude: 24.94)
        var t = Date()
        // Riding along: close to the vehicle, both moving.
        for i in 0..<4 {
            let p = GeoPoint(latitude: base.latitude + Double(i) * 0.0001, longitude: base.longitude)
            d.update(.init(time: t, user: p, userSpeed: 8, vehicle: p, vehicleSpeed: 8, activity: .automotive))
            t += 1
        }
        XCTAssertTrue(d.isOnBoard)
        // Walking away after getting off.
        let off = GeoPoint(latitude: base.latitude, longitude: base.longitude + 0.003)
        for _ in 0..<4 {
            d.update(.init(time: t, user: base, userSpeed: 1.3, vehicle: off, vehicleSpeed: 9, activity: .walking))
            t += 1
        }
        XCTAssertFalse(d.isOnBoard)
    }

    func testWaitingNextToStoppedBusIsNotBoarding() {
        var d = BoardingDetector()
        let p = GeoPoint(latitude: 60.17, longitude: 24.94)
        for _ in 0..<10 {
            d.update(.init(time: Date(), user: p, userSpeed: 0, vehicle: p, vehicleSpeed: 0, activity: .stationary))
        }
        XCTAssertFalse(d.isOnBoard)
    }
}

final class CalendarTests: XCTestCase {
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        FinnishCalendar.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testEaster() {
        XCTAssertTrue(FinnishCalendar.easter(2026) == (4, 5))
        XCTAssertTrue(FinnishCalendar.easter(2025) == (4, 20))
        XCTAssertTrue(FinnishCalendar.easter(2027) == (3, 28))
    }

    func testHolidays2026() {
        XCTAssertEqual(FinnishCalendar.holiday(on: date(2026, 4, 3))?.name, "Good Friday")
        XCTAssertEqual(FinnishCalendar.holiday(on: date(2026, 5, 14))?.name, "Ascension Day")
        XCTAssertEqual(FinnishCalendar.holiday(on: date(2026, 6, 19))?.name, "Midsummer Eve")
        XCTAssertEqual(FinnishCalendar.holiday(on: date(2026, 10, 31))?.name, "All Saints' Day")
        XCTAssertEqual(FinnishCalendar.holiday(on: date(2026, 12, 6))?.name, "Independence Day")
        XCTAssertNil(FinnishCalendar.holiday(on: date(2026, 10, 15)))
    }
}

final class VisitLearnerTests: XCTestCase {
    let home = GeoPoint(latitude: 60.20, longitude: 24.93)
    let work = GeoPoint(latitude: 60.18, longitude: 24.83)

    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        // October 2026: 12th is a Monday.
        FinnishCalendar.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    func visits() -> [Visit] {
        var v: [Visit] = []
        for (i, day) in [12, 13, 14, 15, 16].enumerated() {
            v.append(Visit(arrival: at(day - 1, 17, 30), departure: at(day, 7, 40), location: home))
            v.append(Visit(arrival: at(day, 8, 20 + i), departure: at(day, 16, 35 + i), location: work))
        }
        return v
    }

    func testFindsHomeAndWork() {
        let h = VisitLearner.suggestHome(from: visits())
        XCTAssertNotNil(h)
        XCTAssertLessThan(h!.distance(to: home), 20)
        let w = VisitLearner.suggestWork(from: visits(), home: h)
        XCTAssertNotNil(w)
        XCTAssertLessThan(w!.distance(to: work), 20)
    }

    func testTypicalTimes() {
        let t = VisitLearner.typicalTimes(from: visits(), work: work)
        XCTAssertEqual(t.arrive, 8 * 60 + 20)   // median 8:22 → rounded to 8:20
        XCTAssertEqual(t.leave, 16 * 60 + 35)   // median 16:37 → 16:35
    }
}

final class WeatherTests: XCTestCase {
    func testSlippery() {
        let i = WeatherImpact.assess(WeatherConditions(temperature: -1, precipitation: 0.4, windSpeed: 3, time: Date()))
        XCTAssertTrue(i.isSlippery)
        XCTAssertLessThan(i.walkingFactor, 0.9)
        XCTAssertGreaterThan(i.extraBuffer, 0)
        XCTAssertTrue(i.waitIndoors)
    }

    func testMildDryDay() {
        let i = WeatherImpact.assess(WeatherConditions(temperature: 12, precipitation: 0, windSpeed: 3, time: Date()))
        XCTAssertEqual(i.walkingFactor, 1)
        XCTAssertFalse(i.waitIndoors)
        XCTAssertNil(i.headline)
    }

    func testDeepFreezeWaitsInside() {
        let i = WeatherImpact.assess(WeatherConditions(temperature: -18, precipitation: 0, windSpeed: 2, time: Date()))
        XCTAssertTrue(i.waitIndoors)
        XCTAssertFalse(i.isSlippery)
        XCTAssertNotNil(i.headline)
    }
}

final class CrowdTests: XCTestCase {
    func testRecentReportsWin() {
        let now = Date()
        let reports = [
            CrowdReport(tripKey: "t", level: .seats, time: now.addingTimeInterval(-25 * 60)),
            CrowdReport(tripKey: "t", level: .seats, time: now.addingTimeInterval(-24 * 60)),
            CrowdReport(tripKey: "t", level: .full, time: now.addingTimeInterval(-60)),
        ]
        let e = CrowdOccupancy.estimate(reports, now: now)
        XCTAssertEqual(e?.level, .full)
        XCTAssertEqual(e?.reports, 3)
    }

    func testOldReportsIgnored() {
        let now = Date()
        XCTAssertNil(CrowdOccupancy.estimate([CrowdReport(tripKey: "t", level: .seats,
                                                          time: now.addingTimeInterval(-3600))], now: now))
    }

    func testAskOncePerRideAfterAMinute() {
        XCTAssertNil(CrowdOccupancy.shouldAsk(onBoardFor: 30, alreadyDecided: false, roll: 0.1))
        XCTAssertEqual(CrowdOccupancy.shouldAsk(onBoardFor: 90, alreadyDecided: false, roll: 0.1), true)
        XCTAssertEqual(CrowdOccupancy.shouldAsk(onBoardFor: 90, alreadyDecided: false, roll: 0.9), false)
        XCTAssertNil(CrowdOccupancy.shouldAsk(onBoardFor: 90, alreadyDecided: true, roll: 0.1))
    }

    func testLabel() {
        let now = Date()
        let e = CrowdEstimate(level: .standing, reports: 3, newest: now.addingTimeInterval(-240))
        XCTAssertEqual(e.label(now: now), "Standing · 3 riders, 4 min ago")
    }
}

final class StationMapTests: XCTestCase {
    /// Entrance (0) → escalator down (0;-1) → corridor → platform 1, plus a lift and a stairs alternative.
    let json = """
    {"version":1,"stations":[{"id":"HSL:1000005","name":"Kamppi","kind":"metro","center":[60.169,24.931],
     "levels":[-1,0],"status":"complete","score":1,
     "entrances":[{"id":"n1","pos":[60.169,24.931],"level":0,"ref":"A","graphNode":0}],
     "platforms":[{"id":"w110","ref":"1","level":-1,"line":[[60.1698,24.9308],[60.1698,24.9316]],"gtfsStops":["HSL:1040601"]}],
     "connectors":[{"id":"w101","kind":"escalator","levels":[-1,0],"line":[[60.169,24.931],[60.1693,24.931]]}],
     "graph":{"nodes":[[60.169,24.931,0],[60.1693,24.931,-1],[60.1696,24.931,-1],[60.1698,24.9312,-1],
                       [60.1690,24.9312,0],[60.1693,24.9312,-1]],
              "edges":[[0,1,33.4,"escalator",0],[1,2,33.4,"walk",0],[2,3,25,"walk",0],
                       [0,4,11,"walk",0],[4,5,33.4,"elevator",0],[5,2,33.4,"walk",0]]},
     "stops":[{"id":"HSL:1040601","platform":"1","pos":[60.1698,24.9312]}],
     "missing":[]}]}
    """

    func map() throws -> StationMap { try StationMap.decode(Data(json.utf8)) }

    func testDecodeAndLookup() throws {
        let m = try map()
        let s = try XCTUnwrap(m.station(servingStop: "HSL:1040601"))
        XCTAssertEqual(s.name, "Kamppi")
        XCTAssertEqual(s.graph.edges.first?.kind, .escalator)
        XCTAssertNotNil(m.station(near: GeoPoint(latitude: 60.1691, longitude: 24.9311)))
        XCTAssertNil(m.station(near: GeoPoint(latitude: 60.20, longitude: 25.0)))
    }

    func testRouteUsesEscalator() throws {
        let s = try XCTUnwrap(try map().stations.first)
        let r = try XCTUnwrap(StationRouter().route(in: s, fromEntrance: s.entrances[0], toStop: "HSL:1040601"))
        XCTAssertEqual(r.steps.first?.kind, .escalator)
        XCTAssertEqual(r.steps.first?.instruction, "Take the escalator down to level -1")
        XCTAssertEqual(r.steps.last?.kind, .walk)
        XCTAssertTrue(r.steps.last?.instruction.hasPrefix("Walk ") ?? false)
    }

    func testStepFreeUsesLift() throws {
        let s = try XCTUnwrap(try map().stations.first)
        let r = try XCTUnwrap(StationRouter(stepFree: true).route(in: s, fromEntrance: s.entrances[0], toStop: "HSL:1040601"))
        XCTAssertTrue(r.steps.contains { $0.kind == .elevator })
        XCTAssertFalse(r.steps.contains { $0.kind == .escalator || $0.kind == .stairs })
        XCTAssertGreaterThan(r.seconds, 35)
    }
}
