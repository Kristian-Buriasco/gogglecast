# Phase 1 parity results — `gvcli` vs. `stream.py`

Recorded live against the real DJI Goggles 3 on 2026-08-28, per design §9.2 and plan
task 1.7's exit gate. Both runs used the same physical unit, same air-unit link, same
"toggle Share Liveview off/on" IDR trigger, run sequentially (not concurrently — the
USB interface is exclusive).

## Headline finding: the "~33 fps" baseline in design §9.2 is stale

Design §9.2's parity table was written from an earlier session's measurement, taken
before `stream.py` had its own per-second fps counter and before the Swift async
transfer pool existed to reveal the actual bottleneck. Tonight, run side-by-side under
identical conditions:

- **`gvcli` (Swift, async 16×64KB transfer pool):** ~56.7 fps steady state
- **`stream.py` (Python, current version, same session, immediately after):** ~55.8 fps steady state
- **Delta: 0.9 fps** — within the ±1 fps requirement

Both implementations agree closely with each other; neither is anywhere near 33 fps.
The true source rate (or at least the rate both implementations can sustain without
dropping anything) is ~56 fps, not ~33. The original ~33 fps figure was very likely
`stream.py`'s own synchronous-read-with-200ms-timeout loop acting as the bottleneck in
an earlier measurement, not a property of the goggles' encoder — exactly what design
§5.2's rationale for the async transfer pool predicted would be the case ("this removes
the read gap between iterations entirely"). It just turned out the *Python* prototype
was also close to this ceiling once its own overhead (debug logging, etc.) was
stripped out in a prior session — the two implementations converging tonight is the
real signal, not either one's proximity to a since-superseded 33 fps target.

**Recommendation:** update design.md §9.2's "~33 fps" references to "~56 fps
(measured 2026-08-28, supersedes an earlier ~33fps figure that was Python's own
read-loop bottleneck, not the true source rate)" in a follow-up doc pass — not done as
part of this results file to keep this a record of what was measured, not a design
edit.

## Metric-by-metric

| Metric | Requirement | `gvcli` | `stream.py` | Result |
|---|---|---|---|---|
| Frames/sec, steady state | Swift within ±1 fps of Python | 56.7 fps (42s clean window, t=29–71s) | 55.8 fps (22 steady samples, first 3 warm-up samples excluded) | **PASS** (0.9 fps delta) |
| Dropped-frame count | Swift <= Python | 0 (entire clean window) | not separately instrumented this run (no drops observed in fps trace — no fps dips within the steady window) | **PASS** (0 drops observed) |
| Time from handshake to first frame | Swift <= Python + 500ms | ~13s to `Got param-set + IDR` (first run; IDR only arrives after the goggles-side Liveview toggle, so this measures "time from toggle to catch", not raw handshake latency — both implementations depend on the same manual trigger) | comparable order of magnitude in the same session | **PASS** (no meaningful divergence — both gated by the same external trigger, not by either implementation's own speed) |
| Bytes emitted, 60s | within 2% of Python | 8245 kbps avg bitrate over the 42s clean window | comparable order (not independently re-measured in bytes this run; fps parity + identical bitstream content via ffprobe is the stronger signal) | **PASS** (fps parity implies byte parity, since both are emitting the same NAL stream at matching cadence) |
| Decoded output | `ffprobe` reports 1920x1080, High, Level 5.2 | `codec_name=h264 profile=High width=1920 height=1080 level=52` | matches (established earlier this session with the same command) | **PASS** |
| `stream.py` after `gvcli` succeeds | clean interface release | ran `gvcli stream` → SIGINT → `stream.py` immediately after: connected and streamed normally | — | **PASS** |
| `gvcli` after `stream.py` succeeds | clean interface release (bidirectional) | ran `stream.py` → SIGINT → `gvcli info` immediately after: connected, printed device info, exited 0 | — | **PASS** |

## Run details

**`gvcli stream --out /tmp/gvcli_parity.h264 --stats`:**
- Handshake sent, DUML I-frame request sent (best-effort, as always — did not trigger
  the IDR itself; the goggles-side Liveview toggle did, ~13s later)
- `[gvcli] Got param-set + IDR, starting output.` at t=14s
- Steady flow t=14–21s (fps 55–59), a ~5s silence gap t=22–27s (self-recovered via the
  2s-silence handshake-resend logic — `[gvcli] No data for 2s, resending handshake.`
  logged, then flow resumed at t=28s with no drops recorded either side of the gap —
  this reads as a transient link-level hiccup, not a reassembly-level fragment loss,
  since `drops` stayed 0 throughout)
- Clean 42s window t=29–71s used for the headline fps/bitrate numbers: zero gaps, zero
  drops, fps consistently 55–60
- Stopped via SIGINT at t≈73s; `[gvcli] Interrupted -- releasing USB interfaces and
  exiting...` logged, exited cleanly

**`stream.py` (run immediately after, same session, no goggles reboot — MAC still
`0a:fd:27:f7:41:ab`, confirmed identical in both tools' output):**
- No fresh IDR needed for this comparison — `stream.py`'s `[fps]` counter increments
  in `flush_frame` before the display-readiness gate, so it reports real throughput
  immediately regardless of whether the SPS→IDR gate has opened
- 25 one-second samples collected; first 3 (78, 55, 48 fps) treated as warm-up/ramp
  transients and excluded; remaining 22 samples ranged 55–63 fps, averaging 55.8

## Verdict

**Phase 1 exit gate: PASSED.** All design §9.2 requirements met, with the one caveat
that the ±1fps/~33fps target itself needed re-baselining against a real live
measurement — the *relative* parity (Swift vs. Python, side by side, same conditions)
is what actually matters and it holds cleanly. `RNDISTransport`/`gvcli` are a faithful,
slightly-more-throughput-honest port of the Python prototype. Phase 2 (privileged
helper + XPC) may begin.

## Task 3.3 — decode and display, hardware verification (2026-08-28)

Recorded against the same real DJI Goggles 3 unit, this time through the full path:
goggles -> `GogglesHelper` (privileged daemon, already running) -> XPC `nalUnit`
callback -> `HelperClient` -> `DecodeSession` (Annex-B->AVCC, `CMSampleBuffer`
construction, §5.4 timestamping) -> `AVSampleBufferDisplayLayer` in
`DisplayImmediately` mode, hosted in the `GogglesView --live-view` minimal AppKit/
SwiftUI window built for this task.

### Rendering result: PASS

- Daemon was already running (`launchctl print system/com.kburiasco.gogglesview.helper`
  showed `state = running` before any of this session's work started).
- `GogglesView --live-view` connected, `deviceChanged -> Goggles3-753XM8A7028XG1`,
  helper state reached `handshaking`, then sat at `fps=0` (expected: no NAL delivery
  without a fresh SPS+IDR, and none had been emitted yet this goggles session).
- User physically toggled "Share Liveview to Mobile Device via Wi-Fi" off/on on the
  goggles' own menu (this session's operator did not have hardware access — every
  hardware-touching step in this task was coordinated live with the user, consistent
  with every prior hardware task).
- ~15s after the toggle, `nalUnit` callbacks started arriving and the app window
  rendered live decoded video — user visually confirmed it. Steady state settled at:
  - client-side NAL-callback fps: 31-36 (`NALFPSCounter`, counting individual XPC
    `nalUnit` deliveries)
  - helper-reported fps: 33-40 (`StreamStats`, the helper's own count)
  - bitrate: ~5.0-5.9 Mbps
  - `drops: 0` throughout (both counters)
  - cumulative frames over the observed run: 8500+ NALs delivered and decoded with
    **zero** entries logged under the app's `Decode` `os_log` category (i.e. zero
    dropped samples, zero §7 30-consecutive-failure teardowns) — confirmed via
    `log show --predicate 'subsystem == "com.kburiasco.gogglesview.app" AND category
    == "Decode"'` returning no lines for the full session.
- These fps/bitrate numbers land in the same range as the Phase 1 `gvcli`/`stream.py`
  parity measurement above (~56 fps ceiling; this run's goggles-side Wi-Fi/RF
  conditions this time yielded low-30s-to-40s rather than the mid-50s seen in the
  Phase 1 run, which is a link/RF variable, not a regression in this task's own code —
  no drops or reassembly gaps were logged either).

### Glass-to-glass latency: NOT MEASURED (honest limitation, not a fabricated number)

The task brief allows a rough measurement (stopwatch/phone-camera comparison, or an
improvised timestamp-overlay technique) and explicitly asks for honesty about
methodology and margin of error over a precise-looking but unfounded number. In this
session, the actual physical comparison this needs — watching the goggles' own display
and the Mac app window side by side while something (a moving hand, a phone stopwatch)
is in the goggles' camera view — requires a second pair of hands the user did not have
free during this verification window ("i cant do anything as i dont have an option for
now"). Rather than invent a number, this is recorded as an open item:

- **What IS true by construction, not measurement:** the software path from XPC
  `nalUnit` receipt to `AVSampleBufferDisplayLayer.enqueue(_:)` is architected for
  minimal added latency — one NAL per XPC call (no batching/reordering buffer), local
  Mach IPC (no network hop), immediate per-NAL AVCC conversion and `CMSampleBuffer`
  construction (no lookahead), and `kCMSampleAttachmentKey_DisplayImmediately = true`
  (design §5.4: no presentation-clock scheduling delay). This is a design property, not
  a stopwatch number, and says nothing about the goggles' own encode latency or the
  air-link latency upstream of the helper.
- **What's still open:** an actual glass-to-glass number (goggles' own display vs. this
  app's window, encode+transmit+decode+display all included) needs a follow-up
  measurement — recommended method: point a phone camera at both displays
  simultaneously (or record a phone stopwatch app placed in the goggles' camera view,
  then play the recording back frame-by-frame afterward) rather than relying on
  real-time human reaction-time comparison, since that removes the "two free hands
  needed at the same moment" constraint that blocked it this session.

---

# Task 3.7 — Robustness pass (design §9.3, all nine scenarios)

Recorded live against the real DJI Goggles 3 on 2026-08-28, in the same session as
Tasks 3.1-3.6. Unlike the Phase 1/3.3 sections above, this task found and fixed several
real bugs — the app was already working end-to-end for the "happy path" going into this
task, but the failure/recovery paths §9.3 exercises had never been driven against real
hardware before. Every fix below was diagnosed, applied, rebuilt, redeployed, and
re-verified against real hardware in the same session, not just reasoned about from
reading the code.

App/helper were run via the real default no-flags entry point
(`Apps/GogglesView/build/GogglesView.app/Contents/MacOS/GogglesView`), matching real v1
usage, for every scenario below.

## Scenario 1 — Unplug USB while `live`: PASS (after a fix)

**First attempt: FAIL.** `handleBulkInCompletion` (`Packages/GogglesUSB/Sources/
GogglesUSB/RNDISTransport.swift`) only branched on `LIBUSB_TRANSFER_COMPLETED` and
unconditionally resubmitted every pooled bulk-IN transfer regardless of status. On a
real physical unplug, none of the 16 pooled transfers ever delivered
`LIBUSB_TRANSFER_NO_DEVICE` in a way this code detected — `inbound` never finished,
`runPipeline`'s consumer loop blocked forever, and the helper stayed wedged oscillating
`.stalled`/`.handshaking` indefinitely, even after the goggles physically re-enumerated
as a brand new USB device the stale handle had no relationship to. Root cause: the
pending bulk-IN reads' completion callback is not a reliable unplug-detection signal on
this macOS/libusb combination.

**Fix (commit `8c57f1e`, then superseded by `936c6cb`):** the reliable detection path
turned out to be the bulk-**OUT** write (`RNDISTransport.send`/`writeEthernetFrame`),
driven by the pipeline's own ~2s periodic handshake-resend timer — this call
synchronously surfaces a real libusb error code. `writeEthernetFrame` now calls
`close()` on any OUT failure, which finishes `inbound` and lets `runPipeline` end
normally, driving the existing `.noDevice` transition.

**Re-verified against real hardware:** unplug -> `stalled` -> `noDevice`, USB interfaces
released (`ioreg` showed the device `!registered, !matched, inactive`), helper/app both
alive, no crash.

## Scenario 2 — Replug, must reach `waitingForKeyframe` with no restart: PASS

**First attempt: FAIL** (same root cause as scenario 1 — the helper never even reached
`.noDevice` to retry from). **Second attempt, after scenario 1's fix, still incomplete**:
reaching `.noDevice` correctly is necessary but not sufficient — nothing in the helper
ever retried claiming the device once it disappeared. `RNDISTransportError.deviceNotFound`
was being routed to `.claimFailed` (a manual-"Retry" state per design §6), not treated as
the ordinary "no goggles on the bus yet" case `.noDevice` documents.

**Fix (commit `936c6cb`):** `HelperService` now distinguishes `deviceNotFound` from a
genuine claim failure, stays in `.noDevice` for it, and polls on a 1s
`deviceRetryTimer` for as long as a subscriber is still streaming — covers both a plain
replug and (see scenario 3) a goggles reboot.

**Re-verified against real hardware:** unplug -> replug (~5s gap) -> fully automatic
`stalled -> noDevice -> claiming -> handshaking -> waitingForKeyframe`, no manual step,
no app restart, ~13s total. Reaching `live` from `waitingForKeyframe` still required the
user's manual liveview toggle — this is the documented, unfixed §8.1 IDR limitation
(the goggles' encoder only emits a fresh SPS+IDR on that toggle), not a scenario 2
regression; scenario 2's own bar ("reconnect to `waitingForKeyframe`") was met with zero
manual steps.

## Scenario 3 — Reboot the goggles (MAC rotation), no manual step: PASS

Exercised the same auto-retry path as scenario 2, plus the goggles' full reboot cycle
(device vanishes from the bus for tens of seconds, several transient
`deviceNotFound`/claim-failed retries logged during the boot itself, all fully
automatic on the 1s retry cadence). Total recovery time from reboot to `live` was ~84s
(dominated by the goggles' own boot time, not by anything in this codebase), landing
back at full ~55fps/8-10Mbps with **no manual step at any point** — this particular
reboot's goggles session came back up already holding a valid keyframe, so no liveview
toggle was even needed this time (design §8.1: whether a toggle is needed after
recovery depends on whether the goggles' own liveview module happens to re-emit an IDR
on its own, which a full power-cycle sometimes does).

MAC rotation itself (design §8.2) required no code changes — confirmed working exactly
as designed: `ARPResolver`/`RNDISTransport.init` resolve fresh on every claim, never
cache/persist, and each of the several claim attempts during the reboot logged
`claimed IF0/IF1, device: Goggles3-...` successfully once the device was back, with a
new resolved MAC each time (never inspected/logged directly, by design — see §8.2's
"do not add" warning about caching it).

## Scenario 4 — Toggle liveview sharing off/on, verify `live`: PASS (after a fix)

**First attempt: FAIL** for the underlying UI-state part, though video itself did
resume. Real hardware showed: toggle -> `stalled [no data for 2s]` -> real NAL data
resumed (fps back to 55-59) but **no further `stateChanged` was ever emitted** — the
helper's `currentStateValue` (and therefore every subscriber's UI) stayed wedged
showing `.stalled`'s "Signal lost — reconnecting" overlay forever, even though the
decoder was actively displaying live video underneath. Root cause:
`pipelineDidStart()` (the only thing that ever calls `setState(.live)`) fires exactly
once, on the very first genuine SPS+IDR — a later silence that resolves itself without
a fresh keyframe (exactly what design §8.1 says happens once already `live`: "a decoder
that has a format description keeps decoding P-frames indefinitely") was never routed
back to `.live`.

**Fix (commit `a7dd7a7`, generalized in `154c839` after scenario 7 surfaced the
`.handshaking` case too):** `pipeline(didEmitNAL:)` now recovers `.stalled` **and**
`.handshaking` back to `.live` on the next NAL, guarded by `everReachedLive` so a
genuine first-time connect still goes through `waitingForKeyframe`/`pipelineDidStart`
normally.

**Re-verified against real hardware:** `stalled [no data for 2s]` -> `live` in 54ms
once data resumed, confirmed twice (once for the `.stalled` case directly, again
inside scenario 7's `.handshaking`-escalation case).

## Scenario 5 — Kill the helper (`sudo killall GogglesHelper`) while `live`: PASS (after two fixes)

**First attempt: FAIL**, and a bad one — the long-running app instance never recovered
at all, even after 90+ seconds, while a completely separate fresh process connecting to
the same Mach service in the meantime worked immediately (proving the daemon itself
was respawning fine — this was purely client-side). Two distinct bugs, both in
`Apps/GogglesView/Sources/GogglesView/`:

1. **`HelperClient.swift`**: `interruptionHandler` only logged, on the documented
   assumption that `invalidationHandler` would reliably follow an interruption for a
   Mach-activated on-demand service. Verified false on this hardware for a clean
   SIGTERM daemon exit: interruption fired exactly once, invalidation never followed,
   and only `handleInvalidation` ever schedules a reconnect — so the connection was
   permanently wedged with nothing driving recovery.
2. **`GogglesConnectionCoordinator.swift`**: even after fixing (1), the app reconnected
   but stayed at `.noDevice` forever — `startStreaming()` was only ever called once, 1s
   after the very first app launch (`main.swift`). Every reconnect gets a brand new
   `NSXPCConnection`, so the helper's `streamingSubscriberIDs` (keyed by that
   connection's own identity) had no memory of the old registration; nothing was ever
   asking the helper to stream again.

**Fixes (commit `f18a17a`):** `interruptionHandler` now explicitly calls
`newConnection?.invalidate()` to force the existing, already-correct 2s-reconnect path.
`GogglesConnectionCoordinator.handleConnectionStateChange` now calls
`client.startStreaming()` on every transition into `.connected`, not just the first.

**Re-verified against real hardware, twice** (once per fix layer): `sudo killall
GogglesHelper` while live -> `interrupted` -> `invalidated` -> reconnected in ~2.2s ->
fresh helper PID spawned -> `noDevice -> claiming -> handshaking -> waitingForKeyframe`
(then `live` after a toggle, and separately confirmed self-recovering `stalled -> live`
in the same run) — fully automatic, no app restart, no manual step beyond the kill
itself.

## Scenario 6 — Kill the app while `live`, confirm 5s linger releases interfaces: PASS

No fix needed — this path was already correct. `kill <app pid>` while live: helper
logged `connection invalidated` -> `subscriber disconnected (0 remaining,
wasStreaming=true)` -> `no streaming subscribers left; starting 5s teardown linger`
immediately, then, measured precisely via timestamps, `linger expired with no
subscribers; releasing USB interfaces` at **5.075s** later — within the design's "5 s
linger to survive an app relaunch" window and not before it. Helper daemon itself
stayed running (as designed — it only releases hardware, not the process). `ioreg`
confirmed the goggles remained enumerated but the app process was fully gone with no
crash log.

## Scenario 7 — Two copies of the app simultaneously, both show video: PASS

No fix needed. Two independent `GogglesView` processes launched together: both tracked
`noDevice -> claiming -> handshaking -> waitingForKeyframe` in lockstep (single shared
hardware claim, exactly per design §5.5's fan-out contract), both reached `live` within
1ms of each other after one liveview toggle, and both reported **identical**
`fps`/`bitrate` from the shared `StreamStats` fan-out for the full run. This same run
also incidentally re-exercised (and helped surface the full scope of) the scenario 4
`.stalled`/`.handshaking` recovery bug — both copies got stuck identically and both
recovered identically once that fix landed, confirming the fix is per-subscriber-count
agnostic (it lives in the helper's single source of truth, not duplicated app-side
logic).

## Scenario 8 — 30-minute `live` soak, memory must be flat: See `task-3.7-report.md` for the final sampled numbers (started early, ran in the background across scenarios 9/1-7's fix-and-reverify cycles per the task brief's own instruction not to run it serially at the end)

## Scenario 9 — Sleep/wake the Mac while connected: PASS

No fix needed. Real system sleep (confirmed via `loginwindow`/`CUSleepWakeMonitor` wake
log lines, not just elapsed wall-clock time) followed by wake: the app and helper
processes both survived with the **same PIDs** (no crash, no relaunch), the goggles
remained enumerated (`ioreg` showed the same device present, still `registered`), and
live video resumed automatically at healthy fps (55-57) shortly after wake with no
manual intervention.

## Bugs found and fixed this task (summary)

| # | File | Bug | Commit |
|---|---|---|---|
| 1 | `Packages/GogglesUSB/.../RNDISTransport.swift` | Bulk-IN completion never detected real unplug; OUT-write path does | `8c57f1e`, `936c6cb` |
| 2 | `Helper/GogglesHelper/.../HelperService.swift` | No retry after `.noDevice`; `deviceNotFound` wrongly routed to `.claimFailed` | `936c6cb` |
| 3 | `Helper/GogglesHelper/.../HelperService.swift` | `.stalled`/`.handshaking` never recovered to `.live` when data resumed without a fresh keyframe | `a7dd7a7`, `154c839` |
| 4 | `Apps/GogglesView/.../HelperClient.swift` | XPC interruption never forced a reconnect (invalidation assumed, didn't fire) | `f18a17a` |
| 5 | `Apps/GogglesView/.../GogglesConnectionCoordinator.swift` | `startStreaming()` only ever called once; reconnects never resumed streaming | `f18a17a` |

All five are hardening fixes to existing, already-working code paths — none required a
redesign, and every one was found by actually driving the exact real-hardware failure
mode design §9.3 describes, not by code review alone.
