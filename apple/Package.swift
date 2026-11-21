// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Imp",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "ImpKit", targets: ["ImpKit"]),
        .library(name: "ImpDesign", targets: ["ImpDesign"]),
        .executable(name: "Imp", targets: ["Imp"]),
    ],
    dependencies: [
        // Reference images of the main screens (tests only).
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.7"),
        // The node canvas of the Devices screen (MIT). A 0.x package by one maintainer: pinned to its minor version.
        .package(url: "https://github.com/aaurelions/SwiftFlow.git", .upToNextMinor(from: "0.3.1")),
    ],
    targets: [
        // The portable core (Rust, engine/ in the repository), built by `scripts/apple.sh core`: the static
        // library and the Swift bindings generated from it.
        .binaryTarget(name: "ImpCoreFFI", path: "Frameworks/ImpCoreFFI.xcframework"),
        .target(name: "ImpCore", dependencies: ["ImpCoreFFI"]),
        // Apple-side logic: settings, the model client and agent loop, the shell tool, MCP, reactions. Unit-tested.
        .target(name: "ImpKit", dependencies: ["ImpCore"]),
        // The shared look: colours, corners, spacing, type, motion and the app's own controls (SwiftUI only).
        .target(name: "ImpDesign"),
        // The menu-bar app: AppKit panels, SwiftUI views and system services (hot keys, dictation).
        .executableTarget(name: "Imp", dependencies: ["ImpKit", "ImpDesign", .product(name: "SwiftFlow", package: "SwiftFlow")]),
        .testTarget(name: "ImpKitTests", dependencies: ["ImpKit"]),
        .testTarget(name: "ImpDesignTests", dependencies: ["ImpDesign"], resources: [.copy("Fixtures")]),
        // Tests of the app's own code that needs its models and views, including regressions for crashes seen in the field.
        .testTarget(name: "ImpTests", dependencies: ["Imp", "ImpKit", "ImpDesign", .product(name: "SwiftFlow", package: "SwiftFlow")]),
        // Reference images of the main screens and their key states (see docs/apps/testing.md).
        .testTarget(name: "ImpSnapshotTests", dependencies: [
            "Imp", "ImpKit", "ImpDesign",
            .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
        ], exclude: ["__Snapshots__"]),
    ]
)
