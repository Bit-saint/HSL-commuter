// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CommuterKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ETAEngine", targets: ["ETAEngine"]),
        .library(name: "HSLKit", targets: ["HSLKit"]),
        .library(name: "HSLDesign", targets: ["HSLDesign"]),
    ],
    targets: [
        // Pure Swift, Foundation only. Builds and tests on Linux too.
        .target(name: "ETAEngine"),
        // Network clients: Digitransit GraphQL, HSL HFP (MQTT), Digitraffic rail.
        .target(name: "HSLKit", dependencies: ["ETAEngine"]),
        // SwiftUI styling, line badges and the pseudo-3D vehicle renderer.
        .target(name: "HSLDesign", dependencies: ["ETAEngine"]),
        .testTarget(name: "ETAEngineTests", dependencies: ["ETAEngine"]),
        .testTarget(name: "HSLKitTests", dependencies: ["HSLKit"]),
        .testTarget(name: "HSLDesignTests", dependencies: ["HSLDesign", "ETAEngine"]),
    ],
    swiftLanguageModes: [.v5]
)
