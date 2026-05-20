// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "X-Display-Client",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "X-Display-Client",
            targets: ["App"]
        )
    ],
    targets: [
        .target(
            name: "App",
            path: "Sources",
            resources: [
                .process("Shaders.metal")
            ]
        )
    ]
)
