// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vocalis",
    platforms: [.macOS(.v13)],
    products: [
        // NOTE: macOS default FS is case-insensitive — do not name products
        // "Vocalis" and "vocalis" or they overwrite each other.
        .executable(name: "Vocalis", targets: ["VocalisApp"]),
        .executable(name: "vocalis-cli", targets: ["VocalisCLI"]),
        .library(name: "VocalisCore", targets: ["VocalisCore"]),
    ],
    targets: [
        .target(
            name: "VocalisCore",
            path: "Sources/VocalisCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "VocalisApp",
            dependencies: ["VocalisCore"],
            path: "Sources/VocalisApp"
        ),
        .executableTarget(
            name: "VocalisCLI",
            dependencies: ["VocalisCore"],
            path: "Sources/VocalisCLI"
        ),
    ]
)
