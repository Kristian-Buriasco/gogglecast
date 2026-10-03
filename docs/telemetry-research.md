# Telemetry research: what the type-0x01 packets carry

Status: **research only, no hardware capture analysed yet.** Nothing here is
confirmed on Goggles 3 traffic. Everything in the "candidate messages"
section comes from older DJI products. The tooling below is there to settle
that with one capture session.

## TL;DR

- Besides video (type 0x02), the goggles send **type-0x01 packets at about 10 Hz** on
  UDP 9003, plus **one type 0x00** (the handshake reply). Per the public RE
  docs, type 0x01 is *"telemetry data encapsulated in the DJI MB protocol"*,
  which is DUML, the same `0x55 …` framing as `DUML.swift`.
- The docs give the **container** layout: window state, then a length, then one or
  more DUML frames. They do **not** say which DUML messages a given product
  pushes, or how the messages are laid out on Goggles 3 / O4-era firmware.
- New: `gvcli stream|replay --dump-telemetry <file.jsonl>`. It writes one JSON
  line per inbound non-video packet: full hex, outer header, window fields,
  where the DUML starts, whether the documented length prefix matches, and every
  CRC-valid DUML frame (addresses, cmd set/id, names, payload hex). For a
  handful of legacy messages it also adds a typed decode.
- Side finding (needs testing): our outbound type-0x01 I-frame request probably
  has the wrong container offset for a host→goggles packet, and type 0x01 is
  documented as **drone→app only**. That could be why `02:B3` never worked. The
  documented app→drone DUML channels are type 0x05 and the **tail of the
  0x04/0x06 ack**, whose last field is an MB-payload length. Our `ackTail`
  already ends with that length (`00 00`). See "Sending DUML" below.

## Sources

| Source | What it gives | Applies to |
|---|---|---|
| samuelsadok/dji_protocol `udp_protocol.md` | UDP 9003 packet types, the 0x01/0x03/0x04/0x05/0x06 container layouts, flow control | Mavic Pro over WiFi/RNDIS (2016). Our video path already matches it, so the framing transfers |
| same repo, `usb_mobile_protocol.md` | Two **real Goggles N3** DUML frames (00:99 and 00:88). Used as test vectors | Goggles N3 + O4 Air Unit Pro (2024–25) |
| same repo, `mb_protocol.md` | Stub that points to o-gs and push-force.dev | n/a |
| o-gs/dji-firmware-tools `comm_dissector/wireshark/*.lua` (GPLv3; names and layouts summarised here, not copied) | Device-type names, cmd-set names, command names, payload layouts for OSD general, RC push, battery, HD-link | P3/Mavic/Spark-era firmware |
| `~/PycharmProjects/dji-goggles3-videoout/FINDINGS.md`, `duml-commands.md` | Our own IF4 observations, the DUML address mesh, 416 command IDs pulled from DJI Fly's `libdjisdk_jni.so` symbols | **This goggles unit** (`zv300 gl Ver.02`) |

## What is documented about the UDP container (udp_protocol.md)

All integers are little-endian. Body offsets below start after the 8-byte outer
header (`WireProtocol.ParsedOuter.body`).

**Type 0x01, drone→app, 10 Hz, "telemetry in DJI MB protocol":**

| body offset | field |
|---|---|
| 0–1 / 2–3 / 4–5 / 6–7 | type-2 (video) send window start / end / resend-state-1 / resend-state-2 |
| 8–15 | the same four fields for type 3 |
| 16–17 / 18–19 | type-5 *receive* window start / end (acks our commands) |
| 20 … X−1 | type-5 resend-request list, `2 + 2·N` bytes (N sequence numbers) |
| X … X+1 | total length of the remaining MB payload |
| X+2 … end | one or more DUML frames |

With an empty resend list, X = 22 and **DUML starts at body 24**. The `[proto]`
`gwin=` parse in `PipelineState.noteInbound` (body 0..7) already matches rows
1–4.

**Type 0x00 handshake.** The reply on Mavic is 8 bytes (header only). The request
body starts with a u16 seed for the type-2 and type-5 sequence numbers
(`d0 e9` = 0xE9D0, matching our `handshakeBody`). The rest is unknown.

**Type 0x03, drone→app, rare and acknowledged.** Body 0–7 is the type-3 window, 8 is
a counter, 9–11 are `01 00 00`, and DUML starts at body 12. Only file-transfer
(00:27) was ever seen in it.

**Type 0x04/0x06 ack (app→drone).** Type-2 receive window and resend list, then
the type-3 receive window and list, then the type-5 send window (4×u16), then a
**u16 MB length followed by DUML frames**. The official app sent App(0x02)→HD-link
ground frames this way. Byte for byte, our 18-byte `ackTail` is exactly this
structure with empty lists, and it ends in `00 00`, which is "0 bytes of MB
payload".

**Type 0x05, app→drone command channel, acknowledged.** Body 0–7 is the type-5
window, 8 is a counter, 9–11 are `01 00 00`, and DUML starts at body 12.

### Unknown or inconsistent

- The prototype's `build_telemetry_with_duml`, which we ported as
  `WireProtocol.buildTelemetryWithDUML`, puts 24 zero bytes, then the length,
  then DUML at **body 26**. The doc layout puts DUML at **body 24**. The dump
  records `duml_offset` and `duml_len_prefix_ok` on every packet, so one capture
  settles which layout the goggles use.
- No document says whether Goggles 3 type-0x01 packets carry *any* DUML when no
  app has subscribed to anything. FINDINGS.md P1/P2 saw IF4 (USB vendor
  interface) carry only a 1 Hz `00:82` heartbeat unless the host drove it.
  Type 0x01 could also turn out to be bare window state, which would be about
  24–26 bytes of body.
- None of the type-0x00 body past the seed is understood.

## DUML recap (what the decoder reports)

- Frame: `55 | len(10b)+ver(6b) | crc8 | src | dst | seq u16 | cmd_type | cmd_set | cmd_id | payload | crc16`.
  CRC seeds are 0x77 and 0x3692 (`WireProtocol`).
- **Address byte:** low 5 bits are the device type and high 3 bits are the index
  (`Telemetry.addressName`). On this unit, FINDINGS.md P4 found: goggles
  `0xBC`/`0x3C` (`zv300 gl Ver.02`), air unit `0x09`/`0x29` (`za530 uav`), RC
  `0x0E`/`0x2E`, radio link `0x6E` (`zv300 gfsk`), plus `0x1C`, `0x1F`, `0x59`,
  `0x8E`, `0x9C`. Our host speaks as `0x2A` (pc#1).
- **cmd_type byte:** bit 7 is response, bits 5–6 are the ack type (0 none,
  1 push/ack-before, 2 ack-after), and bits 0–3 are the encryption type. **If
  encrypt ≠ 0, the payload is ciphertext**, so don't try to decode it.
- The two real N3 frames in `usb_mobile_protocol.md` validate with our CRCs. The
  doc's "DUML CRC16" column (`92 3a`, `34 18`) is actually trailing bytes. The
  real CRC is the last two bytes of the doc's payload column.

## Candidate telemetry messages

Confidence key: **documented** means in udp_protocol.md (Mavic). **legacy**
means the o-gs dissector layout for P3/Mavic/Spark. **observed** means seen on
this unit. **speculative** means a guess. The typed decoders in
`Packages/GogglesProtocol/Sources/GogglesProtocol/Telemetry.swift` cover the
rows marked ✓. They key on cmd set/id plus an exact payload size and are
**unverified on Goggles 3**.

| set:id | name | carries | confidence | decoder |
|---|---|---|---|---|
| 03:43 | FC OSD General Data push (~10 Hz on Mavic) | lon/lat (f64 **radians**), rel. height int16 0.1 m, vx/vy/vz int16 0.1 m/s, pitch/roll/yaw int16 0.1°, flight mode (byte 30 & 0x7F), controller state u32@32, GPS sats u8@36, **battery % u8@40**, product type u8@48; 50 or 55 bytes | legacy | ✓ `fc_osd_general` |
| 09:01 | HD-link OSD General | same struct as 03:43 (the dissector reuses it) | legacy | ✓ (same) |
| 03:44 / 09:02 | OSD Home Point | home lon/lat f64 rad, alt f32, home-state flags, go-home height | legacy | ✗ (raw only) |
| 09:08 | HD-link VT Signal Quality push | 1 byte; low 7 bits = **uplink signal quality** | legacy | ✓ `hd_link_vt_signal_quality` |
| 09:24 / 09:25 | HD-link SDR UAV/Gnd RT Status push | N × (8-byte ASCII name + f32), self-describing link stats | legacy | ✓ `hd_link_sdr_rt_status` |
| 09:11, 09:30, 09:3b, 09:37 | WL env quality, wireless env state (interference enums), tip-interference, abnormal event | link-quality warnings shown as OSD toasts | legacy | ✗ |
| 09:22 / 09:36 | SDR DL auto VT info (NF, band, MCS f32) / liveview rate ind | bitrate/MCS | legacy | ✗ |
| 09:52 | HD-link power status push | radio power state | legacy | ✗ |
| 06:05 | RC Parameter push | aileron/elevator/throttle/rudder u16 (364..1684, centre 1024), gyro, wheel, buttons; 13–14 bytes | legacy | ✓ `rc_push_param` |
| 06:51 | RC Push To Glass | RC→goggles custom-button status | legacy, name suggests goggles | ✗ |
| 0D:02 | Battery dynamic data | voltage mV u32, current mA i32, full/remaining mAh, temp, cells, **SoC %** | legacy (dissector notes a 1- or 2-byte prefix ambiguity) | ✓ `battery_dynamic` |
| 0D:03 | Battery cell voltages | per-cell mV | legacy | ✗ |
| 04:05 | Gimbal params push | gimbal attitude | legacy | ✗ |
| 02:80 | Camera state info push | SD/recording state | legacy | ✗ |
| 00:0E | Heartbeat / log message | sometimes FC text | legacy | ASCII runs |
| 00:82 | goggles→app status (`ZV300` + status), 1 Hz on IF4 | goggles heartbeat | **observed** (IF4, not yet on UDP) | ASCII runs |
| 00:99 | `united_pub_sub_agent` (DJI Fly symbol) | **topic-based pub/sub** (topic strings such as `camcap_common`) | observed on N3 (host→goggles) | ASCII runs |
| 00:88 | query device information | `"APP"` registration | observed on N3 | ✗ |

**Main hypothesis for O4-era gear:** newer DJI firmware moved much of its
telemetry onto the **00:99 pub/sub agent**, with named topics, and away from the
fixed legacy pushes above. If the capture shows 00:99 frames with ASCII topic
names (the dump lists them under `decoded.kind = "ascii_strings"`), the field
layouts will be per topic and must be worked out empirically. In that case the
legacy decoders will simply never fire, which is harmless.

## Sending DUML (for later, if telemetry has to be subscribed to)

According to the docs, an app sends DUML to the drone in two ways:

1. The **ack tail**: `ackTail`'s last two bytes are the MB-payload length. Set
   them to `len(frames)` and append the frames. The official app sent up to two
   App→HD-link-gnd frames per ack this way.
2. **Type 0x05**: an 8-byte type-5 window, a counter, `01 00 00`, then DUML. These
   packets are acknowledged through the type-5 receive window in the goggles'
   type-0x01 packets, at body 16..19.

Our current `requestIFrameTelemetry` sends a **type 0x01** packet. The doc lists
type 0x01 as drone→app only, which may be why `02:B3` "is non-functional today"
(design §8.1). This is a cheap experiment, but it is **not** done here: it would
change the video path's outbound traffic.

## Tooling added

- `Packages/GogglesProtocol/Sources/GogglesProtocol/Telemetry.swift` contains:
  - a silent, CRC-validated DUML scan (`scanFrames`, which needs both CRCs)
  - type-0x01 body analysis (`analyzeBody`)
  - address, cmd-type, cmd-set and command names
  - the legacy typed decoders listed above

  Tests are in `Tests/GogglesProtocolTests/TelemetryTests.swift`, using the real
  N3 vectors plus synthetic frames.
- `Tools/gvcli/Sources/GogglesPipeline/TelemetryDump.swift`:
  `TelemetryRecord` (the JSON schema) and `TelemetryDumpWriter`, which appends
  synchronously so nothing is lost on Ctrl-C. Tests are in
  `Tests/GogglesPipelineTests/TelemetryDumpTests.swift`.
- `gvcli stream … --dump-telemetry <path>` and `gvcli replay <cap> … --dump-telemetry <path>`.
  The file is opened in append mode. Every inbound packet **except type 0x02**
  is dumped. With `--stats` there is an extra `[telem]` line per second, for
  example `pkts=10 lines=123 {09>2a 09:08 x10, …}`, which lets you watch messages
  appear or disappear live while you poke at things. Default behaviour without
  the flag is unchanged.
- `Tools/gvcli/scripts/telem_summary.py` produces the inventory, the per-byte
  variability for one command, and field time series.

### JSON line schema

```json
{"t":1696000000.123,"type":1,"seq":4136,"session":4660,"len":58,
 "payload_hex":"3a80…","windows":[59856,59872,0,0,…],
 "duml_offset":24,"duml_len_prefix":26,"duml_len_prefix_ok":true,"duml_unparsed_tail":0,
 "duml":[{"off":24,"ver":1,"src":"09","src_name":"hd_link_air#0","dst":"2a","dst_name":"pc#1",
          "seq":812,"cmd_type":"00","is_response":false,"ack":0,"encrypt":0,
          "cmd":"09:08","set_name":"hd_link","name":"hd_link.vt_signal_quality_push",
          "payload_len":1,"payload_hex":"5c",
          "decoded":{"kind":"hd_link_vt_signal_quality","confidence":"legacy-layout, unverified on Goggles 3",
                     "fields":{"upSignalQuality":92,"rawByte":92}}}]}
```

(The values above are illustrative, not captured.) `t` is host Unix time.
`payload_hex` is the whole UDP payload, outer header included. A NaN or inf
produced by decoding garbage is written as a string.

## Capture plan

Setup (once):

```bash
cd ~/XcodeProjects/GogglesView/Tools/gvcli
swift build -c release
mkdir -p ~/telem && cd ~/XcodeProjects/GogglesView/Tools/gvcli
```

Keep an event log in a **second terminal** so actions can be lined up with `t`.
Type a label and press Enter at each action:

```bash
while read -r l; do echo "$(date +%s) $l"; done >> ~/telem/notes.txt
```

For each session, run the command and stop it with **Ctrl-C** after the stated
time. `sudo` creates root-owned files, so run `sudo chown $USER ~/telem/*` at
the end. Note what the goggles' own OSD shows (battery %, voltage, signal bars,
altitude, distance, sats) at the start and end of each session.

| # | Setup | Duration | Command (output names differ per session) |
|---|---|---|---|
| A | Goggles only, **air unit or drone powered off** | 60 s | `sudo .build/release/gvcli stream --out /tmp/A.h264 --dump-telemetry ~/telem/A-nodrone.jsonl --stats 2>&1 \| tee ~/telem/A.log` |
| B | Drone linked, on the ground, **props off**, motors off, sticks centred, no touching | 60 s | `… --out /tmp/B.h264 --dump-telemetry ~/telem/B-idle.jsonl --stats 2>&1 \| tee ~/telem/B.log` |
| C | Like B, but move the sticks one at a time, about 5 s each, logging each in notes.txt: throttle full up, then full down; yaw full left, then right; pitch full fwd, then back; roll full left, then right; centre; press each RC button once; scroll the gimbal wheel | 90 s | `… --dump-telemetry ~/telem/C-sticks.jsonl …` |
| D | Like B. Tilt and rotate the **drone by hand** (pitch, roll, a 360° yaw), then lift it about 1 m and put it down | 60 s | `… --dump-telemetry ~/telem/D-attitude.jsonl …` |
| E | Like B. After 20 s, cover or shield the air unit's antennas or move the drone behind walls until the signal bars drop, then restore | 90 s | `… --dump-telemetry ~/telem/E-link.jsonl …` |
| F | Like B, left idle long enough for the battery % shown in the goggles to drop by at least 1–2 % | 10 min | `… --dump-telemetry ~/telem/F-battery.jsonl …` (add `--out /dev/null` if disk matters) |
| G (optional) | Outdoors with a GPS lock. Carry the drone (props off) about 20 m away and back, raise it over your head | 3 min | `… --dump-telemetry ~/telem/G-gps.jsonl …` |
| H (optional) | Offline: `replay` a `.gvcap` if you have one (none are checked in) | n/a | `.build/release/gvcli replay Fixtures/clean-start.gvcap --dump-telemetry ~/telem/H-replay.jsonl` (no sudo) |

Don't arm the motors, and keep the props off for everything above.

## How to analyse

1. **Settle the container.** In any file, run
   `python3 scripts/telem_summary.py ~/telem/B-idle.jsonl`. Look at the first
   lines:
   - "type-0x01 packets with no valid DUML frame" near 100% means type 0x01 is
     bare window state on this firmware. Look at `len` and `payload_hex`, then
     go to step 6.
   - `duml_len_prefix_ok: True` together with `duml_offset` 24 confirms the
     udp_protocol.md layout. An offset of 26 confirms the prototype's layout.
     Either way, update `WireProtocol.buildTelemetryWithDUML` and its doc comment.
2. **Inventory diff, A vs B.** Messages present only in B come from the air
   unit or FC (src `09`/`29`, `hd_link_air`, `flight_controller`). Messages in
   both come from the goggles or the link. Check `encrypt`: anything non-zero is
   ciphertext, so stop there.
3. **Localise fields.** For each cmd with a steady rate, run
   `telem_summary.py ~/telem/C-sticks.jsonl <cmd>` and compare the per-byte
   min/max/distinct against `B-idle`. Bytes that are constant in B but vary in C
   are stick- or button-driven. Look for u16 values swinging around 1024
   (±660), the legacy RC range. Then plot them with
   `telem_summary.py C-sticks.jsonl <cmd> --series <off>:u16 …` against
   notes.txt.
4. **Attitude and GPS (D, G).** Look for f64 pairs that decode to about ±π/180 ×
   your coordinates (radians), and for int16 values in 0.1° that track your hand
   motion. If 03:43 or 09:01 is present at 50 or 55 bytes, check its
   `decoded.fields` against the goggles' OSD.
5. **Battery and link (E, F).** Look for a byte that matches the goggles' OSD
   battery %, and for u32 values in the 10 000–26 000 range (pack mV) that fall
   slowly in F. In E, look for a byte or float that drops with the signal bars,
   and for 09:08 / 09:24 / 09:25 entries (named float stats), which are the
   strongest link-quality candidates.
6. **If nothing useful arrives unsolicited,** telemetry probably needs a
   subscription. The next experiment is to append a DUML frame through the
   ack-tail MB length, as in "Sending DUML", for example replaying the N3's 00:99
   `camcap_common` subscribe or a `00:01` version query to `0x09`. Then confirm
   a response shows up in the dump. That changes outbound traffic, so it belongs
   behind its own flag.
7. Record every confirmed field in this doc, moving it from legacy or
   speculative to **confirmed on zv300 fw Ver.02**. Only then promote it into a
   typed decoder that the app's OSD overlay may consume.

## Open questions

- Does type 0x01 on Goggles 3 carry DUML at all without a subscription?
- Is the MB-length field at body 22 (doc) or 24 (prototype)?
- Which address does FC or air-unit telemetry come from (`0x09`, `0x29`,
  `0x03`)? Is it routed to `0x2A`, to `0x02`, or broadcast?
- Is any payload encrypted (the cmd_type low nibble)?
- Do the ack-tail or type-0x05 channels accept host DUML (which would fix the I-frame request)?

## Capture A results (2026-10-03, first real capture)

Run: `gvcli stream --dump-telemetry` for ~35 s, video at 55-60 fps, 8.3 Mbps.
Whether a drone was linked during this run was not recorded; repeat with a
drone linked and sticks moving before drawing final conclusions.

- 376 type-0x01 packets plus one type-0x00 (~10 Hz).
- 338 of the 376 are 34-byte window-state packets (flow control only), no DUML.
- 38 (1 Hz) carry one DUML frame: `1b>02 cmd 07:94`, set "wifi", src `wifi_gnd`,
  31-byte payload that is identical every time and contains the goggles' serial
  as ASCII. A heartbeat, not telemetry.
- No signal quality, battery, GPS, or attitude messages appeared.
- Each video frame carries a 25-byte proprietary SEI (payload type 240). Byte 0
  is a counter; bytes 4, 9, 10 look high-entropy (checksum/timestamp?); bytes
  2, 6, 12 vary slowly; the rest is mostly constant. Without ground truth
  (known camera/OSD values per frame) it cannot be decoded; likely camera
  metadata, not flight telemetry.

Conclusion so far: this RNDIS/UDP:9003 transport appears to expose video plus a
heartbeat only. Real flight telemetry, if available at all, may live on the
other USB "mobile" transport described in `usb_mobile_protocol.md`, or only
reach the goggles' own OSD. Next: repeat the capture with a drone linked
(idle, then sticks moving) and diff against capture A; if still empty, stop
the telemetry phase and mark flight-log/overlay items in the roadmap as
blocked.

## Probe results (2026-10-03): DUML mesh over IF4

Following the lab notes (`dji-goggles3-videoout/FINDINGS.md`): the goggles'
vendor interface IF4 speaks DUML and relays it across the mesh, independent
of the RNDIS video interfaces. `Tools/telemetry-probe/telem_probe.py` sent ~50
read-only get/query commands to 10 addresses (no drone linked or unknown).

- Replying modules: goggles 0xBC/0x3C/0x1C/0x1F, gnd 0x8E, radio 0x6E, RC
  0x0E/0x2E. Nothing answered at the air unit (0x09/0x29) or any flight
  controller address.
- Useful static data: version strings, device info and build dates, RTC clock,
  RC firmware info (`06:79`), country code (`07:19`).
- Possibly live: `0D:02 smart_battery_get_dynamic_info` from 0x1C returned a
  payload ending in `0x64` (100), plausibly the goggles' battery percentage;
  layout not verified.
- Most other queries were rejected (`0xE0`); link SNR (`07:29`) and
  `00:97 link_monitor_request` were rejected by the goggles, so live link and
  flight telemetry needs either a subscription/registration step or a linked
  air unit.

Next: repeat with a drone linked; try subscription-style commands (`02:EB`,
`04:12`, `03:5B`, `51:2B app_conn_product_info`) and the app registration
sequence from the DJI Fly symbol table.
