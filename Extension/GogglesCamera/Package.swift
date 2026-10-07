// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GogglesCameraExtension",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../Packages/GogglesXPC"),
        .package(path: "../../Packages/GogglesH264")
    ],
    targets: [
        .executableTarget(
            name: "GogglesCameraExtension",
            dependencies: [
                .product(name: "GogglesXPC", package: "GogglesXPC"),
                .product(name: "GogglesH264", package: "GogglesH264")
            ]
        )
    ]
)
