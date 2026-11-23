# Presets

A preset is a named bundle the MMI (virtual cockpit) and the iOS app switch
between with one press: an OpenHaldex **mode**, optionally a **map file**, and
optionally the **gates** (disable above throttle/speed, lock release ramp).

Applying a preset is safe while driving:

- Every preset's map is parsed into PSRAM when the catalog loads (boot or
  catalog save). Applying swaps it in atomically, the same way the control
  loop reads it, so no half-written table is ever used.
- No file read and no flash write happens on apply. The new mode, map, gates
  and active preset id are persisted later by the existing settings writer
  (`writeEEP` / `storageSave`), exactly like a mode-button press.
- Apply is refused while Haldex calibration (learn) runs, while CAN View
  capture holds the controller in its safe state, or when the caller's catalog
  version is stale. Selecting a STOCK preset turns the controller output off,
  like the Off button.
- The CAN mode trigger and reverse/thermal protection still override on top,
  as they do for a manual mode.

## Catalog

Stored in `/presets.json` on LittleFS. Without that file the compiled-in
defaults are used (proposed, not yet chosen by the user):

| Id | Name | Mode | Map |
| --- | --- | --- | --- |
| 1 | Street | STOCK | |
| 2 | Autocross | MAP | `/maps/aggressive.txt` |
| 3 | Launch | 5050 | |
| 4 | Wet | MAP | `/maps/conservative.txt` |
| 5 | FWD | FWD | |

File format (max 8 presets, ids 0-254 unique, names 1-16 characters):

```json
{"presets": [
  {"id": 1, "name": "Street", "mode": "STOCK", "map": ""},
  {"id": 2, "name": "Autocross", "mode": "MAP", "map": "/maps/aggressive.txt",
   "disableSpeed": 0, "lockReleaseRatePctPerSec": 80}
]}
```

`mode` uses the API mode names (STOCK, FWD, 5050, 6040, 7030, 8020, 9010,
SPEED, THROTTLE, MAP, RPM). A MAP preset must name a map. `disableThrottle`,
`disableSpeed` and `lockReleaseRatePctPerSec` are optional; when omitted, the
preset leaves that setting as it is.

The **catalog version** is a CRC-16 of the ids, names, modes and map paths. It
is stable across reboots and changes whenever the catalog does.

The **active preset** is the one last applied, reported only while the
controller still matches it (same mode, map and specified gates). After a
manual mode change or map edit it reads 255 ("none").

## API (HTTP before, BLE API in the one-board build)

| Route | Body | Result |
| --- | --- | --- |
| `GET /api/presets` | | `{version, active, custom, presets:[{id,name,mode,map,mapLoaded,...}]}` |
| `POST /api/presets/apply` | `{"id": 2, "version": 48879}` (version optional) | 200 `{ok, active, mode}` or 409 `{ok:false, result, error}` |
| `POST /api/presets` | the catalog JSON above | validates, writes `/presets.json`, reloads |
| `POST /api/presets/reset` | | deletes `/presets.json`, back to defaults |

## MMI protocol

Same UDP socket and port (49160) as the TTG1 stream (see
[MMI_LINK.md](MMI_LINK.md)); big-endian; the head unit replies to the source
port OpenHaldex sends from, as with TTA1. Key is the same u32 as TTG1.

**TTP1** OpenHaldex to MMI, preset catalog. Sent when the link comes up, when
the catalog version changes, and every 5 s while linked (UDP may drop it).

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `TTP1` |
| 4 | 4 | key, u32 |
| 8 | 2 | catalog version, u16 |
| 10 | 1 | preset count N |
| 11 | ... | N entries: id u8, mode u8, name length u8, name bytes (UTF-8, <= 16, no NUL) |

**TTC1** MMI to OpenHaldex, command (14 bytes).

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `TTC1` |
| 4 | 4 | key, u32 |
| 8 | 2 | command sequence, u16 (new value per command; reuse it to retry) |
| 10 | 1 | command: 1 = APPLY_PRESET |
| 11 | 1 | preset id |
| 12 | 2 | catalog version the head unit is showing, u16 |

Accepted only from the STA gateway with a matching key. A retry with the same
sequence number within 5 s is answered again without applying twice; after
5 s the same number is treated as a new command. Preset names are plain ASCII
(the head-unit font is unverified for anything else).

**TTR1** OpenHaldex to MMI, command reply (14 bytes), sent immediately.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `TTR1` |
| 4 | 4 | key, u32 |
| 8 | 2 | echoed command sequence |
| 10 | 1 | result: 0 ok, 1 catalog version mismatch, 2 unknown preset, 3 calibration running, 4 CAN View capture active, 5 preset map missing, 255 unknown command |
| 11 | 1 | active preset id (255 = none) |
| 12 | 2 | current catalog version |

On result 1 the head unit should wait for the next TTP1 (at most 5 s) and let
the driver pick again. Independently of TTR1, **TTG1 channel 22** carries the
active preset id at 20 Hz; its change is the confirmation the agreed design
relies on, so a lost TTR1 is harmless.

## Bench testing without a car or head unit

`scripts/mmi_sim.py` is a fake head unit that speaks TTG1/TTA1 plus
TTP1/TTC1/TTR1. Run it on the machine that is the Wi-Fi hotspot the board
joins:

```bash
python3 scripts/mmi_sim.py --apply 2
```

It prints the catalog when it arrives, applies preset 2, prints the TTR1
reply, and shows `preset=` and `mode=` from the live stream once a second.
Type a preset id + Enter to apply another one. `--no-ack` checks that the board
drops back to 1 Hz probes.
