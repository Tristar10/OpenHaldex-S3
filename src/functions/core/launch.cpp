#include "functions/core/launch.h"

#include <Arduino.h>

#include "functions/core/state.h"

namespace {

constexpr uint32_t kStandCenti = 100;      // < 1 km/h = standing
constexpr uint32_t kMovingCenti = 200;     // >= 2 km/h = launched
constexpr uint32_t kTargetCenti = 10000;   // 100 km/h
constexpr int16_t kArmBrakeDecibar = 500;  // 50 bar
constexpr float kArmPedal = 30.0f;
constexpr float kLiftPedal = 20.0f;
constexpr uint32_t kDisarmMs = 1000;
constexpr uint32_t kLiftMs = 500;
constexpr uint32_t kMaxRunMs = 20000;
constexpr uint32_t kDoneHoldMs = 30000;
constexpr uint32_t kAbortHoldMs = 3000;

volatile LaunchState g_state = LAUNCH_IDLE;
volatile uint32_t g_start_ms = 0;
volatile uint32_t g_result_ms = 0;
uint32_t g_state_ms = 0;        // when the current state was entered
uint32_t g_last_stand_ms = 0;   // last sample below 1 km/h
uint32_t g_unarmed_since = 0;   // ARMED: first sample without the arm condition
uint32_t g_lift_since = 0;      // RUNNING: first sample below the lift threshold

void enter(LaunchState s, uint32_t now) {
  g_state = s;
  g_state_ms = now;
  g_unarmed_since = 0;
  g_lift_since = 0;
}

bool armCondition() {
  return received_dsg_launch_active ||
         (received_brake_pressure_decibar >= kArmBrakeDecibar && received_pedal_value >= kArmPedal);
}

}  // namespace

void launchTrack(uint32_t speed, uint32_t now) {
  const bool standing = speed < kStandCenti;
  if (standing) g_last_stand_ms = now;

  switch (g_state) {
  case LAUNCH_IDLE:
    if (standing && armCondition()) enter(LAUNCH_ARMED, now);
    break;

  case LAUNCH_ARMED:
    if (speed >= kMovingCenti) {
      g_start_ms = g_last_stand_ms;
      enter(LAUNCH_RUNNING, now);
    } else if (!armCondition()) {
      // Brake released with throttle still pinned is the launch itself, so
      // give it a moment before calling it off.
      if (g_unarmed_since == 0) g_unarmed_since = now;
      if (now - g_unarmed_since >= kDisarmMs) enter(LAUNCH_ABORTED, now);
    } else {
      g_unarmed_since = 0;
    }
    break;

  case LAUNCH_RUNNING:
    if (speed >= kTargetCenti) {
      g_result_ms = now - g_start_ms;
      enter(LAUNCH_DONE, now);
    } else if (now - g_start_ms > kMaxRunMs || standing) {
      enter(LAUNCH_ABORTED, now);
    } else if (received_pedal_value < kLiftPedal) {
      if (g_lift_since == 0) g_lift_since = now;
      if (now - g_lift_since >= kLiftMs) enter(LAUNCH_ABORTED, now);
    } else {
      g_lift_since = 0;
    }
    break;

  case LAUNCH_DONE:
    if (now - g_state_ms >= kDoneHoldMs) enter(LAUNCH_IDLE, now);
    break;

  case LAUNCH_ABORTED:
    if (now - g_state_ms >= kAbortHoldMs) enter(LAUNCH_IDLE, now);
    break;
  }
}

LaunchState launchState() { return g_state; }

uint32_t launchElapsedMs() {
  switch (g_state) {
  case LAUNCH_RUNNING: return millis() - g_start_ms;
  case LAUNCH_DONE: return g_result_ms;
  default: return 0;
  }
}
