#include "functions/can/signal_seen.h"

#include "functions/can/can_id.h"

namespace {

// Gen 5 / MQB frames decoded in can_rx.cpp, plus the Haldex status frame.
const SignalSeenEntry kEntries[] = {
  {"MOTOR_04", MOTOR_04, 0, "Gear, boost, oil pressure"},
  {"MOTOR_07", MOTOR_07, 0, "Coolant, oil and intake temps"},
  {"MOTOR_20", MOTOR_20, 0, "Accelerator"},
  {"ESP_19", ESP_19, 0, "Wheel speeds"},
  {"ESP_21", ESP_21, 0, "ABS / ESP / EDS active, vehicle speed"},
  {"ESP_05", ESP_05, 0, "Brake pressure"},
  {"LWI_01", LWI_01, 0, "Steering angle"},
  {"GETRIEBE_12", GETRIEBE_12, 0, "DSG input torque"},
  {"GETRIEBE_14", GETRIEBE_14, 0, "Gearbox temp"},
  {"GATEWAY_72", GATEWAY_72, 0, "Reverse"},
  {"HALDEX_GEN5", HALDEX_ID_GEN5, 1, "Haldex lock actual"},
};
constexpr uint8_t kCount = sizeof(kEntries) / sizeof(kEntries[0]);

volatile uint32_t g_last_ms[kCount] = {};
volatile uint32_t g_frames[kCount] = {};

}  // namespace

void signalSeenTrack(uint32_t id, uint8_t bus, uint32_t now_ms) {
  for (uint8_t i = 0; i < kCount; i++) {
    if (kEntries[i].id == id && kEntries[i].bus == bus) {
      g_last_ms[i] = now_ms ? now_ms : 1;  // 0 means "never"
      g_frames[i] = g_frames[i] + 1;
      return;
    }
  }
}

uint8_t signalSeenCount() { return kCount; }

const SignalSeenEntry& signalSeenEntry(uint8_t index) { return kEntries[index < kCount ? index : 0]; }

uint32_t signalSeenAgeMs(uint8_t index, uint32_t now_ms) {
  if (index >= kCount) return UINT32_MAX;
  const uint32_t last = g_last_ms[index];
  return last == 0 ? UINT32_MAX : now_ms - last;
}

uint32_t signalSeenFrames(uint8_t index) { return index < kCount ? g_frames[index] : 0; }
