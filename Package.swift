// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WispFlow",
    platforms: [.macOS(.v13)],
    products: [
        // NOTE: macOS default FS is case-insensitive — do not name products
        // "WispFlow" and "wispflow" or they overwrite each other.
        .executable(name: "WispFlow", targets: ["WispFlowApp"]),
        .executable(name: "wispflow-cli", targets: ["WispFlowCLI"]),
        .library(name: "WispFlowCore", targets: ["WispFlowCore"]),
    ],
    targets: [
        .target(
            name: "WispFlowCore",
            path: "Sources/WispFlowCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "WispFlowApp",
            dependencies: ["WispFlowCore"],
            path: "Sources/WispFlowApp"
        ),
        .executableTarget(
            name: "WispFlowCLI",
            dependencies: ["WispFlowCore"],
            path: "Sources/WispFlowCLI"
        ),
    ]
)
