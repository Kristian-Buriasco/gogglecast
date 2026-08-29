// swift-tools-version:5.10
import PackageDescription

// ─────────────────────────────────────────────────────────────────────────
// Task 4.1: THROWAWAY spike package. Not the real Phase-4 camera extension
// (that's Task 4.2+) -- this builds the minimal `CMIOExtensionProvider`/
// `Device`/`Stream` skeleton needed to be installable at all, plus one
// `NSXPCConnection` attempt to the helper's Mach service and one logged
// `stats` callback. See `Sources/GogglesCameraExtension/main.swift`'s doc
// comment and `.superpowers/sdd/plan/task-4.1-brief.md` for the exact
// scope. Mirrors `Helper/GogglesHelper/Package.swift`'s path-dependency
// pattern for `GogglesXPC` -- same protocol/value types, no duplication.
// ─────────────────────────────────────────────────────────────────────────

let package = Package(
    name: "GogglesCameraExtension",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../Packages/GogglesXPC")
    ],
    targets: [
        .executableTarget(
            name: "GogglesCameraExtension",
            dependencies: [
                .product(name: "GogglesXPC", package: "GogglesXPC")
            ]
        )
    ]
)
