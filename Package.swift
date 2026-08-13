// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whisperly",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Whisperly",
            path: "Sources/Whisperly",
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
