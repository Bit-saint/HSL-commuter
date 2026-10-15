#if canImport(SwiftUI)
import SwiftUI
import ETAEngine

/// A tiny box-model 3D renderer for HSL vehicles.
///
/// MapKit can't place real 3D models, so vehicles are drawn as shaded 3D boxes
/// projected with the map camera's heading and pitch. `VehicleSpriteCache`
/// pre-renders each model at 64 headings × 4 pitches into images, so the map
/// only blits bitmaps (the "pre-rendered sprites" approach from the plan).
/// Swap in sprite sheets rendered from real models later via `VehicleSpriteCache.customSprite`.
public struct VehicleModel: Sendable {
    public struct Box: Sendable {
        /// Center in meters: x forward, y right, z up.
        public var center: SIMD3<Double>
        public var size: SIMD3<Double>
        public var color: RGB
        /// Optional different top colour (roofs).
        public var top: RGB?
        public init(center: SIMD3<Double>, size: SIMD3<Double>, color: RGB, top: RGB? = nil) {
            self.center = center
            self.size = size
            self.color = color
            self.top = top
        }
    }

    public struct RGB: Sendable {
        public var r: Double, g: Double, b: Double
        public init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
        func shaded(_ k: Double) -> Color { Color(.sRGB, red: min(r * k, 1), green: min(g * k, 1), blue: min(b * k, 1)) }
    }

    public var length: Double
    public var width: Double
    public var boxes: [Box]

    // Livery colours
    static let hslBlue = RGB(0x007AC9)
    static let white = RGB(0xF4F6F8)
    static let glass = RGB(0x1A2633)
    static let roofGrey = RGB(0xC9CED4)
    static let tramGreen = RGB(0x00985F)
    static let jokeri = RGB(0x00B2A9)
    static let metroOrange = RGB(0xFF6319)
    static let trainPurple = RGB(0x8C4799)
    static let trunkOrange = RGB(0xEA7000)
    static let ferryHull = RGB(0x0E3A5B)
    static let ferryCyan = RGB(0x00B9E4)
    static let dark = RGB(0x2B2B2B)

    /// A rail/road car: body, window band, roof, glazed front.
    static func car(at x: Double, length: Double, width: Double, height: Double, body: RGB, roof: RGB,
                    stripe: RGB? = nil, cab: Bool) -> [Box] {
        let lower = height * 0.42
        let windows = height * 0.36
        let roofH = height - lower - windows - 0.15
        var out: [Box] = [
            Box(center: [x, 0, 0.15 + lower / 2], size: [length, width, lower], color: body),
            Box(center: [x, 0, 0.15 + lower + windows / 2], size: [length * 0.98, width * 0.97, windows], color: glass),
            Box(center: [x, 0, 0.15 + lower + windows + roofH / 2], size: [length, width, roofH], color: body, top: roof),
        ]
        if let stripe {
            out.append(Box(center: [x, 0, 0.15 + lower * 0.35], size: [length * 1.002, width * 1.01, lower * 0.25], color: stripe))
        }
        if cab {
            // Glazed nose to show direction.
            out.append(Box(center: [x + length / 2 - 0.05, 0, 0.15 + lower + windows * 0.4],
                           size: [0.12, width * 0.9, windows * 1.4], color: glass))
        }
        return out
    }

    public static func model(for mode: TransitMode) -> VehicleModel {
        switch mode {
        case .bus, .uBus:
            return VehicleModel(length: 12.2, width: 2.55,
                                boxes: car(at: 0, length: 12.2, width: 2.55, height: 3.1, body: hslBlue, roof: white, cab: true))
        case .trunkBus:
            let a = car(at: 4.3, length: 9.6, width: 2.55, height: 3.1, body: hslBlue, roof: trunkOrange, cab: true)
            let b = car(at: -5.3, length: 7.4, width: 2.55, height: 3.1, body: hslBlue, roof: trunkOrange, cab: false)
            let joint = Box(center: [-0.9, 0, 1.7], size: [1.2, 2.3, 2.6], color: dark)
            return VehicleModel(length: 18.7, width: 2.55, boxes: a + [joint] + b)
        case .tram:
            // Artic: three sections, 27 m.
            let s = 8.6
            return VehicleModel(length: 27.6, width: 2.4, boxes:
                car(at: s + 0.3, length: s, width: 2.4, height: 3.4, body: tramGreen, roof: roofGrey, cab: true) +
                car(at: 0, length: s, width: 2.4, height: 3.4, body: tramGreen, roof: roofGrey, cab: false) +
                car(at: -s - 0.3, length: s, width: 2.4, height: 3.4, body: tramGreen, roof: roofGrey, cab: true))
        case .lightRail:
            let s = 11.0
            return VehicleModel(length: 34, width: 2.65, boxes:
                car(at: s + 0.3, length: s, width: 2.65, height: 3.5, body: white, roof: roofGrey, stripe: jokeri, cab: true) +
                car(at: 0, length: s, width: 2.65, height: 3.5, body: white, roof: roofGrey, stripe: jokeri, cab: false) +
                car(at: -s - 0.3, length: s, width: 2.65, height: 3.5, body: white, roof: roofGrey, stripe: jokeri, cab: true))
        case .metro:
            // M300-style: four cars, orange.
            let c = 22.0
            var boxes: [Box] = []
            for i in 0..<4 {
                let x = (1.5 - Double(i)) * (c + 0.4)
                boxes += car(at: x, length: c, width: 3.2, height: 3.7, body: metroOrange, roof: roofGrey,
                             cab: i == 0 || i == 3)
            }
            return VehicleModel(length: 4 * c + 1.2, width: 3.2, boxes: boxes)
        case .rail:
            // Sm5-style: white with purple lower band, three sections.
            let c = 25.0
            var boxes: [Box] = []
            for i in 0..<3 {
                let x = (1 - Double(i)) * (c + 0.4)
                boxes += car(at: x, length: c, width: 3.2, height: 4.2, body: white, roof: roofGrey,
                             stripe: trainPurple, cab: i == 0 || i == 2)
            }
            return VehicleModel(length: 3 * c + 0.8, width: 3.2, boxes: boxes)
        case .ferry:
            return VehicleModel(length: 30, width: 8, boxes: [
                Box(center: [0, 0, 0.9], size: [30, 8, 1.8], color: ferryHull),
                Box(center: [13.5, 0, 0.9], size: [3, 5, 1.8], color: ferryHull),
                Box(center: [-1, 0, 2.8], size: [20, 7, 2.0], color: white),
                Box(center: [-1, 0, 2.8], size: [19.6, 7.05, 0.9], color: glass),
                Box(center: [2, 0, 4.6], size: [8, 5, 1.6], color: white, top: ferryCyan),
            ])
        default:
            return model(for: .bus)
        }
    }
}

/// Renders a `VehicleModel` into a `GraphicsContext`.
public enum VehicleRenderer {
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
        let viewDir = SIMD3(0, -sin(theta), cos(theta)) // towards the camera
        let light = simd_normalize3(SIMD3(-0.35, -0.45, 0.82))

        func world(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let g = fwd * p.x + right * p.y
            return SIMD3(g.x, g.y, p.z)
        }
        func project(_ w: SIMD3<Double>) -> CGPoint {
            let sx = w.x
            let sy = -(w.y * cos(theta) + w.z * sin(theta))
            return CGPoint(x: center.x + sx * scale, y: center.y + sy * scale)
        }
        func depth(_ w: SIMD3<Double>) -> Double { w.z * cos(theta) - w.y * sin(theta) }

        // Ground shadow.
        let half = SIMD2(model.length / 2 + 0.4, model.width / 2 + 0.4)
        let corners = [SIMD3(half.x, half.y, 0), SIMD3(half.x, -half.y, 0),
                       SIMD3(-half.x, -half.y, 0), SIMD3(-half.x, half.y, 0)].map { project(world($0)) }
        var shadow = Path()
        shadow.addLines(corners)
        shadow.closeSubpath()
        ctx.fill(shadow, with: .color(.black.opacity(0.28)))

        struct Face { var pts: [CGPoint]; var depth: Double; var color: Color }
        var faces: [Face] = []
        faces.reserveCapacity(model.boxes.count * 3)

        for box in model.boxes {
            let c = box.center, h = box.size / 2
            // 6 faces: normal (local) and its 4 corners.
            let defs: [(SIMD3<Double>, [SIMD3<Double>])] = [
                (SIMD3(0, 0, 1), [SIMD3(h.x, h.y, h.z), SIMD3(h.x, -h.y, h.z), SIMD3(-h.x, -h.y, h.z), SIMD3(-h.x, h.y, h.z)]),
                (SIMD3(1, 0, 0), [SIMD3(h.x, h.y, h.z), SIMD3(h.x, -h.y, h.z), SIMD3(h.x, -h.y, -h.z), SIMD3(h.x, h.y, -h.z)]),
                (SIMD3(-1, 0, 0), [SIMD3(-h.x, h.y, h.z), SIMD3(-h.x, -h.y, h.z), SIMD3(-h.x, -h.y, -h.z), SIMD3(-h.x, h.y, -h.z)]),
                (SIMD3(0, 1, 0), [SIMD3(h.x, h.y, h.z), SIMD3(-h.x, h.y, h.z), SIMD3(-h.x, h.y, -h.z), SIMD3(h.x, h.y, -h.z)]),
                (SIMD3(0, -1, 0), [SIMD3(h.x, -h.y, h.z), SIMD3(-h.x, -h.y, h.z), SIMD3(-h.x, -h.y, -h.z), SIMD3(h.x, -h.y, -h.z)]),
            ]
            for (n, quad) in defs {
                let wn = world(n)
                let facing = wn.x * viewDir.x + wn.y * viewDir.y + wn.z * viewDir.z
                guard facing > 0.001 else { continue }
                let ws = quad.map { world(c + $0) }
                let d = ws.map(depth).reduce(0, +) / 4
                let lambert = max(0, wn.x * light.x + wn.y * light.y + wn.z * light.z)
                let base = (n.z > 0 ? (box.top ?? box.color) : box.color)
                faces.append(Face(pts: ws.map(project), depth: d, color: base.shaded(0.55 + 0.55 * lambert)))
            }
        }
        for f in faces.sorted(by: { $0.depth < $1.depth }) {
            var p = Path()
            p.addLines(f.pts)
            p.closeSubpath()
            ctx.fill(p, with: .color(f.color))
            ctx.stroke(p, with: .color(.black.opacity(0.12)), lineWidth: 0.5)
        }
    }

    private static func simd_normalize3(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return v / l
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
    private let pointsPerMeter: Double = 3
    private let renderScale: CGFloat = 3

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
        return img
    }

    /// The model's sprite side length in points at the cache's native scale.
    public func nativeSide(for mode: TransitMode) -> Double {
        (VehicleModel.model(for: mode).length + 6) * pointsPerMeter
    }
}
#endif
