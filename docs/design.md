# GogglesView — Design Spec

Native macOS live-video receiver for DJI Goggles 3 (Goggles N3) over USB-C, plus a
virtual camera output for OBS / Zoom / FaceTime.

- **Status:** design, pre-implementation.
- **Basis:** the working Python prototype at `~/PycharmProjects/dji-goggles3-videoout/`
  (`stream.py`, `rndis.py`, `rawnet.py`, `duml.py`). That prototype is the normative
  reference for every protocol detail below; this document restates it exactly, and
  every deviation from it is called out explicitly.
- **Project root:** `~/XcodeProjects/GogglesView/`.

---

## 1. Goal and scope

### In scope (v1)

1. A native macOS app that displays the goggles' live 1080p H.264 FPV feed with the
   goggles connected by USB-C only. No Cynthion, no Raspberry Pi bridge, no phone,
   no `ffplay` subprocess.
2. Hardware decode via VideoToolbox, display via `AVSampleBufferDisplayLayer`.
3. A device-info panel (product string, serial, USB VID:PID, bus/address) and a
   clear connection state machine.

### In scope (v2)

4. A `CMIOExtension` virtual camera publishing the same feed as a system camera
   device named "DJI Goggles 3".

### Explicitly out of scope

- Audio. The prototype never touched an audio path and none has been located.
- Recording to disk (trivial to add later; not a v1 requirement).
- Any control of the goggles beyond what is needed to start/keep the video flowing.
- Windows/Linux.
- Solving the IDR-trigger problem (see §8.1). v1 designs *around* it.

---

## 2. What is actually proven, and what is not

This section exists so no later phase silently assumes something the prototype did
not demonstrate.

### Proven on real hardware

| Fact | Evidence |
|---|---|
| USB device is VID:PID `2CA3:0020`, 8 interfaces | `N3-usb-descriptor.txt` |
| IF0 (class `0xE0`/`0x01`/`0x03`, Wireless-Controller = RNDIS control, EP `0x82` INT IN) + IF1 (class `0x0A` CDC-Data, EP `0x81` bulk IN / `0x01` bulk OUT) form the RNDIS pair | `N3-usb-descriptor.txt`, `rndis.py` |
| macOS binds IF0/IF1 as `en3`/`en4` but reports `media inactive` and never completes DHCP — the OS RNDIS stack is unusable | `FINDINGS.md` P0 |
| A userspace RNDIS driver over libusb brings the link up | `rndis.py` |
| Goggles answer at `192.168.60.2`; host presents as `192.168.60.1` | `stream.py` |
| A 48-byte UDP packet to port 9003 starts the video stream | `stream.py` |
| Video is H.264 Annex-B, 1920x1080, High Profile Level 5.2, ~33 fps measured | `get_resolution.py` + a clean per-second counter in `stream.py` |
| Claiming IF0/IF1 requires root on this Mac, and often a `detach_kernel_driver()` first | Empirical, this session |
| The goggles' RNDIS MAC rotates on every goggles reboot | Empirical, this session |
| SPS and PPS arrive bundled in one small (~40 byte) NAL blob, not as two NALs | Empirical; broke an early gating attempt |
| A random per-connection session id is required; a fixed one breaks IDR delivery on reconnect | Empirical; was a real bug |
| The only reliable way to get a fresh IDR is the user toggling "Share Liveview to Mobile Device via Wi-Fi" off then on in the goggles' menu | Empirical |
| Wi-Fi-share SSID/passphrase are readable over vendor interface IF4 via DUML `07:07` / `07:0E` / `07:0C` to module `0x1B`, **without root** | `get_wifi_creds.py` |

### Attempted and *not* working

- **DUML `02:B3` (`camera_get_app_request_i_frame`) as an I-frame trigger.** `stream.py`
  retries it every 1.5 s inside a type-`0x01` telemetry packet while waiting for a
  keyframe. It does not reliably produce an IDR. Treat as non-functional.
- **The vendor-interface DUML control path (IF3–IF7).** `FINDINGS.md` P1–P4 documents a
  full dead end: functional commands to `0xBC` are rejected with status `0xE0`, the same
  commands to the air unit `0x09` get no reply, and IF3/5/6/7 never wake. This path is
  *not* part of the video pipeline. Only the credential queries on IF4 work.

### Documentation hazard

`FINDINGS.md` in the Python project is **stale**. It concludes "the network path is a
dead end" and "the N3 is driven over DUML on IF4" — both of which the later RNDIS work
disproved. Anyone reading that file for context must read `stream.py` first. This spec
supersedes it.

---

## 3. Protocol reference (normative)

Restated from the prototype source. Byte offsets are exact.

### 3.1 RNDIS bring-up (`rndis.py`)

Control messages ride USB control transfers on IF0:

- **SEND_ENCAPSULATED_COMMAND**: `bmRequestType=0x21`, `bRequest=0x00`, `wValue=0`,
  `wIndex=0` (IF0), data = the RNDIS message.
- **GET_ENCAPSULATED_RESPONSE**: `bmRequestType=0xA1`, `bRequest=0x01`, `wValue=0`,
  `wIndex=0`, length 4096.
- Between the two, a best-effort 8-byte read of the interrupt endpoint `0x82`
  ("response available" notification). Failure to read it is non-fatal.

Sequence at connect:

1. `REMOTE_NDIS_INITIALIZE_MSG` (`0x00000002`), little-endian
   `{type, length=24, requestId=1, majorVersion=1, minorVersion=0, maxTransferSize=0x4000}`.
2. `REMOTE_NDIS_SET_MSG` (`0x00000005`) on OID `OID_GEN_CURRENT_PACKET_FILTER`
   (`0x0001010E`) with a 4-byte LE value
   `DIRECTED|BROADCAST|ALL_MULTICAST|PROMISCUOUS` = `0x0001|0x0004|0x0010|0x0020` = `0x0035`.
   SET message layout: `{type, msgLen=28+infoLen, requestId, oid, infoLen,
   infoBufferOffset=20, deviceVcHandle=0}` followed by the value.

Data path on IF1:

- `REMOTE_NDIS_PACKET_MSG` (`0x00000001`) header is **44 bytes**; `DataOffset` is
  `44 - 8 = 36`, counted from the `DataOffset` field itself. Layout is
  `{type, msgLen, dataOffset, dataLen, then 7 zero u32 fields}` followed by the raw
  Ethernet frame.
- A single bulk-IN read may contain several `PACKET_MSG` structures back to back;
  iterate by `msgLen` until `msgType != PACKET_MSG` or fewer than 44 bytes remain.

### 3.2 Link-layer addressing (`rawnet.py`, `stream.py`)

- Host MAC is a **synthetic locally-administered address**, `02:00:00:00:00:01`. It is
  not queried from the device and does not need to be.
- Host IP `192.168.60.1`, goggles IP `192.168.60.2`.
- The host answers ARP requests for `192.168.60.1` with an ARP reply (the goggles do
  ARP for the host once the stream starts; `stream.py` handles this).
- IPv4 header is hand-built: `0x45`, TOS 0, total length, id `0x1234`, flags/frag
  `0x4000` (DF), TTL 64, proto 17, correct header checksum, no options.
- UDP checksum is transmitted as **0** (permitted for IPv4). Do not compute it.
- Source port `54321`, destination port `9003`. Inbound video is filtered on
  *source* port == 9003.

**Deviation from the prototype, required for v1:** `stream.py` has the goggles MAC
**hardcoded** (`ca:3c:b4:8d:51:c3`) and `rndis_arp_sweep.py` is a *separate manual tool*
that blasts ARP across eight candidate /24s. Because the MAC rotates on goggles reboot,
the shipping implementation must resolve it at connect time. Since the subnet is now
known, a broad sweep is unnecessary:

1. Send an ARP request for `192.168.60.2` from `192.168.60.1` / `02:00:00:00:00:01`.
2. Wait up to 500 ms for an ARP reply; retry up to 6 times (3 s budget).
3. Also accept a *gratuitous* ARP or an ARP request originating from `192.168.60.2` as
   a source of the MAC.
4. Only if all of that fails, fall back to the multi-subnet sweep from
   `rndis_arp_sweep.py` and report whatever subnet answered as a diagnostic.

The MAC is never persisted across app launches.

### 3.3 Application wire protocol (UDP 9003)

**Outer header, 8 bytes** (`build_outer` in `stream.py`):

| Offset | Size | Field |
|---|---|---|
| 0 | u16 LE | `(8 + bodyLen) \| 0x8000` — total length with the top bit set |
| 2 | u16 LE | session id |
| 4 | u16 LE | sequence number |
| 6 | u8 | packet type |
| 7 | u8 | XOR of bytes 0..6 |

Packet types: `0x00` handshake, `0x01` telemetry, `0x02` video, `0x04`/`0x06` ack.

**Session id must be random per connection** (`random.randint(1, 0xFFFE)`). Reusing a
fixed value was an observed bug that broke IDR delivery on reconnect.

**Handshake (type `0x00`)** — the 40-byte constant body, giving a 48-byte packet:

```
d0 e9 64 00 64 00 c0 05 14 00 00 0a 00 64 00 64
00 c0 05 14 00 00 64 00 14 00 64 00 c0 05 14 00
00 64 00 01 01 04 0a 02
```

Sent once at connect, and re-sent whenever no data has arrived for 2 s.

**Ack (type `0x04`)** — 22-byte body: `u16 LE startSeq`, `u16 LE endSeq`, then the
18-byte constant tail

```
00 00 d0 e9 d0 e9 00 00 d0 e9 d8 e9 00 00 00 00 00 00
```

Sent once per completed frame, covering the sequence range of that frame's fragments.

**Telemetry (type `0x01`)** — body is 24 zero bytes (transmission state), then
`u16 LE dumlLen`, then a DUML frame. Used only for the non-functional I-frame request.

**Video (type `0x02`)** — 12-byte sub-header after the outer header:

| Offset | Size | Field |
|---|---|---|
| 8..15 | 8 bytes | not decoded by the prototype; ignore |
| 16 | u8 | frame number, wraps at 256 |
| 17 | u8 | bit7 = fragment-number LSB; bits 0..6 = fragment **count** |
| 18 | u8 | bits 0..4 = fragment-number bits 1..5 |
| 19 | u8 | not decoded; ignore |
| 20.. | | raw H.264 bytes |

So `fragCount = b17 & 0x7F` and `fragNum = ((b18 & 0x1F) << 1) | (b17 >> 7)`, a 6-bit
fragment index (0..63) with a 7-bit count.

Reassembly (`flush_frame`): accumulate fragments keyed by frame number; when the
fragment count is reached, or when the frame number changes, concatenate fragments in
ascending index order and emit. The result is one NAL unit, which may or may not already
carry a `00 00 00 01` start code — prepend one if absent.

### 3.4 DUML (`duml.py`)

Frame: `0x55` magic, u16 LE `(version << 10) | length`, CRC-8 of bytes 0..2 (seed
`0x77`), sender, receiver, u16 LE seq, cmd type, cmd set, cmd id, payload, u16 LE CRC-16
of everything but the last two bytes (seed `0x3692`). Header is 11 bytes, minimum frame
13 bytes. `duml.py` builds version 1 frames.

Used in v1 for exactly two things:

1. The best-effort I-frame request: sender `0x2A`, receiver `0xBC`, seq `0x9000`,
   cmd_type `0x40`, cmd_set `0x02`, cmd_id `0xB3`, empty payload, wrapped in a type-`0x01`
   telemetry packet. Retained because it is harmless; **the UI must not depend on it**.
2. (Optional, Wi-Fi transport only, see §5.3) SSID/passphrase queries on IF4.

---

## 4. Architecture

### 4.1 Review of the proposed three-component design

The proposed split was: privileged USB helper -> main app, plus a CMIOExtension consuming
the same stream. That is the right *shape*. Four changes:

**Change 1 — the CMIOExtension cannot own the USB connection. Confirmed keep-the-helper.**
This was raised as an open question. It is not viable:
- Claiming IF0/IF1 needs root and needs `detach_kernel_driver()`. A CMIO system extension
  runs sandboxed and unprivileged; it has no route to either.
- Even setting privilege aside, a camera extension is lifecycle-managed by the CMIO DAL
  assistant and is only meaningfully alive while a client has the device open. Making it
  the sole owner of the hardware would mean the main app could not show video unless it
  also opened its own virtual camera — an absurd loop, and it would break the
  "app works before the extension is approved" property.
- The exclusive-ownership argument runs the other way too: exactly one process may claim
  IF0/IF1, so the helper must be that process and must fan out to N consumers.

**Change 2 — Mach-service XPC, not a Unix domain socket.** Also raised as an open
question; XPC wins, and the reason is the extension, not the app:
- A root LaunchDaemon vends a Mach service by declaring `MachServices` in its launchd
  plist; the app connects with `NSXPCConnection(machServiceName:options:.privileged)`.
  Either transport would work for the app alone.
- A CMIO extension is sandboxed. Filesystem paths outside its container are unreachable,
  so a Unix socket at `/var/run/...` is a non-starter, and app-group container paths for
  sockets are fragile. The pattern that actually works for camera extensions is a Mach
  service whose name is prefixed with the team-scoped app group ID, which the sandbox
  permits by virtue of the group entitlement.
- **Decision:** one Mach service, name `<TeamID>.com.kburiasco.gogglesview.helper`,
  declared in the daemon plist and listed in the app group shared by app, helper and
  extension.
- **Caveat to verify in Phase 4, not to assume:** system-extension sandbox rules around
  Mach lookup have historically been finicky. Phase 4 begins with a throwaway spike that
  proves the extension can reach the helper's Mach service *before* any video code is
  written into it. If it cannot, the fallback is for the app (not the extension) to be
  the extension's frame source over the CMIO sink-stream / `CMIOExtensionStreamSource`
  push path.

**Change 3 — abstract the transport. This is the significant addition.**
The UDP-9003 protocol in §3.3 is *the goggles' Wi-Fi liveview protocol*; the RNDIS link
is only a carrier for it. `get_wifi_creds.py` already extracts the share SSID and
passphrase over IF4, and IF4 needs **no root** (no kernel driver binds the vendor
interfaces). That means there is a fully unprivileged second transport:

> Join the goggles' Wi-Fi AP and open an ordinary `NWConnection` UDP socket to
> `<goggles>:9003`. No RNDIS, no raw Ethernet, no ARP, no libusb on the data path,
> **no root**.

Everything above the transport — session ids, handshake, fragment reassembly, ack,
parameter-set gating, decode, display, virtual camera — is bit-for-bit identical.

This is not proposed as v1's primary path (it monopolises the Mac's Wi-Fi radio and costs
internet access, which is exactly why USB is the product). It is proposed as:
- a **design constraint**: define `protocol GogglesTransport { func send(_: Data); var
  frames: AsyncStream<Data> }` with `RNDISTransport` and `WiFiUDPTransport` conformances,
  so the protocol core is testable without root and without hardware;
- a **de-risking escape hatch**: if the SMAppService/privileged-helper plumbing
  (§8.4) proves intractable, a Wi-Fi-only build still ships a working product;
- a **v1.1 feature** that costs perhaps a day once the abstraction exists.

**Change 4 — three processes, but staged.** The full three-process topology is correct as
an end state; building it all at once is not. v1 ships app + helper (two processes) and
adds the extension in v2. See the phase plan.

### 4.2 Components

```
┌───────────────────────────────────────────────────────────────┐
│ GogglesView.app  (unprivileged, sandboxed, SwiftUI + menu bar)│
│   • NSXPCConnection ──────────────────────────┐               │
│   • VideoToolbox decode → AVSampleBufferDisplayLayer          │
│   • connection state machine + IDR-recovery UX                │
│   • installs/updates helper (SMAppService) and extension       │
│     (OSSystemExtensionRequest)                                 │
└───────────────────────────────────────────────────────────────┘
                                                │ XPC (Mach service)
┌───────────────────────────────────────────────▼───────────────┐
│ GogglesHelper  (root LaunchDaemon, SMAppService.daemon)       │
│   • libusb (statically linked)                                │
│   • RNDIS driver · raw Eth/ARP/IPv4/UDP · UDP-9003 protocol   │
│   • fragment reassembly → Annex-B NAL units                   │
│   • fan-out to N XPC subscribers; no decode, no display       │
└───────────────────────────────────────────────▲───────────────┘
                                                │ XPC (same Mach service)
┌───────────────────────────────────────────────┴───────────────┐
│ GogglesCamera.systemextension  (CMIOExtension, v2)            │
│   • decodes Annex-B → CVPixelBuffer, publishes as a camera    │
└───────────────────────────────────────────────────────────────┘
```

**GogglesHelper** is deliberately dumb: it owns the hardware, speaks the protocol, and
emits `(annexBData, nalType, isParameterSet, hostTimestamp)`. It does no decoding. This
keeps the root-privileged attack surface small — it never touches VideoToolbox, never
parses anything an untrusted party controls beyond the goggles' own packets, and has no
UI. It also means a helper crash is recoverable without losing the app.

**GogglesView.app** owns all decode and presentation, plus every piece of the install
flow that needs user consent.

**GogglesCamera** is a second, independent decoder. It does *not* receive already-decoded
frames from the app — that would require a large-buffer IOSurface hand-off between two
sandboxes for no benefit. Both consumers decode the same compact H.264 stream. At 1080p33
that is two hardware decode sessions, which Apple Silicon handles trivially.

### 4.3 Why not fewer processes

- **App owns USB directly, no helper.** Requires the app itself to run as root. Rejected.
- **Helper also decodes and hands over IOSurfaces.** Puts VideoToolbox in a root process
  and multiplies IPC payload size by ~50x. Rejected.
- **No app, extension only.** Nothing to install the extension from, no UI, no route to
  root. Rejected.

---

## 5. Data flow

### 5.1 Connect sequence (helper)

1. Enumerate USB for `2CA3:0020`. Read `iProduct`, `iSerialNumber`, `bcdDevice`, bus,
   address; publish as a `DeviceInfo` to subscribers.
2. For IF0 and IF1: `detach_kernel_driver` if a driver is active (tolerate failure), then
   `claim_interface`. Failure here is fatal for the attempt and surfaces as the
   `claimFailed` state (§6).
3. RNDIS `INITIALIZE`, then `SET OID_GEN_CURRENT_PACKET_FILTER = 0x35` (§3.1).
4. Resolve the goggles MAC by targeted ARP (§3.2). Never from cache.
5. Generate a fresh random session id in `1..0xFFFE`.
6. Send the 48-byte handshake to `192.168.60.2:9003`.
7. Enter the receive loop.

### 5.2 Receive loop (helper)

Per inbound bulk-IN buffer: unwrap RNDIS packet messages -> per Ethernet frame:

- ARP request for `192.168.60.1` -> emit an ARP reply. ARP reply/request from
  `192.168.60.2` -> learn/refresh the goggles MAC.
- UDP with source port 9003 and >= 8 bytes payload -> reset the RX watchdog, dispatch on
  packet type. Only type `0x02` with >= 20 bytes is processed for video.
- On a completed frame (fragment count reached) or a frame-number change: concatenate,
  emit, send an ack covering that frame's sequence range.

Timers, all driven from the same loop:

| Timer | Period | Action |
|---|---|---|
| RX watchdog | 2 s of silence | re-send handshake |
| I-frame request | 1.5 s, only while not yet started | send DUML `02:B3` telemetry (best-effort, see §8.1) |
| Stats | 1 s | publish measured fps / bitrate / drop counters |

**Implementation change from the prototype (required, not optional):** `stream.py`'s
`frames` dictionary only ever evicts the current frame number. Because frame numbers wrap
at 256, a fragment lost mid-frame leaves a partial entry that is never freed and that a
later frame with the same number will merge into, producing a corrupt NAL. The Swift
implementation must (a) drop any frame entry older than ~5 frame numbers (modulo-256
distance) or ~250 ms, and (b) discard, not merge, a frame whose fragments are incomplete
when it is evicted, incrementing a drop counter.

**Second implementation change:** `stream.py` uses synchronous 16 KB bulk reads with a
200 ms timeout. At 1080p33 this is adequate in Python only because the goggles buffer.
The Swift helper uses libusb asynchronous transfers — a pool of 16 in-flight 64 KB
transfers submitted round-robin — with `libusb_handle_events_timeout` pumped on a
dedicated high-QoS thread. This removes the read gap between iterations entirely.

### 5.3 Parameter-set handling and the SPS/PPS split

`stream.py` gates output on `nalType in (7, 8)` followed by `nalType == 5`, and emits the
stored blob then the IDR. That is correct for a raw Annex-B byte sink such as a FIFO.
**It is not sufficient for VideoToolbox.**

`CMVideoFormatDescriptionCreateFromH264ParameterSets` requires SPS and PPS as
*separate* pointers. Since the goggles deliver both inside one ~40-byte NAL blob, the
decoder-side code must:

1. Scan the blob for internal `00 00 01` / `00 00 00 01` start codes and split it into
   individual NALs.
2. Identify the type-7 (SPS) and type-8 (PPS) members by `nal[0] & 0x1F`.
3. Build the `CMVideoFormatDescription` from those two, with
   `nalUnitHeaderLength = 4`.
4. Rebuild the format description whenever a *different* parameter-set blob arrives
   (compare bytes; identical blobs are ignored).

Slice NALs must then be converted from Annex-B (start-code prefixed) to AVCC
(4-byte big-endian length prefixed) before being wrapped in a `CMBlockBuffer` /
`CMSampleBuffer`. This conversion is the app's and the extension's job; the helper always
emits Annex-B.

### 5.4 Timestamps

The wire protocol carries **no presentation timestamp** — only a frame number that wraps
at 256. Therefore:

- The helper stamps each emitted NAL with `mach_absolute_time()` at the moment the frame
  completes, and forwards that.
- The app displays with `AVSampleBufferDisplayLayer` in immediate mode
  (`kCMSampleAttachmentKey_DisplayImmediately = true`) and does not attempt a
  presentation clock. This is a live low-latency feed; scheduled presentation would only
  add latency and jitter for no benefit.
- The extension synthesises a CMIO timestamp from the helper's host time so that
  consumers see a monotonic, real-rate clock. Nominal rate is advertised as 30 fps with
  the measured ~33 fps tolerated; consumers such as OBS resample.

### 5.5 XPC interface

One protocol, versioned by a `protocolVersion` reply so a stale app and a fresh helper
fail loudly rather than mysteriously.

```
protocol GogglesHelperProtocol {
    func protocolVersion(reply: (Int) -> Void)
    func currentDeviceInfo(reply: (DeviceInfo?) -> Void)   // NSSecureCoding
    func startStreaming(reply: (Bool, NSError?) -> Void)
    func stopStreaming(reply: () -> Void)
    func requestIFrame(reply: () -> Void)                  // best-effort, see §8.1
    func reconnect(reply: () -> Void)                      // full teardown + §5.1 rerun
}

protocol GogglesClientProtocol {                            // helper -> client
    func deviceChanged(_ info: DeviceInfo?)
    func stateChanged(_ state: Int, detail: String?)
    func nalUnit(_ data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64)
    func stats(_ stats: StreamStats)
}
```

Frames are delivered by the helper calling `nalUnit` on each subscriber's exported
object. A 1080p H.264 P-frame at 33 fps averages roughly 20–60 KB; XPC handles this
volume without special treatment, and `Data` above ~16 KB is transferred out-of-line by
`NSXPCConnection` automatically. If Phase 2 profiling shows XPC overhead is material,
the fallback is a shared-memory ring buffer whose `IOSurface`/`mach_port` handle is passed
once over XPC — deliberately deferred, not designed in speculatively.

**Fan-out rule:** the helper starts the hardware on the first subscriber that calls
`startStreaming` and tears it down when the last one disconnects, with a 5 s linger to
survive an app relaunch. Subscribers are independent; one crashing does not stop the
others.

---

## 6. User-facing state machine

| State | Meaning | UI |
|---|---|---|
| `noHelper` | Helper not installed or not registered | "Set up" button -> `SMAppService.register()` |
| `noDevice` | Helper running, no `2CA3:0020` on USB | "Connect your Goggles 3 with USB-C" |
| `claiming` | Detaching/claiming IF0/IF1, RNDIS init | spinner |
| `claimFailed` | Root claim or RNDIS init failed | diagnostic + "Retry"; see §8.3 |
| `resolving` | ARP for `192.168.60.2` | spinner |
| `handshaking` | Handshake sent, nothing received yet | spinner + elapsed seconds |
| `waitingForKeyframe` | Video packets arriving, no SPS+IDR yet | **the toggle card, §8.1** |
| `live` | Displaying decoded frames | video + stats overlay |
| `stalled` | Was live, no packets for > 2 s | overlay "Signal lost — reconnecting", last frame dimmed |

Transitions out of `live` on a 5 s silence go to `handshaking`, not straight to
`waitingForKeyframe`, because the handshake must be re-established first.

The device-info card (product string, serial, `2CA3:0020`, bus/address) is shown in
every state from `claiming` onward, mirroring CosmoViewer Direct's device picker layout.
CosmoViewer Direct is a **UX reference only**; nothing about its internals is known and
nothing in this design is derived from it.

---

## 7. Error handling

| Failure | Detection | Response |
|---|---|---|
| Device unplugged | libusb hotplug callback, or `LIBUSB_ERROR_NO_DEVICE` on transfer | full teardown -> `noDevice`; keep the XPC connection alive |
| IF0/IF1 claim fails | `libusb_claim_interface` error | `claimFailed` with the errno; retry once after `detach_kernel_driver`; then surface §8.3 guidance |
| RNDIS `INITIALIZE` no response | control-transfer timeout | one retry, then `claimFailed` |
| ARP resolution timeout (3 s) | no reply | run the multi-subnet sweep fallback once; if still nothing, `claimFailed` with "goggles did not answer on the USB network link — power-cycle the goggles" |
| No packets after handshake (5 s) | RX watchdog | re-send handshake; after 3 attempts show "goggles connected but not sending video — check the air unit is powered" |
| Packets flowing, no SPS+IDR (8 s) | gating state | `waitingForKeyframe` card, §8.1 |
| Fragment loss | fragment count not reached at eviction | drop the frame, increment counter, continue; do **not** re-request the stream |
| Corrupt/undecodable NAL | VideoToolbox `OSStatus` error | drop the sample, keep the session; on 30 consecutive errors, tear down the decode session and wait for the next parameter set |
| Helper crashes | `NSXPCConnection` invalidation handler | app shows `noHelper` briefly and relaunches on demand (launchd `KeepAlive` off; the daemon is on-demand via `MachServices`) |
| App crashes | helper's connection invalidation | drop that subscriber; after the 5 s linger with no subscribers, release the USB interfaces |
| Two apps both connect | helper fan-out | supported by design; the hardware is claimed once |

---

## 8. Risks

### 8.1 The IDR problem (unsolved — highest UX risk)

The encoder does **not** emit periodic IDRs. A genuine SPS+IDR pair is produced only when
the user toggles "Share Liveview to Mobile Device via Wi-Fi" off and on in the goggles'
own menu. DUML `02:B3` was implemented and retried on a 1.5 s cadence and does not
reliably work. Nothing found in this session solves it.

**The design must not assume this becomes automatic.** Concretely:

- There is no "connecting…" spinner that hangs forever. After 8 s in
  `waitingForKeyframe`, the app shows an explicit instruction card:

  > **Waiting for a keyframe from your goggles**
  > Video data is arriving, but the goggles only send a new keyframe when liveview
  > sharing is restarted.
  > On the goggles, open the shortcuts menu (5D button / AR dial) and toggle
  > **Share Liveview to Mobile Device via Wi-Fi** off, then on again.
  > *(Ready in a moment — this is a limitation of the goggles, not of GogglesView.)*

  with a live "Waiting… 0:14" counter and a "Try requesting a keyframe" secondary button
  wired to `requestIFrame()`, labelled as unreliable rather than presented as the fix.

- The same card is reachable at any time from a "Reconnect" menu item, which performs a
  full §5.1 teardown-and-reconnect (new random session id included) and then shows the
  card.

- Once `live`, the app never leaves it for a missing keyframe alone — a decoder that has a
  format description keeps decoding P-frames indefinitely.

**Future work, explicitly not v1:** recovering the real start sequence from
`libdjisdk_jni.so` via Ghidra (`PigeonLiveViewLogic::Start`,
`ModuleMediator::StartLiveStreaming`, `SpecialCommandManager::RequestIFrameForLiveView`),
per `FINDINGS.md` P3. If that lands, it slots in behind `requestIFrame()` with no
architectural change.

### 8.2 MAC rotation

Handled by design (§3.2): resolve at every connect, never cache, never persist. Called
out here because a "cache the MAC for faster reconnect" optimisation is exactly the kind
of thing that gets added later and breaks after a goggles reboot. **Do not add it.**

### 8.3 Root privilege for IF0/IF1

Claiming these interfaces required root in this session, from a plain Terminal process,
and often required `detach_kernel_driver()` first because macOS inconsistently binds a
driver to them. Two consequences:

- The helper genuinely must run as root; there is no unprivileged USB entitlement that
  substitutes. (DriverKit would avoid root but requires a `.dext`, an Apple-approved
  `com.apple.developer.driverkit.*` entitlement, and a rewrite — categorically out of
  scope.)
- `detach_kernel_driver` on macOS via libusb is implemented but partial. If it fails and
  the claim also fails, the documented user workaround is to disable the `en*` interface
  macOS created for the goggles in System Settings > Network, or to unplug/replug. This
  must be in the `claimFailed` diagnostic text, not buried in a README.

### 8.4 SMAppService daemon installation

Real footguns, and one correction to the original proposal:

- **`SMPrivilegedExecutables` is not used by `SMAppService`.** That key belongs to the
  legacy `SMJobBless` flow. Mixing the two is a known way to waste a day. The
  `SMAppService.daemon` requirements are different:
  - the launchd plist lives at `Contents/Library/LaunchDaemons/<label>.plist` inside the
    app bundle;
  - the plist's filename, its `Label`, and the string passed to
    `SMAppService.daemon(plistName:)` must all agree;
  - `BundleProgram` is a path *relative to the app bundle root*, e.g.
    `Contents/MacOS/GogglesHelper`;
  - `MachServices` declares the Mach service name;
  - helper and app must be signed by the same Team ID, and the helper must have the
    hardened runtime;
  - `register()` requires the user to approve the item, and it appears under
    System Settings > General > Login Items & Extensions. `SMAppService.status` must be
    consulted and surfaced — a registered-but-not-approved daemon does not run, and this
    is the single most common "it silently doesn't work" case.
- Development iteration is painful: an unapproved or stale registration must be cleared
  with `sudo sfltool resetbtm` (which resets *all* login items on the machine) or by
  unregistering before every rebuild. Phase 2 budgets for this explicitly.
- **Phase 2 mitigation:** the helper binary is written and debugged first as a plain
  root-run CLI (`sudo ./GogglesHelper --stdout`) with a `--xpc` mode added second. That
  way protocol bugs and packaging bugs are never being debugged simultaneously.

### 8.5 CMIOExtension entitlements and distribution

Stated plainly, since the brief asked for a straight answer on what is achievable:

- A camera extension needs: the host app entitled with
  `com.apple.developer.system-extension.install`, the extension bundled at
  `Contents/Library/SystemExtensions/`, an app group shared by app / helper / extension,
  hardened runtime everywhere, and installation via `OSSystemExtensionRequest`.
- **Good news:** `com.apple.developer.system-extension.install` is available to any
  Apple Developer Program member. Unlike DriverKit entitlements, it does **not** require a
  case-by-case Apple approval. CMIOExtension is a supported public API with no special
  gate.
- **The real gate is signing, not approval.** A system extension installs on a normal Mac
  only if the app is signed with a **Developer ID** certificate and notarized. Developer
  ID requires a paid Apple Developer Program membership ($99/yr); a free personal team
  cannot issue one and cannot notarize.
- **Therefore, for a personal/local-only build with no paid membership:** the app,
  helper and virtual camera all still work, but the extension installs only with
  `systemextensionsctl developer on` (and the machine must be rebooted into that mode
  once). That is an acceptable personal-use path and is what v2 targets by default.
- **Distribution to anyone else is blocked on the paid membership plus notarization.**
  This is a hard dependency, not something that can be engineered around. It is the
  reason the virtual camera is v2: v1 must be useful without it.
- Note also that virtual cameras are invisible to apps with the hardened runtime and
  library-validation enabled unless those apps opt in — historically an issue for
  FaceTime and some Safari paths. OBS, Zoom and Chrome are fine. Set expectations in the
  UI: list OBS/Zoom/Discord/Chrome as verified targets rather than promising "any app".

### 8.6 Protocol fragility

Every constant in §3.3 — the 40-byte handshake, the 18-byte ack tail, the fragment bit
layout — was derived empirically from one goggles unit on one firmware version. A
firmware update can invalidate any of it. Mitigation: keep all constants in a single
`WireProtocol.swift` with the observed-on comment (firmware `zv300 gl Ver.02`,
`bcdDevice 0x0504`), and log unknown packet types at debug level rather than dropping
them silently, so a future breakage is diagnosable from a user's log.

---

## 9. Testing and verification

### 9.1 Offline, no hardware (the bulk of the coverage)

The reason for the transport abstraction (§4.1, change 3) is that everything above it is
testable without goggles and without root.

1. **Capture corpus.** Add a `--pcap` mode to the Python `stream.py` that dumps every
   inbound Ethernet frame, plus every outbound frame, to a file with host timestamps.
   Capture at minimum: a clean start including the SPS+IDR, a mid-stream steady state,
   a session with deliberate USB-unplug, and one with visible fragment loss. This corpus
   is committed to the repo (it contains no secrets — the serial can be scrubbed).
2. **Golden-vector unit tests, Swift vs Python.** For each of these, the Swift result must
   equal a Python-generated fixture byte-for-byte:
   - `wrapPacketMsg` / `unwrapPacketMsg` round trip, including multi-message buffers;
   - IPv4 header checksum;
   - `buildUDP`, `buildARPRequest`, `buildARPReply`, and the three parsers;
   - `buildOuter` for each packet type, including the XOR byte and the `0x8000` length bit;
   - the 48-byte handshake and the 22-byte ack;
   - DUML `build` for the `02:B3` frame, and `parseStream` over a captured IF4 dump
     (CRC-8 and CRC-16 both exercised).
3. **Reassembler tests** driven by the corpus: in-order, out-of-order fragments, a
   dropped fragment (must drop the frame and count it, not merge), frame-number wrap
   across 255 -> 0, and the specific stale-entry case that the Python code gets wrong.
4. **Parameter-set split test** on the real ~40-byte bundled blob from the corpus:
   asserts two NALs out, types 7 and 8, and that
   `CMVideoFormatDescriptionCreateFromH264ParameterSets` succeeds with 1920x1080.
5. **Replay harness.** A `MockTransport` that plays the corpus at recorded timing into the
   full protocol core. Used by CI and by the app in a hidden "demo mode".

### 9.2 On-hardware, parity with the prototype

The Phase 1 exit criterion. Run the Python prototype and the Swift CLI back to back on
the same goggles session and compare:

| Metric | Requirement |
|---|---|
| Frames/sec, steady state, 60 s | Swift within ±1 fps of Python's ~33 |
| Dropped-frame count, 60 s | Swift <= Python |
| Time from handshake to first displayed frame (after the user toggle) | Swift <= Python + 500 ms |
| Bytes emitted, 60 s | within 2% of Python's |
| Decoded output | `ffprobe` on the Swift CLI's Annex-B dump reports 1920x1080, High, Level 5.2 |

Additionally: the Swift CLI's raw Annex-B dump piped to `ffplay` must render identically
to `stream.py`'s FIFO output, and running `stream.py` and the Swift CLI in sequence
(not concurrently — the interface is exclusive) must both succeed, proving clean release
of IF0/IF1.

### 9.3 Robustness scenarios (manual, scripted checklist)

Each must leave the app in a correct state with no crash and no leaked USB claim:

1. Unplug USB while `live`.
2. Replug. Must reconnect to `waitingForKeyframe` without a restart.
3. Reboot the goggles while connected (**exercises MAC rotation** — the reconnect must
   succeed without any manual step, proving §8.2).
4. Toggle liveview sharing off and on; verify transition to `live`.
5. Kill the helper (`sudo killall GogglesHelper`) while `live`.
6. Kill the app while `live`; confirm the helper releases the interfaces after the linger.
7. Run two copies of the app simultaneously; both must show video.
8. Leave `live` running for 30 minutes; memory must be flat (this catches the §5.2
   reassembly leak directly).
9. Sleep and wake the Mac while connected.

### 9.4 Virtual camera verification (v2)

- The device appears in OBS, Zoom, Discord and Chrome (`getUserMedia`) as
  "DJI Goggles 3", at 1920x1080.
- OBS shows video within 3 s of selecting it, given the app is already `live`.
- Selecting it while the goggles are absent yields a clean "no signal" frame, not a hang
  and not a black frame with no explanation.
- Stopping and restarting the OBS source does not require an app restart.
- `systemextensionsctl list` shows the extension `activated enabled`.
- The extension is verified to survive a machine reboot, and to still work after the app
  is updated in place (a common breakage point when the extension version is bumped).

---

## 10. Open questions

1. Does a CMIO system extension's sandbox permit Mach lookup of the helper's
   app-group-prefixed service? **Resolved by a Phase 4 spike before any other Phase 4
   work.** Fallback documented in §4.1.
2. Are bytes 8..15 and 19 of the video sub-header meaningful (timestamp? stream id?)? Not
   needed for v1; worth a look at the capture corpus, since a real PTS would improve the
   CMIO clock.
3. What are packet types `0x06` and `0x01` inbound? The prototype ignores both. Logging
   them at debug level (§8.6) will answer this over time.
4. Does the goggles' Wi-Fi transport (§4.1, change 3) reach `192.168.60.2:9003` or a
   different address on the AP subnet? Trivial to determine once the SSID is joined;
   blocks nothing in v1.
