# RaceChrono WiFi telemetry

OpenHaldex-S3 runs a RaceChrono DIY telemetry server over its existing Wi-Fi
access point, using RaceChrono's `$RC3` TCP/IP protocol. This reuses the
Wi-Fi radio already required for the WebUI instead of adding Bluetooth as a
second radio.

Earlier builds used a Bluetooth LE DIY CAN-Bus bridge instead. That approach
was dropped: enabling the BLE radio on this hardware could brown out the
board (the controller sits inline on the CAN bus and controls Haldex AWD
behavior, so a mid-drive reset is not an acceptable risk). WiFi telemetry
reuses the Wi-Fi link that is already proven stable on this board.

## Connect RaceChrono

1. Flash the application firmware and restart the controller normally.
2. Join the `OpenHaldex-S3` Wi-Fi network from your phone.
3. In RaceChrono, open **Settings > Add other device > Add other device >
   RaceChrono DIY**.
4. Select connection method **TCP/IP**, enter IP address `192.168.4.1` and
   port `1338`, then save.
5. Open the active vehicle profile and add channels for the values you want
   to record (see the table below).

The controller does not need to be paired or discovered; RaceChrono connects
to the fixed IP/port above. Only one RaceChrono client is supported.

## OpenHaldex channels

`$RC3` only carries fixed, pre-decoded channels (unlike the BLE DIY protocol,
it has no raw CAN-ID passthrough). The firmware decodes these into the
generic analog channel slots:

| RC3 field | Channel | Unit |
| --- | --- | --- |
| rpm/d1 | Engine speed | RPM |
| Analog 1 | Vehicle speed | km/h |
| Analog 2 | Accelerator | % |
| Analog 3 | Requested Haldex lock | % |
| Analog 4 | Actual Haldex lock | % |
| Analog 5 | OpenHaldex mode | number |

Mode numbers are: Stock `0`, FWD `1`, 50:50 `2`, 60:40 `3`, 70:30 `4`,
80:20 `5`, 90:10 `6`, Speed `7`, Throttle `8`, Map `9`, and RPM `10`.

Vehicle speed currently follows the controller's whole-km/h internal value.

## Performance and failure behavior

- The CAN bridge never calls the telemetry code and never waits for it.
- Telemetry runs in a separate low-priority task on the application core, at
  a fixed 20 Hz.
- A disconnected or absent RaceChrono client is a no-op; it never delays
  Haldex traffic or the WebUI.
- One RaceChrono client is the supported configuration. A second phone can
  continue to use the OpenHaldex Wi-Fi WebUI as a dash.

## Bench test without a CAN harness

1. Connect RaceChrono to the controller over TCP/IP and add the OpenHaldex
   mode channel above.
2. Start a RaceChrono session and confirm the channel reads `0` in Stock
   mode.
3. On another device connected to the OpenHaldex Wi-Fi, change to a fixed
   mode via the WebUI.
4. Confirm the recorded mode value changes to the number in the table.
5. Keep the WebUI open and switch pages while recording. It should remain
   responsive and the controller should not restart or disconnect.

Vehicle speed, RPM, accelerator and actual lock will remain zero on a bench
with no CAN harness. Test those channels at idle before the first driving
session.
