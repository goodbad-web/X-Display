// swift-tools-version: 5.9
import PackageDescription

#if canImport(AppleProductTypes)
import AppleProductTypes

let package = Package(
    name: "X-Display-Client",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .iOSApplication(
            name: "X-Display-Client",
            targets: ["App"],
            bundleIdentifier: "com.goodbad-web.X-Display-Client",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .heart),
            accentColor: .presetColor(.indigo),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeLeft,
                .landscapeRight,
                .portraitUpsideDown
            ],
            capabilities: [
                .incomingNetworkConnections(),
                .outgoingNetworkConnections()
            ]
        )
    ],
    dependencies: [
        .package(path: "../XDisplayShared")
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "XDisplayShared", package: "XDisplayShared")
            ],
            path: "Sources",
            resources: [
                .process("Shaders.metal")
            ]
        )
    ]
)
#else
let package = Package(
    name: "X-Display-Client",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "X-Display-Client",
            targets: ["App"]
        )
    ],
    dependencies: [
        .package(path: "../XDisplayShared")
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [
                .product(name: "XDisplayShared", package: "XDisplayShared")
            ],
            path: "Sources",
            resources: [
                .process("Shaders.metal")
            ]
        )
    ]
)
#endif
