// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GogglesUSB",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GogglesUSB",
            targets: ["GogglesUSB"]
        )
    ],
    targets: [
        .target(
            name: "GogglesUSB",
            dependencies: []
        ),
        .testTarget(
            name: "GogglesUSBTests",
            dependencies: ["GogglesUSB"]
        )
    ]
)
