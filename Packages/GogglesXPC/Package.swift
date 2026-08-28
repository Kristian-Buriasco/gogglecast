// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GogglesXPC",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GogglesXPC",
            targets: ["GogglesXPC"]
        )
    ],
    targets: [
        .target(
            name: "GogglesXPC",
            dependencies: []
        ),
        .testTarget(
            name: "GogglesXPCTests",
            dependencies: ["GogglesXPC"]
        )
    ]
)
