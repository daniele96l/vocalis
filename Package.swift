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
    dependencies: [
        // Local Whisper (Core ML). Pin 0.13.x — still tools-version 5.9 / macOS 13.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.13.1"),
    ],
    targets: [
        .target(
            name: "VocalisCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/VocalisCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreML"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit"),
                .linkedFramework("Speech"),
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
