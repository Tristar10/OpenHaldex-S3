# MMI link (Audi virtual cockpit telemetry)

OpenHaldex-S3 can send its live values to an Audi MIB2 head unit (MMI) over
the MMI's own Wi-Fi hotspot, so a modified head unit can show them on the
virtual cockpit. The head-unit side lives in the
[audi-tt-8s-altscreen](https://github.com/Tristar10/audi-tt-8s-altscreen) repo
(`ports/tt-8s-mu1462/gauges`, wiki page `Telemetry`).

The values are the ones OpenHaldex already decodes from CAN with its built-in
VW DBC tables (the same `received_*` values the RaceChrono feed uses). Nothing
is decoded twice.

## How it connects

- The MMI is the access point; OpenHaldex joins it as a client using the
  normal **STA Wi-Fi settings** (Setup page: SSID and password of the MMI
  hotspot). OpenHaldex's own `OpenHaldex-S3` AP keeps running.
- OpenHaldex sends to its STA gateway (the MMI) on **UDP 49160**. The stock
  MMI firewall already lets hotspot clients reach UDP 49153-49162, so the
  head unit needs no firewall change.
- Until the head unit answers, OpenHaldex sends one probe a second. Once
  acks arrive it streams at 20 Hz; after 3 s without acks it drops back to
  probing. With no STA connection it only checks the Wi-Fi state every 500 ms. A home router on the
  STA side therefore sees at most one small datagram a second.
- No task of its own: `mmiLinkTick()` runs from `loop()` (loopTask, priority
  1, about 100 calls a second) and limits itself to 20 Hz. Each call is one
  non-blocking UDP send at most, plus draining queued acks; about 200 bytes of
  stack. It only reads the shared values, like the RaceChrono feed, and never
  touches CAN or Haldex control. Cost: about 0.9 KB static RAM and one UDP
  socket (counts against `LWIP_MAX_SOCKETS`).

Side effect of AP+STA on the ESP32: when the STA connects, the AP moves to
the hotspot's Wi-Fi channel, so a phone on `OpenHaldex-S3` may drop and
rejoin once. This already happens with the existing STA (OTA) feature.

## Checking the link

`GET /api/network` now has an `mmi` object:

| Field | Meaning |
| --- | --- |
| `linked` | Head unit answered in the last 3 s |
| `gateway` | STA gateway the datagrams go to (the MMI) |
| `sent` / `acks` | Datagrams sent, acks received |
| `rttMs` / `rttMaxMs` | Round-trip time, last and max |
| `huRx` / `huLost` | Datagrams the head unit received / gaps it counted |
| `lastAckAgeMs` | Time since the last ack |

The serial/file log shows `[mmi]` lines: gateway found, link up, link lost.

## Protocol

Big-endian. OpenHaldex to head unit, `TTG1`:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `TTG1` |
| 4 | 4 | key, u32 (0) |
| 8 | 2 | sequence, u16 |
| 10 | 1 | flags (0) |
| 11 | 1 | entry count N |
| 12 + 6i | 2 | channel id, u16 |
| 14 + 6i | 4 | value x 1000, s32 |

Head unit to OpenHaldex, `TTA1` (20 bytes): echoed sequence u16, reserved
u16, received u32, lost u32, head-unit uptime ms u32.

| Id | Value | Source |
| --- | --- | --- |
| 1 | engine rpm | `received_vehicle_rpm` |
| 2 | speed km/h | `received_vehicle_speed` |
| 3 | pedal % | `received_pedal_value` |
| 4 | torque Nm (DSG input) | `received_engine_torque_nm` |
| 5 | coolant degC | `received_coolant_temp_c` |
| 6 | oil degC | `received_oil_temp_c` |
| 7 | intake air degC | `received_intake_air_temp_c` |
| 8 | boost kPa above atmospheric | `received_vehicle_boost` / 10 |
| 10 | Haldex lock target % | `lock_target` |
| 11 | Haldex actual % | `received_haldex_engagement` |
| 12 | OpenHaldex mode | `openhaldexEffectiveMode()` |
| 13 | gear (raw nibble) | `received_gear_number` |
| 16 | DSG sump degC | `received_trans_temp_c` |
| 18 | oil pressure bar | `received_oil_pressure_decibar` / 10 |
| 19 | Haldex clutch degC (only once valid) | `received_haldex_clutch_temp_c` |
| 20 | steering angle deg (right = +, left = −) | `received_steering_angle_decidegrees` / 10 |
| 21 | brake pressure bar | `received_brake_pressure_decibar` / 10 |
| 60 | OpenHaldex uptime s | |
| 61 | STA RSSI dBm | |
| 62 | datagrams sent | |

Ids 9, 14, 15 and 17 are reserved on the head-unit side (lambda, lateral and
longitudinal g, battery) and are not sent. Mode numbers match
[RACECHRONO_WIFI.md](RACECHRONO_WIFI.md).

Code: `src/functions/telemetry/mmi_link.cpp`.
