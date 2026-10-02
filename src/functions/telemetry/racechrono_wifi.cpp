#include "functions/telemetry/racechrono_wifi.h"

#include <Arduino.h>
#include <WiFi.h>

#include "functions/config/config.h"
#include "functions/core/state.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

namespace {

// Port RaceChrono connects to as a TCP client; enter the controller's AP
// address (192.168.4.1) and this port in RaceChrono's "RaceChrono DIY" >
// "TCP/IP" device settings. See docs/RACECHRONO_WIFI.md.
constexpr uint16_t kTcpPort = 1338;
constexpr uint32_t kTelemetryIntervalMs = 50; // 20 Hz.
constexpr uint32_t kAcceptPollIntervalMs = 200;

WiFiServer g_server(kTcpPort);
WiFiClient g_client;
bool g_server_started = false;

// $RC3 is a clear-text NMEA-0183-style extension; checksum is the XOR of all
// characters strictly between '$' and '*'.
uint8_t xorChecksum(const char* body, size_t length) {
  uint8_t checksum = 0;
  for (size_t i = 0; i < length; i++) {
    checksum ^= static_cast<uint8_t>(body[i]);
  }
  return checksum;
}

// Builds one $RC3 sentence carrying the OpenHaldex channels in the generic
// analog slots (a1-a5). RaceChrono's RC2/RC3 DIY protocol only carries fixed,
// pre-decoded channels, unlike the raw CAN-ID passthrough the BLE DIY
// protocol supports - see docs/RACECHRONO_WIFI.md for the channel mapping.
size_t buildSentence(char* out, size_t out_size, uint16_t count) {
  const uint16_t speed_kmh = received_vehicle_speed;
  const uint16_t rpm = received_vehicle_rpm;
  const int pedal_percent = (int)lroundf(constrain(received_pedal_value, 0.0f, 100.0f));
  const int lock_requested = constrain((int)lroundf(lock_target), 0, 100);
  const int lock_actual = constrain((int)received_haldex_engagement, 0, 100);
  const int mode = (int)openhaldexEffectiveMode();

  char count_text[8];
  char rpm_text[8];
  char speed_text[8];
  char pedal_text[8];
  char lock_requested_text[8];
  char lock_actual_text[8];
  char mode_text[4];
  snprintf(count_text, sizeof(count_text), "%u", (unsigned int)count);
  snprintf(rpm_text, sizeof(rpm_text), "%u", (unsigned int)rpm);
  snprintf(speed_text, sizeof(speed_text), "%u", (unsigned int)speed_kmh);
  snprintf(pedal_text, sizeof(pedal_text), "%d", pedal_percent);
  snprintf(lock_requested_text, sizeof(lock_requested_text), "%d", lock_requested);
  snprintf(lock_actual_text, sizeof(lock_actual_text), "%d", lock_actual);
  snprintf(mode_text, sizeof(mode_text), "%d", mode);

  char body[96];
  // Fields: time,count,xacc,yacc,zacc,gyrox,gyroy,gyroz,rpm/d1,d2,a1..a15
  const int body_len = snprintf(body, sizeof(body),
                                 "RC3,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
                                 /* time  */ "", /* count */ count_text,
                                 /* xacc  */ "", /* yacc  */ "", /* zacc  */ "",
                                 /* gyrox */ "", /* gyroy */ "", /* gyroz */ "",
                                 /* rpm/d1 */ rpm_text, /* d2    */ "",
                                 /* a1 speed            */ speed_text,
                                 /* a2 pedal %           */ pedal_text,
                                 /* a3 requested lock %  */ lock_requested_text,
                                 /* a4 actual lock %     */ lock_actual_text,
                                 /* a5 OpenHaldex mode   */ mode_text,
                                 /* a6-a15 */ "", "", "", "", "", "", "", "", "", "");
  if (body_len <= 0 || (size_t)body_len >= sizeof(body)) {
    return 0;
  }

  const uint8_t checksum = xorChecksum(body, (size_t)body_len);
  const int sentence_len = snprintf(out, out_size, "$%s*%02X\r\n", body, checksum);
  return (sentence_len > 0) ? (size_t)sentence_len : 0;
}

void racechronoWifiTask(void* arg) {
  (void)arg;
  uint16_t sequence = 0;
  uint32_t last_accept_attempt_ms = 0;

  for (;;) {
    if (!g_client || !g_client.connected()) {
      g_client.stop();

      const uint32_t now_ms = millis();
      if (now_ms - last_accept_attempt_ms >= kAcceptPollIntervalMs) {
        last_accept_attempt_ms = now_ms;
        WiFiClient incoming = g_server.available();
        if (incoming) {
          g_client = incoming;
          LOG_INFO("racechrono", "WiFi client connected ip=%s", g_client.remoteIP().toString().c_str());
        }
      }

      vTaskDelay(pdMS_TO_TICKS(kAcceptPollIntervalMs));
      continue;
    }

    char sentence[128];
    const size_t sentence_len = buildSentence(sentence, sizeof(sentence), sequence++);
    if (sentence_len > 0) {
      g_client.write(reinterpret_cast<const uint8_t*>(sentence), sentence_len);
    }

    vTaskDelay(pdMS_TO_TICKS(kTelemetryIntervalMs));
  }
}

} // namespace

void racechronoWifiInit() {
  if (g_server_started) {
    return;
  }

  g_server.begin();
  g_server.setNoDelay(true);
  g_server_started = true;

  if (xTaskCreatePinnedToCore(racechronoWifiTask, "racechronoWifi", 4096, nullptr, 1, nullptr, OH_APP_TASK_CORE) !=
      pdPASS) {
    LOG_ERROR("racechrono", "Unable to start RaceChrono WiFi task");
    return;
  }

  LOG_INFO("racechrono", "RaceChrono WiFi bridge ready port=%u", (unsigned int)kTcpPort);
}
