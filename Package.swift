// swift-tools-version: 6.0
// FluidAudio (the Parakeet engine) requires the Swift 6 toolchain, which
// the current macOS release runners carry.
import PackageDescription

let package = Package(
    name: "Lowkey",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parakeet TDT on the Apple Neural Engine: the primary dictation
        // engine. Sidesteps GPU contention and thermal throttling entirely.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "Lowkey",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Lowkey",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
