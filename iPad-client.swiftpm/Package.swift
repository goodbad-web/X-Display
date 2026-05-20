// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "X-Display-Client",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .iOSApplication(
            name: "X-Display-Client",
            targets: ["App"],
            bundleIdentifier: "com.xdisplay.client",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            supportedInterfaceOrientations: [
                .landscapeRight,
                .landscapeLeft
            ],
            capabilities: [
                .incomingConnections(),
                .outgoingConnections()
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "App",
            path: "Sources"
        )
    ]
)
