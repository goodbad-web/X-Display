// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "XDisplayShared",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "XDisplayShared",
            targets: ["XDisplayShared"]
        )
    ],
    targets: [
        .target(
            name: "XDisplayShared"
        ),
        .testTarget(
            name: "XDisplaySharedTests",
            dependencies: ["XDisplayShared"]
        ),
    ]
)
