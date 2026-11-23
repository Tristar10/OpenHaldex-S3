#!/usr/bin/env python3
"""Fake MMI head unit for bench-testing OpenHaldex's MMI link.

Speaks the same UDP protocol as ttlink (audi-tt-8s-altscreen) plus the preset
messages from docs/PRESETS.md:

  OpenHaldex -> MMI   TTG1 data (20 Hz once acked), TTP1 preset catalog,
                      TTR1 command replies
  MMI -> OpenHaldex   TTA1 acks, TTC1 commands (APPLY_PRESET)

Run it on the machine that IS the Wi-Fi hotspot OpenHaldex joins (the board
sends to its STA gateway), e.g. a Mac with Internet Sharing on:

    python3 scripts/mmi_sim.py              # listen, ack, print once a second
    python3 scripts/mmi_sim.py --no-ack     # check the board falls back to 1 Hz
    python3 scripts/mmi_sim.py --apply 2    # apply preset id 2 once linked

While running, type a preset id + Enter to apply it, or "l" to list presets.
"""

from __future__ import annotations

import argparse
import select
import socket
import struct
import sys
import time

CHANNELS = {
    1: "rpm", 2: "speed", 3: "pedal", 4: "torque", 5: "coolant", 6: "oil", 7: "iat",
    8: "boost", 10: "hx_req", 11: "hx_act", 12: "mode", 13: "gear", 16: "trans",
    18: "oil_bar", 19: "clutch_c", 20: "steer", 21: "brake", 22: "preset",
    60: "uptime", 61: "rssi", 62: "sent",
}
MODES = ["STOCK", "FWD", "5050", "6040", "7030", "8020", "9010", "SPEED", "THROTTLE", "MAP", "RPM"]
RESULTS = {0: "ok", 1: "catalog version mismatch", 2: "unknown preset", 3: "calibration running",
           4: "CAN View capture active", 5: "preset map missing", 255: "unknown command"}


class Sim:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("0.0.0.0", args.port))
        self.peer: tuple[str, int] | None = None
        self.rx = 0
        self.lost = 0
        self.last_seq: int | None = None
        self.start = time.monotonic()
        self.values: dict[int, float] = {}
        self.catalog_version: int | None = None
        self.presets: list[tuple[int, int, str]] = []
        self.cmd_seq = 1
        self.pending_apply = args.apply
        self.window_rx = 0

    # --- incoming ---------------------------------------------------------
    def handle(self, data: bytes, addr: tuple[str, int]) -> None:
        magic = data[:4]
        if len(data) >= 8 and struct.unpack(">I", data[4:8])[0] != self.args.key:
            return
        self.peer = addr
        if magic == b"TTG1":
            self.on_data(data, addr)
        elif magic == b"TTP1":
            self.on_catalog(data)
        elif magic == b"TTR1":
            self.on_reply(data)

    def on_data(self, data: bytes, addr: tuple[str, int]) -> None:
        if len(data) < 12:
            return
        seq, _flags, count = struct.unpack(">HBB", data[8:12])
        if self.last_seq is not None:
            gap = (seq - self.last_seq - 1) & 0xFFFF
            if gap < 1000:
                self.lost += gap
        self.last_seq = seq
        self.rx += 1
        self.window_rx += 1
        for i in range(count):
            off = 12 + 6 * i
            if off + 6 > len(data):
                break
            cid, raw = struct.unpack(">Hi", data[off:off + 6])
            self.values[cid] = raw / 1000.0
        if not self.args.no_ack:
            uptime = int((time.monotonic() - self.start) * 1000) & 0xFFFFFFFF
            ack = b"TTA1" + struct.pack(">HHIII", seq, 0, self.rx, self.lost, uptime)
            self.sock.sendto(ack, addr)
        if self.args.verbose:
            print(f"rx seq={seq} " + " ".join(f"{CHANNELS.get(k, k)}={v:g}" for k, v in sorted(self.values.items())))

    def on_catalog(self, data: bytes) -> None:
        if len(data) < 11:
            return
        version, count = struct.unpack(">HB", data[8:11])
        presets = []
        off = 11
        for _ in range(count):
            if off + 3 > len(data):
                break
            pid, mode, n = data[off], data[off + 1], data[off + 2]
            name = data[off + 3:off + 3 + n].decode(errors="replace")
            presets.append((pid, mode, name))
            off += 3 + n
        if version != self.catalog_version or presets != self.presets:
            self.catalog_version, self.presets = version, presets
            print(f"catalog v0x{version:04X}: " + ", ".join(f"{p}={n}({MODES[m] if m < len(MODES) else m})"
                                                       for p, m, n in presets))

    def on_reply(self, data: bytes) -> None:
        if len(data) < 14:
            return
        seq, result, active, version = struct.unpack(">HBBH", data[8:14])
        print(f"reply cmd={seq} result={result} ({RESULTS.get(result, '?')}) active={active} catalog=0x{version:04X}")

    # --- outgoing ---------------------------------------------------------
    def apply(self, preset_id: int) -> None:
        if not self.peer or self.catalog_version is None:
            print("no catalog yet; waiting for the board")
            self.pending_apply = preset_id
            return
        cmd = b"TTC1" + struct.pack(">IHBBH", self.args.key, self.cmd_seq, 1, preset_id, self.catalog_version)
        print(f"-> APPLY_PRESET id={preset_id} (cmd {self.cmd_seq})")
        self.sock.sendto(cmd, self.peer)
        self.cmd_seq = (self.cmd_seq + 1) & 0xFFFF

    # --- loop -------------------------------------------------------------
    def run(self) -> None:
        print(f"mmi_sim listening on udp {self.args.port}, key {self.args.key}, acks {'off' if self.args.no_ack else 'on'}")
        last_print = time.monotonic()
        inputs = [self.sock] + ([sys.stdin] if sys.stdin.isatty() else [])
        while True:
            ready, _, _ = select.select(inputs, [], [], 0.2)
            for r in ready:
                if r is self.sock:
                    data, addr = self.sock.recvfrom(512)
                    self.handle(data, addr)
                else:
                    line = sys.stdin.readline().strip()
                    if line == "l":
                        print(self.presets)
                    elif line.isdigit():
                        self.apply(int(line))
            if self.pending_apply is not None and self.catalog_version is not None:
                pid, self.pending_apply = self.pending_apply, None
                self.apply(pid)
            now = time.monotonic()
            if now - last_print >= 1.0:
                rate = self.window_rx / (now - last_print)
                self.window_rx = 0
                last_print = now
                peer = f"{self.peer[0]}:{self.peer[1]}" if self.peer else "-"
                v = self.values
                print(f"{peer} rate={rate:4.1f}/s rx={self.rx} lost={self.lost} | "
                      f"mode={MODES[int(v[12])] if 12 in v and int(v[12]) < len(MODES) else '-'} "
                      f"preset={int(v.get(22, -1))} hx={v.get(11, 0):g}/{v.get(10, 0):g}% "
                      f"steer={v.get(20, 0):g} rssi={v.get(61, 0):g}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--port", type=int, default=49160)
    ap.add_argument("-k", "--key", type=int, default=0)
    ap.add_argument("-n", "--no-ack", action="store_true", help="never ack (board should fall back to 1 Hz)")
    ap.add_argument("-v", "--verbose", action="store_true", help="print every datagram")
    ap.add_argument("--apply", type=int, help="apply this preset id once the catalog arrives")
    try:
        Sim(ap.parse_args()).run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
