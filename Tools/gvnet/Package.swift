// swift-tools-version:5.10
import PackageDescription

// gvnet: a small, dependency-free client for the goggles' UDP 9003 liveview protocol.
// Builds on macOS and Linux (Windows: untested). It does not touch USB: it talks to the goggles
// over an ordinary network interface, which is what the kernel's RNDIS driver (Linux) or the
// goggles' Wi-Fi access point provides.
let package = Package(
    name: "gvnet",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "gvnet", targets: ["gvnet"]),
        .library(name: "GVNetCore", targets: ["GVNetCore"])
    ],
    dependencies: [
        .package(path: "../../Packages/GogglesProtocol")
    ],
    targets: [
        .target(name: "GVNetCore", dependencies: [.product(name: "GogglesProtocol", package: "GogglesProtocol")]),
        .executableTarget(name: "gvnet", dependencies: ["GVNetCore"]),
        .testTarget(name: "GVNetCoreTests", dependencies: ["GVNetCore", .product(name: "GogglesProtocol", package: "GogglesProtocol")])
    ]
)
