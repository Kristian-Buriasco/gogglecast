# DJI Fly 1.21.12: app registration / telemetry subscription sequence (static analysis)

Status: static RE of `libsdk_jni.so` (DJI Fly 1.21.12, arm64). One item is cross-checked
byte-for-byte against a real capture (the N3 `00:88` frame in
`Packages/GogglesProtocol/Tests/GogglesProtocolTests/TelemetryTests.swift`). Everything else is
inferred and has **not** been tested on hardware yet. The test is
`Tools/telemetry-probe/telem_register.py`.

Companion table: `docs/dji-fly-1.21-duml-commands.md` (448 commands).

## TL;DR

1. **We have probably been using the wrong sender address.** DJI Fly speaks as **`0x02`** (app,
   index 0), not `0x2A` (pc, index 1). Two sources agree: both real N3 frames (`02>3C 00:88`, `02>28 00:99`),
   and the wifi heartbeat on UDP, which is addressed `1b>02`. Our probe round 2 also found that **a module answers
   at `0x2A` on the mesh**, so our frames claimed to come from an address another node
   already owns. This is the most likely reason almost every get came back `0xE0`, and why nothing is pushed to us.
2. **Registration = `00:88` "APP" device-info pack** (`AppInfoSyncLogic::RequestAppInfoRegister`,
   `DeviceRegisterLogic::SendRegisterPack`). The payload is recovered exactly (see below) and matches the N3 capture.
   Devices also *poll* the app with `00:88` (sub-command `0x19`), and the app answers with sub-command `0x1a`.
3. **Flight/link telemetry is NOT subscribed.** DJI Fly observes legacy V1 push packs passively
   (`fc_osd_push`, `fc_battery_push`, `radio_signal_push`, `linkquality_push`, `rc_*_push`,
   `wlm_dev_osd_push`, …). I found no subscribe command for any of them. The devices push to the
   registered app address once the app is known.
4. **The XRCE-DDS pub/sub (`00:99`) carries camera topics only.** All 51 topic names are `camcap_*`, `cam_*`, `pano_*`.
5. **iLink is not involved.** `libilink*.so` is Tencent's WeChat "iLink"/mars stack (mmtls,
   FaceRecognize, SRS live-push, cloud login). There are no drone/OSD/RSSI/battery messages. Telemetry is DUML V1
   over IF4 (and over the UDP:9003 type-0x01 channel on RNDIS). The per-product `lib*_proto.so`
   (wab520 = air unit WA520, etc.) are protobuf schemas for **media-file metadata** (ClipMetaHeader,
   FrameMeta, ISO, ExposureTime…), not link telemetry.

## Method and limits

- `libsdk_jni.so` is protected. The PT_DYNAMIC holds only NEEDED/SONAME. There is no dynsym and no relocations
  (GOT/vtables are zero on disk), and a small extra RX segment at the end is the unpacker stub. The code and
  `.rodata` are **plaintext**, though, and `.eh_frame_hdr` is intact. That gave 94k function boundaries.
- Tooling (scratchpad, not committed): section headers rebuilt so `xcrun llvm-objdump` works, an
  ADRP+ADD/LDR string-xref index, and a BL call graph. Functions were found through their
  `__PRETTY_FUNCTION__` log strings.
- **Can't resolve:** calls through the PLT (most intra-library calls in this build, because of default visibility),
  vtables, and `std::function` targets. So any value produced inside another exported
  function (some payload builders, the heartbeat cmd id) is unknown.

### `uav_cmd_req` header layout (inferred from about 10 send sites, consistent)

| offset | field | evidence |
|---|---|---|
| +2 | cmd_id | 0x88 (APP reg), 0x93 (wifi 07:93), 0x2B (51:2B), 0x01 (get_version sites) |
| +3 | cmd_set (usually set by the per-command ctor) | zeroed explicitly for 00:xx sends |
| +4 | ack mode: 0 = push/no ack (cmd_type 0x00), 3 = wants ack (cmd_type 0x40 in the N3 capture) | 51:2B uses 0, 00:88 uses 3 |
| +7 | receiver **type** | 0x1B, 0x07, 0x0E, 0x08, 0x1C… |
| via `SetReceiverIndex()` | receiver **index** (addr = index<<5 \| type) | APP reg copies the glass index, giving 0x3C in the N3 capture |
| +9 | is_response | 1 in the 00:88 reply path |
| +0x0C | seq echoed in a reply | reply path copies the incoming seq |
| +0x20 | payload buffer | |

## Sequence (confirmed vs inferred)

| # | Step | Frame | Confidence |
|---|---|---|---|
| 0 | Goggles push `00:82` "ZV300…" status at 1 Hz to `0x2A` on IF4 | observed | **confirmed (hardware)** |
| 1 | App learns the glass type/index (`GlassAbstraction`, `AbstractionManager::OnUpdateGlassType`) by reading versions: `00:01 get_version`, `00:FF get_device_info`, `00:51 fetch_serial_number` to the glass | gets | high (names); we already do these |
| 2 | **App registration**: `AppInfoSyncLogic::RequestAppInfoRegister(is_online)` → `00:88`, cmd_type 0x40, `02 → 3C` (glass type 0x1C, glass index) | `55 1b 04 75 02 3c <seq> 40 00 88 17 00 00 23 00 41 50 50 00 00 00 00 00 02 <crc>` | **confirmed** (static payload equals the real N3 capture byte for byte) |
| 2b | `DeviceRegisterLogic::SendRegisterPack` sends the same `00:88`/0x17 payload with receiver type 0 (router default) | same payload | high |
| 3 | Device → app `00:88` (cmd_type 0x40) whose payload starts `19 00`. The app replies **as a response** (is_response=1, same seq) with payload `1a 00 00 00 00` | reply frame cmd_type 0x80 \| ack bits | medium-high (static; our script answers if it sees one) |
| 4 | **App heartbeat**, `HeartbeatLogic`: 1000 ms repeating timer from `PostStart`. Body from `SetPackBody`: v1 = 2 bytes `[datalink_type, bg]` with bg = 0x40 if the app is backgrounded and no keep-active is requested, else 0. v2 (product heartbeat version == 2) = 4 bytes `[datalink_type, (state<<6 & 0xE0) \| 0x02, 0x01, need_keep_aircraft_active]`. Foreground, no keep-active: v1 `00 00`, v2 `00 02 01 00` | **cmd id unresolved**: sent via PLT `0x51694a0`. Candidates `00:0E` / `00:FE` (both typed `uav_general_heartbeat_req`). `datalink_type` for USB is unknown (0 if 0xFF) | body: high. cmd: low |
| 5 | Keep-active helper (`NotifyNeedAircraftKeepActive` storage): sends cmd id 0x00 (likely `00:00 ping`) with the caller's payload to `0x28` and `0x07` | not needed | medium |
| 6 | `51:2B app_conn_product_info` **push** (no ack) to wlm, receiver type 0x0E index 7 (`0xEE`) | payload from an unresolved builder | low. **Not sent** |
| 7 | `EE:07 app_running_state` / `EE:12 app_state_sync`. Only reached through key-value setters ("kAppRunningState setter for uav103", product 103 only) | payload unknown | low. **Not sent** |
| 8 | DDS (`00:99`) subscribe camera topics. N3 example `02 → 28`: payload `02 02 00 00 d5 07 00 00 00 00 00 13 00 0d 00 "camcap_common" 00 00 00 00` | replay of a real frame | confirmed frame (N3). Camera only |
| 9 | **Telemetry**: legacy push packs (FC OSD, battery, GPS SNR, radio signal, link quality, RC OSD, glass state) arrive unsolicited at the app address | — | inferred (no subscribe sites exist for them) |

The relevant DJI Fly logic classes (each runs `PostStart`/`PreStop`) are `HeartbeatLogic`, `AppInfoSyncLogic`,
`DeviceRegisterLogic`, `WlmAssistantLogic`, `ActivateMgr` (activation; **never send**),
`DatalinkMapLogic` (TCP verify `07:45`, wifi only), `XrceClientMgr`/`XrceDdsClient` (DDS).

### `00:88` sub-command 0x17 payload ("APP" info), 14 bytes

```
17 00        u16 sub-command 0x0017
OO 23        byte2 bit0 = !is_online (0 = online), byte3 = 0x23 (bits 8,9,13 of a u24 flag field)
00
41 50 50     "APP"
00 00 00 00 00
02           byte13 = 2
```

### Reply to a device `00:88` query (payload starts `19 00`)

```
1a 00 00 00 00   (sub-command 0x001a, u32)  sent as a response with the request's seq
```

## What the experiment tests

`Tools/telemetry-probe/telem_register.py`:

1. Passive 5 s baseline as sender-agnostic listener.
2. `00:88` APP registration from **0x02** → 0x3C (and → 0xBC), then the same from 0x2A for comparison.
   It answers any device `00:88 / 19 00` query.
3. Heartbeat candidates at 1 Hz throughout the rest of the run: `00:0E` and `00:FE` with v1/v2 bodies,
   from 0x02 to 0x3C, cmd_type 0x00 (push style, so no reply is expected).
4. Read-only gets from 0x02 that were `0xE0` from 0x2A (`00:B7`, `00:B8`, `07:29`, `0D:02`, `00:01`), to see
   whether the sender change alone flips the reject code.
5. The N3 `00:99 camcap_common` subscribe replayed to 0x28 and 0x29 (camera topics; harmless).
6. 30 s final listen. It reports every **new** `src>dst set:id` with count and Hz.

### Not sent (deliberately)

`51:2B`, `EE:07`, `EE:12` (payload unknown). `00:B5 exclusive_set_subscribe` (may claim control).
`03:5B`, `03:46` (flight controller). `04:12` (gimbal). `02:EB`, `21:05`, `09:09` (payloads unknown).
Everything in `ActivateMgr`/`DeActivate*`, `07:45`/`07:BA` (permission/verify), all `set_*`, mode, link,
frequency, pairing, recording, streaming-control, reboot, upgrade, format and calibration commands.

## Still unknown

- The heartbeat cmd set/id, and `datalink_type` for a USB-attached glass.
- The `51:2B` payload layout, and whether the wlm (receiver 0xEE) requires it before it forwards link stats.
- Whether the goggles route pushes to `0x02` over IF4 or only over the RNDIS/UDP app path. If IF4
  stays quiet after registration, repeat with `gvcli stream --dump-telemetry` running at the same time.
- Push-pack cmd ids for the O4 generation (`radio_signal_push`, `wlm_dev_osd_push`, …). The first capture
  that contains them settles this.
- A way past the packer: runtime dump of the unpacked lib (rooted Android + frida) would resolve
  all PLT/vtable targets at once. Out of scope for read-only static work.
