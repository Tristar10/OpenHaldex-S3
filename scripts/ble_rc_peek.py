#!/usr/bin/env python3
"""Act as RaceChrono for a few seconds and print the decoded OpenHaldex PIDs.

Usage: python3 -u scripts/ble_rc_peek.py [seconds]   (run from Terminal, not the Bash tool)
"""

import asyncio
import struct
import sys
import time

from bleak import BleakClient, BleakScanner

RC_DATA = "00000001-0000-1000-8000-00805f9b34fb"
RC_FILTER = "00000002-0000-1000-8000-00805f9b34fb"
PIDS = [0xFFFF0001, 0xFFFF0002, 0xFFFF0003, 0xFFFF0004]


def decode(pid, b):
    if pid == 0xFFFF0001:
        return (f"speed {struct.unpack('>H', b[0:2])[0] / 100:.1f} rpm {struct.unpack('>H', b[2:4])[0]} "
                f"pedal {b[4] * 100 / 255:.0f}% lock tgt {b[5]} act {b[6]} mode {b[7]}")
    if pid == 0xFFFF0002:
        s, br, ct = struct.unpack(">hhh", b[0:6])
        return f"steer {s / 10:.1f} brake {br / 10:.1f} clutch {ct} gear {b[6]} flags 0x{b[7]:02X}"
    if pid == 0xFFFF0003:
        return "wheels " + " ".join(f"{v / 100:.2f}" for v in struct.unpack(">4H", b[0:8]))
    if pid == 0xFFFF0004:
        return (f"coolant {b[0] - 40} oil {b[1] - 40} iat {b[2] - 40} gearbox {b[3] - 40} "
                f"boost {b[4] * 0.02:.2f} bar oilP {b[5] / 10:.1f} bar torque {struct.unpack('>h', b[6:8])[0]} Nm")
    return b.hex()


async def main(secs):
    dev = await BleakScanner.find_device_by_name("OpenHaldex-RC", timeout=15)
    if not dev:
        print("not found")
        return
    last, counts = {}, {p: 0 for p in PIDS}

    def on_rc(_h, data):
        pid = struct.unpack("<I", bytes(data[:4]))[0]
        if pid in counts:
            counts[pid] += 1
            last[pid] = bytes(data[4:12])

    async with BleakClient(dev) as c:
        await c.start_notify(RC_DATA, on_rc)
        await c.write_gatt_char(RC_FILTER, bytes([0]), response=True)
        for p in PIDS:
            await c.write_gatt_char(RC_FILTER, bytes([2, 0, 50]) + struct.pack(">I", p), response=True)
        t0 = time.time()
        await asyncio.sleep(secs)
        dt = time.time() - t0
    for p in PIDS:
        line = decode(p, last[p]) if p in last else "(nothing)"
        print(f"0x{p:08X} {counts[p] / dt:5.1f} Hz  {line}")


asyncio.run(main(float(sys.argv[1]) if len(sys.argv) > 1 else 5))
