import XCTest
import ETAEngine
#if canImport(SwiftUI) && canImport(ImageIO)
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import HSLDesign

final class VehicleModelTests: XCTestCase {
    func testModelsAreWellFormed() {
        for mode in TransitMode.allCases {
            let model = VehicleModel.model(for: mode)
            XCTAssertGreaterThan(model.faces.count, 20, "\(mode)")
            for face in model.faces {
                XCTAssertGreaterThanOrEqual(face.points.count, 3)
                XCTAssertTrue(face.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
                XCTAssertEqual(Geo3.length(face.normal), 1, accuracy: 1e-6, "\(mode)")
                XCTAssertTrue(model.anchors.indices.contains(face.group), "\(mode)")
                // Everything but mirrors and pantograph heads stays near the footprint.
                for p in face.points {
                    XCTAssertLessThanOrEqual(abs(p.x), model.length / 2 + 0.6, "\(mode)")
                    XCTAssertLessThanOrEqual(abs(p.y), model.width / 2 + 0.6, "\(mode)")
                }
            }
        }
    }

    /// Renders every vehicle from a few camera angles into PNGs (uploaded by CI as an artifact).
    @MainActor
    func testRenderPreviewSheets() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEHICLE_PREVIEW_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let modes: [(TransitMode, Double)] = [(.bus, 14), (.trunkBus, 11), (.tram, 8), (.lightRail, 7),
                                              (.metro, 3.2), (.rail, 3.8), (.ferry, 8)]
        let views: [(Double, Double)] = [(240, 55), (60, 50), (300, 30), (150, 70), (90, 0)]
        let sheet = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(modes.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 0) {
                    ForEach(Array(views.enumerated()), id: \.offset) { _, v in
                        VehicleSpriteView(mode: item.0, relativeHeading: v.0, pitch: v.1, pointsPerMeter: item.1)
                    }
                }
            }
        }
        .background(Color(red: 0.24, green: 0.26, blue: 0.29))
        try write(sheet, to: dir.appendingPathComponent("vehicles.png"))

        for (mode, ppm) in modes {
            let close = HStack(spacing: 0) {
                VehicleSpriteView(mode: mode, relativeHeading: 235, pitch: 55, pointsPerMeter: ppm * 2.5)
                VehicleSpriteView(mode: mode, relativeHeading: 125, pitch: 40, pointsPerMeter: ppm * 2.5)
            }
            .background(Color(red: 0.24, green: 0.26, blue: 0.29))
            try write(close, to: dir.appendingPathComponent("vehicle-\(mode.rawValue).png"))
        }
    }

    @MainActor
    private func write<V: View>(_ view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { throw XCTSkip("ImageRenderer unavailable") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return XCTFail("can't write \(url.path)")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
#endif
