// swift-tools-version:5.10
import PackageDescription

// ─────────────────────────────────────────────────────────────────────────
// Task 1.7: `gvcli`, the Phase 1 exit-gate parity harness. Turns the
// `Tools/gvcli/` placeholder from task 0.1 into a real SPM executable
// target that wires together everything built in tasks 1.1-1.6
// (`GogglesProtocol`'s framing/wire-protocol/reassembler and
// `GogglesUSB`'s `RNDISTransport`) into a runnable CLI, matching
// `stream.py`'s conventions closely enough for design §9.2's parity
// comparison to be meaningful.
//
// Task 2.2: the driving-loop logic (handshake, reassembly-driven NAL
// emission, I-frame retry, per-frame-boundary ack) that used to live only
// inside the `gvcli` executable target is extracted into a library product,
// `GogglesPipeline`, so `Helper/GogglesHelper` (task 2.2's new daemon
// binary, which needs the exact same pipeline for both its `--stdout` and
// `--xpc` modes) can depend on it directly instead of a second copy
// drifting out of sync -- see `Sources/GogglesPipeline`'s doc comments.
// `gvcli` itself becomes a thin CLI wrapper (arg parsing, stderr text
// banners, subcommand dispatch) around that library, unchanged in
// behavior. `gvcliTests` (Task 1.7's `FrameBoundaryAckTrackerTests`, 3
// tests) moves to `GogglesPipelineTests` alongside the code it tests, with
// its `@testable import` target renamed accordingly -- same 3 tests,
// unchanged assertions.
// ─────────────────────────────────────────────────────────────────────────

let package = Package(
    name: "gvcli",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GogglesPipeline",
            targets: ["GogglesPipeline"]
        )
    ],
    dependencies: [
        .package(path: "../../Packages/GogglesProtocol"),
        .package(path: "../../Packages/GogglesUSB")
    ],
    targets: [
        // The shared, transport-agnostic driving loop (Pipeline.swift),
        // its actor-backed sequence/timer/stats bookkeeping
        // (PipelineState.swift), the stream.py-matching frame-boundary ack
        // tracker (FrameBoundaryAckTracker.swift), and the raw-fd Annex-B
        // output sink (OutputSink.swift). Depends only on GogglesProtocol
        // (GogglesTransport/WireProtocol/FrameReassembler) -- deliberately
        // NOT on GogglesUSB, so this library doesn't pull libusb into
        // anything that just wants to drive the pipeline against a
        // MockTransport or an already-constructed GogglesTransport.
        .target(
            name: "GogglesPipeline",
            dependencies: [
                .product(name: "GogglesProtocol", package: "GogglesProtocol")
            ]
        ),
        .executableTarget(
            name: "gvcli",
            dependencies: [
                "GogglesPipeline",
                .product(name: "GogglesProtocol", package: "GogglesProtocol"),
                .product(name: "GogglesUSB", package: "GogglesUSB")
            ]
        ),
        // Task 1.7 fix round: unit tests for the pure, transport-free
        // pieces of the pipeline's driving loop -- currently just
        // `FrameBoundaryAckTracker` (the frame-boundary-ack review fix).
        // Moved (Task 2.2) alongside `GogglesPipeline`, the module it now
        // actually lives in; `@testable import GogglesPipeline` works
        // against a library target the same way it did against gvcli's
        // former executableTarget.
        .testTarget(
            name: "GogglesPipelineTests",
            dependencies: [
                "GogglesPipeline",
                .product(name: "GogglesProtocol", package: "GogglesProtocol")
            ]
        )
    ]
)
