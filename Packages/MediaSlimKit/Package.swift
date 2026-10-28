// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaSlimKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MediaSlimCore", targets: ["MediaSlimCore"]),
        .library(name: "MediaSlimEngine", targets: ["MediaSlimEngine"]),
        .library(name: "MediaSlimLibrary", targets: ["MediaSlimLibrary"]),
        .library(name: "MediaSlimPipeline", targets: ["MediaSlimPipeline"]),
    ],
    targets: [
        // Pure Swift: models, policies, quality metrics and search. No Apple media frameworks.
        .target(name: "MediaSlimCore"),
        // On-device encoding: ImageIO (HEIC) and AVFoundation / VideoToolbox (HEVC).
        .target(name: "MediaSlimEngine", dependencies: ["MediaSlimCore"]),
        // PhotoKit access. Compiles to an empty module on platforms without PhotoKit for iOS.
        .target(name: "MediaSlimLibrary", dependencies: ["MediaSlimCore"]),
        // Orchestration: crash-safe journal, resource governor, processing coordinator.
        .target(name: "MediaSlimPipeline", dependencies: ["MediaSlimCore"]),

        .testTarget(name: "MediaSlimCoreTests", dependencies: ["MediaSlimCore"]),
        .testTarget(name: "MediaSlimEngineTests", dependencies: ["MediaSlimEngine", "MediaSlimCore"]),
        .testTarget(name: "MediaSlimPipelineTests", dependencies: ["MediaSlimPipeline", "MediaSlimCore"]),
    ]
)
