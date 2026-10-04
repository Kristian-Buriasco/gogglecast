# GogglesView

A free, native macOS app that shows the live video feed from DJI Goggles 3 on a Mac over USB-C. The protocol is reverse-engineered; no CosmoStreamer dongle is needed.

## Features

- Live view of the goggles' video feed, H.264 passthrough decoded with VideoToolbox.
- Multi-device picker when more than one pair of goggles is attached.
- Full frame rate: 59/60 fps when the goggles send it.
- Recording of the raw stream to `.mov` or `.mp4` (no re-encode), saved to `~/Movies/GogglesView`. Optional auto-start when the stream goes live.
- Chrome-less capture window, for use as an OBS Window Capture source. Optional "keep on top".
- Stats overlay (resolution, framerate, bitrate, dropped frames), each field toggled in Settings.
- Menu bar item (the app runs as a menu bar app, `LSUIElement`).

## Requirements

- Apple Silicon Mac, macOS 14 (Sonoma) or later (`Package.swift` platform `.macOS(.v14)`; the bundled libusb is universal, but only arm64 has been tested).
- DJI Goggles 3 and a USB-C cable that carries data (charge-only cables will not work).
- On the goggles: Settings > About > enable "OTG Wired Connection to Computer". Unplug the goggles before toggling it, then reconnect.
- The goggles' live view must be active while streaming.

## Install and first run

There are no prebuilt, notarized releases. Build from source (below) or use `scripts/make-dmg.sh` to produce a DMG.

1. Copy `GogglesView.app` to `/Applications`. The build is signed with an Apple Development certificate (or ad-hoc), not notarized, so on first launch right-click the app and choose Open.
2. On first launch the app registers a privileged helper daemon (`GogglesHelper`) via `SMAppService`. macOS requires one-time approval: System Settings > General > Login Items & Extensions, enable GogglesView. The helper owns the USB device; the app talks to it over XPC.
3. Enable OTG on the goggles, connect them, start live view.

## Build from source

Requires Xcode or the Command Line Tools with a Swift toolchain that supports macOS 14.

```bash
Apps/GogglesView/build-stub-bundle.sh            # -> Apps/GogglesView/build/GogglesView.app
Apps/GogglesView/build-stub-bundle.sh /some/dir  # custom output dir
scripts/make-dmg.sh                              # -> dist/GogglesView-<version>.dmg
```

The script builds the helper and app in release mode and assembles the bundle. It signs with `GOGGLESVIEW_SIGN_IDENTITY` if set, else the first valid codesigning identity in your keychain, else ad-hoc.

Tests: `Packages/swift-test-clt.sh <package dir>` (see the script for why it exists on a Command Line Tools-only machine).

Entitlements live in `Apps/GogglesView/BundleResources/`. `GogglesView.entitlements` is the default. `GogglesView-with-extension-install.entitlements` adds the system-extension install entitlement for the future OBS virtual camera; it needs a paid Apple Developer Program membership (the app fails to launch with AMFI -413 otherwise), so it is opt-in via `GOGGLESVIEW_WITH_EXTENSION_INSTALL=1` and not used in normal builds. See `docs/dev-setup.md`.

## Automation

Shortcuts, Stream Deck, Raycast, `open "gogglesview://record/toggle"` and AppleScript can drive recording, replay, screenshots, freeze, markers and the UDP stream. See `docs/automation.md`. Toggle in Settings > Advanced > Automation.

## Troubleshooting

- Goggles not detected: try another USB-C port and a known data cable; confirm "OTG Wired Connection to Computer" is on (unplug before toggling); confirm the helper is approved in Login Items & Extensions.
- Connected but no picture: the stream only starts while the goggles' live view is active.
- Frame rate is ~30 fps instead of 60: that is determined by the goggles' own encode mode, not by the app.
- Stuck after helper changes: unregister and re-register the helper (see `docs/dev-setup.md`).

## Known limitations

- No OBS virtual camera yet. Use the capture window with OBS Window Capture. The CMIO camera extension exists only as a spike and is blocked on a paid Developer Program membership.
- Not notarized; dev-signed. Gatekeeper requires right-click > Open.
- Pass-through of the goggles' encoded stream only: no audio, no re-encoding or scaling controls.

## Architecture

- `Apps/GogglesView`: SwiftUI/AppKit app. Decodes H.264 NALs (`DecodeSession`), renders, records (`Recorder`, `AVAssetWriter`), and manages windows/menu bar. Talks to the helper through `HelperClient` (XPC).
- `Helper/GogglesHelper`: root launch daemon registered with `SMAppService`. Enumerates and claims goggles over libusb, runs the protocol, fans video out to the app per device.
- `Packages/`: `GogglesUSB` (transport), `GogglesProtocol` (framing/handshake), `GogglesXPC` (shared XPC interface), `CLibusb` (vendored libusb in `Vendor/`).
- `Extension/GogglesCamera`: unfinished CMIO camera extension spike.

More detail: `docs/design.md`, `docs/dev-setup.md`, `docs/parity-results.md`.
