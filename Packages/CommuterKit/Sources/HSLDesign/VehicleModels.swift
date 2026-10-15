#if canImport(SwiftUI)
import Foundation
import ETAEngine

// HSL vehicles as low-poly meshes, in meters (x forward, y right, z up). Doors are on the
// right (+y) for road vehicles and trams, both sides for metro and trains.

public extension VehicleModel {
    static func model(for mode: TransitMode) -> VehicleModel {
        switch mode {
        case .bus, .uBus: return Built.bus
        case .trunkBus: return Built.trunkBus
        case .tram: return Built.tram
        case .lightRail: return Built.lightRail
        case .metro: return Built.metro
        case .rail: return Built.train
        case .ferry: return Built.ferry
        default: return Built.bus
        }
    }
}

/// Built once per process.
private enum Built {
    static let bus = VehicleModels.bus()
    static let trunkBus = VehicleModels.trunkBus()
    static let tram = VehicleModels.artic(modules: [9.4, 8.0, 9.4], width: 2.4, bidirectional: false)
    static let lightRail = VehicleModels.artic(modules: [11.6, 9.4, 11.6], width: 2.65, bidirectional: true)
    static let metro = VehicleModels.metro()
    static let train = VehicleModels.train()
    static let ferry = VehicleModels.ferry()
}

// MARK: - Mesh builder

typealias V3 = SIMD3<Double>
typealias YZ = (y: Double, z: Double)
typealias Paint = (color: VehicleModel.RGB, material: VehicleModel.Material)

struct MeshBuilder {
    var faces: [VehicleModel.Face] = []
    var anchors: [V3] = []
    var group: Int { anchors.count - 1 }

    mutating func newGroup(_ anchor: V3) { anchors.append(anchor) }

    func model(length: Double, width: Double) -> VehicleModel {
        VehicleModel(length: length, width: width, faces: faces, anchors: anchors)
    }

    /// Adds a planar polygon; flips it so its normal points away from `outwardFrom`.
    mutating func add(_ pts: [V3], _ paint: Paint, bias: Double = 0, outwardFrom: V3? = nil, side: V3? = nil) {
        var pts = pts
        var n = Geo3.normalize(Geo3.cross(pts[1] - pts[0], pts[2] - pts[0]))
        if let o = outwardFrom {
            let c = pts.reduce(V3(0, 0, 0), +) / Double(pts.count)
            if Geo3.dot(n, c - o) < 0 { n = -n; pts.reverse() }
        }
        faces.append(.init(points: pts, normal: n, color: paint.color, material: paint.material,
                           group: group, bias: bias, side: side))
    }

    /// Panel with a known normal (windows, doors, lights), lifted slightly off the surface.
    mutating func panel(_ pts: [V3], normal: V3, _ paint: Paint, bias: Double) {
        faces.append(.init(points: pts, normal: normal, color: paint.color, material: paint.material,
                           group: group, bias: bias, side: nil))
    }

    /// Convex solid between two (y, z) profiles at x0 < x1 with the same vertex count.
    /// `paints` has one entry per profile edge plus one for the caps.
    mutating func loft(_ x0: Double, _ p0: [YZ], _ x1: Double, _ p1: [YZ], _ paints: [Paint],
                       cap0: Bool = true, cap1: Bool = true, bias: Double = 0) {
        let n = p0.count
        let all = p0 + p1
        let cen = V3((x0 + x1) / 2, all.reduce(0) { $0 + $1.y } / Double(all.count),
                     all.reduce(0) { $0 + $1.z } / Double(all.count))
        for k in 0..<n {
            let a = k, b = (k + 1) % n
            add([V3(x0, p0[a].y, p0[a].z), V3(x1, p1[a].y, p1[a].z), V3(x1, p1[b].y, p1[b].z), V3(x0, p0[b].y, p0[b].z)],
                paints[k], bias: bias, outwardFrom: cen)
        }
        if cap0 { add(p0.map { V3(x0, $0.y, $0.z) }, paints[n], bias: bias, outwardFrom: cen) }
        if cap1 { add(p1.map { V3(x1, $0.y, $0.z) }, paints[n], bias: bias, outwardFrom: cen) }
    }

    mutating func box(_ c: V3, _ size: V3, _ paint: Paint, top: Paint? = nil, bias: Double = 0) {
        let h = size / 2
        let p: [YZ] = [(c.y - h.y, c.z - h.z), (c.y + h.y, c.z - h.z), (c.y + h.y, c.z + h.z), (c.y - h.y, c.z + h.z)]
        loft(c.x - h.x, p, c.x + h.x, p, [paint, paint, top ?? paint, paint, paint], bias: bias)
    }

    /// Thin beam from a to b with a square section (pantograph arms, mirror arms).
    mutating func beam(_ a: V3, _ b: V3, _ t: Double, _ paint: Paint, bias: Double = 0) {
        let u = Geo3.normalize(b - a)
        var w = Geo3.cross(u, V3(0, 0, 1))
        if Geo3.length(w) < 1e-6 { w = Geo3.cross(u, V3(0, 1, 0)) }
        w = Geo3.normalize(w) * (t / 2)
        let h = Geo3.normalize(Geo3.cross(w, u)) * (t / 2)
        let corners = [w + h, -w + h, -w - h, w - h]
        let cen = (a + b) / 2
        for k in 0..<4 {
            let c0 = corners[k], c1 = corners[(k + 1) % 4]
            add([a + c0, b + c0, b + c1, a + c1], paint, bias: bias, outwardFrom: cen)
        }
        add(corners.map { b + $0 }, paint, bias: bias, outwardFrom: cen)
        add(corners.map { a + $0 }, paint, bias: bias, outwardFrom: cen)
    }

    /// Rectangle on the vehicle side at y = ±halfWidth.
    mutating func side(_ sgn: Double, _ hw: Double, _ x0: Double, _ x1: Double, _ z0: Double, _ z1: Double,
                       _ paint: Paint, bias: Double = 1, lift: Double = 0.012) {
        let y = sgn * (hw + lift)
        panel([V3(x0, y, z0), V3(x1, y, z0), V3(x1, y, z1), V3(x0, y, z1)], normal: V3(0, sgn, 0), paint, bias: bias)
    }

    mutating func sidePolygon(_ sgn: Double, _ hw: Double, _ xz: [(Double, Double)], _ paint: Paint,
                              bias: Double = 1, lift: Double = 0.012) {
        let y = sgn * (hw + lift)
        panel(xz.map { V3($0.0, y, $0.1) }, normal: V3(0, sgn, 0), paint, bias: bias)
    }

    /// Rectangle on a flat end face at x (front sgn = 1, rear sgn = -1).
    mutating func end(_ x: Double, _ sgn: Double, y0: Double, y1: Double, z0: Double, z1: Double,
                      _ paint: Paint, bias: Double = 1, lift: Double = 0.012) {
        let xx = x + sgn * lift
        panel([V3(xx, y0, z0), V3(xx, y1, z0), V3(xx, y1, z1), V3(xx, y0, z1)], normal: V3(sgn, 0, 0), paint, bias: bias)
    }

    /// Wheel on the side given by the sign of y; painted over the body when that side faces you.
    mutating func wheel(x: Double, y: Double, r: Double, width: Double, z: Double? = nil, sides: Int = 10) {
        let zc = z ?? r
        let sgn: Double = y > 0 ? 1 : -1
        let ring = (0..<sides).map { k -> (Double, Double) in
            let a = 2 * Double.pi * Double(k) / Double(sides)
            return (x + r * cos(a), zc + r * sin(a))
        }
        let yo = y + sgn * width / 2, yi = y - sgn * width / 2
        let cen = V3(x, y, zc), cond = V3(0, sgn, 0)
        let tyre: Paint = (Livery.tyre, .dark)
        for k in 0..<sides {
            let p = ring[k], q = ring[(k + 1) % sides]
            add([V3(p.0, yo, p.1), V3(q.0, yo, q.1), V3(q.0, yi, q.1), V3(p.0, yi, p.1)], tyre,
                bias: 1.5, outwardFrom: cen, side: cond)
        }
        faces.append(.init(points: ring.map { V3($0.0, yo, $0.1) }, normal: cond, color: tyre.color,
                           material: .dark, group: group, bias: 1.5, side: cond))
        let hub = (0..<sides).map { k -> V3 in
            let a = 2 * Double.pi * Double(k) / Double(sides)
            return V3(x + r * 0.55 * cos(a), yo + sgn * 0.01, zc + r * 0.55 * sin(a))
        }
        faces.append(.init(points: hub, normal: cond, color: Livery.hub, material: .metal,
                           group: group, bias: 1.6, side: cond))
    }
}

// MARK: - Shapes and livery

enum Livery {
    typealias RGB = VehicleModel.RGB
    static let hslBlue = RGB(0x007AC9)
    static let blueDark = RGB(0x00548C)
    static let white = RGB(0xF2F4F6)
    static let grey = RGB(0xB9C0C7)
    static let lightGrey = RGB(0xD5DADF)
    static let glass = RGB(0x0F1A24)
    static let doorGlass = RGB(0x1C2A36)
    static let glazingFrame = RGB(0x0B1218)
    static let darkTrim = RGB(0x2A2E33)
    static let under = RGB(0x1A1C1F)
    static let tyre = RGB(0x1E1E1E)
    static let hub = RGB(0x8A9096)
    static let tramGreen = RGB(0x00985F)
    static let metroOrange = RGB(0xFF6319)
    static let trainPurple = RGB(0x8C4799)
    static let led = RGB(0xFFB000)
    static let headlight = RGB(0xFFF6D8)
    static let taillight = RGB(0xD0102A)
    static let insulator = RGB(0xC9A23A)
    static let ferryHull = RGB(0x0E3A5B)
    static let ferryCyan = RGB(0x00B9E4)
}

/// Rounded-roof cross-section (y, z), 10 points. `tw` = width at the shoulder (tumblehome).
func profile(_ w: Double, _ zb: Double, _ zt: Double, _ r: Double, tw: Double? = nil) -> [YZ] {
    let segs = 3
    let hw = w / 2, ht = (tw ?? w) / 2
    var pts: [YZ] = [(hw, zb), (ht, zt - r)]
    for k in 1..<segs {
        let a = Double.pi / 2 * Double(k) / Double(segs)
        pts.append((ht - r + r * cos(a), zt - r + r * sin(a)))
    }
    pts.append((ht - r, zt))
    pts.append((-(ht - r), zt))
    for k in stride(from: segs - 1, through: 1, by: -1) {
        let a = Double.pi / 2 * Double(k) / Double(segs)
        pts.append((-(ht - r + r * cos(a)), zt - r + r * sin(a)))
    }
    pts.append((-ht, zt - r))
    pts.append((-hw, zb))
    return pts
}

/// Paints for a `profile`: sides, shoulders, roof, underside, then caps (side colour).
func bodyPaints(_ side: Paint, roof: Paint, under: Paint, shoulder: Paint? = nil) -> [Paint] {
    let n = 10
    var out: [Paint] = []
    for k in 0..<n {
        if k == 0 || k == n - 2 { out.append(side) }
        else if k == n - 1 { out.append(under) }
        else if [1, 2, n - 4, n - 3].contains(k), let shoulder { out.append(shoulder) }
        else { out.append(roof) }
    }
    out.append(side)
    return out
}

enum VehicleModels {
    typealias RGB = VehicleModel.RGB

    // MARK: Shared details

    static func panes(_ m: inout MeshBuilder, _ s: Double, _ hw: Double, _ x0: Double, _ x1: Double,
                      _ z0: Double, _ z1: Double, pitch: Double = 1.45, gap: Double = 0.09) {
        let n = max(1, Int(((x1 - x0) / pitch).rounded()))
        let step = (x1 - x0) / Double(n)
        for k in 0..<n {
            m.side(s, hw, x0 + Double(k) * step + gap / 2, x0 + Double(k + 1) * step - gap / 2, z0, z1, (Livery.glass, .glass))
        }
    }

    static func door(_ m: inout MeshBuilder, _ s: Double, _ hw: Double, _ x0: Double, _ x1: Double,
                     _ z0: Double, _ z1: Double, frame: RGB) {
        m.side(s, hw, x0, x1, z0, z1, (frame, .paint), bias: 2, lift: 0.016)
        let mid = (x0 + x1) / 2
        m.side(s, hw, x0 + 0.07, mid - 0.03, z0 + 0.12, z1 - 0.1, (Livery.doorGlass, .glass), bias: 2.1, lift: 0.02)
        m.side(s, hw, mid + 0.03, x1 - 0.07, z0 + 0.12, z1 - 0.1, (Livery.doorGlass, .glass), bias: 2.1, lift: 0.02)
    }

    static func wheelArch(_ m: inout MeshBuilder, _ s: Double, _ hw: Double, x: Double, zc: Double, r: Double) {
        let pts = (0...8).map { k -> (Double, Double) in
            let a = Double.pi * Double(k) / 8
            return (x + r * cos(a), zc + r * sin(a))
        }
        m.sidePolygon(s, hw, pts, (Livery.under, .dark), bias: 1.2)
    }

    static func mirror(_ m: inout MeshBuilder, x: Double, _ s: Double, _ hw: Double, z: Double) {
        m.beam(V3(x - 0.15, s * hw, z), V3(x + 0.3, s * (hw + 0.28), z - 0.05), 0.05, (Livery.darkTrim, .dark), bias: 2)
        m.box(V3(x + 0.32, s * (hw + 0.3), z - 0.25), V3(0.08, 0.14, 0.42), (Livery.darkTrim, .dark), bias: 2)
    }

    static func roofPod(_ m: inout MeshBuilder, x0: Double, x1: Double, width: Double, top: Double, height: Double) {
        let p = profile(width, top - 0.03, top + height, 0.1)
        m.loft(x0, p, x1, p, bodyPaints((Livery.grey, .paint), roof: (Livery.lightGrey, .paint), under: (Livery.grey, .paint)),
               bias: 3)
    }

    // MARK: Buses

    struct RoadSection {
        var center: Double
        var length: Double
        var front = false
        var rear = false
        var jointFront = false
        var jointRear = false
        var doors: [(Double, Double)] = []
        var axles: [Double] = []
        var pods: [(Double, Double)] = []
    }

    static func road(_ m: inout MeshBuilder, _ sec: RoadSection, width w: Double = 2.55, height zt: Double = 3.2,
                     body: RGB = Livery.hslBlue) {
        let zb = 0.34, hw = w / 2
        let xc = sec.center
        let x0 = xc - sec.length / 2, x1 = xc + sec.length / 2
        m.newGroup(V3(xc, 0, zt / 2))
        let paints = bodyPaints((body, .paint), roof: (body, .paint), under: (Livery.under, .dark))
        let p = profile(w, zb, zt, 0.32)
        let nf = sec.front ? 0.4 : 0, nr = sec.rear ? 0.3 : 0
        m.loft(x0 + nr, p, x1 - nf, p, paints)
        if sec.front {
            // Rounded front with a big windscreen, destination display, lights and mirrors.
            m.loft(x1 - nf, p, x1, profile(w - 0.16, zb + 0.06, zt - 0.08, 0.45), paints, cap0: false)
            let fw = (w - 0.16) / 2
            m.end(x1, 1, y0: -fw + 0.12, y1: fw - 0.12, z0: 1.0, z1: zt - 0.5, (Livery.glass, .glass))
            m.end(x1, 1, y0: -0.85, y1: 0.85, z0: zt - 0.44, z1: zt - 0.2, (RGB(0x101010), .dark))
            m.end(x1, 1, y0: -0.7, y1: 0.4, z0: zt - 0.38, z1: zt - 0.26, (Livery.led, .light), bias: 2)
            m.end(x1, 1, y0: -fw + 0.08, y1: fw - 0.08, z0: zb + 0.02, z1: zb + 0.3, (Livery.darkTrim, .dark))
            for s in [1.0, -1.0] {
                m.end(x1, 1, y0: s * (fw - 0.5), y1: s * (fw - 0.12), z0: 0.72, z1: 0.86, (Livery.headlight, .light), bias: 2)
                mirror(&m, x: x1 - 0.1, s, hw, z: zt - 0.45)
                m.side(s, hw, x1 - nf - 1.05, x1 - nf - 0.05, 1.15, zt - 0.45, (Livery.glass, .glass))
            }
        }
        if sec.rear {
            m.loft(x0, profile(w - 0.1, zb + 0.04, zt - 0.05, 0.4), x0 + nr, p, paints, cap1: false)
            let rw = (w - 0.1) / 2
            m.end(x0, -1, y0: -0.8, y1: 0.8, z0: 1.9, z1: zt - 0.5, (Livery.glass, .glass))
            for s in [1.0, -1.0] {
                m.end(x0, -1, y0: s * (rw - 0.3), y1: s * (rw - 0.08), z0: 0.7, z1: 1.5, (Livery.taillight, .light), bias: 2)
            }
            m.end(x0, -1, y0: -rw + 0.08, y1: rw - 0.08, z0: zb + 0.02, z1: zb + 0.28, (Livery.darkTrim, .dark))
        }
        if sec.jointFront { m.end(x1, 1, y0: -hw + 0.1, y1: hw - 0.1, z0: zb, z1: zt - 0.1, (Livery.under, .dark)) }
        if sec.jointRear { m.end(x0, -1, y0: -hw + 0.1, y1: hw - 0.1, z0: zb, z1: zt - 0.1, (Livery.under, .dark)) }

        let wx0 = x0 + nr + 0.35
        let wx1 = x1 - nf - (sec.front ? 1.2 : 0.3)
        for s in [1.0, -1.0] {
            m.side(s, hw, wx0 - 0.06, wx1 + 0.06, 1.12, zt - 0.38, (Livery.glazingFrame, .dark), bias: 0.9, lift: 0.008)
            panes(&m, s, hw, wx0, wx1, 1.2, zt - 0.45)
            m.side(s, hw, x0 + nr, x1 - nf, zb, zb + 0.16, (Livery.blueDark, .paint))
            for ax in sec.axles {
                wheelArch(&m, s, hw, x: xc + ax, zc: 0.5, r: 0.66)
                m.wheel(x: xc + ax, y: s * (hw - 0.2), r: 0.5, width: 0.32)
            }
        }
        for (a, b) in sec.doors {
            door(&m, 1, hw, xc + a, xc + b, zb + 0.06, zt - 0.38, frame: Livery.blueDark)
        }
        for (a, b) in sec.pods {
            roofPod(&m, x0: xc + a, x1: xc + b, width: 1.7, top: zt, height: 0.32)
        }
    }

    static func bus() -> VehicleModel {
        var m = MeshBuilder()
        road(&m, RoadSection(center: 0, length: 12.2, front: true, rear: true,
                             doors: [(4.5, 5.6), (-0.2, 1.05), (-4.65, -3.45)], axles: [3.4, -2.75],
                             pods: [(-0.2, 2.2), (-5.0, -2.6)]))
        return m.model(length: 12.2, width: 2.55)
    }

    /// Articulated trunk-line bus, 18.7 m, with bellows.
    static func trunkBus() -> VehicleModel {
        var m = MeshBuilder()
        road(&m, RoadSection(center: 4.0, length: 10.6, front: true, jointRear: true,
                             doors: [(4.5, 5.6), (-0.6, 0.65)], axles: [3.35, -2.55], pods: [(-1.5, 1.5)]))
        bellows(&m, from: -1.25, to: -0.8, width: 2.55, zb: 0.5, zt: 3.0)
        road(&m, RoadSection(center: -4.85, length: 7.3, rear: true, jointFront: true,
                             doors: [(0.3, 1.55)], axles: [-0.9], pods: [(-2.5, 0.0)]))
        return m.model(length: 18.7, width: 2.55)
    }

    static func bellows(_ m: inout MeshBuilder, from xa: Double, to xb: Double, width: Double, zb: Double, zt: Double) {
        m.newGroup(V3((xa + xb) / 2, 0, zt / 2))
        let ribs = 6
        let step = (xb - xa) / Double(ribs)
        for k in 0..<ribs {
            let c = k % 2 == 0 ? Livery.darkTrim : RGB(0x3A3F45)
            m.box(V3(xa + step * (Double(k) + 0.5), 0, (zb + zt) / 2),
                  V3(step, width - 0.2 - 0.08 * Double(k % 2), zt - zb), (c, .dark))
        }
    }

    // MARK: Rail vehicles

    struct NoseStep { var dx, w, zb, zt, r: Double; var glass: Bool }

    struct Nose {
        var steps: [NoseStep]
        var color: RGB
        var screen: (Double, Double)? = nil
        var display: Double? = nil
        var lights: Double? = nil
        var length: Double { steps.reduce(0) { $0 + $1.dx } }
    }

    struct RailLivery {
        var body: RGB
        var roof: RGB = Livery.grey
        var door: RGB
        var upper: (RGB, Double, Double)? = nil
        var lower: (RGB, Double, Double)? = nil
    }

    struct RailCar {
        var center: Double
        var length: Double
        var width: Double
        var height: Double
        var floor: Double
        var front: Nose? = nil
        var rear: Nose? = nil
        var doors: [Double] = []
        var doorWidth = 1.3
        var doorSides: [Double] = [1]
        var bogies: [Double] = []
        var wheelRadius = 0.4
        var pantograph: Double? = nil
        var roofBoxes: [(Double, Double, Double, Double)] = []
        var windows: (Double, Double) = (1.6, 2.8)
        var panePitch = 1.6
        var skirt: Double? = nil
    }

    static func railCar(_ m: inout MeshBuilder, _ car: RailCar, _ liv: RailLivery) {
        let w = car.width, h = car.height, zb = car.floor, hw = w / 2, xc = car.center
        let x0 = xc - car.length / 2, x1 = xc + car.length / 2
        m.newGroup(V3(xc, 0, h / 2))
        let p = profile(w, zb, h, 0.38, tw: w - 0.1)
        let fx = x1 - (car.front?.length ?? 0)
        let rx = x0 + (car.rear?.length ?? 0)
        m.loft(rx, p, fx, p, bodyPaints((liv.body, .paint), roof: (liv.roof, .paint), under: (Livery.under, .dark),
                                        shoulder: (liv.body, .paint)),
               cap0: car.rear == nil, cap1: car.front == nil)

        for (nose, sgn) in [(car.front, 1.0), (car.rear, -1.0)] {
            guard let nose else { continue }
            var prev = p
            var xPrev = sgn > 0 ? fx : rx
            for (k, st) in nose.steps.enumerated() {
                let q = profile(st.w, st.zb, st.zt, st.r, tw: st.w - 0.1)
                let x2 = xPrev + sgn * st.dx
                let paints = bodyPaints((nose.color, .paint),
                                        roof: st.glass ? (Livery.glass, .glass) : (liv.roof, .paint),
                                        under: (Livery.under, .dark))
                let last = k == nose.steps.count - 1
                if sgn > 0 {
                    m.loft(xPrev, prev, x2, q, paints, cap0: false, cap1: last)
                } else {
                    m.loft(x2, q, xPrev, prev, paints, cap0: last, cap1: false)
                }
                prev = q
                xPrev = x2
            }
            let tip = nose.steps[nose.steps.count - 1]
            let fw = (tip.w - 0.1) / 2
            if let screen = nose.screen {
                m.end(xPrev, sgn, y0: -fw + 0.12, y1: fw - 0.12, z0: screen.0, z1: screen.1, (Livery.glass, .glass))
            }
            if let z0 = nose.display {
                m.end(xPrev, sgn, y0: -0.75, y1: 0.75, z0: z0, z1: z0 + 0.22, (RGB(0x101010), .dark), bias: 2)
                m.end(xPrev, sgn, y0: -0.62, y1: 0.45, z0: z0 + 0.05, z1: z0 + 0.17, (Livery.led, .light), bias: 3)
            }
            let lz = nose.lights ?? tip.zb + 0.35
            for s in [1.0, -1.0] {
                m.end(xPrev, sgn, y0: min(s * (fw - 0.45), s * (fw - 0.1)), y1: max(s * (fw - 0.45), s * (fw - 0.1)),
                      z0: lz, z1: lz + 0.16, (sgn > 0 ? Livery.headlight : Livery.taillight, .light), bias: 2)
            }
            m.end(xPrev, sgn, y0: -fw + 0.05, y1: fw - 0.05, z0: tip.zb, z1: tip.zb + 0.18, (Livery.darkTrim, .dark), bias: 1.5)
        }
        // Gangway ends.
        if car.front == nil { m.end(x1, 1, y0: -0.7, y1: 0.7, z0: zb + 0.1, z1: h - 0.3, (Livery.under, .dark)) }
        if car.rear == nil { m.end(x0, -1, y0: -0.7, y1: 0.7, z0: zb + 0.1, z1: h - 0.3, (Livery.under, .dark)) }

        for s in [1.0, -1.0] {
            for band in [liv.lower, liv.upper].compactMap({ $0 }) {
                m.side(s, hw, rx, fx, band.1, band.2, (band.0, .paint), bias: 0.8)
            }
            m.side(s, hw, rx + 0.3, fx - 0.3, car.windows.0 - 0.08, car.windows.1 + 0.08,
                   (Livery.glazingFrame, .dark), bias: 0.9, lift: 0.008)
            panes(&m, s, hw, rx + 0.4, fx - 0.4, car.windows.0, car.windows.1, pitch: car.panePitch)
            if car.doorSides.contains(s) {
                for d in car.doors {
                    door(&m, s, hw, xc + d - car.doorWidth / 2, xc + d + car.doorWidth / 2,
                         zb + 0.08, car.windows.1 + 0.12, frame: liv.door)
                }
            }
            if let skirt = car.skirt {
                m.side(s, hw, rx, fx, zb, zb + skirt, (Livery.under, .dark), bias: 1.4, lift: 0.004)
            }
        }
        for b in car.bogies { bogie(&m, x: xc + b, hw: hw, r: car.wheelRadius) }
        if let x = car.pantograph { pantograph(&m, x: xc + x, roof: h) }
        for (a, b, bw, bh) in car.roofBoxes { roofPod(&m, x0: xc + a, x1: xc + b, width: bw, top: h, height: bh) }
    }

    static func bogie(_ m: inout MeshBuilder, x: Double, hw: Double, r: Double) {
        let fz = r + 0.15
        m.box(V3(x, 0, fz), V3(2.6, hw * 2 - 0.5, 0.45), (Livery.under, .dark), bias: -2)
        for s in [1.0, -1.0] {
            m.side(s, hw - 0.28, x - 1.3, x + 1.3, fz - 0.22, fz + 0.22, (RGB(0x2E3236), .dark), bias: 1.3)
            for dx in [-0.9, 0.9] { m.wheel(x: x + dx, y: s * (hw - 0.3), r: r, width: 0.14) }
        }
    }

    static func pantograph(_ m: inout MeshBuilder, x: Double, roof zt: Double, raised: Double = 1.25) {
        m.box(V3(x, 0, zt + 0.08), V3(1.4, 1.1, 0.16), (Livery.darkTrim, .dark), bias: 3)
        for y in [-0.4, 0.4] {
            m.box(V3(x - 0.5, y, zt + 0.2), V3(0.1, 0.1, 0.2), (Livery.insulator, .paint), bias: 3.1)
        }
        let knee = V3(x - 0.9, 0, zt + 0.25 + raised * 0.55)
        let head = V3(x + 0.1, 0, zt + 0.25 + raised)
        m.beam(V3(x + 0.4, 0, zt + 0.2), knee, 0.07, (Livery.grey, .metal), bias: 3.2)
        m.beam(knee, head, 0.06, (Livery.grey, .metal), bias: 3.3)
        m.box(head, V3(0.12, 1.7, 0.06), (Livery.darkTrim, .dark), bias: 3.4)
    }

    static func joint(_ m: inout MeshBuilder, x: Double, width: Double, floor: Double, height: Double, gap: Double) {
        m.newGroup(V3(x, 0, height / 2))
        m.box(V3(x, 0, (floor + height - 0.15) / 2), V3(gap, width - 0.45, height - 0.15 - floor), (Livery.darkTrim, .dark))
    }

    /// Transtech Artic (trams) and Artic XL (Jokeri light rail): three low-floor modules.
    static func artic(modules: [Double], width w: Double, bidirectional: Bool) -> VehicleModel {
        var m = MeshBuilder()
        let h = 3.55, zb = 0.32, gap = 0.4
        let liv = RailLivery(body: Livery.tramGreen, door: Livery.tramGreen, upper: (Livery.white, 2.72, 3.15))
        let cab = Nose(steps: [NoseStep(dx: 0.55, w: w - 0.1, zb: 0.34, zt: 3.05, r: 0.55, glass: true),
                               NoseStep(dx: 0.45, w: w - 0.3, zb: 0.36, zt: 2.55, r: 0.45, glass: false)],
                       color: Livery.tramGreen, screen: (1.25, 2.5), display: 2.25, lights: 0.75)
        let back = Nose(steps: [NoseStep(dx: 0.5, w: w - 0.15, zb: 0.34, zt: 3.2, r: 0.5, glass: false)],
                        color: Livery.tramGreen, screen: (1.6, 2.6), lights: 0.75)
        let total = modules.reduce(0, +) + gap * Double(modules.count - 1)
        var x = total / 2
        for (i, len) in modules.enumerated() {
            let xc = x - len / 2
            let first = i == 0, last = i == modules.count - 1
            let doors: [Double] = first ? [len * 0.17, -len * 0.23] : (last ? [len * 0.25, -len * 0.21] : [0])
            let pods: [(Double, Double, Double, Double)] =
                first ? [(-len * 0.37, -len * 0.05, 1.8, 0.35)] : (last ? [(len * 0.05, len * 0.37, 1.8, 0.35)] : [])
            railCar(&m, RailCar(center: xc, length: len, width: w, height: h, floor: zb,
                                front: first ? cab : nil,
                                rear: last ? (bidirectional ? cab : back) : nil,
                                doors: doors, doorSides: bidirectional ? [1, -1] : [1],
                                bogies: first ? [0.2] : (last ? [-0.2] : []), wheelRadius: 0.33,
                                pantograph: (!first && !last) ? 0 : nil, roofBoxes: pods,
                                windows: (1.15, 2.6), panePitch: 1.5, skirt: 0.25), liv)
            if !last { joint(&m, x: x - len - gap / 2, width: w, floor: zb, height: h, gap: gap) }
            x -= len + gap
        }
        return m.model(length: total, width: w)
    }

    /// Škoda M300 metro: four cars, about 90 m.
    static func metro() -> VehicleModel {
        var m = MeshBuilder()
        let w = 3.2, h = 3.75, zb = 0.95, c = 22.2, gap = 0.5
        let liv = RailLivery(body: Livery.metroOrange, roof: RGB(0xC5CBD1), door: RGB(0x9AA3AD),
                             lower: (Livery.darkTrim, 0.95, 1.12))
        let nose = Nose(steps: [NoseStep(dx: 0.9, w: 3.05, zb: 0.97, zt: 3.3, r: 0.6, glass: true),
                                NoseStep(dx: 0.7, w: 2.75, zb: 1.0, zt: 2.35, r: 0.4, glass: false)],
                        color: Livery.metroOrange, screen: (1.75, 2.3), display: 2.05, lights: 1.35)
        let total = 4 * c + 3 * gap
        for i in 0..<4 {
            let x = total / 2 - c / 2 - Double(i) * (c + gap)
            railCar(&m, RailCar(center: x, length: c, width: w, height: h, floor: zb,
                                front: i == 0 ? nose : nil, rear: i == 3 ? nose : nil,
                                doors: [-6.6, 0, 6.6], doorWidth: 1.4, doorSides: [1, -1],
                                bogies: [-7.8, 7.8], wheelRadius: 0.4,
                                roofBoxes: [(-2.5, 2.5, 2.0, 0.25)], windows: (1.6, 2.85), panePitch: 1.9), liv)
            if i < 3 { joint(&m, x: x - c / 2 - gap / 2, width: w, floor: zb, height: h, gap: gap) }
        }
        return m.model(length: total, width: w)
    }

    /// Stadler FLIRT (Sm5) commuter train: four cars on shared (Jacobs) bogies, 75 m.
    static func train() -> VehicleModel {
        var m = MeshBuilder()
        let w = 3.2, h = 4.15, zb = 0.95, c = 18.4, gap = 0.4
        let liv = RailLivery(body: Livery.white, door: Livery.trainPurple, lower: (Livery.trainPurple, 1.05, 1.3))
        let nose = Nose(steps: [NoseStep(dx: 1.0, w: 3.15, zb: 0.97, zt: 3.95, r: 0.7, glass: false),
                                NoseStep(dx: 1.2, w: 2.95, zb: 1.0, zt: 3.2, r: 0.75, glass: true),
                                NoseStep(dx: 1.0, w: 2.4, zb: 1.05, zt: 2.0, r: 0.55, glass: false)],
                        color: Livery.white, lights: 1.35)
        let total = 4 * c + 3 * gap
        for i in 0..<4 {
            let x = total / 2 - c / 2 - Double(i) * (c + gap)
            var bogies: [Double] = []
            if i == 0 { bogies.append(c / 2 - 3.5) }
            if i == 3 { bogies.append(-c / 2 + 3.5) }
            railCar(&m, RailCar(center: x, length: c, width: w, height: h, floor: zb,
                                front: i == 0 ? nose : nil, rear: i == 3 ? nose : nil,
                                doors: [-c / 4, c / 4], doorSides: [1, -1], bogies: bogies, wheelRadius: 0.42,
                                pantograph: i == 1 ? -3.0 : nil,
                                roofBoxes: (i == 0 || i == 3) ? [(-2.0, 2.0, 2.1, 0.35)] : [],
                                windows: (1.75, 3.05), panePitch: 1.8), liv)
            if i < 3 {
                let jx = x - c / 2 - gap / 2
                joint(&m, x: jx, width: w, floor: zb, height: h, gap: gap)
                bogie(&m, x: jx, hw: w / 2, r: 0.42)
            }
        }
        return m.model(length: total, width: w)
    }

    /// Suomenlinna-style ferry: dark hull with a pointed bow, white cabin, cyan roof.
    static func ferry() -> VehicleModel {
        var m = MeshBuilder()
        m.newGroup(V3(0, 0, 2))
        let hull: [YZ] = [(3.6, 0), (4.0, 1.8), (-4.0, 1.8), (-3.6, 0)]
        let bow: [YZ] = [(0.15, 0.4), (0.3, 2.1), (-0.3, 2.1), (-0.15, 0.4)]
        let hp: [Paint] = [(Livery.ferryHull, .paint), (Livery.white, .paint), (Livery.ferryHull, .paint),
                           (Livery.under, .dark), (Livery.ferryHull, .paint)]
        m.loft(-15, hull, 9, hull, hp, cap1: false)
        m.loft(9, hull, 15, bow, hp, cap0: false)
        let cabin = profile(7.0, 1.8, 3.9, 0.3)
        m.loft(-11, cabin, 5, cabin, bodyPaints((Livery.white, .paint), roof: (Livery.white, .paint),
                                                under: (Livery.under, .dark)), bias: 0.5)
        for s in [1.0, -1.0] { panes(&m, s, 3.5, -10.5, 4.5, 2.4, 3.3, pitch: 1.2) }
        m.end(5, 1, y0: -3.0, y1: 3.0, z0: 2.4, z1: 3.4, (Livery.glass, .glass), bias: 2)
        let bridge = profile(5.0, 3.85, 5.4, 0.25)
        m.loft(-1, bridge, 4, bridge, bodyPaints((Livery.white, .paint), roof: (Livery.ferryCyan, .paint),
                                                 under: (Livery.under, .dark)), bias: 3)
        m.end(4, 1, y0: -2.2, y1: 2.2, z0: 4.3, z1: 5.0, (Livery.glass, .glass), bias: 4)
        return m.model(length: 30, width: 8)
    }
}
#endif
