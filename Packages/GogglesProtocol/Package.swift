// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GogglesProtocol",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GogglesProtocol",
            targets: ["GogglesProtocol"]
        )
    ],
    targets: [
        .target(
            name: "GogglesProtocol",
            dependencies: []
        ),
        .testTarget(
            name: "GogglesProtocolTests",
            dependencies: ["GogglesProtocol"]
        )
    ]
)
