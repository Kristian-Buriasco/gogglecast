# GogglesView

The `GogglesView` app target, built as a real SPM executable package
(`Package.swift`). SwiftUI UI is not filled in yet (Task 3.4+) -- through
Task 3.1 this is the XPC client layer (`Sources/GogglesView/HelperClient.swift`)
plus the `SMAppService.daemon` registration harness from Task 2.3/2.4
(`Sources/GogglesView/main.swift`'s `--register`/`--unregister`/
`--check-daemon-status`), exercised from the command line via
`--test-client` until a real UI exists to drive `HelperClient` instead.

Build/assemble the app bundle: `./build-stub-bundle.sh` (still named for
its Task 2.3 origins as a stub-app bundler; it now builds the real
`GogglesView` SPM target, not a bare `swiftc`-compiled stub -- see that
script's own doc comment).

Run tests: `../../Packages/swift-test-clt.sh .` (from this directory) --
this machine only has the Xcode Command Line Tools installed, not full
Xcode.app, which needs the flags that script sets; see its own comment.
