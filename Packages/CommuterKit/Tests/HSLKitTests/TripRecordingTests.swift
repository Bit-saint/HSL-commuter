import XCTest
import ETAEngine
@testable import HSLKit

final class TripRecordingTests: XCTestCase {
    private func sample() throws -> TripRecording {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("App/Resources/Demo/sample-trip.json"))
        return try TripRecording.decode(data)
    }

    func testSampleTripDecodesAndIsConsistent() throws {
        let r = try sample()
        XCTAssertEqual(r.itinerary.legs.map(\.mode), [.walk, .metro, .walk])
        let metro = try XCTUnwrap(r.itinerary.legs.first { $0.mode.isTransit })
        let trip = try XCTUnwrap(r.trips.first { $0.tripId == metro.trip?.tripId })
        XCTAssertTrue(trip.stops.contains { $0.id == metro.from.stop?.id })
        XCTAssertTrue(trip.stops.contains { $0.id == metro.to.stop?.id })
        XCTAssertGreaterThan(r.vehicles.count, 100)
        XCTAssertGreaterThan(r.locations.count, 100)
        XCTAssertLessThan(r.startedAt, r.itinerary.start)
        XCTAssertGreaterThan(r.endedAt, r.itinerary.end)
        XCTAssertEqual(r.itinerary.zones, "AB")
        XCTAssertEqual(r.itinerary.fare?.price, 3.2)
    }

    func testReplayedVehicleGivesSensibleBoardingETA() throws {
        let r = try sample()
        let metro = try XCTUnwrap(r.itinerary.legs.first { $0.mode.isTransit })
        let pattern = try XCTUnwrap(r.trips.first).pattern()
        let tracker = TripTracker(pattern: pattern)
        let board = try XCTUnwrap(pattern.stops.firstIndex { $0.id == metro.from.stop?.id })
        // Five minutes before the metro reaches Sörnäinen, fed with the fixes so far.
        let now = metro.scheduledStart.addingTimeInterval(-300)
        for o in r.vehicles where o.observation.timestamp <= now { tracker.ingest(o.observation) }
        let eta = ETAEstimator().estimate(tracker, stop: board, target: .arrival, now: now)
        XCTAssertEqual(eta.source, .liveVehicle)
        // It really arrives 40 s late, 20 s before departure: within 90 s either way.
        let truth = metro.scheduledStart.addingTimeInterval(20)
        XCTAssertLessThan(abs(eta.expected.timeIntervalSince(truth)), 90)
    }

    func testRecordingRoundTrips() throws {
        let r = try sample()
        let again = try TripRecording.decode(try r.encoded())
        XCTAssertEqual(again.vehicles.count, r.vehicles.count)
        XCTAssertEqual(again.itinerary.id, r.itinerary.id)
    }

    func testTicketZones() {
        XCTAssertEqual(FareZones.ticketZones(["A", "B"]), "AB")
        XCTAssertEqual(FareZones.ticketZones(["A", "C"]), "ABC")
        XCTAssertEqual(FareZones.ticketZones(["B"]), "AB")
        XCTAssertEqual(FareZones.ticketZones(["C", "D"]), "CD")
        XCTAssertEqual(FareZones.ticketZones(["D"]), "D")
        XCTAssertNil(FareZones.ticketZones([nil]))
    }
}
