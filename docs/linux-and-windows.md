# Linux and Windows (early, command line only)

GogglesView itself is a macOS app. For other systems there is `gvnet`, a small command-line client in `Tools/gvnet`. It speaks the goggles' liveview protocol (UDP port 9003) over a normal network interface and writes raw H.264 to a file, stdout or a UDP port. There is no window, no recording UI, no stabilizer: pipe it into a player or OBS.

**Status: experimental.** It builds and its tests pass on macOS and Linux, and it has been run end to end against a fake goggles (`Tools/gvnet/scripts/fake_goggles.py`) on loopback. It has **not** been run against real goggles on Linux or Windows yet. If you try it, please report what happened (issue or discussion), with the output of `ip addr` / `lsusb` on Linux.

## Why this can work without USB code

On macOS the system's RNDIS driver does not bring the goggles' USB link up, so the app speaks RNDIS itself over libusb. Linux ships an RNDIS driver (`rndis_host`) and Windows has a built-in RNDIS driver (some Windows 11 builds removed it; see below). If the goggles show up as a network interface, the protocol is just UDP to `192.168.60.2:9003`. The goggles' own Wi-Fi access point works the same way, with the goggles' Wi-Fi address.

## Linux

1. Build: `cd Tools/gvnet && swift build -c release` (Swift 5.10 or newer, from swift.org).
2. Goggles on, Share Liveview on, OTG enabled, connect over USB.
3. Find the new interface (`ip link`, usually `usb0` or `enx...`) and give it the host address:
   `sudo ip addr add 192.168.60.1/24 dev usb0 && sudo ip link set usb0 up`
4. Watch it: `.build/release/gvnet --host 192.168.60.2 --bind 192.168.60.1 --stats | ffplay -f h264 -fflags nobuffer -`
   or record: `gvnet --out flight.h264` (remux with `ffmpeg -f h264 -i flight.h264 -c copy flight.mp4`).

If no interface appears, run `dmesg | tail` after plugging in. If the kernel does not bind `rndis_host` to the goggles, that needs a libusb based fallback (a port of the macOS RNDIS transport); not written yet.

## Windows

Not tested. The same approach applies if Windows binds the goggles as a "Remote NDIS Compatible Device" and gives it a network adapter: set that adapter to `192.168.60.1/24` and run `gvnet.exe`. `gvnet` currently uses POSIX sockets, so it needs a small WinSock layer (`UDPSocket.swift`) and a Swift for Windows toolchain before it builds there. Windows 11 has removed the in-box RNDIS driver in some versions; then a driver such as the Linux-style `usb_rndis` or a WinUSB based client would be needed.

## What it does

Handshake and 2 s silence resend, cumulative window acks, fragment reassembly, and a keyframe gate: output starts at SPS+PPS+IDR. The goggles send one keyframe when Share Liveview starts, so start `gvnet` first, then toggle Share Liveview. Flags: `--host --bind --port --local-port --out FILE|-|udp://HOST:PORT --seconds N --stats`.

## Not included

Telemetry decoding, battery and goggles control (DUML over USB interface 4), recording extras, and everything else the Mac app does.
