# One-board build status (branch `one-board-ble`)

One LilyGO T-2CAN runs Haldex control, RaceChrono over BLE, the iOS app over
BLE, and the MMI gauge link over Wi-Fi. Current firmware: **v1.1.15**.

## What runs

| Part | How | Status |
| --- | --- | --- |
| Haldex control (CAN) | unchanged | on the bench, not driven yet |
| RaceChrono | BLE DIY service `0x1FF8`, device `OpenHaldex-RC`, no pairing | verified from a Mac acting as RaceChrono |
| iOS app (replaces the web UI) | BLE service `4f480001-…`, Just Works pairing | API verified over BLE; app on the phone via Xcode (free account, 7-day expiry) |
| MMI gauges | Wi-Fi client of the MMI hotspot, UDP 49160 ([MMI_LINK.md](MMI_LINK.md)) | bench-tested over a Mac hotspot with `scripts/mmi_sim.py`: ~20 Hz, 0 lost, presets apply |
| Presets | [PRESETS.md](PRESETS.md): app + MMI (TTP1/TTC1/TTR1, channel 22) | verified over BLE; MMI path tested only against a simulator |
| Web UI, own AP, DNS/mDNS, internet update | compiled out (`-D OH_ENABLE_WEB=0`) | flip to 1 to bring back |

Internal RAM free: ~85 KB with BLE + app and no hotspot configured; ~39 KB
(min 35 KB) once Wi-Fi joins the hotspot and the MMI link runs. The first
BLE+AP+web build that crashed had 4-14 KB. Static RAM 102 KB, flash 39%.

## Verified on the bench (Mac + board, no car)

- All API endpoints over BLE (status, maps, curves, logs, CAN View, presets,
  404 for unknown) - `scripts/ble_api_test.py`.
- Presets: apply FWD/Street/Autocross; Autocross swaps in exactly
  `aggressive.txt`; unknown id → 409; stale catalog version → result 1; manual
  mode change → active preset 255.
- RaceChrono + app on one link - `scripts/ble_dual_test.py`: decoded PIDs
  0xFFFF0001/2/3 at 19.7 Hz each (20 requested); with the API streaming
  27.6 KB/s continuously, worst PID 18.6 Hz (94%).
- Unattended flashing: `python3 scripts/flash.py` reboots the running board
  into download mode by itself (1200 bps touch). No BOOT/RESET needed.

## Bugs found and fixed along the way

- RaceChrono BLE lost frames in every burst (setValue+notify overwrite): only
  the last of back-to-back frames arrived. Existed since the first BLE build.
- Wheel speeds read 0 whenever a speed input was mapped (Gen 5 default):
  ESP_19 decoding was skipped entirely. Now on PID 0xFFFF0003 at 0.01 km/h.
- Steering sign inverted; convention is now right = +, left = −.
- A reset during BLE startup (serial monitor, flash, RESET) left BLE off until
  power was removed. Now only a real crash skips BLE, for one boot.
- `/api/map` could leave a half-written map on a bad row; maps now swap
  atomically.
- MMI link never came up (ack timestamp wrapped to ~49 days); fixed v1.1.15.
- After a restart, MAP mode came back with the old map instead of the active
  preset's map; fixed v1.1.15.
- Wi-Fi maintenance task had 500 bytes of stack left while joining; now 4 KB.

## Not tested yet

- Anything in the car: Haldex control with this build, real CAN load, the real
  MMI hotspot and head unit, firewall path for TTC1 from the head unit.
- Gear, boost, oil pressure: MOTOR_04 (0x107) likely never reaches the board's
  bus; check CAN View in the car.
- The app against the board on the phone after the preset/live-channel
  changes (installed, needs the first pairing prompt accepted on the phone).
- RaceChrono itself (the Mac emulated its protocol).

## Next steps

1. Phone: open OpenHaldex, accept the pairing prompt, try presets on Home.
2. ~~Bench MMI test~~ done 2026-11-23. Run `mmi_sim.py` from the Terminal
   panel: the Bash tool has no Local Network permission and its replies are
   dropped.
3. RaceChrono: add channels from the app's More → RaceChrono setup page.
4. Car test.
