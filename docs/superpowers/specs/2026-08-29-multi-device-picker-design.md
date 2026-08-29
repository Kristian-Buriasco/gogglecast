# Multi-device support: picker (v1 of this feature)

## Context

GogglesView v1 (Phase 3, shipped) assumes exactly one DJI Goggles 3 unit connected at a
time — the helper claims the first `2CA3:0020` USB device it finds
(`libusb_open_device_with_vid_pid`), and the XPC protocol's `DeviceInfo` is an implicit
singular "whatever's claimed" value with no device identifier on the wire.

The user wants to support multiple goggles connected simultaneously: a picker (see all
connected units, choose one to stream) as the near-term deliverable, with the explicit
wish that simultaneous multi-view (seeing more than one goggles' video at once) not be
architecturally foreclosed, even if not built in this pass.

## Decision: staged approach

Consulted an independent Opus-model review of three framings (picker-only-single-device,
picker-plus-multi-window-via-device-pinning, full-multi-pane-single-window). Its
conclusion, adopted here: the real cost split isn't between these UX shapes — it's
between the helper/protocol work (device identity, multi-claim capability, per-device
state) which nearly all three approaches need anyway, and the app-side window work,
which is cheap and the app is already structured for (per-window bundles are already
plain locals injected into a coordinator, not singletons — see
`Apps/GogglesView/Sources/GogglesView/main.swift`).

**Decision:** do the helper/protocol device-identity work now, since the XPC protocol is
the one surface multiple consumers depend on (app, helper, `gvcli`'s shared pipeline,
and eventually the CMIOExtension) and it's cheapest to get the identity model right
before more consumers exist. Ship **picker-only UX** in this pass — the app shows a list
of connected devices when more than one is present, picks one, streams it. Multi-window
(seeing two streams in two separate app windows simultaneously) is deliberately deferred
as a cheap, app-side-only follow-up, NOT built in this pass. Full multi-pane
single-window display is explicitly out of scope, not planned.

## Scope of this pass

1. **Device identity**: `DeviceInfo` (in `Packages/GogglesXPC`) gains a stable device ID
   field — USB serial when available, falling back to a `bus:address` composite when
   the serial can't be read (a real, already-observed case in this codebase — see
   `RNDISTransport.swift`'s existing fallback to `serial: nil`). This ID is opaque to
   consumers; they don't need to know its internal shape, just that it identifies a
   specific physical unit stably across a connect session (not necessarily across a
   goggles reboot, since bus:address can change — degrade gracefully, don't assume
   permanence).

2. **Real device enumeration**: replace `libusb_open_device_with_vid_pid`'s
   first-match behavior with real enumeration (`libusb_get_device_list` + descriptor
   filtering on VID:PID `2CA3:0020`), producing a list of all currently-connected
   candidates, each with as much `DeviceInfo` as can be read WITHOUT fully claiming the
   device (a genuine open question — spike this first, cheaply, before designing the
   picker UI around an assumption that might not hold: can the USB serial string
   descriptor be read via a non-exclusive open, or does reading it require the same
   claim that excludes other consumers?).

3. **Helper: fix the process-wide-globals bug BEFORE anything else in this list.**
   `Tools/gvcli/Sources/GogglesPipeline/Pipeline.swift` has `currentTransport`/
   `currentSink` as process-wide globals that `HelperService` reads for real control
   flow (e.g. deciding whether to declare `.noDevice`, where to send `requestIFrame`).
   This is currently harmless because there's only ever one device — it becomes a real
   correctness bug the moment multi-claim exists (device A unplugging could read/act on
   device B's transport). This must become per-pipeline/per-device state as the first
   step of implementation, independent of and before any picker UI work.

4. **Helper: per-device claim and state.** Extend the helper to be ABLE to claim
   multiple devices simultaneously (each with its own independent pipeline/transport
   instance — the existing per-transport isolation already supports this in principle,
   per Task 1.5-1.7's design; it's currently just instantiated as a singleton). State
   that's currently helper-singular (`currentStateValue`, `currentDeviceInfoValue`,
   `everReachedLive`, `pipelineGeneration`, `pipelineTask`, `pendingClose`,
   `lingerTimer`, `deviceRetryTimer`) becomes per-device, keyed by the device ID from
   item 1.

5. **XPC protocol**: relevant `GogglesHelperProtocol` calls gain a device-ID parameter
   (e.g. a new `enumerateDevices(reply:)` call returning `[DeviceInfo]`, and existing
   calls like `startStreaming`/`stopStreaming`/`requestIFrame`/`reconnect` gain a device
   ID parameter instead of implicitly acting on "whatever's claimed"). Bump
   `currentProtocolVersion` per the existing versioning discipline
   (`GogglesXPC.ProtocolVersion`) since this is a breaking wire-protocol change.

6. **Fan-out becomes device-scoped.** `HelperService.fanOut` currently blasts every
   callback (`stateChanged`/`deviceChanged`/`nalUnit`/`stats`) to every connected XPC
   subscriber unconditionally. This must become scoped: a client subscribed to device A
   must not receive device B's callbacks. `streamingSubscriberIDs` (currently a flat
   set) becomes a map keyed by device ID.

7. **App: picker UI.** When `enumerateDevices` returns more than one device, show a
   picker (a new state or a new screen ahead of the existing 9-state machine — design
   this as a "device selection" step that precedes entering the existing per-device
   state machine, rather than adding picker-related cases to the existing
   `GogglesUIState` enum, which should stay modeling ONE device's connection lifecycle
   per the existing, working design). Picking a device threads its device ID through to
   `HelperClient`'s calls.

## Explicitly out of scope for this pass

- Simultaneous multi-window display (deferred, cheap follow-up later, no code for it now
  beyond not architecturally precluding it — i.e., don't hardcode any singleton
  assumptions on the APP side either, even though the app only opens one window today).
- Full multi-pane single-window tiled display (not planned at all, per the design
  decision above).
- The CMIOExtension/virtual camera's own device-selection question (Phase 4, currently
  hard-blocked on a paid Apple Developer Program membership — out of scope entirely
  until that's unblocked; when it is, it should pin a device ID rather than inherit an
  ambient ".whatever's claimed" the way this pass's protocol changes make possible).

## Verification

- Single-device regression is the primary verifiable bar with current hardware (one
  physical Goggles 3 unit available tonight): confirm the existing single-device flow
  (connect, stream, reconnect, disconnect) still works identically after this change,
  now going through the device-ID-aware code paths instead of the old singleton
  assumption.
- Multi-claim (two devices simultaneously) can be tested with `MockTransportTests`
  (already exists in the test suite) for the fan-out-scoping and per-device-state logic,
  but CANNOT be hardware-verified without a second physical Goggles 3 unit, which isn't
  confirmed available tonight. Ship this pass's real-hardware verification honestly
  scoped to single-device-still-works; flag multi-claim as mock-tested-only,
  hardware-unverified, pending a second unit.

## Global constraints (carry into implementation plan)

- No hardcoded goggles MAC address (standing project rule, unaffected by this change but
  worth restating since ARP resolution logic will be touched by per-device work).
- Device ID must degrade gracefully on bus:address changes (replug/reboot) — never
  assume permanence.
- `GogglesXPC.currentProtocolVersion` must be bumped; the version-mismatch "fails loudly"
  behavior already built (Task 3.1) must continue to work correctly against the new
  version number.
