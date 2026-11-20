// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sensorium",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CSensors",
            path: "Sources/CSensors",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation"), .linkedFramework("CoreAudio"),
                             .linkedFramework("AudioToolbox"), .linkedFramework("CoreGraphics"), .linkedFramework("ApplicationServices")]
        ),
        .target(
            name: "SensoriumCore",
            dependencies: ["CSensors"],
            path: "Sources/SensoriumCore",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "SensoriumHelper",
            dependencies: ["CSensors", "SensoriumCore"],
            path: "Sources/SensoriumHelper",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "Sensorium",
            dependencies: ["CSensors", "SensoriumCore"],
            path: "Sources/Sensorium",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("LocalAuthentication")]
        ),
    ]
)
