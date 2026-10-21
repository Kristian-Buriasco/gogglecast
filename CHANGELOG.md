# Changelog

All notable changes to this project are documented here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.11.2] - 2026-10-20

### Added
- Settings > HDMI > "Keep displays awake" (on by default): while the program outputs are shown, the Mac no longer lets its displays go to sleep, which used to blank the HDMI feed after a couple of minutes of no input. A locked Mac still covers every display.

### Changed
- Settings > Picture > Stabilization mode has a new "Translation only (previous method)" entry, so the old measurement can be compared with the new default.
- The live stabilizer now measures motion with the homography registration on the central 70% of the picture at 384 px. On real recorded footage the previous translation mode was slightly worse than no stabilization; the new default removes a little jitter (about 3% on the test clip) and crops about 8%, at about 8.5 ms per frame. The Tiles mode measured worse than no stabilization on real footage and stays opt-in.
- Auto recording (Settings > Recording > "Start recording automatically when live") now follows the frame rate: it starts once the rate holds above 10 fps for a second and the picture is really changing, stops when the rate sits at 0 for 2 seconds, and starts a new recording when the feed comes back. It only stops recordings it started, and after you stop one by hand it waits for the feed to go away and return before starting again.

## [0.11.1] - 2026-10-20

A dedicated HDMI tab, an emergency way to close program outputs and two layout fixes.

### Added
- Settings has a new HDMI tab for the program outputs: the master switches, a table of connected displays (main or external, resolution, which output uses it) and one group per output with a status line.
- Emergency close: press Control-Option-Command-period in any app to close all program outputs, for example when one landed on your only screen. Active only while an output is shown.

### Fixed
- Settings > General: the Check Now button was clipped; it keeps its full width now.
- Settings > Advanced > Remote alerts: the card now says what is needed to switch it on (server and topic), and the Send test button is no longer clipped.

## [0.11.0] - 2026-10-19

A redesigned Settings window and two new stabilizer modes.

### Changed
- Settings is now eight sidebar tabs (General, Display, Picture, Recording, Streaming, Outputs, Integrations, Advanced) with aligned label and control rows. Every field has a visible label and units, long help text moved into info popovers, and text inputs have a new look with a focus outline. Secret fields have a show/hide button and are still read from the keychain only when needed.

### Added
- Stabilization mode (Settings > Picture): "Translation only" (the default, as before), "Translation and roll (tiles)" and "Translation and roll (homography)". The two new modes also correct roll. They were measured only on synthetic clips so far, so they are opt-in.

### Fixed
- The stabilizer shares one Core Image context and frees its temporary objects after each picture, like the noise reducer already did.

## [0.10.3] - 2026-10-19

Remote alerts, so you can step away from the Mac during an event.

### Added
- Remote alerts (Settings > Advanced, off by default): sends a notification to a self-hosted [ntfy](https://ntfy.sh) server when a goggles signal is lost or back, the picture freezes or goes black, the battery runs low, an output (RTMP, SRT, NDI, recording or the HDMI window) fails or stalls, or the helper is unreachable. Each condition has its own delay and priority, alerts repeat while the fault lasts and a recovery message is sent. An Away switch (also in the menu bar) turns sending on, and an optional heartbeat URL lets an outside monitor notice if the Mac goes silent. Messages use the crew's feed names, never serial numbers.

### Known limits
- ntfy on iOS delivers these as normal notifications; Apple critical alerts are not supported by the ntfy app.
- A recording alerts only when it stops on an error; NDI and UDP outputs can fail but not stall; a hung helper that still reports live is not detected.

## [0.10.2] - 2026-10-19

Two options for the HDMI program output.

### Added
- Program output: a "Clean output" option hides every name, the no-signal marker, the issue warnings and the red border on all outputs, leaving only the video.
- Program output: a "Stabilize the program output" option runs the stabilizer while the outputs are shown, including in race mode, where stabilization was always off. The stabilizer sits in the shared decode path, so the preview is stabilized too.

### Fixed
- CI: the 1080p enhancer timing check no longer fails on the virtual GPU of the GitHub runners.

## [0.10.1] - 2026-10-17

A light theme, a clearer Record button and fewer keychain prompts.

### Added
- Appearance setting (System / Light / Dark) in Settings > Display. The interface now supports a light theme.

### Fixed
- Settings: input values and placeholders were hard to read on a light macOS theme, and the Settings button was invisible. The interface now follows the chosen appearance (#9).

### Changed
- The Record button is now a labelled pill at the start of the toolbar, with elapsed time while recording.
- Saved stream keys and tokens are read from the keychain only when a feature that needs them is used, so plain live view no longer triggers a keychain prompt.

## [0.10.0] - 2026-10-16

Picture enhancement (off by default), a new web viewer port and the token fix. Builds on 0.9.1, which was a pre-release.

### Added
- Picture enhancement (Settings, both off by default): a noise reducer (Apple's temporal noise filter where the Mac supports it, otherwise a motion-adaptive Core Image filter) and a MetalFX upscaler. They run per window after decoding, before the stabilizer and outputs, and are skipped in race mode. Measured on real goggles: about 2-4 ms (noise reducer) and 8-10 ms (upscaler) per frame; the upscaler holds about 225 MB per feed, so leave it off with many feeds.

### Changed
- The web viewer's default port is now 8787 instead of 8080. A port you set in Settings is kept; old links and QR codes on 8080 need refreshing.

### Fixed
- Web viewer: "Missing or wrong token" after changing the token in Settings. The server now reads the token on every request.

## [0.9.1] - 2026-10-11

Confirmed on real goggles (two units side by side, replug, 12 s helper freeze, Camera View Recording on, HDMI program output). Tested as a pre-release.

### Fixed
- A goggles window with no keyframe reconnected every 8 s forever: the reconnect itself ended the "waiting" state, which reset the back-off timer. The back-off (8, 16, 32 s) now survives that gap and resets only when a real picture shows.
- A goggles display that shows nothing moving sends one keyframe and then no video at all. The app took that silence for a dead stream, reconnected 13 s later and lost the picture. A background service that still reports live with fresh stats now counts as an alive link.
- Second goggles stayed black in a two-goggles setup: see Troubleshooting. The goggles pause Liveview sharing ("Goggles operating. Liveview sharing temporarily paused") while their menu is in use or when sharing was reset after a power cycle; toggle Share Liveview off and on once on that unit. Mixed firmware (1.0.0.8 and 1.0.0.15) was in use in the test: update all units to the same version before an event.


### Added
- A "Back to the list" button appears in the goggles window when the goggles have not been found (or could not be claimed) for 8 seconds, so you can pick again without looking for the menu.

### Changed
- The overlay notice (first stream, capture window), the README and the site no longer suggest the display-scale trick. They now say to turn the goggles' overlay off at its source: Settings > Camera > Advanced camera settings > Camera View Recording > off.

### Changed
- After a reconnect, a replug or a reopened window the picture no longer stays black. The background service keeps the last real keyframe the goggles sent (they send one only when Share Liveview starts) and starts every new window or decoder from it; the live frames then update it. Static content comes out exact (measured error 0.2 of 255 on a synthetic stream); with moving content ghosts of moving things stay (about 20 of 255) until you turn Share Liveview off and on, which sends a fresh keyframe and heals the picture. Not yet seen on real goggles.
- A goggles window that has lost its picture now says what actually fixes it: "No picture: turn Share Liveview off and on on the goggles" (menu bar, status pill, Operator Overview, phone status page). The goggles send a keyframe only when sharing starts, and nothing the app can send makes them send another.

### Fixed
- The app now waits 8 s (was 3 s) before reconnecting while it waits for a keyframe, so its reconnect no longer cuts off the stream the pipeline resumed on its own after 2.5 s.
- After a reconnect the goggles resume the video without a keyframe (they send one only when Share Liveview starts), so the picture stayed gone. If video has been arriving for 2.5 s with the parameter sets known but no keyframe, the pipeline now opens its gate anyway. A decoder that still holds the previous picture carries on from the next frames (possibly with artifacts); one that does not ignores them until a real keyframe. Seen on live goggles: the helper goes live 2.85 s after the first video packet. Not yet seen on screen with a live decoder.
- After a long silence (12 s was enough to make the goggles drop the session) the window showed "reconnecting" forever without ever reconnecting. A live stream that stays silent now makes the app reconnect by itself, with the same backoff as the keyframe recovery.
- The picture no longer stays gone after a short silence from the goggles. A 2 second gap in the video (a brief radio dropout; seen unattended after 9.5 minutes) re-armed the keyframe gate, which threw away every frame until a keyframe arrived, and the goggles send one keyframe only when Share Liveview starts, so the picture never came back by itself. A pause loses no frames, so the stream now simply continues; real frame loss still re-arms the gate. Checked on live goggles by freezing the helper for 6 s: it logged the stall and went straight back to live.
- Stabilization: on real footage about 3% of frames reported nonsense motion of 30 to 80% of the picture width (motion-blurred frames), which threw the whole correction off and made hard shake come out worse than it went in. Implausible motion is now ignored: on recorded hand shake the remaining shake dropped by about 80% at full strength (it was about 33%). The zoom that hides the edges is now adaptive: about 4% while the picture is steady, growing only when a correction needs the room and easing back afterwards, instead of a constant 8 to 25% crop.
- When frames were dropped, the app waited for a keyframe forever: its automatic recovery only ran while the background service said "live". It now also asks for a keyframe and reconnects while the service itself waits for one. Recovery is limited by the goggles: they send a keyframe only when Share Liveview starts, so switching it off and on again on the goggles is still the reliable fix.
- Several goggles at once: DJI goggles report the same placeholder USB serial (`987654321ABCDEF`), so every unit got the same device ID, window position and profile. The real serial number (the tail of the product name, for example `753XM567024TS7`) is now used, so each goggles has its own ID that stays the same after a replug. The window title and feed name read "Goggles 3 · 753XM567024TS7". Window positions saved under the old shared ID are reused once for the first goggles.

- The app restarts its own background service when it is older than the app: after replacing the app by hand, a DMG drag or `brew upgrade`, the old service kept running the old code until it was restarted from the terminal. The app now notices at launch (the service started before its file was installed) and restarts it, with no password or terminal command.

## [0.9.0] - 2026-10-10

### Added
- Operator overview (Goggles menu): one window with a row per open goggles (state, outputs sending, fps, battery, warnings), a Record button each, Start all / Stop all outputs, a big-tile view and full screen. While something records it also shows Stop all recordings and a free-disk line that warns when fewer than 3 hours are left.
- Warnings per feed: battery under 25% / 10%, a black picture for 10 s, a picture not changing for 15 s. They show on the overview, the program output tiles, the menu-bar icon and the web status page. Lost feeds pulse red on the program output, and the signal-lost alert names the feed.
- Status page for a phone (`/status` on the web viewer): one tile per goggles, read-only, no serial numbers.
- "Event" preset for several goggles over many hours: signal-lost alert on, clean video, no recording, no replay.
- SRT output can start automatically, like the UDP stream.

### Fixed
- When the signal drops (for example the air unit disconnects), the last picture now stays on screen, dimmed, under the "reconnecting" card. Before, it disappeared after 5 seconds.
- Program output no longer reopens its full screen windows at launch (they hid the normal window). Turn on "Open the program outputs when the app starts" in Settings > Display to get the old behaviour.
- Slow start after an update: when macOS refused to restart the background service, the app stopped and retried it on every launch. It now retries a few times within one launch and gives up after two launches, with a message in Settings. Run `defaults delete com.kburiasco.gogglesview updateHelperChanged` to clear an old stuck marker.

## [0.8.2] - 2026-10-10

### Added
- Several goggles at once: a separate SRT/UDP port per goggles window (window 1 keeps the configured port, the next windows add 1, 2, ...), and NDI source names with a number. On by default, switchable in Settings > Streaming > OBS Studio.
- "Add all feeds to OBS" (Settings > Streaming > OBS Studio): creates one Media Source per open goggles over the OBS WebSocket connection, pointing at that window's SRT or UDP output. Existing sources are updated, never deleted. Not checked against a real OBS yet.
- "Re-encode at 30 fps" (Settings > Streaming): halves the hardware encoder load of recordings and streams so more goggles fit on one Mac. Measured: 6 windows keep 52 fps with it, 27 fps without.
- A multi-goggles soak test (`GOGGLES_SOAK_FEEDS=6 GOGGLES_SOAK_SECONDS=600 swift test --filter MultiFeedSoak`) and `docs/events.md` capacity table.
- Program output (Settings > Display, Goggles menu): up to four clean full screen outputs, each on its own display (for example one HDMI per feed into a vision mixer, or a multiview). Either a grid of every open goggles feed with names and a NO SIGNAL marker, or one feed on its own. Feed names are chosen by you and never contain a serial number. See `docs/events.md`.
- Dutch. The app follows the macOS language: set macOS to Dutch and the interface appears in Dutch (791 strings, same scope as Italian and French). The translation is machine-assisted: corrections are welcome, see `docs/localization.md`.

## [0.8.1] - 2026-10-09

### Added
- Zebra stripes and focus peaking can be switched from automation: URL commands (`zebra/on|off|toggle`, `peaking/on|off|toggle`), AppleScript properties (`zebra stripes`, `focus peaking`) and two Shortcuts actions.
- `gvnet` (Tools/gvnet): an experimental command-line client for Linux and Windows (and macOS) that reads the goggles' liveview over a network interface and writes raw H.264 to a file, stdout or UDP. Tested against a fake goggles on loopback, CI builds, tests and loopback-runs it on Linux and Windows. Not yet tried on real goggles outside macOS. Prebuilt Linux (x86_64, arm64) and Windows binaries are attached to releases by CI. See `docs/linux-and-windows.md`.

### Fixed
- Zebra stripes and focus peaking no longer appear in the capture window (they are for the operator's preview only).
- OBS rules catch up when OBS connects: if the goggles are already live when the connection comes up, the scene is set and the recording starts, instead of the earlier event being lost.

### Developer
- CI builds and tests `gvnet` on Linux and Windows. `GogglesProtocol` builds on Linux; four of its tests need the `clean-start.gvcap` capture that is not in the repository and fail without it (also on macOS).

## [0.8.0] - 2026-10-08

### Added
- Zebra stripes and focus peaking (Settings > Display > Exposure and focus aids, and the Goggles menu). Stripes mark areas above a chosen brightness (50 to 100%, 100 means clipping); peaking colours sharp edges in red, green, yellow or white at low, medium or high sensitivity. Preview only: recordings, replays and streams are never changed. Analysed on a small copy of the frame about 15 times a second, so the cost does not grow with resolution. Race mode turns them off.
- French. The app follows the macOS language: set macOS to French and the interface appears in French (785 strings, same scope as Italian). The translation is machine-assisted: corrections are welcome, see `docs/localization.md`.

## [0.7.1] - 2026-10-08

### Added
- Italian. The app follows the macOS language: set macOS to Italian and menus, settings, alerts, toasts, notifications and error messages appear in Italian (769 strings). Developer tools (benchmark, self test, session log), the AppleScript dictionary, URL commands, Shortcuts action names, the web viewer page and log and diagnostics contents stay in English on purpose. The translation is machine-assisted: corrections are welcome. More languages are a matter of adding one folder, see `docs/localization.md` and `scripts/localization.py`.

### Developer
- `scripts/localization.py check` (also run as a unit test) fails on missing keys, extra keys, mismatched format placeholders and interpolated SwiftUI literals that would not localize. New user-facing text that is not a plain SwiftUI literal goes through `L("English text", args)`.


## [0.7.0] - 2026-10-08

### Added
- OBS Studio integration (Settings > Streaming > OBS Studio, over obs-websocket v5): optionally start OBS recording when the goggles go live and stop it after a grace period when the signal is lost, switch OBS scenes on live and lost, and stop OBS when you stop your own recording. Every rule is off by default, the WebSocket password is in the Keychain, and it only ever stops a recording it started. See `docs/obs.md`.
- Automatic markers while recording (Settings > Recording, on by default): signal lost and restored, goggles battery low, replay saved, screenshot taken, race mode on and off. The same debounced events as the hooks, no second detector, and duplicates within 2 s are dropped. Auto markers show in cyan on the trim timeline.
- Markers become real chapters: when a recording with markers stops, the file is rewritten without re-encoding so QuickTime, editors and `ffprobe -show_chapters` list them. The original is replaced only after the copy verifies (plays, same duration, same chapter titles); any failure leaves it untouched. The `.markers.json` file stays the source of truth. Trimming keeps the markers inside the cut.
- A better web viewer for iPad and phone: a QR code and `.local` address in Settings, Bonjour discovery, full-screen playback, tap to freeze, a LIVE indicator with a "Back to live" button, automatic reconnect, and "Add to Home Screen" as a full-screen app. See `docs/web-viewer.md`.

### Changed
- The web viewer uses 1 second segments and starts closer to the live edge: expect roughly 3 to 5 s behind live instead of 4 to 8 s (not yet measured on hardware).
- `NSAllowsLocalNetworking` is set so OBS can be reached on your local network over `ws://`.

### Known limits
- OBS rules act only on live and lost events that happen while OBS is connected; start OBS first. Chapters are added when a recording stops, so a crash leaves the video without chapters (the sidecar still has the markers), and stopping a very large recording takes a few seconds longer.
- None of the new features has been tried against real OBS, a real iPad or in QuickTime and editors yet, and the earlier list still stands: unplug and replug, sleep and wake, the signal alert, RTMP and SRT outputs, the setup assistant flow and the Shortcuts actions.


## [0.6.2] - 2026-10-07

### Added
- An app icon. The app and its DMG had none, so the Dock and Finder showed the generic icon. The artwork is in `docs/images/app-icon.png`.
- Back up settings (Settings > General): export your preferences to one JSON file and import them on another Mac. Secrets and identifiers (stream keys, passphrases, tokens, webhook and script paths, goggles profiles, folder paths, window positions) are never exported, and switches that open the app to the network (web viewer, URL commands, automatic installs) are not imported.
- Troubleshooting card at the top of Settings > General with a one-line health state and buttons for the setup assistant, Reconnect, Connection health and diagnostics. Benchmark, self test and session log moved under "Developer tools" in Settings > Advanced.

### Changed
- Saving an instant replay (menu bar, hotkey, AppleScript, Shortcuts, `gogglesview://replay/save`) now says why when it can't: "Instant replay is off. Turn it on in Settings > Recording.", the keyframe encoder message, or "The replay buffer is still filling." It used to do nothing without saying so.
- Plainer captions for live stabilization, color looks, output framing, RTMP, NDI and the web viewer ("Off by default. Anyone on your network can watch while it is on."), and a friendlier empty clip gallery.
- The color look on the preview updates as soon as you change it, without resizing or reopening the window.

### Known limits
- Not yet tried on live goggles: unplug and replug, sleep and wake, the signal alert, RTMP and SRT outputs, the setup assistant flow and the Shortcuts actions.


## [0.6.1] - 2026-10-07

Found during the first run of 0.6 on real goggles with a drone linked.

### Fixed
- The background service was not restarted after an update. The "service changed" marker was stored with a leading "v" and compared without it, so an updated app kept talking to the old service until you re-registered it by hand. Both forms now match.
- Recordings, replay and streams made from the re-encoded stream repeated pictures: a source of about 35 frames per second came out as about 60, with roughly 45% duplicate frames (wasted bitrate and CPU). The encoder's own access to a picture made it look new. New pictures are now counted as they are decoded.
- The recorder treated a sample that held only an SEI or access-unit-delimiter NAL as a keyframe, which would start a file with undecodable data. Such samples are no longer keyframes.

### Added
- The first-stream and capture-window notice now explains the display-scale tip: with the goggles' display scale at about 70%, the picture sits inside the overlay frame and a centred crop of about 1.4x removes the overlay while the uncropped original keeps the data.
- README and website explain the goggles' overlay and the 70% picture, with an annotated frame from real goggles. `docs/hardware-testing.md` is a tick-box sheet for a real-goggles pass, including a telemetry capture.

### Developer
- The doc-shot flags accept `GOGGLESVIEW_DOC_PICTURE=/path/frame.png` to render a window around a real frame. The fake-goggles integration tests run in CI except the slow ones (`GOGGLES_SKIP_SLOW_TESTS=1`).

### Known limits
- Still not tried on live goggles: unplug and replug, sleep and wake, the signal alert, RTMP and SRT outputs, the setup assistant flow and the Shortcuts actions.


## [0.6.0] - 2026-10-07

### Added
- Setup assistant: replaces the Welcome window with four live checks (background service approved, goggles seen on USB, OTG and cable, video arriving), one plain sentence and one button each. It updates without a restart, opens on first launch, and is offered from Help, Settings, the menu bar and every failure screen.
- Signal-lost alert: a notification and an optional repeating sound when video stops for a few seconds, with a "restored" alert once it has been back for 2 s. Works with the window hidden. Settings > Advanced.
- Clip gallery search and tags: search by file name, note, tag or goggles (⌘F), filter by date, goggles and favourites, five sort orders, tags, a note and a star per clip, multi-select with bulk tagging and trash. Tags are stored in a `.gvmeta.json` file next to each clip. Recordings now note the goggles name and serial.
- Shortcuts actions (App Intents): start, stop and toggle recording, save replay, screenshot, add marker, start and stop the network stream, toggle freeze, show window, and get status. Needs the app installed in /Applications; plain `swift run` builds have no actions.
- Race mode: one switch (Settings > Display, Goggles menu, menu bar, `gogglesview://race/on`) that turns off the stabilizer, preview color looks, grid, stats overlay and mini window for the lowest-latency preview. A RACE badge shows while it is on.
- Connection health window (Goggles > Connection Health…): frames per second, bitrate, frame gaps, drops, decode latency and a verdict with practical suggestions for cable, port and OTG problems. Collects nothing while closed.
- Copy frame (⇧⌘C, menu bar, `gogglesview://screenshot/copy`, AppleScript `copy frame`) puts the current picture on the clipboard. The screenshot note has a Show in Finder link.
- A one-time notice the first time you start a stream (UDP, RTMP, SRT, NDI or the web viewer) or turn on the capture window: the goggles draw their own overlay (flight data, battery, storage warnings) into the picture, so it also shows up in OBS, recordings and streams. It offers to open Output framing (or Framing for the capture window) to crop it out.
- Recordings are crash-safe: files are written in 2 s fragments, so a crash, force-quit, power loss or unplugged drive leaves a playable file. Recording failures now show a plain-language alert, a "Saved to…" note with Show in Finder appears when a recording stops, and recording stops cleanly when free space drops below 500 MB.

### Changed
- Plain-language wording throughout: "Connecting to your goggles…" replaces claim, RNDIS and handshaking text; "background service" replaces "helper"; the window's Close button is now Hide, and closing the window while recording or streaming asks what to do; Retry, Copy diagnostics and Open setup assistant appear on every failure screen.
- `gogglesview://` URL commands are off by default (Settings > Advanced > Automation) because any web page could trigger them. When on, each command shows a short on-screen notice and is limited to a few per second. AppleScript and Shortcuts are not affected.
- Instant replay needs the keyframe encoder and says so when it is off; the settings text shows the real window (about 107 s at 20 Mbps, not 120 s).
- Auto-delete skips files modified in the last 24 hours, never touches replay clips, asks before it is first turned on, and reports what it trashed. Loop recording says its old parts are permanently deleted.
- Recordings made while stabilization is on use the re-encoded stream so they contain the stabilized picture.
- RTMP and UDP streams reconnect automatically with backoff after a drop; RTMP also detects a stalled connection. The installer refuses to update while any output (RTMP, SRT, NDI, web viewer, replay save) is active.
- A failed update helper re-registration is shown in Settings and the setup assistant instead of being ignored.

### Fixed
- The app's silence watchdog never fired because the helper's once-a-second stats counted as activity; the connection state flapped between live and connecting during a real dropout and ran stream hooks and auto-start recordings falsely. Only video now counts, and hook events are debounced.
- A stuck decoder (after a dropped frame or reconnect) now asks the goggles for a new keyframe and reconnects if none arrives, and the waiting card is shown instead of a frozen picture.
- Output zoom was off-centre and panned to the wrong region; the transform is fixed.
- Sleep and wake: the Mac going to sleep drops a marker in a running recording and the app reconnects on wake; the app holds an activity assertion while recording or streaming so it is not throttled.
- A bounded queue between the helper and the main thread: if the main thread stalls, input is dropped to the next keyframe instead of growing without limit.
- Helper: a failed claim after replug, wake or a booting goggles is now retried with backoff instead of staying failed; repeated USB transfer errors stop the pipeline instead of looping; after silence or a dropped-frame burst the helper waits for a fresh keyframe; a window opened late gets the cached stream head so it shows a picture.
- Instant replay no longer empties itself when the keyframe encoder is off, and raw recordings can split or loop by switching to the re-encoded stream when no keyframe arrives.
- A slow disk no longer silently drops frames and corrupts a passthrough recording: it switches to the re-encoded stream and tells you.
- The network frame-rate counter restarted correctly after a helper reconnect.

### Security
- Updates are verified against the running app's designated code requirement (or its team requirement), the checksum is mandatory and computed on the exact file that is mounted, an ad-hoc signed app never auto-installs, and the work folder is cleaned up. The quarantine flag is no longer cleared.
- RTMP: fixed crashes on a hostile or buggy server (negative chunk size, deeply nested AMF, out-of-range stream id).
- Local web viewer: checks the Host header (blocks DNS rebinding), creates an access token automatically, refuses LAN mode without one, compares tokens in constant time and bounds its segment size.
- LUT import limits file size and rejects non-numeric data; hook script paths are stored in the Keychain and hooks run in their own process group that is killed on timeout; the developer screenshot flags need `GOGGLESVIEW_DEV_SHOTS=1` and no longer touch real preferences.

### Known limits
- Most of this is verified by tests and synthetic footage only. Keyframe recovery, sleep and wake, the signal alert and the Shortcuts actions have not yet been tried on live goggles.
- The setup assistant's USB detection and the Shortcuts discovery need a check on a real install.

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
