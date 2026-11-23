# One-board build status (branch `one-board-ble`)

One LilyGO T-2CAN runs Haldex control, RaceChrono over BLE, the iOS app over
BLE, and the MMI gauge link over Wi-Fi. Current firmware: **v1.1.11**.

## What runs

| Part | How | Status |
| --- | --- | --- |
| Haldex control (CAN) | unchanged | on the bench, not driven yet |
| RaceChrono | BLE DIY service `0x1FF8`, device `OpenHaldex-RC`, no pairing | verified from a Mac acting as RaceChrono |
| iOS app (replaces the web UI) | BLE service `4f480001-…`, Just Works pairing | API verified over BLE; app on the phone via Xcode (free account, 7-day expiry) |
| MMI gauges | Wi-Fi client of the MMI hotspot, UDP 49160 ([MMI_LINK.md](MMI_LINK.md)) | built and merged; not yet tested with a hotspot |
| Presets | [PRESETS.md](PRESETS.md): app + MMI (TTP1/TTC1/TTR1, channel 22) | verified over BLE; MMI path tested only against a simulator |
| Web UI, own AP, DNS/mDNS, internet update | compiled out (`-D OH_ENABLE_WEB=0`) | flip to 1 to bring back |

Internal RAM free: ~85 KB (min ~85 KB) with BLE + app, versus 4-14 KB on the
first BLE+AP+web build that crashed. Static RAM 102 KB, flash 39%.

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

## Not tested yet

- Anything in the car: Haldex control with this build, real CAN load, MMI
  hotspot, firewall path for TTC1 from the head unit.
- The app against the board on the phone after the preset/live-channel
  changes (installed, needs the first pairing prompt accepted on the phone).
- RaceChrono itself (the Mac emulated its protocol).

## Next steps

1. Phone: open OpenHaldex, accept the pairing prompt, try presets on Home.
2. Bench MMI test: Mac Internet Sharing (iPhone USB → Wi-Fi), hotspot creds
   in the app (More → Wi-Fi), then `./ttlink -l - -a 2` or
   `python3 scripts/mmi_sim.py --apply 2`.
3. RaceChrono: add channels from the app's More → RaceChrono setup page.
4. Car test.
