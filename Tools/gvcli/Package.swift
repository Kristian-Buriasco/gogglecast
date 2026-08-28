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
// ─────────────────────────────────────────────────────────────────────────

let package = Package(
    name: "gvcli",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../Packages/GogglesProtocol"),
        .package(path: "../../Packages/GogglesUSB")
    ],
    targets: [
        .executableTarget(
            name: "gvcli",
            dependencies: [
                .product(name: "GogglesProtocol", package: "GogglesProtocol"),
                .product(name: "GogglesUSB", package: "GogglesUSB")
            ]
        )
    ]
)
