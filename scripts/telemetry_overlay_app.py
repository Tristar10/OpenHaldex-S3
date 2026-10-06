#!/usr/bin/env python3
"""Local web app for generating an OpenHaldex telemetry HUD overlay from a
RaceChrono .vbo export. Drag in a file, scrub a live preview, render a
transparent-background video.

Requires: Pillow (pip install Pillow), ffmpeg on PATH. Reuses the render
logic from telemetry_overlay.py (same directory) - that script remains the
scriptable/CLI entry point; this is the interactive one.

Usage: python3 scripts/telemetry_overlay_app.py [--port 8787] [--no-browser]
"""
from __future__ import annotations

import argparse
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import telemetry_overlay as core  # noqa: E402

APP_DIR = Path(__file__).resolve().parent / "overlay_app"

STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "application/javascript; charset=utf-8"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
}

# (row key, display label, is_boolean) - used to flag channels with no
# variation across the session ("dead"/not present on this car's bus).
CHANNELS = [
    ("speed", "Speed", False),
    ("rpm", "RPM", False),
    ("pedal", "Pedal position", False),
    ("lock_act", "Haldex lock %", False),
    ("gps_speed", "GPS speed", False),
    ("long_g", "Longitudinal G", False),
    ("lat_g", "Lateral G", False),
    ("clutch_temp", "Haldex clutch temp", False),
    ("steering", "Steering angle", False),
    ("brake", "Brake pressure", False),
    ("oil_temp", "Oil temp", False),
    ("coolant_temp", "Coolant temp", False),
    ("trans_temp", "Trans sump temp", False),
    ("iat", "Intake air temp", False),
    ("abs", "ABS active", True),
    ("esp", "ESP active", True),
    ("eds", "EDS active", True),
]

STATE_LOCK = threading.Lock()
STATE = {"seg": None, "duration": 0.0, "g_peaks": None, "dragy": None}

FONTS = None  # created on first use, after we know Pillow imported fine

JOBS_LOCK = threading.Lock()
JOBS: dict[str, dict] = {}


def get_fonts():
    global FONTS
    if FONTS is None:
        FONTS = core.Fonts()
    return FONTS


def compute_channel_stats(seg: list[dict]) -> dict:
    out = {}
    for key, label, is_bool in CHANNELS:
        vals = [r[key] for r in seg]
        if is_bool:
            dead = not any(vals)
        else:
            dead = (max(vals) - min(vals)) < 0.5
        out[key] = {"label": label, "dead": dead}
    return out


def run_render_job(job_id: str, fps: float, fmt: str) -> None:
    job = JOBS[job_id]
    try:
        with STATE_LOCK:
            seg = STATE["seg"]
            g_peaks = STATE["g_peaks"]
            dragy = STATE["dragy"]
        if seg is None:
            raise core.OverlayError("No .vbo loaded.")

        duration = (len(seg) - 1) * 0.01
        frame_dt = 1.0 / fps
        total = int(duration // frame_dt) + 1
        job["total"] = total

        work_dir = Path(tempfile.mkdtemp(prefix="oh_overlay_app_"))
        frames_dir = work_dir / "frames"
        frames_dir.mkdir()
        fonts = get_fonts()

        t = 0.0
        n = 0
        while t <= duration:
            row = core.prepare_row(seg, g_peaks, dragy, t)
            core.render_frame(row, fonts).save(frames_dir / f"frame_{n:06d}.png")
            n += 1
            job["rendered"] = n
            t += frame_dt

        job["status"] = "encoding"
        ffmpeg = core.find_ffmpeg()
        if fmt == "prores":
            out_path = work_dir / "overlay.mov"
            core.run([ffmpeg, "-y", "-framerate", str(fps), "-i", str(frames_dir / "frame_%06d.png"),
                      "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-alpha_bits", "16",
                      str(out_path)])
        else:
            out_path = work_dir / "overlay.webm"
            core.run([ffmpeg, "-y", "-framerate", str(fps), "-i", str(frames_dir / "frame_%06d.png"),
                      "-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p", "-b:v", "0", "-crf", "32", "-auto-alt-ref", "0",
                      str(out_path)])

        shutil.rmtree(frames_dir, ignore_errors=True)
        job["status"] = "done"
        job["path"] = str(out_path)
    except Exception as exc:
        job["status"] = "error"
        job["error"] = str(exc)


class Handler(BaseHTTPRequestHandler):
    server_version = "OpenHaldexOverlayApp/1"

    def log_message(self, fmt, *args):
        pass

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path in STATIC_FILES:
            fname, ctype = STATIC_FILES[path]
            fpath = APP_DIR / fname
            if not fpath.is_file():
                self._json(404, {"error": f"missing static file {fname}"})
                return
            data = fpath.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if path == "/api/frame":
            qs = parse_qs(parsed.query)
            try:
                t = float(qs.get("t", ["0"])[0])
            except ValueError:
                self._json(400, {"error": "invalid t"})
                return
            with STATE_LOCK:
                seg = STATE["seg"]
                g_peaks = STATE["g_peaks"]
                dragy = STATE["dragy"]
            if seg is None:
                self._json(409, {"error": "No .vbo loaded."})
                return
            t = max(0.0, min(STATE["duration"], t))
            img = core.render_frame(core.prepare_row(seg, g_peaks, dragy, t), get_fonts())
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            data = buf.getvalue()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return

        if path == "/api/render/status":
            qs = parse_qs(parsed.query)
            job_id = qs.get("id", [""])[0]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if job is None:
                self._json(404, {"error": "unknown job id"})
                return
            self._json(200, {
                "status": job["status"],
                "rendered": job.get("rendered", 0),
                "total": job.get("total", 0),
                "error": job.get("error"),
            })
            return

        if path == "/api/render/download":
            qs = parse_qs(parsed.query)
            job_id = qs.get("id", [""])[0]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if job is None or job["status"] != "done":
                self._json(409, {"error": "render not ready"})
                return
            out_path = Path(job["path"])
            ctype = "video/webm" if out_path.suffix == ".webm" else "video/quicktime"
            size = out_path.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", f'attachment; filename="{out_path.name}"')
            self.end_headers()
            try:
                with out_path.open("rb") as f:
                    shutil.copyfileobj(f, self.wfile)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        self._json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        if path == "/api/upload":
            filename = unquote(self.headers.get("X-Filename", "upload.vbo"))
            tmp = None
            try:
                with tempfile.NamedTemporaryFile(suffix=".vbo", delete=False) as f:
                    f.write(body)
                    tmp = Path(f.name)
                rows = core.load_vbo(tmp)
                seg = core.connected_segment(rows)
            except core.OverlayError as exc:
                self._json(400, {"error": str(exc)})
                return
            except Exception as exc:
                self._json(400, {"error": f"Could not parse '{filename}': {exc}"})
                return
            finally:
                if tmp is not None:
                    tmp.unlink(missing_ok=True)

            duration = (len(seg) - 1) * 0.01
            g_peaks = core.compute_g_peaks(seg)
            dragy = core.compute_dragy_stats(seg)
            with STATE_LOCK:
                STATE["seg"] = seg
                STATE["duration"] = duration
                STATE["g_peaks"] = g_peaks
                STATE["dragy"] = dragy

            self._json(200, {
                "duration": duration,
                "rows": len(seg),
                "channels": compute_channel_stats(seg),
                "peak_g": g_peaks[-1],
                "dragy": dragy,
            })
            return

        if path == "/api/render":
            try:
                req = json.loads(body.decode("utf-8")) if body else {}
            except json.JSONDecodeError:
                self._json(400, {"error": "invalid JSON body"})
                return
            fps = float(req.get("fps", 20) or 20)
            fmt = req.get("format", "prores")
            if fmt not in ("webm", "prores"):
                self._json(400, {"error": f"unsupported format '{fmt}'"})
                return
            if fps <= 0 or fps > 60:
                self._json(400, {"error": "fps must be between 1 and 60"})
                return
            with STATE_LOCK:
                has_vbo = STATE["seg"] is not None
            if not has_vbo:
                self._json(409, {"error": "No .vbo loaded."})
                return

            job_id = uuid.uuid4().hex
            with JOBS_LOCK:
                JOBS[job_id] = {"status": "rendering", "rendered": 0, "total": 0}
            threading.Thread(target=run_render_job, args=(job_id, fps, fmt), daemon=True).start()
            self._json(200, {"job_id": job_id})
            return

        self._json(404, {"error": "not found"})


def cleanup_jobs():
    with JOBS_LOCK:
        for job in JOBS.values():
            path = job.get("path")
            if path:
                shutil.rmtree(Path(path).parent, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--no-browser", action="store_true", help="don't auto-open the browser")
    args = ap.parse_args()

    try:
        core.find_ffmpeg()
    except core.OverlayError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2

    if core.Image is None:
        print("Error: Pillow is required: pip install Pillow", file=sys.stderr)
        return 2

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}"
    print(f"OpenHaldex telemetry overlay app running at {url}")
    print("Press Ctrl+C to stop.")
    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cleanup_jobs()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
