import XCTest
@testable import HSLKit
import ETAEngine

final class HFPTests: XCTestCase {
    let topic = "/hfp/v2/journey/ongoing/vp/bus/0022/01288/2550/1/Itäkeskus(M)/07:15/1040129/4/60;24/19/73/45"
    let payload = """
    {"VP":{"desi":"550","dir":"1","oper":22,"veh":1288,"tst":"2026-10-15T04:20:01.123Z","tsi":1792038001,
    "spd":9.27,"hdg":87,"lat":60.17321,"long":24.93456,"acc":0.3,"dl":-45,"odo":1234,"drst":0,
    "oday":"2026-10-15","jrn":321,"line":123,"start":"07:15","loc":"GPS","stop":null,"route":"2550","occu":35}}
    """

    func testTopicParsing() {
        let t = HFP.Topic(topic)
        XCTAssertEqual(t?.eventType, "vp")
        XCTAssertEqual(t?.routeId, "2550")
        XCTAssertEqual(t?.directionId, "1")
        XCTAssertEqual(t?.startTime, "07:15")
        XCTAssertEqual(t?.vehicleId, "0022/01288")
        XCTAssertEqual(t?.nextStop, "1040129")
    }

    func testPayloadDecoding() throws {
        let obs = try XCTUnwrap(HFP.decode(topic: topic, payload: Data(payload.utf8)))
        XCTAssertEqual(obs.event, .vp)
        XCTAssertEqual(obs.speed ?? 0, 9.27, accuracy: 0.001)
        XCTAssertEqual(obs.location?.latitude ?? 0, 60.17321, accuracy: 1e-6)
        XCTAssertEqual(obs.scheduleOffset, -45)
        XCTAssertEqual(obs.occupancyPercent, 35)
        XCTAssertEqual(obs.doorsOpen, false)
        XCTAssertNil(obs.stopId)
        XCTAssertEqual(obs.nextStopId, "1040129")
    }

    func testStopEventDecoding() throws {
        let t = topic.replacingOccurrences(of: "/vp/", with: "/dep/")
        let p = #"{"DEP":{"tst":"2026-10-15T04:20:01Z","stop":1040129,"lat":60.1,"long":24.9,"dl":10}}"#
        let obs = try XCTUnwrap(HFP.decode(topic: t, payload: Data(p.utf8)))
        XCTAssertEqual(obs.event, .dep)
        XCTAssertEqual(obs.stopId, "1040129")
    }

    func testTripKey() {
        let key = HFP.TripKey(routeGtfsId: "HSL:2550", gtfsDirectionId: 0, firstDepartureSeconds: 7 * 3600 + 15 * 60,
                              serviceDay: "20261015")
        XCTAssertEqual(key.route, "2550")
        XCTAssertEqual(key.direction, "1")
        XCTAssertEqual(key.startTime, "07:15")
        XCTAssertEqual(key.operatingDay, "2026-10-15")
        XCTAssertEqual(key.topicFilter, "/hfp/v2/journey/ongoing/+/+/+/+/2550/1/+/07:15/#")

        let late = HFP.TripKey(routeGtfsId: "HSL:31M1", gtfsDirectionId: 1, firstDepartureSeconds: 25 * 3600 + 5 * 60,
                               serviceDay: "2026-10-15")
        XCTAssertEqual(late.startTime, "01:05")
        XCTAssertEqual(late.direction, "2")
    }
}

final class MQTTTests: XCTestCase {
    func testRemainingLength() {
        XCTAssertEqual(MQTTClient.encodeRemainingLength(0), Data([0]))
        XCTAssertEqual(MQTTClient.encodeRemainingLength(127), Data([0x7F]))
        XCTAssertEqual(MQTTClient.encodeRemainingLength(128), Data([0x80, 0x01]))
        XCTAssertEqual(MQTTClient.encodeRemainingLength(16_383), Data([0xFF, 0x7F]))
    }

    func testParsePublishAcrossChunks() {
        let topic = MQTTClient.encodeString("a/b")
        let payload = Data("hello".utf8)
        let packet = Data([0x30]) + MQTTClient.encodeRemainingLength(topic.count + payload.count) + topic + payload
        XCTAssertNil(MQTTClient.parsePacket(packet.prefix(4)))
        let parsed = MQTTClient.parsePacket(packet + Data([0xD0, 0x00]))
        XCTAssertEqual(parsed?.type, 3)
        XCTAssertEqual(parsed?.consumed, packet.count)
        XCTAssertEqual(parsed?.body, topic + payload)
    }

    func testConnectPacket() {
        let p = MQTTClient.connectPacket(clientId: "x", keepAlive: 60)
        XCTAssertEqual(p.first, 0x10)
        XCTAssertEqual(Array(p.suffix(3)), [0x00, 0x01, UInt8(ascii: "x")])
    }
}

final class DigitransitDecodingTests: XCTestCase {
    func testLegDecoding() throws {
        let json = """
        {"data":{"planConnection":{"edges":[{"node":{"start":"2026-10-15T07:30:00+03:00","end":"2026-10-15T08:05:00+03:00",
        "walkDistance":420.5,"legs":[
          {"mode":"WALK","distance":300,"realTime":false,"headsign":null,"serviceDate":null,
           "start":{"scheduledTime":"2026-10-15T07:30:00+03:00","estimated":null},
           "end":{"scheduledTime":"2026-10-15T07:34:00+03:00","estimated":null},
           "from":{"name":"Home","lat":60.2,"lon":24.9,"stop":null},
           "to":{"name":"Stop","lat":60.201,"lon":24.901,"stop":{"gtfsId":"HSL:1","name":"Stop","code":"H1","platformCode":null,"lat":60.201,"lon":24.901,"vehicleMode":"BUS"}},
           "legGeometry":{"points":"_p~iF~ps|U"},"route":null,"trip":null},
          {"mode":"BUS","distance":5000,"realTime":true,"headsign":"Itäkeskus","serviceDate":"2026-10-15",
           "start":{"scheduledTime":"2026-10-15T07:35:00+03:00","estimated":{"time":"2026-10-15T07:36:10+03:00"}},
           "end":{"scheduledTime":"2026-10-15T07:55:00+03:00","estimated":null},
           "from":{"name":"Stop","lat":60.201,"lon":24.901,"stop":{"gtfsId":"HSL:1","name":"Stop","code":"H1","platformCode":null,"lat":60.201,"lon":24.901,"vehicleMode":"BUS"}},
           "to":{"name":"End","lat":60.21,"lon":25.08,"stop":{"gtfsId":"HSL:2","name":"End","code":"H2","platformCode":null,"lat":60.21,"lon":25.08,"vehicleMode":"BUS"}},
           "legGeometry":{"points":"_p~iF~ps|U_ulLnnqC"},
           "route":{"gtfsId":"HSL:2550","shortName":"550","longName":"Itäkeskus-Westendinasema","mode":"BUS","type":702},
           "trip":{"gtfsId":"HSL:2550_20261015_Ti_1_0715","directionId":"0","tripHeadsign":"Itäkeskus"}}
        ]}}]}}}
        """
        let env = try JSONDecoder().decode(GQLEnvelope<GQLPlanData>.self, from: Data(json.utf8))
        let it = try XCTUnwrap(env.data?.planConnection.edges.first?.node.toDomain())
        XCTAssertEqual(it.legs.count, 2)
        let bus = it.legs[1]
        XCTAssertEqual(bus.mode, .trunkBus)
        XCTAssertEqual(bus.route?.shortName, "550")
        XCTAssertEqual(bus.trip?.serviceDate, "20261015")
        XCTAssertEqual(bus.estimatedStart!.timeIntervalSince(bus.scheduledStart), 70, accuracy: 0.1)
    }
}

final class DisruptionTests: XCTestCase {
    func testPlainLanguageForRouteOnTrip() {
        let stop = StopRef(id: "HSL:1", name: "Kamppi", location: GeoPoint(latitude: 60.169, longitude: 24.932))
        let leg = Leg(mode: .metro, scheduledStart: Date(), scheduledEnd: Date().addingTimeInterval(600), distance: 3000,
                      from: Place(name: "Kamppi", location: stop.location, stop: stop),
                      to: Place(name: "Ruoholahti", location: GeoPoint(latitude: 60.163, longitude: 24.914)),
                      geometry: [], route: RouteRef(id: "HSL:31M2", shortName: "M2", mode: .metro))
        let it = Itinerary(start: Date(), end: Date().addingTimeInterval(900), legs: [leg], walkDistance: 0)
        let alerts = [
            ServiceAlert(id: "a", header: "Metro M2 not running", description: "", severity: .warning, effect: "NO_SERVICE",
                         routeId: "HSL:31M2", routeName: "M2", stopId: nil, stopName: nil, start: nil, end: nil),
            ServiceAlert(id: "b", header: "Bus 550 detour", description: "", severity: .warning, effect: "DETOUR",
                         routeId: "HSL:2550", routeName: "550", stopId: nil, stopName: nil, start: nil, end: nil),
        ]
        let d = DisruptionDigest.relevant(alerts, to: it)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.summary, "Metro M2 isn't running")
        XCTAssertEqual(d.first?.severity, .severe)
    }
}

final class FMIParserTests: XCTestCase {
    func testParsesSimpleFeatures() {
        let xml = """
        <wfs:FeatureCollection xmlns:wfs="http://www.opengis.net/wfs/2.0" xmlns:BsWfs="http://xml.fmi.fi/schema/wfs/2.0">
          <wfs:member><BsWfs:BsWfsElement>
            <BsWfs:Time>2026-10-15T09:00:00Z</BsWfs:Time>
            <BsWfs:ParameterName>Temperature</BsWfs:ParameterName>
            <BsWfs:ParameterValue>-1.5</BsWfs:ParameterValue>
          </BsWfs:BsWfsElement></wfs:member>
          <wfs:member><BsWfs:BsWfsElement>
            <BsWfs:Time>2026-10-15T09:00:00Z</BsWfs:Time>
            <BsWfs:ParameterName>Precipitation1h</BsWfs:ParameterName>
            <BsWfs:ParameterValue>NaN</BsWfs:ParameterValue>
          </BsWfs:BsWfsElement></wfs:member>
        </wfs:FeatureCollection>
        """
        let els = FMISimpleParser.parse(Data(xml.utf8))
        XCTAssertEqual(els.count, 2)
        XCTAssertEqual(els[0].name, "Temperature")
        XCTAssertEqual(els[0].value, -1.5)
        XCTAssertTrue(els[1].value.isNaN)
    }
}
