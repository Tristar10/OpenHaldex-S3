#pragma once

#include <stdint.h>

// Tracks when each CAN frame that feeds a decoded signal was last received, so
// the app can show at a glance which signals this bus actually carries.

struct SignalSeenEntry {
  const char* frame;    // DBC frame name, e.g. "MOTOR_04"
  uint32_t id;          // 11-bit CAN id
  uint8_t bus;          // 0 = chassis, 1 = Haldex
  const char* signals;  // what the app derives from it
};

// Called from the receive loops for every frame (cheap linear scan).
void signalSeenTrack(uint32_t id, uint8_t bus, uint32_t now_ms);

uint8_t signalSeenCount();
const SignalSeenEntry& signalSeenEntry(uint8_t index);
// Milliseconds since the frame was last received; UINT32_MAX if never.
uint32_t signalSeenAgeMs(uint8_t index, uint32_t now_ms);
// Frames received since boot (wraps).
uint32_t signalSeenFrames(uint8_t index);
