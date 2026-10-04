# Changelog

All notable changes to this project are documented here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Output: RTMP push, HLS web viewer, SRT (libsrt) and NDI (unverified), plus UDP MPEG-TS.
- Clip gallery with passthrough trim and share; loop recorder, auto-split, auto-delete, markers; burn-in logo/text recording.
- Framing (zoom/pan/crop/grid/color), freeze, mini window, per-goggles profiles, presets, onboarding, self-test.
- Event hooks (script/webhook), multiple goggles in separate windows, accessibility labels, data collection tool.
- Session log (per-second stats and events, CSV export), menu-bar mini-controls, benchmark/latency mode (`docs/latency.md`).
- Automation: `gogglesview://` URL scheme and AppleScript suite (`docs/automation.md`).

### Changed
- Settings reorganized into General / Display / Recording / Streaming / Advanced tabs; the last tab is remembered.
- Stream key, SRT passphrase, web viewer token, GitHub token and webhook URLs now live in the Keychain; existing values migrate automatically on launch.

### Fixed
- Recordings, replay clips and streams now start on a real keyframe.

## [0.1] - 2026-10-03

### Added
- Multi-device support: device identity and enumeration, per-device claim/state in the helper, device-scoped XPC protocol, and an app-side device picker.
- Recording of the passthrough stream to `.mov` or `.mp4`, with recording settings (container, auto-start).
- Chrome-less external capture window for OBS Window Capture, with optional keep-on-top.
- On-screen stats overlay (OSD) with per-field toggles in Settings.
- Screenshot button (PNG to `~/Pictures/GogglesView`) and keyboard shortcuts (Shift-Cmd-S screenshot, Shift-Cmd-R record).
- Stream resolution read from the stream itself and shown in the status pill and overlay.
- Settings screen, reachable before a device is selected; real app menu bar; custom title bar and restyled chrome.
- `scripts/make-dmg.sh` to package the app as a DMG; README.

### Fixed
- Periodic stream stalls: the transport now sends cumulative window acknowledgements instead of per-frame acks.
- Multi-device XPC array decoding, an AMFI launch block, and status pill alignment.
- noDevice/claiming UI flicker from background device-retry polls.
- Recovery from helper restart and from stalled/handshaking states back to live.
- Process-wide transport/sink globals in the pipeline (now per-session).

### Known limitations
- No OBS virtual camera; the CMIO extension is blocked on paid Apple Developer Program membership.
