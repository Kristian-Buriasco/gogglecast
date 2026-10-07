# Hardware test sheet

A manual pass for a build before it is released, on a Mac with the goggles (and ideally the drone linked, so telemetry flows). It covers what the automated tests cannot: real USB, the helper, the goggles' own stream behaviour, sleep and wake. Tick each box; write down the build and what failed, with the diagnostics report (Settings > Advanced > Diagnostics > Copy).

Build under test: ______  Mac / macOS: ______  Goggles firmware: ______  Drone: ______

Useful: `log stream --predicate 'subsystem BEGINSWITH "com.kburiasco.gogglesview"' --info` in a terminal while testing. Automation helpers (AppleScript works with URL commands off): `osascript -e 'tell application "GogglesView" to get {goggles count, recording, fps, battery}'`.

## 1. First run
- [ ] Fresh install from the DMG into /Applications (or `brew install --cask`), right-click > Open.
- [ ] The setup assistant opens. Each step goes green by itself as you do it: approve the background service, connect the goggles, turn on OTG (unplug and replug), start Share Liveview.
- [ ] Unplug the cable: the USB step goes amber with the numbered OTG and cable hints. Replug: it goes green without a restart.
- [ ] Done opens the live window.

## 2. Live view
- [ ] Picture appears; fps close to 60; no visible stutter for 5 minutes.
- [ ] Stats overlay (Settings > Display) shows resolution, fps, bitrate, latency. Race mode on: overlay and badge behave, picture stays live.
- [ ] Hide the window (Hide button): stream keeps running; reopening from the menu bar is instant.
- [ ] Add Goggles… opens a second window of the same goggles without a grey picture (late joiner).
- [ ] Connection health window: verdict Healthy, graphs moving, Copy report works.

## 3. Recording
- [ ] Start recording from the window before the goggles' first keyframe (toggle Share Liveview, record at once): file plays, no grey start.
- [ ] Start recording mid-stream: file plays from the first frame.
- [ ] Stop: "Saved to …" note with Show in Finder.
- [ ] Force-quit the app during a recording: the file still plays up to about the last 2 seconds.
- [ ] Output framing 9:16, a LUT, stabilization on: recorded file has the crop, look and stabilized picture.
- [ ] Split every 1 minute and loop mode actually rotate (raw stream).
- [ ] Add a marker; it is in the `.markers.json`.

## 4. Replay, copy frame, screenshot
- [ ] Instant replay saves a playable clip that does not start grey (try it 30 s after starting, and after a window reopen).
- [ ] Screenshot saves a PNG; Show in Finder link works. Copy frame (⇧⌘C) pastes into Preview.

## 5. Outputs
- [ ] UDP to OBS Media Source (`udp://@:5000`): picture, no long grey start.
- [ ] RTMP to a local server (e.g. `nginx-rtmp` or MediaMTX): connects; kill the server, restart it: the app reconnects by itself.
- [ ] SRT caller and listener: picture appears; reconnect after a drop.
- [ ] Web viewer on a phone (LAN on, token): plays; a wrong token is refused.
- [ ] The first time any output starts, the overlay notice appears once; "Don't show again" sticks.

## 6. Failure and recovery
- [ ] Unplug USB mid-stream, wait 10 s, replug: video resumes by itself; the signal-lost alert fired once and "restored" once.
- [ ] Turn the goggles off and on: same.
- [ ] Turn the drone off (link lost) and on: the goggles' picture changes but the stream continues (note what the app shows).
- [ ] Toggle Share Liveview off and on on the goggles: the waiting card appears and clears.
- [ ] Sleep the Mac for 1 minute during a stream: on wake the app reconnects within a few seconds; a running recording has a "Mac went to sleep" marker.
- [ ] Recording with a nearly full disk (use a small disk image): clear alert, playable file.
- [ ] Quit and relaunch with the goggles still streaming: picks up within a few seconds.

## 7. Automation
- [ ] Settings > Advanced > Automation: URL commands are off by default; `open gogglesview://record/toggle` with them off shows the notice once; with them on it works and shows a toast.
- [ ] AppleScript `take screenshot`, `copy frame`, `start recording` work.
- [ ] Shortcuts.app lists GogglesView actions (needs the app in /Applications). Run "Get goggles status".
- [ ] Menu bar controls: Stop Recording, Save Replay, Screenshot, Freeze, Add Marker, Copy Frame, Race Mode.

## 8. Updates
- [ ] Settings > General > Updates > Check Now reports the right state. With a newer release available: install on quit works and the app comes back at the new version, the background service still approved.

## 9. Telemetry capture (for the future flight-data feature)
The goggles send about 10 packets per second of DUML telemetry next to the video. Capture a flight with the drone linked and armed (props off on the bench is fine, move the sticks):

1. Quit GogglesView and wait 6 seconds so the helper releases the goggles.
2. In a terminal (needs root): `cd Tools/gvcli && swift build && sudo .build/debug/gvcli stream --out /tmp/goggles.h264 --dump-telemetry /tmp/telemetry.jsonl --stats` and stop it with Ctrl-C after 60 seconds.
3. Keep `/tmp/telemetry.jsonl`. It contains the goggles serial and possibly GPS positions: do not post it publicly. See docs/telemetry-research.md for how to read it.
