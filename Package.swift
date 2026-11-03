// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Imp",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpKit", targets: ["ImpKit"]),
        .library(name: "ImpDesign", targets: ["ImpDesign"]),
        .executable(name: "Imp", targets: ["Imp"]),
    ],
    targets: [
        // Pure logic: settings, the model client and agent loop, the shell tool, MCP, reactions. Unit-tested.
        .target(name: "ImpKit"),
        // The shared look: colours, corners, spacing, type, motion and the app's own controls (SwiftUI only).
        .target(name: "ImpDesign"),
        // The menu-bar app: AppKit panels, SwiftUI views and system services (hot keys, dictation).
        .executableTarget(name: "Imp", dependencies: ["ImpKit", "ImpDesign"]),
        .testTarget(name: "ImpKitTests", dependencies: ["ImpKit"]),
        .testTarget(name: "ImpDesignTests", dependencies: ["ImpDesign"]),
        // The app's own paths that need its models and views (crashes once seen in the field).
        .testTarget(name: "ImpTests", dependencies: ["Imp", "ImpKit"]),
    ]
)
