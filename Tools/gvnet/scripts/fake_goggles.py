#!/usr/bin/env python3
"""Tiny stand-in for the goggles' UDP 9003 liveview: waits for the 48-byte handshake, then sends
SPS, PPS, an IDR (split into fragments) and a few P frames. For testing gvnet without hardware.
usage: fake_goggles.py [--bind 127.0.0.1] [--port 9003]"""
import argparse, socket, struct, time

def outer(ptype, seq, body, session):
    total = (8 + len(body)) | 0x8000
    h = struct.pack("<HHHB", total, session, seq, ptype)
    x = 0
    for b in h:
        x ^= b
    return h + bytes([x]) + body

def video(seq, session, frame, count, index, payload):
    sub = bytearray(12)
    sub[8] = frame
    sub[9] = (count & 0x7F) | ((index & 1) << 7)
    sub[10] = (index >> 1) & 0x1F
    return outer(2, seq, bytes(sub) + payload, session)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9003)
    a = ap.parse_args()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((a.bind, a.port))
    print("waiting for handshake", flush=True)
    while True:
        data, peer = s.recvfrom(4096)
        if len(data) == 48 and data[6] == 0:
            break
    session = struct.unpack_from("<H", data, 2)[0]
    print("handshake from", peer, "session", session, flush=True)
    sc = b"\x00\x00\x00\x01"
    seq, frame = 0, 0
    def send_nal(nal, frags=1):
        nonlocal seq, frame
        chunk = max(1, len(nal) // frags)
        parts = [nal[i * chunk:(i + 1) * chunk] for i in range(frags - 1)] + [nal[(frags - 1) * chunk:]]
        for i, p in enumerate(parts):
            s.sendto(video(seq, session, frame & 0xFF, frags, i, p), peer)
            seq += 8
        frame += 1
    send_nal(sc + b"\x67" + bytes(range(1, 20)))
    send_nal(sc + b"\x68" + bytes(range(1, 8)))
    send_nal(sc + b"\x65" + bytes(range(200)) * 3, frags=4)
    for _ in range(30):
        send_nal(sc + b"\x41" + bytes(60))
        time.sleep(0.02)
    s.settimeout(1)
    acks = 0
    try:
        while True:
            d, _ = s.recvfrom(4096)
            if d[6] in (4, 6):
                acks += 1
    except socket.timeout:
        pass
    print("acks received:", acks, flush=True)

main()
