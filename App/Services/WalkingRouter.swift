import MapKit
import ETAEngine

/// Walking distances via MapKit, cached, with a straight-line fallback.
@MainActor
final class WalkingRouter {
    /// Typical detour factor of a walking route over the straight line in Helsinki.
    static let detourFactor = 1.3

    private var cache: [String: Double] = [:]

    private func key(_ a: GeoPoint, _ b: GeoPoint) -> String {
        // ~10 m grid so small GPS moves hit the cache.
        String(format: "%.4f,%.4f>%.4f,%.4f", a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Walking route with its path, for showing "where do I need to go" on the map.
    func route(from a: GeoPoint, to b: GeoPoint) async -> (distance: Double, path: [GeoPoint]) {
        let straight = a.distance(to: b)
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.coordinate))
        request.transportType = .walking
        if straight > 30, let route = try? await MKDirections(request: request).calculate().routes.first {
            let poly = route.polyline
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: poly.pointCount)
            poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
            cache[key(a, b)] = route.distance
            return (route.distance, coords.map { GeoPoint($0) })
        }
        return (straight * (straight > 30 ? Self.detourFactor : 1), [a, b])
    }

    /// Street-following shape through a bus trip's stops (driving directions stop to stop),
    /// used when Digitransit has no route geometry. Nil if it couldn't do better than straight lines.
    func roadShape(through stops: [GeoPoint]) async -> [GeoPoint]? {
        guard stops.count >= 2, stops.count <= 80 else { return nil }
        var shape: [GeoPoint] = []
        var routed = 0
        for (a, b) in zip(stops, stops.dropFirst()) {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: a.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.coordinate))
            request.transportType = .automobile
            var piece = [a, b]
            if let route = try? await MKDirections(request: request).calculate().routes.first,
               route.distance < a.distance(to: b) * 3 {  // reject wild detours (one-way systems etc.)
                let poly = route.polyline
                var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: poly.pointCount)
                poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
                piece = coords.map { GeoPoint($0) }
                routed += 1
            }
            shape.append(contentsOf: shape.isEmpty ? piece : Array(piece.dropFirst()))
        }
        return routed > 0 && shape.count > stops.count ? shape : nil
    }

    func distance(from a: GeoPoint, to b: GeoPoint) async -> Double {
        let straight = a.distance(to: b)
        if straight < 60 { return straight }
        let k = key(a, b)
        if let d = cache[k] { return d }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.coordinate))
        request.transportType = .walking
        do {
            let response = try await MKDirections(request: request).calculate()
            if let route = response.routes.first {
                cache[k] = route.distance
                return route.distance
            }
        } catch {}
        return straight * Self.detourFactor
    }
}

/// Keeps a walking distance fresh while the user moves, without calling MapKit every second:
/// takes one routed measurement, then scales the straight-line distance by the observed detour ratio.
@MainActor
final class WalkTracker {
    private let router: WalkingRouter
    private var target: GeoPoint?
    private var ratio = WalkingRouter.detourFactor
    private var anchor: GeoPoint?
    private var lastRouted = Date.distantPast
    private var inFlight = false

    init(router: WalkingRouter) {
        self.router = router
    }

    func distance(from user: GeoPoint, to stop: GeoPoint) -> Double {
        if target != stop {
            target = stop
            ratio = WalkingRouter.detourFactor
            anchor = nil
            lastRouted = .distantPast
        }
        let straight = user.distance(to: stop)
        let movedFar = anchor.map { $0.distance(to: user) > 150 } ?? true
        if !inFlight, movedFar || Date().timeIntervalSince(lastRouted) > 90 {
            inFlight = true
            Task {
                let routed = await router.distance(from: user, to: stop)
                if straight > 30 { ratio = max(1, min(routed / straight, 3)) }
                anchor = user
                lastRouted = Date()
                inFlight = false
            }
        }
        return straight < 40 ? straight : straight * ratio
    }
}
