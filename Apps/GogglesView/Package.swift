// swift-tools-version:5.10
import PackageDescription

// ─────────────────────────────────────────────────────────────────────────
// Task 3.1: `GogglesView` graduates from a bare `swiftc`-compiled stub
// binary (Task 2.3/2.4's `StubApp/main.swift`, built via a raw `swiftc`
// invocation in `build-stub-bundle.sh` with manual `-framework` flags) into
// a real SPM executable package, matching every other target in this repo
// (`GogglesHelper`, `gvcli`, all three `Packages/*`).
//
// The trigger is `GogglesXPC`: this task's `HelperClient` needs
// `GogglesHelperProtocol`/`GogglesClientProtocol`/`DeviceInfo`/
// `StreamStats`/`currentProtocolVersion`, all from `GogglesXPC`. Task 2.4's
// throwaway XPC test client proved this is *possible* to do by hand with
// raw `swiftc -module-name GogglesXPC ...` flags (see that task's report --
// the module-name mismatch bug that produced undecodable
// `NSSecureCoding` payloads), but that was explicitly a throwaway, and
// hand-maintaining matching `swiftc` flags for a second module dependency
// permanently is exactly the kind of fragile setup a real, committed app
// target shouldn't carry forward. A path dependency here is the same
// pattern `Helper/GogglesHelper/Package.swift` already uses for the same
// package.
// ─────────────────────────────────────────────────────────────────────────

let package = Package(
    name: "GogglesView",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../Packages/GogglesXPC"),
        .package(path: "../../Packages/GogglesH264")
    ],
    targets: [
        .executableTarget(
            name: "GogglesView",
            dependencies: [
                .product(name: "GogglesXPC", package: "GogglesXPC"),
                .product(name: "GogglesH264", package: "GogglesH264")
            ]
        ),
        .testTarget(
            name: "GogglesViewTests",
            dependencies: [
                "GogglesView",
                .product(name: "GogglesH264", package: "GogglesH264")
            ]
        )
    ]
)
