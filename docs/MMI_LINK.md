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
  **STA Wi-Fi settings** (iOS app: More > Wi-Fi; web Setup page in builds with
  `OH_ENABLE_WEB=1`). The one-board build has no AP of its own.
- OpenHaldex sends to its STA gateway (the MMI) on a **UDP port it
  discovers in 49153-49162**. The stock MMI firewall lets hotspot clients
  reach exactly that range, so the head unit needs no firewall change. The
  range is shared with wireless CarPlay/AirPlay, which takes some of those
  ports when the phone connects, so no single fixed port is safe: the head
  unit's receiver binds a free port in the range, and the board finds it.
- Discovery: until the head unit answers, OpenHaldex sends a probe every
  250 ms, each to the next port in the range (a full sweep takes 2.5 s). The
  source port of the first TTA1 ack is kept; TTG1/TTP1/TTR1 then go there
  only, at 20 Hz. After 3 s without acks it goes back to probing, starting
  from the port that last answered. With no STA connection it only checks the
  Wi-Fi state every 500 ms. A home router on the STA side sees at most four
  small datagrams a second.
- Probes all carry the same seq (it only advances while linked), so a sweep
  over unanswered ports does not count as loss on the head unit.
- After 10 s of unanswered probing, or when the STA connection drops, the
  board closes and reopens its UDP socket.
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

### No gateway (car without internet)

Without an internet connection the MMI's dnsmasq sends an empty DHCP router
option, so `WiFi.gatewayIP()` is 0.0.0.0. The board then uses
`(localIP & subnetMask) | 1` as the head unit, which is 10.173.189.1 in the
car (fixed in the stock MMI script). A real gateway is still used when there
is one, and the bench target below overrides both (since v1.1.16).

### Bench target (testing without the car)

`POST /api/wifi {"mmiTarget":"172.20.10.3"}` (app: More → Wi-Fi → Bench test)
sends the datagrams to that address instead of the STA gateway, so a Mac on a
phone hotspot can play the head unit (`scripts/mmi_sim.py` or `ttlink`). Acks
and commands are only accepted from that address. `{"mmiTarget":""}` clears it;
leave it blank in the car. Stored in NVS (`mmiTarget`).

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
| 22 | active preset id (255 = none) | `presetsActiveId()`, see [PRESETS.md](PRESETS.md) |
| 60 | OpenHaldex uptime s | |
| 61 | STA RSSI dBm | |
| 62 | datagrams sent | |

Ids 9, 14, 15 and 17 are reserved on the head-unit side (lambda, lateral and
longitudinal g, battery) and are not sent. Mode numbers match
[RACECHRONO_WIFI.md](RACECHRONO_WIFI.md).

Presets: the head unit can also switch OpenHaldex presets (TTP1 catalog,
TTC1 APPLY_PRESET, TTR1 reply); see [PRESETS.md](PRESETS.md). Bench test
without a head unit: `scripts/mmi_sim.py`.

Code: `src/functions/telemetry/mmi_link.cpp`.

## Cockpit test pattern

App More > Wi-Fi > "Send test pattern to cockpit", `POST /api/mmi/test
{"seconds": 60}` (0 stops, max 600), or TTC1 command 4 with byte 11 =
seconds / 10. For that time the TTG1 values sweep through their ranges, with
flags bit0 set. Every 20 s there is a 4 s held launch: standing, brake 60 bar,
throttle 100 %, DSG launch flag (channel 24) on, lock ramping to 100. Channels
12, 22 and 23 stay real so MMI commands can still be checked. Only what goes to
the MMI changes; Haldex control is untouched. Works with the engine off.

Channel 24 = DSG launch control active (GETRIEBE_14 GE_LaunchControl, bit 51).
