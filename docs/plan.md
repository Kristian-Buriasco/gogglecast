# GogglesView — Implementation Plan

Companion to [`design.md`](design.md). Read that first; this document does not restate
protocol details, it references them by section.

Every task below is written to be executed one at a time by a developer or an AI agent,
with a stated exit criterion. **Do not start a phase until the previous phase's exit
criterion is demonstrably met** — the parity gate at the end of Phase 1 in particular is
what prevents protocol bugs and packaging bugs from being debugged simultaneously later.

## Phase summary

| Phase | Deliverable | Blocks on |
|---|---|---|
| 0 | Repo, Xcode workspace, libusb vendored, capture corpus | nothing |
| 1 | Swift protocol core + root CLI, byte-parity with Python | 0 |
| 2 | Privileged helper as an `SMAppService` daemon + XPC | 1 |
| 3 | SwiftUI app: decode, display, state machine, IDR UX | 2 |
| 4 | CMIOExtension virtual camera | 3, paid Apple Developer membership *or* developer mode |
| 5 | Hardening, Wi-Fi transport, packaging | 3 |

---

## Phase 0 — Foundation

**Goal:** a buildable, testable skeleton and an offline test corpus, before any protocol
code is written.

### 0.1 Repository and layout
Create `~/XcodeProjects/GogglesView/` as a git repo with:

```
GogglesView.xcodeproj            # or GogglesView.xcworkspace + SPM packages
Packages/GogglesProtocol/        # SPM library: pure Swift, no libusb, no AppKit
Packages/GogglesUSB/             # SPM library: libusb + RNDIS transport
Apps/GogglesView/                # SwiftUI app (Phase 3)
Helper/GogglesHelper/            # CLI -> LaunchDaemon (Phases 1-2)
Extension/GogglesCamera/         # CMIOExtension (Phase 4)
Tools/gvcli/                     # test harness CLI (Phase 1)
Fixtures/                        # capture corpus + golden vectors
docs/
```

`GogglesProtocol` must have **zero** dependency on libusb or on any Apple framework
beyond Foundation. This is what makes §9.1 offline testing possible and what lets the
Wi-Fi transport drop in later.

**Exit:** `swift test` runs (with zero tests) on both packages; the repo has an initial
commit.

### 0.2 Vendor libusb
Build libusb 1.0.27+ as a static universal (arm64 + x86_64) library and vendor it, or add
it as an SPM binary target. Static, not dynamic — a root LaunchDaemon should not depend on
Homebrew paths, and a dynamic dependency under `/opt/homebrew` in a signed privileged
binary is both a signing and a security problem.

**Exit:** a trivial Swift target links it and prints `libusb_get_version()`.

### 0.3 Capture corpus
Add a `--capture <file>` flag to the Python `stream.py` that appends every inbound and
outbound Ethernet frame with a host timestamp and a direction byte. Record four sessions
per design §9.1: clean start with SPS+IDR, 60 s steady state, unplug mid-stream,
and one with visible fragment loss. Scrub the serial number. Commit to `Fixtures/`.

Also dump the raw ~40-byte bundled SPS+PPS blob to its own fixture file — it is needed by
the Phase 3 parameter-set split test and is small enough to keep separate.

**Exit:** `Fixtures/` contains the four captures plus the parameter-set blob, and a short
`Fixtures/README.md` naming the firmware (`zv300 gl Ver.02`) and `bcdDevice` they came
from.

### 0.4 Golden vectors
Add a Python script `Tools/gen_golden.py` that imports the prototype's `rawnet`, `rndis`
and `duml` modules and emits a JSON file of `{name, inputHex, outputHex}` for every case
listed in design §9.1 item 2. Committing the *generator* as well as its output means the
vectors can be regenerated if the prototype is ever corrected.

**Exit:** `Fixtures/golden.json` exists and is non-trivial (>= 20 vectors).

---

## Phase 1 — Swift protocol core + parity CLI

**Goal:** prove the Swift port is byte-identical to the Python prototype, on real
hardware, before any macOS packaging complexity exists.

### 1.1 `GogglesProtocol`: framing primitives
Port `rawnet.py` and the pure-data parts of `rndis.py`:
`checksum16`, `buildUDP`, `buildARPRequest`, `buildARPReply`, `parseARP`, `parseUDP`,
`wrapPacketMsg`, `unwrapPacketMsg`, and the RNDIS control-message builders
(`initializeMsg`, `setMsg`, `queryMsg`). Constants exactly per design §3.1–§3.2.

**Exit:** all `Fixtures/golden.json` vectors for these functions pass.

### 1.2 `GogglesProtocol`: wire protocol
Port `build_outer`, the handshake constant, `build_ack`, `build_telemetry_with_duml`, and
the DUML codec (`crc8`, `crc16`, `build`, `parseStream`) per design §3.3–§3.4. Put every
magic constant in one `WireProtocol.swift` with the provenance comment required by
design §8.6.

**Exit:** remaining golden vectors pass, including CRC-8/CRC-16 over a captured IF4 dump.

### 1.3 `GogglesProtocol`: reassembler
Implement the fragment reassembler with the **two corrections** the Python code needs
(design §5.2): age-based eviction of stale frame entries (modulo-256 distance > 5 or
> 250 ms), and dropping rather than merging incomplete frames, with a drop counter.

**Exit:** the reassembler tests in design §9.1 item 3 pass, including frame-number wrap
and the stale-entry case that `stream.py` gets wrong.

### 1.4 Transport abstraction + mock
Define `protocol GogglesTransport { func send(_ frame: Data) throws; var inbound:
AsyncStream<Data> { get } }` and a `MockTransport` that replays a `Fixtures/` capture at
recorded timing.

**Exit:** the full protocol core, driven by `MockTransport` over the clean-start capture,
emits the expected NAL sequence — verified against a reference NAL-type/length list
extracted from the same capture by a Python script.

### 1.5 `GogglesUSB`: RNDIS transport
Implement `RNDISTransport` conforming to `GogglesTransport`: device discovery
(`2CA3:0020`), kernel-driver detach, IF0/IF1 claim, RNDIS `INITIALIZE` + packet-filter
`SET`, and the async bulk-transfer pool (16 in-flight 64 KB transfers, libusb event
thread at high QoS) per design §5.2. Include `DeviceInfo` extraction (product, serial,
`bcdDevice`, bus, address).

**Exit:** the transport brings the link up and delivers Ethernet frames on real hardware
under `sudo`.

### 1.6 ARP resolution (replaces the hardcoded MAC)
Implement targeted ARP for `192.168.60.2` with the retry schedule in design §3.2, the
gratuitous-ARP/inbound-request learning path, the inbound ARP-request responder, and the
multi-subnet sweep fallback ported from `rndis_arp_sweep.py`.

**Exit:** connects successfully with no hardcoded MAC anywhere in the codebase, and
still connects after the goggles are power-cycled (this is the §8.2 test).

### 1.7 `gvcli` parity harness
A CLI: `sudo gvcli stream --out video.h264 --stats` that runs the whole pipeline and
writes Annex-B to a file or FIFO, printing per-second fps/bitrate/drop stats. Also
`gvcli replay <capture>` for the offline path and `gvcli info` for device info only.

**Exit — the Phase 1 gate.** All of design §9.2 met:
- `ffplay` on the FIFO renders correctly;
- `ffprobe` on the dump reports 1920x1080 High L5.2;
- fps within ±1 of Python's ~56 over 60 s (this target was originally documented as
  ~33 fps; the Phase 1 parity run found that figure was `stream.py`'s own read-loop
  bottleneck, not the true source rate — see `docs/parity-results.md`), drops <=
  Python's, bytes within 2%;
- running `stream.py` after `gvcli` succeeds (clean interface release).

Record the numbers in `docs/parity-results.md`. Do not proceed until they are recorded.

---

## Phase 2 — Privileged helper + XPC

**Goal:** the same code running as a root LaunchDaemon, reachable over XPC.

### 2.1 XPC interface package
Define `GogglesHelperProtocol`, `GogglesClientProtocol`, and the `NSSecureCoding`
`DeviceInfo` / `StreamStats` value types per design §5.5, in a package shared by helper,
app and extension. Include `protocolVersion`.

**Exit:** compiles into all three future targets.

### 2.2 Helper daemon binary
Wrap the Phase 1 core in a daemon: a `NSXPCListener` on the Mach service, a subscriber
registry with the fan-out and 5 s linger rules (design §5.5), signal handling that
releases USB interfaces on `SIGTERM`, and `os_log` throughout.

Keep the Phase 1 `--stdout` mode working. This is deliberate: it lets protocol
regressions be diagnosed without the XPC layer in the way, per design §8.4.

**Exit:** `sudo ./GogglesHelper --xpc` serves a throwaway CLI client that receives NAL
callbacks; `--stdout` still passes the Phase 1 parity check.

### 2.3 launchd plist and bundle placement
Author `Contents/Library/LaunchDaemons/com.kburiasco.gogglesview.helper.plist` with
`Label`, `BundleProgram` = `Contents/MacOS/GogglesHelper`, `MachServices`, and
`AssociatedBundleIdentifiers`. Verify the design §8.4 checklist item by item:
plist filename == `Label` == the `plistName:` argument; same Team ID on app and helper;
hardened runtime on the helper. **Do not add `SMPrivilegedExecutables`** — that key is
`SMJobBless` and does not belong here.

**Exit:** `SMAppService.daemon(plistName:).status` reports `.notRegistered` (not
`.notFound`) from a stub app — proving the bundle layout is discoverable.

### 2.4 Registration flow and status surfacing
A minimal AppKit/SwiftUI harness that calls `register()`, handles the approval flow, and
displays `SMAppService.Status` verbatim. Explicitly handle `.requiresApproval` with a
deep link to System Settings > General > Login Items & Extensions.

Write `docs/dev-setup.md` covering the iteration loop, including how to clear a stale
registration (`unregister()` first; `sudo sfltool resetbtm` as the nuclear option, noting
it resets *all* login items on the machine).

**Exit:** register -> approve -> the daemon is running as root and a client connects, and
the whole loop can be repeated after a rebuild without a machine reboot.

---

## Phase 3 — SwiftUI app

**Goal:** the shippable v1 product.

### 3.1 Client layer
`NSXPCConnection(machServiceName:options:.privileged)`, the exported client object,
reconnection on invalidation, and a `protocolVersion` mismatch check that fails loudly.

**Exit:** app receives NAL callbacks and logs fps matching `gvcli`.

### 3.2 Parameter-set splitting and format description
Implement the design §5.3 split: scan the bundled blob for internal start codes, isolate
SPS (type 7) and PPS (type 8), build the `CMVideoFormatDescription` with
`nalUnitHeaderLength = 4`, and rebuild only when the blob's bytes change.

**Exit:** the §9.1 item 4 test passes against the Phase 0 fixture blob, reporting
1920x1080.

### 3.3 Decode and display
Annex-B -> AVCC conversion, `CMSampleBuffer` construction with the helper's host
timestamp, `AVSampleBufferDisplayLayer` in `DisplayImmediately` mode per design §5.4, and
the §7 error policy (drop bad samples; tear down the session after 30 consecutive
failures).

**Exit:** live video in the app window, visually identical to `ffplay`, with measured
glass-to-glass latency recorded in `docs/parity-results.md`.

### 3.4 State machine and device card
The nine states of design §6 as a single observable enum driving the UI, plus the device
info card (product / serial / `2CA3:0020` / bus-address) styled after CosmoViewer Direct's
layout. Include the §7 diagnostic strings — notably the `claimFailed` text that tells the
user to disable the `en*` interface or replug (design §8.3).

**Exit:** every state is reachable and correctly rendered; verified by forcing each one.

### 3.5 The IDR/keyframe UX
The `waitingForKeyframe` card with the exact copy in design §8.1, the elapsed counter, the
"Try requesting a keyframe" secondary button wired to `requestIFrame()` and labelled as
unreliable, and the "Reconnect" menu command performing a full §5.1 reconnect with a fresh
random session id.

**Reviewer note:** reject any implementation that presents `requestIFrame()` as the
primary or expected fix. It does not reliably work; the goggles-side toggle is the
instruction.

**Exit:** from a cold start with the goggles already streaming, following only the
on-screen instructions produces live video, with no terminal and no documentation.

### 3.6 Menu bar item and window management
Menu bar extra with state glyph, show/hide window, Reconnect, Quit. Window preserves
aspect ratio; a fullscreen mode.

**Exit:** v1 is usable as a daily driver.

### 3.7 Robustness pass
Work through the design §9.3 checklist, all nine scenarios. Scenario 3 (goggles reboot ->
MAC rotation) and scenario 8 (30-minute memory flatness, which exercises the §5.2
reassembly fix) are the two that most commonly fail; treat them as required, not optional.

**Exit — v1 ships.** All nine scenarios pass; results in `docs/parity-results.md`.

---

## Phase 4 — CMIOExtension virtual camera

**Prerequisite check before starting:** confirm whether a paid Apple Developer Program
membership is available. If not, this phase targets `systemextensionsctl developer on`
only and is personal-use-only, per design §8.5. Write the answer into
`docs/dev-setup.md` before writing code.

### 4.1 Mach-lookup spike (gate — do this first)
A do-nothing CMIOExtension whose only job is to connect to the helper's app-group-prefixed
Mach service and log one received `stats` callback. Nothing else.

**Exit:** either the connection works (proceed to 4.2), or it does not, in which case
adopt the design §4.1 fallback — the app pushes frames to the extension via
`CMIOExtensionStream` — and record the decision in `docs/design.md` §10 question 1 before
continuing.

### 4.2 Extension skeleton and installation
`CMIOExtensionProvider` / `Device` / `StreamSource` publishing "DJI Goggles 3" at
1920x1080. App group, `com.apple.developer.system-extension.install` entitlement, bundle
at `Contents/Library/SystemExtensions/`, install via `OSSystemExtensionRequest` with
proper delegate handling of the replace/upgrade cases.

**Exit:** `systemextensionsctl list` shows it `activated enabled`, and it appears in
OBS's camera list showing a static test pattern.

### 4.3 Frame path
Reuse the Phase 3 decode code (extract it into a shared package first — do not fork it),
producing `CVPixelBuffer`s into the CMIO stream with timestamps synthesised per design
§5.4, advertising 30 fps nominal.

**Exit:** live goggles video in OBS.

### 4.4 Lifecycle and no-signal handling
Start/stop the helper subscription on stream start/stop; render an explanatory "no signal"
frame rather than hanging or going black when the goggles are absent; survive the app
being quit and the machine rebooting.

**Exit:** the full design §9.4 checklist, including OBS, Zoom, Discord and Chrome
`getUserMedia`, and the app-update-in-place case.

---

## Phase 5 — Hardening and packaging

### 5.1 Wi-Fi transport (design §4.1, change 3)
`WiFiUDPTransport` using `NWConnection` over UDP to port 9003, plus SSID/passphrase
retrieval over IF4 via DUML `07:07` / `07:0E` / `07:0C` to module `0x1B`, ported from
`get_wifi_creds.py`. Note this needs **no root** — the vendor interfaces have no kernel
driver bound. Resolve design §10 question 4 (which address answers on the AP subnet)
here. Surface as a "Wi-Fi (no setup required)" alternative in the UI.

**Exit:** video works over Wi-Fi with the helper stopped entirely.

### 5.2 Logging and diagnostics
`os_log` categories across all three processes; a "Export diagnostics" command producing
a zip of recent logs, `SMAppService.Status`, `systemextensionsctl list` output, and the
USB descriptor. Log unknown packet types at debug level per design §8.6.

### 5.3 Signing, notarization, distribution
Developer ID signing of app, helper and extension; hardened runtime; notarization;
stapling; a DMG. **If no paid membership:** stop here, document the developer-mode-only
install path in the README, and state plainly that redistribution is blocked.

### 5.4 Documentation
`README.md` (what it does, requirements, install, the goggles-side liveview toggle
instruction), `docs/dev-setup.md`, `docs/parity-results.md`, and a `docs/protocol.md`
extracted from design §3 for anyone reimplementing this. Cross-link the Python prototype
and note that its `FINDINGS.md` is stale (design §2).

---

## Sequencing notes

- **Phases 1 and 2 are strictly sequential.** Doing packaging before parity means
  debugging RNDIS and `SMAppService` at the same time, which is the single most likely
  way for this project to stall.
- **Phase 4 is independent of Phase 5** and can be skipped entirely; v1 is defined as
  Phases 0–3 and is a complete product without a virtual camera.
- **Phase 0.3 (the capture corpus) is on the critical path** even though it looks like
  housekeeping — Phases 1.1 through 1.4 cannot be tested without it, and it requires the
  hardware to be present. Capture it while the goggles are to hand.
- Anything discovered about the IDR trigger (design §8.1) slots in behind
  `requestIFrame()` at any point with no architectural change. Do not restructure to
  anticipate it.
