# Running GogglesView at an event

For several goggles on one Mac, with the picture going to a vision mixer, projector or TV over HDMI.

## Program output (HDMI)

Settings > Display > **Program output (HDMI)**, or Goggles menu > Program Output.

- Shows a clean, borderless, full screen picture on the display you choose. Automatic picks the first external display and never covers your only screen; if you pick your main display on purpose, the output covers your controls (turn it off from the menu bar item).
- **All feeds in a grid** shows every open goggles window as a tile (1, 2x1, 2x2, 3x2, 3x3, 4x3, 4x4, in the order the windows were opened) with its name, and marks a feed that has lost its signal with NO SIGNAL. Use it as a crew monitor.
- **One feed** shows a single picture with nothing drawn on it: a fixed goggles, or the one in the active window. Use it as the program picture.
- Feeds are named "Feed 1, Feed 2, ..." by default. Name them ("Runner 3", up to 24 characters) in the same card. Names never include the goggles serial number.
- Zebra stripes and focus peaking are never drawn on the program output or the capture window.
- One Mac can drive as many HDMI displays as it has outputs; the program output uses one of them. For several separate program pictures, use the Capture window per goggles with the mixer's window capture, or NDI/SRT.

## Several goggles on one Mac

Each goggles is one USB connection and one window. Use a powered USB hub and good cables, and test the exact set-up beforehand: it has not been soak-tested for many hours. Check Goggles > Connection Health for each window.

## A long run

- Keep the Mac on power and awake: GogglesView prevents idle sleep while recording or streaming.
- Recording > split every N minutes, with enough free disk (about 5 GB per hour per goggles at default bitrate; the app warns before the disk is full).
- Turn on the signal-lost alert so you hear when a feed drops.
- Do a full dry run the day before with all goggles and the real HDMI chain.
