# Telemetry video overlay

Renders a HUD-style telemetry overlay from a RaceChrono `.vbo` export (the
file produced by RaceChrono Pro's "Export to VBO" on a session recorded
with the OpenHaldex-S3 WiFi DIY telemetry device connected - see
[RACECHRONO_WIFI.md](RACECHRONO_WIFI.md)) as a transparent-background
video - just the gauges/numbers, nothing else - ready to drop onto your
own footage as an overlay track in any video editor (Premiere, Resolve,
Final Cut, etc.).

RaceChrono's RC2/RC3 channels can't be renamed or re-equationed in-app, and
re-importing an edited `.vbo` back into RaceChrono drops all custom
channels (GPS-only re-import) - this tool exists as the practical
workaround for getting readable, labeled telemetry alongside footage.

## Requirements

- Python 3 with Pillow: `pip install Pillow`
- `ffmpeg` (and `ffprobe`) on `PATH`

## Web app (recommended)

```bash
python3 scripts/telemetry_overlay_app.py
```

Opens a local page in your browser. Drag in a `.vbo`, scrub a live preview
to check the data before committing to a render, see which channels are
flagged dead for that specific session (no variation anywhere in it - a
decent sign the signal isn't on this car's bus), pick frame rate/format,
and render. Progress is shown live; when it's done, download the file.
Everything runs locally - nothing leaves your machine. `--port` picks a
different port than the default 8787, `--no-browser` skips auto-opening.

## Format: use ProRes 4444 (.mov) for editors

WebM/VP9 alpha is small and plays correctly in VLC/ffmpeg-based tools, but
support for it in video editors is inconsistent - Final Cut doesn't read it
natively at all, and Premiere/Resolve's handling has been unreliable across
versions. The practical symptom: the editor can't read the clip's frame
rate correctly and falls back to some default, so a 10-20fps overlay plays
back noticeably faster than it should once dropped onto a timeline (this
is *not* a bug in the render - the file itself is frame-accurate; verified
by burning the elapsed time into the overlay and seeking to known points).

**If you're dropping the overlay into an editor, use ProRes 4444 (`.mov`)**
- it's the default in the web app, and every major NLE reads its frame
rate metadata correctly. Reach for WebM only for quick previews outside an
editor (a browser, VLC, etc.) where its small size is worth more than
editor compatibility.

## CLI

For scripting, or if you'd rather not run a server, `scripts/telemetry_overlay.py`
does the same render non-interactively:

```bash
python3 scripts/telemetry_overlay.py --vbo session.vbo --out overlay.mov
```

Or as WebM/VP9 with alpha (smaller, for quick non-editor previews only - see above):

```bash
python3 scripts/telemetry_overlay.py --vbo session.vbo --out overlay.webm
```

Or as a folder of transparent PNG frames, one per frame:

```bash
python3 scripts/telemetry_overlay.py --vbo session.vbo --out frames/ --format png
```

Run `python3 scripts/telemetry_overlay.py --help` for all options (frame
rate, etc).

The output covers the *connected* telemetry only - i.e. from the moment
the device first reports `device_update_rate-data` nonzero to when it
last does, not the full RaceChrono session. Line this clip up with your
footage by eye/ear in your editor: pick one clearly identifiable moment
(a corner, a hard brake, a flash) visible in both, and slide the overlay
track to match.

## If a session was recorded before the `vTaskDelayUntil()` fix

Firmware builds before that fix paced the telemetry loop with `vTaskDelay()`,
which doesn't compensate for the loop body's own execution time - the true
average send rate ran a little under 20.000Hz, and since RaceChrono infers
each sample's real timestamp from the packet counter assuming a dead-steady
rate (see [RACECHRONO_WIFI.md](RACECHRONO_WIFI.md)), that small error
compounded into the OpenHaldex channels drifting increasingly ahead of real
(GPS) time over a session - a few percent by the end of a ~2 minute run. A
session recorded with the fixed firmware shouldn't need this; for one
recorded before it, `scripts/fix_vbo_drift.py` measures the drift from the
file itself (cross-correlating RaceChrono's own GPS speed against the
OpenHaldex speed channel) and resamples every OpenHaldex-sourced column back
onto the correct real-time grid:

```bash
python3 scripts/fix_vbo_drift.py --vbo session.vbo --out session_fixed.vbo
```

Feed the corrected file into the overlay tool as usual.

## Known-dead channels

On the car this was developed against, these CAN messages were never
observed on the bus (gear/oil pressure/boost all share one message; engine
torque is a separate one) and read zero - not a decode bug, the message
itself isn't reaching this car's CAN tap:

- Gear number, oil pressure, boost pressure (all from `Motor_04`/`0x107`)
- Engine torque (`Getriebe_12`/`0xAE`)

Wheel speed FL/FR/RL/RR (`ESP_19`/`0xB2`) was the same story and has been
removed from the overlay entirely (not just hidden) - replaced with a G-meter
and Dragy-style performance stats, which use RaceChrono's own GPS-derived
acceleration channels instead of CAN, so they don't depend on finding an
alternate wheel-speed signal.

## Overlay layout

- Bottom-left: speed, RPM bar, pedal position, mode, Haldex lock %, Haldex
  clutch temp
- Bottom-right ("CHASSIS"): brake pressure, steering angle, ABS/ESP/EDS
  indicators
- Top-left: oil/coolant/trans/intake-air temps
- Top-center: G-meter (live lateral/longitudinal G ball, peak-so-far
  readouts) and a "best run" panel (0-100 km/h, 0-60 mph, 1/4 mile ET/trap
  speed) - Dragy-style launch detection over the whole session, reported
  from a single clean run rather than mixed across different launches. On a
  technical/autocross course these often show "-": a corner mid-run aborts
  the detection on purpose rather than reporting a misleadingly slow split
  from a run that drove through a corner instead of a straight.
- Top-right: session elapsed time

G/speed data for the G-meter and best-run stats comes from RaceChrono's own
`longacc-calc`/`latacc-calc`/`velocity` columns (GPS-derived, the same
source Dragy itself uses) - not from this project's CAN telemetry, so it's
available on any session regardless of which CAN channels this car exposes.

All panels are semi-transparent so footage remains visible underneath.
