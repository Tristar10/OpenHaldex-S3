# RaceChrono BLE telemetry

OpenHaldex-S3 advertises a RaceChrono DIY CAN-Bus device named
`OpenHaldex-RC`. It implements the official RaceChrono BLE service and works
alongside the normal OpenHaldex Wi-Fi access point and WebUI.

## Power the controller from 12V/VIN, not USB alone

Powering the board over USB only (e.g. a laptop port during bring-up) can
brown out the moment the BLE radio initializes, even on USB ports rated for
high wattage: the board does not negotiate USB-PD, and the one-time radio
calibration burst can exceed what the USB path delivers. Power the controller
from its 12V/VIN input (vehicle or bench supply) whenever BLE is enabled. USB
can stay connected for flashing and serial logs alongside VIN power.

## Connect RaceChrono

1. Flash the application firmware and restart the controller normally.
2. In RaceChrono, open **Settings > Add other device > Add other device >
   RaceChrono DIY**.
3. Select **Bluetooth LE** and **CAN-Bus**, then select `OpenHaldex-RC`.
4. Open the active vehicle profile and add CAN-Bus channels for the values you
   want to record.

RaceChrono Pro is required for freely typed CAN-Bus equations. The controller
does not need to be paired in the phone's system Bluetooth settings.

## Easy OpenHaldex channels

For a quick setup, add channels using PID `0xFFFF0001`. The same eight-byte
packet contains all of these values:

| Channel | Unit | RaceChrono equation |
| --- | --- | --- |
| Vehicle speed | km/h | `bytesToUint(raw, 0, 2) / 100.0` |
| Engine speed | RPM | `bytesToUint(raw, 2, 2)` |
| Accelerator | % | `E * 100.0 / 255.0` |
| Requested Haldex lock | % | `F` |
| Actual Haldex lock | % | `G` |
| OpenHaldex mode | number | `H` |

Mode numbers are: Stock `0`, FWD `1`, 50:50 `2`, 60:40 `3`, 70:30 `4`,
80:20 `5`, 90:10 `6`, Speed `7`, Throttle `8`, Map `9`, and RPM `10`.

The decoded packet is intended for convenient logging. Speed currently follows
the controller's whole-km/h internal value, even though the packet and equation
allow two decimal places.

## Log raw chassis CAN

You can also add any chassis CAN identifier as its RaceChrono PID and decode its
original eight data bytes with a normal RaceChrono equation. For example, CAN
ID `0x123` uses PID `0x123`. Only PIDs requested by RaceChrono are copied to the
BLE queue, so select the small set of PT-CAN signals needed for the session.

Raw frames are captured before OpenHaldex changes any pass-through data. Haldex
module-side frames are not sent over BLE.

## Performance and failure behavior

- The CAN bridge never calls the Bluetooth stack and never waits for telemetry.
- BLE transmission runs in a separate low-priority task on the application core.
- A full telemetry queue drops telemetry packets; it cannot delay Haldex traffic.
- Each selected PID is capped at 50 Hz. RaceChrono may request a slower rate.
- Promiscuous/allow-all mode is capped at 50 packets per second total. Specific
  PID channels are preferred for an autocross session.
- One RaceChrono BLE client is the supported configuration. A second phone can
  continue to use the OpenHaldex Wi-Fi WebUI as a dash.
- BLE reserves its radio memory before Wi-Fi starts and validates every setup step. If BLE crashes
  during startup, the following boot leaves BLE disabled so the controller and
  WebUI remain recoverable. Remove power and reconnect it to retry BLE.

## Bench test without a CAN harness

1. Connect RaceChrono to `OpenHaldex-RC` and add the OpenHaldex mode channel
   above.
2. Start a RaceChrono session and confirm the channel reads `0` in Stock mode.
3. On another device connected to the OpenHaldex Wi-Fi, change to a fixed mode.
4. Confirm the recorded mode value changes to the number in the table.
5. Keep the WebUI open and switch pages while recording. It should remain
   responsive and the controller should not restart or disconnect.

Vehicle speed, RPM, accelerator and actual lock will remain zero on a bench with
no CAN harness. Test those channels at idle before the first driving session.
