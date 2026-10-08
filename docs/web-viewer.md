# Web viewer

A small HLS server inside the app. Off by default. Enable it in Settings > Web Viewer.

## Watch on an iPad or phone

1. Turn on **Enable local web viewer** and **Allow other devices on the network**. A random access token is created automatically.
2. Scan the QR code in the Settings card with the iPad or phone camera, or press **Copy URL** and send it over. The card shows the Mac's `<hostname>.local` address and its IP address; the QR code uses the IP, which is the more reliable of the two on iOS.
3. The device must be on the same network as the Mac. The app advertises itself as "GogglesView" (`_http._tcp`, Bonjour) only while Allow other devices is on.
4. In Safari: Share > Add to Home Screen gives a full-screen app. The page has a Full screen button, tap-to-freeze (tap again to resume at the live edge), a LIVE indicator with how many seconds it is behind, and a Back to live button.

The page retries by itself with a growing delay when the stream restarts or the Mac sleeps, and shows Waiting for the stream, Connecting, Live or Stream ended (with a Retry button).

Playback uses the browser's native HLS, so Safari (iPad, iPhone, Mac) works; other desktop browsers do not play HLS natively. Use VLC with `live.m3u8` there.

## Security

- Plain HTTP, no encryption; the token travels in the URL. Keep it off on untrusted networks.
- Every route needs the token: page, playlist, segments, manifest and icons. Nothing is public. The page links its manifest and icons with the token in the query string.
- The `Host` header must be localhost, or (with LAN access on) this Mac's `.local` name or one of its IP addresses, which blocks DNS rebinding.
- Without LAN access the server listens on 127.0.0.1 only.

## Latency

Segments are cut on keyframes (the encoder emits one per second), so they are about 1 s long (previously 2 s), the playlist lists the newest 8, and it carries `EXT-X-START:TIME-OFFSET=-3` so Safari starts near the live edge. Safari normally begins about three target durations behind the end of a live playlist, so the expected glass-to-glass delay is a few seconds (roughly 3 to 5 s) instead of the earlier 4 to 8 s.

These figures are an estimate from how HLS players behave, not a measurement on an iPad. The page shows its own estimate (distance from the playlist's live edge, which does not include capture, encode and network delay). Low-latency HLS with partial segments (`EXT-X-PART`) was not implemented: it needs chunked-transfer blocking playlist reload and is a much larger change.
