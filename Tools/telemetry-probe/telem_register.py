#!/usr/bin/env python3
"""Read-only DUML registration/subscription experiment on goggles IF4.

Replays the app-side registration DJI Fly 1.21.12 performs (see
docs/telemetry-registration-sequence.md) and logs every inbound frame, so
pushes that start after registration stand out.

Only sends announcements (00:88 APP info, heartbeat candidates), a camera
DDS subscribe replayed from a real N3 capture, and read-only gets. Nothing
that writes settings, changes modes/links, records, calibrates, reboots,
upgrades, formats or touches the flight controller / gimbal.

Run (helper stopped so IF4 is free):
  sudo pkill -9 -f "GogglesHelper --xpc"
  sudo DYLD_LIBRARY_PATH=/opt/homebrew/lib <venv>/bin/python3 telem_register.py
Options: --no-0x2a  skip the 0x2A comparison step
         --final N  final listen seconds (default 30)
"""
import sys, os, time, json, argparse, collections
sys.path.insert(0, os.path.expanduser('~/PycharmProjects/dji-goggles3-videoout'))
import usb.core, usb.util, duml

DJI_VID, DJI_PID = 0x2CA3, 0x0020
IFACE, EP_OUT, EP_IN = 4, 0x04, 0x85
APP, PC = 0x02, 0x2A          # DJI Fly speaks as 0x02 (app#0); our old probes used 0x2A (pc#1)
GLASS = 0x3C                   # glass type 0x1C index 1 (N3 capture used 0x3C)

ap = argparse.ArgumentParser()
ap.add_argument('--no-0x2a', action='store_true')
ap.add_argument('--final', type=float, default=30.0)
ap.add_argument('--baseline', type=float, default=5.0)
args = ap.parse_args()

# ---- payloads recovered from libsdk_jni.so (see doc) ----------------------
APP_INFO = bytes.fromhex('1700' '0023' '00' '415050' '0000000000' '02')   # 00:88 sub 0x17, online
assert len(APP_INFO) == 14
QUERY_REPLY = bytes.fromhex('1a00000000')                               # answer to 00:88 sub 0x19
HB_V1 = bytes([0x00, 0x00])                                              # [datalink_type, bg flag]
HB_V2 = bytes([0x00, 0x02, 0x01, 0x00])                                  # [dl, state|2, 1, keep_active]
# N3 capture 02>28 00:99 "camcap_common" subscribe (camera DDS topic), payload verbatim
DDS_CAMCAP = bytes.fromhex('020200 00d507 0000000000 1300 0d00'.replace(' ', '')) + b'camcap_common' + b'\0' * 4

dev = usb.core.find(idVendor=DJI_VID, idProduct=DJI_PID)
if dev is None:
    sys.exit('goggles not found')
try:
    if dev.is_kernel_driver_active(IFACE):
        dev.detach_kernel_driver(IFACE)
except (usb.core.USBError, NotImplementedError):
    pass
usb.util.claim_interface(dev, IFACE)

os.makedirs(os.path.expanduser('~/telem'), exist_ok=True)
logpath = os.path.expanduser(time.strftime('~/telem/register-%Y%m%d-%H%M%S.jsonl'))
log = open(logpath, 'a')
T0 = time.time()
seq = 0x3000
step = 'baseline'
seen = {}            # key -> dict(first, count, step)
baseline = set()
buf = bytearray()


def key(p):
    return f'{p.sender:02X}>{p.receiver:02X} {p.cmd_set:02X}:{p.cmd_id:02X}'


def rec(kind, **kw):
    kw.update(t=round(time.time(), 4), dt=round(time.time() - T0, 3), kind=kind, step=step)
    log.write(json.dumps(kw) + '\n'); log.flush()


def send(src, dst, cmd_type, cs, ci, payload=b'', note=''):
    global seq
    seq = (seq + 1) & 0xFFFF
    fr = duml.build(src, dst, seq=seq, cmd_type=cmd_type, cmd_set=cs, cmd_id=ci, payload=payload)
    try:
        dev.write(EP_OUT, fr, timeout=500)
        ok = True
    except usb.core.USBError as e:
        ok = False
        try: dev.clear_halt(EP_OUT)
        except usb.core.USBError: pass
        print(f'  ! write failed: {e}')
    rec('tx', src=f'{src:02X}', dst=f'{dst:02X}', cmd=f'{cs:02X}:{ci:02X}', cmd_type=f'{cmd_type:02X}',
        seq=seq, payload=payload.hex(), ok=ok, note=note)
    print(f'[{time.time()-T0:6.1f}] TX {src:02X}>{dst:02X} {cs:02X}:{ci:02X} t={cmd_type:02X} '
          f'{payload.hex(" ")[:60]}  {note}', flush=True)
    return seq


def handle(p):
    k = key(p)
    pl = bytes(p.payload)
    rec('rx', src=f'{p.sender:02X}', dst=f'{p.receiver:02X}', cmd=f'{p.cmd_set:02X}:{p.cmd_id:02X}',
        cmd_type=f'{p.cmd_type:02X}', seq=p.seq, len=len(pl), payload=pl.hex(), key=k)
    s = seen.get(k)
    if s is None:
        seen[k] = s = {'first': time.time(), 'count': 0, 'step': step}
        tag = 'BASE' if step == 'baseline' else 'NEW '
        if step == 'baseline':
            baseline.add(k)
        status = f' status={pl[0]:02X}' if (p.cmd_type & 0x80) and pl else ''
        print(f'[{time.time()-T0:6.1f}] {tag} {k} t={p.cmd_type:02X}{status} len={len(pl)} '
              f'{pl[:32].hex(" ")}  (during: {step})', flush=True)
    s['count'] += 1
    # Answer device "who is the app" queries exactly like DeviceRegisterLogic does.
    if p.cmd_set == 0 and p.cmd_id == 0x88 and not (p.cmd_type & 0x80) and pl[:2] == b'\x19\x00':
        fr = duml.build(p.receiver if p.receiver in (APP, PC) else APP, p.sender, seq=p.seq,
                        cmd_type=0x80, cmd_set=0, cmd_id=0x88, payload=QUERY_REPLY)
        try: dev.write(EP_OUT, fr, timeout=500)
        except usb.core.USBError: pass
        rec('tx', note='auto-reply to 00:88/0x19 query', frame=fr.hex())
        print(f'  -> replied to {p.sender:02X} 00:88/0x19 query')


def pump(seconds, hb=False):
    """Read for `seconds`; if hb, send heartbeat candidates once per second."""
    global buf
    end = time.time() + seconds
    next_hb = time.time()
    while time.time() < end:
        if hb and time.time() >= next_hb:
            next_hb += 1.0
            for ci in (0x0E, 0xFE):
                fr_payload = HB_V2 if ci == 0xFE else HB_V1
                s = duml.build(APP, GLASS, seq=(seq + ci) & 0xFFFF, cmd_type=0x00, cmd_set=0, cmd_id=ci,
                               payload=fr_payload)
                try: dev.write(EP_OUT, s, timeout=200)
                except usb.core.USBError: pass
        try:
            buf += bytes(dev.read(EP_IN, 16384, timeout=50))
        except usb.core.USBError:
            pass
        pk, buf = duml.parse_stream(buf)
        for p in pk:
            handle(p)


def phase(name):
    global step
    step = name
    rec('phase', name=name)
    print(f'\n=== {name} ===', flush=True)


print('log ->', logpath)
phase('baseline')
pump(args.baseline)
print(f'baseline keys: {sorted(baseline)}')

HB = False   # heartbeats start after registration

phase('register 00:88 APP from 0x02')
send(APP, GLASS, 0x40, 0x00, 0x88, APP_INFO, 'AppInfoSync RequestAppInfoRegister (N3-identical)')
pump(1.0)
send(APP, 0xBC, 0x40, 0x00, 0x88, APP_INFO, 'same, glass index 5')
pump(1.0)
send(APP, 0x00, 0x40, 0x00, 0x88, APP_INFO, 'DeviceRegisterLogic: receiver type 0 (router default)')
pump(2.0)

if not args.no_0x2a:
    phase('register 00:88 APP from 0x2A (comparison)')
    send(PC, GLASS, 0x40, 0x00, 0x88, APP_INFO, 'old sender')
    pump(1.5)

phase('heartbeat candidates 00:0E(v1) + 00:FE(v2) @1Hz from 0x02')
pump(4.0, hb=True)

phase('gets from 0x02 (were 0xE0 from 0x2A)')
for dst, cs, ci, note in [(GLASS, 0x00, 0x01, 'get_version'), (GLASS, 0x00, 0xB7, 'get_static_cap'),
                          (GLASS, 0x00, 0xB8, 'get_function_discover'), (0x1B, 0x07, 0x29, 'request_snr'),
                          (0x59, 0x0D, 0x02, 'battery dynamic'), (0x09, 0x00, 0x01, 'air unit get_version'),
                          (0x29, 0x00, 0xFF, 'air unit get_device_info'), (0x6E, 0x00, 0x97, 'link_monitor_request')]:
    send(APP, dst, 0x40, cs, ci, b'', note)
    pump(1.0, hb=True)

phase('DDS 00:99 camcap_common subscribe (camera topic, N3 replay)')
for dst in (0x28, 0x29, 0x01):
    send(APP, dst, 0x40, 0x00, 0x99, DDS_CAMCAP, 'united_pub_sub_agent subscribe camcap_common')
    pump(1.0, hb=True)

phase('re-register + final listen')
send(APP, GLASS, 0x40, 0x00, 0x88, APP_INFO, 're-announce')
pump(args.final, hb=True)

usb.util.release_interface(dev, IFACE)
now = time.time()
print('\n=== summary (NEW = not seen in baseline) ===')
for k, s in sorted(seen.items(), key=lambda kv: (kv[0] in baseline, kv[0])):
    span = max(now - s['first'], 1e-3)
    tag = 'base' if k in baseline else 'NEW '
    print(f'{tag} {k:22s} n={s["count"]:5d} {s["count"]/span:6.2f} Hz  first during: {s["step"]}')
rec('summary', seen={k: {'count': v['count'], 'step': v['step']} for k, v in seen.items()})
print('log ->', logpath)
