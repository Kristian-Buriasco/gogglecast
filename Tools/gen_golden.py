#!/usr/bin/env python3
"""Generate golden test vectors for the Swift-vs-Python wire-protocol parity
tests required by design.md §9.1 item 2 / plan task 0.4.

Imports the prototype's `rawnet`, `rndis`, `duml` and `stream` modules
directly from ~/PycharmProjects/dji-goggles3-videoout (a separate repo, not
vendored here) and calls their real functions to produce byte-exact
expected outputs. Writes Fixtures/golden.json, which a future Swift test
target parses and replays against the Swift reimplementations — the Swift
result must equal the `output` field byte-for-byte (or value-for-value, for
non-byte results such as CRCs).

Run from anywhere:
    python3 Tools/gen_golden.py

Determinism: `stream.build_outer` normally salts its 8-byte header with a
random-at-import `SESSION_ID` (`random.randint(1, 0xFFFE)` at module scope
in stream.py). That would make golden.json different on every run. This
script overrides `stream.SESSION_ID` to a fixed constant
(`FIXED_SESSION_ID` below) immediately after importing the module and
before calling anything that reads it, so every regeneration produces a
byte-identical file. No other prototype state is randomized.

── JSON schema ──────────────────────────────────────────────────────────
golden.json is a JSON array of vector objects. Every vector has:
    name        string, unique, stable identifier for the vector
    description string, one-line human-readable note on what it exercises
    inputs      object mapping the Python function's parameter names to
                JSON-representable values:
                  - raw bytes / bytearray  -> lowercase hex string, no
                    spaces or "0x" prefix (b"\\x01\\x02" -> "0102"); empty
                    bytes -> ""
                  - a list of byte-strings (e.g. multiple frames fed to one
                    call) -> JSON array of hex strings
                  - IPv4 address           -> dotted-decimal string, as-is
                  - int                    -> JSON number
                  - None / not applicable  -> omitted from the object
    output      the function's return value, JSON-encoded with the same
                hex-string convention as `inputs`:
                  - bytes result                    -> hex string
                  - None result                      -> JSON null
                  - tuple/dataclass result            -> JSON object with
                    one key per field, named in camelCase to match the
                    planned Swift API (e.g. parse_udp's (src_ip, dst_ip,
                    src_port, dst_port, payload) -> {srcIp, dstIp,
                    srcPort, dstPort, payloadHex})
                  - list-of-frames result (e.g.
                    rndis.unwrap_packet_msg)           -> JSON array of hex
                    strings
                  - duml.parse_stream's (packets, tail) -> {packets: [...],
                    tailHex}, each packet an object with camelCase fields
                    matching duml.DumlPacket plus payloadHex/rawHex
                  - plain int result (crc8/crc16/checksum16)
                                                        -> JSON number

Every vector is produced by literally calling the prototype function with
the literal `inputs` shown (decoded from hex/etc. as above) — this script
does not hand-compute any expected output.
"""
import json
import os
import sys

PROTOTYPE_DIR = os.path.expanduser("~/PycharmProjects/dji-goggles3-videoout")
sys.path.insert(0, PROTOTYPE_DIR)

import rawnet   # noqa: E402
import rndis    # noqa: E402
import duml     # noqa: E402
import stream   # noqa: E402

# Fixed for reproducibility -- see module docstring. Chosen arbitrarily;
# only requirement is that it fits the 16-bit SESSION_ID field.
FIXED_SESSION_ID = 0x1234
stream.SESSION_ID = FIXED_SESSION_ID

OUT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Fixtures", "golden.json",
)

vectors = []


def add(name, description, inputs, output):
    vectors.append({
        "name": name,
        "description": description,
        "inputs": inputs,
        "output": output,
    })


def h(b) -> str:
    """bytes/bytearray -> lowercase hex string."""
    return bytes(b).hex()


def hx(s: str) -> bytes:
    """lowercase/mixed hex string -> bytes."""
    return bytes.fromhex(s)


# ── Shared test constants ────────────────────────────────────────────────
HOST_MAC = bytes.fromhex("020000000001")
GOGGLES_MAC = bytes.fromhex("aabbccddeeff")
HOST_IP = "192.168.60.1"
GOGGLES_IP = "192.168.60.2"
SRC_PORT = 54321
DST_PORT = 9003


# ═══════════════════════════════════════════════════════════════════════
# rawnet.py — checksum16
# ═══════════════════════════════════════════════════════════════════════

# Classic RFC 1071 worked example (even-length input).
_c16_even = bytes.fromhex("4500003c1c4640004006")
add(
    "checksum16_even_length",
    "IPv4 header checksum over an even-length byte string (RFC 1071-style worked example).",
    {"data": h(_c16_even)},
    rawnet.checksum16(_c16_even),
)

# Odd-length input exercises the zero-pad-then-sum branch.
_c16_odd = bytes.fromhex("450000") + b"\x01"
add(
    "checksum16_odd_length_padding",
    "checksum16 with an odd-length input, exercising the trailing zero-byte pad before summing.",
    {"data": h(_c16_odd)},
    rawnet.checksum16(_c16_odd),
)

# A real IPv4 header (as built by build_udp, minus the checksum field
# itself) run through checksum16 directly.
_ip_hdr_wo_cksum = bytes.fromhex("4500002812340000400011000000c0a83c01c0a83c02")
add(
    "checksum16_real_ipv4_header",
    "checksum16 over a realistic 20-byte IPv4 header (checksum field zeroed), matching what build_udp computes internally.",
    {"data": h(_ip_hdr_wo_cksum)},
    rawnet.checksum16(_ip_hdr_wo_cksum),
)


# ═══════════════════════════════════════════════════════════════════════
# rawnet.py — build_udp / build_arp_request / build_arp_reply
# ═══════════════════════════════════════════════════════════════════════

_udp_payload = bytes.fromhex("de ad be ef 00 01 02 03".replace(" ", ""))
_udp_frame = rawnet.build_udp(HOST_MAC, GOGGLES_MAC, HOST_IP, GOGGLES_IP,
                               SRC_PORT, DST_PORT, _udp_payload)
add(
    "build_udp_basic",
    "build_udp with a small non-empty payload; covers Ethernet+IPv4+UDP header assembly and the IPv4 checksum.",
    {
        "srcMac": h(HOST_MAC), "dstMac": h(GOGGLES_MAC),
        "srcIp": HOST_IP, "dstIp": GOGGLES_IP,
        "srcPort": SRC_PORT, "dstPort": DST_PORT,
        "payload": h(_udp_payload),
    },
    h(_udp_frame),
)

_udp_frame_empty = rawnet.build_udp(HOST_MAC, GOGGLES_MAC, HOST_IP, GOGGLES_IP,
                                     SRC_PORT, DST_PORT, b"")
add(
    "build_udp_empty_payload",
    "build_udp with a zero-length payload -- edge case for the length/checksum fields.",
    {
        "srcMac": h(HOST_MAC), "dstMac": h(GOGGLES_MAC),
        "srcIp": HOST_IP, "dstIp": GOGGLES_IP,
        "srcPort": SRC_PORT, "dstPort": DST_PORT,
        "payload": "",
    },
    h(_udp_frame_empty),
)

_arp_req = rawnet.build_arp_request(HOST_MAC, HOST_IP, GOGGLES_IP)
add(
    "build_arp_request_basic",
    "build_arp_request: a broadcast 'who-has GOGGLES_IP' ARP request, as sent by resolve_goggles_mac.",
    {"srcMac": h(HOST_MAC), "srcIp": HOST_IP, "targetIp": GOGGLES_IP},
    h(_arp_req),
)

_arp_reply = rawnet.build_arp_reply(HOST_MAC, HOST_IP, GOGGLES_MAC, GOGGLES_IP)
add(
    "build_arp_reply_basic",
    "build_arp_reply: a unicast ARP reply to the goggles, as sent by main()'s ARP-request handler.",
    {"srcMac": h(HOST_MAC), "srcIp": HOST_IP, "dstMac": h(GOGGLES_MAC), "dstIp": GOGGLES_IP},
    h(_arp_reply),
)


# ═══════════════════════════════════════════════════════════════════════
# rawnet.py — parsers (parse_udp, parse_arp)
#
# Note: rawnet.py defines exactly two parse_* functions (parse_udp,
# parse_arp) despite design.md §9.1 item 2 saying "the three parsers" --
# verified by reading rawnet.py directly, and by grepping the whole
# prototype tree for `def parse_`, which turns up only these two plus
# duml.parse_stream (already covered separately, later in this file, per
# its own bullet in the §9.1 list). Rather than fabricate a third rawnet
# parser that doesn't exist, this script covers parse_udp and parse_arp
# thoroughly (success + malformed-input cases each) and notes this
# discrepancy in the task-0.4 report.
# ═══════════════════════════════════════════════════════════════════════

_parsed_udp = rawnet.parse_udp(_udp_frame)
add(
    "parse_udp_round_trip",
    "parse_udp fed the exact output of build_udp_basic -- round-trip success case.",
    {"frame": h(_udp_frame)},
    {
        "srcIp": _parsed_udp[0], "dstIp": _parsed_udp[1],
        "srcPort": _parsed_udp[2], "dstPort": _parsed_udp[3],
        "payloadHex": h(_parsed_udp[4]),
    },
)

_short_frame = bytes.fromhex("00" * 10)
_parsed_udp_short = rawnet.parse_udp(_short_frame)
add(
    "parse_udp_too_short_returns_none",
    "parse_udp on a frame shorter than the minimum Ethernet+IPv4+UDP length -- must return None.",
    {"frame": h(_short_frame)},
    None if _parsed_udp_short is None else _parsed_udp_short,
)

_non_ipv4_frame = bytes.fromhex("00" * 12) + bytes.fromhex("0806") + bytes.fromhex("00" * 28)
_parsed_udp_wrong_ethertype = rawnet.parse_udp(_non_ipv4_frame)
add(
    "parse_udp_wrong_ethertype_returns_none",
    "parse_udp on a long-enough frame whose EtherType is ARP (0x0806), not IPv4 (0x0800) -- must return None.",
    {"frame": h(_non_ipv4_frame)},
    None if _parsed_udp_wrong_ethertype is None else _parsed_udp_wrong_ethertype,
)

_parsed_arp = rawnet.parse_arp(_arp_req)
add(
    "parse_arp_round_trip_request",
    "parse_arp fed the exact output of build_arp_request_basic -- round-trip success case (op=1, who-has).",
    {"frame": h(_arp_req)},
    {
        "op": _parsed_arp[0], "senderMac": h(_parsed_arp[1]),
        "senderIp": _parsed_arp[2], "targetMac": h(_parsed_arp[3]),
        "targetIp": _parsed_arp[4],
    },
)

_parsed_arp_reply = rawnet.parse_arp(_arp_reply)
add(
    "parse_arp_round_trip_reply",
    "parse_arp fed the exact output of build_arp_reply_basic -- round-trip success case (op=2, is-at).",
    {"frame": h(_arp_reply)},
    {
        "op": _parsed_arp_reply[0], "senderMac": h(_parsed_arp_reply[1]),
        "senderIp": _parsed_arp_reply[2], "targetMac": h(_parsed_arp_reply[3]),
        "targetIp": _parsed_arp_reply[4],
    },
)

_short_arp = bytes.fromhex("00" * 20)
_parsed_arp_short = rawnet.parse_arp(_short_arp)
add(
    "parse_arp_too_short_returns_none",
    "parse_arp on a frame shorter than the minimum ARP-over-Ethernet length -- must return None.",
    {"frame": h(_short_arp)},
    None if _parsed_arp_short is None else _parsed_arp_short,
)


# ═══════════════════════════════════════════════════════════════════════
# rndis.py — wrap_packet_msg / unwrap_packet_msg round trip
# ═══════════════════════════════════════════════════════════════════════

_eth_frame_1 = bytes.fromhex("de ad be ef ca fe 01 02 03 04 05 06 08 00".replace(" ", "")) + b"\x11" * 20
_wrapped_1 = rndis.wrap_packet_msg(_eth_frame_1)
add(
    "wrap_packet_msg_single",
    "wrap_packet_msg over one small Ethernet frame -- basic RNDIS_PACKET_MSG framing.",
    {"frame": h(_eth_frame_1)},
    h(_wrapped_1),
)

_unwrapped_1 = list(rndis.unwrap_packet_msg(_wrapped_1))
add(
    "unwrap_packet_msg_single",
    "unwrap_packet_msg fed the exact output of wrap_packet_msg_single -- single-message round trip.",
    {"buf": h(_wrapped_1)},
    [h(f) for f in _unwrapped_1],
)

_eth_frame_2 = bytes.fromhex("ff ff ff ff ff ff 02 00 00 00 00 01 08 06".replace(" ", "")) + b"\x22" * 28
_eth_frame_3 = bytes.fromhex("aa bb cc dd ee ff 11 22 33 44 55 66 08 00".replace(" ", "")) + b"\x33" * 6
_multi_buf = rndis.wrap_packet_msg(_eth_frame_1) + rndis.wrap_packet_msg(_eth_frame_2) + rndis.wrap_packet_msg(_eth_frame_3)
_unwrapped_multi = list(rndis.unwrap_packet_msg(_multi_buf))
add(
    "unwrap_packet_msg_multi_message_buffer",
    "unwrap_packet_msg over a buffer containing three back-to-back RNDIS_PACKET_MSG structures (as a single bulk-IN read can deliver) -- multi-message round trip required by design.md §9.1 item 2.",
    {"buf": h(_multi_buf)},
    [h(f) for f in _unwrapped_multi],
)


# ═══════════════════════════════════════════════════════════════════════
# stream.py — build_outer for each packet type
#
# Packet type constants, verified against stream.py's actual call sites:
#   0x00 handshake   (build_outer(0x00, seq, HANDSHAKE_BODY) in main())
#   0x01 telemetry   (build_telemetry_with_duml -> build_outer(0x01, ...))
#   0x02 video       (inbound-only in the prototype -- payload[6] == 0x02
#                     is read in main()'s RX loop, never built by
#                     stream.py itself; build_outer is still exercised
#                     directly here with pkt_type=0x02 since it is a
#                     generic function and design.md explicitly asks for
#                     "buildOuter for each packet type" including video)
#   0x04 ack         (build_ack -> build_outer(0x04, ...))
# ═══════════════════════════════════════════════════════════════════════

_outer_body_small = bytes.fromhex("00112233")

for _pkt_type, _pkt_name in ((0x00, "handshake"), (0x01, "telemetry"), (0x02, "video"), (0x04, "ack")):
    _seq = 0x0007
    _outer = stream.build_outer(_pkt_type, _seq, _outer_body_small)
    add(
        f"build_outer_pkt_type_{_pkt_name}",
        f"build_outer with pkt_type=0x{_pkt_type:02X} ({_pkt_name}), a fixed SESSION_ID (0x{FIXED_SESSION_ID:04X}), and a small body -- exercises the XOR checksum byte and the 0x8000 length-field bit for this packet type.",
        {"pktType": _pkt_type, "seq": _seq, "body": h(_outer_body_small), "sessionId": FIXED_SESSION_ID},
        h(_outer),
    )


# ═══════════════════════════════════════════════════════════════════════
# stream.py — the 48-byte handshake and the 22-byte-body ack
# ═══════════════════════════════════════════════════════════════════════

_handshake_seq = 0
_handshake_frame = stream.build_outer(0x00, _handshake_seq, stream.HANDSHAKE_BODY)
assert len(_handshake_frame) == 48, f"expected 48-byte handshake, got {len(_handshake_frame)}"
add(
    "handshake_48_bytes",
    "The full 48-byte handshake frame: build_outer(0x00, seq=0, HANDSHAKE_BODY) with the fixed SESSION_ID -- HANDSHAKE_BODY is the prototype's 40-byte empirically-derived constant.",
    {"seq": _handshake_seq, "handshakeBody": h(stream.HANDSHAKE_BODY), "sessionId": FIXED_SESSION_ID},
    h(_handshake_frame),
)

_ack_start_seq, _ack_end_seq, _ack_seq = 0x0010, 0x0015, 0x0020
_ack_frame = stream.build_ack(_ack_start_seq, _ack_end_seq, _ack_seq)
assert len(_ack_frame) == 30, f"expected 8-byte outer header + 22-byte body = 30 bytes, got {len(_ack_frame)}"
add(
    "ack_22_byte_body",
    "The full ack frame from build_ack: an 8-byte build_outer(0x04, ...) header wrapping the 22-byte ack body (4-byte start/end seq range + the 18-byte ACK_TEMPLATE_TAIL constant) -- 30 bytes total.",
    {"startSeq": _ack_start_seq, "endSeq": _ack_end_seq, "seq": _ack_seq, "sessionId": FIXED_SESSION_ID},
    h(_ack_frame),
)


# ═══════════════════════════════════════════════════════════════════════
# duml.py — crc8 / crc16
# ═══════════════════════════════════════════════════════════════════════

_crc8_input = bytes.fromhex("55 0d 04".replace(" ", ""))
add(
    "duml_crc8_header",
    "duml.crc8 over a 3-byte DUML header prefix (magic + length/version bytes), the standard header-CRC use, default seed 0x77.",
    {"data": h(_crc8_input)},
    duml.crc8(_crc8_input),
)

_crc16_input = bytes.fromhex("55 0d 04 00 2a bc 00 90 40 02 b3".replace(" ", ""))
add(
    "duml_crc16_whole_frame_prefix",
    "duml.crc16 over an 11-byte DUML header (everything but the trailing CRC-16 itself), default seed 0x3692.",
    {"data": h(_crc16_input)},
    duml.crc16(_crc16_input),
)


# ═══════════════════════════════════════════════════════════════════════
# duml.py — build for the 02:B3 frame (send_request_iframe's exact call)
# ═══════════════════════════════════════════════════════════════════════

_duml_02b3 = duml.build(sender=0x2A, receiver=0xBC, seq=0x9000,
                         cmd_type=0x40, cmd_set=0x02, cmd_id=0xB3, payload=b"")
add(
    "duml_build_02_b3_iframe_request",
    "duml.build reproducing send_request_iframe's exact call -- the I-frame-request DUML frame (cmd_set=0x02, cmd_id=0xB3), empty payload.",
    {"sender": 0x2A, "receiver": 0xBC, "seq": 0x9000, "cmdType": 0x40, "cmdSet": 0x02, "cmdId": 0xB3, "payload": ""},
    h(_duml_02b3),
)

_duml_payload_edge = bytes.fromhex("de ad be ef 00 ff".replace(" ", ""))
_duml_with_payload = duml.build(sender=0x01, receiver=0x02, seq=0x1234,
                                 cmd_type=0x40, cmd_set=0x02, cmd_id=0x80, payload=_duml_payload_edge)
add(
    "duml_build_with_nonempty_payload",
    "duml.build with a non-empty 6-byte payload -- edge case exercising the payload-length-dependent CRC-16 over the whole frame.",
    {"sender": 0x01, "receiver": 0x02, "seq": 0x1234, "cmdType": 0x40, "cmdSet": 0x02, "cmdId": 0x80, "payload": h(_duml_payload_edge)},
    h(_duml_with_payload),
)


# ═══════════════════════════════════════════════════════════════════════
# duml.py — parse_stream over a synthetic IF4-style byte stream
#
# There is no saved raw hardware IF4 (DUML vendor-interface) capture file
# in either repo. Per the task-0.4 brief, this script does NOT fabricate
# one and claim it's real hardware data. Instead this vector hand-
# constructs a synthetic multi-frame byte stream out of duml.build()'s own
# real output (concatenating two distinct valid frames, one corrupted
# frame with a deliberately flipped CRC-16 byte so it must be rejected and
# skipped, and a trailing partial third frame left as the unconsumed
# tail) -- this still meaningfully exercises parse_stream's real CRC-8 and
# CRC-16 checks, since duml.build() computes genuine CRCs, and
# parse_stream must independently recompute and verify them. Labeled
# "synthetic" throughout, not "captured".
# ═══════════════════════════════════════════════════════════════════════

_syn_frame_a = duml.build(sender=0x2A, receiver=0xBC, seq=0x0001,
                           cmd_type=0x40, cmd_set=0x02, cmd_id=0xB3, payload=b"")
_syn_frame_b = duml.build(sender=0x2A, receiver=0xBC, seq=0x0002,
                           cmd_type=0x00, cmd_set=0x08, cmd_id=0x01, payload=bytes.fromhex("0102030405"))

_syn_frame_corrupt = bytearray(duml.build(sender=0x2A, receiver=0xBC, seq=0x0003,
                                           cmd_type=0x00, cmd_set=0x08, cmd_id=0x02, payload=b"\x99"))
_syn_frame_corrupt[-1] ^= 0xFF  # flip the high byte of the trailing CRC-16 -> must fail crc16 check
_syn_frame_corrupt = bytes(_syn_frame_corrupt)

_syn_frame_c = duml.build(sender=0x2A, receiver=0xBC, seq=0x0004,
                           cmd_type=0x40, cmd_set=0x02, cmd_id=0xB3, payload=b"")
_syn_partial_tail = _syn_frame_c[:5]  # deliberately incomplete -- header present, frame not fully arrived yet

_syn_stream = _syn_frame_a + _syn_frame_b + _syn_frame_corrupt + _syn_partial_tail
_syn_packets, _syn_tail = duml.parse_stream(bytearray(_syn_stream))

add(
    "duml_parse_stream_synthetic_if4",
    "SYNTHETIC (not a hardware capture): duml.parse_stream over a hand-built buffer of two valid duml.build() frames, one frame with a corrupted CRC-16 (must be rejected/skipped), and a truncated trailing partial frame (must be left as the unconsumed tail) -- exercises CRC-8 and CRC-16 both.",
    {"buf": h(_syn_stream)},
    {
        "packets": [
            {
                "version": p.version, "sender": p.sender, "receiver": p.receiver,
                "seq": p.seq, "cmdType": p.cmd_type, "cmdSet": p.cmd_set, "cmdId": p.cmd_id,
                "payloadHex": h(p.payload), "rawHex": h(p.raw),
            }
            for p in _syn_packets
        ],
        "tailHex": h(_syn_tail),
    },
)

_syn_stream_clean = _syn_frame_a + _syn_frame_b
_syn_packets_clean, _syn_tail_clean = duml.parse_stream(bytearray(_syn_stream_clean))
add(
    "duml_parse_stream_synthetic_clean_two_frames",
    "SYNTHETIC (not a hardware capture): duml.parse_stream over exactly two valid, back-to-back duml.build() frames with no corruption and no trailing partial data -- baseline multi-frame case, empty tail expected.",
    {"buf": h(_syn_stream_clean)},
    {
        "packets": [
            {
                "version": p.version, "sender": p.sender, "receiver": p.receiver,
                "seq": p.seq, "cmdType": p.cmd_type, "cmdSet": p.cmd_set, "cmdId": p.cmd_id,
                "payloadHex": h(p.payload), "rawHex": h(p.raw),
            }
            for p in _syn_packets_clean
        ],
        "tailHex": h(_syn_tail_clean),
    },
)


# ═══════════════════════════════════════════════════════════════════════
# Write output
# ═══════════════════════════════════════════════════════════════════════

def main():
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(vectors, f, indent=2, sort_keys=False)
        f.write("\n")
    print(f"Wrote {len(vectors)} vectors to {OUT_PATH}")


if __name__ == "__main__":
    main()
