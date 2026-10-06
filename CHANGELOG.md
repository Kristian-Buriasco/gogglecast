# Changelog

All notable changes to this project are documented here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.5.1] - 2026-10-06

### Fixed
- Live stabilization shifted colours slightly (a flat 200/100/50 came out as 203/108/61) because the output was always rendered in Rec.709. It now keeps the input's colour space.
- Live stabilization silently stopped after about 7 frames whenever something held on to its output pictures, passing the unstabilized picture through. The buffer pool no longer has that cap.
- Live stabilization measured motion too coarsely at 1080p (shake reduction was about 50%). The analysis resolution is higher now: about 57% at 1080p and 63% at 720p on synthetic shaky footage, at roughly 6 ms per frame.

### Added
- VoiceOver support across the app: labels for icon-only buttons, values with units on sliders, spoken status for colour-only indicators, clip gallery actions (open, reveal, share, trim, move to Trash), trim start and end sliders, and marker ticks.
- Stabilizer tests on synthetic shaky footage for BGRA, 420v and 10-bit input, including a colour check.

### Developer
- `GogglesView --doc-shot <clip-gallery|mini-window|menu-bar|live-synthetic> <out.png>` renders documentation pictures with generated data and no helper.

## [0.5.0] - 2026-10-06

### Added
- Live stabilization (Settings > Display): electronic stabilization of the live picture with an adjustable strength. It only uses motion seen so far, so it adds a few ms of processing but no frames of delay. Zooms in 4 to 10% to hide the edges; doesn't correct rotation.
- Color looks: import `.cube` 3D LUTs and apply one, with an intensity slider, to the preview and/or to recordings, replay and streams.
- Output framing: a separate crop (aspect 16:9, 4:3, 1:1 or 9:16, zoom, position) for recordings, replay and streams, independent of the preview framing. A new 9:16 aspect is also available for the preview.

### Changed
- Recording uses the shared keyframe encoder from the start when an output crop or look is active, since those only exist in the re-encoded stream.
- The RTMP settings note now says the stream key is kept in the Keychain (it used to say unencrypted preferences).

### Developer
- `GogglesView --settings-shot <Tab> <out.png> [height]` writes the Settings window on a tab to a PNG without the helper, for documentation screenshots.

## [0.4.0] - 2026-10-05

### Added
- Shared keyframe encoder: instant replay, UDP, RTMP, SRT and the web viewer now get a re-encoded stream with a keyframe every second (hardware encoder, only while one of them is active), so clips and late-joining viewers start cleanly. Settings > Streaming has an on/off switch and a bitrate stepper.
- The overlay's latency now measures the stream arriving to the decoded picture being ready (includes hardware decode).

### Changed
- The app decodes the stream once and gives every window the decoded picture. A capture or mini window opened mid-stream, or a window reopened after closing, shows video straight away instead of waiting for a keyframe.
- The window's "Disconnect" button is now "Close": it hides the window and keeps the stream and decoder running, so coming back is instant. Goggles > Disconnect and the menu-bar item still stop the stream.

### Fixed
- Recording started mid-stream produced no file or an unplayable one (the goggles send a single keyframe when Share Liveview starts and none after). A recording armed before that keyframe stays lossless passthrough; one started later now records the shared keyframe encoder's stream after 1 s, so it plays from the first frame.
- Recorder now logs its lifecycle and failures (subsystem `com.kburiasco.gogglesview.app`, category `Recorder`).

## [0.3.0] - 2026-10-04

### Added
- In-app updates: downloads the release DMG from GitHub, verifies its SHA-256 and code signature (same app identity and team, newer version), and installs on quit or via "Install & Restart". Optional "Install updates automatically". Never while recording or streaming. Rolls back if the copy fails and re-registers the helper when it changed.

### Changed
- Settings redesigned: sidebar navigation with icons, one card per setting group, larger window, cleaner Updates card. Daily update check is now on by default.

## [0.2.1] - 2026-10-04

### Fixed
- Rebuilt the bundled libusb for macOS 14 so the helper no longer depends on `pipe2`, which is missing on macOS 14/15 (0.2 could fail to start the helper there).
- Fixed compile errors on older Swift toolchains; CI now builds and tests on GitHub.

## [0.2] - 2026-10-04

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
