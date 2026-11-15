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
        .executableTarget(name: "Imp", dependencies: ["ImpKit", "ImpDesign"]),
        .testTarget(name: "ImpKitTests", dependencies: ["ImpKit"]),
        .testTarget(name: "ImpDesignTests", dependencies: ["ImpDesign"]),
        // The app's own paths that need its models and views (crashes once seen in the field).
        .testTarget(name: "ImpTests", dependencies: ["Imp", "ImpKit", "ImpDesign"]),
        // Reference images of the main screens and their key states (see docs/apps/testing.md).
        .testTarget(name: "ImpSnapshotTests", dependencies: [
            "Imp", "ImpKit", "ImpDesign",
            .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
        ], exclude: ["__Snapshots__"]),
    ]
)
