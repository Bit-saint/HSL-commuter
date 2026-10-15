#if canImport(SwiftUI)
import SwiftUI
import ETAEngine

/// A small polygon-mesh 3D renderer for HSL vehicles.
///
/// MapKit can't place real 3D models, so vehicles are built from convex lofted bodies
/// (rounded roofs, raked noses), flat detail panels (windows, doors, lights, displays),
/// wheels, bogies and roof gear, then projected with the map camera's heading and pitch.
/// `VehicleSpriteCache` pre-renders each model at 64 headings × 4 pitches into images, so the
/// map only blits bitmaps. Models live in `VehicleModels.swift`.
public struct VehicleModel: Sendable {
    public enum Material: Sendable { case paint, glass, dark, metal, light }

    public struct RGB: Sendable {
        public var r: Double, g: Double, b: Double
        public init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    }

    public struct Face: Sendable {
        /// Corners in meters: x forward, y right, z up.
        public var points: [SIMD3<Double>]
        public var normal: SIMD3<Double>
        public var color: RGB
        public var material: Material
        /// Part of the vehicle (one car, a joint). Parts are painted back to front.
        public var group: Int
        /// Order inside a part: body 0, panels on it 1–2, roof gear 3, wheels ±.
        public var bias: Double
        /// Wheels: drawn over the body only while this side of the vehicle faces the camera.
        public var side: SIMD3<Double>?
    }

    public var length: Double
    public var width: Double
    public var faces: [Face]
    /// Centre of each part, indexed by `Face.group`.
    public var anchors: [SIMD3<Double>]
}

/// Renders a `VehicleModel` into a `GraphicsContext`.
public enum VehicleRenderer {
    static let sky = VehicleModel.RGB(0x9DBBD6)

    /// - Parameters:
    ///   - relativeHeading: vehicle heading minus map camera heading, degrees (0 = pointing up the screen).
    ///   - pitch: map camera pitch, degrees (0 = straight down).
    ///   - scale: points per meter.
    public static func draw(_ model: VehicleModel, in ctx: GraphicsContext, center: CGPoint,
                            relativeHeading: Double, pitch: Double, scale: Double) {
        let psi = relativeHeading * .pi / 180
        let theta = min(max(pitch, 0), 80) * .pi / 180
        let fwd = SIMD2(sin(psi), cos(psi))          // vehicle forward on the ground (u right, v away)
        let right = SIMD2(cos(psi), -sin(psi))
        let view = SIMD3(0, -sin(theta), cos(theta)) // towards the camera
        let light = Geo3.normalize(SIMD3(-0.35, -0.45, 0.82))

        func world(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let g = fwd * p.x + right * p.y
            return SIMD3(g.x, g.y, p.z)
        }
        func project(_ w: SIMD3<Double>) -> CGPoint {
            CGPoint(x: center.x + w.x * scale, y: center.y - (w.y * cos(theta) + w.z * sin(theta)) * scale)
        }
        func depth(_ w: SIMD3<Double>) -> Double { w.z * cos(theta) - w.y * sin(theta) }

        // Soft ground shadow.
        let half = SIMD2(model.length / 2 + 0.3, model.width / 2 + 0.3)
        var shadow = Path()
        shadow.addLines([SIMD3(half.x, half.y, 0), SIMD3(half.x, -half.y, 0),
                         SIMD3(-half.x, -half.y, 0), SIMD3(-half.x, half.y, 0)].map { project(world($0)) })
        shadow.closeSubpath()
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: max(scale * 0.35, 1)))
            layer.fill(shadow, with: .color(.black.opacity(0.32)))
        }

        let groupDepth = model.anchors.map { depth(world($0)) }
        struct Item { var group: Double; var bias: Double; var depth: Double; var path: Path; var color: Color }
        var items: [Item] = []
        items.reserveCapacity(model.faces.count / 2)

        for face in model.faces {
            let wn = world(face.normal)
            let facing = Geo3.dot(wn, view)
            guard facing > 0.001 else { continue }
            var bias = face.bias
            if let side = face.side, Geo3.dot(world(side), view) <= 0 { bias = -1 }
            let ws = face.points.map(world)
            let d = ws.reduce(0) { $0 + depth($1) } / Double(ws.count)
            var path = Path()
            path.addLines(ws.map(project))
            path.closeSubpath()
            items.append(Item(group: groupDepth.indices.contains(face.group) ? groupDepth[face.group] : 0,
                              bias: bias, depth: d, path: path,
                              color: shade(face, normal: wn, facing: facing, view: view, light: light)))
        }
        items.sort {
            if $0.group != $1.group { return $0.group < $1.group }
            if $0.bias != $1.bias { return $0.bias < $1.bias }
            return $0.depth < $1.depth
        }
        for item in items {
            ctx.fill(item.path, with: .color(item.color))
            // Same-colour hairline closes anti-aliasing seams between neighbouring faces.
            ctx.stroke(item.path, with: .color(item.color), lineWidth: 0.6)
        }
    }

    private static func shade(_ face: VehicleModel.Face, normal n: SIMD3<Double>, facing: Double,
                              view: SIMD3<Double>, light: SIMD3<Double>) -> Color {
        let c = face.color
        let lambert = max(0, Geo3.dot(n, light))
        let reflected = n * (2 * facing) - view
        let spec = pow(max(0, Geo3.dot(reflected, light)), 24)
        func mix(_ k: Double, _ add: Double) -> (Double, Double, Double) { (c.r * k + add, c.g * k + add, c.b * k + add) }
        let out: (Double, Double, Double)
        switch face.material {
        case .paint: out = mix(0.52 + 0.55 * lambert, 0.22 * spec)
        case .metal: out = mix(0.45 + 0.5 * lambert, 0.45 * spec)
        case .dark: out = mix(0.7 + 0.45 * lambert, 0)
        case .light: out = (c.r, c.g, c.b)
        case .glass:
            // Dark tint plus sky reflection: stronger at grazing angles and on upward faces.
            let f = min(0.12 + 0.5 * pow(1 - facing, 2) + 0.25 * max(0, n.z), 0.85)
            out = (c.r * (1 - f) + sky.r * f + 0.5 * spec,
                   c.g * (1 - f) + sky.g * f + 0.5 * spec,
                   c.b * (1 - f) + sky.b * f + 0.5 * spec)
        }
        return Color(.sRGB, red: min(max(out.0, 0), 1), green: min(max(out.1, 0), 1), blue: min(max(out.2, 0), 1))
    }
}

enum Geo3 {
    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    static func length(_ a: SIMD3<Double>) -> Double { dot(a, a).squareRoot() }
    static func normalize(_ a: SIMD3<Double>) -> SIMD3<Double> {
        let l = length(a)
        return l > 0 ? a / l : a
    }
}

/// Live-drawn vehicle (use for previews or when the cache isn't warm).
public struct VehicleSpriteView: View {
    var mode: TransitMode
    var relativeHeading: Double
    var pitch: Double
    var pointsPerMeter: Double

    public init(mode: TransitMode, relativeHeading: Double, pitch: Double, pointsPerMeter: Double = 3) {
        self.mode = mode
        self.relativeHeading = relativeHeading
        self.pitch = pitch
        self.pointsPerMeter = pointsPerMeter
    }

    public var body: some View {
        let model = VehicleModel.model(for: mode)
        let side = (model.length + 6) * pointsPerMeter
        Canvas { ctx, size in
            VehicleRenderer.draw(model, in: ctx, center: CGPoint(x: size.width / 2, y: size.height / 2),
                                 relativeHeading: relativeHeading, pitch: pitch, scale: pointsPerMeter)
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }
}

/// Pre-renders sprites: 64 headings × 4 pitch levels per mode, rendered lazily and cached.
@MainActor
public final class VehicleSpriteCache {
    public static let shared = VehicleSpriteCache()
    public static let headingSteps = 64
    public static let pitchLevels: [Double] = [0, 30, 50, 70]
    /// Optional hook to supply sprites from real 3D renders (e.g. an asset catalog sheet).
    public var customSprite: ((TransitMode, Int, Int) -> Image?)?

    private var cache: [String: Image] = [:]
    /// Oldest first; the cache keeps the most recent `capacity` sprites (a metro sprite is ~1.3 MB).
    private var order: [String] = []
    public var capacity = 64
    private let pointsPerMeter: Double = 3
    private let renderScale: CGFloat = 2

    public func sprite(mode: TransitMode, relativeHeading: Double, pitch: Double) -> Image? {
        let h = Int(((relativeHeading.truncatingRemainder(dividingBy: 360) + 360) / 360 * Double(Self.headingSteps))
            .rounded()) % Self.headingSteps
        let p = Self.pitchLevels.enumerated().min { abs($0.element - pitch) < abs($1.element - pitch) }?.offset ?? 0
        if let o = customSprite?(mode, h, p) { return o }
        let key = "\(mode.rawValue)-\(h)-\(p)"
        if let img = cache[key] { return img }
        let view = VehicleSpriteView(mode: mode, relativeHeading: Double(h) * 360 / Double(Self.headingSteps),
                                     pitch: Self.pitchLevels[p], pointsPerMeter: pointsPerMeter)
        let renderer = ImageRenderer(content: view)
        renderer.scale = renderScale
        guard let cg = renderer.cgImage else { return nil }
        let img = Image(decorative: cg, scale: renderScale)
        cache[key] = img
        order.append(key)
        if order.count > capacity { cache[order.removeFirst()] = nil }
        return img
    }

    /// The model's sprite side length in points at the cache's native scale.
    public func nativeSide(for mode: TransitMode) -> Double {
        (VehicleModel.model(for: mode).length + 6) * pointsPerMeter
    }
}
#endif
