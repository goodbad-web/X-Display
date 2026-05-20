// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "X-display",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "XDisplayShared")
    ],
    targets: [
        .target(
            name: "CVirtualDisplay",
            dependencies: [],
            path: "Sources/CVirtualDisplay"
        ),
        .executableTarget(
            name: "X-display",
            dependencies: [
                "CVirtualDisplay",
                .product(name: "XDisplayShared", package: "XDisplayShared")
            ],
            path: "Sources/X-display"
        ),
        .testTarget(
            name: "X-displayTests",
            dependencies: ["X-display"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
