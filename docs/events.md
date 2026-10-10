# Running GogglesView at an event

For several goggles on one Mac, with the picture going to a vision mixer, projector or TV over HDMI.

## Operator overview and event preset

- **Goggles > Operator Overview…** is one window with a row per open goggles: a colour dot (green fine, amber needs a look, red lost or critical), name, state, which outputs are sending (SRT, UDP, NDI; "(SRT)" means waiting for the receiver, "SRT!" an error), fps, battery and a Record button. Click a name to bring that window forward. **Big view** turns it into large coloured tiles, and the arrow button makes it full screen, for a screen the whole crew can read.
- **Start all outputs / Stop all outputs** start or stop the outputs ticked next to them (SRT by default) in every window at once.
- Warnings, shown on the overview, the program output grid, the web status page and the menu-bar icon: battery under 25% (amber) or 10% (red), a **black picture** for 10 seconds, a **picture not changing** for 15 seconds while frames keep arriving. A black or unchanging picture is only amber, since a covered camera or a still scene is the operator's call. The signal-lost alert, and the program output tile (a pulsing red frame and NO SIGNAL), use the name you gave the feed.
- The menu-bar icon is green, yellow or red for the worst feed, including these warnings; hover it for the details.
- While anything records, the header shows **Stop all recordings** and the bottom line shows the free space in the recordings folder, amber or red when fewer than 3 or 1 hours of recording are left (about 9 GB per hour per recording, so it warns early). Without recording none of that is shown.
- **Settings > General > Presets > Event** is for several goggles over many hours without recording: signal-lost alert on, clean video, no recording, no replay. Settings > Streaming has **Start automatically** for UDP and SRT so a goggles that reconnects starts sending again by itself.

## Status page for a phone

With the web viewer on (Settings > Streaming), open `http://<this Mac>:<port>/status` (add `?t=<token>` when a token is set, as for the viewer): one big tile per goggles, refreshed every 2 seconds, read-only. It shows names, state, fps, battery, warnings and outputs, never serial numbers or device ids.

## Program output (HDMI)

Settings > Display > **Program output (HDMI)**, or Goggles menu > Program Output.

- Shows a clean, borderless, full screen picture on the display you choose. Automatic picks the first external display and never covers your only screen; if you pick your main display on purpose, the output covers your controls (turn it off with Goggles menu > Program Output, which stays reachable if it is on another display; with a single display, use the keyboard shortcut for the menu or quit the app).
- **All feeds in a grid** shows every open goggles window as a tile (1, 2x1, 2x2, 3x2, 3x3, 4x3, 4x4, in the order the windows were opened) with its name, and marks a feed that has lost its signal with NO SIGNAL. Use it as a crew monitor.
- **One feed** shows a single picture with nothing drawn on it: a fixed goggles, or the one in the active window. Use it as the program picture.
- Feeds are named "Feed 1, Feed 2, ..." by default. Name them ("Runner 3", up to 24 characters) in the same card. Names never include the goggles serial number.
- Zebra stripes and focus peaking are never drawn on the program output or the capture window.
- Add up to four outputs, each on its own display and each with its own choice (a grid or one feed). That is the ATEM-style set-up: one HDMI per feed, or one multiview plus program feeds. Automatic gives each output the next free external display; two outputs never share a display. A Mac mini drives two displays directly; more need USB or Thunderbolt HDMI adapters.
- For OBS, each goggles window can show a Capture window (Settings > Display > Capture window) that OBS takes with Window Capture, one per feed.

## Several goggles on one Mac

Each goggles is one USB connection and one window. Use a powered USB hub and good cables, and test the exact set-up beforehand: it has not been soak-tested for many hours. Check Goggles > Connection Health for each window.

## Several goggles into OBS

- Settings > Streaming > OBS Studio: turn on **Separate port for each goggles window** (on by default). Window 1 uses the SRT/UDP port from Settings, window 2 the next port, and so on; NDI adds a number to the source name ("GogglesView 2"). The first window behaves exactly as before.
- Connect to OBS, pick a scene and SRT or UDP, press **Add all feeds to OBS**. It makes one Media Source per open goggles, named after the feed (rename feeds under Program output), pointing at that window's port. Press again after opening more goggles: existing sources are updated, never deleted. Then press the SRT or UDP button in each goggles window to start sending.
- With an SRT passphrase set the button refuses, because the passphrase would be written into OBS. Clear it or add the sources by hand.
- The Media Source settings are standard but have not been checked against a real OBS yet; if a source stays black, open its properties and check the URL.

## How many goggles one Mac can carry

Measured with software goggles (1080p60) on an M1 Pro, each window decoding, recording and sending UDP at once:

| Goggles | Re-encode on (default) | Re-encode at 30 fps | Re-encode off |
|--------:|-----------------------:|--------------------:|--------------:|
| 1 | 60 fps | 60 fps | 60 fps |
| 2 | 59 fps | 60 fps | 60 fps |
| 3 | 47 fps | 60 fps | 60 fps |
| 4 | 37 fps | 60 fps | 60 fps |
| 6 | 27 fps | 52 fps | 60 fps |

The numbers are the frame rate each window keeps decoding. Recordings and streams run at that rate (half of it with the 30 fps option). Memory stayed flat over 5 minutes with 6 windows recording and sending.

Recordings, streams, replay and the web viewer need a keyframe, which the goggles only send once, so GogglesView re-encodes each window's picture with a hardware encoder (Settings > Streaming > Keyframes). That encoder is the limit: about 150 encoded frames per second in total on this Mac, so 2 goggles at 60 fps, or 5 at 30 fps. **Re-encode at 30 fps** in the same card halves the load. Re-encode off removes the limit, but then a recording or an OBS source that starts after the goggles' one keyframe stays grey, so it only works if every output is started before Share Liveview.

For OBS feeds, plan for 2 goggles at 60 fps or up to 5 at 30 fps per Mac like this one, or one Mac per two goggles. Chips with more encoders (Max, Ultra) should do better but are untested. These are software numbers: check them with the real goggles.

## A long run

- Keep the Mac on power and awake: GogglesView prevents idle sleep while recording or streaming.
- Recording > split every N minutes, with enough free disk (about 5 GB per hour per goggles at default bitrate; the app warns before the disk is full).
- Turn on the signal-lost alert so you hear when a feed drops.
- Do a full dry run the day before with all goggles and the real HDMI chain.
