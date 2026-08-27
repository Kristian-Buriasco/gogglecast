#!/usr/bin/env python3
"""Extract the raw bundled SPS+PPS parameter-set blob from a GogglesView
capture file, and write it to its own small fixture file.

Context: the DJI Goggles 3 stream sends a single small H.264 access unit
(NAL type 7 = SPS, sometimes with an embedded type-8 PPS -- see
`stream.py`'s `flush_frame()` in the dji-goggles3-videoout prototype) once
at stream start, ahead of the first IDR frame. That ~40-byte blob is the
fixture the Phase 3 parameter-set split test (design.md 9.1 item 4) needs:
it asserts two NALs out (types 7 and 8) and that
`CMVideoFormatDescriptionCreateFromH264ParameterSets` succeeds with
1920x1080.

Input: a capture file produced by `stream.py --capture <file>` (see
Fixtures/README.md for the "GVCAP001" on-disk format -- a magic header
followed by [timestamp:f64][direction:u8][len:u32][raw Ethernet frame]
records for every inbound and outbound frame).

This script re-derives the video-frame reassembly that `stream.py` does
live (frame_num/frag_num bookkeeping over the DJI wire protocol's UDP
payload) against the *inbound* frames in the capture, and returns the
first reassembled H.264 access unit whose leading NAL type is 7 or 8.

Standalone: intentionally does not import anything from the
dji-goggles3-videoout prototype (a separate repo) -- the small amount of
Ethernet/UDP parsing and DJI payload field logic needed is duplicated here
so this script has no cross-repo dependency. Keep it in sync with
`rawnet.py` / `stream.py`'s `flush_frame()` there if the wire format ever
changes.

Usage:
    python3 gen_sps_pps_fixture.py <capture_file> <output_fixture_file>
"""
import struct
import sys

MAGIC = b"GVCAP001"
DIR_INBOUND = 0x00
DIR_OUTBOUND = 0x01

# The goggles send video packets from this UDP source port (see stream.py's
# DST_PORT / the "sport != DST_PORT" check in its main loop).
VIDEO_SRC_PORT = 9003


def read_capture(path: str):
    """Yield (timestamp, direction, raw_ethernet_frame) for every record in
    a GVCAP001 capture file."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != MAGIC:
        raise ValueError(f"not a GVCAP001 capture file (bad magic): {path}")
    off = 8
    n = len(data)
    while off < n:
        if off + 13 > n:
            raise ValueError(f"truncated record header at offset {off}")
        ts, direction, flen = struct.unpack_from("<dBI", data, off)
        off += 13
        if off + flen > n:
            raise ValueError(f"truncated frame body at offset {off}")
        frame = data[off:off + flen]
        off += flen
        yield ts, direction, frame


def parse_udp(frame: bytes):
    """Minimal Ethernet/IPv4/UDP parse. Mirrors rawnet.parse_udp() in the
    dji-goggles3-videoout prototype; deliberately duplicated (see module
    docstring)."""
    if len(frame) < 42 or frame[12:14] != b"\x08\x00":
        return None
    ihl = (frame[14] & 0x0F) * 4
    proto = frame[23]
    if proto != 17:
        return None
    udp_off = 14 + ihl
    if udp_off + 8 > len(frame):
        return None
    src_port, dst_port, udp_len = struct.unpack_from(">HHH", frame, udp_off)
    payload = frame[udp_off + 8: udp_off + udp_len]
    return src_port, dst_port, payload


def extract_param_set_blob(capture_path: str, video_src_port: int = VIDEO_SRC_PORT):
    """Replay stream.py's frame reassembly (frame_num -> {frag_num: bytes})
    over the inbound frames in the capture, and return the bytes of the
    first reassembled access unit whose NAL type is 7 (SPS) or 8 (PPS), or
    None if no such access unit is found."""
    frames: dict[int, dict[int, bytes]] = {}
    frame_expected_count: dict[int, int] = {}

    for _ts, direction, eth_frame in read_capture(capture_path):
        if direction != DIR_INBOUND:
            continue
        parsed = parse_udp(eth_frame)
        if not parsed:
            continue
        sport, _dport, payload = parsed
        if sport != video_src_port or len(payload) < 20:
            continue

        pkt_type = payload[6]
        if pkt_type != 0x02:
            continue

        frame_num = payload[16]
        b17 = payload[17]
        frag_count = b17 & 0x7F
        frag_lsb = (b17 >> 7) & 1
        frag_num = ((payload[18] & 0x1F) << 1) | frag_lsb
        h264_chunk = payload[20:]

        frames.setdefault(frame_num, {})[frag_num] = h264_chunk
        frame_expected_count[frame_num] = frag_count

        if len(frames[frame_num]) < frag_count:
            continue

        frags = frames.pop(frame_num)
        frame_expected_count.pop(frame_num, None)
        data = b"".join(frags[i] for i in sorted(frags))
        if not data:
            continue

        nal_off = 4 if data[:4] == b"\x00\x00\x00\x01" else 0
        if len(data) <= nal_off:
            continue
        nal_type = data[nal_off] & 0x1F
        if nal_type in (7, 8):
            return data

    return None


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <capture_file> <output_fixture_file>",
              file=sys.stderr)
        return 2

    capture_path, out_path = sys.argv[1], sys.argv[2]
    blob = extract_param_set_blob(capture_path)
    if blob is None:
        print("No SPS/PPS parameter-set NAL found in capture (looked for "
              "the first reassembled H.264 access unit, among inbound "
              "frames, with NAL type 7 or 8).", file=sys.stderr)
        return 1

    with open(out_path, "wb") as f:
        f.write(blob)
    print(f"Wrote {len(blob)}-byte parameter-set blob to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
