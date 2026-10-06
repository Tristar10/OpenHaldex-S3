#include "functions/diag/engine_probe.h"

#include <string.h>

#include "functions/can/can.h"
#include "functions/config/config.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"

struct engine_probe_variant_t {
  const char* name;
  uint32_t requestId;
  bool extended;
  uint8_t len;
  uint8_t payload[7];
};

// All requests are read-only (current engine RPM).
static const engine_probe_variant_t k_variants[] = {
  {"obd-functional-7df", 0x7DF, false, 2, {0x01, 0x0C}},
  {"obd-physical-7e0", 0x7E0, false, 2, {0x01, 0x0C}},
  {"uds-physical-7e0", 0x7E0, false, 3, {0x22, 0xF4, 0x0C}},
  {"obd-functional-29bit", 0x18DB33F1, true, 2, {0x01, 0x0C}},
  {"uds-physical-29bit", 0x18DA10F1, true, 3, {0x22, 0xF4, 0x0C}},
};

static const uint32_t k_variant_window_ms = 300;
static const uint8_t k_max_replies = 8;

static QueueHandle_t g_rx_queue = nullptr;
static SemaphoreHandle_t g_mutex = nullptr;
static volatile bool g_listening = false;

// 11-bit OBD/UDS responses (0x7E8-0x7EF) and 29-bit responses to tester 0xF1.
static bool isEngineResponseId(const twai_message_t& frame) {
  const uint32_t id = frame.identifier & 0x1FFFFFFF;
  if (frame.extd) {
    return (id & 0x1FFFFF00) == 0x18DAF100;
  }
  return id >= 0x7E8 && id <= 0x7EF;
}

void engineProbeInit() {
  if (!g_rx_queue) {
    g_rx_queue = xQueueCreate(16, sizeof(twai_message_t));
  }
  if (!g_mutex) {
    g_mutex = xSemaphoreCreateMutex();
  }
}

void engineProbeObserveChassisFrame(const twai_message_t& frame) {
  if (!g_listening || !g_rx_queue || !isEngineResponseId(frame)) {
    return;
  }
  (void)xQueueSend(g_rx_queue, &frame, 0);
}

static String hexBytes(const uint8_t* data, uint8_t len) {
  String out;
  for (uint8_t i = 0; i < len; i++) {
    if (i > 0) {
      out += " ";
    }
    if (data[i] < 0x10) {
      out += "0";
    }
    out += String(data[i], HEX);
  }
  out.toUpperCase();
  return out;
}

static String hexId(uint32_t id, bool extended) {
  String hex = String(id, HEX);
  hex.toUpperCase();
  while (hex.length() < (extended ? 8u : 3u)) {
    hex = "0" + hex;
  }
  return "0x" + hex;
}

// Single-frame ISO-TP payload: data[0] = 0x0N, service bytes follow.
static bool decodeRpm(const twai_message_t& frame, float& rpm) {
  if (frame.data_length_code < 5 || (frame.data[0] & 0xF0) != 0x00) {
    return false;
  }
  const uint8_t len = frame.data[0] & 0x0F;
  const uint8_t* p = &frame.data[1];
  if (len >= 4 && p[0] == 0x41 && p[1] == 0x0C) {
    rpm = (((uint16_t)p[2] << 8) | p[3]) / 4.0f;
    return true;
  }
  if (len >= 5 && frame.data_length_code >= 6 && p[0] == 0x62 && p[1] == 0xF4 && p[2] == 0x0C) {
    rpm = (((uint16_t)p[3] << 8) | p[4]) / 4.0f;
    return true;
  }
  return false;
}

static void runVariant(const engine_probe_variant_t& v, JsonObject out) {
  out["name"] = v.name;
  out["requestId"] = hexId(v.requestId, v.extended);

  twai_message_t msg = {};
  msg.identifier = v.requestId;
  msg.extd = v.extended ? 1 : 0;
  msg.data_length_code = 8;
  memset(msg.data, 0x55, sizeof(msg.data));
  msg.data[0] = v.len;
  memcpy(&msg.data[1], v.payload, v.len);
  out["request"] = hexBytes(msg.data, 8);

  twai_message_t discarded = {};
  while (xQueueReceive(g_rx_queue, &discarded, 0) == pdTRUE) {
  }

  const bool sent = chassis_can_send(msg, pdMS_TO_TICKS(20));
  out["sent"] = sent;
  JsonArray replies = out["replies"].to<JsonArray>();
  if (!sent) {
    return;
  }

  const uint32_t started_ms = millis();
  uint8_t count = 0;
  while ((millis() - started_ms) < k_variant_window_ms && count < k_max_replies) {
    const uint32_t remaining = k_variant_window_ms - (millis() - started_ms);
    twai_message_t frame = {};
    if (xQueueReceive(g_rx_queue, &frame, pdMS_TO_TICKS(remaining ? remaining : 1)) != pdTRUE) {
      continue;
    }
    JsonObject r = replies.add<JsonObject>();
    r["id"] = hexId(frame.identifier & 0x1FFFFFFF, frame.extd);
    r["ms"] = millis() - started_ms;
    r["data"] = hexBytes(frame.data, frame.data_length_code);
    float rpm = 0.0f;
    if (decodeRpm(frame, rpm)) {
      r["rpm"] = rpm;
    } else if (frame.data[0] == 0x03 && frame.data[1] == 0x7F) {
      r["negative"] = true;
      r["nrc"] = hexBytes(&frame.data[3], 1);
    }
    count++;
  }
}

void engineProbeRun(JsonObject out) {
  engineProbeInit();
  if (!g_rx_queue || !g_mutex) {
    out["ok"] = false;
    out["error"] = "init_failed";
    return;
  }
  if (xSemaphoreTake(g_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    out["ok"] = false;
    out["error"] = "busy";
    return;
  }

  g_listening = true;
  JsonArray variants = out["variants"].to<JsonArray>();
  bool any_rpm = false;
  for (const engine_probe_variant_t& v : k_variants) {
    JsonObject row = variants.add<JsonObject>();
    runVariant(v, row);
    for (JsonObject r : row["replies"].as<JsonArray>()) {
      if (r["rpm"].is<float>()) {
        any_rpm = true;
      }
    }
    vTaskDelay(pdMS_TO_TICKS(30));
  }
  g_listening = false;
  xSemaphoreGive(g_mutex);

  out["ok"] = true;
  out["engineReachable"] = any_rpm;
  LOG_INFO("diag", "Engine probe finished reachable=%d", any_rpm ? 1 : 0);
}
