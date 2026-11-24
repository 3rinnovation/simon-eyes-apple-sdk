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
            url: "https://github.com/3rinnovation/simon-eyes-apple-sdk/releases/download/0.1.0/ThreeRSipHosted.xcframework.zip",
            checksum: "0509897a501878891eda80661cf4b5df57bc8f5d9be28f9ee5a1b7343347a16a"
        ),
        .target(
            name: "ThreeRSip",
            dependencies: ["CThreeRSipHosted"],
            // Apple's privacy manifest: the required-reason APIs the library uses.
            resources: [.copy("PrivacyInfo.xcprivacy")],
            linkerSettings: [
                // What the static library needs from the system: Core Motion on iOS.
                .linkedFramework("CoreMotion", .when(platforms: [.iOS])),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
