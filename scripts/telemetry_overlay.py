#!/usr/bin/env python3
"""Render an OpenHaldex telemetry HUD overlay from a RaceChrono .vbo export
as a transparent-background video, ready to drop onto footage in any video
editor.

Requires: Pillow (pip install Pillow), ffmpeg on PATH.

Examples:
  # WebM/VP9 with alpha (smaller, widely supported):
  python3 scripts/telemetry_overlay.py --vbo session.vbo --out overlay.webm

  # ProRes 4444 with alpha (bigger, best for pro NLEs):
  python3 scripts/telemetry_overlay.py --vbo session.vbo --out overlay.mov

See docs/VIDEO_OVERLAY.md for the full guide and channel mapping notes.
"""
from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = None

W, H = 1920, 1080
FONT_DIR = "/System/Library/Fonts/Supplemental"
if sys.platform != "darwin" or not os.path.isdir(FONT_DIR):
    FONT_DIR = None  # fall back to Pillow's default bitmap font on non-macOS

WHITE = (255, 255, 255, 255)
DIM = (255, 255, 255, 145)
RED = (227, 75, 74, 255)
GREEN = (99, 153, 34, 255)
AMBER = (239, 159, 39, 255)
BLUE = (55, 138, 221, 255)
GRAY = (90, 90, 90, 180)
BG_PANEL = (18, 18, 20, 135)

MODE_NAMES = ["STOCK", "FWD", "50:50", "60:40", "70:30", "80:20", "90:10", "SPEED", "THROTTLE", "MAP", "RPM"]


class OverlayError(RuntimeError):
    """A user-actionable overlay-generation error."""


def _font(name: str, size: int):
    if FONT_DIR:
        try:
            return ImageFont.truetype(os.path.join(FONT_DIR, name), size)
        except OSError:
            pass
    return ImageFont.load_default(size)


class Fonts:
    def __init__(self):
        self.speed = _font("Arial Black.ttf", 140)
        self.speed_unit = _font("Arial Bold.ttf", 32)
        self.big_num = _font("Arial Black.ttf", 46)
        self.med_num = _font("Arial Bold.ttf", 34)
        self.label = _font("Arial Bold.ttf", 22)
        self.label_sm = _font("Arial Bold.ttf", 18)
        self.mode = _font("Arial Black.ttf", 36)
        self.time = _font("Arial Black.ttf", 56)


def find_ffmpeg() -> str:
    found = shutil.which("ffmpeg")
    if not found:
        raise OverlayError(
            "ffmpeg was not found on PATH. Install it (e.g. 'brew install ffmpeg' on macOS)."
        )
    return found


def load_vbo(path: Path) -> list[dict]:
    """Parse a RaceChrono .vbo export into one dict per ~100Hz data row.

    Field mapping matches the RC3 sentence layout built in
    src/functions/telemetry/racechrono_wifi.cpp - if that layout changes,
    update COLUMN below to match (see docs/VIDEO_OVERLAY.md).
    """
    with path.open("r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    idx = {}
    for i, l in enumerate(lines):
        s = l.strip()
        if s.startswith("[") and s.endswith("]"):
            idx[s[1:-1]] = i

    for required in ("column names", "data"):
        if required not in idx:
            raise OverlayError(f"'{path}' doesn't look like a RaceChrono .vbo export (no [{required}] section).")

    colnames_i = idx["column names"] + 1
    while lines[colnames_i].strip() == "":
        colnames_i += 1
    col_names = lines[colnames_i].split()

    data_start = idx["data"] + 1
    rows = [l.split() for l in lines[data_start:] if l.strip()]
    if not rows:
        raise OverlayError(f"'{path}' has no data rows.")

    def col(name: str) -> int:
        if name not in col_names:
            raise OverlayError(
                f"'{path}' is missing the expected column '{name}'. "
                "This likely means it wasn't exported from a session with the OpenHaldex-S3 "
                "WiFi DIY device connected, or the RC3 channel layout has changed."
            )
        return col_names.index(name)

    rate_i = col("device_update_rate-data")
    out = []
    for r in rows:
        if len(r) != len(col_names):
            continue
        out.append({
            "connected": r[rate_i] != "+000.000",
            "speed": float(r[col("analog1-data")]),
            "rpm": float(r[col("digital1-data")]),
            "pedal": float(r[col("analog2-data")]),
            "lock_act": float(r[col("analog4-data")]),
            "mode": int(float(r[col("analog5-data")])),
            # GPS-derived, from RaceChrono's own standard columns - not our CAN
            # telemetry. Wheel speed FL/FR/RL/RR was dropped here (confirmed
            # dead CAN signal on the reference car - see docs/VIDEO_OVERLAY.md);
            # these replace it with real, populated data.
            "gps_speed": float(r[col("velocity")]),
            "long_g": float(r[col("longacc-calc")]),
            "lat_g": float(r[col("latacc-calc")]),
            "clutch_temp": float(r[col("analog10-data")]),
            "steering": float(r[col("analog11-data")]),
            "brake": float(r[col("analog12-data")]),
            "oil_temp": float(r[col("analog13-data")]),
            "coolant_temp": float(r[col("analog14-data")]),
            "trans_temp": float(r[col("analog15-data")]),
            "iat": float(r[col("z_rate_of_rotation-data")]),
            "abs": float(r[col("x_acc-data")]) != 0,
            "esp": float(r[col("y_acc-data")]) != 0,
            "eds": float(r[col("z_acc-data")]) != 0,
        })
    return out


def _panel(d, x, y, w, h):
    d.rounded_rectangle([x, y, x + w, y + h], radius=16, fill=BG_PANEL)


def _label(d, x, y, text, f, color=DIM):
    d.text((x, y), text, font=f, fill=color)


def _hbar(d, x, y, w, h, pct, color, bg=(255, 255, 255, 40)):
    d.rounded_rectangle([x, y, x + w, y + h], radius=h / 2, fill=bg)
    fw = max(0, min(1, pct)) * w
    if fw > 2:
        d.rounded_rectangle([x, y, x + fw, y + h], radius=h / 2, fill=color)


def _indicator(d, cx, cy, r, text, active, color, f):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(color if active else GRAY))
    bbox = d.textbbox((0, 0), text, font=f)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2, cy + r + 4), text, font=f, fill=WHITE if active else DIM)


def _centered(d, cx, y, text, f, color):
    bbox = d.textbbox((0, 0), text, font=f)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2 - bbox[0], y), text, font=f, fill=color)


def render_frame(row: dict, fonts: Fonts) -> "Image.Image":
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Main cluster: bottom-left - speed, RPM, pedal, mode, lock, Haldex temp
    px, py, pw, ph = 36, H - 320, 620, 284
    _panel(d, px, py, pw, ph)
    speed_top = py + 18
    d.text((px + 24, speed_top), f"{row['speed']:.0f}", font=fonts.speed, fill=WHITE)
    bbox = d.textbbox((px + 24, speed_top), f"{row['speed']:.0f}", font=fonts.speed)
    d.text((bbox[2] + 8, bbox[3] - 38), "km/h", font=fonts.speed_unit, fill=DIM)
    speed_bottom = bbox[3]

    row2_y = speed_bottom + 44
    _label(d, px + 24, row2_y - 26, f"RPM {row['rpm']:.0f}", fonts.label)
    rpm_pct = row["rpm"] / 7000.0
    rpm_color = GREEN if rpm_pct < 0.7 else (AMBER if rpm_pct < 0.9 else RED)
    _hbar(d, px + 24, row2_y, 330, 18, rpm_pct, rpm_color)

    _label(d, px + 24, row2_y + 34, f"PEDAL {row['pedal']:.0f}%", fonts.label)
    _hbar(d, px + 24, row2_y + 60, 330, 18, row["pedal"] / 100.0, BLUE)

    mode_name = MODE_NAMES[row["mode"]] if 0 <= row["mode"] < len(MODE_NAMES) else "?"
    mb_x, mb_y, mb_w, mb_h = px + pw - 210, py + 18, 190, 62
    d.rounded_rectangle([mb_x, mb_y, mb_x + mb_w, mb_y + mb_h], radius=12, fill=(255, 255, 255, 30))
    _centered(d, mb_x + mb_w / 2, mb_y + 10, mode_name, fonts.mode, WHITE)
    _label(d, mb_x, mb_y + mb_h + 6, "MODE", fonts.label_sm)

    lock_y = row2_y
    _label(d, mb_x, lock_y - 26, f"LOCK {row['lock_act']:.0f}%", fonts.label)
    _hbar(d, mb_x, lock_y, mb_w, 18, row["lock_act"] / 100.0, GREEN)

    temp = row["clutch_temp"]
    temp_color = GREEN if temp < 90 else (AMBER if temp < 110 else RED)
    _label(d, mb_x, lock_y + 34, "HALDEX TEMP", fonts.label)
    _centered(d, mb_x + 60, lock_y + 56, f"{temp:.0f}°", fonts.med_num, temp_color)

    # Chassis cluster: bottom-right - brake, steering, ABS/ESP/EDS
    cx0, cy0, cw, ch = W - 520 - 36, H - 320, 520, 284
    _panel(d, cx0, cy0, cw, ch)
    _label(d, cx0 + 24, cy0 + 16, "CHASSIS", fonts.label)
    _label(d, cx0 + 24, cy0 + 56, f"BRAKE PRESSURE {row['brake']:.1f} bar", fonts.label)
    _hbar(d, cx0 + 24, cy0 + 82, 300, 18, row["brake"] / 100.0, RED)

    _label(d, cx0 + 24, cy0 + 126, f"STEERING {row['steering']:+.0f}°", fonts.label)
    steer_pct = max(-1, min(1, row["steering"] / 480.0))
    bar_x, bar_w = cx0 + 24, 300
    mid = bar_x + bar_w / 2
    d.rounded_rectangle([bar_x, cy0 + 152, bar_x + bar_w, cy0 + 170], radius=9, fill=(255, 255, 255, 40))
    d.line([(mid, cy0 + 148), (mid, cy0 + 174)], fill=DIM, width=2)
    if steer_pct >= 0:
        d.rounded_rectangle([mid, cy0 + 152, mid + steer_pct * (bar_w / 2), cy0 + 170], radius=9, fill=BLUE)
    else:
        d.rounded_rectangle([mid + steer_pct * (bar_w / 2), cy0 + 152, mid, cy0 + 170], radius=9, fill=BLUE)

    ind_x = cx0 + 400
    _indicator(d, ind_x, cy0 + 70, 24, "ABS", row["abs"], AMBER, fonts.label_sm)
    _indicator(d, ind_x, cy0 + 150, 24, "ESP", row["esp"], RED, fonts.label_sm)
    _indicator(d, ind_x, cy0 + 230, 24, "EDS", row["eds"], AMBER, fonts.label_sm)

    # Temps strip: top-left
    tx, ty, tw_, th_ = 36, 36, 640, 108
    _panel(d, tx, ty, tw_, th_)
    temps = [("OIL", row["oil_temp"]), ("COOLANT", row["coolant_temp"]),
             ("TRANS", row["trans_temp"]), ("IAT", row["iat"])]
    slot_w = tw_ / 4
    for i, (name, val) in enumerate(temps):
        cx = tx + slot_w * i + slot_w / 2
        tcolor = GREEN if val < 95 else (AMBER if val < 115 else RED)
        _centered(d, cx, ty + 14, f"{val:.0f}°", fonts.big_num, tcolor)
        _centered(d, cx, ty + 76, name, fonts.label_sm, DIM)

    # G-meter: top-center - live lat/long G ball with peak-so-far readouts.
    gx, gy, gs = tx + tw_ + 40, 36, 280
    _panel(d, gx, gy, gs, gs)
    gcx, gcy = gx + gs / 2, gy + gs / 2 - 12
    gr = gs / 2 - 56
    for ring_g, ring_alpha in ((0.5, 50), (1.0, 70)):
        rr = gr * (ring_g / 1.5)
        d.ellipse([gcx - rr, gcy - rr, gcx + rr, gcy + rr], outline=(255, 255, 255, ring_alpha), width=2)
    d.line([(gcx - gr, gcy), (gcx + gr, gcy)], fill=(255, 255, 255, 40), width=1)
    d.line([(gcx, gcy - gr), (gcx, gcy + gr)], fill=(255, 255, 255, 40), width=1)
    dot_x = gcx + max(-1.5, min(1.5, row["lat_g"])) / 1.5 * gr
    dot_y = gcy - max(-1.5, min(1.5, row["long_g"])) / 1.5 * gr
    dot_r = 11
    d.ellipse([dot_x - dot_r, dot_y - dot_r, dot_x + dot_r, dot_y + dot_r], fill=AMBER)
    _centered(d, gcx, gy + gs - 76,
              f"LAT {row['peak_lat_g']:.2f}g   ACCEL {row['peak_accel_g']:.2f}g   BRAKE {row['peak_brake_g']:.2f}g",
              fonts.label_sm, DIM)
    _centered(d, gcx, gy + gs - 52, "PEAK G (SESSION)", fonts.label_sm, DIM)

    # Best-run stats: top-center-right - Dragy-style 0-100/quarter mile.
    dragy = row.get("dragy", {})
    sx, sy, sw, sh = gx + gs + 30, 36, 300, 280
    _panel(d, sx, sy, sw, sh)
    _centered(d, sx + sw / 2, sy + 14, "BEST RUN", fonts.label, DIM)

    def fmt_s(v):
        return f"{v:.2f}s" if v is not None else "—"

    _label(d, sx + 24, sy + 54, "0-100 KM/H", fonts.label_sm)
    _centered(d, sx + sw / 2, sy + 76, fmt_s(dragy.get("zero_to_100_s")), fonts.big_num, WHITE)
    _label(d, sx + 24, sy + 140, "0-60 MPH", fonts.label_sm)
    _centered(d, sx + sw / 2, sy + 162, fmt_s(dragy.get("zero_to_60mph_s")), fonts.big_num, WHITE)
    _label(d, sx + 24, sy + 226, "1/4 MILE", fonts.label_sm)
    quarter_s = dragy.get("quarter_mile_s")
    quarter_trap = dragy.get("quarter_mile_trap_kmh")
    quarter_text = f"{quarter_s:.2f}s @ {quarter_trap:.0f}km/h" if quarter_s is not None else "—"
    _centered(d, sx + sw / 2, sy + 248, quarter_text, fonts.med_num, WHITE)

    # Session elapsed time: top-right
    if "elapsed" in row:
        ex, ey, ew, eh = W - 260 - 36, 36, 260, 100
        _panel(d, ex, ey, ew, eh)
        mm = int(row["elapsed"] // 60)
        ss = row["elapsed"] % 60
        _centered(d, ex + ew / 2, ey + 16, f"{mm:01d}:{ss:05.2f}", fonts.time, WHITE)
        _centered(d, ex + ew / 2, ey + 76, "SESSION TIME", fonts.label_sm, DIM)

    return img


def connected_segment(rows: list[dict]) -> list[dict]:
    connected_idx = [i for i, r in enumerate(rows) if r["connected"]]
    if not connected_idx:
        raise OverlayError("No connected OpenHaldex telemetry found in this .vbo (device_update_rate stayed 0).")
    return rows[connected_idx[0]:connected_idx[-1] + 1]


def compute_g_peaks(seg: list[dict]) -> list[dict]:
    """Running max-so-far of lateral/accel/braking G, one dict per row."""
    peak_lat = peak_accel = peak_brake = 0.0
    out = []
    for r in seg:
        peak_lat = max(peak_lat, abs(r["lat_g"]))
        peak_accel = max(peak_accel, r["long_g"])
        peak_brake = max(peak_brake, -r["long_g"])
        out.append({"peak_lat_g": peak_lat, "peak_accel_g": peak_accel, "peak_brake_g": peak_brake})
    return out


_QUARTER_MILE_M = 402.336
_LAUNCH_SPEED_KMH = 5.0
_ABORT_SPEED_KMH = 3.0


def compute_dragy_stats(seg: list[dict]) -> dict:
    """Best-of-session 0-100km/h, 0-60mph, and 1/4 mile ET/trap speed, Dragy-
    style: scan every near-standstill point as a launch candidate, integrate
    GPS speed (trapezoidal) forward from it, and keep the single best clean
    run - all splits reported together come from that one run, same as Dragy
    (not cherry-picked independently per metric from different launches).
    GPS speed is used rather than CAN speed since it's independent of any
    telemetry timing/decode issues and is what Dragy itself is based on.

    A "clean run" requires roughly monotonic acceleration: on a technical
    course (autocross, not a drag strip) a launch can run straight into a
    corner, and integrating straight through the resulting slowdown would
    produce a nonsense (very slow) split, so a run aborts as soon as speed
    sags more than 20% off its peak-so-far within that attempt.
    """
    n = len(seg)
    speeds = [r["gps_speed"] for r in seg]
    dt = 0.01

    candidates = []  # each: dict with t100/t60/tq/trap_q (any may be None)

    i = 0
    while i < n - 1:
        if speeds[i] >= _LAUNCH_SPEED_KMH:
            i += 1
            continue
        dist_m = 0.0
        t100 = t60 = tq = trap_q = None
        peak_v = speeds[i]
        j = i
        while j < n - 1:
            v0, v1 = speeds[j], speeds[j + 1]
            dist_m += (v0 + v1) / 2.0 * (1000.0 / 3600.0) * dt
            t_elapsed = (j + 1 - i) * dt
            peak_v = max(peak_v, v1)
            if t100 is None and v1 >= 100.0:
                t100 = t_elapsed
            if t60 is None and v1 >= 96.5606:  # 60 mph
                t60 = t_elapsed
            if tq is None and dist_m >= _QUARTER_MILE_M:
                tq = t_elapsed
                trap_q = v1
            if tq is not None and t100 is not None:
                break
            if v1 < _ABORT_SPEED_KMH and t_elapsed > 1.0:
                break  # dropped back to a stop - not a continuous run
            if peak_v > _LAUNCH_SPEED_KMH and v1 < peak_v * 0.8:
                break  # sagged off a corner mid-"run" - not a clean pull
            j += 1

        if t100 is not None or t60 is not None or tq is not None:
            candidates.append({"zero_to_100_s": t100, "zero_to_60mph_s": t60,
                                "quarter_mile_s": tq, "quarter_mile_trap_kmh": trap_q})
        i = max(j, i + 1)

    if not candidates:
        return {"zero_to_100_s": None, "zero_to_60mph_s": None,
                "quarter_mile_s": None, "quarter_mile_trap_kmh": None}

    # Prefer the run that completes the furthest/hardest benchmark, fastest:
    # a finished quarter mile beats a 0-100 beats a 0-60-only run.
    def rank(c):
        if c["quarter_mile_s"] is not None:
            return (0, c["quarter_mile_s"])
        if c["zero_to_100_s"] is not None:
            return (1, c["zero_to_100_s"])
        return (2, c["zero_to_60mph_s"])

    return min(candidates, key=rank)


def prepare_row(seg: list[dict], g_peaks: list[dict], dragy: dict, t: float) -> dict:
    idx = max(0, min(len(seg) - 1, int(round(t / 0.01))))
    row = dict(seg[idx])
    row.update(g_peaks[idx])
    row["dragy"] = dragy
    row["elapsed"] = t
    return row


def render_frames(seg: list[dict], out_dir: Path, start: float, end: float, fps: float,
                   g_peaks: list[dict] | None = None, dragy: dict | None = None) -> int:
    if Image is None:
        raise OverlayError("Pillow is required: pip install Pillow")
    fonts = Fonts()
    out_dir.mkdir(parents=True, exist_ok=True)
    if g_peaks is None:
        g_peaks = compute_g_peaks(seg)
    if dragy is None:
        dragy = compute_dragy_stats(seg)
    frame_dt = 1.0 / fps
    t = start
    n = 0
    while t <= end:
        data_row = prepare_row(seg, g_peaks, dragy, t)
        render_frame(data_row, fonts).save(out_dir / f"frame_{n:06d}.png")
        n += 1
        t += frame_dt
    return n


def run(cmd: list[str]) -> None:
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise OverlayError(f"Command failed: {' '.join(cmd)}\n{result.stderr[-4000:]}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vbo", required=True, type=Path, help="RaceChrono .vbo export to read telemetry from")
    ap.add_argument("--out", required=True, type=Path, help="output file path (.webm, .mov, or a directory for --format png)")
    ap.add_argument("--fps", type=float, default=20.0, help="overlay frame rate (default 20)")
    ap.add_argument("--format", choices=["webm", "prores", "png"], default=None,
                     help="output format (default: guessed from --out's extension - .mov -> prores, otherwise webm)")
    args = ap.parse_args()

    if not args.vbo.is_file():
        raise OverlayError(f"'{args.vbo}' does not exist.")

    ffmpeg = find_ffmpeg()
    rows = load_vbo(args.vbo)
    seg = connected_segment(rows)
    vbo_duration = (len(seg) - 1) * 0.01

    g_peaks = compute_g_peaks(seg)
    dragy = compute_dragy_stats(seg)

    def fmt_s(v):
        return f"{v:.2f}s" if v is not None else "n/a"

    print(f"Best 0-100 km/h: {fmt_s(dragy['zero_to_100_s'])}  |  "
          f"Best 0-60 mph: {fmt_s(dragy['zero_to_60mph_s'])}  |  "
          f"Best 1/4 mile: {fmt_s(dragy['quarter_mile_s'])}"
          + (f" @ {dragy['quarter_mile_trap_kmh']:.0f}km/h" if dragy['quarter_mile_trap_kmh'] else ""))
    print(f"Peak G: lat {g_peaks[-1]['peak_lat_g']:.2f}g  accel {g_peaks[-1]['peak_accel_g']:.2f}g  "
          f"brake {g_peaks[-1]['peak_brake_g']:.2f}g")

    with tempfile.TemporaryDirectory(prefix="oh_overlay_") as tmp:
        frames_dir = Path(tmp) / "frames"
        n = render_frames(seg, frames_dir, 0.0, vbo_duration, args.fps, g_peaks, dragy)
        print(f"Rendered {n} overlay frames ({vbo_duration:.2f}s of telemetry).")

        fmt = args.format
        if fmt is None:
            ext = args.out.suffix.lower()
            fmt = "prores" if ext == ".mov" else ("png" if ext == "" else "webm")

        args.out.parent.mkdir(parents=True, exist_ok=True)
        if fmt == "png":
            args.out.mkdir(parents=True, exist_ok=True)
            for p in frames_dir.glob("*.png"):
                shutil.copy(p, args.out / p.name)
            print(f"Wrote {n} PNG frames to {args.out}")
        elif fmt == "prores":
            run([ffmpeg, "-y", "-framerate", str(args.fps), "-i", str(frames_dir / "frame_%06d.png"),
                 "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-alpha_bits", "16",
                 str(args.out)])
            print(f"Wrote {args.out} (ProRes 4444 with alpha)")
        else:
            run([ffmpeg, "-y", "-framerate", str(args.fps), "-i", str(frames_dir / "frame_%06d.png"),
                 "-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p", "-b:v", "0", "-crf", "32", "-auto-alt-ref", "0",
                 str(args.out)])
            print(f"Wrote {args.out} (WebM/VP9 with alpha)")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except OverlayError as exc:
        print(f"\nError: {exc}", file=sys.stderr)
        raise SystemExit(2)
