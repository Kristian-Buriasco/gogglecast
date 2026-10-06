# Benchmark / latency mode

Settings > Advanced > **Run benchmark…** opens a window that measures the live
stream of the goggles window app-level commands act on (the key goggles window,
else the most recently focused one). Pick a duration (10/30/60/120 s, default
30), press **Run**, then **Copy report** (plain text) or **Save as JSON…**.
Run is disabled, with a message, when no goggles window is open or its stream
is not live.

The point is a baseline: run it before and after a change (or on two machines,
or two USB ports) and compare. Close other heavy apps first. A single run
says little; repeat it.

## Where the numbers come from

```
goggles sensor -> encoder -> air link -> goggles -> USB -> helper (libusb, reassembly)
   [not visible to us .................................]   |
                                                     hostTime stamp (uptime ns)
                                                           |  XPC
                                                     app main queue -> DecodeSession
                                                           |  enqueue on display layer
                                                     BenchmarkRecorder sees the sample  <- "arrival"
                                                           |
                       VideoToolbox decode -> compositor -> display scan-out
                       [not measured .........................................]
```

`BenchmarkRecorder` is registered on the session's `DecodeSession` as an extra
`SampleBufferRendering` consumer for the length of the run, so it receives
exactly the sample buffers the window's display layer gets, a few microseconds
after the display layer's `enqueue` returned. Each sample's presentation
timestamp is the helper's `hostTime`, `DispatchTime.now().uptimeNanoseconds` in
the helper process, which is the same clock as in the app.

A "frame" below is one slice sample handed to the display layer, i.e. one
output of the helper's `FrameReassembler` (the stamp is taken in
`GogglesPipeline` right after reassembly, see `Pipeline.swift`). If a stream
ever carried several slice NALs per picture, counts and fps would be per NAL.

## The numbers

### Frames (arrival at display layer)

- **fps avg**: (frames - 1) / time from first to last frame.
- **fps min 1s**: fewest frames in any complete one-second window, counted
  from the first frame. Partial last second is ignored, so short runs (< 1 s of
  frames) show n/a.
- **fps 1% low**: 1000 / mean of the slowest 1% of frame intervals (at least
  one interval). Catches the occasional hitch the average hides.
- **frame interval mean / max**: gap between consecutive frames, ms.
- **jitter**: population standard deviation of the frame intervals, ms. Lower
  is smoother. Includes stalls, so one long stall inflates it.
- **stalls**: intervals longer than 100 ms, and their summed length. A stall
  means nothing reached the display layer for that long, whatever the cause
  (radio, USB, helper, main thread busy).

### Latency: helper stamp -> display layer enqueue

`arrival - hostTime` for every slice, reported as p50/p95/p99/max (and mean,
n). This is the same quantity the OSD's "Latency (helper to screen)" shows,
but unsmoothed and with percentiles. It covers:

- the helper fanning the NAL out over XPC (the stamp is taken after reassembly),
- XPC transfer and delivery to the app's main queue,
- main-queue waiting behind other work (UI, other windows),
- Annex B to AVCC conversion and `CMSampleBuffer` construction.

It does **not** cover anything before the stamp or after the enqueue, see
below. Samples whose stamp is missing or in the future are skipped.

### Stream

- **bitrate (app, slices)**: bytes of slice samples enqueued / measured
  duration. Excludes parameter sets.
- **bitrate (helper)**: from the helper's `StreamStats.cumulativeBytes`, delta
  over the run. n/a if no stats arrived. Should be close to the app figure; a
  big difference means NALs are not reaching the app.
- **dropped frames (helper reassembly)**: `StreamStats.cumulativeDrops` delta,
  frames the helper could not reassemble (missing USB/air-link pieces).
- **decode teardowns**: times `DecodeSession` gave up after 30 consecutive
  decode failures during the run (should be 0).
- **renderer counters** (macOS 14.4+): deltas of the display layer's
  `AVSampleBufferVideoRenderer` performance metrics: frames, frames dropped by
  the renderer (late or before decode), corrupted frames, and frames shown via
  optimized (direct-to-display) compositing. Only the window's primary layer;
  n/a if the layer was replaced mid-run or the API is unavailable.

### Process

- **CPU**: this app's user+system CPU time (`getrusage`) over wall time,
  sampled once a second, as % of one core (can exceed 100 % on several cores).
  Average and peak of the one-second samples. The helper daemon and
  WindowServer are separate processes and not included.
- **memory**: `phys_footprint` (Activity Monitor's "Memory") sampled once a
  second; peak and value at the end.

### Environment

App version/build, macOS version, Mac model and CPU architecture (same sources
as the diagnostics report), goggles model and serial (last four characters
only), USB vendor/product id, bus/address and `bcdDevice` from the helper's
device info, the negotiated USB link speed (read from the IORegistry
`IOUSBHostDevice` entry matching the goggles' VID/PID and serial; "unknown" if
not found), and the stream resolution from the SPS.

## What it cannot see

- **Goggles-internal latency**: camera exposure, encode, air link, the
  goggles' own buffering and USB send. The stamp happens when the helper has
  the NAL, so all of that is invisible. Measuring glass-to-glass needs an
  external method (film a running clock and the screen with a high-speed
  camera, or an LED/photodiode rig).
- **USB transfer and helper reassembly** before the stamp.
- **Decode-to-present**: deliberately omitted. Frames are enqueued with
  `DisplayImmediately`, and `AVSampleBufferDisplayLayer` exposes no per-frame
  "decoded" or "presented" callback or timestamp. The renderer's
  `totalAccumulatedFrameDelay` is measured against the presentation
  timestamp schedule, which we do not use (no timebase), so it does not mean
  decode-to-present here and is not reported. Any number we printed for this
  segment would be a guess.
- **Compositor and display scan-out** (WindowServer, refresh rate, display
  processing). A 60 Hz display alone adds 0-16.7 ms that is not counted.
- **Other windows of the same session**: only the primary layer's renderer
  counters are read; the capture/mini windows and outputs (recording,
  streaming) still receive the same samples and cost CPU, which does show up
  in the CPU figure.

## Race mode

Settings > Display > **Race mode**, Goggles menu > Race Mode, the menu-bar menu,
`gogglesview://race/on|off|toggle` and the AppleScript property `race mode`
(read/write) switch the lowest-latency preview. It is app-wide, applies
instantly and survives restarts (`raceMode` in UserDefaults, default off). A red
RACE badge shows in the video window (not in the capture window, which stays
clean for OBS). No global hotkey: the hotkeys are per-window and a test pins
their count, so it was not trivial.

### Audit of the preview path

Already minimal, unchanged:

- Decoder: `kVTDecompressionPropertyKey_RealTime` is set, frames are decoded with
  `_EnableAsynchronousDecompression` + `_1xRealTimePlayback`, and
  `EnableTemporalProcessing` is not set, so output is in decode order with no
  reorder queue. The decoder is a single session shared by all windows.
- Display: pictures are enqueued with `kCMSampleAttachmentKey_DisplayImmediately`,
  there is no timebase/presentation clock, and the layer is the view's backing
  layer (no extra passthrough layer). Layout transforms (orientation, zoom, pan,
  crop) are compositor-side and cost no frame delay.
- Idle features cost nothing: the keyframe re-encode hub only runs while
  something subscribes; the output crop/look (`OutputProcessor`) runs only in
  that hub; the benchmark recorder exists only during a run; recording
  passthrough taps the compressed NALs, not the preview.

Avoidable, now removed by race mode (all live, no decoder re-creation):

| Item | Cost | Race mode |
|---|---|---|
| Stabilizer | CoreImage render + Vision registration on the decode callback, a few ms per frame, inline before the frame is shown | bypassed (and its state reset) |
| Preview LUT, brightness/contrast/saturation | `CALayer.filters` evaluated by the compositor every frame | filters removed |
| Grid overlay | extra shape layer | emptied |
| Stats overlay (OSD) | SwiftUI re-render on the main thread, which also feeds the decoder | hidden |
| Mini window | a second display layer enqueued from the decode callback, plus a window to composite | hidden (preference kept, restored when race mode ends) |
| Decoder power hints | `MaximizePowerEfficiency` may let the hardware decoder favour efficiency | set to false on the running session; original value restored when race mode ends |

The decoder is also created with `EnableHardwareAcceleratedVideoDecoder` set (not
`Require`, so software remains the fallback). On Apple Silicon hardware decode is
the default, so this is an explicit statement rather than a change.

Why no decoder re-creation: every property above applies to a live
`VTDecompressionSession`, and the goggles send a single IDR, so re-creating the
decoder would freeze the picture until the next IDR. If a future property ever
needs it, it must go through the existing `decoderReady` IDR gate, never an
unconditional invalidate.

Not touched on purpose:

- Capture window (OBS): an output, kept. It adds one more `enqueue` per frame;
  close it while racing if every millisecond counts.
- Replay buffer / keyframe hub: when replay is enabled in Settings, the hub
  polls every 8 ms **on the main queue**, which is also where NALs are delivered
  and decoded. That is the main remaining avoidable cost for people who leave
  replay on. Recommendation (not done, it changes threading of the hub): run the
  hub's timer on its own serial queue. Race mode does not disable replay or any
  stream and never starts the hub.
- Stabilized frames are not recorded or streamed while race mode is on, because
  those outputs read the same decoded picture.

Remaining costs outside race mode's reach:

- The whole decode feed (XPC callback -> Annex B to AVCC copy -> sample buffer ->
  `VTDecompressionSessionDecodeFrame`) runs on the main queue. Anything slow on
  main (any SwiftUI update, another window) delays the next frame. Moving it to a
  dedicated queue would remove that coupling but changes `DecodeSession`'s
  threading contract; not done here.
- `decoded()` builds a new `CMVideoFormatDescription` per frame; microseconds, cached
  would be marginally cheaper.
- The display's refresh (0-16.7 ms at 60 Hz) and the compositor.

### Measurement

Not measured. A synthetic H.264 source for `DecodeSession` needs the bundled
parameter-set blob format and a real encoder loop, and a decode-latency number
without the real goggles stream would not reflect the 146 ms glass-to-glass path
(our share is a few ms). To compare, run Settings > Advanced > Run benchmark
once with race mode off and once on, on a live stream.
