#pragma once

#include <stdint.h>

// Launch detector and 0-100 km/h timer, fed from the wheel speeds (ESP_19,
// ~50 Hz). Read-only: it never touches Haldex control.
//
//   IDLE    -> ARMED   standing (< 1 km/h) and either DSG launch control is
//                      active or brake >= 50 bar with throttle >= 30 %
//   ARMED   -> RUNNING the car moves off (>= 2 km/h); the clock starts at
//                      the last sample still below 1 km/h
//   RUNNING -> DONE    100 km/h reached; the time is held for 30 s
//   ARMED/RUNNING -> ABORTED  disarmed while standing for 1 s, throttle
//                      below 20 % for 0.5 s while running, or 20 s elapsed;
//                      shown for 3 s
enum LaunchState : uint8_t {
  LAUNCH_IDLE = 0,
  LAUNCH_ARMED = 1,
  LAUNCH_RUNNING = 2,
  LAUNCH_DONE = 3,
  LAUNCH_ABORTED = 4,
};

// Called with the average wheel speed in 0.01 km/h for every ESP_19 frame.
void launchTrack(uint32_t speed_centi_kmh, uint32_t now_ms);
LaunchState launchState();
// RUNNING: ms since the start. DONE: the 0-100 time. Otherwise 0.
uint32_t launchElapsedMs();
