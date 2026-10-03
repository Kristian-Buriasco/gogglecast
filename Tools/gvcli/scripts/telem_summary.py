#!/usr/bin/env python3
"""Summarize a `gvcli ... --dump-telemetry` JSONL capture.

Usage:
  python3 telem_summary.py telem.jsonl                 # message inventory
  python3 telem_summary.py telem.jsonl 09:08           # per-byte variability for one cmd
  python3 telem_summary.py telem.jsonl 09:08 --series 0:u8 2:u16   # time series of fields

Inventory: for each (src>dst, cmd) -> count, rate (Hz), payload lengths,
decoded kind. Also reports type-0x01 packets that carried NO valid DUML
frame, and whether the documented length prefix matched.

Per-byte view: for one cmd, shows each payload byte offset's min/max/
distinct-count across the capture -- constant bytes are framing/IDs,
slowly-changing ones are counters/battery, fast-changing ones are
sticks/attitude/link quality. Diff two captures (sticks idle vs. moving)
to localise fields.
"""
import json
import struct
import sys
from collections import defaultdict

FMT = {"u8": "<B", "i8": "<b", "u16": "<H", "i16": "<h", "u32": "<I", "i32": "<i", "f32": "<f", "f64": "<d"}


def load(path):
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                yield json.loads(line)


def inventory(recs):
    stats = defaultdict(lambda: {"n": 0, "lens": set(), "kinds": set(), "t0": None, "t1": None, "name": None})
    types = defaultdict(int)
    no_duml = 0
    prefix_ok = defaultdict(int)
    for r in recs:
        types[r["type"]] += 1
        if r["type"] == 1:
            if not r["duml"]:
                no_duml += 1
            prefix_ok[str(r.get("duml_len_prefix_ok"))] += 1
        for f in r["duml"]:
            k = f"{f['src']}>{f['dst']} {f['cmd']} {'rsp' if f['is_response'] else 'req'}"
            s = stats[k]
            s["n"] += 1
            s["lens"].add(f["payload_len"])
            s["name"] = f.get("name") or f.get("set_name") or ""
            if f.get("decoded"):
                s["kinds"].add(f["decoded"]["kind"])
            s["t0"] = r["t"] if s["t0"] is None else s["t0"]
            s["t1"] = r["t"]
    print("outer packet types:", dict(types))
    print(f"type-0x01 packets with no valid DUML frame: {no_duml}")
    print("type-0x01 length-prefix-matches:", dict(prefix_ok))
    print()
    print(f"{'src>dst cmd dir':28} {'count':>6} {'Hz':>6}  lens  name / decoded")
    for k in sorted(stats, key=lambda k: -stats[k]["n"]):
        s = stats[k]
        span = (s["t1"] - s["t0"]) if s["n"] > 1 else 0
        hz = (s["n"] - 1) / span if span > 0 else 0
        print(f"{k:28} {s['n']:6d} {hz:6.1f}  {sorted(s['lens'])}  {s['name']} {sorted(s['kinds']) or ''}")


def payloads(recs, cmd):
    for r in recs:
        for f in r["duml"]:
            if f["cmd"] == cmd:
                yield r["t"], bytes.fromhex(f["payload_hex"])


def per_byte(recs, cmd):
    rows = list(payloads(recs, cmd))
    if not rows:
        print("no frames for", cmd)
        return
    width = max(len(p) for _, p in rows)
    print(f"{cmd}: {len(rows)} frames, max payload {width} bytes")
    print("off  min  max  distinct  first")
    for o in range(width):
        vals = [p[o] for _, p in rows if len(p) > o]
        print(f"{o:3d}  {min(vals):3d}  {max(vals):3d}  {len(set(vals)):8d}  {vals[0]:02x}")


def series(recs, cmd, specs):
    parsed = []
    for s in specs:
        off, typ = s.split(":")
        parsed.append((int(off), FMT[typ]))
    t0 = None
    for t, p in payloads(recs, cmd):
        t0 = t if t0 is None else t0
        vals = []
        for off, fmt in parsed:
            size = struct.calcsize(fmt)
            vals.append(struct.unpack_from(fmt, p, off)[0] if len(p) >= off + size else None)
        print(f"{t - t0:8.3f}  " + "  ".join(str(v) for v in vals))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    recs = list(load(sys.argv[1]))
    if len(sys.argv) == 2:
        inventory(recs)
    elif len(sys.argv) >= 4 and sys.argv[3] == "--series":
        series(recs, sys.argv[2], sys.argv[4:])
    else:
        per_byte(recs, sys.argv[2])


if __name__ == "__main__":
    main()
