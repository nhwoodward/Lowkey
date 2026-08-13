// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lowkey",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lowkey",
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
