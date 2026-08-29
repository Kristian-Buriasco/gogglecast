// swift-tools-version:5.10
import PackageDescription

// ─────────────────────────────────────────────────────────────────────────
// Task 2.2: `GogglesHelper`, the daemon binary that wraps the Phase 1
// protocol core (`GogglesProtocol`/`GogglesUSB`) and the shared driving
// loop extracted from `gvcli` (`GogglesPipeline`, see
// `Tools/gvcli/Package.swift`) behind two modes:
//
//   sudo ./GogglesHelper --stdout   -- plain root-run CLI, Annex-B to
//                                       stdout, no XPC (design §8.4's
//                                       staging: debug the pipeline before
//                                       the packaging/XPC layer).
//   sudo ./GogglesHelper --xpc      -- NSXPCListener on the Mach service
//                                       `com.kburiasco.gogglesview.helper`,
//                                       serving GogglesHelperProtocol/
//                                       GogglesClientProtocol (GogglesXPC,
//                                       task 2.1) to N fanned-out
//                                       subscribers.
//
// Depends on `GogglesPipeline` (the gvcli-extracted library product) via a
// path dependency on `Tools/gvcli`, exactly as the task 2.2 brief's option
// (a) describes -- not a second package, and not a duplicated copy of
// Pipeline.swift/FrameBoundaryAckTracker.swift.
// ─────────────────────────────────────────────────────────────────────────

let package = Package(
    name: "GogglesHelper",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../Packages/GogglesProtocol"),
        .package(path: "../../Packages/GogglesUSB"),
        .package(path: "../../Packages/GogglesXPC"),
        .package(path: "../../Tools/gvcli")
    ],
    targets: [
        .executableTarget(
            name: "GogglesHelper",
            dependencies: [
                .product(name: "GogglesProtocol", package: "GogglesProtocol"),
                .product(name: "GogglesUSB", package: "GogglesUSB"),
                .product(name: "GogglesXPC", package: "GogglesXPC"),
                .product(name: "GogglesPipeline", package: "gvcli")
            ]
        ),
        // MEDIUM 5 fix (multi-device picker review round 2): this package
        // previously had no test target at all -- the riskiest, most
        // multi-device-changed file (`HelperService.swift`, ~730 lines) had
        // zero coverage despite the spec explicitly saying its
        // device-identity/fan-out-scoping logic "can be tested with
        // MockTransportTests" and the task brief asking for tests here.
        // `@testable import GogglesHelper` works against an
        // `executableTarget` from a same-package test target on this
        // toolchain (SwiftPM 5.5+) -- no separate library target needed
        // just to make this testable.
        .testTarget(
            name: "GogglesHelperTests",
            dependencies: [
                "GogglesHelper",
                .product(name: "GogglesXPC", package: "GogglesXPC")
            ]
        )
    ]
)
