// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Imp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Imp", targets: ["Imp"]),
    ],
    targets: [
        // Pure logic: settings, the model client and agent loop, the shell tool, MCP, reactions. Unit-tested.
        .target(name: "ImpKit"),
        // The menu-bar app: AppKit panels, SwiftUI views and system services (hot keys, dictation).
        .executableTarget(name: "Imp", dependencies: ["ImpKit"]),
        .testTarget(name: "ImpKitTests", dependencies: ["ImpKit"]),
    ]
)
