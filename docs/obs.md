# OBS Studio integration

GogglesView can talk to OBS Studio over OBS's built-in WebSocket server (OBS 28 or newer). It is off by default. When it is on, it can start and stop an OBS recording and switch scenes for you when your goggles go live or lose signal.

## 1. Turn on the WebSocket server in OBS

1. In OBS, open Tools > WebSocket Server Settings.
2. Tick "Enable WebSocket server". The default port is 4455.
3. Keep "Enable Authentication" on and click "Show Connect Info" to see or change the password.

## 2. Connect GogglesView

Open Settings > Streaming > OBS Studio and:

1. Turn on "Connect to OBS".
2. Enter the host (`127.0.0.1` if OBS runs on the same Mac), the port and the password.
3. Click "Test connection". You see the OBS version, or a plain message such as "Wrong WebSocket password" or "Couldn't reach OBS".

The password is stored in the macOS Keychain, not in the preferences file. While the integration is on, GogglesView reconnects by itself if OBS is closed and opened again. It stops retrying after a wrong password until you change the settings.

## 3. Use GogglesView as an OBS source

- Capture window: add a "Window Capture" (or "macOS Screen Capture" in window mode) source in OBS and pick the GogglesView capture window. Turn on the capture window in Settings > Display.
- UDP: turn on the network stream in Settings > Streaming, then add a "Media Source" in OBS with the UDP address GogglesView shows. Untick "Local file".
- NDI: turn on NDI output in Settings > Streaming (needs the NDI runtime and the OBS NDI plugin), then add an "NDI Source" in OBS.

## 4. What the rules do

Each rule is off until you switch it on. They only react to GogglesView changes (goggles live or lost, session disconnected, your own recording stopped). They never act on a timer of their own and never touch a recording you started in OBS yourself.

- Record in OBS while I'm live: when the goggles go live (the signal has been steady for a few seconds), GogglesView starts an OBS recording. If the signal is lost, it waits for the grace period (default 30 s, adjustable) and then stops the recording. If the signal comes back within the grace period, the recording just continues. If the goggles are unplugged or the window is closed, it stops right away. If OBS is already recording when you go live, GogglesView leaves it alone and will not stop it later.
- Switch OBS scenes: switches to the scene you choose when live and to another when lost. Pick "Leave unchanged" to skip one of them. The lists are filled from OBS when connected.
- Stop the OBS recording when I stop mine: when you stop GogglesView's own recording, the OBS recording that GogglesView started is stopped too.

If OBS is not reachable when something should happen, you see one message in the card and nothing is retried or queued.

## Privacy

GogglesView only connects to the host and port you enter. Nothing is sent anywhere else, and nothing is sent at all while "Connect to OBS" is off. If OBS is on another computer, the connection is plain `ws://` on your local network, so use a password and keep it on a network you trust.
