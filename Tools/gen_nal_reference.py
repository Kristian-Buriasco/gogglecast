#!/usr/bin/env python3
"""Generate the NAL-type/length reference vector for the Swift integration
test required by plan task 1.4's exit criterion:

    the full protocol core, driven by MockTransport replaying
    Fixtures/clean-start.gvcap, emits the expected NAL sequence -- verified
    against a reference NAL-type/length list extracted from the same
    capture by a Python script.

Walks Fixtures/clean-start.gvcap record by record (the on-disk format is
documented in Fixtures/README.md and in dji-goggles3-videoout/stream.py's
CaptureWriter docstring), extracts every inbound UDP:9003 video packet
(outer-header pktType == 0x02), and feeds them through a REIMPLEMENTATION
of the Swift `FrameReassembler`'s corrected reassembly algorithm (age +
mod-256-distance eviction, discard-not-merge on eviction -- see
Packages/GogglesProtocol/Sources/GogglesProtocol/FrameReassembler.swift).

Why reimplement rather than import the prototype's stream.py reassembly
logic directly (the way Tools/gen_golden.py imports duml/rawnet/rndis/
stream for task 0.4's parity vectors): stream.py's inline reassembly logic
(the `frames`/`frame_expected_count` dicts + `flush_frame` in main()) has a
known bug task 1.3 deliberately fixed -- it only ever evicts the *current*
frame number, so a fragment lost mid-frame can leave a stale entry that
silently merges with an unrelated later frame reusing the same mod-256
frame number (see FrameReassembler.swift's header comment for the full
writeup). This reference must describe what the CORRECTED Swift pipeline
emits, not what the buggy prototype would -- so it is not "the same
[buggy] logic ported to Python", it is a faithful Python port of the
already-corrected Swift algorithm. It stays byte-for-byte behaviorally
equivalent to FrameReassembler.swift: same field offsets, same stale-entry
eviction rule (mod-256 distance > 5 OR age > 250ms), same discard-not-merge
semantics, same start-code-prepend rule. If FrameReassembler.swift's
algorithm ever changes, this script must change with it.

Ethernet/IPv4/UDP framing parsing (telling a video packet apart from ARP/
other traffic and extracting the UDP payload) DOES reuse the prototype's
`rawnet.parse_udp` by importing it directly from
~/PycharmProjects/dji-goggles3-videoout (read-only reference, not vendored
into this repo) -- that parsing is unrelated to the reassembler-correctness
bug above and reusing the proven-correct implementation (task 0.4's golden
vectors already cover it byte-for-byte against the Swift port) is strictly
more robust than re-deriving Ethernet offsets by hand a second time.

Output: Fixtures/clean_start_nal_reference.json, a JSON array of
{"nalType": int, "length": int} objects (length is the length of the fully
reassembled NAL INCLUDING the prepended 4-byte 0x00000001 start code, since
that's exactly what FrameReassembler.process returns and what the Swift
test will measure), one entry per NAL FrameReassembler emits, in emission
order. `nalType` is `data[startCodeLen] & 0x1F` where `startCodeLen` is 4
(FrameReassembler always emits with a start code -- see
`assembleNAL`/`startCode` in FrameReassembler.swift).

Run from anywhere:
    python3 Tools/gen_nal_reference.py
"""
import json
import os
import struct
import sys

PROTOTYPE_DIR = os.path.expanduser("~/PycharmProjects/dji-goggles3-videoout")
sys.path.insert(0, PROTOTYPE_DIR)

import rawnet  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAPTURE_PATH = os.path.join(REPO_ROOT, "Fixtures", "clean-start.gvcap")
OUT_PATH = os.path.join(REPO_ROOT, "Fixtures", "clean_start_nal_reference.json")

GVCAP_MAGIC = b"GVCAP001"
DIR_INBOUND = 0x00
GOGGLES_UDP_PORT = 9003
PKT_TYPE_VIDEO = 0x02

# Mirrors FrameReassembler.swift's eviction thresholds exactly.
MAX_FRAME_AGE_DISTANCE = 5
MAX_FRAME_AGE_INTERVAL = 0.250  # seconds

START_CODE = bytes([0x00, 0x00, 0x00, 0x01])


# ═══════════════════════════════════════════════════════════════════════
# .gvcap reader
# ═══════════════════════════════════════════════════════════════════════

def read_gvcap_records(path):
    """Yields (timestamp: float, direction: int, frame: bytes) for every
    record in a .gvcap file, in on-disk order."""
    with open(path, "rb") as f:
        magic = f.read(len(GVCAP_MAGIC))
        if magic != GVCAP_MAGIC:
            raise ValueError(f"{path}: bad magic {magic!r}, expected {GVCAP_MAGIC!r}")
        while True:
            header = f.read(13)
            if len(header) == 0:
                break
            if len(header) < 13:
                raise ValueError(f"{path}: truncated record header at EOF")
            ts, direction, frame_len = struct.unpack("<dBI", header)
            frame = f.read(frame_len)
            if len(frame) < frame_len:
                raise ValueError(f"{path}: truncated frame body at EOF")
            yield ts, direction, frame


def inbound_video_payloads(path):
    """Yields (timestamp, video_payload) for every inbound UDP:9003 video
    (pktType 0x02) packet in the capture -- video_payload is the outer-
    header's body (everything after the 8-byte outer header), matching
    what FrameReassembler.process(videoPayload:) expects."""
    for ts, direction, frame in read_gvcap_records(path):
        if direction != DIR_INBOUND:
            continue
        parsed = rawnet.parse_udp(frame)
        if parsed is None:
            continue
        src_ip, dst_ip, sport, dport, payload = parsed
        if sport != GOGGLES_UDP_PORT or len(payload) < 8:
            continue
        pkt_type = payload[6]
        if pkt_type != PKT_TYPE_VIDEO:
            continue
        body = payload[8:]
        yield ts, body


# ═══════════════════════════════════════════════════════════════════════
# Reassembler -- Python port of FrameReassembler.swift's corrected algorithm
# ═══════════════════════════════════════════════════════════════════════

class Entry:
    __slots__ = ("fragments", "expected_count", "first_seen_at")

    def __init__(self, expected_count, first_seen_at):
        self.fragments = {}
        self.expected_count = expected_count
        self.first_seen_at = first_seen_at


def mod256_distance(frm, to):
    """Matches FrameReassembler.mod256Distance: steps forward from `frm`
    (wrapping at 256) to reach `to`."""
    return (to - frm) & 0xFF


class FrameReassembler:
    def __init__(self):
        self.entries = {}
        self.dropped_frame_count = 0

    def _evict_stale_entries(self, current_frame_num, now):
        for num in list(self.entries.keys()):
            entry = self.entries.get(num)
            if entry is None:
                continue
            distance = mod256_distance(num, current_frame_num)
            age = now - entry.first_seen_at
            if distance > MAX_FRAME_AGE_DISTANCE or age > MAX_FRAME_AGE_INTERVAL:
                del self.entries[num]
                self.dropped_frame_count += 1

    def process(self, video_payload, received_at):
        if len(video_payload) < 12:
            return None

        frame_num = video_payload[8]
        b17 = video_payload[9]
        b18 = video_payload[10]
        frag_count = b17 & 0x7F
        frag_num = ((b18 & 0x1F) << 1) | (b17 >> 7)
        chunk = video_payload[12:]

        self._evict_stale_entries(frame_num, received_at)

        entry = self.entries.get(frame_num)
        if entry is None:
            entry = Entry(expected_count=frag_count, first_seen_at=received_at)
        entry.expected_count = frag_count
        entry.fragments[frag_num] = chunk
        self.entries[frame_num] = entry

        if len(entry.fragments) < frag_count or frag_count == 0:
            return None

        del self.entries[frame_num]
        return self._assemble_nal(entry.fragments)

    @staticmethod
    def _assemble_nal(fragments):
        data = b"".join(fragments[k] for k in sorted(fragments.keys()))
        if not data:
            return None
        if data[:4] == START_CODE:
            return data
        return START_CODE + data


# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

def main():
    reassembler = FrameReassembler()
    nal_reference = []

    for ts, video_payload in inbound_video_payloads(CAPTURE_PATH):
        nal = reassembler.process(video_payload, ts)
        if nal is None:
            continue
        nal_type = nal[4] & 0x1F  # nal[0:4] is always the start code here
        nal_reference.append({"nalType": nal_type, "length": len(nal)})

    with open(OUT_PATH, "w") as f:
        json.dump(nal_reference, f, indent=2)
        f.write("\n")

    print(f"Wrote {len(nal_reference)} NAL reference entries to {OUT_PATH}")
    print(f"dropped_frame_count during generation: {reassembler.dropped_frame_count}")


if __name__ == "__main__":
    main()
