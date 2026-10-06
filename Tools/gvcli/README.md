# gvcli

Task 1.7's Phase 1 exit-gate parity harness CLI. An SPM executable target
wiring `GogglesProtocol` (framing/wire-protocol/`FrameReassembler`) and
`GogglesUSB` (`RNDISTransport`) together into a runnable command-line tool.

```
gvcli info
    Connect over USB/RNDIS, print device info, exit. No video pipeline.

gvcli stream --out <path> [--stats]
    Live hardware. Requires root (sudo) to claim IF0/IF1 on macOS.

gvcli replay <capture-file> [--out <path>] [--stats]
    Offline path, driven by MockTransport over a .gvcap capture file.
    No root required.
```

See `docs/design.md` §9.2 for the parity-gate acceptance criteria this
tool exists to measure, and the original task notes (not kept in the repo)
for what has and hasn't been run/recorded so far.

Build/run:

```
cd Tools/gvcli
swift build
.build/debug/gvcli info
```
