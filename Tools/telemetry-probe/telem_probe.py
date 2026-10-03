import sys, time, json, re, os
sys.path.insert(0, os.path.expanduser('~/PycharmProjects/dji-goggles3-videoout'))
import usb.core, usb.util, duml

DJI_VID, DJI_PID = 0x2CA3, 0x0020
IFACE, EP_OUT, EP_IN = 4, 0x04, 0x85
SENDER = 0x2A
EXCLUDE = re.compile(r'set_|reset|restart|format|erase|upgrade|calib|ctrl|start|stop|record|enable|clear|delete|ota|reboot|switch|take|shutdown|_rsp|power|discharge|write|file|download|upload|sync|bind|link_mode|mode_switch|self|password|blackbox|lock_uav|auth|simulator|cellular|fc2|perception|sdk|waypoint|esc|cloud|vision|diag|adsb|bt_', re.I)
rows = []
for l in open(os.path.expanduser('~/PycharmProjects/dji-goggles3-videoout/duml-commands.md')):
    m = re.match(r'\|\s*0x([0-9A-Fa-f]{2})\s*\|\s*0x([0-9A-Fa-f]{2})\s*\|\s*\d+\s*\|\s*`([^`]+)`', l)
    if m: rows.append((int(m.group(1),16), int(m.group(2),16), m.group(3)))
cmds = [r for r in rows if re.search(r'get|request|query|info|status|state|monitor|version|snr|frequency', r[2], re.I) and not EXCLUDE.search(r[2])]
targets = [0xBC, 0x3C, 0x1C, 0x1F, 0x09, 0x29, 0x0E, 0x2E, 0x6E, 0x8E]

dev = usb.core.find(idVendor=DJI_VID, idProduct=DJI_PID)
if dev is None: sys.exit("goggles not found")
usb.util.claim_interface(dev, IFACE)
out = open(os.path.expanduser('~/telem/probe.jsonl'), 'w')
print(len(cmds), "commands x", len(targets), "targets")

def drain(seconds):
    buf = bytearray(); end = time.time() + seconds
    while time.time() < end:
        try: buf += bytes(dev.read(EP_IN, 16384, timeout=60))
        except usb.core.USBError: pass
    return duml.parse_stream(buf)[0]

# passive listen
passive = drain(4)
print("passive frames:", [(f"{p.cmd_set:02X}:{p.cmd_id:02X}", p.sender, p.receiver) for p in passive][:6])
seq = 0x2000
answered = 0
for tgt in targets:
    for (cs, ci, name) in cmds:
        seq += 1
        frame = duml.build(SENDER, tgt, seq=seq, cmd_type=0x40, cmd_set=cs, cmd_id=ci, payload=b"")
        try: dev.write(EP_OUT, frame, timeout=500)
        except usb.core.USBError as e:
            continue
        pk = drain(0.12)
        for p in pk:
            if p.cmd_set == cs and p.cmd_id == ci and p.sender != SENDER:
                answered += 1
                rec = {"to": f"{tgt:02X}", "cmd": f"{cs:02X}:{ci:02X}", "name": name, "from": f"{p.sender:02X}",
                       "payload": bytes(p.payload).hex(), "type": f"{p.cmd_type:02X}"}
                out.write(json.dumps(rec) + "\n"); out.flush()
                print(rec["to"], rec["cmd"], name, "->", rec["from"], rec["payload"][:60])
print("done; replies:", answered)
usb.util.release_interface(dev, IFACE)
