// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "UsageBarCore",
            targets: ["UsageBarCore"]
        ),
        .executable(
            name: "UsageBarApp",
            targets: ["UsageBarApp"]
        ),
    ],
    targets: [
        .target(
            name: "UsageBarCore"
        ),
        .executableTarget(
            name: "UsageBarApp",
            dependencies: ["UsageBarCore"]
        ),
    ]
)
