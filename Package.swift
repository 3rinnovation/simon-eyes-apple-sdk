// swift-tools-version: 6.0
// Simon Eyes Apple SDK: ThreeRSip, the Swift API over the Simon Eyes sensing core, which ships as a
// binary library. Needs Xcode 16 or later.
import PackageDescription

let package = Package(
    name: "ThreeRSip",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ThreeRSip", targets: ["ThreeRSip"]),
    ],
    targets: [
        .binaryTarget(
            name: "CThreeRSipHosted",
            url: "https://github.com/3rinnovation/simon-eyes-apple-sdk/releases/download/0.1.0-rc.1/ThreeRSipHosted.xcframework.zip",
            checksum: "9c3463c3105fe2126966c1200e981742c80998bb2428427a45f011c9d7bf14e5"
        ),
        .target(
            name: "ThreeRSip",
            dependencies: ["CThreeRSipHosted"],
            linkerSettings: [
                // What the static library needs from the system: Core Motion on iOS.
                .linkedFramework("CoreMotion", .when(platforms: [.iOS])),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
