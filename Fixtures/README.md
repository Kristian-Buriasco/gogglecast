# Fixtures

Capture corpus for offline (no-hardware) testing of the protocol core, per
design.md §9.1 and plan task 0.3.

## Status

- [x] `clean-start.gvcap` — clean start including SPS+IDR (23.5 MB, ~10 s
      captured after the IDR arrived)
- [x] `steady-state-60s.gvcap` — 60 s of mid-stream steady state (100 MB)
- [x] `unplug-mid-stream.gvcap` — deliberate USB unplug while streaming
      (12.9 MB) — capture ends in a `USBError: [Errno 19] No such device`,
      which is the expected/correct tail behavior for this scenario
- [x] `fragment-loss.gvcap` — a session with visible fragment loss
      (191 MB — ran longer than the intended ~45 s due to an unrelated
      shell/sudo delay while stopping it; not deliberately induced beyond
      ordinary session length, see note below)
- [x] `sps_pps.bin` — the raw 40-byte bundled SPS+PPS blob (`67 64 00 34
      ac 4d 00 f0 04 4f cb 35 01 01 01 40 00 00 03 00 40 00 00 1e 03 c7
      0c a8` + PPS `68 ee 3c b0`), extracted from `clean-start.gvcap` via
      `Tools/gen_sps_pps_fixture.py` — matches byte-for-byte an earlier
      independent manual capture of the same device's SPS/PPS, cross-
      confirming both the capture pipeline and the extraction script.

`Tools/gen_sps_pps_fixture.py` was originally tested only against synthetic
data (see the dji-goggles3-videoout repo's task-0.3 commit); it has now also
been run successfully against this real `clean-start.gvcap` capture.

**Note on fragment-loss.gvcap size:** at 191 MB this is the largest file in
the corpus by a wide margin (target was ~45 s of ordinary streaming; it
ended up closer to ~90 s because stopping it was delayed by an unrelated
sudo-auth issue, not a deliberate choice). Loss was not artificially
induced (no cable-wiggling, etc.) — whether it actually contains visible
fragment loss needs to be confirmed by whoever writes the Phase 1
reassembler tests against it (design §9.1 item 3); if it doesn't contain
loss, a shorter, deliberately-flaky-connection recapture may still be
needed. Flagging the file size here since it's large to keep committing to
git if a smaller capture would do just as well.

## Capture file format ("GVCAP001")

Produced by `stream.py --capture <file>` in the `dji-goggles3-videoout`
prototype repo (a separate repo from this one — not vendored here). The
flag is fully opt-in: default behavior of `stream.py` (no `--capture`) is
unchanged.

Every inbound (received from the goggles) and every outbound (sent to the
goggles) raw Ethernet frame on the RNDIS link is appended, in the order it
was seen/sent, with a host timestamp and a direction byte. Writes happen
off the hot RX/TX loop (queued to a background writer thread), so passing
`--capture` does not measurably disrupt real-time reassembly/output.

```
offset  size  field
0       8     magic, literal bytes "GVCAP001" (ASCII) — file header, once

-- then one of the following records, back to back, until EOF --

0       8     timestamp: float64, little-endian
              (time.time() when the frame was seen/sent — Unix epoch
              seconds, host clock)
8       1     direction: 0x00 = inbound (received from the goggles)
              0x01 = outbound (sent to the goggles)
9       4     frame_len: uint32, little-endian
13      N     raw Ethernet frame bytes, exactly frame_len bytes long —
              destination MAC, source MAC, ethertype, and payload, exactly
              as it crossed the RNDIS link (after RNDIS-unwrap on the way
              in / before RNDIS-wrap on the way out)
```

Each record is `13 + frame_len` bytes. There is no trailing footer or
index — a reader loops "read a 13-byte record header, then `frame_len`
more bytes" until EOF. This is deliberately simple (no compression, no
nesting) so a future Swift `MockTransport` can parse it directly: read the
8-byte magic once, then loop reading `Data(count: 13)` for the header
(`Double` timestamp + `UInt8` direction + `UInt32` length, all
little-endian — matches `Double`/`UInt8`/`UInt32` layout on Apple
platforms with `.littleEndian` conversions) followed by the frame bytes.

## How to record a capture

From the `dji-goggles3-videoout` prototype repo, with the goggles connected
over USB exactly as for a normal `stream.py` run:

```bash
python3 stream.py --capture /path/to/output.gvcap
```

Then copy the resulting file into this `Fixtures/` directory under one of
the names listed in Status above, and check it in.

**Before committing:** scrub the serial number. `stream.py` prints the
goggles' S/N to stdout at startup (not into the capture file itself — the
capture only contains Ethernet frame bytes, which do not carry the USB
serial), but double-check no capture accidentally contains the serial in
free-text form before committing. The MAC addresses and any embedded
device identifiers in the DUML/handshake payloads are fine to keep as-is;
they are not credentials.

## How the four sessions were recorded (kept for future re-recording)

All four sessions above are now recorded (see Status). Instructions below
are left in place in case the corpus ever needs re-recording (e.g. after a
firmware update, or if `fragment-loss.gvcap` turns out not to contain real
loss and needs a deliberate-flaky-connection retake).

All four use the same `--capture` invocation above; only what happens
during the session differs. Record with the goggles powered on, USB
connected, in the state `stream.py` normally expects.

1. **Clean start with SPS+IDR** (`clean-start.gvcap`) — start `stream.py
   --capture clean-start.gvcap` from a cold state (goggles just connected /
   liveview just enabled) and let it run through the handshake, the
   SPS+PPS parameter-set blob, and the first IDR frame, then a few seconds
   of steady playback. Stop with Ctrl-C. This is also the source capture
   for the SPS/PPS blob extraction below.

2. **60 s steady state** (`steady-state-60s.gvcap`) — start capturing once
   the stream is already flowing normally (past the initial IDR), let it
   run for 60 continuous seconds of ordinary playback, then stop.

3. **Unplug mid-stream** (`unplug-mid-stream.gvcap`) — start capturing
   during normal playback, then physically unplug the USB cable partway
   through (say goodbye to the RNDIS link cleanly failing), leave `stream.py`
   running for a few seconds afterward so the capture shows the tail
   behavior (retries / silence / whatever it actually does), then Ctrl-C.

4. **Visible fragment loss** (`fragment-loss.gvcap`) — capture a session
   where dropped/incomplete fragments are visible (e.g. flaky USB
   connection, a marginal cable, or moving the goggles/cable during
   capture to induce loss). The goal is a corpus that exercises the
   reassembler's "drop the frame and count it, don't merge" path
   (design.md §9.1 item 3). If nothing reliably induces loss, note in this
   file what was tried and ship what you get — some loss over a long
   session is normal.

After recording, extract the SPS/PPS fixture from capture #1:

```bash
python3 Tools/gen_sps_pps_fixture.py Fixtures/clean-start.gvcap Fixtures/sps_pps.bin
```

Then update the Status checklist above and remove this instructional
section (or leave it for future re-recording — your call).

## Device provenance

- **Product string:** `Goggles3-<serial, scrubbed>` (DJI Goggles 3)
- **Firmware:** `zv300 gl Ver.02`
- **bcdDevice:** `0x0504`
- **USB VID:PID:** `2ca3:0020`
- **Goggles RNDIS MAC:** rotates on every goggles reboot — do not treat any
  MAC seen in these captures as fixed. At capture time it was
  `6e:27:68:45:bf:4b`; a prior session the same evening saw
  `ca:3c:b4:8d:51:c3`. The `dji-goggles3-videoout` prototype's `stream.py`
  now resolves this live via ARP at startup (`resolve_goggles_mac()`)
  rather than hardcoding it, matching what Phase 1.6 does in Swift.
