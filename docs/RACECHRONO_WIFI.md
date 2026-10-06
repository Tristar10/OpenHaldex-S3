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

| RC3 field | Channel | Unit | Notes |
| --- | --- | --- | --- |
| xacc | ABS active | 0/1 | Gen 5 only; repurposed field, see caveat below |
| yacc | ESP active | 0/1 | Gen 5 only; repurposed field, see caveat below |
| zacc | EDS/XDS active | 0/1 | Gen 5 only; repurposed field, see caveat below |
| gyrox | Gear number | number | Gen 5 only; repurposed field, see caveat below |
| gyroy | Oil pressure | Bar (one decimal) | Gen 5 only; repurposed field, see caveat below |
| gyroz | Intake air temperature | degrees C | Gen 5 only; repurposed field, see caveat below |
| rpm/d1 | Engine speed | RPM | |
| d2 | Boost | mbar, relative to atmospheric | Gen 5 only |
| Analog 1 | Vehicle speed | km/h | |
| Analog 2 | Accelerator | % | |
| Analog 3 | Engine torque | Nm | Gen 5 only, DSG/dual-clutch only |
| Analog 4 | Actual Haldex lock | % | |
| Analog 5 | OpenHaldex mode | number | |
| Analog 6 | Wheel speed, front left | km/h | Gen 5 only |
| Analog 7 | Wheel speed, front right | km/h | Gen 5 only |
| Analog 8 | Wheel speed, rear left | km/h | Gen 5 only |
| Analog 9 | Wheel speed, rear right | km/h | Gen 5 only |
| Analog 10 | Haldex clutch temperature | degrees C | Gen 5 only; polled via UDS every ~2s, not live CAN - see below |
| Analog 11 | Steering angle | degrees (one decimal, e.g. `-15.3`) | Gen 5 only; sign convention unverified, see below |
| Analog 12 | Brake pressure | Bar (one decimal, e.g. `48.0`) | Gen 5 only |
| Analog 13 | Oil temperature | degrees C | Gen 5 only |
| Analog 14 | Coolant temperature | degrees C | Gen 5 only |
| Analog 15 | Transmission sump temperature | degrees C | Gen 5 only, DSG/dual-clutch only |

Mode numbers are: Stock `0`, FWD `1`, 50:50 `2`, 60:40 `3`, 70:30 `4`,
80:20 `5`, 90:10 `6`, Speed `7`, Throttle `8`, Map `9`, and RPM `10`.

"Gen 5 only" channels are zero (or blank, for clutch temperature before the
first successful read) on Haldex generation 1/2/4 (PQ chassis) controllers;
that platform's CAN layout doesn't currently decode these signals in this
firmware. "Requested Haldex lock %" (previously Analog 3) was dropped to
make room for engine torque; actual lock (Analog 4) is unaffected.

Steering angle, brake pressure, oil temp, coolant temp, intake air temp,
gear number, and oil pressure are decoded from CAN IDs that were already
reserved in `can_id.h` (`LWI_01`, `ESP_05`, `MOTOR_07`) but unused until now.
ABS/ESP/EDS come from `ESP_21`, a frame this firmware already decodes for a
vehicle-speed fallback. The bit layout and scaling come from
[commaai/opendbc's `vw_mqb.dbc`](https://github.com/commaai/opendbc/blob/master/opendbc/dbc/vw_mqb.dbc)
(the DBC library behind openpilot), cross-checked against this firmware's
already-working boost decode, which matches that DBC's `MO_Ladedruck` signal
bit-for-bit. Transmission sump temperature (`GE_Sumpftemperatur`, ID 968)
and engine torque (`GE_Aufnahmemoment`, ID 174 - this is gearbox *input*
torque, DSG-side, used as a proxy for engine output torque) come from the
same source. Steering angle's positive/negative direction convention (left
vs. right) has not been verified against a real car. RaceChrono's RC2/RC3
analog/accel/gyro fields have no per-channel equation editor (confirmed:
unlike the BLE DIY CAN-Bus protocol, there is no way to rename or rescale
these channels on the RaceChrono side), so values that need adjusting -
including the steering sign, if it reads backwards - have to be fixed in
firmware (`racechrono_wifi.cpp`), not in the app.

There is no signal in this DBC distinctly labeled "XDS" - `EDS_Eingriff`
(electronic differential lock intervention) is the closest available signal,
since XDS is built on EDS braking the inside wheel in a corner. Ride height
and ignition timing retard were not found in this DBC (checked both this
repo's copy and the latest upstream version) or in any UDS DID catalog this
project has; ride height likely needs air-suspension-specific hardware this
car may not have, and ignition timing retard is normally only exposed via a
UDS measured-value request to the engine ECU, which this project has no
catalog for (unlike the Haldex controller's). Neither is sent.

ABS active, ESP active, EDS/XDS active, gear number, oil pressure, and
intake air temperature are sent in the `xacc`/`yacc`/`zacc`/`gyrox`/`gyroy`/
`gyroz` fields (there's no IMU on this board, and all 15 analog slots were
already in use for other channels). Confirmed on a real RaceChrono
installation: none of the RC2/RC3 fields - analog or accel/gyro alike - can
be renamed, re-unitted, or given a custom equation from within the app.
They show up as generic "Analog N" labels (and presumably similar generic
labels for the accel/gyro fields) that cannot be edited, which is why
values needing scaling or sign correction are pre-adjusted in firmware
rather than left to a RaceChrono-side equation.

Haldex clutch temperature is read via a UDS request (`ReadDataByIdentifier`,
DID `0x2BF1`) to the Haldex Gen 5 controller every ~2 seconds, not sniffed
passively off the CAN bus like the other channels - it updates at that
interval and only once the first read succeeds. This shares the same request
path as the Diagnostics page; both are serialized through the firmware's
existing diagnostic mutex, so using the Diagnostics page at the same time
only delays individual polls rather than conflicting.

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
