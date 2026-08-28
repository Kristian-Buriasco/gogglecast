// swift-tools-version:5.10
import Foundation
import PackageDescription

// Same computation as CLibusb/Package.swift: resolve the vendored static
// libusb's lib directory relative to this manifest's own location, so the
// package builds regardless of invocation directory.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let vendorLibDir = packageDir
    .deletingLastPathComponent() // Packages/
    .deletingLastPathComponent() // repo root
    .appendingPathComponent("Vendor/libusb/lib")
    .standardizedFileURL
    .path

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
    dependencies: [
        .package(path: "../CLibusb"),
        .package(path: "../GogglesProtocol")
    ],
    targets: [
        .target(
            name: "GogglesUSB",
            dependencies: [
                .product(name: "CLibusb", package: "CLibusb"),
                .product(name: "GogglesProtocol", package: "GogglesProtocol")
            ],
            linkerSettings: [
                // GogglesUSB is the layer that actually links and calls into
                // the vendored static libusb (task 1.5) -- unlike
                // GogglesProtocol, which is deliberately kept libusb-free.
                // Mirrors CLibusb's own libusb-proof target's linker
                // settings (Packages/CLibusb/Package.swift), since libusb's
                // Darwin backend needs IOKit/CoreFoundation/Security
                // transitively, not just IOKit.
                .unsafeFlags(["-L\(vendorLibDir)", "-lusb-1.0"]),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "GogglesUSBTests",
            dependencies: [
                "GogglesUSB",
                .product(name: "GogglesProtocol", package: "GogglesProtocol")
            ]
        )
    ]
)
