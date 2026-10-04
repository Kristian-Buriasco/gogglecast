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
