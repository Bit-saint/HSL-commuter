import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif
import ETAEngine

/// Finnish Meteorological Institute open data (CC BY 4.0), no key needed.
/// https://en.ilmatieteenlaitos.fi/open-data
public struct FMIWeatherClient: Sendable {
    private let session: URLSession
    public var baseURL = "https://opendata.fmi.fi/wfs"

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Next-hour forecast plus the last 12 h of observed precipitation (for ice).
    public func conditions(at point: GeoPoint, now: Date = Date()) async throws -> WeatherConditions {
        let iso = ISO8601DateFormatter()
        let latlon = String(format: "%.4f,%.4f", point.latitude, point.longitude)
        let forecastURL = "\(baseURL)?service=WFS&version=2.0.0&request=getFeature"
            + "&storedquery_id=fmi::forecast::edited::weather::scandinavia::point::simple"
            + "&latlon=\(latlon)&parameters=Temperature,Precipitation1h,WindSpeedMS"
            + "&starttime=\(iso.string(from: now))&endtime=\(iso.string(from: now.addingTimeInterval(2 * 3600)))"
        let forecast = try await fetch(forecastURL)
        func first(_ name: String) -> Double? {
            forecast.filter { $0.name == name && !$0.value.isNaN }.sorted { $0.time < $1.time }.first?.value
        }

        // Observed precipitation, best effort.
        var recent = 0.0
        let obsURL = "\(baseURL)?service=WFS&version=2.0.0&request=getFeature"
            + "&storedquery_id=fmi::observations::weather::simple"
            + "&latlon=\(latlon)&maxlocations=1&parameters=r_1h"
            + "&starttime=\(iso.string(from: now.addingTimeInterval(-12 * 3600)))&endtime=\(iso.string(from: now))"
        if let obs = try? await fetch(obsURL) {
            recent = obs.filter { $0.name == "r_1h" && !$0.value.isNaN && $0.value > 0 }.reduce(0) { $0 + $1.value }
        }
        return WeatherConditions(temperature: first("Temperature") ?? 5,
                                 precipitation: max(first("Precipitation1h") ?? 0, 0),
                                 recentPrecipitation: recent,
                                 windSpeed: first("WindSpeedMS") ?? 0,
                                 time: now)
    }

    struct Element { var time: Date; var name: String; var value: Double }

    private func fetch(_ url: String) async throws -> [Element] {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: u)
        request.timeoutInterval = 15
        let (data, _) = try await session.data(for: request)
        return FMISimpleParser.parse(data)
    }
}

/// Parses BsWfs "simple" feature responses: Time / ParameterName / ParameterValue triples.
final class FMISimpleParser: NSObject, XMLParserDelegate {
    private var elements: [FMIWeatherClient.Element] = []
    private var current = ""
    private var time: Date?
    private var name: String?
    private var value: Double?
    private let iso = ISO8601DateFormatter()

    static func parse(_ data: Data) -> [FMIWeatherClient.Element] {
        let delegate = FMISimpleParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.elements
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        current = ""
        if local(elementName) == "BsWfsElement" { time = nil; name = nil; value = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local(elementName) {
        case "Time": time = iso.date(from: text)
        case "ParameterName": name = text
        case "ParameterValue": value = Double(text) ?? .nan
        case "BsWfsElement":
            if let time, let name, let value { elements.append(.init(time: time, name: name, value: value)) }
        default: break
        }
        current = ""
    }
}
