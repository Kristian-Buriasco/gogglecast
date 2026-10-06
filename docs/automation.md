# Automation

GogglesView can be driven from outside the app through a `gogglesview://` URL scheme and an AppleScript dictionary. Both go through the same code path as the window buttons and global hotkeys (`Apps/GogglesView/Sources/GogglesView/Automation.swift`).

Both are controlled by **Settings > Advanced > Automation > Allow automation** (on by default). When it is off, URLs are ignored and AppleScript commands fail with "Automation is turned off".

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

GogglesView ships native Shortcuts actions (App Intents, macOS 14+). In Shortcuts.app open the sidebar, choose **Apps > GogglesView** (or search the action list for "GogglesView"). They also work from Siri and Spotlight, e.g. "Start recording in GogglesView".

| Action | Result |
|--------|--------|
| Start Recording / Stop Recording / Toggle Recording | "Recording started" etc. |
| Save Instant Replay | Saves the replay buffer |
| Take Screenshot | Saves a screenshot |
| Add Marker | Optional **Label** (default "Marker") |
| Start Network Stream / Stop Network Stream | UDP stream using the host/port from Settings |
| Toggle Freeze | Freezes/unfreezes the live view |
| Show Goggles Window | Brings the window (or device picker) to the front |
| Get Goggles Status | Returns goggles count, recording, fps, battery (%) and a one-line summary; fps/battery are -1 when unknown |

Every action has an optional **Device** parameter (serial or device id, same as `?device=`). Actions run inside the app without opening a window, go through the same dispatcher and "Allow automation" switch as the URL scheme, and fail with a readable message when no goggles are live ("No goggles are live. Connect the goggles and open a GogglesView window first.") or automation is off. There is no copy-frame action here.

Feasibility notes: Shortcuts only lists actions from apps whose bundle contains `Contents/Resources/Metadata.appintents`. Xcode generates that at build time; plain SwiftPM does not. `Apps/GogglesView/build-stub-bundle.sh` therefore builds with `-emit-const-values` for the intent protocols and runs `appintentsmetadataprocessor` afterwards, copying the result into the bundle before signing (so `scripts/make-dmg.sh` bundles get it too). If the processor is missing the script prints a warning and the app still works, just without the Shortcuts actions. A plain `swift build` / `swift run` binary has no metadata, so no actions there. After installing a new build, Shortcuts may need a few seconds (or a relaunch of Shortcuts.app) to pick the app up.

Alternatives that always work, even without metadata: the **Open URLs** action with e.g. `gogglesview://record/toggle`, or **Run AppleScript** with any of the scripts above.

## Stream Deck / Raycast

- **Stream Deck**: use the Shortcuts support (the "Run Shortcut"/Shortcuts action in the Stream Deck app) to run a shortcut containing a GogglesView action, or use the built-in **System > Website** action with a `gogglesview://...` URL (untick "GET request in background"), or the **Open** action with a small shell script that runs `open "gogglesview://record/toggle"`.
- **Raycast**: create a Quicklink with the link `gogglesview://record/toggle` and open it with GogglesView, or a Script Command that runs `open "gogglesview://screenshot"` / `osascript -e '...'`.
- Anything that can open a URL or run a shell command works the same way (Alfred, BetterTouchTool, Keyboard Maestro, `cron`, hooks).

Global hotkeys (Settings > Advanced) cover recording, screenshot and replay without any extra tool.
