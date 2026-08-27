// swift-tools-version:5.10
import Foundation
import PackageDescription

// Absolute path to the repo-root `Vendor/libusb` directory, computed from this manifest's
// own location so the package builds correctly regardless of the working directory it is
// invoked from (Xcode workspace, `swift build` from this package dir, CI, etc.).
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let vendorLibDir = packageDir
    .deletingLastPathComponent() // Packages/
    .deletingLastPathComponent() // repo root
    .appendingPathComponent("Vendor/libusb/lib")
    .standardizedFileURL
    .path

let package = Package(
    name: "CLibusb",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CLibusb",
            targets: ["CLibusb"]
        ),
        .executable(
            name: "libusb-proof",
            targets: ["libusb-proof"]
        )
    ],
    targets: [
        // Thin system-library wrapper around the vendored static libusb (module map +
        // a copy of the public header — see Vendor/libusb/VERSION.md for provenance).
        // No libusb source is compiled here; linking against the vendored .a happens on
        // the consuming targets below via -L/-l flags, since a systemLibrary target
        // itself carries no linker settings.
        .systemLibrary(
            name: "CLibusb",
            path: "Sources/CLibusb"
        ),
        .executableTarget(
            name: "libusb-proof",
            dependencies: ["CLibusb"],
            path: "Sources/libusb-proof",
            linkerSettings: [
                .unsafeFlags(["-L\(vendorLibDir)", "-lusb-1.0"]),
                // libusb's Darwin backend (os/darwin_usb.c) talks to IOKit directly and
                // uses CoreFoundation + Security (for IOServiceAuthorize's entitlement
                // check) — these are required transitively, not just IOKit.
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security")
            ]
        )
    ]
)
