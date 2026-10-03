# GogglesView roadmap

Shipped in 0.1: live view, multi-goggles picker, 60 fps stall fix, recording,
instant replay, capture window, MPEG-TS/UDP out, stats + latency overlay,
screenshots, orientation, global hotkeys, diagnostics, auto-open, back-to-picker.

Each item below is its own design + build cycle. Order reflects dependencies
and what unblocks the most value; the phases are not time estimates.

## Phase 1 — Quality of life and reliability (no hard dependencies)

- **Onboarding checklist**: first-run screen covering OTG toggle, data cable,
  helper approval, with live pass/fail per step.
- **Clear "why not detected" states**: distinguish no USB device / OTG off /
  helper not approved / claim failed, each with the fix.
- **Self-test screen**: USB seen, helper reachable, protocol version, first
  frame received, measured fps.
- **Window memory**: persist size/position per window.
- **Presets**: "Streaming", "Recording", "Minimal" bundles of settings.
- **Per-goggles profiles**: remember name and settings per serial.
- **Update checker**: compare running version to the latest GitHub release,
  link to it (no auto-install).
- **Accessibility pass** and **localization** (Italian first; string catalog).
- **Rebindable global hotkeys** (currently fixed combos).

## Phase 2 — Viewing

- **Crop and aspect**: crop rectangle, aspect presets (16:9, 4:3, 1:1, custom),
  zoom/pan, optional grid and safe-area overlay. Applies to the display
  layer; recording stays passthrough unless burn-in is enabled.
- **Color tweaks** (brightness/contrast/saturation) via Core Image on the
  display path.
- **Freeze frame / pause view** while the stream continues.
- **Picture-in-picture / floating mini window.**
- **Multi-goggles in separate windows**: one window per goggles, each
  independently sized and positioned. Builds on the existing multi-device
  helper protocol; needs a per-window session/coordinator instead of the
  single `launchMainWindow` flow (see
  `docs/superpowers/specs/2026-08-29-multi-device-picker-design.md`).

## Phase 3 — Telemetry and flight data

Capture A (2026-10-03) showed only a 1 Hz heartbeat and undecodable per-frame SEI on this transport; repeat with a drone linked before building on it. Capture plan in `docs/telemetry-research.md`
(`gvcli --dump-telemetry`, no drone vs drone linked vs moving sticks, etc.),
then decode. Until a capture exists everything below is speculative.

1. Decode captured type-0x01 DUML messages into typed fields (signal,
   battery, GPS, attitude, whatever the goggles actually emit).
2. Live telemetry in the overlay (per-field toggles like the stats OSD).
3. Flight log: record telemetry alongside video; export CSV/GPX; replay a log
   next to a recording.
4. Link-quality graph over time.
5. If the goggles do not emit usable telemetry on this transport, stop at 1
   and document it.

## Phase 4 — Recording and clips

- **Loop recorder**: record continuously, keep only the last N minutes on disk
  (segmented files, delete oldest).
- **Auto-split** by size/time and **auto-delete** old recordings.
- **Markers/bookmarks** while recording, stored in a sidecar file.
- **Quick trim and share**: trim a recording or replay clip (passthrough cut at
  keyframes, optional re-encode), then share via the system share sheet.
- **Clip gallery**: browse recordings, trim, export.
- **Burn-in overlay**: optional logo/watermark and OSD burned into a
  *re-encoded* output (VideoToolbox H.264/HEVC). Off by default; costs CPU and
  breaks passthrough, so it is a separate output mode, not the default recorder.

## Phase 5 — Streaming and output

- **SRT output** (needs libsrt; check licensing/bundling and notarization).
- **RTMP push** to Twitch/YouTube (hand-rolled client or small dependency).
- **Local web viewer**: embedded HTTP server with a browser page (HLS/MSE or
  WebRTC); decide based on latency needs. LAN-only by default, opt-in, with a
  clear security note.
- **NDI output**: requires the NDI SDK (redistribution terms to confirm).
- **OBS virtual camera** (CMIO extension): hard-blocked on a paid Apple
  Developer Program membership (in progress). Existing spike lives in
  `Extension/GogglesCamera`; entitlements are split in
  `GogglesView-with-extension-install.entitlements`.

## Phase 6 — Distribution (after the Developer Program is active)

- Developer ID signing and notarization; notarized DMG in releases.
- Sparkle or similar for in-app updates (optional).
- Later, deliberately deferred: project website, Homebrew cask.

## Phase 7 — Ambitious

- **Low-latency mode.** First measure where time goes: the overlay already
  shows helper-to-screen delay; add decode-to-present timing and compare with a
  CosmoStreamer-style reference. Candidates: skip display-layer buffering,
  immediate-display flags (already set), smaller helper-to-app batching,
  avoiding extra copies. Goggles-internal latency is outside our control.
- **Scripting hook.** Start small: run a user-provided executable/URL on events
  (stream live/lost, recording started/stopped, replay saved) with event data
  as JSON on stdin or in the request body. A richer embedded scripting layer
  only if there is demand. Security: user-configured only, no remote triggers
  by default.
- **Windows/Linux client**: protocol tooling (`gvcli`, `GogglesProtocol`)
  could port; separate project.

## Suggested order

1. Telemetry capture + decode (unblocks Phase 3; needs one hardware session).
2. Phase 1 reliability items (onboarding, clear states, self-test).
3. Crop/aspect, then multi-window.
4. Loop recorder and quick trim/share.
5. SRT/RTMP/web viewer; NDI after checking SDK terms.
6. Notarization + OBS virtual camera when the membership lands.
7. Low-latency investigation and the scripting hook alongside any of the above.
