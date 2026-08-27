# Fixtures

Capture corpus for offline (no-hardware) testing of the protocol core, per
design.md §9.1 and plan task 0.3. **As of this commit, no real captures
exist yet.** This README specifies the format and lists exactly what a
human with the goggles needs to record next.

## Status

- [ ] `clean-start.gvcap` — clean start including SPS+IDR
- [ ] `steady-state-60s.gvcap` — 60 s of mid-stream steady state
- [ ] `unplug-mid-stream.gvcap` — deliberate USB unplug while streaming
- [ ] `fragment-loss.gvcap` — a session with visible fragment loss
- [ ] `sps_pps.bin` — the raw ~40-byte bundled SPS+PPS blob, extracted from
      one of the above via `Tools/gen_sps_pps_fixture.py`

None of these are present yet. `Tools/gen_sps_pps_fixture.py` exists and is
tested against a synthetic (fabricated) capture — see that script's module
docstring and the dji-goggles3-videoout repo's task-0.3 commit for how it
was verified. It has **not** been run against real hardware data.

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

## Four sessions still needed (human, with hardware)

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

- **Firmware:** `zv300 gl Ver.02`
- **bcdDevice:** `<fill in from live device>` — `stream.py` prints this at
  startup (`USB ID: vvvv:pppp (bcdDevice 0xbbbb)`); copy the printed value
  here once a real capture session has been run. Not filled in yet because
  no live session has occurred as part of this task.
