#!/usr/bin/env python3
"""BLE coexistence test: RaceChrono telemetry while the app API is busy.

Acts as RaceChrono (service 0x1FF8: filter write + CAN-data notify) asking for
the decoded PIDs 0xFFFF0001/2/3 at 50 ms each, measures their rate for a quiet
baseline, then again while hammering the API with large responses (CAN View,
status, logs). Prints per-PID rates and API latency.

Needs the API without encryption for an unattended run:
    PLATFORMIO_BUILD_FLAGS="-D OH_BLE_API_ENCRYPT=0" python3 scripts/flash.py
"""

import asyncio
import struct
import time
from collections import Counter

from bleak import BleakClient, BleakScanner

RC_DATA = "00000001-0000-1000-8000-00805f9b34fb"
RC_FILTER = "00000002-0000-1000-8000-00805f9b34fb"
API_RX = "4f480002-0000-4c44-8000-4f70656e4844"
API_TX = "4f480003-0000-4c44-8000-4f70656e4844"
PIDS = [0xFFFF0001, 0xFFFF0002, 0xFFFF0003]
PHASE_S = 10.0


class Rig:
    def __init__(self, c):
        self.c = c
        self.counts = Counter()
        self.buf = bytearray()
        self.done = asyncio.Queue()
        self.rid = 1

    def on_rc(self, _h, data):
        if len(data) >= 4:
            self.counts[struct.unpack("<I", bytes(data[:4]))[0]] += 1

    def on_api(self, _h, data):
        if data[0] & 1:
            self.buf = bytearray()
        self.buf += data[1:]
        if data[0] & 2:
            self.done.put_nowait(bytes(self.buf))

    async def call(self, target):
        msg = f"{self.rid} GET {target}\n".encode()
        self.rid += 1
        chunk = min(self.c.mtu_size - 3, 512) - 1
        parts = [msg[i:i + chunk] for i in range(0, len(msg), chunk)]
        for i, p in enumerate(parts):
            flags = (1 if i == 0 else 0) | (2 if i == len(parts) - 1 else 0)
            await self.c.write_gatt_char(API_RX, bytes([flags]) + p, response=True)
        return await asyncio.wait_for(self.done.get(), 20)


async def phase(rig, name, load):
    rig.counts.clear()
    stop = time.time() + PHASE_S
    api_n, api_bytes, lat = 0, 0, []
    while time.time() < stop:
        if load:
            for t in ("/api/canview?decoded=200&raw=40&bus=all", "/api/status", "/api/logs/read?path=/logs/all.txt"):
                t0 = time.time()
                body = await rig.call(t)
                lat.append(time.time() - t0)
                api_n += 1
                api_bytes += len(body)
        else:
            await asyncio.sleep(0.5)
    rates = {f"0x{p:08X}": rig.counts[p] / PHASE_S for p in PIDS}
    print(f"{name:9s} RaceChrono Hz: " + "  ".join(f"{k}={v:5.1f}" for k, v in rates.items()))
    if load:
        print(f"{'':9s} API: {api_n} calls, {api_bytes / 1024:.1f} KB in {PHASE_S:.0f}s "
              f"({api_bytes / 1024 / PHASE_S:.1f} KB/s), latency avg {sum(lat) / len(lat) * 1000:.0f} ms "
              f"max {max(lat) * 1000:.0f} ms")
    return rates


async def main():
    dev = await BleakScanner.find_device_by_name("OpenHaldex-RC", timeout=15)
    if not dev:
        print("not found")
        return
    async with BleakClient(dev) as c:
        print("connected, mtu", c.mtu_size)
        rig = Rig(c)
        await c.start_notify(RC_DATA, rig.on_rc)
        await c.start_notify(API_TX, rig.on_api)
        await c.write_gatt_char(RC_FILTER, bytes([0]), response=True)  # deny all
        for p in PIDS:  # allow PID at 50 ms
            await c.write_gatt_char(RC_FILTER, bytes([2, 0, 50]) + struct.pack(">I", p), response=True)
        await asyncio.sleep(1.0)
        base = await phase(rig, "quiet", False)
        busy = await phase(rig, "API busy", True)
        worst = min(busy[k] / base[k] for k in base if base[k] > 0) if any(base.values()) else 0
        print(f"RaceChrono rate under API load: {worst * 100:.0f}% of quiet (worst PID)")


asyncio.run(asyncio.wait_for(main(), 120))
