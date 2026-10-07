// swift-tools-version:5.10
import PackageDescription

// H.264 helpers shared by the app and the camera extension: Annex-B parameter-set
// splitting, format-description cache, Annex-B to AVCC conversion.
let package = Package(
    name: "GogglesH264",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GogglesH264", targets: ["GogglesH264"])
    ],
    targets: [
        .target(name: "GogglesH264")
    ]
)
