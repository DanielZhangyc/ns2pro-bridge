// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NS2ProBridge",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "NS2ProBridge", targets: ["BridgeApp"])],
    targets: [
        .target(name: "NS2Transport", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("CoreBluetooth"), .linkedFramework("Foundation")]),
        .executableTarget(name: "BridgeApp", dependencies: ["NS2Transport"],
                          linkerSettings: [.linkedFramework("CoreHID"), .linkedFramework("AppKit")]),
        .testTarget(name: "BridgeAppTests", dependencies: ["BridgeApp", "NS2Transport"])
    ]
)
