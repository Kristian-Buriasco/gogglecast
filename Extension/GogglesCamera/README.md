# GogglesCamera

CMIOExtension that publishes the goggles as a 1920x1080 camera named "DJI Goggles 3" (OBS, Zoom, Discord, Chrome).

- `HelperFeed` subscribes to the helper's Mach service like the app does, picks the first goggles, and starts/stops streaming with the CMIO stream.
- `FrameDecoder` decodes the H.264 NALs (shared `GogglesH264` package, same parameter-set/AVCC code as the app).
- `FrameRenderer` letterboxes pictures into 1920x1080 BGRA and draws the "no signal" card.
- `ProviderSource` sends live frames as they arrive and the no-signal card at ~30 fps when none arrive for 1 s.

Status: compiles and bundles, never run. Installing needs the paid Apple Developer Program (`docs/dev-setup.md`). First things to check once it can run: the sandbox Mach lookup of the helper (design §10 q1), `CMIOExtensionMachServiceName` in `BundleResources/Info.plist`, then design §9.4.
