#!/usr/bin/env python3
"""End-to-end test of the OpenHaldex BLE JSON API from a computer (bleak).

    python3 -m pip install bleak
    python3 scripts/ble_api_test.py                      # default endpoint sweep
    LIMIT=2000 python3 scripts/ble_api_test.py 'GET|/api/presets|' 'POST|/api/presets/apply|{"id":2}'

The API service requires an encrypted (bonded) link. macOS shows a pairing
popup that needs a click; for unattended bench runs, flash a test build with
    PLATFORMIO_BUILD_FLAGS="-D OH_BLE_API_ENCRYPT=0" python3 scripts/flash.py
and flash the normal build again afterwards.
"""
import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner

RX = "4f480002-0000-4c44-8000-4f70656e4844"
TX = "4f480003-0000-4c44-8000-4f70656e4844"


class Api:
    def __init__(self, client):
        self.c = client
        self.buf = bytearray()
        self.done = asyncio.Queue()
        self.next_id = 1

    def on_notify(self, _h, data: bytearray):
        flags = data[0]
        if flags & 1:
            self.buf = bytearray()
        self.buf += data[1:]
        if flags & 2:
            self.done.put_nowait(bytes(self.buf))

    async def call(self, method, target, body=""):
        rid = self.next_id
        self.next_id += 1
        msg = f"{rid} {method} {target}\n{body}".encode()
        mtu = max(23, self.c.mtu_size)
        chunk = min(mtu - 3, 512) - 1
        parts = [msg[i:i + chunk] for i in range(0, len(msg), chunk)] or [b""]
        for i, p in enumerate(parts):
            flags = (1 if i == 0 else 0) | (2 if i == len(parts) - 1 else 0)
            await self.c.write_gatt_char(RX, bytes([flags]) + p, response=True)
        t0 = time.time()
        raw = await asyncio.wait_for(self.done.get(), 15)
        header, _, body = raw.partition(b"\n")
        return header.decode(), body.decode(errors="replace"), time.time() - t0


DEFAULT = [("GET", "/api/presets", ""), ("POST", "/api/presets/apply", '{"id":5}'), ("GET", "/api/presets", ""),
           ("POST", "/api/presets/apply", '{"id":1}'), ("POST", "/api/presets/apply", '{"id":9}'), ("GET", "/api/status", ""),
           ("GET", "/api/maps", ""), ("GET", "/api/curve/speed", ""), ("GET", "/api/logs", ""),
           ("GET", "/api/canview?decoded=20&raw=10&bus=all", ""), ("GET", "/api/nope", "")]
LIMIT = int(__import__("os").environ.get("LIMIT", "160"))


async def main():
    dev = await BleakScanner.find_device_by_name("OpenHaldex-RC", timeout=15)
    if not dev:
        print("not found")
        return
    async with BleakClient(dev) as c:
        print("connected mtu", c.mtu_size)
        api = Api(c)
        await c.start_notify(TX, api.on_notify)
        for method, target, body in (DEFAULT if len(sys.argv) < 2 else []) + [tuple(a.split("|", 2)) for a in sys.argv[1:]]:
            h, b, dt = await api.call(method, target, body)
            print(f"{method} {target} -> [{h}] {len(b)} bytes in {dt*1000:.0f} ms :: {b[:LIMIT]}")


asyncio.run(asyncio.wait_for(main(), 90))
