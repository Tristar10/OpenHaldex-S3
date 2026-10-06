#!/usr/bin/env python3
"""Correct OpenHaldex-S3 WiFi telemetry drift in a RaceChrono .vbo export
recorded before the racechrono_wifi.cpp vTaskDelayUntil() fix.

Background: the old firmware paced its 20Hz telemetry loop with vTaskDelay(),
which delays a fixed amount from *when it's called* rather than from a fixed
reference tick, so time spent building/sending each sentence pushed the true
average rate slightly below 20.000Hz. RaceChrono has no GPS timestamp to
anchor to for a non-GPS DIY device (that's correct - see docs/RACECHRONO_WIFI.md)
and instead infers each sample's real time from the packet counter assuming a
dead-steady rate, so that small per-loop error compounded into the OpenHaldex
channels drifting increasingly ahead of real (GPS) time over a session - a
few percent by the end of a ~2 minute run.

This script measures that drift from the file itself - by cross-correlating
RaceChrono's own GPS speed (trustworthy, real-time) against the OpenHaldex
speed channel (analog1-data) in sliding windows - fits a linear drift-rate
model, and resamples every OpenHaldex-sourced column back onto the correct
real-time grid. It only touches data recorded with the old firmware; once a
controller is reflashed with the fix, new recordings shouldn't need this.

Usage: python3 scripts/fix_vbo_drift.py --vbo session.vbo --out session_fixed.vbo
"""
from __future__ import annotations

import argparse
from pathlib import Path

# Every [column names] entry sourced from our WiFi telemetry stream (i.e.
# everything the old firmware's mistimed loop wrote) - all share one packet
# counter/timestamp, so one drift curve (measured from speed) corrects all of
# them together. GPS-native columns (time, lat, long, velocity, heading, ...)
# are left untouched - they're the trustworthy reference, not the problem.
OH_COLUMNS = [
    "x_acc-data", "y_acc-data", "z_acc-data",
    "x_rate_of_rotation-data", "y_rate_of_rotation-data", "z_rate_of_rotation-data",
    "device_update_rate-data",
    "digital1-data", "digital2-data",
    "analog1-data", "analog2-data", "analog3-data", "analog4-data", "analog5-data",
    "analog6-data", "analog7-data", "analog8-data", "analog9-data", "analog10-data",
    "analog11-data", "analog12-data", "analog13-data", "analog14-data", "analog15-data",
]


class FixError(RuntimeError):
    pass


def load_vbo_raw(path: Path):
    with path.open("r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    idx = {}
    for i, l in enumerate(lines):
        s = l.strip()
        if s.startswith("[") and s.endswith("]"):
            idx[s[1:-1]] = i
    for required in ("column names", "data"):
        if required not in idx:
            raise FixError(f"'{path}' doesn't look like a RaceChrono .vbo export (no [{required}] section).")

    cn_i = idx["column names"] + 1
    while lines[cn_i].strip() == "":
        cn_i += 1
    cols = lines[cn_i].split()

    data_start = idx["data"] + 1
    rows = [l.split() for l in lines[data_start:] if l.strip()]
    if not rows:
        raise FixError(f"'{path}' has no data rows.")
    return lines, data_start, cols, rows


def connected_bounds(rows: list[list[str]], rate_i: int) -> tuple[int, int]:
    connected = [i for i, r in enumerate(rows) if r[rate_i] != "+000.000"]
    if not connected:
        raise FixError("No connected OpenHaldex telemetry found in this .vbo (device_update_rate stayed 0).")
    return connected[0], connected[-1]


def estimate_drift(seg: list[list[str]], gps_i: int, oh_i: int,
                    win: int = 1000, step: int = 200, search: int = 700):
    gps = [float(r[gps_i]) for r in seg]
    oh = [float(r[oh_i]) for r in seg]
    n = len(seg)

    points: list[tuple[int, int]] = [(0, 0)]
    for start in range(step, n - win - search, step):
        g = gps[start:start + win]
        best_lag, best_err = 0, float("inf")
        for lag in range(-search, search):
            s2 = start + lag
            if s2 < 0 or s2 + win > len(oh):
                continue
            o = oh[s2:s2 + win]
            err = sum((a - b) * (a - b) for a, b in zip(g, o))
            if err < best_err:
                best_err, best_lag = err, lag
        points.append((start, best_lag))

    # Overall average rate, just for the summary print - the actual
    # correction follows the measured curve directly (see build_lag_curve),
    # not this single slope, since the real drift isn't perfectly linear
    # (e.g. a slower start in the first ~20s before settling into a steady
    # rate - a single straight-line fit averages over that shape and leaves
    # a small residual).
    num = sum(r * l for r, l in points)
    den = sum(r * r for r, l in points)
    slope = (num / den) if den else 0.0
    return slope, points


def _isotonic_nonincreasing(values: list[float]) -> list[float]:
    """Pool-adjacent-violators: the least-squares best fit that never
    increases. Clock drift only accumulates in one direction over a
    session, so any upward blip between adjacent measured points is noise
    in that window's cross-correlation (common at low/near-zero speed,
    where GPS speed itself is less precise), not real signal - this removes
    exactly that kind of blip without smoothing away genuine curve shape.
    """
    stack: list[list[float]] = []  # [value, weight] pairs, strictly decreasing
    for v in values:
        stack.append([v, 1.0])
        while len(stack) > 1 and stack[-2][0] < stack[-1][0]:
            v2, w2 = stack.pop()
            v1, w1 = stack.pop()
            stack.append([(v1 * w1 + v2 * w2) / (w1 + w2), w1 + w2])
    out = []
    for v, w in stack:
        out.extend([v] * int(w))
    return out


def build_lag_curve(points: list[tuple[int, int]], n: int) -> list[float]:
    """Per-row correction lag, following the measured points directly
    (piecewise-linear interpolation) rather than approximating them with one
    straight line. The sliding-window scan can't probe the last win+search
    rows (there's no room for a full window past them), so the trailing
    segment's slope is extrapolated out to the end of the file.
    """
    rows_sorted = [r for r, _ in sorted(points)]
    smoothed_lags = _isotonic_nonincreasing([l for _, l in sorted(points)])
    pts = list(zip(rows_sorted, smoothed_lags))
    if len(pts) >= 2:
        (r0, l0), (r1, l1) = pts[-2], pts[-1]
        if r1 > r0 and r1 < n - 1:
            tail_slope = (l1 - l0) / (r1 - r0)
            pts.append((n - 1, l1 + tail_slope * (n - 1 - r1)))
    elif pts:
        pts.append((n - 1, pts[-1][1]))
    else:
        pts = [(0, 0), (n - 1, 0)]

    lag = [0.0] * n
    for (r0, l0), (r1, l1) in zip(pts, pts[1:]):
        if r1 <= r0:
            continue
        span = r1 - r0
        for r in range(r0, min(r1, n - 1) + 1):
            lag[r] = l0 + (r - r0) / span * (l1 - l0)
    for r in range(pts[-1][0], n):
        lag[r] = pts[-1][1]
    return lag


def apply_correction(seg: list[list[str]], oh_indices: list[int], lag_curve: list[float]) -> list[list[str]]:
    n = len(seg)
    corrected = [list(r) for r in seg]
    for r in range(n):
        lag = round(lag_curve[r])
        src = max(0, min(n - 1, r + lag))
        if src == r:
            continue
        for ci in oh_indices:
            corrected[r][ci] = seg[src][ci]
    return corrected


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vbo", required=True, type=Path, help="RaceChrono .vbo export recorded with the old firmware")
    ap.add_argument("--out", required=True, type=Path, help="corrected .vbo to write")
    args = ap.parse_args()

    if not args.vbo.is_file():
        raise FixError(f"'{args.vbo}' does not exist.")

    lines, data_start, cols, rows = load_vbo_raw(args.vbo)

    def col(name: str) -> int:
        if name not in cols:
            raise FixError(f"'{args.vbo}' is missing expected column '{name}'.")
        return cols.index(name)

    gps_i = col("velocity")
    oh_speed_i = col("analog1-data")
    rate_i = col("device_update_rate-data")

    seg_start, seg_end = connected_bounds(rows, rate_i)
    seg = rows[seg_start:seg_end + 1]
    print(f"Connected telemetry: rows {seg_start}-{seg_end} ({(len(seg) - 1) * 0.01:.2f}s)")

    slope, points = estimate_drift(seg, gps_i, oh_speed_i)
    print(f"Estimated drift rate: {slope * 100:+.3f}% (telemetry clock vs. GPS real time)")
    print("  window_start_s  lag_rows  lag_s")
    for r, l in points:
        print(f"  {r * 0.01:12.1f}   {l:7d}   {l * 0.01:6.2f}")

    lag_curve = build_lag_curve(points, len(seg))
    oh_indices = [col(c) for c in OH_COLUMNS if c in cols]
    corrected = apply_correction(seg, oh_indices, lag_curve)

    # Self-check: redo the same drift estimate against the corrected data -
    # the slope should now be close to zero.
    check_slope, _ = estimate_drift(corrected, gps_i, oh_speed_i)
    print(f"Residual drift after correction: {check_slope * 100:+.3f}%")

    new_rows = list(rows)
    for i, r in enumerate(corrected):
        new_rows[seg_start + i] = r
    out_lines = list(lines)
    for i, r in enumerate(new_rows):
        out_lines[data_start + i] = " ".join(r) + "\n"

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as f:
        f.writelines(out_lines)
    print(f"Wrote {args.out}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FixError as exc:
        print(f"\nError: {exc}")
        raise SystemExit(2)
