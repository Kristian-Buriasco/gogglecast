# Automation

GogglesView can be driven from outside the app through a `gogglesview://` URL scheme and an AppleScript dictionary. Both go through the same code path as the window buttons and global hotkeys (`Apps/GogglesView/Sources/GogglesView/Automation.swift`).

**Settings > Advanced > Automation > Allow automation** (on by default) is the master switch: when it is off, URLs are ignored and AppleScript commands fail with "Automation is turned off".

URL commands have a second switch, **Allow gogglesview:// URL commands**, which is **off by default**: any web page or app can open a `gogglesview://` link, so URL commands only run once you turn this on. While it is off, URLs are ignored; the first ignored command in each launch shows a short on-screen notice that says where to turn it on. While it is on, every URL command shows a brief on-screen notice, and at most 3 run per second (extras are dropped). AppleScript is not affected by this switch.

Commands act on the frontmost goggles window (the key window, else the most recently focused one). Add `?device=<serial>` (URL) or `device "<serial>"` (AppleScript) to target specific goggles; the goggles' device id also works. If no open window matches, nothing happens -- a command never falls back to a different device.

## URL scheme

| URL | Action |
|-----|--------|
| `gogglesview://record/start` | Start recording (only while live) |
| `gogglesview://record/stop` | Stop recording |
| `gogglesview://record/toggle` | Toggle recording |
| `gogglesview://replay/save` | Save the instant-replay buffer |
| `gogglesview://screenshot` | Take a screenshot |
| `gogglesview://freeze/toggle` | Freeze/unfreeze the live view |
| `gogglesview://marker` | Add a marker to the current recording; optional `?label=Lap%201` |
| `gogglesview://stream/start` | Start the UDP network stream |
| `gogglesview://stream/stop` | Stop the UDP network stream |
| `gogglesview://window/show` | Bring the goggles window (or the device picker) to the front |

```sh
open "gogglesview://record/toggle"
open "gogglesview://marker?label=Lap%202"
open "gogglesview://screenshot?device=1581F5FHC23B1234"
```

Security: the URL can only select one of the actions above. It never carries a file path, shell command or network host -- recordings go to the folder from Settings and the UDP stream uses the host/port from Settings. Unknown query parameters are ignored; anything malformed (unknown path, extra path components, credentials, ports, fragments, a bad `device` value) is dropped without doing anything. Marker labels are stripped of control characters and capped at 64 characters.

Settings > Advanced has a **Copy example** button that copies a ready-to-paste `open "gogglesview://..."` command.

## AppleScript

```applescript
tell application "GogglesView"
    start recording
    add marker label "Lap 1"
    take screenshot device "1581F5FHC23B1234"
    save replay
    toggle freeze
    stop recording
    log {goggles count, recording, battery, fps}
end tell
```

From the shell:

```sh
osascript -e 'tell application "GogglesView" to start recording'
osascript -e 'tell application "GogglesView" to get {goggles count, recording, battery, fps}'
```

Commands: `start recording`, `stop recording`, `save replay`, `take screenshot`, `toggle freeze`, `add marker [label text]`, each with an optional `device text`.

Read-only properties (of the frontmost goggles window): `goggles count` (number of open goggles windows), `recording` (boolean), `battery` (percent, or `missing value`), `fps` (decoded fps, or `missing value`).

Errors: "No goggles window is open", "No open goggles match that device", "Invalid device identifier", "Automation is turned off".

The first time a script controls GogglesView, macOS asks whether the calling app (Terminal, Script Editor, Shortcuts...) may control GogglesView. Change this later in System Settings > Privacy & Security > Automation.

The dictionary is `Apps/GogglesView/BundleResources/GogglesView.sdef` (open it in Script Editor > File > Open Dictionary).

## Shortcuts

Use the URL scheme:

1. New shortcut > add the **Open URLs** action.
2. Set the URL to e.g. `gogglesview://record/toggle`.
3. Optionally give it a keyboard shortcut (shortcut details > Add Keyboard Shortcut) or add it to the menu bar.

Alternatively use the **Run AppleScript** action with any of the scripts above (this one can also read `recording`, `battery`, ...).

GogglesView has no native App Intents actions: the app is built with SwiftPM, which compiles but does not package App Intents metadata, so Shortcuts would not list them.

## Stream Deck / Raycast

- **Stream Deck**: use the built-in **System > Website** action with a `gogglesview://...` URL (untick "GET request in background"), or the **Open** action with a small shell script that runs `open "gogglesview://record/toggle"`.
- **Raycast**: create a Quicklink with the link `gogglesview://record/toggle` and open it with GogglesView, or a Script Command that runs `open "gogglesview://screenshot"` / `osascript -e '...'`.
- Anything that can open a URL or run a shell command works the same way (Alfred, BetterTouchTool, Keyboard Maestro, `cron`, hooks).

Global hotkeys (Settings > Advanced) cover recording, screenshot and replay without any extra tool.
