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
            appIcon: .placeholder(icon: .screen),
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
    targets: [
        .executableTarget(
            name: "App",
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
#endif

