# Running GogglesView at an event

For several goggles on one Mac, with the picture going to a vision mixer, projector or TV over HDMI.

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

## A long run

- Keep the Mac on power and awake: GogglesView prevents idle sleep while recording or streaming.
- Recording > split every N minutes, with enough free disk (about 5 GB per hour per goggles at default bitrate; the app warns before the disk is full).
- Turn on the signal-lost alert so you hear when a feed drops.
- Do a full dry run the day before with all goggles and the real HDMI chain.
