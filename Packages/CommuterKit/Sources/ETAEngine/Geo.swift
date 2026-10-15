import Foundation

/// WGS84 coordinate. Kept independent of CoreLocation so the engine builds on Linux.
public struct GeoPoint: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    static let earthRadius = 6_371_008.8

    /// Great-circle distance in meters.
    public func distance(to other: GeoPoint) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * GeoPoint.earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Initial bearing in degrees, 0 = north, clockwise.
    public func bearing(to other: GeoPoint) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Local planar coordinates (meters east, meters north) relative to `origin`.
    /// Accurate enough for the few-kilometer spans we work with.
    func local(relativeTo origin: GeoPoint) -> (x: Double, y: Double) {
        let x = (longitude - origin.longitude) * .pi / 180 * GeoPoint.earthRadius * cos(origin.latitude * .pi / 180)
        let y = (latitude - origin.latitude) * .pi / 180 * GeoPoint.earthRadius
        return (x, y)
    }

    func interpolated(to other: GeoPoint, fraction t: Double) -> GeoPoint {
        GeoPoint(latitude: latitude + (other.latitude - latitude) * t,
                 longitude: longitude + (other.longitude - longitude) * t)
    }
}

/// A route shape with cumulative distances, supporting projection of GPS fixes
/// onto "distance along route".
public struct Polyline: Sendable {
    public let points: [GeoPoint]
    /// cumulative[i] = distance in meters from points[0] to points[i].
    public let cumulative: [Double]
    public var length: Double { cumulative.last ?? 0 }

    public init(_ raw: [GeoPoint]) {
        var pts: [GeoPoint] = []
        pts.reserveCapacity(raw.count)
        for p in raw where pts.last.map({ $0.distance(to: p) > 0.5 }) ?? true {
            pts.append(p)
        }
        var cum: [Double] = [0]
        cum.reserveCapacity(pts.count)
        for i in stride(from: 1, to: pts.count, by: 1) {
            cum.append(cum[i - 1] + pts[i - 1].distance(to: pts[i]))
        }
        self.points = pts
        self.cumulative = pts.isEmpty ? [] : cum
    }

    public struct Projection: Sendable, Equatable {
        public var distanceAlong: Double
        /// Perpendicular distance from the fix to the route, meters.
        public var lateralDistance: Double
        public var point: GeoPoint
        public var segmentIndex: Int
    }

    /// Projects `p` onto the polyline. When `hint` is given (last known distance
    /// along), segments near the hint are preferred so loops and routes that run
    /// back past themselves don't make the vehicle jump.
    public func project(_ p: GeoPoint, near hint: Double? = nil, window: Double = 800) -> Projection? {
        guard points.count >= 2 else {
            return points.first.map { Projection(distanceAlong: 0, lateralDistance: $0.distance(to: p), point: $0, segmentIndex: 0) }
        }
        var best: Projection?
        var bestCost = Double.infinity
        for i in 0..<(points.count - 1) {
            if let hint {
                // Allow a little backwards slack for GPS noise, more forwards.
                if cumulative[i + 1] < hint - window * 0.25 || cumulative[i] > hint + window { continue }
            }
            let proj = projectOnSegment(p, i)
            var cost = proj.lateralDistance
            if let hint { cost += 0.02 * abs(proj.distanceAlong - hint) }
            if cost < bestCost {
                bestCost = cost
                best = proj
            }
        }
        // Hint window found nothing sensible, so fall back to a global search.
        if hint != nil, best == nil || best!.lateralDistance > 150 {
            let global = project(p, near: nil)
            if let global, global.lateralDistance < (best?.lateralDistance ?? .infinity) - 50 {
                return global
            }
        }
        return best
    }

    private func projectOnSegment(_ p: GeoPoint, _ i: Int) -> Projection {
        let a = points[i], b = points[i + 1]
        let pa = a.local(relativeTo: p)
        let pb = b.local(relativeTo: p)
        // Vector a->b and a->p (p is origin, so a->p = -pa).
        let abx = pb.x - pa.x, aby = pb.y - pa.y
        let len2 = abx * abx + aby * aby
        var t = len2 > 0 ? ((-pa.x) * abx + (-pa.y) * aby) / len2 : 0
        t = min(max(t, 0), 1)
        let cx = pa.x + abx * t, cy = pa.y + aby * t
        let lateral = (cx * cx + cy * cy).squareRoot()
        let segLen = cumulative[i + 1] - cumulative[i]
        return Projection(distanceAlong: cumulative[i] + segLen * t,
                          lateralDistance: lateral,
                          point: a.interpolated(to: b, fraction: t),
                          segmentIndex: i)
    }

    private func segmentIndex(at distance: Double) -> Int {
        // Binary search for the last cumulative <= distance.
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cumulative[mid] <= distance { lo = mid } else { hi = mid - 1 }
        }
        return min(lo, max(points.count - 2, 0))
    }

    /// Coordinate at a given distance along the route (clamped).
    public func point(at distance: Double) -> GeoPoint {
        guard points.count >= 2 else { return points.first ?? GeoPoint(latitude: 0, longitude: 0) }
        let d = min(max(distance, 0), length)
        let i = segmentIndex(at: d)
        let segLen = cumulative[i + 1] - cumulative[i]
        let t = segLen > 0 ? (d - cumulative[i]) / segLen : 0
        return points[i].interpolated(to: points[i + 1], fraction: t)
    }

    /// Direction of travel at a given distance along the route.
    public func bearing(at distance: Double) -> Double {
        guard points.count >= 2 else { return 0 }
        let i = segmentIndex(at: min(max(distance, 0), length))
        return points[i].bearing(to: points[i + 1])
    }

    /// The points between two distances, endpoints included.
    public func slice(from start: Double, to end: Double) -> [GeoPoint] {
        guard points.count >= 2, end > start else { return [] }
        var out = [point(at: start)]
        for (i, c) in cumulative.enumerated() where c > start && c < end {
            out.append(points[i])
        }
        out.append(point(at: end))
        return out
    }

    /// Decodes a Google encoded polyline (Digitransit `legGeometry.points`).
    public static func decodeGoogle(_ encoded: String, precision: Double = 1e5) -> [GeoPoint] {
        var result: [GeoPoint] = []
        let bytes = Array(encoded.utf8)
        var index = 0, lat = 0, lon = 0
        func next() -> Int? {
            var shift = 0, value = 0
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                value |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 { return (value & 1) != 0 ? ~(value >> 1) : (value >> 1) }
            }
            return nil
        }
        while index < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            result.append(GeoPoint(latitude: Double(lat) / precision, longitude: Double(lon) / precision))
        }
        return result
    }
}
